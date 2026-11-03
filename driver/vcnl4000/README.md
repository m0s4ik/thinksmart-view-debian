# VCNL4200 light / proximity sensor module

The ThinkSmart View has a **Vishay VCNL4200** ambient light and proximity sensor at address 0x51 on the sensor I²C
bus (`/sys/devices/platform/i2c-sensors/i2c-*`, the same bus as the BMA253 accelerometer). The upstream kernel
driver `vcnl4000` supports it, but the postmarketOS kernel is built without it (`# CONFIG_VCNL4000 is not set`) and
the postmarketOS device tree has no node for it. So:

- the module is built **out of tree** from the unchanged upstream source of the 7.1.3 kernel
  (`drivers/iio/light/vcnl4000.c`, GPL-2.0, not copied into this repository);
- at boot `thinksmart-light.service` ([`image/rootfs/usr/local/sbin/thinksmart-light`](../../image/rootfs/usr/local/sbin/thinksmart-light))
  loads it and declares the chip with `echo vcnl4200 0x51 > .../new_device`.

The sensor then appears as an IIO device named `vcnl4000`:

```sh
d=$(grep -l '^vcnl4000$' /sys/bus/iio/devices/iio:device*/name | xargs dirname)
cat $d/in_illuminance_raw $d/in_illuminance_scale    # lux = raw x scale
```

**Light works; proximity reads 0.** The infrared LED of the proximity part has its own supply (`vled`), which the
Lenovo device tree turns on and the postmarketOS one does not know about, so the driver uses a dummy regulator and
the LED stays dark. See [docs/known-issues.md](../../docs/known-issues.md).

## Building

Same toolchain, kernel source and `.config` as the speaker driver: follow steps 1-3 of
[driver/tas5782m/README.md](../tas5782m/README.md#building-for-the-postmarketos-713-kernel) (kernel source in
`/tmp/linux-7.1.3`), then, from the root of this repository:

```sh
cp /tmp/linux-7.1.3/drivers/iio/light/vcnl4000.c driver/vcnl4000/
make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/vcnl4000" modules
/sbin/modinfo driver/vcnl4000/vcnl4000.ko       # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"
cp driver/vcnl4000/vcnl4000.ko image/parts/
```

`image/build.sh` installs `image/parts/vcnl4000.ko` in `/usr/lib/modules/7.1.3-msm8953/extra/` when it is there; it
is optional (without it the image builds and the service only logs that the module is missing). The CI builds it
too (artifact `vcnl4000-7.1.3-msm8953`).

On a running device: copy the module to `/usr/lib/modules/$(uname -r)/extra/`, `depmod -a`, then
`systemctl restart thinksmart-light`.
