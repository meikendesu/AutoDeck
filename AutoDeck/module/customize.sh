#!/system/bin/sh

STATE=/data/adb/autodeck
HOOK=/data/adb/service.d/90-autodeck.sh
[ ! -e "$STATE/session" ] || abort "End the AutoDeck session before upgrading"
mkdir -p /data/adb/service.d || abort "Cannot create service.d"
cp "$MODPATH/device.sh" "$HOOK.new" || abort "Cannot copy the watchdog"
chmod 0700 "$HOOK.new" || abort "Cannot set watchdog permissions"
mv -f "$HOOK.new" "$HOOK" || abort "Cannot install the watchdog"
ui_print "Restart Android to start the AutoDeck watchdog"
