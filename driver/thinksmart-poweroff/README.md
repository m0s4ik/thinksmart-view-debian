# Staying off after `poweroff` (experimental, not tested on the device yet)

The ThinkSmart View has **no battery and no power button**. With the power supply plugged in, `poweroff` switches it
off and it starts again by itself about 25 seconds later. This module is meant to keep it off until the supply is
unplugged. **It has not been tested on the device yet** (see "Status"), so it is not in the image.

## Why the device comes back

Read on a running device (PM8953 PON block at 0x800, `compatible = "qcom,pm8916-pon"`, through
`/sys/kernel/debug/regmap/0-00/registers`):

| Register | Value | Meaning |
|---|---|---|
| `0x880` PON_TRIGGER_EN | `0xfe` | power-on triggers enabled, including CBLPWR_N (bit 6, cable power) and PON1 (bit 5, from the charger PMIC) |
| `0x80c` POFF_REASON1 | `0x02` | the last power off came from PS_HOLD dropping, as expected for `poweroff` |
| `0x808` PON_REASON1 after `poweroff` | `0x60` | started again by CBLPWR_N + PON1: the supply is still there |
| `0x808` PON_REASON1 after `reboot` | `0x61` | the same plus hard reset |

So `poweroff` is a real power off (mainline's `pm8941-pwrkey` already sets the PS_HOLD reset type to "shutdown" on
power off, through its `resin` instance), and the PMIC starts again because the supply that powers it also counts as
a power-on event. With a battery, CBLPWR_N would only fire when a charger is plugged in; here it is always there.

Qualcomm's downstream kernel has a device tree switch for boards without a battery, `qcom,pon-reset-off`, which clears
CBLPWR_N in PON_TRIGGER_EN at probe time. No other ThinkSmart View project we know of changes this: one documents
`systemctl halt` and then unplugging.

## What the module does

It registers a `POWER_OFF_PREPARE` handler that clears CBLPWR_N and PON1 in PON_TRIGGER_EN just before power off.
Reboot is not affected. When the supply is unplugged both PMICs lose all power and start again with their default
triggers, so plugging the supply back in should power the device on as usual. One sign that the PMIC really loses
everything when unplugged: its RTC (on the always-on domain) counts from 1970 again after every unplug, but keeps
counting across `poweroff` and `reboot`.

The risk, if that assumption were wrong, is a device that does not power on when plugged in, and EDL would not help
(EDL also needs the device to power on). Wait at least 30 seconds before plugging back in either way: a PMIC that has
not fully discharged may not start.

## Status

- Built and loaded on the device (`insmod`), not installed.
- Not tested yet: `poweroff` with the module loaded, then unplug and plug back in.

Until it is tested, switch the device off with `systemctl halt`: the CPUs stop and the screen goes black, the PMIC
stays on and nothing restarts. Then unplug the supply.

## Building

Same toolchain, kernel source and `.config` as the speaker driver: follow steps 1-3 of
[driver/tas5782m/README.md](../tas5782m/README.md#building-for-the-postmarketos-713-kernel) (kernel source in
`/tmp/linux-7.1.3`), then, from the root of this repository:

```sh
make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/thinksmart-poweroff" modules
/sbin/modinfo driver/thinksmart-poweroff/thinksmart-poweroff.ko   # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"
```

To try it on a running device: `insmod thinksmart-poweroff.ko` (the kernel log says "power off stays off until the
supply is unplugged"), then `poweroff`. `rmmod thinksmart_poweroff` undoes it.
