# Omarchy on the 2017 MacBook Pro 15" (A1707 / MacBookPro14,3) — Repair Runbook

**Omarchy/Arch on the 15" 2017 Touch Bar MacBook Pro (MacBookPro14,3, T1 chip).**

| Problem | Root cause | Fix lives in |
|---|---|---|
| Wi-Fi never creates an interface (`brcmfmac` crashes, no `wlan0`, ever) | **Two independent causes on this machine:** a non-stock/corrupt `brcmfmac43602` blob in the field (chip never POSTs), plus a missing NVRAM board file with the machine's *real* MAC (`cur_etheraddr failed, -5`) | [`scripts/fix-wifi-43602.sh`](scripts/fix-wifi-43602.sh) |
| Touch Bar dark on *some boots*, "worked yesterday, dead today", zero error messages | Overlay **hardcodes HID instance numbers** (`.0001/.0002`) that are actually registration *order* and shift boot to boot — also independently found upstream in [PR #26](https://github.com/gavinmclelland/omarchy-macbookpro14-3/pull/26) (farkas), which covers 1 of the 3 hardcoded locations; this fix covers all three | [`scripts/fix-touchbar-instances.sh`](scripts/fix-touchbar-instances.sh) |

Verified 2026-09-26 on kernel `7.2.5-3-omarchy` through cold-reboot persistence tests
(symptoms reproduced identically on `linux-lts` 6.18 — not a kernel regression).

> **Correction notice (2026-09-26):** an earlier version of this runbook claimed the
> 2015-vintage firmware blob was required and newer blobs "can't POST the rev-02 chip."
> That was wrong — a compressed-container hash was mistaken for a content hash. Every
> official `linux-firmware-broadcom` package from 2023 through 2026 ships the **identical**
> blob (`bf4cfc23…` uncompressed; Broadcom hasn't touched it since 2015). What this machine
> actually had was a **non-stock/corrupt blob** (`7f735b72…`) — which proves field corruption
> happens, and makes "verify against `bf4cfc23…` first" the correct triage step. Thanks to
> the independent review that caught this and to farkas for PR #26. See issue
> [#31](https://github.com/gavinmclelland/omarchy-macbookpro14-3/issues/31) for the full record.

---

## TL;DR

```bash
git clone https://github.com/elmapache1620/mbp2017-a1707-omarchy && cd mbp2017-a1707-omarchy
# 1. overlay first (if not installed): https://github.com/gavinmclelland/omarchy-macbookpro14-3
sudo ./scripts/fix-wifi-43602.sh <REAL_WIFI_MAC>      # macOS: System Info -> Network -> Wi-Fi
sudo ./scripts/fix-touchbar-instances.sh
sudo reboot
```

Verify after reboot:

```bash
ip -br link | grep wlp                                        # wlp3s0 UP, real MAC
nmcli device wifi list | head                                 # 2.4 AND 5 GHz visible
systemctl is-active touchbar.service touchbar-fn.service      # active, active
journalctl -b -u touchbar.service --no-pager | tail -3        # "Finished Enable the Apple T1 Touch Bar"
```

---

## Wi-Fi: the long version

**Symptoms.** No wireless interface ever appears. dmesg shows `brcmf_pcie_download_fw_nvram: FW failed to initialize`, or — after trying older firmware — `Timeout on response for query command` / `brcmf_c_preinit_dcmds: Retrieving cur_etheraddr failed, -5`.

**What it is NOT** (all eliminated with evidence during the debug — don't retest):
rfkill/airplane, PCIe power state (D0), driver reload, `brcmfmac_wcc` (no WCC ACPI device exists on T1 Macs), `feature_disable` quirks, ASPM L1, kernel regression (LTS kernels fail identically), PRAM/EC resets, dead hardware (**the card works perfectly in macOS** — the tell that this is firmware/board-file, not hardware), and — for the record — *firmware vintage*: there is only one official 43602 blob content, so "old blob vs new blob" can never be the axis (see correction notice).

**Root cause (two independent causes; both were live on this machine).**

1. **Field-corrupted firmware blob.** The machine's installed `brcmfmac43602-pcie.bin` hashed (uncompressed) `7f735b72…` — content no official package ever shipped. A corrupt blob never completes chip POST. Official content is `bf4cfc23ee952a3d82ef33a0f5f87853201c98f1bed034876a910f354f37862d` in *every* `linux-firmware-broadcom` build 2023→2026 (all stamp the firmware ID `7.35.177.61 (r598657)`, dated 2015 — Broadcom hasn't touched this blob in a decade). **Triage rule: `zstd -dc /usr/lib/firmware/brcm/brcmfmac43602-pcie.bin.zst | sha256sum` and compare against `bf4cfc23…` before believing anything else.** (Caution: hash the *decompressed* content — `.zst` container hashes differ per compression run and prove nothing. This exact mistake produced an incorrect root cause in an earlier revision of this runbook.)
2. **NVRAM board file with a real MAC.** The chip requires a board file (`brcmfmac43602-pcie.txt`) carrying the machine's actual Wi-Fi MAC. The overlay's shipped template contains the placeholder `xx:xx:xx:xx:xx:xx`, and a placeholder/absent MAC produces `brcmf_c_preinit_dcmds: Retrieving cur_etheraddr failed, -5` + `Timeout on response for query command`. The kernel firmware loader searches `/usr/lib/firmware/updates/` first and requests the **board-specific filename** (`brcmfmac43602-pcie.Apple Inc.-MacBookPro14,3.txt`) before the generic one — so that DMI-named file with the real MAC is what actually gets loaded. Get the MAC from macOS: System Information → Network → Wi-Fi (OUI varies by unit — this machine's is `dc:a9:04`, others e.g. `8c:85:90`; never trust a guide's example MAC).

The script does: verify the blob against official content (reinstall via `pacman -S linux-firmware-broadcom --overwrite` if non-stock, backing the corrupt one up) → fetch the NVRAM template, patch the real MAC, install under both names in `updates/` **and** `brcm/` → ensure `feature_disable=0x82000` (separate Apple WPA-handshake quirk). No pacman pin: the blob content hasn't changed 2023→2026, and the blob is owned by `linux-firmware-broadcom` anyway, not the `linux-firmware` meta-package.

**Benign log noise with the old blob (ignore):** `no clm_blob available (err=-2)`, `fail to get arp ip table err:-52`.

**Fallback if `-5` timeout persists with a real MAC:** try the alternate NVRAM variant (`boardflags3=0x00000300`, from [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1)) — one-line change to the script. We didn't need it; the variant this repo uses worked.

## Touch Bar: the long version

**Symptoms.** Strip dark. `touchbar.service` shows `skipped, unmet condition check ConditionPathExistsGlob=/sys/bus/hid/devices/0003:05AC:8600.0001`. Nothing in dmesg. May work on some boots and not others, or "worked yesterday, dead today" — with zero errors anywhere.

**Root cause.** The HID device path `0003:05AC:8600.0001` ends in a **registration-order counter**, not a stable identity. Depending on how many other input devices (applespi keyboard, trackpad, keyd…) enumerate before the iBridge, the iBridge may get `.0001` — or `.0005`. The overlay hardcodes `.0001/.0002` in three places: the service condition, `touchbar-enable.sh`, and `touchbar-fn-watch.sh`. Wrong draw at boot → condition never fires → dark strip, no errors, looks like dead hardware.

**The fix** ([`scripts/fix-touchbar-instances.sh`](scripts/fix-touchbar-instances.sh)): a tiny `tb-find.sh` helper that globs for whichever `05AC:8600.*` device exposes `fnmode`, a dynamically-discovered `IBDEV` (the Touch Bar is consistently the *second* 8600 HID interface — the order is stable even when the prefix shifts), and a systemd drop-in wildcarding the condition. Reported upstream in issue #31 with the same content.

> ## ⚠️ The one rule that saves your machine
> **Never `modprobe apple_ibridge` by hand while debugging a dark strip.**
> Unpatched default `tb_mode` calls `usb_set_configuration()` under its own lock → re-enters → **self-deadlock**: unkillable D-state, frozen shutdown, forced power-off required. The modules are blacklisted at boot for exactly this reason. Always bring the Touch Bar up with the overlay's `touchbar-enable.sh` (it loads with `tb_mode_param=keyboard`, which side-steps the deadlock), or restart the service:
> ```bash
> sudo systemctl restart touchbar.service touchbar-fn.service
> ```

**Sanity check the T1 first:** its USB product ID must be `8600` (alive). `1281` means **recovery mode** — T1 firmware damaged on Apple's ESP, a different and deeper problem (see upstream repo notes; don't run any of this expecting it to help).

## Maintenance gotchas

- **Re-running the overlay's `install.sh` reverts the Touch Bar fix** (it redeploys the hardcoded-ID scripts; your `touchbar.service.d/` drop-in survives). It does **not** touch the firmware blob, modprobe config, or your board-specific NVRAM filename — the Wi-Fi fix is safe. Re-apply `fix-touchbar-instances.sh` after every overlay reinstall. (Ordinary kernel updates are fine — DKMS rebuilds the drivers automatically.)
- **No pacman pin is needed.** The blob content is stable 2023→2026, and it belongs to `linux-firmware-broadcom`, not `linux-firmware` — an `IgnorePkg = linux-firmware` line protects nothing. If you ever truly must override a packaged firmware file, `/usr/lib/firmware/updates/` is unowned by any package and searched first.
- **macOS dual-boot is safe** — separate partitions, macOS never touches the Linux-side fixes. But macOS updates / the "Startup Disk" pane can re-bless the macOS ESP as default boot (refix from Linux with `efibootmgr`), and a PRAM reset wipes EFI boot entries entirely. Clock handling: macOS keeps the hardware clock in UTC, so leave Linux at the default (`timedatectl set-local-rtc 0`); only set `1` if you dual-boot a Windows install.
- `macbook12-spi-driver-dkms` fails to build on every kernel (ancient upstream; mainline `applespi` covers the keyboard). Safe to remove; it's pure update noise.

## Repo layout

```
scripts/
  fix-wifi-43602.sh             # Wi-Fi blob + NVRAM + pacman pin (takes the real MAC)
  fix-touchbar-instances.sh     # dynamic HID discovery + condition glob
  tb-find.sh                    # the discovery helper, standalone
```

## Appendix: the no-overlay path

Everything here works without installing gavinmclelland/omarchy-macbookpro14-3 — relevant if you want a minimal-footprint install, or if the overlay changes shape later. Trade-offs first:

**What the overlay provides beyond this appendix:** the DKMS `apple-ibridge*` Touch Bar driver sources (T1 variant, adapted from the T2Linux project lineage), CS8409 audio codec work + PipeWire DSP, keyd Esc/Fn config, boot quirks (`pcie_ports=compat`, NVMe D3cold fix). **Wi-Fi needs none of it.**

### Wi-Fi — fully standalone
`scripts/fix-wifi-43602.sh` has no overlay dependency *except* where it curls the NVRAM template from the overlay repo. If you'd rather not pull from there at all, the board file's content requirement is simple: the BCM943602 board parameters (`boardtype=0x61b`, `boardflags3=0xC0000303`, `ccode=00`, `regrev=245`, `aa2g=7 aa5g=7 txchain=7 rxchain=7`, full TSSI/rssi calibration tables — the calibration data is the part you cannot author yourself; bugzilla.kernel.org attach 290569 is the original community source, currently behind a bot-wall, which is why link-at-runtime-to-a-git-mirror is the pragmatic move). Steps 1, 2, 4, 5 of the script (blob, backup, WPA quirk, pacman pin) run unchanged.

### Touch Bar — what standalone actually means
There is no mainline T1 Touch Bar driver; "no overlay" for the Touch Bar still means building out-of-tree `apple-ibridge` / `apple-ib-tb` / `apple-ib-als` modules (source: gavin's `drivers/appleibridge/`, itself derived from the T2Linux appleibridge work). The deadlock and interface-steal pitfalls (§Touch Bar) apply to *any* build of these drivers — they live in the driver, not the packaging. If you hand-build:

1. `make` in the driver dir against `uname -r` headers; `insmod` order: `apple-ibridge.ko tb_mode_param=keyboard`, then `apple-ib-tb.ko` — the `keyboard` parameter is **mandatory** or you get the self-deadlock.
2. Reclaim the Touch Bar interface (the *second* `05AC:8600.*` HID device — never hardcode the suffix) from `hid-generic`/`hid-sensor-hub`:
   ```bash
   DEV=$(basename $(ls -d /sys/bus/hid/devices/0003:05AC:8600.* | sed -n 2p))
   DRV=$(basename $(readlink -f /sys/bus/hid/devices/$DEV/driver))
   echo $DEV | sudo tee /sys/bus/hid/drivers/$DRV/unbind
   echo $DEV | sudo tee /sys/bus/hid/drivers/apple-ibridge-hid/bind
   ```
3. `tb-find.sh` in this repo is the instance-safe way to locate the controls (`fnmode`, `idle_timeout`, `dim_timeout`).
4. Blacklist the modules from early load (`modprobe.d`: `blacklist apple_ibridge`, `apple_ib_tb`, `apple_ib_als`) — early loading wedges boot the same way manual modprobe does. Load late, from a script, like the overlay's does.

### Bottom line
Skip the overlay for Wi-Fi freely — it adds nothing there. Keep it for Touch Bar/audio unless you enjoy maintaining an out-of-tree DKMS tree by hand; either way, apply `scripts/fix-touchbar-instances.sh` to whatever glue scripts you end up with, because the instance-numbering trap is universal.

## Credits / sources

- [farkas / PR #26](https://github.com/gavinmclelland/omarchy-macbookpro14-3/pull/26) (Sep 12, 2026) — independently discovered the Touch Bar HID-renumbering root cause and fixed `touchbar-enable.sh` with a by-driver discovery approach. Our fix covers the two locations #26 does not (the `touchbar.service` condition and `touchbar-fn-watch.sh`); the ideal merge is noted in [issue #31](https://github.com/gavinmclelland/omarchy-macbookpro14-3/issues/31).
- [gavinmclelland/omarchy-macbookpro14-3](https://github.com/gavinmclelland/omarchy-macbookpro14-3) — the platform overlay; our work patches *its* scripts. Issue: [#31](https://github.com/gavinmclelland/omarchy-macbookpro14-3/issues/31)
- [nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1) — base guide + alternate NVRAM variant
- Arch Linux package archive — the firmware blob bisect source of truth
- Debug methodology: two weeks of evidence-bisect over a paste-relay connection to a remote dual-boot machine — one variable per experiment, verdicts only on fresh boots. Plus an independent review after publication that caught our one wrong root cause — which is now corrected above, in public, with the lesson (hash content, not containers) folded into the triage steps.

## Disclaimer

You're modifying firmware files and input-device drivers on someone's laptop. Read every script before you run it. Both scripts keep backups and fail loudly on checksum mismatch. None of it bricks anything: worst case is a non-working Wi-Fi/Touch Bar until you restore the backed-up files. macOS is unaffected throughout.
