#!/usr/bin/env bash
set -euo pipefail

# restore-gnome-shortcuts-defaults.sh
# Restore GNOME defaults for the shortcuts changed by mac-like-gnome-shortcuts.sh

SCRIPT_NAME="$(basename "$0")"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command not found: $1" >&2
        exit 1
    }
}

log() {
    printf '%s\n' "$*"
}

reset_key() {
    local schema="$1"
    local key="$2"

    log "Resetting ${schema} ${key}"
    gsettings reset "$schema" "$key"
}

get_key() {
    local schema="$1"
    local key="$2"
    gsettings get "$schema" "$key"
}

print_summary() {
    cat <<'EOF'

Current values after reset:
EOF

    printf '  switch-applications: %s\n' "$(get_key org.gnome.desktop.wm.keybindings switch-applications)"
    printf '  close:               %s\n' "$(get_key org.gnome.desktop.wm.keybindings close)"
    printf '  minimize:            %s\n' "$(get_key org.gnome.desktop.wm.keybindings minimize)"
    printf '  screenshot:          %s\n' "$(get_key org.gnome.shell.keybindings screenshot)"
    printf '  show-screenshot-ui:  %s\n' "$(get_key org.gnome.shell.keybindings show-screenshot-ui)"
    printf '  home:                %s\n' "$(get_key org.gnome.settings-daemon.plugins.media-keys home)"
}

main() {
    require_cmd gsettings

    log "Restoring GNOME defaults for modified shortcuts..."
    log

    reset_key org.gnome.desktop.wm.keybindings switch-applications
    reset_key org.gnome.desktop.wm.keybindings close
    reset_key org.gnome.desktop.wm.keybindings minimize

    reset_key org.gnome.shell.keybindings screenshot
    reset_key org.gnome.shell.keybindings show-screenshot-ui

    reset_key org.gnome.settings-daemon.plugins.media-keys home

    print_summary

    cat <<EOF

Done.

Tip:
  Make this executable with:
    chmod +x "$SCRIPT_NAME"
EOF
}

main "$@"
