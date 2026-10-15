#!/usr/bin/env bash
# Lock/unlock soak test: GNOME disables the extension on lock and enables it on
# unlock, rebuilding every panel. Runs it in a throwaway headless GNOME Shell with
# two virtual monitors, cycles it, then sends a notification. A leaked date menu
# throws "this._settings is null" on every notification, so any such error fails.
#
# Usage: scripts/soak-test.sh [extension-source-dir] [cycles]
# Requires a local GNOME Shell (headless mode); never touches the running session.
set -euo pipefail

SOURCE_DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
CYCLES="${2:-200}"
# RSS climbs while the GC settles and then plateaus; only growth over the second
# half of the run counts. Noise on a plateau measured at about 25 MB.
MAX_RSS_GROWTH_KB="${MAX_RSS_GROWTH_KB:-40000}"
UUID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["uuid"])' "$SOURCE_DIR/metadata.json")"

WORK="$(mktemp -d /tmp/mmb-soak.XXXXXX)"
if [ -z "${KEEP_WORK:-}" ]; then
    trap 'rm -rf -- "$WORK"' EXIT
fi
EXT_DIR="$WORK/.local/share/gnome-shell/extensions/$UUID"
mkdir -p "$EXT_DIR" "$WORK/.config" "$WORK/run"
chmod 700 "$WORK/run"
rsync -a --exclude=.git --exclude=.github --exclude=tests --exclude=scripts --exclude='*.zip' \
    "$SOURCE_DIR/" "$EXT_DIR/"
glib-compile-schemas "$EXT_DIR/schemas"

cat > "$WORK/session.sh" <<'SESSION'
set -euo pipefail
shell_call() {
    gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method "org.gnome.Shell.Extensions.$1" "$UUID" 2>/dev/null
}
state() { shell_call GetExtensionInfo | grep -oE "'state': <[0-9.]+>" | grep -oE '[0-9]+' | head -1; }
wait_state() {
    for _ in $(seq 100); do
        [ "$(state)" = "$1" ] && return 0
        sleep 0.1
    done
    echo "RESULT error=timeout-waiting-for-state-$1 last_state=$(state)"
    exit 1
}
notify() {
    gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify soak-test 0 '' "$1" body '[]' '{}' 0
}
rss() { awk '/^VmRSS/{print $2}' "/proc/$SHELL_PID/status"; }

gnome-shell --headless --wayland --no-x11 \
    --virtual-monitor 1920x1080 --virtual-monitor 1920x1080 > "$WORK/shell.log" 2>&1 &
SHELL_PID=$!
for _ in $(seq 300); do
    shell_call GetExtensionInfo >/dev/null && break
    sleep 0.2
done

shell_call EnableExtension >/dev/null
wait_state 1
# One notification source that outlives every rebuild, like a chat app's. Each gdbus
# call is a new sender, hence a new source, so the trigger below closes this same one.
NOTIFICATION_ID=$(notify first | sed -E 's/.* ([0-9]+),.*/\1/')
RSS_MID=$(rss)
sleep 2

for i in $(seq "$CYCLES"); do
    shell_call DisableExtension >/dev/null
    wait_state 2
    shell_call EnableExtension >/dev/null
    wait_state 1
    if [ "$i" -eq $((CYCLES / 2)) ]; then
        RSS_MID=$(rss)
    fi
    if [ $((i % 25)) -eq 0 ]; then
        echo "SERIES cycle=$i rss_kb=$(rss)"
    fi
done
sleep 2
gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.CloseNotification "$NOTIFICATION_ID" >/dev/null
sleep 3

ERRORS="$(shell_call GetExtensionErrors)"
RSS_END=$(rss)
echo "RESULT state=$(state) rss_mid_kb=$RSS_MID rss_end_kb=$RSS_END extension_errors=$ERRORS"
kill "$SHELL_PID"
wait "$SHELL_PID" 2>/dev/null || true
SESSION

env -i PATH="$PATH" HOME="$WORK" XDG_CONFIG_HOME="$WORK/.config" XDG_DATA_HOME="$WORK/.local/share" \
    XDG_CACHE_HOME="$WORK/.cache" XDG_RUNTIME_DIR="$WORK/run" WORK="$WORK" UUID="$UUID" CYCLES="$CYCLES" \
    dbus-run-session -- bash "$WORK/session.sh" > "$WORK/result.log" 2>&1 || true

RESULT="$(grep '^RESULT' "$WORK/result.log" || true)"
grep '^SERIES' "$WORK/result.log" || true
LEAKED="$(grep -c '_settings is null' "$WORK/shell.log" || true)"
JS_ERRORS="$(grep -cE 'JS ERROR' "$WORK/shell.log" || true)"
EXT_TRACES="$(grep -cE "extensions/$UUID/.*\.js" "$WORK/shell.log" || true)"
echo "uuid=$UUID cycles=$CYCLES"
echo "${RESULT:-RESULT error=no-result}"
echo "settings_null_errors=$LEAKED js_errors=$JS_ERRORS extension_stack_frames=$EXT_TRACES"
grep -oE 'JS ERROR: .*' "$WORK/shell.log" | sort | uniq -c | sort -rn | head -5 || true

FAILED=0
case "$RESULT" in
    *"state=1 "*) ;;
    *) echo "FAIL: extension not active at the end"; FAILED=1 ;;
esac
case "$RESULT" in
    *"extension_errors=(@as [],)"*) ;;
    *) echo "FAIL: extension reported errors"; FAILED=1 ;;
esac
if [ "$LEAKED" -gt 0 ]; then
    echo "FAIL: $LEAKED leaked date menus reacted to a notification"
    FAILED=1
fi
MID=$(grep -oE 'rss_mid_kb=[0-9]+' <<<"$RESULT" | cut -d= -f2)
END=$(grep -oE 'rss_end_kb=[0-9]+' <<<"$RESULT" | cut -d= -f2)
if [ -n "$MID" ] && [ -n "$END" ] && [ $((END - MID)) -gt "$MAX_RSS_GROWTH_KB" ]; then
    echo "FAIL: shell RSS grew $(((END - MID) / 1024)) MB over the second half (limit $((MAX_RSS_GROWTH_KB / 1024)) MB)"
    FAILED=1
fi
[ "$FAILED" -eq 0 ] && echo "PASS"
exit "$FAILED"
