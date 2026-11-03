# Installation guide

From a sealed ThinkSmart View to Debian with audio, Wi-Fi and ssh, step by step. Plan an afternoon: most of the time
is waiting (backup ~10 min, image build ~10 min, flashing ~5 min).

There is **no ready-made image to download**: the image contains your Wi-Fi password and ssh keys, and the kernel,
firmware and modules come from postmarketOS and from your own device. You build it yourself with one script.

> Everything below rewrites the eMMC of the device. Do the full backup in step 2 first: it is the only way back to
> the original Lenovo firmware.

## What you need

- A **Lenovo ThinkSmart View CD-18781Y** with its power supply. Tested on the Himax panel variant; the FT8201 variant
  needs a different device tree (see [hardware.md](hardware.md)).
- A **USB-A to USB-C cable** (the device's USB-C port has no CC resistors: a plain C-to-C cable is often not seen).
- A **Linux machine** (Debian/Ubuntu, x86_64 or arm64; a VM with loop devices is fine) with root and **~20 GB
  free**: ~8 GB for the EDL backup, up to ~10 GB for the image build in `WORK_DIR`, ~2 GB for the kernel source and
  the Mesa build. EDL also works from macOS.

## 1. Tools

```bash
git clone https://github.com/m0s4ik/thinksmart-view-linux.git
cd thinksmart-view-linux
python3 -m venv ~/edl-venv && ~/edl-venv/bin/pip install git+https://github.com/bkerler/edl
```

On Linux, `edl` needs raw access to the USB device: install the udev rules shipped with
[bkerler/edl](https://github.com/bkerler/edl) or run it with `sudo`, and stop ModemManager
(`sudo systemctl stop ModemManager`), which otherwise grabs the device.

From [rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart) download `prebuilt/lk2nd.img`, the
postmarketOS bootstrap image and `apply-ubuntu-gpt.sh`. Decompress the bootstrap image first if it is compressed,
and rename it to `bootstrap.img`.

## 2. Backup over EDL

Put the device in EDL mode: unplug the power, hold **Vol+ and Vol−**, plug the power back in, release after 5-10 s
(the screen stays black). Then:

```bash
~/edl-venv/bin/edl rf stock-full-emmc.bin
~/edl-venv/bin/edl printgpt > gpt-original.txt
```

Check that `stock-full-emmc.bin` is **7,818,182,656 bytes** (a full disk truncates it silently). Keep it safe.

## 3. lk2nd and the postmarketOS bootstrap

The bootstrap has no Wi-Fi profile and the device has no keyboard, so **prepare `bootstrap.img` on the build machine
before flashing it** (details in [kernel.md](kernel.md), "Getting them"). Its user is `pmos` (rickx's image; its
password, needed for `doas`, is in rickx's README). Write a NetworkManager
keyfile `wifi.nmconnection`:

```ini
[connection]
id=wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=YOUR_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=YOUR_WIFI_PASSWORD

[ipv4]
method=auto

[ipv6]
method=auto
```

Then put it, a machine-id and your public key into the root partition (the second one) of the image:

```bash
LOOP=$(sudo losetup -P --show -f bootstrap.img)
sudo mount "${LOOP}p2" /mnt
sudo install -m 600 wifi.nmconnection /mnt/etc/NetworkManager/system-connections/
cat /proc/sys/kernel/random/uuid | tr -d - | sudo tee /mnt/etc/machine-id   # empty in the image
sudo install -d -m 700 /mnt/home/pmos/.ssh
sudo install -m 600 ~/.ssh/id_ed25519.pub /mnt/home/pmos/.ssh/authorized_keys
sudo chown -R --reference=/mnt/home/pmos /mnt/home/pmos/.ssh
sudo umount /mnt && sudo losetup -d "$LOOP"
```

`ls /mnt/home` shows the user if a newer bootstrap uses another name. Then, in EDL mode:

```bash
~/edl-venv/bin/edl w boot lk2nd.img
~/edl-venv/bin/edl w system bootstrap.img
~/edl-venv/bin/edl reset
```

The bootstrap is only needed to get the kernel 7.1.3 files (step 4). Android will not boot any more.

## 4. Kernel, firmware and the speaker driver

The bootstrap joins your Wi-Fi: find the device's IP address in your router and log in with `ssh pmos@<device-ip>`.
Upgrade its kernel to 7.1.3 as in [kernel.md](kernel.md) ("Getting them", step 3), reboot, then from the build
machine:

```bash
./image/fetch-parts.sh pmos@<device-ip>
```

Build `snd-soc-tas5782m.ko` as described in [driver/tas5782m/README.md](../driver/tas5782m/README.md) and copy it to
`image/parts/` (optional: `vcnl4000.ko` for the light sensor, [driver/vcnl4000/README.md](../driver/vcnl4000/README.md)).

## 5. Mesa for the GPU

The image uses a reduced Mesa (freedreno only, no LLVM) built by a script. Install its build dependencies once, as
root (cross build on x86_64; the list is also at the top of the script):

```bash
sudo dpkg --add-architecture arm64 && sudo apt update
sudo apt install --no-install-recommends ca-certificates curl xz-utils binutils meson ninja-build \
  python3-mako python3-yaml python3-packaging bison flex gcc-aarch64-linux-gnu g++-aarch64-linux-gnu pkg-config \
  libdrm-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 libexpat1-dev:arm64
./image/build-mesa.sh        # as a normal user, ~5 min
```

It writes `image/parts/mesa-freedreno-<version>-aarch64.tar.gz`. You now have six files in `image/parts/`
(`boot.tar`, `modules-7.1.3-msm8953.tar`, `firmware.tar`, `ucm.tar`, `snd-soc-tas5782m.ko` and the Mesa tarball,
plus the optional `vcnl4000.ko`); you never need the bootstrap again.

## 6. Build the image

```bash
cp image/config.env.example image/config.env
chmod 600 image/config.env
nano image/config.env
```

Set at least `WIFI_SSID`, `WIFI_PSK`, `WIFI_COUNTRY`, `TIMEZONE`, `SSH_AUTHORIZED_KEYS_FILE` (absolute path such
as `/home/YOU/.ssh/id_ed25519.pub`: under `sudo`, `$HOME` is root's) and `LAN_V4` (your home network). Optional: `LAN_TCP_PORTS` (ports of your application),
`ROOT_PASSWORD` (login on the screen with a USB keyboard), `CUSTOMIZE` (a script that adds your application, see
[image/README.md](../image/README.md#customization)).

```bash
sudo ./image/build.sh image/config.env
```

It ends with `VERIFY OK` and the image in `/var/tmp/thinksmart-build/out/thinksmart-debian-YYYYMMDD.img`.

## 7. Repartition and flash

With the device in EDL mode, run rickx's `apply-ubuntu-gpt.sh` as documented in his repository: it enlarges
`system` to the end of the eMMC. Check the new size (`edl printgpt`): it must equal `SYSTEM_SECTORS` of your
`config.env` (14280671 on our device). If it differs, set `SYSTEM_SECTORS` to your value and build again (step 6)
before flashing. Then:

```bash
~/edl-venv/bin/edl w system /var/tmp/thinksmart-build/out/thinksmart-debian-YYYYMMDD.img
~/edl-venv/bin/edl reset
```

After ~30 s the device joins your Wi-Fi (the screen shows the login prompt). Find its address in your router
(hostname from `DEVICE_HOSTNAME`) and log in: `ssh root@<device-ip>`. Tip: give it a fixed address in the router
(set `WIFI_MAC` in `config.env` if you want a stable MAC).

## 8. Check the hardware

```bash
speaker-test -c 2 -t sine -l 1          # a tone from the speaker
amixer -c 0 sset 'Speaker Amp Master' 70   # volume: 0-85, 85 = 0 dB, 1 dB per step
arecord -d 5 -f S16_LE -r 16000 -c 2 /tmp/mic.wav && aplay /tmp/mic.wav
cat /sys/bus/iio/devices/iio:device0/in_accel_y_raw   # accelerometer
evtest                                  # touch and volume keys (apt install evtest)
```

## Everyday use and updates

| What | How |
|---|---|
| Speaker volume | `amixer -c 0 sset 'Speaker Amp Master' N` (0-85); at boot, in percent, from `/var/lib/thinksmart/volume` or `/etc/default/thinksmart-audio` |
| Screen brightness | `/sys/class/backlight/backlight/brightness` (0-4095) |
| Update Debian | `apt update && apt upgrade` (kernel and modules are untouched) |
| Rebuild everything | `sudo ./image/build.sh image/config.env` and flash again (step 7, no repartitioning): the ssh host keys stay the same as long as you keep the same `WORK_DIR` (they live in its `cache/`) |
| Logs | `journalctl -b`, audio: `journalctl -u thinksmart-audio` |

## If something goes wrong

- **No sound, or no microphone**: `journalctl -u thinksmart-audio`; the card `cd-18781y` must be in `aplay -l`
  (needs `snd-soc-tas5782m`).
- **No network**: check the Wi-Fi profile in `config.env`; with a USB keyboard and `ROOT_PASSWORD` you can log in on
  the screen and run `nmcli`.
- **It does not boot**: see "Going back" in [flashing.md](flashing.md); the original firmware is always one
  `edl wf stock-full-emmc.bin` away.
- More in [known-issues.md](known-issues.md).
