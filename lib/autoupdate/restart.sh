#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIND_APP_AWK="${SCRIPT_DIR}/find_running_app.awk"

LSAPPINFO_BIN="${AUTOUPDATE_LSAPPINFO_BIN:-/usr/bin/lsappinfo}"
OSASCRIPT_BIN="${AUTOUPDATE_OSASCRIPT_BIN:-/usr/bin/osascript}"
OPEN_BIN="${AUTOUPDATE_OPEN_BIN:-/usr/bin/open}"
LAUNCHCTL_BIN="${AUTOUPDATE_LAUNCHCTL_BIN:-/bin/launchctl}"
KILL_BIN="${AUTOUPDATE_KILL_BIN:-/bin/kill}"
ID_BIN="${AUTOUPDATE_ID_BIN:-/usr/bin/id}"
SLEEP_BIN="${AUTOUPDATE_SLEEP_BIN:-/bin/sleep}"
QUIT_TIMEOUT="${AUTOUPDATE_RESTART_QUIT_TIMEOUT:-10}"
POLL_INTERVAL="${AUTOUPDATE_RESTART_POLL_INTERVAL:-0.5}"
RELAUNCH_DELAY="${AUTOUPDATE_RESTART_RELAUNCH_DELAY:-0.5}"

BREW_BIN=""
BREW_SERVICES_LOADED=0
BREW_SERVICES_LIST=""

expand_tilde() {
  local value="$1"
  case "${value}" in
    \~/*)
      printf '%s/%s\n' "${HOME}" "${value#\~/}"
      ;;
    *)
      printf '%s\n' "${value}"
      ;;
  esac
}

tsv_field() {
  local line="$1"
  local index="$2"
  /usr/bin/awk -F '\t' -v idx="${index}" '{ print $idx }' <<<"${line}"
}

# Match a UI app specification (app name, Foo.app, /path/to/Foo.app, or bundle ID)
# against the output of `lsappinfo list`. Prints: pid<TAB>bundle_id<TAB>bundle_path
find_running_app() {
  local target="$1"
  local lsappinfo_output="$2"
  local expanded_target
  expanded_target=$(expand_tilde "${target}")

  [[ -n "${lsappinfo_output}" ]] || return 0

  TARGET_APP="${expanded_target}" /usr/bin/awk -f "${FIND_APP_AWK}" <<<"${lsappinfo_output}"
}

snapshot_apps() {
  local state_file="$1"
  shift

  if [[ -z "${state_file}" ]]
  then
    return 0
  fi

  : >"${state_file}" || return 0
  [[ "$#" -gt 0 ]] || return 0

  local lsappinfo_output
  lsappinfo_output=$("${LSAPPINFO_BIN}" list 2>/dev/null || true)
  [[ -n "${lsappinfo_output}" ]] || return 0

  local app match
  for app in "$@"
  do
    match=$(find_running_app "${app}" "${lsappinfo_output}")
    if [[ -n "${match}" ]]
    then
      printf '%s\t%s\n' "${app}" "${match}" >>"${state_file}"
    fi
  done
}

upgrades_occurred() {
  local log_file="$1"
  [[ -n "${log_file}" ]] && [[ -f "${log_file}" ]] || return 1

  /usr/bin/awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); if ($0 ~ /^==> Upgrading /) { found = 1; exit 0 } } END { exit (found ? 0 : 1) }' "${log_file}"
}

lookup_snapshot_entry() {
  local state_file="$1"
  local app="$2"

  [[ -n "${state_file}" ]] && [[ -f "${state_file}" ]] || return 1

  TARGET_APP="${app}" /usr/bin/awk -F '\t' '$1 == ENVIRON["TARGET_APP"] { printf "%s\t%s\t%s\n", $2, $3, $4; found = 1; exit 0 } END { exit (found ? 0 : 1) }' "${state_file}"
}

wait_for_app_exit() {
  local app="$1"
  local pid="$2"

  local max_checks
  max_checks=$(/usr/bin/awk -v t="${QUIT_TIMEOUT}" -v p="${POLL_INTERVAL}" 'BEGIN { if (p <= 0) { print 1; exit } n = int((t / p) + 0.999999); if (n < 1) n = 1; print n }')

  local i=0
  while [[ "${i}" -lt "${max_checks}" ]]
  do
    local pid_alive=0
    if [[ -n "${pid}" ]] && "${KILL_BIN}" -0 "${pid}" 2>/dev/null
    then
      pid_alive=1
    fi

    if [[ "${pid_alive}" -eq 0 ]]
    then
      local current_output current_match
      current_output=$("${LSAPPINFO_BIN}" list 2>/dev/null || true)
      current_match=$(find_running_app "${app}" "${current_output}")
      if [[ -z "${current_match}" ]]
      then
        return 0
      fi
    fi

    "${SLEEP_BIN}" "${POLL_INTERVAL}"
    i=$((i + 1))
  done

  return 1
}

quit_running_app() {
  local app="$1"
  local pid="$2"
  local bundle_id="$3"
  local bundle_path="$4"

  local osa_err osa_status
  if [[ -n "${bundle_id}" ]]
  then
    osa_err=$("${OSASCRIPT_BIN}" \
      -e 'on run argv' \
      -e "with timeout of ${QUIT_TIMEOUT} seconds" \
      -e 'tell application id (item 1 of argv) to quit' \
      -e 'end timeout' \
      -e 'end run' \
      -- "${bundle_id}" 2>&1)
    osa_status=$?
  else
    local osa_target="${bundle_path:-${app}}"
    osa_err=$("${OSASCRIPT_BIN}" \
      -e 'on run argv' \
      -e "with timeout of ${QUIT_TIMEOUT} seconds" \
      -e 'tell application (item 1 of argv) to quit' \
      -e 'end timeout' \
      -e 'end run' \
      -- "${osa_target}" 2>&1)
    osa_status=$?
  fi

  if [[ "${osa_status}" -ne 0 ]]
  then
    if [[ "${osa_err}" == *"-1712"* ]]
    then
      printf "Warning: timed out asking UI app '%s' to quit; skipping relaunch.\n" "${app}" >&2
      return 1
    fi

    if [[ -n "${pid}" ]]
    then
      "${KILL_BIN}" -TERM "${pid}" 2>/dev/null || true
    fi
  fi

  if ! wait_for_app_exit "${app}" "${pid}"
  then
    printf "Warning: UI app '%s' did not quit within %ss; skipping relaunch.\n" "${app}" "${QUIT_TIMEOUT}" >&2
    return 1
  fi

  if [[ "${RELAUNCH_DELAY}" != "0" ]] && [[ "${RELAUNCH_DELAY}" != "0.0" ]]
  then
    "${SLEEP_BIN}" "${RELAUNCH_DELAY}"
  fi

  return 0
}

launch_ui_app() {
  local app="$1"
  local bundle_id="$2"
  local bundle_path="$3"
  local expanded_app
  expanded_app=$(expand_tilde "${app}")

  if [[ -n "${bundle_path}" ]] && [[ -d "${bundle_path}" ]]
  then
    "${OPEN_BIN}" -g "${bundle_path}"
  elif [[ -n "${bundle_id}" ]]
  then
    "${OPEN_BIN}" -g -b "${bundle_id}"
  elif [[ "${expanded_app}" == /* ]] && [[ -d "${expanded_app}" ]]
  then
    "${OPEN_BIN}" -g "${expanded_app}"
  else
    "${OPEN_BIN}" -g -a "${app}"
  fi
}

restart_ui_app() {
  local app="$1"
  local state_file="$2"
  local only_if_stopped="${3:-0}"

  local pre_entry
  if ! pre_entry=$(lookup_snapshot_entry "${state_file}" "${app}")
  then
    printf "Skipping UI app '%s' (was not running before update).\n" "${app}"
    return 0
  fi

  local pre_bundle_id pre_bundle_path
  pre_bundle_id=$(tsv_field "${pre_entry}" 2)
  pre_bundle_path=$(tsv_field "${pre_entry}" 3)

  local current_output current_match
  current_output=$("${LSAPPINFO_BIN}" list 2>/dev/null || true)
  current_match=$(find_running_app "${app}" "${current_output}")

  local launch_bundle_id="${pre_bundle_id}"
  local launch_bundle_path="${pre_bundle_path}"

  if [[ -n "${current_match}" ]]
  then
    if [[ "${only_if_stopped}" -eq 1 ]]
    then
      printf "Skipping UI app '%s' (still running; no upgrades were applied).\n" "${app}"
      return 0
    fi

    local cur_pid cur_bundle_id cur_bundle_path
    cur_pid=$(tsv_field "${current_match}" 1)
    cur_bundle_id=$(tsv_field "${current_match}" 2)
    cur_bundle_path=$(tsv_field "${current_match}" 3)
    [[ -n "${cur_bundle_id}" ]] && launch_bundle_id="${cur_bundle_id}"
    [[ -n "${cur_bundle_path}" ]] && launch_bundle_path="${cur_bundle_path}"

    printf "Restarting UI app '%s'...\n" "${app}"
    if ! quit_running_app "${app}" "${cur_pid}" "${launch_bundle_id}" "${launch_bundle_path}"
    then
      return 0
    fi
  else
    printf "Relaunching UI app '%s' (was running before update)...\n" "${app}"
  fi

  if ! launch_ui_app "${app}" "${launch_bundle_id}" "${launch_bundle_path}"
  then
    printf "Warning: failed to launch UI app '%s'.\n" "${app}" >&2
  fi
}

load_brew_services() {
  if [[ "${BREW_SERVICES_LOADED}" -eq 1 ]]
  then
    return 0
  fi
  BREW_SERVICES_LOADED=1
  if [[ -n "${BREW_BIN}" ]]
  then
    BREW_SERVICES_LIST=$("${BREW_BIN}" services list 2>/dev/null | /usr/bin/awk 'NR > 1 && NF > 0 { gsub(/\033\[[0-9;]*[A-Za-z]/, ""); printf "%s\t%s\n", $1, $2 }' || true)
  fi
}

match_brew_service() {
  local service="$1"
  load_brew_services
  [[ -n "${BREW_SERVICES_LIST}" ]] || return 1

  local short_name="${service}"
  if [[ "${service}" != gui/* ]] && [[ "${service}" != user/* ]] && [[ "${service}" != system/* ]] && [[ "${service}" != pid/* ]]
  then
    short_name="${service##*/}"
  fi

  local line name
  while IFS= read -r line
  do
    [[ -n "${line}" ]] || continue
    name=$(tsv_field "${line}" 1)
    if [[ "${name}" == "${service}" ]] || [[ "${name}" == "${short_name}" ]]
    then
      printf '%s\n' "${line}"
      return 0
    fi
  done <<<"${BREW_SERVICES_LIST}"

  return 1
}

restart_service() {
  local service="$1"
  local only_if_stopped="${2:-0}"

  local matched_entry
  if matched_entry=$(match_brew_service "${service}")
  then
    local matched_brew_service brew_status
    matched_brew_service=$(tsv_field "${matched_entry}" 1)
    brew_status=$(tsv_field "${matched_entry}" 2)

    if [[ "${only_if_stopped}" -eq 1 ]] && { [[ "${brew_status}" == "started" ]] || [[ "${brew_status}" == "scheduled" ]]; }
    then
      printf "Skipping service '%s' (already running; no upgrades were applied).\n" "${service}"
      return 0
    fi

    printf "Restarting service '%s' via brew services...\n" "${service}"
    if ! "${BREW_BIN}" services restart "${matched_brew_service}"
    then
      printf "Warning: failed to restart brew service '%s'.\n" "${service}" >&2
    fi
    return 0
  fi

  local uid
  uid=$("${ID_BIN}" -u)

  local candidates=()
  case "${service}" in
    gui/* | user/* | system/* | pid/*)
      candidates=("${service}")
      ;;
    *)
      candidates=("gui/${uid}/${service}" "user/${uid}/${service}" "system/${service}")
      ;;
  esac

  local target print_output
  for target in "${candidates[@]}"
  do
    if print_output=$("${LAUNCHCTL_BIN}" print "${target}" 2>/dev/null)
    then
      if [[ "${only_if_stopped}" -eq 1 ]] && [[ "${print_output}" == *"state = running"* ]]
      then
        printf "Skipping service '%s' (already running; no upgrades were applied).\n" "${service}"
        return 0
      fi

      printf "Restarting service '%s' via launchctl (%s)...\n" "${service}" "${target}"
      if ! "${LAUNCHCTL_BIN}" kickstart -k "${target}"
      then
        printf "Warning: failed to restart launchd service '%s' (%s).\n" "${service}" "${target}" >&2
      fi
      return 0
    fi
  done

  printf "Warning: service '%s' was not found in brew services or launchd; skipping.\n" "${service}" >&2
}

main() {
  local action="${1:-}"
  shift || true

  local status="0"
  local run_log=""
  local state_file=""
  local apps=()
  local services=()

  while [[ "$#" -gt 0 ]]
  do
    case "$1" in
      --status)
        status="${2:-0}"
        shift 2
        ;;
      --run-log)
        run_log="${2:-}"
        shift 2
        ;;
      --state-file)
        state_file="${2:-}"
        shift 2
        ;;
      --brew)
        BREW_BIN="${2:-}"
        shift 2
        ;;
      --app)
        apps+=("${2:-}")
        shift 2
        ;;
      --service)
        services+=("${2:-}")
        shift 2
        ;;
      *)
        printf "Warning: unknown restart option: %s\n" "$1" >&2
        shift
        ;;
    esac
  done

  case "${action}" in
    snapshot)
      if [[ "${#apps[@]}" -gt 0 ]]
      then
        snapshot_apps "${state_file}" "${apps[@]}"
      fi
      ;;
    apply)
      if [[ "${#services[@]}" -eq 0 ]] && [[ "${#apps[@]}" -eq 0 ]]
      then
        return 0
      fi

      local only_if_stopped=0
      if upgrades_occurred "${run_log}"
      then
        if [[ "${status}" -ne 0 ]]
        then
          printf "==> Homebrew autoupdate exited with status %s; restarting configured apps and services...\n" "${status}"
        else
          printf "==> Restarting configured apps and services...\n"
        fi
      elif [[ "${status}" -ne 0 ]]
      then
        only_if_stopped=1
        printf "==> Homebrew autoupdate exited with status %s; ensuring configured apps and services are running...\n" "${status}"
      else
        printf "Skipping restarts: no packages were upgraded.\n"
        return 0
      fi

      if [[ "${#services[@]}" -gt 0 ]]
      then
        local service
        for service in "${services[@]}"
        do
          restart_service "${service}" "${only_if_stopped}"
        done
      fi

      if [[ "${#apps[@]}" -gt 0 ]]
      then
        local app
        for app in "${apps[@]}"
        do
          restart_ui_app "${app}" "${state_file}" "${only_if_stopped}"
        done
      fi
      ;;
    *)
      printf "Usage: %s <snapshot|apply> [options]\n" "$0" >&2
      return 1
      ;;
  esac
}

main "$@"
