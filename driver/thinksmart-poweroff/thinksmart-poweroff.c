// SPDX-License-Identifier: GPL-2.0-only
// SPDX-FileCopyrightText: 2026 Andrea Mattera
/*
 * thinksmart-poweroff: make "poweroff" keep the Lenovo ThinkSmart View off instead of starting it again.
 *
 * On power off mainline already sets the PMIC (PM8953, PON block "qcom,pm8916-pon") to shut down when PS_HOLD
 * drops (pm8941-pwrkey, through its resin instance). But the device has no battery and no power button: with the
 * power supply plugged in, the PON triggers CBLPWR_N (cable power) and PON1 (from the charger PMIC) are still
 * asserted, so the PMIC powers straight back on (PON_REASON1 = 0x60). This module clears those two triggers in a
 * POWER_OFF_PREPARE handler, like Qualcomm's "qcom,pon-reset-off" does at probe. Reboot is not affected.
 * Unplugging removes all power from both PMICs, which then start again with their default triggers: plugging the
 * supply back in powers the device on as usual.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/reboot.h>
#include <linux/regmap.h>

#define PON_TRIGGER_EN		0x80
#define PON_TRIGGER_CBLPWR_N	BIT(6)
#define PON_TRIGGER_PON1	BIT(5)

static struct regmap *pon_regmap;
static u32 pon_base;
static struct sys_off_handler *handler;

static int thinksmart_poweroff_prepare(struct sys_off_data *data)
{
	int ret;

	ret = regmap_update_bits(pon_regmap, pon_base + PON_TRIGGER_EN,
				 PON_TRIGGER_CBLPWR_N | PON_TRIGGER_PON1, 0);
	if (ret)
		pr_err("thinksmart-poweroff: cannot clear the cable power-on triggers: %d\n", ret);
	return NOTIFY_DONE;
}

static int __init thinksmart_poweroff_init(void)
{
	struct platform_device *pdev;
	struct device_node *np;
	int ret;

	np = of_find_compatible_node(NULL, NULL, "qcom,pm8916-pon");
	if (!np)
		return -ENODEV;
	ret = of_property_read_u32(np, "reg", &pon_base);
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (ret || !pdev)
		return ret ? ret : -EPROBE_DEFER;

	pon_regmap = dev_get_regmap(pdev->dev.parent, NULL);
	put_device(&pdev->dev);
	if (!pon_regmap)
		return -ENODEV;

	handler = register_sys_off_handler(SYS_OFF_MODE_POWER_OFF_PREPARE, SYS_OFF_PRIO_DEFAULT,
					   thinksmart_poweroff_prepare, NULL);
	if (IS_ERR(handler))
		return PTR_ERR(handler);

	pr_info("thinksmart-poweroff: PON at 0x%x, power off stays off until the supply is unplugged\n", pon_base);
	return 0;
}

static void __exit thinksmart_poweroff_exit(void)
{
	unregister_sys_off_handler(handler);
}

module_init(thinksmart_poweroff_init);
module_exit(thinksmart_poweroff_exit);

MODULE_DESCRIPTION("Lenovo ThinkSmart View: stay off after power off");
MODULE_AUTHOR("Andrea Mattera");
MODULE_LICENSE("GPL");
