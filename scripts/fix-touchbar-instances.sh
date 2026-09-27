#!/bin/bash
# Make the gavinmclelland/omarchy-macbookpro14-3 Touch Bar scripts survive
# HID instance renumbering. Root cause: touchbar.service condition,
# touchbar-enable.sh and touchbar-fn-watch.sh hardcode 0003:05AC:8600.0001/.0002,
# but the trailing number is HID REGISTRATION ORDER - it shifts boot to boot.
# When the iBridge enumerates as .0005/.0006 the service silently skips itself:
# dark strip, zero errors, "worked yesterday, dead today".
#
# See: https://github.com/gavinmclelland/omarchy-macbookpro14-3/issues/31
#
# Usage: sudo ./fix-touchbar-instances.sh
# NOTE: re-run this AFTER any 'sudo ./install.sh' from the overlay repo (it reverts).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
S=/usr/local/sbin

[ -f "$S/touchbar-enable.sh" ] || { echo "overlay not installed (no $S/touchbar-enable.sh) - run its install.sh first"; exit 1; }

echo "[1/4] Installing tb-find.sh..."
if ! install -m 0755 "$(dirname "$0")/tb-find.sh" "$S/tb-find.sh" 2>/dev/null; then
cat > "$S/tb-find.sh" <<'EOF'
#!/bin/bash
for d in /sys/bus/hid/devices/0003:05AC:8600.*; do
  r=$(readlink -f "$d" 2>/dev/null)
  if [ -e "$r/fnmode" ]; then printf '%s\n' "$r"; exit 0; fi
done
exit 1
EOF
chmod 0755 "$S/tb-find.sh"
fi

echo "[2/4] Patching touchbar-enable.sh..."
# NOTE: after upstream PR #26 merges (by-driver discovery), these sed targets
# no longer exist. Detect that and report instead of silently "succeeding".
if grep -q 'touchbar_hid_device' "$S/touchbar-enable.sh"; then
  echo "  touchbar-enable.sh already has upstream dynamic discovery (PR #26+) - skipping"
else
  cp -n "$S/touchbar-enable.sh" "$S/touchbar-enable.sh.pre-hidfix"
  sed -i 's#readlink -f "/sys/bus/hid/devices/0003:05AC:8600.[0-9]*"#/usr/local/sbin/tb-find.sh#' "$S/touchbar-enable.sh"
  sed -i 's#^IBDEV=.*#IBDEV=$(basename $(ls -d /sys/bus/hid/devices/0003:05AC:8600.* 2>/dev/null | sed -n 2p))#' "$S/touchbar-enable.sh"
  grep -q "tb-find.sh" "$S/touchbar-enable.sh" || { echo "  ERROR: sed matched nothing in touchbar-enable.sh"; exit 1; }
fi
# ^ The Touch Bar is consistently the SECOND 8600 HID interface; the order is
#   stable even when the instance prefix shifts. hid-sensor-hub steals it at boot -
#   the script reclaims it. That logic is untouched here.

echo "[3/4] Patching touchbar-fn-watch.sh..."
cp -n "$S/touchbar-fn-watch.sh" "$S/touchbar-fn-watch.sh.pre-hidfix"
sed -i 's#readlink -f /sys/bus/hid/devices/0003:05AC:8600.[0-9]*#/usr/local/sbin/tb-find.sh#' "$S/touchbar-fn-watch.sh"
grep -q "tb-find.sh" "$S/touchbar-fn-watch.sh" || { echo "  ERROR: sed matched nothing in touchbar-fn-watch.sh"; exit 1; }

echo "[4/4] Wildcarding the service condition..."
install -d /etc/systemd/system/touchbar.service.d
cat > /etc/systemd/system/touchbar.service.d/any-instance.conf <<'EOF'
[Unit]
ConditionPathExistsGlob=
ConditionPathExistsGlob=/sys/bus/hid/devices/0003:05AC:8600.*
EOF
systemctl daemon-reload

echo
echo "Done. Test now (no reboot needed):"
echo "  sudo systemctl restart touchbar.service touchbar-fn.service"
echo "  journalctl -b -u touchbar.service --no-pager | tail -4   # expect: SUCCESS / Finished"
echo "  systemctl is-active touchbar.service touchbar-fn.service # active, active"
echo "Then reboot to confirm."
echo
echo "WARNING: never 'modprobe apple_ibridge' while debugging - default tb_mode"
echo "self-deadlocks (D-state, frozen shutdown). Always use the enable script."
