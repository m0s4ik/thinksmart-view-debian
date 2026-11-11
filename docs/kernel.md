# Kernel, initramfs, firmware: the device files

The image uses the **postmarketOS kernel package `linux-postmarketos-qcom-msm8953` 7.1.3** (built from
[msm8953-mainline/linux](https://github.com/msm8953-mainline/linux), tag `v7.1.3-r0`), its **initramfs**, the
firmware and the UCM profile of postmarketOS, unchanged. The kernel is **frozen**: Debian packages never touch
`/boot` or `/usr/lib/modules/7.1.3-msm8953`.

None of these binaries are in this repository. `image/build.sh` expects them in `image/parts/`:

| File | Content |
|---|---|
| `boot.tar` | `/boot` of the device: `vmlinuz`, `initramfs`, `config`, `System.map`, flat DTBs (`apq8053-lenovo-cd-18781y.dtb`, the one lk2nd reads, and the other msm8953 ones) and `dtbs/qcom/…` |
| `modules-7.1.3-msm8953.tar` | `/usr/lib/modules/7.1.3-msm8953` |
| `firmware.tar` | `/lib/firmware` (ath10k QCA9379, Adreno a530/a506 zap, TAS5782M DSP, `regulatory.db`, …) |
| `ucm.tar` | UCM profile of the ThinkSmart: `conf.d/cd-18781y`, `Lenovo/cd-18781y`, `codecs/msm8953-wcd` |
| `snd-soc-tas5782m.ko` | the speaker driver built for this kernel ([driver/tas5782m/README.md](../driver/tas5782m/README.md)) |
| `vcnl4000.ko` | optional: the light sensor driver built for this kernel ([driver/vcnl4000/README.md](../driver/vcnl4000/README.md)) |
| `venus-core.ko` | optional: the video decoder core rebuilt with the mainline HFI parser ([driver/venus/README.md](../driver/venus/README.md)); replaces the kernel package's one |
| `s5kc505a.ko`, `apq8053-lenovo-cd-18781y-camera.dtb` | optional, only for the front camera (`CAMERA=1`): the sensor driver and the patched DTB ([driver/s5kc505a/README.md](../driver/s5kc505a/README.md)); CI builds both |
| `mesa-freedreno_<version>_arm64.deb` | reduced Mesa for the GPU (freedreno only, EGL, GBM, OpenGL ES, Wayland platform, no LLVM, ~22 MB installed), built by `image/build-mesa.sh` (see [Mesa](#mesa) below) |
| `libwpewebkit-2.0-1_*~bpo13+1_arm64.deb` (+ `-dev`, `wpewebkit-webdriver`) | optional, only for the web layer (`WEB=1`): WPE WebKit 2.54 backported from Debian forky to Debian 13 (Debian 13's 2.48 cannot use the GPU with Mesa 26), built by `image/build-wpe.sh` on a fast arm64 machine with Docker. The image installs only `libwpewebkit-2.0-1` |

The kernel package's DTB is used as it is. The DTS of msm8953-mainline `v7.1.3-r0` rebuilds it byte for byte
(`make … qcom/apq8053-lenovo-cd-18781y.dtb` with the `.config` above), which is how the optional camera DTB is made:
the same source with [driver/s5kc505a](../driver/s5kc505a/README.md)'s patch. Both DTBs' sha256 are pinned in
`driver/s5kc505a/dtb.sha256`: CI rebuilds and checks them, and `image/build.sh` with `CAMERA=1` installs the camera DTB
next to the original (and `s5kc505a.ko`) only if they match.

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
6. Build `snd-soc-tas5782m.ko` (and, optionally, `vcnl4000.ko` for the light sensor and `venus-core.ko` for the
   video decoder) and copy them to `image/parts/`.
7. Build the reduced Mesa: `./image/build-mesa.sh` (cross-compiles in ~10 minutes; dependencies at the top of the
   script). It writes `image/parts/mesa-freedreno_<version>_arm64.deb`.

The parts do not change between builds: you need the bootstrap only once.

Possible shortcut (not tried): the kernel, firmware and UCM packages are plain `.apk` (tar.gz) files on the
postmarketOS mirror; only the initramfs is generated on the device by `mkinitfs`.

## Mesa

Debian's Mesa pulls LLVM (~450 MB on disk) and drivers for every GPU. `image/build-mesa.sh` builds **Mesa
26.3.0** with only the freedreno Gallium driver, EGL, GBM and OpenGL ES, without LLVM, X11, Vulkan or video
acceleration, and packs it as `mesa-freedreno_26.3.0-1_arm64.deb`. The tarball's sha256 is pinned in the script
(checked against the release signature). The v0.3 release candidates shipped 26.3.0-rc3.

- **Wayland platform, always on**: WPE WebKit 2.54 (web layer) creates its EGL displays and buffers through it, also
  when drawing off screen. Cost: `libwayland-client0`, ~90 KB.
- **Under `/usr`**, built for `/usr/lib/aarch64-linux-gnu`: WebKit's bubblewrap sandbox does not expose `/opt`, and
  libgbm looks for its backend (`gbm/dri_gbm.so`) at the path it was built for. Earlier images had Mesa in
  `/opt/mesa-freedreno` with an `ld.so.conf.d` entry; that is gone.
- **libglvnd, as in Debian**: Debian's `libegl1`, `libgles2` and `libgl1` are libglvnd dispatchers, and other
  packages link against them (GStreamer's GL library, needed by WPE, links `libGL.so.1` and `libEGL.so.1`). Our Mesa
  is built with `-Dglvnd=enabled` and is the vendor behind them (`libEGL_mesa.so.0`,
  `/usr/share/glvnd/egl_vendor.d/50_mesa.json`). The dispatchers cost ~1 MB; the alternative, a non-glvnd
  `libEGL.so.1` posing as `libegl1`, would still need libglvnd's `libGL.so.1` for GStreamer, and mixing the two
  dispatch schemes in one process is fragile.
- **The package replaces Debian's Mesa**: `mesa-freedreno` provides `libgbm1` (with its own version, so WPE's
  `libgbm1 (>= 21.3)` is satisfied), `libegl-mesa0` and `libglx-mesa0` (there is no GLX: no X server on the device),
  and conflicts with `mesa-libgallium` and `libgl1-mesa-dri`. apt therefore never installs Debian's Mesa or LLVM next
  to it. A package that really needs them (for example `libgbm-dev`, which wants Debian's exact `libgbm1`) makes apt
  propose removing `mesa-freedreno` instead: see [known-issues.md](known-issues.md#gpu-and-web-layer).
- Mesa 26 bundles wayland-protocols 1.49, whose XML Debian 13's `wayland-scanner` (1.23) rejects in `--strict` mode:
  with a scanner older than 1.24 the script runs it through a small wrapper without `--strict` (found by meson
  through `PKG_CONFIG_PATH_FOR_BUILD`). The options `gallium-vdpau` and `gallium-xa` no longer exist in Mesa 26.
- freedreno has a GMEM tiling bug that browsers hit: see [known-issues.md](known-issues.md#gpu-and-web-layer).

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
- waits up to 10 s for `/dev/fb0`, which never comes (the panel driver is not in the initramfs), unless
  `deviceinfo_no_framebuffer=true` is on the kernel command line: the image puts it there since v0.4-rc2
  ([boot.md](boot.md#kernel-command-line)).

The kernel has everything systemd needs (cgroups, `FHANDLE`, `DEVTMPFS`, `AUTOFS`, seccomp, BPF).
