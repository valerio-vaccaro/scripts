#!/bin/bash

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
KIOSK_USER="kiosk"
KIOSK_DIR="/etc/kiosk"
PROFILES_DIR="$KIOSK_DIR/profiles.d"
SWAY_CONF="/etc/sway/kiosk.conf"
START_SCRIPT="/usr/local/bin/kiosk-start.sh"
PROFILE_LOGIN_SCRIPT="/usr/local/bin/kiosk-profile-login.sh"
SERVICE_FILE="/etc/systemd/system/kiosk.service"

usage() {
    cat << EOF
Usage:
  sudo $SCRIPT_NAME
  sudo $SCRIPT_NAME chrome --url <url> [--name <name>] [--theme dark|bitcoin|navy] [--reboot]
  sudo $SCRIPT_NAME app --command <application-or-path> [--name <name>] [--theme dark|bitcoin|navy] [--reboot]
  sudo $SCRIPT_NAME profiles --name <name> [--theme dark|bitcoin|navy] [--reboot]
  sudo $SCRIPT_NAME profile-add --id <id> --label <label> --pin <pin> (--url <url>|--command <command>) [--fail-url <url>|--fail-command <command>]
  sudo $SCRIPT_NAME profile-modify --id <id> [--label <label>] [--pin <pin>] [--url <url>|--command <command>] [--fail-url <url>|--fail-command <command>|--clear-fail]
  sudo $SCRIPT_NAME profile-list
  sudo $SCRIPT_NAME profile-remove --id <id>
  sudo $SCRIPT_NAME wifi --ssid <ssid> [--password <password>]
  sudo $SCRIPT_NAME name --name <name>
  sudo $SCRIPT_NAME status
  sudo $SCRIPT_NAME revert [--reboot]

The interactive mode uses whiptail/dialog when available and falls back to a text menu.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_value() {
    local option="$1"
    local value="${2:-}"
    [ -n "$value" ] || die "Option '$option' requires a value."
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "Please run this script using sudo or as root."
    fi
}

ui_backend() {
    if [ ! -t 0 ] || [ ! -t 2 ]; then
        printf 'text\n'
        return
    fi

    if command -v whiptail >/dev/null 2>&1; then
        printf 'whiptail\n'
    elif command -v dialog >/dev/null 2>&1; then
        printf 'dialog\n'
    else
        printf 'text\n'
    fi
}

ui_msg() {
    local title="$1"
    local text="$2"
    local backend
    backend=$(ui_backend)

    case "$backend" in
        whiptail) whiptail --title "$title" --msgbox "$text" 12 74 ;;
        dialog) dialog --title "$title" --msgbox "$text" 12 74 ;;
        *) printf '\n[%s]\n%b\n\n' "$title" "$text" ;;
    esac
}

ui_yesno() {
    local title="$1"
    local text="$2"
    local backend
    backend=$(ui_backend)

    case "$backend" in
        whiptail) whiptail --title "$title" --yesno "$text" 10 74 ;;
        dialog) dialog --title "$title" --yesno "$text" 10 74 ;;
        *)
            local answer
            read -r -p "$text [y/N]: " answer
            [[ "$answer" =~ ^[Yy]$ ]]
            ;;
    esac
}

ui_input() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    local secret="${4:-no}"
    local backend
    backend=$(ui_backend)

    case "$backend" in
        whiptail)
            if [ "$secret" = "yes" ]; then
                whiptail --title "$title" --passwordbox "$prompt" 10 74 "$default" 3>&1 1>&2 2>&3
            else
                whiptail --title "$title" --inputbox "$prompt" 10 74 "$default" 3>&1 1>&2 2>&3
            fi
            ;;
        dialog)
            if [ "$secret" = "yes" ]; then
                dialog --title "$title" --passwordbox "$prompt" 10 74 "$default" 3>&1 1>&2 2>&3
            else
                dialog --title "$title" --inputbox "$prompt" 10 74 "$default" 3>&1 1>&2 2>&3
            fi
            ;;
        *)
            local value
            if [ "$secret" = "yes" ]; then
                read -r -s -p "$prompt: " value
                printf '\n' >&2
            else
                read -r -p "$prompt [$default]: " value
            fi
            printf '%s\n' "${value:-$default}"
            ;;
    esac
}

ui_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    local backend
    backend=$(ui_backend)

    case "$backend" in
        whiptail) whiptail --title "$title" --menu "$prompt" 18 78 9 "$@" 3>&1 1>&2 2>&3 ;;
        dialog) dialog --title "$title" --menu "$prompt" 18 78 9 "$@" 3>&1 1>&2 2>&3 ;;
        *)
            local tags=()
            local labels=()
            local i=1
            local choice
            printf '\n%s\n%s\n' "$title" "$prompt" >&2
            while [ "$#" -gt 0 ]; do
                tags+=("$1")
                labels+=("$2")
                printf '  %d) %s - %s\n' "$i" "$1" "$2" >&2
                shift 2
                i=$((i + 1))
            done
            read -r -p "Choose: " choice
            [[ "$choice" =~ ^[0-9]+$ ]] || return 1
            [ "$choice" -ge 1 ] && [ "$choice" -le "${#tags[@]}" ] || return 1
            printf '%s\n' "${tags[$((choice - 1))]}"
            ;;
    esac
}

theme_colors() {
    case "${1:-dark}" in
        dark) printf '#111111 #ffffff\n' ;;
        bitcoin) printf '#f7931a #ffffff\n' ;;
        navy) printf '#001f3f #ffffff\n' ;;
        *) die "Unknown theme '$1'. Use dark, bitcoin or navy." ;;
    esac
}

validate_theme() {
    case "${1:-dark}" in
        dark|bitcoin|navy) ;;
        *) die "Unknown theme '$1'. Use dark, bitcoin or navy." ;;
    esac
}

default_name() {
    /usr/bin/hostname
}

validate_profile_id() {
    local profile_id="$1"
    [[ "$profile_id" =~ ^[A-Za-z0-9_-]+$ ]] || die "Profile id must contain only letters, numbers, underscore and dash."
}

profile_file_path() {
    printf '%s/%s.conf\n' "$PROFILES_DIR" "$1"
}

hash_pin() {
    local pin="$1"
    /usr/bin/printf '%s' "$pin" | /usr/bin/sha256sum | /usr/bin/awk '{ print $1 }'
}

load_profile_fields() {
    local profile_file="$1"
    PROFILE_ID=""
    LABEL=""
    TYPE=""
    URL=""
    COMMAND=""
    PIN_HASH=""
    FAIL_TYPE=""
    FAIL_TARGET=""
    # Profile files are created by this script and sourced as shell fragments.
    # shellcheck disable=SC1090
    . "$profile_file"
}

write_profile_file() {
    local profile_id="$1"
    local label="$2"
    local pin_hash="$3"
    local profile_type="$4"
    local target="$5"
    local fail_type="${6:-}"
    local fail_target="${7:-}"
    local profile_file

    profile_file=$(profile_file_path "$profile_id")
    /usr/bin/install -d -m 0755 "$PROFILES_DIR"

    case "$profile_type" in
        chrome)
            case "$fail_type" in
                ""|chrome|command) ;;
                *) die "Unknown fallback type '$fail_type'." ;;
            esac
            /usr/bin/cat > "$profile_file" << EOF
PROFILE_ID=$(printf '%q' "$profile_id")
LABEL=$(printf '%q' "$label")
TYPE=chrome
URL=$(printf '%q' "$target")
COMMAND=
PIN_HASH=$(printf '%q' "$pin_hash")
FAIL_TYPE=$(printf '%q' "$fail_type")
FAIL_TARGET=$(printf '%q' "$fail_target")
EOF
            ;;
        command)
            case "$fail_type" in
                ""|chrome|command) ;;
                *) die "Unknown fallback type '$fail_type'." ;;
            esac
            /usr/bin/cat > "$profile_file" << EOF
PROFILE_ID=$(printf '%q' "$profile_id")
LABEL=$(printf '%q' "$label")
TYPE=command
URL=
COMMAND=$(printf '%q' "$target")
PIN_HASH=$(printf '%q' "$pin_hash")
FAIL_TYPE=$(printf '%q' "$fail_type")
FAIL_TARGET=$(printf '%q' "$fail_target")
EOF
            ;;
        *)
            die "Unknown profile type '$profile_type'."
            ;;
    esac

    /usr/bin/chown root:root "$profile_file"
    /usr/bin/chmod 0644 "$profile_file"
}

resolve_app_command() {
    local requested="$1"
    local app_path

    if [[ "$requested" == */* ]]; then
        app_path=$(/usr/bin/readlink -f -- "$requested" || true)
    else
        app_path=$(type -P -- "$requested" || true)
    fi

    [ -n "$app_path" ] || die "Application '$requested' was not found."
    [ -f "$app_path" ] || die "Application '$requested' does not exist."
    [ -x "$app_path" ] || die "Application '$requested' is not executable."
    printf '%s\n' "$app_path"
}

install_base_packages() {
    local include_chromium="$1"
    local packages=(
        sway
        waybar
        foot
        whiptail
        xwayland
        dbus-daemon
        network-manager
        libpam-systemd
        firmware-linux
        mesa-va-drivers
        mesa-vdpau-drivers
    )

    if [ "$include_chromium" = "yes" ]; then
        packages+=(chromium)
    fi

    echo "Updating package lists and installing kiosk dependencies..."
    /usr/bin/apt update
    /usr/bin/apt install -y --no-install-recommends "${packages[@]}"
}

ensure_kiosk_user() {
    if /usr/bin/id "$KIOSK_USER" >/dev/null 2>&1; then
        echo "User '$KIOSK_USER' already exists."
    else
        echo "Creating user '$KIOSK_USER'..."
        /usr/sbin/useradd -m -s /bin/bash "$KIOSK_USER"
    fi

    echo "Assigning hardware permissions to '$KIOSK_USER'..."
    /usr/sbin/usermod -aG video,input,render,tty "$KIOSK_USER"
}

write_common_files() {
    local kiosk_name="$1"
    local bar_background="$2"
    local bar_color="$3"
    local show_logout="${4:-no}"
    local modules_left_json='["custom/name"]'
    local logout_module_json=''

    /usr/bin/install -d -m 0755 "$KIOSK_DIR" /etc/sway
    /usr/bin/printf '%s\n' "$kiosk_name" > "$KIOSK_DIR/name"

    /usr/bin/cat > "$KIOSK_DIR/ip-address.sh" << 'EOF'
#!/bin/bash

IP=$(/usr/bin/hostname -I 2>/dev/null | /usr/bin/awk '{ print $1 }')
if [ -z "$IP" ]; then
    IP="offline"
fi

/usr/bin/printf 'IP %s\n' "$IP"
EOF
    /usr/bin/chmod +x "$KIOSK_DIR/ip-address.sh"

    /usr/bin/cat > "$KIOSK_DIR/wifi-status.sh" << 'EOF'
#!/bin/bash

if ! command -v nmcli >/dev/null 2>&1; then
    /usr/bin/printf 'WiFi unavailable\n'
    exit 0
fi

STATUS=$(/usr/bin/nmcli -t -f WIFI general 2>/dev/null | /usr/bin/head -n 1)
if [ "$STATUS" != "enabled" ]; then
    /usr/bin/printf 'WiFi off\n'
    exit 0
fi

ACTIVE=$(/usr/bin/nmcli -t -f ACTIVE,SSID,SIGNAL device wifi 2>/dev/null | /usr/bin/awk -F: '$1 == "yes" { print $2 ":" $3; exit }')
if [ -z "$ACTIVE" ]; then
    /usr/bin/printf 'WiFi disconnected\n'
    exit 0
fi

SSID=${ACTIVE%:*}
SIGNAL=${ACTIVE##*:}
/usr/bin/printf 'WiFi %s %s%%\n' "$SSID" "$SIGNAL"
EOF
    /usr/bin/chmod +x "$KIOSK_DIR/wifi-status.sh"

    /usr/bin/cat > "$KIOSK_DIR/logout.sh" << 'EOF'
#!/bin/bash

set -Eeuo pipefail

APP_PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/kiosk-current-app.pid"

if [ ! -s "$APP_PID_FILE" ]; then
    exit 0
fi

APP_PID=$(/usr/bin/sed -n '1p' "$APP_PID_FILE")
case "$APP_PID" in
    ''|*[!0-9-]*)
        exit 1
        ;;
esac

/usr/bin/kill -- "-$APP_PID" 2>/dev/null || /usr/bin/kill "$APP_PID" 2>/dev/null || true
EOF
    /usr/bin/chmod +x "$KIOSK_DIR/logout.sh"

    if [ "$show_logout" = "yes" ]; then
        modules_left_json='["custom/name", "custom/logout"]'
        logout_module_json=$(cat <<'EOF'
, 
    "custom/logout": {
        "exec": "/usr/bin/printf 'Return\\n'",
        "interval": 3600,
        "return-type": "text",
        "tooltip": false,
        "on-click": "/etc/kiosk/logout.sh"
    }
EOF
)
    fi

    /usr/bin/cat > "$SWAY_CONF" << 'EOF'
xwayland enable

output * bg #000000 solid_color
input * {
    tap enabled
}

default_border none
default_floating_border none
gaps inner 0
gaps outer 0
focus_follows_mouse no

for_window [app_id=".*"] border none
for_window [class=".*"] border none

exec /usr/bin/waybar --config /etc/kiosk/waybar.json --style /etc/kiosk/waybar.css
exec /usr/local/bin/kiosk-start.sh
EOF

    /usr/bin/cat > "$KIOSK_DIR/waybar.json" << EOF
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "exclusive": true,
    "passthrough": false,
    "modules-left": $modules_left_json,
    "modules-right": ["custom/wifi", "custom/ip", "battery"],
    "custom/name": {
        "exec": "/usr/bin/sed -n '1p' /etc/kiosk/name",
        "interval": 3600,
        "return-type": "text",
        "tooltip": false
    }$logout_module_json,
    "custom/ip": {
        "exec": "/etc/kiosk/ip-address.sh",
        "interval": 10,
        "return-type": "text",
        "tooltip": false
    },
    "custom/wifi": {
        "exec": "/etc/kiosk/wifi-status.sh",
        "interval": 10,
        "return-type": "text",
        "tooltip": false
    },
    "battery": {
        "interval": 10,
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "BAT {capacity}%",
        "format-charging": "AC {capacity}%",
        "format-plugged": "AC {capacity}%",
        "tooltip": false
    }
}
EOF

    /usr/bin/cat > "$KIOSK_DIR/waybar.css" << EOF
* {
    border: none;
    border-radius: 0;
    font-family: sans-serif;
    font-size: 16px;
    min-height: 0;
}

window#waybar {
    background: $bar_background;
    color: $bar_color;
}

#custom-name,
#custom-logout,
#custom-wifi,
#custom-ip,
#battery {
    padding: 0 12px;
}

#custom-logout {
    background: rgba(255, 255, 255, 0.12);
    margin: 4px 0;
}

#battery.warning {
    background: #d97706;
}

#battery.critical {
    background: #b91c1c;
}
EOF
}

write_chrome_start_script() {
    local kiosk_url="$1"
    local quoted_url
    printf -v quoted_url '%q' "$kiosk_url"

    /usr/bin/cat > "$START_SCRIPT" << EOF
#!/bin/bash

export OZONE_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland

TARGET_URL=$quoted_url

exec /usr/bin/chromium \\
    --app="\$TARGET_URL" \\
    --start-maximized \\
    --no-first-run \\
    --noerrdialogs \\
    --password-store=basic \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --enable-features=UseOzonePlatform \\
    --ozone-platform=wayland
EOF
    /usr/bin/chmod +x "$START_SCRIPT"
}

write_app_start_script() {
    local app_path="$1"
    local quoted_app
    printf -v quoted_app '%q' "$app_path"

    /usr/bin/cat > "$START_SCRIPT" << EOF
#!/bin/bash

set -Eeuo pipefail

export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM=wayland
export OZONE_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland
export XDG_SESSION_TYPE=wayland

while true; do
    $quoted_app
    sleep 2
done
EOF
    /usr/bin/chmod +x "$START_SCRIPT"
}

write_profile_login_script() {
    /usr/bin/cat > "$PROFILE_LOGIN_SCRIPT" << 'EOF'
#!/bin/bash

set -Eeuo pipefail

PROFILES_DIR="/etc/kiosk/profiles.d"
KIOSK_NAME_FILE="/etc/kiosk/name"
REQUEST_FILE="${XDG_RUNTIME_DIR:-/tmp}/kiosk-launch-request"

kiosk_title() {
    local title="Kiosk Login"
    if [ -f "$KIOSK_NAME_FILE" ]; then
        title=$(/usr/bin/sed -n '1p' "$KIOSK_NAME_FILE")
    fi
    [ -n "$title" ] || title="Kiosk Login"
    printf '%s\n' "$title"
}

prepare_ui() {
    unset COLUMNS LINES
    stty sane 2>/dev/null || true
}

render_text_header() {
    prepare_ui
    clear 2>/dev/null || true
    printf '\n'
    printf '============================================================\n'
    printf '  %s\n' "$(kiosk_title)"
    printf '============================================================\n'
    printf '\n'
}

ui_backend() {
    if [ ! -t 0 ] || [ ! -t 2 ]; then
        printf 'text\n'
        return
    fi

    if command -v whiptail >/dev/null 2>&1; then
        printf 'whiptail\n'
    elif command -v dialog >/dev/null 2>&1; then
        printf 'dialog\n'
    else
        printf 'text\n'
    fi
}

ui_msg() {
    local title="$1"
    local text="$2"
    local backtitle
    backtitle=$(kiosk_title)
    prepare_ui
    case "$(ui_backend)" in
        whiptail) whiptail --backtitle "$backtitle" --title "$title" --msgbox "$text" 11 78 ;;
        dialog) dialog --backtitle "$backtitle" --title "$title" --msgbox "$text" 11 78 ;;
        *)
            render_text_header
            printf '[%s]\n%b\n\n' "$title" "$text"
            ;;
    esac
}

ui_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    local backtitle
    backtitle=$(kiosk_title)
    prepare_ui
    case "$(ui_backend)" in
        whiptail) whiptail --backtitle "$backtitle" --title "$title" --menu "$prompt" 20 82 11 "$@" 3>&1 1>&2 2>&3 ;;
        dialog) dialog --backtitle "$backtitle" --title "$title" --menu "$prompt" 20 82 11 "$@" 3>&1 1>&2 2>&3 ;;
        *)
            local tags=()
            local choice
            local i=1
            render_text_header >&2
            printf '%s\n%s\n\n' "$title" "$prompt" >&2
            while [ "$#" -gt 0 ]; do
                tags+=("$1")
                printf '  %d) %s - %s\n' "$i" "$1" "$2" >&2
                shift 2
                i=$((i + 1))
            done
            read -r -p "Choose: " choice
            [[ "$choice" =~ ^[0-9]+$ ]] || return 1
            [ "$choice" -ge 1 ] && [ "$choice" -le "${#tags[@]}" ] || return 1
            printf '%s\n' "${tags[$((choice - 1))]}"
            ;;
    esac
}

ui_password() {
    local title="$1"
    local prompt="$2"
    local backtitle
    backtitle=$(kiosk_title)
    prepare_ui
    case "$(ui_backend)" in
        whiptail) whiptail --backtitle "$backtitle" --title "$title" --passwordbox "$prompt" 11 78 3>&1 1>&2 2>&3 ;;
        dialog) dialog --backtitle "$backtitle" --title "$title" --passwordbox "$prompt" 11 78 3>&1 1>&2 2>&3 ;;
        *)
            local value
            render_text_header >&2
            read -r -s -p "$prompt: " value
            printf '\n' >&2
            printf '%s\n' "$value"
            ;;
    esac
}

hash_pin() {
    /usr/bin/printf '%s' "$1" | /usr/bin/sha256sum | /usr/bin/awk '{ print $1 }'
}

load_profile() {
    local path="$1"
    PROFILE_ID=""
    LABEL=""
    TYPE=""
    URL=""
    COMMAND=""
    PIN_HASH=""
    FAIL_TYPE=""
    FAIL_TARGET=""
    # Profile files are root-owned shell fragments created by kiosk.sh.
    # shellcheck disable=SC1090
    . "$path"
}

write_request() {
    local profile_id="$1"
    local launch_kind="$2"
    /usr/bin/cat > "$REQUEST_FILE" << REQUEST_EOF
PROFILE_ID=$(printf '%q' "$profile_id")
LAUNCH_KIND=$(printf '%q' "$launch_kind")
REQUEST_EOF
}

while true; do
    mapfile -t profile_files < <(/usr/bin/find "$PROFILES_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | /usr/bin/sort)
    if [ "${#profile_files[@]}" -eq 0 ]; then
        ui_msg "No Profiles" "No kiosk profiles are configured.\n\nAsk an administrator to add one with:\nsudo ./kiosk.sh profile-add --id staff --label Staff --pin 1234 --url https://example.com"
        sleep 5
        continue
    fi

    menu_items=()
    for profile_file in "${profile_files[@]}"; do
        load_profile "$profile_file"
        [ -n "$PROFILE_ID" ] || continue
        menu_items+=("$PROFILE_ID" "${LABEL:-$PROFILE_ID}")
    done
    if [ "${#menu_items[@]}" -eq 0 ]; then
        ui_msg "No Profiles" "Configured profile files are invalid or empty."
        sleep 5
        continue
    fi

    selected=$(ui_menu "Select Profile" "Choose a profile, then enter its PIN." "${menu_items[@]}") || continue
    selected_file="$PROFILES_DIR/$selected.conf"
    [ -f "$selected_file" ] || continue

    load_profile "$selected_file"
    pin=$(ui_password "Profile PIN" "Enter PIN for ${LABEL:-$PROFILE_ID}") || continue
    if [ "$(hash_pin "$pin")" != "$PIN_HASH" ]; then
        if [ -n "$FAIL_TYPE" ] && [ -n "$FAIL_TARGET" ]; then
            write_request "$PROFILE_ID" fallback
            exit 0
        fi
        continue
    fi

    write_request "$PROFILE_ID" primary
    exit 0
done
EOF
    /usr/bin/chmod +x "$PROFILE_LOGIN_SCRIPT"
}

write_profiles_start_script() {
    /usr/bin/cat > "$START_SCRIPT" << 'EOF'
#!/bin/bash

set -Eeuo pipefail

export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM=wayland
export OZONE_PLATFORM=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland
export XDG_SESSION_TYPE=wayland

PROFILES_DIR="/etc/kiosk/profiles.d"
REQUEST_FILE="${XDG_RUNTIME_DIR:-/tmp}/kiosk-launch-request"
APP_PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/kiosk-current-app.pid"

launch_target() {
    local launch_type="$1"
    local launch_target="$2"

    case "$launch_type" in
        chrome)
            setsid /usr/bin/chromium \
                --app="$launch_target" \
                --start-maximized \
                --no-first-run \
                --noerrdialogs \
                --password-store=basic \
                --disable-infobars \
                --disable-session-crashed-bubble \
                --enable-features=UseOzonePlatform \
                --ozone-platform=wayland &
            ;;
        command)
            setsid /bin/bash -lc "$launch_target" &
            ;;
        *)
            return 1
            ;;
    esac

    app_pid=$!
    /usr/bin/printf '%s\n' "$app_pid" > "$APP_PID_FILE"
    wait "$app_pid" || true
    /usr/bin/rm -f "$APP_PID_FILE"
}

launch_profile() {
    local profile_id="$1"
    local launch_kind="${2:-primary}"
    local profile_file="$PROFILES_DIR/$profile_id.conf"

    [ -f "$profile_file" ] || return 1

    PROFILE_ID=""
    LABEL=""
    TYPE=""
    URL=""
    COMMAND=""
    PIN_HASH=""
    FAIL_TYPE=""
    FAIL_TARGET=""
    # Profile files are root-owned shell fragments created by kiosk.sh.
    # shellcheck disable=SC1090
    . "$profile_file"

    case "$launch_kind" in
        primary) launch_target "$TYPE" "${URL:-$COMMAND}" ;;
        fallback) launch_target "$FAIL_TYPE" "$FAIL_TARGET" ;;
        *) return 1 ;;
    esac
}

while true; do
    /usr/bin/rm -f "$REQUEST_FILE" "$APP_PID_FILE"
    sleep 0.3
    /usr/bin/foot \
        --fullscreen \
        --title "Kiosk Login" \
        --app-id "kiosk-login" \
        -o font=monospace:size=18 \
        -o colors.background=111111 \
        -o colors.foreground=eeeeee \
        -o colors.regular0=111111 \
        -o colors.regular7=eeeeee \
        /usr/local/bin/kiosk-profile-login.sh || sleep 2

    if [ -s "$REQUEST_FILE" ]; then
        PROFILE_ID=""
        LAUNCH_KIND=""
        # shellcheck disable=SC1090
        . "$REQUEST_FILE"
        [ -n "$PROFILE_ID" ] || continue
        [ -n "$LAUNCH_KIND" ] || LAUNCH_KIND="primary"
        launch_profile "$PROFILE_ID" "$LAUNCH_KIND" || sleep 2
    fi
done
EOF
    /usr/bin/chmod +x "$START_SCRIPT"
}

write_service() {
    local description="$1"
    local kiosk_uid
    kiosk_uid=$(/usr/bin/id -u "$KIOSK_USER")

    /usr/bin/cat > "$SERVICE_FILE" << EOF
[Unit]
Description=$description
After=systemd-user-sessions.service systemd-logind.service network.target
Conflicts=display-manager.service getty@tty1.service

[Service]
Type=simple
User=$KIOSK_USER
PAMName=login
WorkingDirectory=/home/$KIOSK_USER
Environment=XDG_RUNTIME_DIR=/run/user/$kiosk_uid
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SEAT=seat0
Environment=XDG_VTNR=1
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-force
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpLevel=user

ExecStart=/usr/bin/dbus-run-session -- /usr/bin/sway --config /etc/sway/kiosk.conf

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

enable_kiosk_service() {
    echo "Enabling NetworkManager and kiosk service..."
    /usr/bin/systemctl enable --now NetworkManager.service
    /usr/bin/systemctl set-default multi-user.target
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl enable kiosk.service
}

maybe_reboot() {
    local reboot="${1:-ask}"
    case "$reboot" in
        yes)
            echo "Rebooting..."
            /usr/sbin/reboot
            ;;
        no)
            echo "Reboot later with: sudo reboot"
            ;;
        ask|*)
            if ui_yesno "Reboot" "Reboot now to launch kiosk mode?"; then
                echo "Rebooting..."
                /usr/sbin/reboot
            else
                echo "Reboot later with: sudo reboot"
            fi
            ;;
    esac
}

install_chrome_kiosk() {
    local kiosk_url="$1"
    local kiosk_name="$2"
    local theme="$3"
    local reboot="$4"
    local colors bar_background bar_color

    [ -n "$kiosk_url" ] || die "Chrome kiosk URL is required."
    [ -n "$kiosk_name" ] || kiosk_name=$(default_name)
    validate_theme "$theme"
    read -r bar_background bar_color <<< "$(theme_colors "$theme")"

    require_root
    install_base_packages yes
    ensure_kiosk_user
    write_chrome_start_script "$kiosk_url"
    write_common_files "$kiosk_name" "$bar_background" "$bar_color"
    write_service "Sway Chromium Kiosk Service"
    enable_kiosk_service

    ui_msg "Kiosk" "Chrome kiosk setup complete for:\n$kiosk_url"
    maybe_reboot "$reboot"
}

install_app_kiosk() {
    local requested_app="$1"
    local kiosk_name="$2"
    local theme="$3"
    local reboot="$4"
    local colors bar_background bar_color app_path

    [ -n "$requested_app" ] || die "Application command or path is required."
    app_path=$(resolve_app_command "$requested_app")
    [ -n "$kiosk_name" ] || kiosk_name=$(default_name)
    validate_theme "$theme"
    read -r bar_background bar_color <<< "$(theme_colors "$theme")"

    require_root
    install_base_packages no
    ensure_kiosk_user
    write_app_start_script "$app_path"
    write_common_files "$kiosk_name" "$bar_background" "$bar_color"
    write_service "Sway Application Kiosk Service"
    enable_kiosk_service

    ui_msg "Kiosk" "Application kiosk setup complete for:\n$app_path"
    maybe_reboot "$reboot"
}

install_profiles_kiosk() {
    local kiosk_name="$1"
    local theme="$2"
    local reboot="$3"
    local bar_background bar_color

    [ -n "$kiosk_name" ] || kiosk_name=$(default_name)
    validate_theme "$theme"
    read -r bar_background bar_color <<< "$(theme_colors "$theme")"

    require_root
    install_base_packages yes
    ensure_kiosk_user
    /usr/bin/install -d -m 0755 "$PROFILES_DIR"
    write_profile_login_script
    write_profiles_start_script
    write_common_files "$kiosk_name" "$bar_background" "$bar_color" yes
    write_service "Sway Profile Kiosk Service"
    enable_kiosk_service

    ui_msg "Kiosk Profiles" "Profile kiosk setup complete.\nAdd profiles with:\nsudo ./$SCRIPT_NAME profile-add --id staff --label Staff --pin 1234 --url https://example.com"
    maybe_reboot "$reboot"
}

add_profile() {
    local profile_id="$1"
    local label="$2"
    local pin="$3"
    local profile_type="$4"
    local target="$5"
    local fail_type="${6:-}"
    local fail_target="${7:-}"
    local pin_hash

    [ -n "$profile_id" ] || die "Profile id is required."
    [ -n "$label" ] || die "Profile label is required."
    [ -n "$pin" ] || die "Profile PIN is required."
    [ -n "$profile_type" ] || die "Profile type is required."
    [ -n "$target" ] || die "Profile target is required."
    validate_profile_id "$profile_id"
    require_root

    pin_hash=$(hash_pin "$pin")
    write_profile_file "$profile_id" "$label" "$pin_hash" "$profile_type" "$target" "$fail_type" "$fail_target"
    ui_msg "Kiosk Profile" "Profile '$profile_id' saved."
}

modify_profile() {
    local profile_id="$1"
    local new_label="${2:-}"
    local new_pin="${3:-}"
    local new_type="${4:-}"
    local new_target="${5:-}"
    local new_fail_type="${6:-__KEEP__}"
    local new_fail_target="${7:-__KEEP__}"
    local profile_file label pin_hash profile_type target fail_type fail_target

    [ -n "$profile_id" ] || die "Profile id is required."
    validate_profile_id "$profile_id"
    require_root

    profile_file=$(profile_file_path "$profile_id")
    [ -f "$profile_file" ] || die "Profile '$profile_id' does not exist."

    load_profile_fields "$profile_file"
    label="${LABEL:-$profile_id}"
    pin_hash="${PIN_HASH:-}"
    profile_type="${TYPE:-}"
    if [ "$profile_type" = "chrome" ]; then
        target="${URL:-}"
    else
        target="${COMMAND:-}"
    fi
    fail_type="${FAIL_TYPE:-}"
    fail_target="${FAIL_TARGET:-}"

    [ -n "$new_label" ] && label="$new_label"
    [ -n "$new_pin" ] && pin_hash=$(hash_pin "$new_pin")
    [ -n "$new_type" ] && profile_type="$new_type"
    [ -n "$new_target" ] && target="$new_target"

    if [ "$new_fail_type" != "__KEEP__" ]; then
        fail_type="$new_fail_type"
    fi
    if [ "$new_fail_target" != "__KEEP__" ]; then
        fail_target="$new_fail_target"
    fi

    [ -n "$label" ] || die "Profile label is required."
    [ -n "$pin_hash" ] || die "Profile PIN is required."
    [ -n "$profile_type" ] || die "Profile type is required."
    [ -n "$target" ] || die "Profile target is required."

    if [ -z "$fail_type" ] || [ -z "$fail_target" ]; then
        fail_type=""
        fail_target=""
    fi

    write_profile_file "$profile_id" "$label" "$pin_hash" "$profile_type" "$target" "$fail_type" "$fail_target"
    ui_msg "Kiosk Profile" "Profile '$profile_id' updated."
}

list_profiles() {
    local profile_file profile_id label type target output
    output=""

    if [ ! -d "$PROFILES_DIR" ]; then
        ui_msg "Kiosk Profiles" "No profile directory found."
        return
    fi

    while IFS= read -r profile_file; do
        load_profile_fields "$profile_file"
        profile_id="${PROFILE_ID:-${profile_file##*/}}"
        label="${LABEL:-$profile_id}"
        type="${TYPE:-unknown}"
        if [ "$type" = "chrome" ]; then
            target="$URL"
        else
            target="$COMMAND"
        fi
        if [ -n "${FAIL_TYPE:-}" ] && [ -n "${FAIL_TARGET:-}" ]; then
            output+="$profile_id | $label | $type | $target | fallback: $FAIL_TYPE\n"
        else
            output+="$profile_id | $label | $type | $target\n"
        fi
    done < <(/usr/bin/find "$PROFILES_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | /usr/bin/sort)

    [ -n "$output" ] || output="No profiles configured.\n"
    ui_msg "Kiosk Profiles" "$output"
}

remove_profile() {
    local profile_id="$1"
    [ -n "$profile_id" ] || die "Profile id is required."
    validate_profile_id "$profile_id"
    require_root

    /usr/bin/rm -f "$PROFILES_DIR/$profile_id.conf"
    ui_msg "Kiosk Profile" "Profile '$profile_id' removed."
}

configure_wifi() {
    local ssid="$1"
    local password="${2:-}"
    local wifi_device

    [ -n "$ssid" ] || die "SSID is required."
    require_root

    if ! command -v nmcli >/dev/null 2>&1; then
        echo "Installing NetworkManager..."
        /usr/bin/apt update
        /usr/bin/apt install -y network-manager
    fi

    echo "Enabling NetworkManager and WiFi radio..."
    /usr/bin/systemctl enable --now NetworkManager.service
    /usr/bin/nmcli radio wifi on

    wifi_device=$(/usr/bin/nmcli -t -f DEVICE,TYPE,STATE device status | /usr/bin/awk -F: '$2 == "wifi" { print $1; exit }')
    [ -n "$wifi_device" ] || die "No WiFi device found."

    echo "Scanning for WiFi networks..."
    /usr/bin/nmcli device wifi rescan ifname "$wifi_device" || true

    echo "Connecting '$wifi_device' to '$ssid'..."
    if [ -n "$password" ]; then
        /usr/bin/nmcli device wifi connect "$ssid" password "$password" ifname "$wifi_device"
    else
        /usr/bin/nmcli device wifi connect "$ssid" ifname "$wifi_device"
    fi

    /usr/bin/nmcli connection modify "$ssid" connection.autoconnect yes
    /usr/bin/nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP4.ADDRESS device show "$wifi_device"
}

set_kiosk_name() {
    local kiosk_name="$1"
    [ -n "$kiosk_name" ] || die "Kiosk name is required."
    require_root

    /usr/bin/install -d -m 0755 "$KIOSK_DIR"
    /usr/bin/printf '%s\n' "$kiosk_name" > "$KIOSK_DIR/name"
    ui_msg "Kiosk Name" "Kiosk name set to:\n$kiosk_name\n\nRestart kiosk.service or reboot to refresh the topbar immediately."
}

show_status() {
    local service_state="unknown"
    local enabled_state="unknown"
    local configured_name="not configured"
    local profile_count="0"

    if command -v systemctl >/dev/null 2>&1; then
        service_state=$(/usr/bin/systemctl is-active kiosk.service 2>/dev/null || true)
        enabled_state=$(/usr/bin/systemctl is-enabled kiosk.service 2>/dev/null || true)
    fi
    [ -n "$service_state" ] || service_state="unknown"
    [ -n "$enabled_state" ] || enabled_state="unknown"
    if [ -f "$KIOSK_DIR/name" ]; then
        configured_name=$(/usr/bin/sed -n '1p' "$KIOSK_DIR/name")
    fi
    if [ -d "$PROFILES_DIR" ]; then
        profile_count=$(/usr/bin/find "$PROFILES_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | /usr/bin/wc -l)
    fi

    ui_msg "Kiosk Status" "Service active: $service_state\nService enabled: $enabled_state\nKiosk name: $configured_name\nProfiles: $profile_count\nStart script: $START_SCRIPT\nSway config: $SWAY_CONF"
}

revert_kiosk() {
    local reboot="$1"
    require_root

    echo "Stopping and disabling kiosk service..."
    /usr/bin/systemctl disable --now kiosk.service 2>/dev/null || true

    echo "Removing kiosk service and startup files..."
    /usr/bin/rm -f \
        "$SERVICE_FILE" \
        "$START_SCRIPT" \
        "$PROFILE_LOGIN_SCRIPT" \
        "$SWAY_CONF" \
        "$KIOSK_DIR/name" \
        "$KIOSK_DIR/ip-address.sh" \
        "$KIOSK_DIR/logout.sh" \
        "$KIOSK_DIR/wifi-status.sh" \
        "$KIOSK_DIR/waybar.json" \
        "$KIOSK_DIR/waybar.css"
    /usr/bin/rm -rf "$PROFILES_DIR"
    /usr/bin/rmdir "$KIOSK_DIR" 2>/dev/null || true

    echo "Restoring normal graphical boot target..."
    /usr/bin/systemctl set-default graphical.target
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl reset-failed kiosk.service 2>/dev/null || true
    /usr/bin/systemctl unmask getty@tty1.service

    ui_msg "Kiosk" "Kiosk configuration removed.\nInstalled packages and the '$KIOSK_USER' user were preserved."
    maybe_reboot "$reboot"
}

ask_theme() {
    ui_menu "Theme" "Choose top bar theme" \
        dark "Dark top bar" \
        bitcoin "Bitcoin orange top bar" \
        navy "Navy top bar"
}

interactive_chrome() {
    local url name theme
    url=$(ui_input "Chrome Kiosk" "URL to open in kiosk mode" "https://example.com") || return
    name=$(ui_input "Chrome Kiosk" "Name shown in the top bar" "$(default_name)") || return
    theme=$(ask_theme) || return
    install_chrome_kiosk "$url" "$name" "$theme" ask
}

interactive_app() {
    local app name theme
    app=$(ui_input "Application Kiosk" "Application command or full path" "chromium") || return
    name=$(ui_input "Application Kiosk" "Name shown in the top bar" "$(default_name)") || return
    theme=$(ask_theme) || return
    install_app_kiosk "$app" "$name" "$theme" ask
}

interactive_profiles() {
    local name theme
    name=$(ui_input "Profile Kiosk" "Name shown in the top bar" "$(default_name)") || return
    theme=$(ask_theme) || return
    install_profiles_kiosk "$name" "$theme" ask
}

interactive_select_profile() {
    local profile_file choice
    local menu_items=()

    if [ ! -d "$PROFILES_DIR" ]; then
        ui_msg "Profiles" "No profile directory found."
        return 1
    fi

    while IFS= read -r profile_file; do
        load_profile_fields "$profile_file"
        [ -n "$PROFILE_ID" ] || continue
        menu_items+=("$PROFILE_ID" "${LABEL:-$PROFILE_ID}")
    done < <(/usr/bin/find "$PROFILES_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | /usr/bin/sort)

    if [ "${#menu_items[@]}" -eq 0 ]; then
        ui_msg "Profiles" "No profiles configured."
        return 1
    fi

    choice=$(ui_menu "Profiles" "Select a profile" "${menu_items[@]}") || return 1
    printf '%s\n' "$choice"
}

interactive_profile_add() {
    local profile_id label pin target profile_type choice
    local fail_type="" fail_target=""
    profile_id=$(ui_input "Add Profile" "Profile id. Use letters, numbers, underscore or dash" "staff") || return
    label=$(ui_input "Add Profile" "Profile label shown at login" "$profile_id") || return
    pin=$(ui_input "Add Profile" "Profile PIN" "" yes) || return
    choice=$(ui_menu "Add Profile" "What should this profile launch?" \
        chrome "Chromium URL" \
        command "Application command") || return
    profile_type="$choice"
    if [ "$profile_type" = "chrome" ]; then
        target=$(ui_input "Add Profile" "URL" "https://example.com") || return
    else
        target=$(ui_input "Add Profile" "Command" "chromium") || return
    fi
    if ui_yesno "Fallback" "Launch a fallback program when the PIN is wrong?"; then
        choice=$(ui_menu "Fallback" "Fallback target type" \
            chrome "Chromium URL" \
            command "Application command") || return
        fail_type="$choice"
        if [ "$fail_type" = "chrome" ]; then
            fail_target=$(ui_input "Fallback" "Fallback URL" "https://example.com") || return
        else
            fail_target=$(ui_input "Fallback" "Fallback command" "chromium --app=https://example.com") || return
        fi
    fi
    add_profile "$profile_id" "$label" "$pin" "$profile_type" "$target" "$fail_type" "$fail_target"
}

interactive_profile_modify() {
    local profile_id label pin target profile_type choice profile_file
    local current_label current_type current_target current_fail_type current_fail_target
    local fail_type="__KEEP__" fail_target="__KEEP__"

    profile_id=$(interactive_select_profile) || return
    profile_file=$(profile_file_path "$profile_id")
    [ -f "$profile_file" ] || return

    load_profile_fields "$profile_file"
    current_label="${LABEL:-$profile_id}"
    current_type="${TYPE:-command}"
    if [ "$current_type" = "chrome" ]; then
        current_target="${URL:-}"
    else
        current_target="${COMMAND:-}"
    fi
    current_fail_type="${FAIL_TYPE:-}"
    current_fail_target="${FAIL_TARGET:-}"

    label=$(ui_input "Modify Profile" "Profile label" "$current_label") || return
    pin=$(ui_input "Modify Profile" "New PIN. Leave empty to keep current" "" yes) || return
    if ui_yesno "Modify Target" "Change the real program or URL for this profile?"; then
        choice=$(ui_menu "Modify Target" "Current type: $current_type. Choose target type" \
            chrome "Chromium URL" \
            command "Application command") || return
        profile_type="$choice"
        if [ "$profile_type" = "chrome" ]; then
            if [ "$current_type" = "chrome" ]; then
                target=$(ui_input "Modify Target" "URL" "$current_target") || return
            else
                target=$(ui_input "Modify Target" "URL" "https://example.com") || return
            fi
        else
            if [ "$current_type" = "command" ]; then
                target=$(ui_input "Modify Target" "Command" "$current_target") || return
            else
                target=$(ui_input "Modify Target" "Command" "chromium") || return
            fi
        fi
    else
        profile_type=""
        target=""
    fi
    if ui_yesno "Fallback" "Change fallback program for wrong PIN?"; then
        if [ -n "$current_fail_type" ] && [ -n "$current_fail_target" ]; then
            if ui_yesno "Fallback" "Clear the current fallback program?"; then
                fail_type=""
                fail_target=""
            else
                choice=$(ui_menu "Fallback" "Current fallback type: $current_fail_type. Choose target type" \
                    chrome "Chromium URL" \
                    command "Application command") || return
                fail_type="$choice"
                if [ "$fail_type" = "chrome" ]; then
                    if [ "$current_fail_type" = "chrome" ]; then
                        fail_target=$(ui_input "Fallback" "Fallback URL" "$current_fail_target") || return
                    else
                        fail_target=$(ui_input "Fallback" "Fallback URL" "https://example.com") || return
                    fi
                else
                    if [ "$current_fail_type" = "command" ]; then
                        fail_target=$(ui_input "Fallback" "Fallback command" "$current_fail_target") || return
                    else
                        fail_target=$(ui_input "Fallback" "Fallback command" "chromium --app=https://example.com") || return
                    fi
                fi
            fi
        else
            choice=$(ui_menu "Fallback" "Fallback target type" \
                chrome "Chromium URL" \
                command "Application command") || return
            fail_type="$choice"
            if [ "$fail_type" = "chrome" ]; then
                fail_target=$(ui_input "Fallback" "Fallback URL" "https://example.com") || return
            else
                fail_target=$(ui_input "Fallback" "Fallback command" "chromium --app=https://example.com") || return
            fi
        fi
    fi
    modify_profile "$profile_id" "$label" "$pin" "$profile_type" "$target" "$fail_type" "$fail_target"
}

interactive_profile_remove() {
    local profile_id
    profile_id=$(interactive_select_profile) || return
    remove_profile "$profile_id"
}

interactive_wifi() {
    local ssid password
    ssid=$(ui_input "WiFi" "SSID") || return
    password=$(ui_input "WiFi" "Password. Leave empty for open network" "" yes) || return
    configure_wifi "$ssid" "$password"
    ui_msg "WiFi" "WiFi configuration finished."
}

interactive_name() {
    local name
    name=$(ui_input "Kiosk Name" "Name shown in the top bar" "$(default_name)") || return
    set_kiosk_name "$name"
}

interactive_settings_menu() {
    local choice
    while true; do
        choice=$(ui_menu "Settings" "Choose a settings action" \
            wifi "Configure WiFi" \
            name "Change kiosk top bar name" \
            back "Back") || return

        case "$choice" in
            wifi) interactive_wifi ;;
            name) interactive_name ;;
            back) return ;;
        esac
    done
}

interactive_menu() {
    local choice
    while true; do
        choice=$(ui_menu "Kiosk Setup" "What does the client want to do?" \
            chrome "Install Chromium URL kiosk" \
            app "Install application kiosk" \
            profiles "Install profile login kiosk" \
            profile_add "Add a login profile" \
            profile_modify "Modify a login profile" \
            profile_list "List login profiles" \
            profile_remove "Remove a login profile" \
            settings "WiFi and kiosk name" \
            status "Show kiosk status" \
            revert "Remove kiosk boot configuration" \
            quit "Exit") || exit 0

        case "$choice" in
            chrome) interactive_chrome ;;
            app) interactive_app ;;
            profiles) interactive_profiles ;;
            profile_add) interactive_profile_add ;;
            profile_modify) interactive_profile_modify ;;
            profile_list) list_profiles ;;
            profile_remove) interactive_profile_remove ;;
            settings) interactive_settings_menu ;;
            status) show_status ;;
            revert)
                if ui_yesno "Revert" "Remove kiosk service and restore graphical boot?"; then
                    revert_kiosk ask
                fi
                ;;
            quit) exit 0 ;;
        esac
    done
}

parse_common_install_args() {
    local mode="$1"
    shift
    local target=""
    local name=""
    local theme="dark"
    local reboot="ask"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --url)
                [ "$mode" = "chrome" ] || die "--url is only valid for chrome mode."
                require_value "$1" "${2:-}"
                target="${2:-}"
                shift 2
                ;;
            --command|--app)
                [ "$mode" = "app" ] || die "$1 is only valid for app mode."
                require_value "$1" "${2:-}"
                target="${2:-}"
                shift 2
                ;;
            --name)
                require_value "$1" "${2:-}"
                name="${2:-}"
                shift 2
                ;;
            --theme)
                require_value "$1" "${2:-}"
                theme="${2:-}"
                shift 2
                ;;
            --reboot)
                reboot="yes"
                shift
                ;;
            --no-reboot)
                reboot="no"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option '$1'."
                ;;
        esac
    done

    if [ "$mode" = "chrome" ]; then
        install_chrome_kiosk "$target" "$name" "$theme" "$reboot"
    else
        install_app_kiosk "$target" "$name" "$theme" "$reboot"
    fi
}

main() {
    if [ "$#" -eq 0 ]; then
        interactive_menu
        exit 0
    fi

    case "$1" in
        chrome)
            shift
            parse_common_install_args chrome "$@"
            ;;
        app)
            shift
            parse_common_install_args app "$@"
            ;;
        profiles)
            shift
            local name=""
            local theme="dark"
            local reboot="ask"
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --name) require_value "$1" "${2:-}"; name="${2:-}"; shift 2 ;;
                    --theme) require_value "$1" "${2:-}"; theme="${2:-}"; shift 2 ;;
                    --reboot) reboot="yes"; shift ;;
                    --no-reboot) reboot="no"; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            install_profiles_kiosk "$name" "$theme" "$reboot"
            ;;
        profile-add)
            shift
            local profile_id=""
            local label=""
            local pin=""
            local profile_type=""
            local target=""
            local fail_type=""
            local fail_target=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --id) require_value "$1" "${2:-}"; profile_id="${2:-}"; shift 2 ;;
                    --label) require_value "$1" "${2:-}"; label="${2:-}"; shift 2 ;;
                    --pin) require_value "$1" "${2:-}"; pin="${2:-}"; shift 2 ;;
                    --url)
                        require_value "$1" "${2:-}"
                        [ -z "$profile_type" ] || die "Use only one of --url or --command."
                        profile_type="chrome"
                        target="${2:-}"
                        shift 2
                        ;;
                    --command)
                        require_value "$1" "${2:-}"
                        [ -z "$profile_type" ] || die "Use only one of --url or --command."
                        profile_type="command"
                        target="${2:-}"
                        shift 2
                        ;;
                    --fail-url)
                        require_value "$1" "${2:-}"
                        [ -z "$fail_type" ] || die "Use only one of --fail-url or --fail-command."
                        fail_type="chrome"
                        fail_target="${2:-}"
                        shift 2
                        ;;
                    --fail-command)
                        require_value "$1" "${2:-}"
                        [ -z "$fail_type" ] || die "Use only one of --fail-url or --fail-command."
                        fail_type="command"
                        fail_target="${2:-}"
                        shift 2
                        ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            add_profile "$profile_id" "$label" "$pin" "$profile_type" "$target" "$fail_type" "$fail_target"
            ;;
        profile-modify)
            shift
            local profile_id=""
            local label=""
            local pin=""
            local profile_type=""
            local target=""
            local fail_type="__KEEP__"
            local fail_target="__KEEP__"
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --id) require_value "$1" "${2:-}"; profile_id="${2:-}"; shift 2 ;;
                    --label) require_value "$1" "${2:-}"; label="${2:-}"; shift 2 ;;
                    --pin) require_value "$1" "${2:-}"; pin="${2:-}"; shift 2 ;;
                    --url)
                        require_value "$1" "${2:-}"
                        [ -z "$profile_type" ] || die "Use only one of --url or --command."
                        profile_type="chrome"
                        target="${2:-}"
                        shift 2
                        ;;
                    --command)
                        require_value "$1" "${2:-}"
                        [ -z "$profile_type" ] || die "Use only one of --url or --command."
                        profile_type="command"
                        target="${2:-}"
                        shift 2
                        ;;
                    --fail-url)
                        require_value "$1" "${2:-}"
                        [ "$fail_type" = "__KEEP__" ] || die "Use only one fallback option."
                        fail_type="chrome"
                        fail_target="${2:-}"
                        shift 2
                        ;;
                    --fail-command)
                        require_value "$1" "${2:-}"
                        [ "$fail_type" = "__KEEP__" ] || die "Use only one fallback option."
                        fail_type="command"
                        fail_target="${2:-}"
                        shift 2
                        ;;
                    --clear-fail)
                        [ "$fail_type" = "__KEEP__" ] || die "Use only one fallback option."
                        fail_type=""
                        fail_target=""
                        shift
                        ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            modify_profile "$profile_id" "$label" "$pin" "$profile_type" "$target" "$fail_type" "$fail_target"
            ;;
        profile-list)
            list_profiles
            ;;
        profile-remove)
            shift
            local profile_id=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --id) require_value "$1" "${2:-}"; profile_id="${2:-}"; shift 2 ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            remove_profile "$profile_id"
            ;;
        wifi)
            shift
            local ssid=""
            local password=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --ssid) require_value "$1" "${2:-}"; ssid="${2:-}"; shift 2 ;;
                    --password) require_value "$1" "${2:-}"; password="${2:-}"; shift 2 ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            configure_wifi "$ssid" "$password"
            ;;
        name)
            shift
            local name=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --name) require_value "$1" "${2:-}"; name="${2:-}"; shift 2 ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            set_kiosk_name "$name"
            ;;
        status)
            show_status
            ;;
        revert)
            shift
            local reboot="ask"
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --reboot) reboot="yes"; shift ;;
                    --no-reboot) reboot="no"; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) die "Unknown option '$1'." ;;
                esac
            done
            revert_kiosk "$reboot"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            die "Unknown command '$1'. Run '$SCRIPT_NAME --help'."
            ;;
    esac
}

main "$@"
