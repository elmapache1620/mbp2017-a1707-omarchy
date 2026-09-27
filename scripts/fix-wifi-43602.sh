#!/bin/bash
# Repair BCM43602 (14e4:43ba) Wi-Fi on Omarchy/Arch for the 2017 MBP 15" (A1707).
#
# CORRECTED ROOT CAUSE (2026-09-26, after independent review - see README):
#   1. The client machine had a NON-STOCK/corrupt brcmfmac43602-pcie.bin that no
#      official package ever shipped (7f735b72... uncompressed; official content is
#      bf4cfc23... in EVERY linux-firmware-broadcom build 2023->2026 - Broadcom has
#      not touched this blob since 2015). A corrupt blob fails chip POST.
#   2. The chip then REQUIRES an NVRAM board file carrying the machine's REAL MAC.
#      A placeholder/absent MAC = "cur_etheraddr failed, -5" timeout.
#
# Usage:  sudo ./fix-wifi-43602.sh <WIFI_MAC>
#   MAC from macOS: System Information -> Network -> Wi-Fi (OUI varies by unit).
set -euo pipefail
MAC="${1:?usage: $0 <real-wifi-mac>}"
[[ "$MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || { echo "Bad MAC format"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

OFFICIAL_SHA=bf4cfc23ee952a3d82ef33a0f5f87853201c98f1bed034876a910f354f37862d
BLOB=/usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst

echo "[1/4] Verifying the installed blob against official content..."
if [ -f "$BLOB" ]; then
  CUR=$(zstd -dc "$BLOB" 2>/dev/null | sha256sum | cut -d" " -f1)
  echo "  installed (uncompressed): $CUR"
else
  CUR=missing
fi
if [ "$CUR" = "$OFFICIAL_SHA" ]; then
  echo "  blob is official content - leaving it alone."
else
  echo "  blob is NON-STOCK (or missing). Backing it up, reinstalling from the package..."
  [ -f "$BLOB" ] && cp "$BLOB" "/root/43602-nonstock-$(date +%Y%m%d).bin.zst.bak"
  pacman -S --overwrite usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst --noconfirm linux-firmware-broadcom
  NEW=$(zstd -dc "$BLOB" | sha256sum | cut -d" " -f1)
  [ "$NEW" = "$OFFICIAL_SHA" ] || { echo "  reinstall did not produce official content ($NEW) - STOP, investigate"; exit 1; }
fi

echo "[2/4] Installing the NVRAM board file with the REAL mac..."
# boardflags3=0xC0000303 variant verified on hardware; mismatch only warns.
curl -sfL -o /tmp/43602-nvram.txt https://raw.githubusercontent.com/gavinmclelland/omarchy-macbookpro14-3/HEAD/firmware/brcm/brcmfmac43602-pcie.txt
grep -q "boardflags3=0xC0000303" /tmp/43602-nvram.txt || echo "  note: boardflags3 differs from the verified variant"
sed -i "s/^macaddr=.*/macaddr=${MAC}/" /tmp/43602-nvram.txt
grep "macaddr=" /tmp/43602-nvram.txt | grep -q "^macaddr=${MAC}$" || { echo "  macaddr patch failed"; exit 1; }
mkdir -p /usr/lib/firmware/updates/brcm /usr/lib/firmware/brcm
# updates/ wins the loader search; the board-specific name is requested first.
install -m644 /tmp/43602-nvram.txt /usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt
install -m644 /tmp/43602-nvram.txt "/usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.Apple Inc.-MacBookPro14,3.txt"
install -m644 /tmp/43602-nvram.txt /usr/lib/firmware/brcm/brcmfmac43602-pcie.txt
install -m644 /tmp/43602-nvram.txt "/usr/lib/firmware/brcm/brcmfmac43602-pcie.Apple Inc.-MacBookPro14,3.txt"

echo "[3/4] Checking the Apple WPA handshake quirk..."
if ! grep -qs "feature_disable" /etc/modprobe.d/*.conf; then
  printf "# Broadcom firmware supplicant fails WPA4way on Apple hw; let wpa_supplicant do it.\noptions brcmfmac feature_disable=0x82000\n" \
    > /etc/modprobe.d/brcmfmac.conf
fi

echo "[4/4] Done. No pacman pin needed: the blob content has not changed 2023->2026."
echo
echo "REBOOT, then verify:"
echo "  ip -br link | grep wlp      # wlp3s0 UP with your real MAC"
echo "  nmcli device wifi list      # expect 2.4 AND 5 GHz APs"
echo "Benign dmesg noise: 'clm_blob ... err=-2', 'fail to get arp ip table err:-52'."
