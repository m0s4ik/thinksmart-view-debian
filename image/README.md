# Building the system image

`build.sh` builds the image of the ThinkSmart View's `system` partition: **Debian 13 trixie arm64, minimal**, with
the frozen postmarketOS kernel 7.1.3-msm8953, working audio (speaker and microphones), Wi-Fi and ssh. It never touches
the device; flashing is described in [docs/flashing.md](../docs/flashing.md). Your application goes on top, either
built into the image with a [customization script](#customization) or installed later over ssh.

## Requirements

- A Debian or Ubuntu machine (x86_64 or arm64; a VM or container with loop devices works), root, ~10 GB free in
  `WORK_DIR` for the build itself. The host packages `build.sh` needs (`debootstrap qemu-user-static binfmt-support
  pigz python3 fdisk e2fsprogs`) are installed by `build.sh` if missing; the build dependencies of `build-mesa.sh`
  and of the driver are not (install them by hand, see their own instructions).
- The device files in `image/parts/` ([docs/kernel.md](../docs/kernel.md)): `boot.tar`, `modules-7.1.3-msm8953.tar`,
  `firmware.tar`, `ucm.tar` (with `fetch-parts.sh` from a device running postmarketOS 7.1.3),
  `snd-soc-tas5782m.ko` ([driver/tas5782m](../driver/tas5782m/README.md)) and
  `mesa-freedreno-<version>-aarch64.tar.gz` (with `build-mesa.sh`, dependencies at the top of the script).
  Optional: `vcnl4000.ko` ([driver/vcnl4000](../driver/vcnl4000/README.md)).

## Build

```bash
cp image/config.env.example image/config.env
chmod 600 image/config.env
$EDITOR image/config.env          # Wi-Fi, ssh key, time zone, firewall, ...
sudo ./image/build.sh image/config.env
```

About 10 minutes (apt runs under qemu). Output in `$WORK_DIR/out/`: `thinksmart-debian-YYYYMMDD.img` (sparse, 6.8 GB
apparent), `.img.gz` and `.sha256`. The chroot is rebuilt from scratch every time; `.deb` files are cached in
`$WORK_DIR/cache/`, together with the identities that stay the same across builds (partition UUIDs, `machine-id`, ssh
host keys, so your ssh client does not complain after a reflash) as long as you keep that directory.

**The image contains your Wi-Fi PSK, the root password hash and the ssh host keys**: do not share it.

| File | What it does |
|---|---|
| `build.sh` | debootstrap, packages, configuration, kernel/modules/firmware/UCM, services, optional customization, image (sfdisk, loop, mkfs, copy), `verify.sh`, compressed copy. A trap unmounts everything if it stops halfway |
| `verify.sh` | read-only checks of the finished image (see below) |
| `fetch-parts.sh` | copies kernel, initramfs, DTBs, modules, firmware and UCM from a device running postmarketOS 7.1.3 |
| `build-wpe.sh` | optional: backports WPE WebKit 2.54 to Debian 13 in a Docker container on a fast arm64 machine (for a web view; not in the image yet) |
| `config.env.example` | all settings, with comments |
| `rootfs/` | files copied as they are into the image (`*.in` are templates) |

## What is in the image

Debian `minbase` with systemd, NetworkManager, OpenSSH, nftables, ALSA (with the ThinkSmart UCM profile), Python 3
with venv, DejaVu fonts, a reduced Mesa for the GPU (`/opt/mesa-freedreno`); the kernel, modules (including `snd-soc-tas5782m`), firmware and `msm-firmware-loader`.
Details in [docs/boot.md](../docs/boot.md).

- **Audio**: `thinksmart-audio.service` sets up the card at boot. `default` plays on the speaker (volume on the
  amplifier: `amixer -c 0 sset 'Speaker Amp Master' 70`, 0-85) and records from the two microphones; `aplay`/`arecord` work without options.
- **Network**: one Wi-Fi profile from `config.env`; firewall open only to `LAN_TCP_PORTS` (default 22) from your LAN.
- **Access**: `ssh root@<device>` with your key; optional root password for a login on the screen with a USB keyboard.

## Customization

Set `CUSTOMIZE=/path/to/script.sh` in `config.env` to add an application to the image. The script is **sourced** by
`build.sh` after the system is set up, with the chroot mounted and the network available. It can use:

| Name | What |
|---|---|
| `$R` | root of the image being built |
| `in_chroot <command>` | runs a command inside the image (arm64, through qemu: slow for pip) |
| `install_file SRC DEST` | copies a file, keeping the executable bit |
| `step "title"` | prints a section title in the build log |
| `$C` | cache directory, kept between builds (downloads) |
| config variables | everything in `config.env`, including your own variables |

Example:

```bash
# my-app.sh
step "my application"
in_chroot apt-get install -y -q --no-install-recommends python3-pil
install_file my-app/app.py "$R/opt/my-app/app.py"
install_file my-app/my-app.service "$R/etc/systemd/system/my-app.service"
in_chroot systemctl enable my-app
```

`/etc/thinksmart-version` in the image records which script was used (`customization: <name>`).

## What `verify.sh` checks

Size and MBR; p1 features (lk2nd); `e2fsck -fn` of both partitions; UUIDs in `extlinux.conf` and `fstab`; `/boot`
with `nofail`; `dmsetup` and the device-mapper udev rules (`udevadm verify`); `systemd-gpt-auto-generator` disabled;
no unit requires `local-fs.target` or `/boot`; a **test device-mapper on p1** run through `udevadm test --action=add`
in a mount namespace with the image's rules and an empty `/run/udev` (it must get `/dev/disk/by-uuid/<p1>` and not
`SYSTEMD_READY=0`); the image's own `systemd-fstab-generator` (through qemu); kernel, initramfs, DTBs; `modules.dep`
(TAS5782M, ath10k, accelerometer); firmware; UCM; enabled and masked services; keys, Wi-Fi profile (without printing
the PSK), `nft -c`; inside the image: Python with venv and the ALSA pcms `speaker` and `default`.

## After the first boot

- `ssh root@<device>`; versions in `/etc/thinksmart-version`.
- Volume at boot: `/etc/default/thinksmart-audio` (or write the percent to `/var/lib/thinksmart/volume`).
- `apt upgrade` is fine: Debian packages do not touch `/boot` or the 7.1.3 modules.
