# REFERENCES

Every architectural claim traces to one of these. Record document number, revision, and what was derived.

| Ref | Document | Rev/Access date | Derived information |
|---|---|---|---|
| REF-001 | AMD UG850 — ZC702 Evaluation Board User Guide | v1.x, accessed 2026-08-25 (docs.amd.com/v/u/en-US/ug850-zc702-eval-bd) | Two FMC **LPC** connectors J3/J4; bank map: FMC1→banks 34/35, FMC2→banks 13/33; VADJ=2.5V default on banks 13/33/34/35; 200 MHz LVDS system clock (SIT9102); SI570 user clock via I2C mux; Marvell tri-speed Ethernet PHY (88E1111 early / 88E1116R later revs) → GEM0 RGMII; XADC header J40; component table incl. schematic 0381449 page refs |
| REF-002 | AMD DS190 — Zynq-7000 SoC Data Sheet: Overview | 2018-07-02 version | Device resources table (7z020: 53.2K LUT / 106.4K FF / 4.9 Mb BRAM / 220 DSP); GEM SGMII/RGMII support; ISERDES oversampling mode note (1.25 Gb/s SGMII-class async recovery) |
| REF-003 | AMD UG585 — Zynq-7000 SoC TRM, "GTX Low-Power Serial Transceivers" section | docs.amd.com, accessed 2026-08-25 | PL GTX only in 7z030/035/045/100; PL GTP only in 7z012S/7z015 → **7z020 has zero PL transceivers**; PS-side SerDes dedicated to GEM SGMII |
| REF-004 | AMD official package pinout file xc7z020clg484pkg.txt | download.amd.com, accessed 2026-08-25 | All PL I/O banks 13/33/34/35 are **HR** type |
| REF-005 | AMD UG471 — 7-Series SelectIO Resources User Guide | accessed 2026-08-25 | ISERDESE2/OSERDESE2 ratios; IDELAYE2 in HR+HP banks; ODELAYE2 HP-banks only; LVDS_25 VCCO=2.5V requirements in HR banks |
| REF-006 | XAPP523/XAPP594 family (LVDS SERDES app notes) + AR#50949 | accessed 2026-08-25 | IDELAY tap ≈78 ps @200 MHz (32 taps ⇒ ~400 Mb/s min deskew capture); per-bit-deskew capture range ~400–1600 Mb/s by family/speed grade; ZC702 LPC differential pairs usable single-ended |
| REF-007 | DS181/DS187 Artix/Zynq-7000 DC&AC data sheets + AMD forum guidance | accessed 2026-08-25 | DDR LVDS max ~950 Mb/s class (-1); static-alignment practical ≤ ~600 Mb/s |
| REF-008 | UG865 — Zynq-7000 Packaging and Pinout | referenced | Package/bank bonding cross-check |
| REF-009 | UG953 — Vivado 2025.2 7-Series Libraries (OSERDESE2 entry) | accessed 2026-08-25 | Primitive parameters for future Profile C work |
| REF-010 | UG1118 (IP packaging), UG903 (constraints), UG900 (simulation), UG908 (debug) | pending detailed read at M12/M13 | Packaging/constraint/sim/debug flows |

Pending reads (tracked): UG585 PS-GTR chapter detail (OQ-003); external PHY datasheet once card selected.
