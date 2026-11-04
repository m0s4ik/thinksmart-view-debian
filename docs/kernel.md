# Kernel, initramfs, firmware: the device files

The image uses the **postmarketOS kernel package `linux-postmarketos-qcom-msm8953` 7.1.3** (built from
[msm8953-mainline/linux](https://github.com/msm8953-mainline/linux), tag `v7.1.3-r0`), its **initramfs**, the
firmware and the UCM profile of postmarketOS, unchanged. The kernel is **frozen**: Debian packages never touch
`/boot` or `/usr/lib/modules/7.1.3-msm8953`.

None of these binaries are in this repository. `image/build.sh` expects them in `image/parts/`:

| File | Content |
|---|---|
| `boot.tar` | `/boot` of the device: `vmlinuz`, `initramfs`, `config`, `System.map`, flat DTBs (`apq8053-lenovo-cd-18781y.dtb` and the other msm8953 ones) and `dtbs/qcom/…` |
| `modules-7.1.3-msm8953.tar` | `/usr/lib/modules/7.1.3-msm8953` |
| `firmware.tar` | `/lib/firmware` (ath10k QCA9379, Adreno a530/a506 zap, TAS5782M DSP, `regulatory.db`, …) |
| `ucm.tar` | UCM profile of the ThinkSmart: `conf.d/cd-18781y`, `Lenovo/cd-18781y`, `codecs/msm8953-wcd` |
| `snd-soc-tas5782m.ko` | the speaker driver built for this kernel ([driver/tas5782m/README.md](../driver/tas5782m/README.md)) |
| `vcnl4000.ko` | optional: the light sensor driver built for this kernel ([driver/vcnl4000/README.md](../driver/vcnl4000/README.md)) |
| `mesa-freedreno-<version>-aarch64.tar.gz` | reduced Mesa for the GPU (freedreno only, EGL, GBM, OpenGL ES, no LLVM, ~19 MB installed), built by `image/build-mesa.sh` |
| `libwpewebkit-2.0-1_*~bpo13+1_arm64.deb` (+ `-dev`, `wpewebkit-webdriver`) | optional, not used by `build.sh` yet: WPE WebKit 2.54 backported from Debian forky to Debian 13 for a web view on the device (Debian 13's 2.48 cannot use the GPU with Mesa 26), built by `image/build-wpe.sh` on a fast arm64 machine with Docker |

## Getting them (what we did)

1. Flash lk2nd and rickx's postmarketOS bootstrap ([flashing.md](flashing.md), step 2). The bootstrap of
   2026-05-22 ships kernel 6.12.
2. Get it on the network. The bootstrap has no Wi-Fi profile and no keyboard; we added one offline by loop-mounting
   the image on a Linux machine (`losetup -P`) and writing, inside the root partition:
   - a NetworkManager keyfile in `/etc/NetworkManager/system-connections/` (mode 0600);
   - a non-empty `/etc/machine-id` (it is empty in the image: dbus and NetworkManager do not start without it);
   - your public key in `~/.ssh/authorized_keys` of the default user (`pmos` on the bootstrap of 2026-05-22).

   The commands are in [install.md](install.md), step 3. Do this before flashing the bootstrap.
3. On the device, upgrade the kernel package: `doas apk upgrade linux-postmarketos-qcom-msm8953` (6.12 → 7.1.3).
   The bootstrap still has `/lib` separate from `/usr/lib`, so the new modules land in `/usr/lib/modules` and `depmod`
   fails: `doas ln -s /usr/lib/modules/7.1.3-msm8953 /lib/modules/7.1.3-msm8953 && doas depmod -a 7.1.3-msm8953`.
   lk2nd only handles **one** entry in `extlinux.conf` (it ignores `default`; the last entry's lines overwrite the
   first), so keep a copy of the old file to go back.
4. Reboot; screen, touch and Wi-Fi work on 7.1.3 with the Himax panel.
5. From the build machine: `./image/fetch-parts.sh user@device` copies the four tar files to `image/parts/`.
6. Build `snd-soc-tas5782m.ko` (and, optionally, `vcnl4000.ko` for the light sensor) and copy it to `image/parts/`.
7. Build the reduced Mesa: `./image/build-mesa.sh` (cross-compiles in ~5 minutes; dependencies at the top of the
   script). It writes `image/parts/mesa-freedreno-<version>-aarch64.tar.gz`. Debian's Mesa is not used because it
   pulls LLVM (~450 MB); do not install Debian's `libegl1`, `libgbm1` or `libgl1-mesa-dri` on the device next to it.

The parts do not change between builds: you need the bootstrap only once.

Possible shortcut (not tried): the kernel, firmware and UCM packages are plain `.apk` (tar.gz) files on the
postmarketOS mirror; only the initramfs is generated on the device by `mkinitfs`.

## How the postmarketOS initramfs boots Debian

The initramfs (postmarketOS 3.7.2, from the 7.1.3 package):

- runs `kpartx -afs` on the partition with two sub-partitions and finds boot and root by `pmos_boot_uuid` /
  `pmos_root_uuid` from the kernel command line (`build.sh` writes the same UUIDs in `extlinux.conf` and in the file
  systems; there is no fallback);
- runs `e2fsck -p`, grows p2 and the root file system if the partition is larger, mounts root, requires only
  `/etc/os-release` (a symlink to `/usr/lib/os-release` on Debian is fine) and `switch_root`s to `/sbin/init`
  (systemd);
- **does not move `/run`** into the new root: Debian starts without the initramfs udev database, which is why the
  image needs `54-dm-initramfs.rules` ([boot.md](boot.md));
- loads no modules (ext4, dm and mmc are built in);
- waits up to 10 s for `/dev/fb0`, which never comes (the panel driver is not in the initramfs): see
  [known-issues.md](known-issues.md).

The kernel has everything systemd needs (cgroups, `FHANDLE`, `DEVTMPFS`, `AUTOFS`, seccomp, BPF).
