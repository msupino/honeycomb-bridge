# License and protocol provenance

This version is distributed under GNU GPL version 2 or, at your option, any later version. See COPYING. The new native authentication implementation is adapted from the protocol and algorithms in medusalix/xone, commit 3484f603484782dd7551c64e5a33fc602b127051, especially auth/auth.c and auth/crypto.c, Copyright (C) 2023 Severin von Wnuck-Lipinski. GIP framing/startup research also used transport/wired.c and bus/protocol.c from that checkout, Copyright (C) 2021 Severin von Wnuck-Lipinski.

The macOS transport uses IOKit; the native cryptographic implementation uses CommonCrypto and Security.framework. No Linux module or upstream binary is bundled. The included GPL copy comes from xone. Protocol observations and experimental changes are described in XONE-RESEARCH.md. Preserve upstream notices and this provenance when distributing adaptations.
