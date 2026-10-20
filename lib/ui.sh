#!/usr/bin/env bash
# Bash 3.2 compatible. No terminal modes, external packages or hidden cursor.
UI_ACCENT='' UI_DIM='' UI_BOLD='' UI_RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
  UI_ACCENT=$'\033[36m'; UI_DIM=$'\033[2m'; UI_BOLD=$'\033[1m'; UI_RESET=$'\033[0m'
fi
ui_header() {
  printf '\n%s  REMOTE / PODMAN%s\n' "$UI_BOLD" "$UI_RESET"
  printf '%s  %s%s\n\n' "$UI_DIM" "$1" "$UI_RESET"
}
ui_pause() { printf '\n  Enter to return to menu... '; IFS= read -r _ || return 1; }
ui_choose() {
  local title="$1" index=0 key rest i
  shift
  local options=("$@")
  while :; do
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then printf '\033[2J\033[H'; fi
    ui_header "$title"
    for ((i=0; i<${#options[@]}; i++)); do
      if ((i == index)); then printf '%s  > %s  %s%s\n' "$UI_ACCENT" "$((i+1))" "${options[i]}" "$UI_RESET"
      else printf '    %s  %s\n' "$((i+1))" "${options[i]}"; fi
    done
    printf '\n%s  Up/Down or j/k / Enter / number / q back%s\n  ' "$UI_DIM" "$UI_RESET"
    IFS= read -rsn1 key || return 1
    case "$key" in
      $'\033')
        rest=''; IFS= read -rsn2 -t 1 rest || true
        case "$rest" in '[A') index=$(((index + ${#options[@]} - 1) % ${#options[@]}));; '[B') index=$(((index + 1) % ${#options[@]}));; *) return 1;; esac;;
      k) index=$(((index + ${#options[@]} - 1) % ${#options[@]}));;
      j) index=$(((index + 1) % ${#options[@]}));;
      '') UI_CHOICE=$index; printf '\n'; return 0;;
      q|Q) printf '\n'; return 1;;
      [1-9]) if ((key <= ${#options[@]})); then index=$((key - 1)); fi;;
    esac
  done
}
ui_config_value() { [[ ! -f "$CONFIG_FILE" ]] || awk -F= -v key="$1" '{ sub(/\r$/, "") } $1 == key { print substr($0,index($0,"=")+1); exit }' "$CONFIG_FILE"; }
ui_ensure_config() {
  [[ ! -f "$CONFIG_FILE" ]] || return 0
  local project
  project="$(basename "$ROOT_DIR" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g;s/^[^a-z0-9]*//;s/^$/project/' | cut -c1-40)"
  umask 077
  sed "s/^PROJECT_NAME=.*/PROJECT_NAME=$project/" "$ROOT_DIR/config/dev.env.example" > "$CONFIG_FILE"
}
ui_run() {
  "$@"
  local result=$?
  if ((result != 0)); then printf '\n%s  Action failed (exit %s). Review the message above.%s\n' "$UI_ACCENT" "$result" "$UI_RESET"; fi
  ui_pause
}
ui_setup_menu() {
  local target
  while ui_choose 'SERVER SETUP / choose a connection path' \
      'Full installation  /  root SSH, Debian or Ubuntu' \
      'Connect existing user  /  Podman already installed' \
      'View configuration' 'Back'; do
    case "$UI_CHOICE" in
      0) ui_ensure_config || return; ui_run bash "$ROOT_DIR/setup.sh" full || return;;
      1)
        ui_ensure_config || return
        printf '\n  Project account SSH target (user@host or alias; blank cancels): '
        IFS= read -r target || return
        [[ -n "$target" ]] || continue
        ui_run bash "$ROOT_DIR/setup.sh" setup "$target" || return;;
      2)
        ui_header 'CONFIGURATION'
        printf '  File: %s\n' "$CONFIG_FILE"
        if [[ -f "$CONFIG_FILE" ]]; then
          printf '  Project: %s\n  Account: %s\n  SSH port: %s\n' "$(ui_config_value PROJECT_NAME)" "$(ui_config_value PODMAN_HOST)" "$(ui_config_value SSH_PORT)"
        else printf '  No configuration yet. Choose a setup option to create it.\n'; fi
        ui_pause || return;;
      3) return;;
    esac
  done
}
menu() {
  [[ -t 0 ]] || { printf 'Open ./dev.sh in a terminal for the menu; use --help for automation.\n' >&2; return 2; }
  local host project title
  while :; do
    host="$(ui_config_value PODMAN_HOST)"; project="$(ui_config_value PROJECT_NAME)"
    if [[ -n "$host" ]]; then title="${project:-Project} / $host / connection not checked"
    else title='WELCOME / start with Server setup'; fi
    ui_choose "$title" 'Server setup' 'Start services + tunnels' 'Status' 'Stop selected services' 'Stop all services (keep volumes)' 'Close tunnel only' 'Check connection' 'Quit' || return 0
    case "$UI_CHOICE" in
      0) ui_setup_menu;;
      1) ui_run bash "$ROOT_DIR/dev.sh" start || return;;
      2) ui_run bash "$ROOT_DIR/dev.sh" status || return;;
      3) ui_run bash "$ROOT_DIR/dev.sh" stop-selected || return;;
      4) ui_run bash "$ROOT_DIR/dev.sh" stop || return;;
      5) ui_run bash "$ROOT_DIR/dev.sh" stop-tunnel || return;;
      6) ui_run bash "$ROOT_DIR/dev.sh" check || return;;
      7) return 0;;
    esac
  done
}
ui_select_services() {
  local marks=() i input
  for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do marks+=(0); done
  while :; do
    ui_header 'SERVICES / select one or more'
    for ((i=0; i<${#SERVICE_NAMES[@]}; i++)); do
      local mark=' '; ((marks[i])) && mark=x
      printf '  %s [%s] %-12s  local ports: %s\n' "$((i+1))" "$mark" "${SERVICE_NAMES[i]}" "${SERVICE_LPORTS[i]}"
    done
    printf '\n  Number toggles / a all / n none / Enter applies / q cancels\n  > '
    IFS= read -r input || return 1
    case "$input" in
      q|Q) return 1;;
      a) for ((i=0; i<${#marks[@]}; i++)); do marks[i]=1; done;;
      n) for ((i=0; i<${#marks[@]}; i++)); do marks[i]=0; done;;
      '')
        SELECTED=()
        for ((i=0; i<${#marks[@]}; i++)); do ((marks[i])) && SELECTED+=("${SERVICE_NAMES[i]}"); done
        ((${#SELECTED[@]})) && return 0
        printf '  Select at least one service.\n';;
      *)
        if [[ "$input" =~ ^[1-9][0-9]?$ ]] && ((input <= ${#marks[@]})); then i=$((input-1)); marks[i]=$((1-marks[i]))
        else printf '  Choose a listed service number.\n'; fi;;
    esac
  done
}
