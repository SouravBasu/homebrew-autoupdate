# frozen_string_literal: true

require "shellwords"

module Autoupdate
  module Restart
    class InvalidTargetError < ArgumentError; end

    CONTROL_CHARS_REGEX = /[\x00-\x1f\x7f]/
    SERVICE_NAME_REGEX = %r{\A[a-zA-Z0-9\-_.@/+]+\z}

    module_function

    def restart_script
      File.expand_path("restart.sh", __dir__)
    end

    def normalize_apps(raw_apps)
      apps = Array(raw_apps).map(&:strip).reject(&:empty?).uniq
      raise InvalidTargetError, "`--restart-apps` requires at least one app name." if apps.empty?

      invalid = apps.grep(CONTROL_CHARS_REGEX)
      if invalid.any?
        raise InvalidTargetError,
              "Invalid app name(s): app names cannot contain control characters or newlines."
      end

      apps
    end

    def normalize_services(raw_services)
      services = Array(raw_services).map(&:strip).reject(&:empty?).uniq
      raise InvalidTargetError, "`--restart-services` requires at least one service name." if services.empty?

      invalid = services.grep_v(SERVICE_NAME_REGEX)
      if invalid.any?
        raise InvalidTargetError, <<~EOS.chomp
          Invalid service name(s): #{invalid.join(", ")}
          Service names may only contain letters, digits, hyphens, underscores, dots, +, @ signs, and slashes.
        EOS
      end

      services
    end

    def snapshot_command(apps:, state_file: '"$restart_state"')
      return "" if apps.empty?

      parts = [
        Shellwords.escape(restart_script),
        "snapshot",
        "--state-file",
        state_file,
      ]
      apps.each do |app|
        parts << "--app" << Shellwords.escape(app)
      end
      parts.join(" ")
    end

    def apply_command(apps:, services:, brew: Autoupdate::Core.brew, status: '"$status"',
                      run_log: '"$run_log"', state_file: '"$restart_state"')
      return "" if apps.empty? && services.empty?

      parts = [
        Shellwords.escape(restart_script),
        "apply",
        "--status",
        status,
        "--run-log",
        run_log,
        "--brew",
        Shellwords.escape(brew.to_s),
      ]
      parts << "--state-file" << state_file if apps.any?
      apps.each do |app|
        parts << "--app" << Shellwords.escape(app)
      end
      services.each do |service|
        parts << "--service" << Shellwords.escape(service)
      end
      parts.join(" ")
    end

    def configured_targets(script)
      apps = []
      services = []

      apply_line = script.lines.find do |line|
        line.include?("restart.sh") && line.include?(" apply ")
      end
      return { apps: apps, services: services } if apply_line.nil?

      tokens = Shellwords.split(apply_line)
      index = 0
      while index < tokens.length
        case tokens[index]
        when "--app"
          apps << tokens[index + 1] if tokens[index + 1]
          index += 2
        when "--service"
          services << tokens[index + 1] if tokens[index + 1]
          index += 2
        else
          index += 1
        end
      end

      { apps: apps, services: services }
    rescue ArgumentError
      { apps: [], services: [] }
    end
  end
end
