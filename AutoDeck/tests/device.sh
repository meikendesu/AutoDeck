#!/usr/bin/env bash
set -eu
base=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export FIXTURE="$fixture" PATH="$fixture/bin:$PATH"
export AUTODECK_STATE="$fixture/state" AUTODECK_MODULE="$fixture/module"
export AUTODECK_SYS_USB="$fixture/usb" AUTODECK_UPTIME="$fixture/uptime"
mkdir "$fixture/bin" "$AUTODECK_MODULE" -p "$AUTODECK_SYS_USB/1-1"
echo 17e9 > "$AUTODECK_SYS_USB/1-1/idVendor"
echo 6006 > "$AUTODECK_SYS_USB/1-1/idProduct"
echo 100 > "$AUTODECK_UPTIME"
echo 'com.example.old/.Home' > "$fixture/home"
echo none > "$fixture/size"
echo ON > "$fixture/panel"

cat > "$fixture/bin/android-fake" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${0##*/} $*" in
    'getprop sys.boot_completed') echo 1 ;;
    'am get-current-user') echo 0 ;;
    'am get-started-user-state 0') echo RUNNING_UNLOCKED ;;
    'cmd display get-displays -i -t INTERNAL') echo 0 ;;
    'dumpsys media_projection')
        echo 'Media Projection:'
        if [ -e "$FIXTURE/projecting" ]; then
            echo '(com.displaylink.presenter, uid=10212): TYPE_SCREEN_CAPTURE'
        else
            echo null
        fi ;;
    'dumpsys display')
        state=$(cat "$FIXTURE/panel")
        echo "  DisplayDeviceInfo{\"Built-in Screen\": type INTERNAL, state $state, committedState $state}"
        if [ -e "$FIXTURE/capture-surface" ]; then
            echo '  DisplayDeviceInfo{"DisplayLink": type VIRTUAL, state ON, committedState UNKNOWN, owner com.displaylink.presenter (uid 10212)}'
        fi ;;
    'dumpsys window policy')
        if [ -e "$FIXTURE/locked" ]; then showing=true; else showing=false; fi
        printf '%s\n' '  KeyguardServiceDelegate' "    showing=$showing" ;;
    'cmd role get-role-holders --user 0 android.app.role.HOME')
        cut -d/ -f1 "$FIXTURE/home" ;;
    'cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME')
        cat "$FIXTURE/home" ;;
    'cmd package query-activities --components --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -p com.example.deck')
        echo com.example.deck/.Home ;;
    'cmd package set-home-activity --user 0 '*)
        if [ -e "$FIXTURE/delay-restore" ] && [ "${5}" = 'com.example.old/.Home' ]; then exit 1; fi
        echo "${5}" > "$FIXTURE/home"
        if [ -e "$FIXTURE/fail-set" ] && [ "${5}" = 'com.example.deck/.Home' ]; then exit 1; fi ;;
    'wm size -d 0')
        echo 'Physical size: 1080x2340'
        size=$(cat "$FIXTURE/size")
        if [ "$size" != none ]; then echo "Override size: $size"; fi ;;
    'wm size '*' -d 0')
        if [ "$2" = reset ]; then echo none
        elif [ "$2" = 1080x1920 ] && [ -e "$FIXTURE/clamp-size" ]; then echo 1000x1800
        else echo "$2"; fi > "$FIXTURE/size" ;;
    'am start-activity -W --user 0 --display 0 -a android.intent.action.MAIN -n com.example.deck/.Home')
        echo launched >> "$FIXTURE/launches"
        echo 'Status: ok' ;;
    'cmd display power-reset 0') echo ON > "$FIXTURE/panel" ;;
    'cmd display power-off 0') echo OFF > "$FIXTURE/panel" ;;
    *) echo "Unexpected fake command: ${0##*/} $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/android-fake"
for command in getprop am cmd wm dumpsys; do ln -s android-fake "$fixture/bin/$command"; done

device() { bash "$base/module/device.sh" "$@"; }
check() {
    [ "$(cat "$fixture/$1")" = "$2" ] || { echo "FAIL: $1 expected $2" >&2; exit 1; }
}
link() { touch "$fixture/projecting" "$fixture/capture-surface"; }
unlink_projection() { rm -f "$fixture/projecting" "$fixture/capture-surface"; }
idle() { unlink_projection; device tick; }

device configure com.example.deck/.Home 1080x1920 17e9:6006
touch "$fixture/projecting"
device tick
check home com.example.old/.Home
test ! -e "$fixture/launches"
touch "$fixture/capture-surface" "$fixture/locked"
device tick
check home com.example.old/.Home
rm "$fixture/locked"
device tick
check home com.example.deck/.Home
check size 1080x1920
check panel ON
check launches launched
echo 'PASS matching USB, active Presenter surface and an unlocked user gate automation'

device blank 5
check panel OFF
for attempt in {1..70}; do
    [ "$(cat "$fixture/panel")" != ON ] || break
    sleep .1
done
check panel ON
echo 'PASS the independent timer restores the panel without a watcher tick'

device blank 5
check panel OFF
echo 106 > "$AUTODECK_UPTIME"
device tick
check panel ON
check home com.example.deck/.Home
echo 'PASS explicit blanking expires without changing the session'

rm "$AUTODECK_SYS_USB/1-1/idProduct"
device tick
check size none
check home com.example.old/.Home
echo 'PASS OTG detach rolls back HOME and removes the temporary size override'

echo 6006 > "$AUTODECK_SYS_USB/1-1/idProduct"
echo 1024x2048 > "$fixture/size"
device tick
idle
check size 1024x2048
check home com.example.old/.Home
echo 'PASS projection stop restores a preexisting override exactly'

link
touch "$fixture/clamp-size"
device tick || :
rm "$fixture/clamp-size"
check size 1024x2048
check home com.example.old/.Home
echo 140 > "$AUTODECK_UPTIME"
idle
echo 'PASS an unexpected applied size is rolled back after verification fails'

link
touch "$fixture/fail-set"
device tick || :
rm "$fixture/fail-set"
check size 1024x2048
check home com.example.old/.Home
echo 175 > "$AUTODECK_UPTIME"
idle
echo 'PASS a failing launcher mutation rolls back the partial transaction'

link
device tick
touch "$fixture/delay-restore"
idle || :
test -s "$AUTODECK_STATE/session"
check size 1024x2048
rm "$fixture/delay-restore"
device tick
check home com.example.old/.Home
echo 'PASS failed HOME recovery keeps its saved state for retry'

link
device tick
echo 4000 > "$AUTODECK_UPTIME"
device tick
device tick
check home com.example.old/.Home
echo 'PASS session safety timeout does not rearm on a continuously present link'

idle
link
device tick
sed -i '1 s/.*/ffffffff-ffff-ffff-ffff-ffffffffffff/' "$AUTODECK_STATE/session"
idle
check home com.example.old/.Home
check size 1024x2048
echo 'PASS boot recovery restores persisted HOME and size'

link
device tick
device blank 5
touch "$AUTODECK_MODULE/disable"
device tick
check panel ON
check home com.example.old/.Home
echo 'PASS disabling the module restores the panel first'
