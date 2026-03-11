#!/usr/bin/env bash
set -euo pipefail

# mac-like-gnome-shortcuts.sh
# Apply a small set of macOS-inspired keyboard shortcuts to GNOME on Ubuntu.
#
# What this changes:
# - Super+Tab      -> switch applications
# - Super+W        -> close window
# - Super+M        -> minimize window
# - Super+Shift+3  -> full screenshot
# - Super+Shift+4  -> screenshot UI / area capture
# - Super+E        -> open Files/Home
#
# Notes:
# - This does NOT swap Ctrl and Super.
# - It is intended for GNOME desktops using gsettings.
# - Existing custom bindings for these actions will be replaced.

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

set_key() {
    local schema="$1"
    local key="$2"
    local value="$3"

    log "Setting ${schema} ${key} -> ${value}"
    gsettings set "$schema" "$key" "$value"
}

get_key() {
    local schema="$1"
    local key="$2"
    gsettings get "$schema" "$key"
}

print_summary() {
    cat <<'EOF'

Applied shortcuts:
  Super+Tab       switch applications
  Super+W         close window
  Super+M         minimize window
  Super+Shift+3   full screenshot
  Super+Shift+4   screenshot UI
  Super+E         open Files/Home

Current values:
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

    log "Applying mac-like GNOME shortcuts..."
    log

    set_key org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
    set_key org.gnome.desktop.wm.keybindings close "['<Super>w']"
    set_key org.gnome.desktop.wm.keybindings minimize "['<Super>m']"

    set_key org.gnome.shell.keybindings screenshot "['<Shift><Super>3']"
    set_key org.gnome.shell.keybindings show-screenshot-ui "['<Shift><Super>4']"

    set_key org.gnome.settings-daemon.plugins.media-keys home "['<Super>e']"

    print_summary

    cat <<EOF

Done.

To restore GNOME defaults later, run:
  ./restore-gnome-shortcuts-defaults.sh

Tip:
  Make this executable with:
    chmod +x "$SCRIPT_NAME"
EOF
}

main "$@"
