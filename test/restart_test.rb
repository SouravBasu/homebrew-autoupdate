# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/autoupdate/restart"

class RestartTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__).freeze
  SCRIPT = File.expand_path("../lib/autoupdate/restart.sh", __dir__).freeze

  def test_restart_script_resolves_to_repository_helper
    assert_equal SCRIPT, Autoupdate::Restart.restart_script
    assert File.executable?(SCRIPT)
  end

  def test_normalize_apps_trims_deduplicates_and_validates
    normalized = Autoupdate::Restart.normalize_apps([
      " Raycast ",
      "Visual Studio Code",
      "Raycast",
      "",
      "  ",
      "/Applications/Docker.app",
      "com.microsoft.VSCode",
    ])

    assert_equal ["Raycast", "Visual Studio Code", "/Applications/Docker.app", "com.microsoft.VSCode"], normalized

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_apps(["", "   "])
    end

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_apps(["Raycast\nEvil"])
    end

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_apps(["Bad\tApp"])
    end
  end

  def test_normalize_services_trims_deduplicates_and_validates
    normalized = Autoupdate::Restart.normalize_services([
      " redis ",
      "postgresql@16",
      "felixkratz/formulae/sketchybar",
      "com.example.my-agent_1",
      "gui/501/com.example.explicit",
      "redis",
    ])

    assert_equal [
      "redis",
      "postgresql@16",
      "felixkratz/formulae/sketchybar",
      "com.example.my-agent_1",
      "gui/501/com.example.explicit",
    ], normalized

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_services(["", " "])
    end

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_services(["redis; rm -rf /"])
    end

    assert_raises(Autoupdate::Restart::InvalidTargetError) do
      Autoupdate::Restart.normalize_services(["$(whoami)"])
    end
  end

  def test_commands_round_trip_through_configured_targets
    apps = ["Raycast", "Visual Studio Code", "Bob's \"App\""]
    services = ["redis", "com.example.agent"]

    snapshot = Autoupdate::Restart.snapshot_command(apps: apps)
    apply = Autoupdate::Restart.apply_command(apps: apps, services: services, brew: "/opt/homebrew/bin/brew")

    assert_includes snapshot, "restart.sh snapshot --state-file \"$restart_state\""
    assert_includes apply, "restart.sh apply --status \"$status\" --run-log \"$run_log\""

    fake_script = <<~SH
      #!/bin/sh
      /bin/date
      #{snapshot}
      (/opt/homebrew/bin/brew update) >"$run_log" 2>&1
      status=$?
      #{apply}
      exit "$status"
    SH

    parsed = Autoupdate::Restart.configured_targets(fake_script)
    assert_equal apps, parsed[:apps]
    assert_equal services, parsed[:services]
  end

  def test_configured_targets_returns_empty_when_unconfigured
    parsed = Autoupdate::Restart.configured_targets("#!/bin/sh\n/bin/date\n")
    assert_equal({ apps: [], services: [] }, parsed)
  end

  def test_restarts_apps_and_services_when_upgrade_run_fails
    with_harness do |h|
      drive_app = h.create_app_bundle("Google Drive.app")
      chrome_app = h.create_app_bundle("Google Chrome.app")
      h.write_lsappinfo(<<~LIST)
        1) "Google Drive" ASN:0x0-0x1001:
           bundleID="com.google.drivefs"
           bundle path="#{drive_app}"
           pid = 8100 token=[sess=100015 pid=8100] type="UIElement" flavor=3
        2) "Google Chrome" ASN:0x0-0x2002:
           bundleID="com.google.Chrome"
           bundle path="#{chrome_app}"
           pid = 8200 token=[sess=100015 pid=8200] type="Foreground" flavor=3
      LIST
      h.write_brew_services(<<~SERVICES)
        Name  Status  User   File
        redis stopped sourav ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
      SERVICES
      h.write_launchctl_targets(["gui/501/com.example.agent"])

      apps = ["Google Drive", "Google Chrome", "WhatsApp"]
      _, snap_status = h.snapshot(apps: apps)
      assert_predicate snap_status, :success?

      # Simulate brew upgrade quitting Google Drive before failing, while Chrome stays running.
      h.write_lsappinfo(<<~LIST)
        2) "Google Chrome" ASN:0x0-0x2002:
           bundleID="com.google.Chrome"
           bundle path="#{chrome_app}"
           pid = 8200 token=[sess=100015 pid=8200] type="Foreground" flavor=3
      LIST
      h.mark_pid_alive(8200)
      h.write_log("==> Upgrading google-drive\nError: sudo failed\n")

      output, status = h.apply(
        exit_status: 1,
        services:    ["redis", "com.example.agent"],
        apps:        apps,
      )

      assert_predicate status, :success?, output
      assert_includes output, "Homebrew autoupdate exited with status 1; restarting configured apps and services..."
      assert_includes output, "Relaunching UI app 'Google Drive' (was running before update)..."
      assert_includes output, "Restarting UI app 'Google Chrome'..."
      assert_includes output, "Skipping UI app 'WhatsApp' (was not running before update)."

      calls = h.recorded_calls
      assert_includes calls, "brew:services restart redis"
      assert_includes calls, "launchctl:kickstart -k gui/501/com.example.agent"
      assert_includes calls, "open:-g #{drive_app}"
      assert_includes calls, "osascript:quit-id:com.google.Chrome"
      assert_includes calls, "open:-g #{chrome_app}"
    end
  end

  def test_ensures_stopped_apps_and_services_restart_when_run_fails_before_upgrades
    with_harness do |h|
      drive_app = h.create_app_bundle("Google Drive.app")
      chrome_app = h.create_app_bundle("Google Chrome.app")
      h.write_lsappinfo(<<~LIST)
        1) "Google Drive" ASN:0x0-0x1001:
           bundleID="com.google.drivefs"
           bundle path="#{drive_app}"
           pid = 9100 token=[sess=100015 pid=9100] type="UIElement" flavor=3
        2) "Google Chrome" ASN:0x0-0x2002:
           bundleID="com.google.Chrome"
           bundle path="#{chrome_app}"
           pid = 9200 token=[sess=100015 pid=9200] type="Foreground" flavor=3
      LIST
      h.write_brew_services(<<~SERVICES)
        Name       Status  User   File
        redis      started sourav ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
        postgresql stopped sourav ~/Library/LaunchAgents/homebrew.mxcl.postgresql.plist
      SERVICES
      h.write_launchctl_targets([
        "gui/501/com.example.running:running",
        "gui/501/com.example.stopped:not running",
      ])

      apps = ["Google Drive", "Google Chrome"]
      _, snap_status = h.snapshot(apps: apps)
      assert_predicate snap_status, :success?

      # Only Google Drive stopped; Google Chrome is still running; no upgrades logged.
      h.write_lsappinfo(<<~LIST)
        2) "Google Chrome" ASN:0x0-0x2002:
           bundleID="com.google.Chrome"
           bundle path="#{chrome_app}"
           pid = 9200 token=[sess=100015 pid=9200] type="Foreground" flavor=3
      LIST
      h.write_log("Error: Could not resolve host: github.com\n")

      output, status = h.apply(
        exit_status: 1,
        services:    ["redis", "postgresql", "com.example.running", "com.example.stopped"],
        apps:        apps,
      )

      assert_predicate status, :success?, output
      assert_includes output,
                      "Homebrew autoupdate exited with status 1; ensuring configured apps and services are running..."
      assert_includes output, "Skipping service 'redis' (already running; no upgrades were applied)."
      assert_includes output, "Restarting service 'postgresql' via brew services..."
      assert_includes output, "Skipping service 'com.example.running' (already running; no upgrades were applied)."
      assert_includes output,
                      "Restarting service 'com.example.stopped' via launchctl (gui/501/com.example.stopped)..."
      assert_includes output, "Relaunching UI app 'Google Drive' (was running before update)..."
      assert_includes output, "Skipping UI app 'Google Chrome' (still running; no upgrades were applied)."

      calls = h.recorded_calls
      assert_includes calls, "brew:services restart postgresql"
      assert_includes calls, "launchctl:kickstart -k gui/501/com.example.stopped"
      assert_includes calls, "open:-g #{drive_app}"
      refute_includes calls, "brew:services restart redis"
      refute_includes calls, "launchctl:kickstart -k gui/501/com.example.running"
      refute(calls.any? { |c| c.include?("Google Chrome") })
    end
  end

  def test_skips_restarts_when_nothing_was_upgraded
    with_harness do |h|
      h.write_log(<<~LOG)
        ==> Updating Homebrew...
        Updated 1 tap (homebrew/core).
        Already up-to-date.
        Warning: Not upgrading wget, the latest version is already installed
      LOG
      output, status = h.apply(exit_status: 0, services: ["redis"], apps: ["Raycast"])

      assert_predicate status, :success?, output
      assert_includes output, "Skipping restarts: no packages were upgraded."
      assert_empty h.recorded_calls
    end
  end

  def test_restarts_running_ui_app_and_skips_closed_ui_app
    with_harness do |h|
      vscode_app = h.create_app_bundle("Visual Studio Code.app")
      stats_app = h.create_app_bundle("Stats.app")
      h.write_lsappinfo(<<~LIST)
        1) "Code" ASN:0x0-0x1001:
           bundleID="com.microsoft.VSCode"
           bundle path="#{vscode_app}"
           executable path="#{vscode_app}/Contents/MacOS/Electron"
           pid = 4100 token=[sess=100015 pid=4100] type="Foreground" flavor=3
        2) "Stats" ASN:0x0-0x2002:
           bundleID="eu.exelban.Stats"
           bundle path="#{stats_app}"
           executable path="#{stats_app}/Contents/MacOS/Stats"
           pid = 4200 token=[sess=100015 pid=4200] type="UIElement" flavor=3
        3) "Google Chrome Helper" ASN:0x0-0x3003:
           bundleID="com.google.Chrome.helper"
           bundle path="/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app"
           pid = 4300 token=[sess=100015 pid=4300] type="UIElement" flavor=3
        4) "Intents" ASN:0x0-0x4004:
           bundleID="net.whatsapp.WhatsApp.Intents"
           bundle path="/Applications/WhatsApp.app/Contents/PlugIns/Intents.appex"
           pid = 4400 token=[sess=100015 pid=4400] type="BackgroundOnly" flavor=2
      LIST

      apps = ["Visual Studio Code", "Stats", "Google Chrome", "WhatsApp", "Docker"]
      snap_out, snap_status = h.snapshot(apps: apps)
      assert_predicate snap_status, :success?, snap_out

      # Simulate brew upgrade quitting Stats during cask upgrade, while VS Code stays running.
      h.write_lsappinfo(<<~LIST)
        1) "Code" ASN:0x0-0x1001:
           bundleID="com.microsoft.VSCode"
           bundle path="#{vscode_app}"
           executable path="#{vscode_app}/Contents/MacOS/Electron"
           pid = 4100 token=[sess=100015 pid=4100] type="Foreground" flavor=3
      LIST
      h.mark_pid_alive(4100)
      h.write_log("\e[34m==>\e[0m Upgrading 2 outdated packages:\nvisual-studio-code\nstats\n")

      output, status = h.apply(exit_status: 0, apps: apps)

      assert_predicate status, :success?, output
      assert_includes output, "Restarting UI app 'Visual Studio Code'..."
      assert_includes output, "Relaunching UI app 'Stats' (was running before update)..."
      assert_includes output, "Skipping UI app 'Google Chrome' (was not running before update)."
      assert_includes output, "Skipping UI app 'WhatsApp' (was not running before update)."
      assert_includes output, "Skipping UI app 'Docker' (was not running before update)."

      calls = h.recorded_calls
      assert_includes calls, "osascript:quit-id:com.microsoft.VSCode"
      assert_includes calls, "open:-g #{vscode_app}"
      assert_includes calls, "open:-g #{stats_app}"
      refute(calls.any? { |c| c.include?("Google Chrome") || c.include?("WhatsApp") || c.include?("Docker") })
    end
  end

  def test_matches_app_by_bundle_id_full_path_dot_app_and_null_bundle_id
    with_harness do |h|
      raycast_app = h.create_app_bundle("Raycast.app")
      custom_app = h.create_app_bundle("CustomTool.app")
      h.write_lsappinfo(<<~LIST)
        1) "Raycast" ASN:0x0-0x1001:
           bundleID="com.raycast.macos"
           bundle path="#{raycast_app}"
           pid = 5100 token=[sess=100015 pid=5100] type="UIElement" flavor=3
        2) "CustomTool" ASN:0x0-0x2002:
           bundleID=[ NULL ]
           bundle path="#{custom_app}"
           pid = 5200 token=[sess=100015 pid=5200] type="Foreground" flavor=3
      LIST

      apps = ["com.raycast.macos", custom_app]
      _, snap_status = h.snapshot(apps: apps)
      assert_predicate snap_status, :success?

      # Both apps exited during cask upgrade; raycast bundle moved so fallback to bundle ID.
      FileUtils.rm_rf(raycast_app)
      h.write_lsappinfo("")
      h.write_log("==> Upgrading raycast\n")

      output, status = h.apply(exit_status: 0, apps: apps)

      assert_predicate status, :success?, output
      calls = h.recorded_calls
      assert_includes calls, "open:-g -b com.raycast.macos"
      assert_includes calls, "open:-g #{custom_app}"
    end
  end

  def test_falls_back_to_sigterm_when_osascript_not_authorized
    with_harness do |h|
      app_bundle = h.create_app_bundle("Alacritty.app")
      h.write_lsappinfo(<<~LIST)
        1) "Alacritty" ASN:0x0-0x1001:
           bundleID="org.alacritty"
           bundle path="#{app_bundle}"
           pid = 6100 token=[sess=100015 pid=6100] type="Foreground" flavor=3
      LIST
      h.mark_pid_alive(6100)
      h.write_osascript_behavior("deny")

      _, snap_status = h.snapshot(apps: ["Alacritty.app"])
      assert_predicate snap_status, :success?

      h.write_log("==> Upgrading alacritty\n")
      output, status = h.apply(exit_status: 0, apps: ["Alacritty.app"])

      assert_predicate status, :success?, output
      calls = h.recorded_calls
      assert_includes calls, "kill:-TERM 6100"
      assert_includes calls, "open:-g #{app_bundle}"
    end
  end

  def test_skips_relaunch_when_osascript_times_out_or_app_refuses_to_quit
    with_harness do |h|
      app_bundle = h.create_app_bundle("Obsidian.app")
      h.write_lsappinfo(<<~LIST)
        1) "Obsidian" ASN:0x0-0x1001:
           bundleID="md.obsidian"
           bundle path="#{app_bundle}"
           pid = 7100 token=[sess=100015 pid=7100] type="Foreground" flavor=3
      LIST
      h.mark_pid_alive(7100)
      h.write_osascript_behavior("timeout")

      _, snap_status = h.snapshot(apps: ["Obsidian"])
      assert_predicate snap_status, :success?

      h.write_log("==> Upgrading obsidian\n")
      output, status = h.apply(exit_status: 0, apps: ["Obsidian"])

      assert_predicate status, :success?, output
      assert_includes output, "Warning: timed out asking UI app 'Obsidian' to quit; skipping relaunch."
      calls = h.recorded_calls
      refute(calls.any? { |c| c.start_with?("kill:-TERM") })
      refute(calls.any? { |c| c.start_with?("open:") })

      # Also test when osascript returns 0 but the app never exits before timeout.
      h.write_osascript_behavior("hang")
      output, status = h.apply(exit_status: 0, apps: ["Obsidian"])

      assert_predicate status, :success?, output
      assert_includes output, "Warning: UI app 'Obsidian' did not quit within 1s; skipping relaunch."
      refute(h.recorded_calls.any? { |c| c.start_with?("open:") })
    end
  end

  def test_restarts_brew_services_and_launchd_services_with_fallback
    with_harness do |h|
      h.write_brew_services(<<~SERVICES)
        Name       Status  User   File
        redis      started sourav ~/Library/LaunchAgents/homebrew.mxcl.redis.plist
        sketchybar started sourav ~/Library/LaunchAgents/homebrew.mxcl.sketchybar.plist
      SERVICES
      h.write_launchctl_targets([
        "gui/501/com.example.guiagent",
        "user/501/com.example.useragent",
        "gui/501/com.example.explicit",
      ])
      h.write_log("==> Upgrading 1 outdated package:\nredis\n")

      services = [
        "redis",
        "felixkratz/formulae/sketchybar",
        "com.example.guiagent",
        "com.example.useragent",
        "gui/501/com.example.explicit",
        "com.example.missing",
      ]

      output, status = h.apply(exit_status: 0, services: services)

      assert_predicate status, :success?, output
      assert_includes output, "Restarting service 'redis' via brew services..."
      assert_includes output, "Restarting service 'felixkratz/formulae/sketchybar' via brew services..."
      assert_includes output,
                      "Restarting service 'com.example.guiagent' via launchctl (gui/501/com.example.guiagent)..."
      assert_includes output,
                      "Restarting service 'com.example.useragent' via launchctl (user/501/com.example.useragent)..."
      assert_includes output,
                      "Restarting service 'gui/501/com.example.explicit' via launchctl " \
                      "(gui/501/com.example.explicit)..."
      assert_includes output,
                      "Warning: service 'com.example.missing' was not found in brew services or launchd; skipping."

      calls = h.recorded_calls
      assert_includes calls, "brew:services restart redis"
      assert_includes calls, "brew:services restart sketchybar"
      assert_includes calls, "launchctl:kickstart -k gui/501/com.example.guiagent"
      assert_includes calls, "launchctl:kickstart -k user/501/com.example.useragent"
      assert_includes calls, "launchctl:kickstart -k gui/501/com.example.explicit"
    end
  end

  private

  class RestartHarness
    attr_reader :dir, :state_file, :run_log

    def initialize(dir)
      @dir = dir
      @bin_dir = File.join(dir, "bin")
      @apps_dir = File.join(dir, "Applications")
      @calls_file = File.join(dir, "calls.log")
      @lsappinfo_file = File.join(dir, "lsappinfo.txt")
      @brew_services_file = File.join(dir, "brew_services.txt")
      @launchctl_targets_file = File.join(dir, "launchctl_targets.txt")
      @osascript_mode_file = File.join(dir, "osascript_mode.txt")
      @alive_pids_dir = File.join(dir, "pids")
      @state_file = File.join(dir, "restart_state.tsv")
      @run_log = File.join(dir, "run.log")

      FileUtils.mkdir_p([@bin_dir, @apps_dir, @alive_pids_dir])
      File.write(@calls_file, "")
      File.write(@lsappinfo_file, "")
      File.write(@brew_services_file, "")
      File.write(@launchctl_targets_file, "")
      File.write(@osascript_mode_file, "ok")

      write_stub("id", "echo 501")
      write_stub("lsappinfo", "cat \"#{@lsappinfo_file}\"")
      write_stub("open", "echo \"open:$*\" >> \"#{@calls_file}\"")
      write_stub("kill", <<~SH)
        signal="$1"
        pid="$2"
        if [[ "$signal" == "-0" ]]; then
          [[ -f "#{@alive_pids_dir}/$pid" ]]
          exit $?
        fi
        echo "kill:$signal $pid" >> "#{@calls_file}"
        rm -f "#{@alive_pids_dir}/$pid"
        : > "#{@lsappinfo_file}"
      SH
      write_stub("osascript", <<~SH)
        mode=$(cat "#{@osascript_mode_file}")
        target="${@: -1}"
        if [[ "$*" == *"tell application id"* ]]; then
          echo "osascript:quit-id:$target" >> "#{@calls_file}"
        else
          echo "osascript:quit:$target" >> "#{@calls_file}"
        fi
        case "$mode" in
          ok)
            rm -f "#{@alive_pids_dir}"/*
            : > "#{@lsappinfo_file}"
            exit 0
            ;;
          deny)
            echo "execution error: Not authorized to send Apple events (-1743)" >&2
            exit 1
            ;;
          timeout)
            echo "execution error: AppleEvent timed out. (-1712)" >&2
            exit 1
            ;;
          hang)
            exit 0
            ;;
        esac
      SH
      write_stub("brew", <<~SH)
        if [[ "$1" == "services" && "$2" == "list" ]]; then
          cat "#{@brew_services_file}"
          exit 0
        fi
        echo "brew:$*" >> "#{@calls_file}"
      SH
      write_stub("launchctl", <<~SH)
        if [[ "$1" == "print" ]]; then
          if grep -Fxq "$2" "#{@launchctl_targets_file}"; then
            echo "state = running"
            exit 0
          fi
          line=$(grep -F "$2:" "#{@launchctl_targets_file}" | head -n 1)
          if [[ -n "$line" ]]; then
            state="${line#*:}"
            echo "state = $state"
            exit 0
          fi
          exit 113
        fi
        echo "launchctl:$*" >> "#{@calls_file}"
      SH
    end

    def create_app_bundle(name)
      path = File.join(@apps_dir, name)
      FileUtils.mkdir_p(path)
      path
    end

    def write_lsappinfo(content)
      File.write(@lsappinfo_file, content)
    end

    def write_brew_services(content)
      File.write(@brew_services_file, content)
    end

    def write_launchctl_targets(targets)
      File.write(@launchctl_targets_file, "#{targets.join("\n")}\n")
    end

    def write_osascript_behavior(mode)
      File.write(@osascript_mode_file, mode)
    end

    def mark_pid_alive(pid)
      File.write(File.join(@alive_pids_dir, pid.to_s), "1")
    end

    def write_log(content)
      File.write(@run_log, content)
    end

    def recorded_calls
      File.read(@calls_file).lines(chomp: true)
    end

    def snapshot(apps:)
      args = ["snapshot", "--state-file", @state_file]
      apps.each { |app| args << "--app" << app }
      run_script(args)
    end

    def apply(exit_status:, apps: [], services: [])
      args = [
        "apply",
        "--status",
        exit_status.to_s,
        "--run-log",
        @run_log,
        "--brew",
        File.join(@bin_dir, "brew"),
      ]
      args << "--state-file" << @state_file if apps.any?
      apps.each { |app| args << "--app" << app }
      services.each { |svc| args << "--service" << svc }
      run_script(args)
    end

    private

    def run_script(args)
      env = {
        "AUTOUPDATE_LSAPPINFO_BIN"          => File.join(@bin_dir, "lsappinfo"),
        "AUTOUPDATE_OSASCRIPT_BIN"          => File.join(@bin_dir, "osascript"),
        "AUTOUPDATE_OPEN_BIN"               => File.join(@bin_dir, "open"),
        "AUTOUPDATE_LAUNCHCTL_BIN"          => File.join(@bin_dir, "launchctl"),
        "AUTOUPDATE_KILL_BIN"               => File.join(@bin_dir, "kill"),
        "AUTOUPDATE_ID_BIN"                 => File.join(@bin_dir, "id"),
        "AUTOUPDATE_SLEEP_BIN"              => "/usr/bin/true",
        "AUTOUPDATE_RESTART_QUIT_TIMEOUT"   => "1",
        "AUTOUPDATE_RESTART_POLL_INTERVAL"  => "0.2",
        "AUTOUPDATE_RESTART_RELAUNCH_DELAY" => "0",
      }
      stdout, stderr, status = Open3.capture3(env, SCRIPT, *args)
      ["#{stdout}#{stderr}", status]
    end

    def write_stub(name, body)
      path = File.join(@bin_dir, name)
      File.write(path, "#!/bin/bash\n#{body}\n")
      FileUtils.chmod(0755, path)
    end
  end

  def with_harness
    Dir.mktmpdir("autoupdate-restart-test") do |dir|
      yield RestartHarness.new(dir)
    end
  end
end
