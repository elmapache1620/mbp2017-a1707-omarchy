#!/bin/bash
# Repair BCM43602 (14e4:43ba rev 02) Wi-Fi on Omarchy/Arch for the 2017 MBP 15" (A1707).
# Root cause: current linux-firmware blobs never POST the rev-02 chip; the 2015 blob
# (7.35.177.61) boots it and then requires an NVRAM board file with the REAL mac address.
#
# Usage:  sudo ./fix-wifi-43602.sh <WIFI_MAC>     e.g. sudo ./fix-wifi-43602.sh dc:a9:04:xx:xx:xx
# Get the MAC from macOS: System Information -> Network -> Wi-Fi (Apple OUI dc:a9:04).
set -euo pipefail
MAC="${1:?usage: $0 <real-wifi-mac>}"
[[ "$MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || { echo "Bad MAC format"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

EXPECTED_SHA=ee04af3b5be1399613b2e592a7e340a8dff2d9f98cce87a3c3a0fdfdedee562e
WORK=$(mktemp -d); cd "$WORK"

echo "[1/5] Fetching linux-firmware 20231110 from the Arch archive..."
curl -sfLO https://archive.archlinux.org/packages/l/linux-firmware/linux-firmware-20231110.74158e7a-1-any.pkg.tar.zst
tar --zstd -xf linux-firmware-20231110*.pkg.tar.zst usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst
SHA=$(sha256sum usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst | cut -d" " -f1)
[ "$SHA" = "$EXPECTED_SHA" ] || { echo "sha256 mismatch: $SHA"; exit 1; }

echo "[2/5] Installing the 2015 firmware blob..."
[ -f /usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst ] && \
  cp /usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst /root/43602-stock.bin.zst.bak
cp usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst /usr/lib/firmware/brcm/

echo "[3/5] Installing the NVRAM board file (gavin variant, boardflags3=0xC0000303)..."
curl -sfL -o nvram.txt https://raw.githubusercontent.com/gavinmclelland/omarchy-macbookpro14-3/HEAD/firmware/brcm/brcmfmac43602-pcie.txt
grep -q "boardflags3=0xC0000303" nvram.txt || echo "  note: boardflags3 differs from the verified variant - continuing"
sed -i "s/^macaddr=.*/macaddr=${MAC}/" nvram.txt
cp nvram.txt /usr/lib/firmware/brcm/brcmfmac43602-pcie.txt
cp nvram.txt "/usr/lib/firmware/brcm/brcmfmac43602-pcie.Apple Inc.-MacBookPro14,3.txt"

echo "[4/5] Checking the Apple WPA handshake quirk..."
if ! grep -qs "feature_disable" /etc/modprobe.d/*.conf; then
  printf "# Broadcom firmware supplicant fails WPA4way on Apple hw; let wpa_supplicant do it.\noptions brcmfmac feature_disable=0x82000\n" \
    > /etc/modprobe.d/brcmfmac.conf
fi

echo "[5/5] Pinning linux-firmware so updates cannot re-break the blob..."
if ! grep -q "^IgnorePkg.*linux-firmware" /etc/pacman.conf; then
  printf "\nIgnorePkg = linux-firmware\n" >> /etc/pacman.conf
fi

echo
echo "Done. REBOOT, then verify:"
echo "  ip -br link | grep wlp      # wlp3s0 UP with your real MAC"
echo "  nmcli device wifi list      # expect 2.4 AND 5 GHz APs"
echo "Benign dmesg noise: 'clm_blob ... err=-2', 'fail to get arp ip table err:-52'."
