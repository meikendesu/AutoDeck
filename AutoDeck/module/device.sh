#!/system/bin/sh

umask 077
export LC_ALL=C
STATE=${AUTODECK_STATE:-/data/adb/autodeck}
MODULE=${AUTODECK_MODULE:-/data/adb/modules/autodeck}
USB=${AUTODECK_SYS_USB:-/sys/bus/usb/devices}
UPTIME=${AUTODECK_UPTIME:-/proc/uptime}
CONFIG=$STATE/config
SESSION=$STATE/session
DEFER=$STATE/defer
PANEL=$STATE/panel
LATCH=$STATE/handled
MAX_SESSION=1800

fail() { printf 'AutoDeck: %s\n' "$*" >&2; return 1; }
[ "$(id -u)" = 0 ] || { fail 'root required'; exit 1; }
mkdir -p "$STATE" || exit 1
BOOT=$(cat /proc/sys/kernel/random/boot_id) || exit 1

lock() {
    if [ -x /data/adb/ksu/bin/busybox ]; then
        /data/adb/ksu/bin/busybox flock "$@"
    else
        flock "$@"
    fi
}

android() { timeout -k 2 6 "$@"; }
booted() { [ "$(getprop sys.boot_completed)" = 1 ]; }
enabled() { [ -d "$MODULE" ] && [ ! -e "$MODULE/disable" ] && [ ! -e "$MODULE/remove" ]; }
owner_unlocked() { [ "$(android am get-started-user-state 0)" = RUNNING_UNLOCKED ]; }

current_user_ready() {
    owner_unlocked && [ "$(android am get-current-user)" = 0 ] || return 1
    policy=$(android dumpsys window policy) || return 1
    printf '%s\n' "$policy" | awk '
        /^[[:space:]]*KeyguardServiceDelegate[[:space:]]*$/ { delegate = 1; next; }
        delegate { found = ($0 ~ /^[[:space:]]*showing=false[[:space:]]*$/); exit; }
        END { exit !found; }'
}

uptime_seconds() {
    read -r elapsed rest < "$UPTIME" || return 1
    printf '%s\n' "${elapsed%%.*}"
}

atomic_write() {
    destination=$1
    shift
    printf '%s\n' "$@" > "$destination.new" && mv -f "$destination.new" "$destination"
}

component() {
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/\.?[A-Za-z_][A-Za-z0-9_.]*$' ||
        return 1
    component_package=${1%%/*}
    component_class=${1#*/}
    case "$component_class" in
        "$component_package".*) component_class=.${component_class#"$component_package."} ;;
    esac
    printf '%s/%s\n' "$component_package" "$component_class"
}

valid_size() {
    printf '%s\n' "$1" | grep -Eq '^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$'
}

configure() {
    [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 1
    [ ! -f "$SESSION" ] || { fail 'recover or disconnect before configuring'; return 1; }
    new_home=$(component "$1") || { fail 'invalid HOME component'; return 1; }
    new_size=${2:-keep}
    [ "$new_size" = keep ] || valid_size "$new_size" || { fail 'expected keep or WIDTHxHEIGHT'; return 1; }
    new_usb=${3:-17e9:*}
    printf '%s\n' "$new_usb" | grep -Eq '^[0-9a-f]{4}:([0-9a-f]{4}|\*)$' ||
        { fail 'expected lowercase USB VID:PID'; return 1; }
    atomic_write "$CONFIG" "$new_home" "$new_size" "$new_usb"
}

read_config() {
    { read -r configured_home && read -r configured_size && read -r configured_usb; } < "$CONFIG"
}

usb_devices() {
    for usb_node in "$USB"/*; do
        [ -r "$usb_node/idVendor" ] && [ -r "$usb_node/idProduct" ] || continue
        read -r vid < "$usb_node/idVendor" && read -r pid < "$usb_node/idProduct" || continue
        printf '%s %s:%s\n' "${usb_node##*/}" "$vid" "$pid"
    done
}

link_present() {
    usb_devices | awk -v id="$configured_usb" '
        $2 == id || (substr(id, 6) == "*" && substr($2, 1, 5) == substr(id, 1, 5)) { matches++; }
        END { exit matches != 1; }'
}

presenter_ready() {
    grant=$(android dumpsys media_projection) || return 1
    grant_uid=$(printf '%s\n' "$grant" | sed -nE 's/^\(com\.displaylink\.presenter, uid=([0-9]+)\):.*/\1/p')
    [ "$grant_uid" -ge 10000 ] 2>/dev/null && [ "$grant_uid" -lt 100000 ] || return 1
    displays=$(android dumpsys display) || return 1
    printf '%s\n' "$displays" | awk -v owner="owner com.displaylink.presenter (uid $grant_uid)" '
        /^[[:space:]]*DisplayDeviceInfo\{/ && /type VIRTUAL,/ && /state ON,/ && index($0, owner) { found = 1; }
        END { exit !found; }'
}

home_role() { android cmd role get-role-holders --user 0 android.app.role.HOME; }

current_home() {
    holder=$(home_role) || return 1
    resolved=$(android cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN \
        -c android.intent.category.HOME) || return 1
    resolved=$(component "$(printf '%s\n' "$resolved" | tail -n 1)") || return 1
    [ "$holder" = "${resolved%%/*}" ] || return 1
    printf '%s\n' "$resolved"
}

set_home() {
    android cmd package set-home-activity --user 0 "$1" >/dev/null || return 1
    [ "$(current_home)" = "$1" ]
}

size_override() {
    wm_size=$(android wm size -d 0) || return 1
    printf '%s\n' "$wm_size" | awk '
        /^Physical size: [1-9][0-9]+x[1-9][0-9]+$/ { physical++; next; }
        /^Override size: [1-9][0-9]+x[1-9][0-9]+$/ { override = $3; next; }
        { bad = 1; }
        END { if (bad || physical != 1) exit 1; print override == "" ? "none" : override; }'
}

set_size() {
    if [ "$1" = none ]; then
        android wm size reset -d 0 >/dev/null || return 1
    else
        valid_size "$1" && android wm size "$1" -d 0 >/dev/null || return 1
    fi
    [ "$(size_override)" = "$1" ]
}

panel_state() {
    devices=$(android dumpsys display) || return 1
    printf '%s\n' "$devices" | awk '
        /^[[:space:]]*DisplayDeviceInfo\{.*type INTERNAL,/ && /committedState / {
            split($0, part, "committedState "); split(part[2], value, /[,} ]/);
            count++; state = value[1];
        }
        END { if (count != 1) exit 1; print state; }'
}

panel_reset() {
    [ -f "$PANEL" ] || return 0
    marker=$(cat "$PANEL") || return 1
    # A previous boot already cleared DisplayManager's transient override.
    case "$marker" in
        "$BOOT":*) android cmd display power-reset 0 >/dev/null || return 1 ;;
    esac
    rm -f "$PANEL"
}

read_session() {
    { read -r previous_boot && read -r session_end && read -r old_home && read -r old_size &&
        read -r new_home && read -r new_size; } < "$SESSION" || return 1
    case "$session_end" in ''|*[!0-9]*) return 1 ;; esac
}

restore() {
    booted || return 1
    restored=0
    panel_reset || restored=1
    [ -f "$SESSION" ] || return "$restored"
    read_session && owner_unlocked || return 1
    if [ "$new_size" != keep ] && [ "$new_size" != "$old_size" ]; then
        actual_size=$(size_override) || actual_size=
        if [ -z "$actual_size" ]; then
            restored=1
        elif [ "$actual_size" != "$old_size" ]; then
            # A ROM can clamp a requested size before reporting success.
            if [ "$actual_size" = "$new_size" ] || [ -f "$DEFER" ]; then
                set_size "$old_size" || restored=1
            fi
        fi
    fi
    selected=$(current_home) || selected=
    if [ "$selected" != "$old_home" ]; then
        holder=$(home_role) || return 1
        if [ "$holder" = "${new_home%%/*}" ]; then set_home "$old_home" || restored=1
        elif [ -z "$selected" ]; then restored=1
        fi
    fi
    [ "$restored" = 0 ] || return 1
    if [ "$previous_boot" = "$BOOT" ] && [ -f "$DEFER" ]; then
        grace=$(cat "$DEFER") && moment=$(uptime_seconds) || return 1
        # Allow an interrupted Binder mutation to settle before discarding the backup.
        [ "$moment" -ge "$grace" ] || return 0
    fi
    rm -f "$SESSION" "$DEFER"
}

start_session() {
    old_home=$(current_home) || { fail 'no verifiable original HOME'; return 1; }
    old_size=$(size_override) || { fail 'cannot snapshot the Android display size'; return 1; }
    candidates=$(android cmd package query-activities --components --user 0 -a android.intent.action.MAIN \
        -c android.intent.category.HOME -p "${configured_home%%/*}") || return 1
    [ "$(component "$candidates")" = "$configured_home" ] ||
        { fail 'configured component must be the only HOME activity in its package'; return 1; }
    now=$(uptime_seconds) || return 1

    atomic_write "$SESSION" "$BOOT" "$((now + MAX_SESSION))" "$old_home" "$old_size" \
        "$configured_home" "$configured_size" &&
        atomic_write "$DEFER" "$((now + 30))" && sync || return 1
    if [ "$configured_size" != keep ] && [ "$configured_size" != "$old_size" ]; then
        set_size "$configured_size" || { restore; fail 'size override failed'; return 1; }
    fi
    if [ "$configured_home" != "$old_home" ]; then
        set_home "$configured_home" || { restore; fail 'HOME switch failed'; return 1; }
    fi
    started=$(android am start-activity -W --user 0 --display 0 -a android.intent.action.MAIN \
        -n "$configured_home")
    if ! printf '%s\n' "$started" | grep -qx 'Status: ok' || ! link_present || ! presenter_ready; then
        restore
        fail 'app launch or projection check failed'
        return 1
    fi
    rm -f "$DEFER"
}

tick() {
    booted || return 0
    linked=
    if [ -f "$CONFIG" ] && read_config && link_present && presenter_ready; then
        linked=1
    else
        rm -f "$LATCH"
    fi
    if [ -f "$SESSION" ]; then
        now=$(uptime_seconds) || return 1
        if ! read_session || [ "$previous_boot" != "$BOOT" ] || [ -f "$DEFER" ] ||
            [ "$now" -ge "$session_end" ] || ! enabled || [ -z "$linked" ] || ! current_user_ready; then
            restore
            return $?
        fi
        if [ -f "$PANEL" ]; then
            marker=$(cat "$PANEL") || return 1
            [ "$now" -lt "${marker#*:}" ] || panel_reset
        fi
    elif [ -f "$PANEL" ]; then
        panel_reset
    elif [ -n "$linked" ] && enabled && [ ! -f "$LATCH" ] && current_user_ready; then
        touch "$LATCH" && start_session
    fi
}

blank() {
    secs=${1:-15}
    printf '%s\n' "$secs" | grep -Eq '^([5-9]|[1-5][0-9]|60)$' ||
        { fail 'blank duration must be 5 to 60 seconds'; return 1; }
    [ -f "$SESSION" ] && [ ! -f "$DEFER" ] && [ ! -f "$PANEL" ] && enabled &&
        read_session && [ "$previous_boot" = "$BOOT" ] && read_config &&
        link_present && presenter_ready && current_user_ready ||
        { fail 'blanking requires an active Presenter session'; return 1; }
    [ "$(android cmd display get-displays -i -t INTERNAL)" = 0 ] &&
        [ "$(panel_state)" = ON ] && android cmd display power-reset 0 >/dev/null ||
        { fail 'internal panel or reversible power control unavailable'; return 1; }
    command -v nohup >/dev/null || return 1
    blank_now=$(uptime_seconds) || return 1
    marker="$BOOT:$((blank_now + secs))"
    atomic_write "$PANEL" "$marker" || return 1
    # The separate timer can reverse the override even if the main watcher exits.
    nohup sh "$0" panel-timer "$marker" "$secs" </dev/null >/dev/null 2>&1 9>&- &
    if ! android cmd display power-off 0 >/dev/null || [ "$(panel_state)" != OFF ] || ! presenter_ready; then
        panel_reset
        fail 'this ROM did not preserve the active capture during panel blanking'
        return 1
    fi
}

doctor() {
    printf '%s\n' 'USB path and VID:PID:'
    usb_devices
    if presenter_ready; then echo 'Presenter capture: active'; else echo 'Presenter capture: not detected'; fi
    printf 'HOME: %s\n' "$(current_home)"
    android wm size -d 0
    if [ -f "$SESSION" ]; then echo 'Session or pending recovery: yes'; else echo 'Session: idle'; fi
}

watch() {
    exec 8>"$STATE/watch.lock"
    lock -n -x 8 || exit 0
    while [ -f "$0" ]; do
        sh "$0" tick 8>&- || :
        if ! enabled && [ ! -f "$SESSION" ] && [ ! -f "$PANEL" ]; then break; fi
        sleep 2 8>&-
    done
}

command=${1:-watch}
case "$command" in
    watch) watch; exit $? ;;
    panel-timer)
        sleep "$3" || exit 1
        exec sh "$0" panel-expire "$2" ;;
esac
[ "$#" = 0 ] || shift
exec 9>"$STATE/lock"
lock -w 35 -x 9 || exit 1
case "$command" in
    tick) tick ;;
    configure) configure "$@" ;;
    doctor) doctor ;;
    blank) blank "$@" ;;
    recover) restore ;;
    panel-expire)
        if [ -f "$PANEL" ] && [ "$(cat "$PANEL")" = "$1" ]; then panel_reset; fi ;;
    *) fail 'usage: configure HOME [keep|WxH] [VID:PID] | doctor | blank [5-60] | recover' ;;
esac
