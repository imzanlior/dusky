#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Waybar Manager - Unified Edition v4.4.1 (Stable)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
# Description: High-performance TUI for Waybar theme management.
# Features:
#   - FIXED: "M: unbound variable" crash (removed integer flag from string var).
#   - FIXED: CPU spikes during scroll (Zero-fork debounce).
#   - FIXED: Bounding box misalignment on selected items.
#   - FIXED: Atomic file writes (prevents config corruption).
#   - Live position toggling (Spacebar).
#   - Mouse support (click, scroll).
# -----------------------------------------------------------------------------

set -euo pipefail

# Force standard C locale for numeric operations.
export LC_NUMERIC=C

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

readonly CONFIG_ROOT="${HOME}/.config/waybar"
readonly APP_TITLE="Dusky Waybar Manager"
readonly APP_VERSION="v4.4.1"

readonly -a UWSM_CMD=(uwsm-app -- waybar)

declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_WIDTH=76
declare -ri ITEM_COL_WIDTH=48
declare -ri DEBOUNCE_MS=150

# =============================================================================
# ▲ END OF CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _hbuf
printf -v _hbuf '%*s' "$BOX_WIDTH" ''
readonly H_LINE="${_hbuf// /─}"
unset _hbuf

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare ORIGINAL_STTY=""

declare -a THEME_DIRS=()
declare -a THEME_NAMES=()
declare -a THEME_POSITIONS=()

declare -i PREVIEW_PID=0
declare -i FINALIZED=0
declare ORIG_CONFIG=""
declare ORIG_STYLE=""

# Debounce State
declare LAST_INPUT_TIME="0"
declare -i PREVIEW_DIRTY=0
declare -i PENDING_IDX=-1

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

log_info() {
    printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$1"
}

log_ok() {
    printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

# Zero-fork millisecond timestamp using Bash 5.0+ EPOCHREALTIME.
get_time_ms() {
    local -n _out_ms=$1
    local raw="${EPOCHREALTIME}"
    local seconds="${raw%%.*}"
    local fractional="${raw#*.}"
    # EPOCHREALTIME gives 6 decimal places; take first 3 for milliseconds.
    fractional="${fractional:0:3}"
    _out_ms="${seconds}${fractional}"
}

kill_waybar() {
    pkill -x waybar 2>/dev/null || :
    local -i i
    for (( i = 0; i < 5; i++ )); do
        pgrep -x waybar &>/dev/null || return 0
        sleep 0.1
    done
    pkill -9 -x waybar 2>/dev/null || :
    sleep 0.1
    return 0
}

force_clean_locks() {
    local lockfile="/run/user/${UID}/uwsm-app.lock"
    if [[ -f "$lockfile" ]]; then
        rm -f "$lockfile"
    fi
    return 0
}

cleanup() {
    local rc=$?
    # Always restore terminal state first.
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"

    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n'

    if (( FINALIZED )); then
        exit "$rc"
    fi

    # Cancelled: kill preview, restore original symlinks.
    if (( PREVIEW_PID > 0 )); then
        kill "$PREVIEW_PID" 2>/dev/null || :
        wait "$PREVIEW_PID" 2>/dev/null || :
    fi

    if [[ -n "$ORIG_CONFIG" ]]; then
        rm -f "${CONFIG_ROOT}/config.jsonc" "${CONFIG_ROOT}/style.css"
        ln -snf "$ORIG_CONFIG" "${CONFIG_ROOT}/config.jsonc"
        [[ -n "$ORIG_STYLE" ]] && ln -snf "$ORIG_STYLE" "${CONFIG_ROOT}/style.css"

        force_clean_locks
        kill_waybar
        "${UWSM_CMD[@]}" &>/dev/null & disown
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Core Logic ---

scan_themes() {
    local dir
    shopt -s nullglob
    local -a candidates=("${CONFIG_ROOT}"/*/config.jsonc)
    shopt -u nullglob

    THEME_DIRS=()
    THEME_NAMES=()

    for dir in "${candidates[@]}"; do
        dir="${dir%/config.jsonc}"
        THEME_DIRS+=("$dir")
        THEME_NAMES+=("${dir##*/}")
    done

    if (( ${#THEME_NAMES[@]} == 0 )); then
        log_err "No valid theme directories found in ${CONFIG_ROOT}."
        exit 1
    fi
}

find_current_index() {
    local -n _out=$1
    _out=-1
    local cfg="${CONFIG_ROOT}/config.jsonc"
    [[ -e "$cfg" ]] || return 0

    local real_path
    real_path=$(readlink -f "$cfg" 2>/dev/null) || return 0
    local current_dir="${real_path%/*}"

    local -i i
    local resolved
    for (( i = 0; i < ${#THEME_DIRS[@]}; i++ )); do
        resolved=$(readlink -f "${THEME_DIRS[i]}") || continue
        if [[ "$resolved" == "$current_dir" ]]; then
            _out=$i
            return 0
        fi
    done
}

# Reads the "position" field from a theme's config.jsonc via nameref.
get_theme_position() {
    local -n _pos_out=$1
    local idx=$2
    local config_file="${THEME_DIRS[idx]}/config.jsonc"

    if [[ ! -r "$config_file" ]]; then
        _pos_out="UNK"
        return 0
    fi

    local content
    content=$(<"$config_file")
    if [[ $content =~ \"position\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then
        _pos_out="${BASH_REMATCH[1]}"
    else
        _pos_out="UNK"
    fi
}

refresh_positions() {
    THEME_POSITIONS=()
    local -i i
    local pos
    for (( i = 0; i < ${#THEME_NAMES[@]}; i++ )); do
        get_theme_position pos "$i"
        THEME_POSITIONS+=("$pos")
    done
}

toggle_position() {
    local -i idx=$1
    local config_file="${THEME_DIRS[idx]}/config.jsonc"
    [[ -w "$config_file" ]] || return 1

    local current_pos="${THEME_POSITIONS[idx]}"
    local target_pos

    case "$current_pos" in
        top)    target_pos="bottom" ;;
        bottom) target_pos="top" ;;
        left)   target_pos="right" ;;
        right)  target_pos="left" ;;
        *)      target_pos="top" ;;
    esac

    # Atomic write: sed to temp file, then mv to replace original.
    local tmpfile
    tmpfile=$(mktemp "${config_file}.XXXXXX")
    
    if ! sed -E "s/(\"position\"[[:space:]]*:[[:space:]]*)\"[^\"]+\"/\1\"${target_pos}\"/" \
         "$config_file" > "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi
    mv -f "$tmpfile" "$config_file"

    THEME_POSITIONS[idx]="$target_pos"
    queue_preview "$idx"
}

apply_symlinks() {
    local dir="$1"
    rm -f "${CONFIG_ROOT}/config.jsonc" "${CONFIG_ROOT}/style.css"
    ln -snf "${dir}/config.jsonc" "${CONFIG_ROOT}/config.jsonc"
    if [[ -f "${dir}/style.css" ]]; then
        ln -snf "${dir}/style.css" "${CONFIG_ROOT}/style.css"
    fi
}

# --- Debounced Preview Engine ---

queue_preview() {
    local -i idx=$1
    PENDING_IDX=$idx
    PREVIEW_DIRTY=1
    get_time_ms LAST_INPUT_TIME
}

commit_preview() {
    local -i idx=$PENDING_IDX
    (( idx < 0 || idx >= ${#THEME_NAMES[@]} )) && return 0

    local dir="${THEME_DIRS[idx]}"

    if (( PREVIEW_PID > 0 )); then
        kill "$PREVIEW_PID" 2>/dev/null || :
        wait "$PREVIEW_PID" 2>/dev/null || :
        PREVIEW_PID=0
    fi

    force_clean_locks
    apply_symlinks "$dir"
    kill_waybar

    setsid "${UWSM_CMD[@]}" &>/dev/null &
    PREVIEW_PID=$!
    PREVIEW_DIRTY=0
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad="" inner_line=""
    local -i i count=${#THEME_NAMES[@]}
    local -i vis_start vis_end
    local -i vis_len left_pad right_pad
    local item p_val p_str padded_name pos_tag status
    local -i fill rows_rendered p_len
    local position_info msg

    # Header
    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    vis_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_WIDTH - vis_len - left_pad ))
    printf -v pad '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad '%*s' "$right_pad" ''
    buf+="${pad}│${C_RESET}"$'\n'
    buf+="${C_MAGENTA}├${H_LINE}┤${C_RESET}"$'\n'

    # Scroll Math
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    (( max_scroll < 0 )) && max_scroll=0
    (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll

    vis_start=$SCROLL_OFFSET
    vis_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( vis_end > count )) && vis_end=$count

    # Scroll Indicator (top)
    if (( SCROLL_OFFSET > 0 )); then
        printf -v inner_line "    ▲ (more above)%*s" "$(( BOX_WIDTH - 18 ))" ""
        buf+="${C_MAGENTA}│${C_GREY}${inner_line}${C_MAGENTA}│${C_RESET}"$'\n'
    else
        printf -v inner_line '%*s' "$BOX_WIDTH" ''
        buf+="${C_MAGENTA}│${inner_line}│${C_RESET}"$'\n'
    fi

    # Render List
    # Layout Fix:
    # Selected Row Prefix: " ➤ " (3 chars)
    # Normal Row Prefix:   "    " (4 chars)
    # We define fixed widths for the content before the padding starts.
    local -ri SEL_FIXED_WIDTH=$(( 3 + 5 + 1 + ITEM_COL_WIDTH + 1 + 8 ))
    local -ri NORM_FIXED_WIDTH=$(( 4 + 5 + 1 + ITEM_COL_WIDTH ))

    for (( i = vis_start; i < vis_end; i++ )); do
        item="${THEME_NAMES[i]}"
        if (( ${#item} > ITEM_COL_WIDTH )); then
            item="${item:0:$((ITEM_COL_WIDTH - 1))}…"
        fi

        p_val="${THEME_POSITIONS[i]}"
        case "$p_val" in
            top)    p_str="[TOP]" ;;
            bottom) p_str="[BOT]" ;;
            left)   p_str="[LFT]" ;;
            right)  p_str="[RGT]" ;;
            *)      p_str="[UNK]" ;;
        esac

        printf -v padded_name "%-${ITEM_COL_WIDTH}s" "$item"

        if (( i == SELECTED_ROW )); then
            if [[ "$p_val" == "UNK" ]]; then
                pos_tag="${C_GREY}${p_str}${C_RESET}"
            else
                pos_tag="${C_YELLOW}${p_str}${C_RESET}"
            fi

            if (( PREVIEW_DIRTY )); then
                status="${C_YELLOW}● Wait  ${C_RESET}"
            else
                status="${C_GREEN}● Active${C_RESET}"
            fi

            fill=$(( BOX_WIDTH - SEL_FIXED_WIDTH ))
            (( fill < 0 )) && fill=0
            printf -v pad '%*s' "$fill" ''

            buf+="${C_MAGENTA}│${C_CYAN} ➤ ${C_INVERSE}${pos_tag} ${padded_name}${C_RESET} ${status}${pad}${C_MAGENTA}│${C_RESET}"$'\n'
        else
            pos_tag="${C_GREY}${p_str}${C_RESET}"

            fill=$(( BOX_WIDTH - NORM_FIXED_WIDTH ))
            (( fill < 0 )) && fill=0
            printf -v pad '%*s' "$fill" ''

            buf+="${C_MAGENTA}│    ${pos_tag} ${padded_name}${pad}│${C_RESET}"$'\n'
        fi
    done

    # Fill Empty Rows
    rows_rendered=$(( vis_end - vis_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        printf -v inner_line '%*s' "$BOX_WIDTH" ''
        buf+="${C_MAGENTA}│${inner_line}│${C_RESET}"$'\n'
    done

    # Footer Indicators
    if (( count > MAX_DISPLAY_ROWS )); then
        position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        p_len=${#position_info}
        if (( vis_end < count )); then
            msg="    ▼ (more below) "
            fill=$(( BOX_WIDTH - ${#msg} - p_len ))
            (( fill < 0 )) && fill=0
            printf -v pad '%*s' "$fill" ''
            buf+="${C_MAGENTA}│${C_GREY}${msg}${pad}${position_info}${C_MAGENTA}│${C_RESET}"$'\n'
        else
            fill=$(( BOX_WIDTH - p_len - 1 ))
            (( fill < 0 )) && fill=0
            printf -v pad '%*s' "$fill" ''
            buf+="${C_MAGENTA}│${C_GREY}${pad}${position_info} ${C_MAGENTA}│${C_RESET}"$'\n'
        fi
    else
        printf -v inner_line '%*s' "$BOX_WIDTH" ''
        buf+="${C_MAGENTA}│${inner_line}│${C_RESET}"$'\n'
    fi

    # Footer Border
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # Controls
    buf+="${C_CYAN} [Space] Toggle Position   [↑/↓/PgUp/PgDn] Navigate   [Enter] Apply${C_RESET}"$'\n'
    buf+="${C_CYAN} [Esc/q] Cancel & Revert   Config: ${C_WHITE}${CONFIG_ROOT}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -i count=${#THEME_NAMES[@]}
    (( count == 0 )) && return 0

    SELECTED_ROW=$(( SELECTED_ROW + dir ))

    # Wrap around
    if (( SELECTED_ROW < 0 )); then
        SELECTED_ROW=$(( count - 1 ))
    elif (( SELECTED_ROW >= count )); then
        SELECTED_ROW=0
    fi

    queue_preview "$SELECTED_ROW"
    return 0
}

handle_mouse() {
    local input=$1
    # CRITICAL FIX: 'type' MUST NOT be declared as integer (-i), 
    # otherwise assigning characters like "M" causes a crash.
    local -i button y
    local type

    # Input arrives as: [<button;x;y[Mm]
    # Strip the leading '[' to simplify parsing.
    local body="${input#\[}"

    local regex='^<([0-9]+);([0-9]+);([0-9]+)([Mm])$'
    if [[ $body =~ $regex ]]; then
        button=${BASH_REMATCH[1]}
        # x=${BASH_REMATCH[2]}  # unused
        y=${BASH_REMATCH[3]}
        type="${BASH_REMATCH[4]}"

        # Scroll wheel
        if (( button == 64 )); then navigate -1; return 0; fi
        if (( button == 65 )); then navigate  1; return 0; fi

        # Only process press events, not release
        [[ "$type" != "M" ]] && return 0

        # Item rows start at line 5 (Header=3 lines, Top Scroll Indicator=1 line, 1-indexed terminal)
        local -i item_row_start=5

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            local -i count=${#THEME_NAMES[@]}
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
                queue_preview "$SELECTED_ROW"
            fi
        fi
    fi
    return 0
}

# --- Main ---

main() {
    local -i opt_toggle=0 opt_back=0

    while (( $# )); do
        case "$1" in
            --toggle)      opt_toggle=1 ;;
            --back_toggle) opt_back=1 ;;
            -h|--help)
                printf 'Usage: %s [--toggle | --back_toggle]\n' "${0##*/}"
                exit 0
                ;;
            *)  ;;
        esac
        shift
    done

    # Verify Bash 5.0+ for EPOCHREALTIME
    if [[ -z "${EPOCHREALTIME:-}" ]]; then
        log_err "Bash 5.0+ required (EPOCHREALTIME not available)."
        exit 1
    fi

    # Dependencies Check
    local dep
    for dep in waybar uwsm-app stty sed setsid; do
        if ! command -v "$dep" &>/dev/null; then
            log_err "Required dependency not found: ${dep}"
            exit 1
        fi
    done
    [[ -d "$CONFIG_ROOT" ]] || { log_err "Directory ${CONFIG_ROOT} missing."; exit 1; }

    scan_themes
    refresh_positions

    local -i total=${#THEME_NAMES[@]}
    local -i cur_idx
    find_current_index cur_idx

    # ── TOGGLE MODE (No TUI) ──
    if (( opt_toggle || opt_back )); then
        local -i target_idx
        local cur_name="(unknown)"
        (( cur_idx >= 0 )) && cur_name="${THEME_NAMES[cur_idx]}"

        if (( cur_idx < 0 )); then
            target_idx=0
        elif (( opt_toggle )); then
            target_idx=$(( (cur_idx + 1) % total ))
        else
            target_idx=$(( (cur_idx - 1 + total) % total ))
        fi

        log_info "Switching: '${cur_name}' -> '${THEME_NAMES[target_idx]}'"
        apply_symlinks "${THEME_DIRS[target_idx]}"

        force_clean_locks
        kill_waybar
        "${UWSM_CMD[@]}" &>/dev/null & disown
        sleep 0.3
        log_ok "Applied: ${THEME_NAMES[target_idx]}"
        FINALIZED=1
        exit 0
    fi

    # ── TUI MODE ──
    # Save original state for revert on cancel.
    [[ -L "${CONFIG_ROOT}/config.jsonc" ]] && ORIG_CONFIG=$(readlink "${CONFIG_ROOT}/config.jsonc")
    [[ -L "${CONFIG_ROOT}/style.css" ]]    && ORIG_STYLE=$(readlink "${CONFIG_ROOT}/style.css")

    (( cur_idx >= 0 )) && SELECTED_ROW=$cur_idx

    force_clean_locks

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null || :

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    # Initial preview
    queue_preview "$SELECTED_ROW"
    commit_preview

    local key seq char
    local current_time_ms

    while true; do
        draw_ui

        # Debounce Logic
        if (( PREVIEW_DIRTY )); then
            get_time_ms current_time_ms
            if (( current_time_ms - LAST_INPUT_TIME > DEBOUNCE_MS )); then
                commit_preview
                continue
            fi
            # Non-blocking short read during active debounce wait
            IFS= read -rsn1 -t 0.05 key || true
        else
            # Blocking read when idle
            IFS= read -rsn1 key || true
        fi

        if [[ -z "${key:-}" ]]; then
            continue
        fi

        if [[ "$key" == $'\x1b' ]]; then
            seq=""
            # Hardcoded small timeout for sequence safety
            while IFS= read -rsn1 -t 0.02 char; do
                seq+="$char"
            done

            # Bare ESC (no sequence following) -> quit
            if [[ -z "$seq" ]]; then
                break
            fi

            case "$seq" in
                '[A'|'OA')    navigate -1  ;;
                '[B'|'OB')    navigate  1  ;;
                '[5~')        navigate -10 ;;  # Page Up
                '[6~')        navigate  10 ;;  # Page Down
                '['*'<'*)     handle_mouse "$seq" ;;
                *)            ;;  # Unknown sequence, ignore
            esac
        else
            case "$key" in
                k|K)          navigate -1 ;;
                j|J)          navigate  1 ;;
                ' ')
                    if (( ${#THEME_NAMES[@]} > 0 )); then
                        toggle_position "$SELECTED_ROW"
                    fi
                    ;;
                '')           # Enter key
                    FINALIZED=1
                    break
                    ;;
                q|Q|$'\x03')  break ;;  # q or Ctrl-C
                *)            ;;
            esac
        fi
    done

    if (( FINALIZED )); then
        log_ok "Applied: ${THEME_NAMES[SELECTED_ROW]}"
    fi
    # Exit handled by trap cleanup
}

main "$@"
