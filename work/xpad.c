// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Xbox gamepad driver
 *
 * Copyright (c) 2002 Marko Friedemann <mfr@bmx-chemnitz.de>
 *               2004 Oliver Schwartz <Oliver.Schwartz@gmx.de>,
 *                    Steven Toth <steve@toth.demon.co.uk>,
 *                    Franz Lehner <franz@caos.at>,
 *                    Ivan Hawkes <blackhawk@ivanhawkes.com>
 *               2005 Dominic Cerquetti <binary1230@yahoo.com>
 *               2006 Adam Buchbinder <adam.buchbinder@gmail.com>
 *               2007 Jan Kratochvil <honza@jikos.cz>
 *               2010 Christoph Fritz <chf.fritz@googlemail.com>
 *
 * This driver is based on:
 *  - information from     http://euc.jp/periphs/xbox-controller.ja.html
 *  - the iForce driver    drivers/char/joystick/iforce.c
 *  - the skeleton-driver  drivers/usb/usb-skeleton.c
 *  - Xbox 360 information http://www.free60.org/wiki/Gamepad
 *  - Xbox One information https://github.com/quantus/xbox-one-controller-protocol
 *
 * Thanks to:
 *  - ITO Takayuki for providing essential xpad information on his website
 *  - Vojtech Pavlik     - iforce driver / input subsystem
 *  - Greg Kroah-Hartman - usb-skeleton driver
 *  - Xbox Linux project - extra USB IDs
 *  - Pekka Pöyry (quantus) - Xbox One controller reverse-engineering
 */

#include <linux/bits.h>
#include <linux/kernel.h>
#include <linux/input.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/stat.h>
#include <linux/module.h>
#include <linux/usb/input.h>
#include <linux/usb/quirks.h>

#define XPAD_PKT_LEN 64

/*
 * xbox d-pads should map to buttons, as is required for DDR pads
 * but we map them to axes when possible to simplify things
 */
#define MAP_DPAD_TO_BUTTONS		BIT(0)
#define MAP_TRIGGERS_TO_BUTTONS		BIT(1)
#define MAP_STICKS_TO_NULL		BIT(2)
#define MAP_SHARE_BUTTON		BIT(3)
#define MAP_PADDLES			BIT(4)
#define MAP_PROFILE_BUTTON		BIT(5)
#define MAP_SHARE_OFFSET		BIT(6)

#define DANCEPAD_MAP_CONFIG	(MAP_DPAD_TO_BUTTONS |			\
				MAP_TRIGGERS_TO_BUTTONS | MAP_STICKS_TO_NULL)

#define XTYPE_XBOX        0
#define XTYPE_XBOX360     1
#define XTYPE_XBOX360W    2
#define XTYPE_XBOXONE     3
#define XTYPE_UNKNOWN     4

/* Send power-off packet to xpad360w after holding the mode button for this many
 * seconds
 */
#define XPAD360W_POWEROFF_TIMEOUT 5

#define PKT_XB              0
#define PKT_XBE1            1
#define PKT_XBE2_FW_OLD     2
#define PKT_XBE2_FW_5_EARLY 3
#define PKT_XBE2_FW_5_11    4

#define FLAG_DELAY_INIT BIT(0)

static bool dpad_to_buttons;
module_param(dpad_to_buttons, bool, S_IRUGO);
MODULE_PARM_DESC(dpad_to_buttons, "Map D-PAD to buttons rather than axes for unknown pads");

static bool triggers_to_buttons;
module_param(triggers_to_buttons, bool, S_IRUGO);
MODULE_PARM_DESC(triggers_to_buttons, "Map triggers to buttons rather than axes for unknown pads");

static bool sticks_to_null;
module_param(sticks_to_null, bool, S_IRUGO);
MODULE_PARM_DESC(sticks_to_null, "Do not map sticks at all for unknown pads");

static bool auto_poweroff = true;
module_param(auto_poweroff, bool, S_IWUSR | S_IRUGO);
MODULE_PARM_DESC(auto_poweroff, "Power off wireless controllers on suspend");

static const struct xpad_device {
	u16 idVendor;
	u16 idProduct;
	char *name;
	u8 mapping;
	u8 xtype;
	u8 flags;
} xpad_device[] = {
	/* Please keep this list sorted by vendor and product ID. */
	{ 0x0079, 0x18d4, "GPD Win 2 X-Box Controller", 0, XTYPE_XBOX360 },
	{ 0x0351, 0x1000, "CRKD LP Blueberry Burst Pro Edition (Xbox)", 0, XTYPE_XBOX360 },
	{ 0x0351, 0x2000, "CRKD LP Black Tribal Edition (Xbox) ", 0, XTYPE_XBOX360 },
	{ 0x03eb, 0xff01, "Wooting One (Legacy)", 0, XTYPE_XBOX360 },
	{ 0x03eb, 0xff02, "Wooting Two (Legacy)", 0, XTYPE_XBOX360 },
	{ 0x03f0, 0x038D, "HyperX Clutch", 0, XTYPE_XBOX360 },			/* wired */
	{ 0x03f0, 0x048D, "HyperX Clutch", 0, XTYPE_XBOX360 },			/* wireless */
	{ 0x03f0, 0x0495, "HyperX Clutch Gladiate", 0, XTYPE_XBOXONE },
	{ 0x03f0, 0x07A0, "HyperX Clutch Gladiate RGB", 0, XTYPE_XBOXONE },
	{ 0x03f0, 0x08B6, "HyperX Clutch Gladiate", MAP_SHARE_BUTTON, XTYPE_XBOXONE },		/* v2 */
	{ 0x03f0, 0x09B4, "HyperX Clutch Tanto", 0, XTYPE_XBOXONE },
	{ 0x044f, 0x0f00, "Thrustmaster Wheel", 0, XTYPE_XBOX },
	{ 0x044f, 0x0f03, "Thrustmaster Wheel", 0, XTYPE_XBOX },
	{ 0x044f, 0x0f07, "Thrustmaster, Inc. Controller", 0, XTYPE_XBOX },
	{ 0x044f, 0x0f10, "Thrustmaster Modena GT Wheel", 0, XTYPE_XBOX },
	{ 0x044f, 0xb326, "Thrustmaster Gamepad GP XID", 0, XTYPE_XBOX360 },
	{ 0x044f, 0xd01e, "ThrustMaster, Inc. ESWAP X 2 ELDEN RING EDITION", 0, XTYPE_XBOXONE },
	{ 0x045e, 0x0202, "Microsoft X-Box pad v1 (US)", 0, XTYPE_XBOX },
	{ 0x045e, 0x0285, "Microsoft X-Box pad (Japan)", 0, XTYPE_XBOX },
	{ 0x045e, 0x0287, "Microsoft Xbox Controller S", 0, XTYPE_XBOX },
	{ 0x045e, 0x0288, "Microsoft Xbox Controller S v2", 0, XTYPE_XBOX },
	{ 0x045e, 0x0289, "Microsoft X-Box pad v2 (US)", 0, XTYPE_XBOX },
	{ 0x045e, 0x028e, "Microsoft X-Box 360 pad", 0, XTYPE_XBOX360 },
	{ 0x045e, 0x028f, "Microsoft X-Box 360 pad v2", 0, XTYPE_XBOX360 },
	{ 0x045e, 0x0291, "Xbox 360 Wireless Receiver (XBOX)", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360W },
	{ 0x045e, 0x02a9, "Xbox 360 Wireless Receiver (Unofficial)", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360W },
	{ 0x045e, 0x02d1, "Microsoft X-Box One pad", 0, XTYPE_XBOXONE },
	{ 0x045e, 0x02dd, "Microsoft X-Box One pad (Firmware 2015)", 0, XTYPE_XBOXONE },
	{ 0x045e, 0x02e3, "Microsoft X-Box One Elite pad", MAP_PADDLES, XTYPE_XBOXONE },
	{ 0x045e, 0x02ea, "Microsoft X-Box One S pad", 0, XTYPE_XBOXONE },
	{ 0x045e, 0x0719, "Xbox 360 Wireless Receiver", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360W },
	{ 0x045e, 0x0b00, "Microsoft X-Box One Elite 2 pad", MAP_PADDLES, XTYPE_XBOXONE },
	{ 0x045e, 0x0b0a, "Microsoft X-Box Adaptive Controller", MAP_PROFILE_BUTTON, XTYPE_XBOXONE },
	{ 0x045e, 0x0b12, "Microsoft Xbox Series S|X Controller", MAP_SHARE_BUTTON | MAP_SHARE_OFFSET, XTYPE_XBOXONE },
	{ 0x046d, 0xc21d, "Logitech Gamepad F310", 0, XTYPE_XBOX360 },
	{ 0x046d, 0xc21e, "Logitech Gamepad F510", 0, XTYPE_XBOX360 },
	{ 0x046d, 0xc21f, "Logitech Gamepad F710", 0, XTYPE_XBOX360 },
	{ 0x046d, 0xc242, "Logitech Chillstream Controller", 0, XTYPE_XBOX360 },
	{ 0x046d, 0xca84, "Logitech Xbox Cordless Controller", 0, XTYPE_XBOX },
	{ 0x046d, 0xca88, "Logitech Compact Controller for Xbox", 0, XTYPE_XBOX },
	{ 0x046d, 0xca8a, "Logitech Precision Vibration Feedback Wheel", 0, XTYPE_XBOX },
	{ 0x046d, 0xcaa3, "Logitech DriveFx Racing Wheel", 0, XTYPE_XBOX360 },
	{ 0x0502, 0x1305, "Acer NGR200", 0, XTYPE_XBOX360 },
	{ 0x056e, 0x2004, "Elecom JC-U3613M", 0, XTYPE_XBOX360 },
	{ 0x05fd, 0x1007, "Mad Catz Controller (unverified)", 0, XTYPE_XBOX },
	{ 0x05fd, 0x107a, "InterAct 'PowerPad Pro' X-Box pad (Germany)", 0, XTYPE_XBOX },
	{ 0x05fe, 0x3030, "Chic Controller", 0, XTYPE_XBOX },
	{ 0x05fe, 0x3031, "Chic Controller", 0, XTYPE_XBOX },
	{ 0x062a, 0x0020, "Logic3 Xbox GamePad", 0, XTYPE_XBOX },
	{ 0x062a, 0x0033, "Competition Pro Steering Wheel", 0, XTYPE_XBOX },
	{ 0x06a3, 0x0200, "Saitek Racing Wheel", 0, XTYPE_XBOX },
	{ 0x06a3, 0x0201, "Saitek Adrenalin", 0, XTYPE_XBOX },
	{ 0x06a3, 0xf51a, "Saitek P3600", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4503, "Mad Catz Racing Wheel", 0, XTYPE_XBOXONE },
	{ 0x0738, 0x4506, "Mad Catz 4506 Wireless Controller", 0, XTYPE_XBOX },
	{ 0x0738, 0x4516, "Mad Catz Control Pad", 0, XTYPE_XBOX },
	{ 0x0738, 0x4520, "Mad Catz Control Pad Pro", 0, XTYPE_XBOX },
	{ 0x0738, 0x4522, "Mad Catz LumiCON", 0, XTYPE_XBOX },
	{ 0x0738, 0x4526, "Mad Catz Control Pad Pro", 0, XTYPE_XBOX },
	{ 0x0738, 0x4530, "Mad Catz Universal MC2 Racing Wheel and Pedals", 0, XTYPE_XBOX },
	{ 0x0738, 0x4536, "Mad Catz MicroCON", 0, XTYPE_XBOX },
	{ 0x0738, 0x4540, "Mad Catz Beat Pad", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0738, 0x4556, "Mad Catz Lynx Wireless Controller", 0, XTYPE_XBOX },
	{ 0x0738, 0x4586, "Mad Catz MicroCon Wireless Controller", 0, XTYPE_XBOX },
	{ 0x0738, 0x4588, "Mad Catz Blaster", 0, XTYPE_XBOX },
	{ 0x0738, 0x45ff, "Mad Catz Beat Pad (w/ Handle)", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0738, 0x4716, "Mad Catz Wired Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4718, "Mad Catz Street Fighter IV FightStick SE", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4726, "Mad Catz Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4728, "Mad Catz Street Fighter IV FightPad", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0738, 0x4736, "Mad Catz MicroCon Gamepad", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4738, "Mad Catz Wired Xbox 360 Controller (SFIV)", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0738, 0x4740, "Mad Catz Beat Pad", 0, XTYPE_XBOX360 },
	{ 0x0738, 0x4743, "Mad Catz Beat Pad Pro", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0738, 0x4758, "Mad Catz Arcade Game Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0738, 0x4a01, "Mad Catz FightStick TE 2", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x0738, 0x6040, "Mad Catz Beat Pad Pro", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0738, 0x9871, "Mad Catz Portable Drum", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xb726, "Mad Catz Xbox controller - MW2", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xb738, "Mad Catz MVC2TE Stick 2", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0738, 0xbeef, "Mad Catz JOYTECH NEO SE Advanced GamePad", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xcb02, "Saitek Cyborg Rumble Pad - PC/Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xcb03, "Saitek P3200 Rumble Pad - PC/Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xcb29, "Saitek Aviator Stick AV8R02", 0, XTYPE_XBOX360 },
	{ 0x0738, 0xf738, "Super SFIV FightStick TE S", 0, XTYPE_XBOX360 },
	{ 0x07ff, 0xffff, "Mad Catz GamePad", 0, XTYPE_XBOX360 },
	{ 0x0b05, 0x1a38, "ASUS ROG RAIKIRI", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x0b05, 0x1abb, "ASUS ROG RAIKIRI PRO", 0, XTYPE_XBOXONE },
	{ 0x0b05, 0x1c91, "ASUS ROG RAIKIRI II", 0, XTYPE_XBOX360 },
	{ 0x0b05, 0x1c92, "ASUS ROG RAIKIRI II WIRELESS", 0, XTYPE_XBOX360 },
	{ 0x0b05, 0x1c96, "ASUS ROG RAIKIRI II XBOX", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x0b05, 0x1d04, "ASUS ROG RAIKIRI II XBOX WIRELESS", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x0c12, 0x0005, "Intec wireless", 0, XTYPE_XBOX },
	{ 0x0c12, 0x8801, "Nyko Xbox Controller", 0, XTYPE_XBOX },
	{ 0x0c12, 0x8802, "Zeroplus Xbox Controller", 0, XTYPE_XBOX },
	{ 0x0c12, 0x8809, "RedOctane Xbox Dance Pad", DANCEPAD_MAP_CONFIG, XTYPE_XBOX },
	{ 0x0c12, 0x880a, "Pelican Eclipse PL-2023", 0, XTYPE_XBOX },
	{ 0x0c12, 0x8810, "Zeroplus Xbox Controller", 0, XTYPE_XBOX },
	{ 0x0c12, 0x9902, "HAMA VibraX - *FAULTY HARDWARE*", 0, XTYPE_XBOX },
	{ 0x0d2f, 0x0002, "Andamiro Pump It Up pad", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0db0, 0x1901, "Micro Star International Xbox360 Controller for Windows", 0, XTYPE_XBOX360 },
	{ 0x0e4c, 0x1097, "Radica Gamester Controller", 0, XTYPE_XBOX },
	{ 0x0e4c, 0x1103, "Radica Gamester Reflex", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX },
	{ 0x0e4c, 0x2390, "Radica Games Jtech Controller", 0, XTYPE_XBOX },
	{ 0x0e4c, 0x3510, "Radica Gamester", 0, XTYPE_XBOX },
	{ 0x0e6f, 0x0003, "Logic3 Freebird wireless Controller", 0, XTYPE_XBOX },
	{ 0x0e6f, 0x0005, "Eclipse wireless Controller", 0, XTYPE_XBOX },
	{ 0x0e6f, 0x0006, "Edge wireless Controller", 0, XTYPE_XBOX },
	{ 0x0e6f, 0x0008, "After Glow Pro Controller", 0, XTYPE_XBOX },
	{ 0x0e6f, 0x0105, "HSM3 Xbox360 dancepad", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0113, "Afterglow AX.1 Gamepad for Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x011f, "Rock Candy Gamepad Wired Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0131, "PDP EA Sports Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0133, "Xbox 360 Wired Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0139, "Afterglow Prismatic Wired Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x013a, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0146, "Rock Candy Wired Controller for Xbox One", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0147, "PDP Marvel Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x015c, "PDP Xbox One Arcade Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x0e6f, 0x015d, "PDP Mirror's Edge Official Wired Controller for Xbox One", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0161, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0162, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0163, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0164, "PDP Battlefield One", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0165, "PDP Titanfall 2", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0201, "Pelican PL-3601 'TSZ' Wired Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0213, "Afterglow Gamepad for Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x021f, "Rock Candy Gamepad for Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0246, "Rock Candy Gamepad for Xbox One 2015", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x024c, "PDP Victrix Pro BFG Wired Controller for Xbox", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a0, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a1, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a2, "PDP Wired Controller for Xbox One - Crimson Red", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a4, "PDP Wired Controller for Xbox One - Stealth Series", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a6, "PDP Wired Controller for Xbox One - Camo Series", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a7, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02a8, "PDP Xbox One Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02ab, "PDP Controller for Xbox One", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02ad, "PDP Wired Controller for Xbox One - Stealth Series", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02b3, "Afterglow Prismatic Wired Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x02b8, "Afterglow Prismatic Wired Controller", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0301, "Logic3 Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0346, "Rock Candy Gamepad for Xbox One 2016", 0, XTYPE_XBOXONE },
	{ 0x0e6f, 0x0401, "Logic3 Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0413, "Afterglow AX.1 Gamepad for Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0x0501, "PDP Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x0e6f, 0xf900, "PDP Afterglow AX.1", 0, XTYPE_XBOX360 },
	{ 0x0e8f, 0x0201, "SmartJoy Frag Xpad/PS2 adaptor", 0, XTYPE_XBOX },
	{ 0x0e8f, 0x3008, "Generic xbox control (dealextreme)", 0, XTYPE_XBOX },
	{ 0x0f0d, 0x000a, "Hori Co. DOA4 FightStick", 0, XTYPE_XBOX360 },
	{ 0x0f0d, 0x000c, "Hori PadEX Turbo", 0, XTYPE_XBOX360 },
	{ 0x0f0d, 0x000d, "Hori Fighting Stick EX2", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0f0d, 0x0016, "Hori Real Arcade Pro.EX", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0f0d, 0x001b, "Hori Real Arcade Pro VX", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0f0d, 0x0063, "Hori Real Arcade Pro Hayabusa (USA) Xbox One", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x0f0d, 0x0067, "HORIPAD ONE", 0, XTYPE_XBOXONE },
	{ 0x0f0d, 0x0078, "Hori Real Arcade Pro V Kai Xbox One", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x0f0d, 0x00c5, "Hori Fighting Commander ONE", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x0f0d, 0x00dc, "HORIPAD FPS for Nintendo Switch", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x0f0d, 0x0151, "Hori Racing Wheel Overdrive for Xbox Series X", 0, XTYPE_XBOXONE },
	{ 0x0f0d, 0x0152, "Hori Racing Wheel Overdrive for Xbox Series X", 0, XTYPE_XBOXONE },
	{ 0x0f0d, 0x01b2, "HORI Taiko No Tatsujin Drum Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x0f30, 0x010b, "Philips Recoil", 0, XTYPE_XBOX },
	{ 0x0f30, 0x0202, "Joytech Advanced Controller", 0, XTYPE_XBOX },
	{ 0x0f30, 0x8888, "BigBen XBMiniPad Controller", 0, XTYPE_XBOX },
	{ 0x102c, 0xff0c, "Joytech Wireless Advanced Controller", 0, XTYPE_XBOX },
	{ 0x1038, 0x1430, "SteelSeries Stratus Duo", 0, XTYPE_XBOX360 },
	{ 0x1038, 0x1431, "SteelSeries Stratus Duo", 0, XTYPE_XBOX360 },
	{ 0x10f5, 0x7005, "Turtle Beach Recon Controller", 0, XTYPE_XBOXONE },
	{ 0x10f5, 0x7008, "Turtle Beach Recon Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x10f5, 0x7073, "Turtle Beach Stealth Ultra Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x11c9, 0x55f0, "Nacon GC-100XF", 0, XTYPE_XBOX360 },
	{ 0x11ff, 0x0511, "PXN V900", 0, XTYPE_XBOX360 },
	{ 0x1209, 0x2882, "Ardwiino Controller", 0, XTYPE_XBOX360 },
	{ 0x12ab, 0x0004, "Honey Bee Xbox360 dancepad", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x12ab, 0x0301, "PDP AFTERGLOW AX.1", 0, XTYPE_XBOX360 },
	{ 0x12ab, 0x0303, "Mortal Kombat Klassic FightStick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x12ab, 0x8809, "Xbox DDR dancepad", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x1430, 0x4748, "RedOctane Guitar Hero X-plorer", 0, XTYPE_XBOX360 },
	{ 0x1430, 0x8888, "TX6500+ Dance Pad (first generation)", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX },
	{ 0x1430, 0xf801, "RedOctane Controller", 0, XTYPE_XBOX360 },
	{ 0x146b, 0x0601, "BigBen Interactive XBOX 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x146b, 0x0604, "Bigben Interactive DAIJA Arcade Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1532, 0x0a00, "Razer Atrox Arcade Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOXONE },
	{ 0x1532, 0x0a03, "Razer Wildcat", 0, XTYPE_XBOXONE },
	{ 0x1532, 0x0a29, "Razer Wolverine V2", 0, XTYPE_XBOXONE },
	{ 0x1532, 0x0a57, "Razer Wolverine V3 Pro (Wired)", 0, XTYPE_XBOX360 },
	{ 0x1532, 0x0a59, "Razer Wolverine V3 Pro (2.4 GHz Dongle)", 0, XTYPE_XBOX360 },
	{ 0x15e4, 0x3f00, "Power A Mini Pro Elite", 0, XTYPE_XBOX360 },
	{ 0x15e4, 0x3f0a, "Xbox Airflo wired controller", 0, XTYPE_XBOX360 },
	{ 0x15e4, 0x3f10, "Batarang Xbox 360 controller", 0, XTYPE_XBOX360 },
	{ 0x162e, 0xbeef, "Joytech Neo-Se Take2", 0, XTYPE_XBOX360 },
	{ 0x1689, 0xfd00, "Razer Onza Tournament Edition", 0, XTYPE_XBOX360 },
	{ 0x1689, 0xfd01, "Razer Onza Classic Edition", 0, XTYPE_XBOX360 },
	{ 0x1689, 0xfe00, "Razer Sabertooth", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x1103, "Azeron Cyro", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x113c, "Azeron Cyborg", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x1192, "Azeron Classic/Compact", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x1212, "Azeron Cyro Lefty", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x12f7, "Azeron Cyborg II", 0, XTYPE_XBOX360 },
	{ 0x16d0, 0x13ea, "Azeron Keyzen", 0, XTYPE_XBOX360 },
	{ 0x17ef, 0x6182, "Lenovo Legion Controller for Windows", 0, XTYPE_XBOX360 },
	{ 0x1949, 0x041a, "Amazon Game Controller", 0, XTYPE_XBOX360 },
	{ 0x1a86, 0xe310, "Legion Go S", 0, XTYPE_XBOX360 },
	{ 0x1b1c, 0x2b1f, "Corsair Novablade Pro (Wired)", 0, XTYPE_XBOX360 },
	{ 0x1b1c, 0x2b2b, "Corsair Novablade Pro (2.4 GHz Receiver)", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0x0002, "Harmonix Rock Band Guitar", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0x0003, "Harmonix Rock Band Drumkit", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0x0130, "Ion Drum Rocker", MAP_DPAD_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf016, "Mad Catz Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf018, "Mad Catz Street Fighter IV SE Fighting Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf019, "Mad Catz Brawlstick for Xbox 360", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf021, "Mad Cats Ghost Recon FS GamePad", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf023, "MLG Pro Circuit Controller (Xbox)", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf025, "Mad Catz Call Of Duty", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf027, "Mad Catz FPS Pro", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf028, "Street Fighter IV FightPad", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf02e, "Mad Catz Fightpad", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf030, "Mad Catz Xbox 360 MC2 MicroCon Racing Wheel", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf036, "Mad Catz MicroCon GamePad Pro", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf038, "Street Fighter IV FightStick TE", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf039, "Mad Catz MvC2 TE", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf03a, "Mad Catz SFxT Fightstick Pro", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf03d, "Street Fighter IV Arcade Stick TE - Chun Li", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf03e, "Mad Catz MLG FightStick TE", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf03f, "Mad Catz FightStick SoulCaliber", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf042, "Mad Catz FightStick TES+", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf080, "Mad Catz FightStick TE2", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf501, "HoriPad EX2 Turbo", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf502, "Hori Real Arcade Pro.VX SA", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf503, "Hori Fighting Stick VX", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf504, "Hori Real Arcade Pro. EX", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf505, "Hori Fighting Stick EX2B", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xf506, "Hori Real Arcade Pro.EX Premium VLX", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf900, "Harmonix Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf901, "Gamestop Xbox 360 Controller", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf903, "Tron Xbox 360 controller", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf904, "PDP Versus Fighting Pad", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xf906, "MortalKombat FightStick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x1bad, 0xfa01, "MadCatz GamePad", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xfd00, "Razer Onza TE", 0, XTYPE_XBOX360 },
	{ 0x1bad, 0xfd01, "Razer Onza", 0, XTYPE_XBOX360 },
	{ 0x1ee9, 0x1590, "ZOTAC Gaming Zone", 0, XTYPE_XBOX360 },
	{ 0x20bc, 0x5134, "BETOP BTP-KP50B Xinput Dongle", 0, XTYPE_XBOX360 },
	{ 0x20bc, 0x514a, "BETOP BTP-KP50C Xinput Dongle", 0, XTYPE_XBOX360 },
	{ 0x20d6, 0x2001, "BDA Xbox Series X Wired Controller", 0, XTYPE_XBOXONE },
	{ 0x20d6, 0x2009, "PowerA Enhanced Wired Controller for Xbox Series X|S", 0, XTYPE_XBOXONE },
	{ 0x20d6, 0x2064, "PowerA Wired Controller for Xbox", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x20d6, 0x281f, "PowerA Wired Controller For Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x20d6, 0x400b, "PowerA FUSION Pro 4 Wired Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x20d6, 0x890b, "PowerA MOGA XP-Ultra Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x2345, 0xe00b, "Machenike G5 Pro Controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5000, "Razer Atrox Arcade Stick", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x24c6, 0x5300, "PowerA MINI PROEX Controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5303, "Xbox Airflo wired controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x530a, "Xbox 360 Pro EX Controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x531a, "PowerA Pro Ex", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5397, "FUS1ON Tournament Controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x541a, "PowerA Xbox One Mini Wired Controller", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x542a, "Xbox ONE spectra", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x543a, "PowerA Xbox One wired controller", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x5500, "Hori XBOX 360 EX 2 with Turbo", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5501, "Hori Real Arcade Pro VX-SA", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5502, "Hori Fighting Stick VX Alt", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x24c6, 0x5503, "Hori Fighting Edge", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x24c6, 0x5506, "Hori SOULCALIBUR V Stick", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x550d, "Hori GEM Xbox controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x550e, "Hori Real Arcade Pro V Kai 360", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x24c6, 0x5510, "Hori Fighting Commander ONE (Xbox 360/PC Mode)", MAP_TRIGGERS_TO_BUTTONS, XTYPE_XBOX360 },
	{ 0x24c6, 0x551a, "PowerA FUSION Pro Controller", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x561a, "PowerA FUSION Controller", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x581a, "ThrustMaster XB1 Classic Controller", 0, XTYPE_XBOXONE },
	{ 0x24c6, 0x5b00, "ThrustMaster Ferrari 458 Racing Wheel", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5b02, "Thrustmaster, Inc. GPX Controller", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5b03, "Thrustmaster Ferrari 458 Racing Wheel", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0x5d04, "Razer Sabertooth", 0, XTYPE_XBOX360 },
	{ 0x24c6, 0xfafe, "Rock Candy Gamepad for Xbox 360", 0, XTYPE_XBOX360 },
	{ 0x2563, 0x058d, "OneXPlayer Gamepad", 0, XTYPE_XBOX360 },
	{ 0x294b, 0x3303, "Snakebyte GAMEPAD BASE X", 0, XTYPE_XBOXONE },
	{ 0x294b, 0x3404, "Snakebyte GAMEPAD RGB X", 0, XTYPE_XBOXONE },
	{ 0x2993, 0x2001, "TECNO Pocket Go", 0, XTYPE_XBOX360 },
	{ 0x2dc8, 0x2000, "8BitDo Pro 2 Wired Controller fox Xbox", 0, XTYPE_XBOXONE },
	{ 0x2dc8, 0x200f, "8BitDo Ultimate 3-mode Controller for Xbox", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x2dc8, 0x201e, "8BitDo Pro 2 Wired Controller for Xbox", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x2dc8, 0x3106, "8BitDo Ultimate Wireless / Pro 2 Wired Controller", 0, XTYPE_XBOX360 },
	{ 0x2dc8, 0x3109, "8BitDo Ultimate Wireless Bluetooth", 0, XTYPE_XBOX360 },
	{ 0x2dc8, 0x310a, "8BitDo Ultimate 2C Wireless Controller", 0, XTYPE_XBOX360 },
	{ 0x2dc8, 0x310b, "8BitDo Ultimate 2 Wireless Controller", 0, XTYPE_XBOX360 },
	{ 0x2dc8, 0x6001, "8BitDo SN30 Pro", 0, XTYPE_XBOX360 },
	{ 0x2e24, 0x0423, "Hyperkin DuchesS Xbox One pad", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x2e24, 0x0652, "Hyperkin Duke X-Box One pad", 0, XTYPE_XBOXONE },
	{ 0x2e24, 0x1688, "Hyperkin X91 X-Box One pad", 0, XTYPE_XBOXONE },
	{ 0x2e95, 0x0504, "SCUF Gaming Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE },
	{ 0x31e3, 0x1100, "Wooting One", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1200, "Wooting Two", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1210, "Wooting Lekker", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1220, "Wooting Two HE", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1230, "Wooting Two HE (ARM)", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1300, "Wooting 60HE (AVR)", 0, XTYPE_XBOX360 },
	{ 0x31e3, 0x1310, "Wooting 60HE (ARM)", 0, XTYPE_XBOX360 },
	{ 0x3285, 0x0603, "Nacon Pro Compact controller for Xbox", 0, XTYPE_XBOXONE },
	{ 0x3285, 0x0607, "Nacon GC-100", 0, XTYPE_XBOX360 },
	{ 0x3285, 0x0614, "Nacon Pro Compact", 0, XTYPE_XBOXONE },
	{ 0x3285, 0x0646, "Nacon Pro Compact", 0, XTYPE_XBOXONE },
	{ 0x3285, 0x0662, "Nacon Revolution5 Pro", 0, XTYPE_XBOX360 },
	{ 0x3285, 0x0663, "Nacon Evol-X", 0, XTYPE_XBOXONE },
	{ 0x3507, 0x000b, "ZENAIM LEVERLESS", 0, XTYPE_XBOX360 },
	{ 0x3537, 0x1004, "GameSir T4 Kaleid", 0, XTYPE_XBOX360 },
	{ 0x3537, 0x100f, "GameSir Nova 2 Lite", 0, XTYPE_XBOX360 },
	{ 0x3537, 0x1010, "GameSir G7 SE", 0, XTYPE_XBOXONE },
	{ 0x3537, 0x1040, "GameSir Nova Lite", 0, XTYPE_XBOX360 },
	{ 0x3651, 0x1000, "CRKD SG", 0, XTYPE_XBOX360 },
	{ 0x366c, 0x0005, "ByoWave Proteus Controller", MAP_SHARE_BUTTON, XTYPE_XBOXONE, FLAG_DELAY_INIT },
	{ 0x3767, 0x0101, "Fanatec Speedster 3 Forceshock Wheel", 0, XTYPE_XBOX },
	{ 0x37d7, 0x2501, "Flydigi Apex 5", 0, XTYPE_XBOX360 },
	{ 0x413d, 0x2104, "Black Shark Green Ghost Gamepad", 0, XTYPE_XBOX360 },
	{ 0xffff, 0xffff, "Chinese-made Xbox Controller", 0, XTYPE_XBOX },
	{ 0x0000, 0x0000, "Generic X-Box pad", 0, XTYPE_UNKNOWN }
};

/* buttons shared with xbox and xbox360 */
static const signed short xpad_common_btn[] = {
	BTN_A, BTN_B, BTN_X, BTN_Y,			/* "analog" buttons */
	BTN_START, BTN_SELECT, BTN_THUMBL, BTN_THUMBR,	/* start/back/sticks */
	-1						/* terminating entry */
};

/* original xbox controllers only */
static const signed short xpad_btn[] = {
	BTN_C, BTN_Z,		/* "analog" buttons */
	-1			/* terminating entry */
};

/* used when dpad is mapped to buttons */
static const signed short xpad_btn_pad[] = {
	BTN_DPAD_LEFT, BTN_DPAD_RIGHT,	/* d-pad left, right */
	BTN_DPAD_UP, BTN_DPAD_DOWN,	/* d-pad up, down */
	-1				/* terminating entry */
};

/* used when triggers are mapped to buttons */
static const signed short xpad_btn_triggers[] = {
	BTN_TL2, BTN_TR2,		/* triggers left/right */
	-1
};

static const signed short xpad360_btn[] = {  /* buttons for x360 controller */
	BTN_TL, BTN_TR,		/* Button LB/RB */
	BTN_MODE,		/* The big X button */
	-1
};

static const signed short xpad_abs[] = {
	ABS_X, ABS_Y,		/* left stick */
	ABS_RX, ABS_RY,		/* right stick */
	-1			/* terminating entry */
};

/* used when dpad is mapped to axes */
static const signed short xpad_abs_pad[] = {
	ABS_HAT0X, ABS_HAT0Y,	/* d-pad axes */
	-1			/* terminating entry */
};

/* used when triggers are mapped to axes */
static const signed short xpad_abs_triggers[] = {
	ABS_Z, ABS_RZ,		/* triggers left/right */
	-1
};

/* used when the controller has extra paddle buttons */
static const signed short xpad_btn_paddles[] = {
	BTN_GRIPR, BTN_GRIPR2, /* paddle upper right, lower right */
	BTN_GRIPL, BTN_GRIPL2, /* paddle upper left, lower left */
	-1						/* terminating entry */
};

/*
 * Xbox 360 has a vendor-specific class, so we cannot match it with only
 * USB_INTERFACE_INFO (also specifically refused by USB subsystem), so we
 * match against vendor id as well. Wired Xbox 360 devices have protocol 1,
 * wireless controllers have protocol 129.
 */
#define XPAD_XBOX360_VENDOR_PROTOCOL(vend, pr) \
	.match_flags = USB_DEVICE_ID_MATCH_VENDOR | USB_DEVICE_ID_MATCH_INT_INFO, \
	.idVendor = (vend), \
	.bInterfaceClass = USB_CLASS_VENDOR_SPEC, \
	.bInterfaceSubClass = 93, \
	.bInterfaceProtocol = (pr)
#define XPAD_XBOX360_VENDOR(vend) \
	{ XPAD_XBOX360_VENDOR_PROTOCOL((vend), 1) }, \
	{ XPAD_XBOX360_VENDOR_PROTOCOL((vend), 129) }

/* The Xbox One controller uses subclass 71 and protocol 208. */
#define XPAD_XBOXONE_VENDOR_PROTOCOL(vend, pr) \
	.match_flags = USB_DEVICE_ID_MATCH_VENDOR | USB_DEVICE_ID_MATCH_INT_INFO, \
	.idVendor = (vend), \
	.bInterfaceClass = USB_CLASS_VENDOR_SPEC, \
	.bInterfaceSubClass = 71, \
	.bInterfaceProtocol = (pr)
#define XPAD_XBOXONE_VENDOR(vend) \
	{ XPAD_XBOXONE_VENDOR_PROTOCOL((vend), 208) }

static const struct usb_device_id xpad_table[] = {
	/*
	 * Please keep this list sorted by vendor ID. Note that there are 2
	 * macros - XPAD_XBOX360_VENDOR and XPAD_XBOXONE_VENDOR.
	 */
	{ USB_INTERFACE_INFO('X', 'B', 0) },	/* Xbox USB-IF not-approved class */
	XPAD_XBOX360_VENDOR(0x0079),		/* GPD Win 2 con