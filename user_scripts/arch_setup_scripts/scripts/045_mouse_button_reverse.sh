#!/usr/bin/env bash
# ==============================================================================
# Script: mouse_button_reverse.sh (v2.1)
# Purpose: Toggles mouse handedness in Hyprland (Dusky TUI Enhanced)
# Usage:   ./mouse_button_reverse.sh [ --left | --right ]
# ==============================================================================

set -euo pipefail

# --- Dusky TUI Standards ---
export LC_NUMERIC=C

# Colors
readonly C_RESET=$'\033[0m'
readonly C_GREEN=$'\033[1;32m'
readonly C_CYAN=$'\033[1;36m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_RED=$'\033[1;31m'

# --- Configuration ---
readonly CONFIG_FILE="${HOME}/.config/hypr/source/input.conf"

# --- Cleanup Trap ---
cleanup() {
    [[ -f "${TEMP_FILE:-}" ]] && rm -f "$TEMP_FILE" || true
}
trap cleanup EXIT

# --- Helper Functions ---
log_success() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

# --- Core Logic ---

main() {
    # 1. Validation
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    local target_val=""
    local interactive_mode=true
    local action_msg=""

    # 2. Argument Parsing (Flags)
    # Allows bypassing the interactive prompt for keybinds/scripts
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --left)
                target_val="true"
                interactive_mode=false
                action_msg="Setting Left-Handed Mode (Force)"
                ;;
            --right)
                target_val="false"
                interactive_mode=false
                action_msg="Setting Right-Handed Mode (Force)"
                ;;
            *)
                log_err "Unknown flag: $1"
                printf "Usage: %s [ --left | --right ]\n" "$0"
                exit 1
                ;;
        esac
    fi

    # 3. Detect Current State (if needed for toggle)
    if [[ "$interactive_mode" == "true" ]]; then
        local current_state
        
        # Robust AWK parser to find the real value inside correct block
        current_state=$(awk '
            BEGIN { depth = 0; in_input = 0; found_val = "" }
            { clean = $0; sub(/#.*/, "", clean) }
            clean ~ /^[[:space:]]*input[[:space:]]*\{/ { if (depth == 0) in_input = 1 }
            {
                n_open = gsub(/{/, "{", clean); n_close = gsub(/}/, "}", clean)
                if (in_input && depth >= 0 && clean ~ /^[[:space:]]*left_handed[[:space:]]*=/) {
                    split(clean, parts, "="); val = parts[2]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    found_val = val
                }
                depth += n_open - n_close
                if (depth <= 0) { in_input = 0; depth = 0 }
            }
            END { print found_val }
        ' "$CONFIG_FILE")

        [[ -z "$current_state" ]] && current_state="false"

        if [[ "$current_state" == "true" ]]; then
            printf "\n  Current: %sLeft-Handed%s\n" "$C_GREEN" "$C_RESET"
            printf "  Switch to %sRight-Handed%s? [Y/n]: " "$C_CYAN" "$C_RESET"
            target_val="false"
        else
            printf "\n  Current: %sRight-Handed%s\n" "$C_CYAN" "$C_RESET"
            printf "  Switch to %sLeft-Handed%s? [Y/n]: " "$C_GREEN" "$C_RESET"
            target_val="true"
        fi

        read -r -n 1 user_input < /dev/tty
        printf "\n"

        if [[ ! "$user_input" =~ ^[Yy]$ ]] && [[ -n "$user_input" ]]; then
            printf "  No changes made.\n"
            exit 0
        fi
    else
        printf "  %s...\n" "$action_msg"
    fi

    # 4. Apply Changes (Atomic & Safe)
    TEMP_FILE=$(mktemp)
    
    awk -v new_val="$target_val" '
    BEGIN { depth = 0; in_input = 0 }
    { line = $0; clean = $0; sub(/#.*/, "", clean) }
    
    # Enter input block
    clean ~ /^[[:space:]]*input[[:space:]]*\{/ { if (depth == 0) in_input = 1 }

    {
        n_open = gsub(/{/, "{", clean); n_close = gsub(/}/, "}", clean)

        # Only replace if inside input block (and not nested deeper in something like touchpad{})
        # NOTE: If "touchpad" block support is needed, depth check can be adjusted.
        if (in_input && depth >= 0 && clean ~ /^[[:space:]]*left_handed[[:space:]]*=/) {
            if (match(line, /^([[:space:]]*left_handed[[:space:]]*=[[:space:]]*)[^#[:space:]]+(.*)$/, groups)) {
                line = groups[1] new_val groups[2]
            }
        }

        depth += n_open - n_close
        if (depth <= 0) { in_input = 0; depth = 0 }
        print line
    }
    ' "$CONFIG_FILE" > "$TEMP_FILE"

    if cat "$TEMP_FILE" > "$CONFIG_FILE"; then
        if [[ "$interactive_mode" == "true" ]]; then
            log_success "Configuration updated."
        fi
        
        # Silent reload for flags, verbose for interactive
        if pgrep -x "Hyprland" > /dev/null; then
            if [[ "$interactive_mode" == "true" ]]; then
                printf "  Reloading Hyprland... "
                hyprctl reload > /dev/null 2>&1 && printf "${C_GREEN}Done.${C_RESET}\n" || printf "${C_RED}Failed.${C_RESET}\n"
            else
                hyprctl reload > /dev/null 2>&1
            fi
        fi
    else
        log_err "Failed to write to config file."
        exit 1
    fi
}

main "$@"
