#!/system/bin/sh

HOOK=/data/adb/service.d/90-autodeck.sh
# Keep recovery available at later boots if Android services are unavailable.
if [ -f "$HOOK" ] && /system/bin/sh "$HOOK" recover &&
    [ ! -e /data/adb/autodeck/session ]; then
    rm -f "$HOOK"
fi
