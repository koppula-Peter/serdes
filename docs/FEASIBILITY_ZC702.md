# FEASIBILITY_ZC702.md — ZC702 / XC7Z020 Capability Analysis

| | |
|---|---|
| Document ID | SERDES-FEAS-001 |
| Status | APPROVED for v0.1 baseline |
| Target | AMD ZC702, device XC7Z020-1CLG484C |
| Sources | UG850 (v1.1–v1.5), DS190, DS187, UG585, UG471, UG953, XAPP523/XAPP594, UG865 + official package pinout `xc7z020clg484pkg.txt`. See REFERENCES.md |

---

## 1. Executive Summary

**The XC7Z020 contains NO hard serial transceivers (no GTP, no GTX, no GTH) in its Programmable
Logic.** This is a property of the device family member, not of the board. A conventional
multi-gigabit SerDes design **cannot** be implemented in the ZC702 PL fabric.

Therefore the product developed under this mandate is a **SerDes/PHY control and management
subsystem** that drives an *abstract PHY backend*:

- On ZC702: an **external PHY/SerDes** reached over a management transport (MDIO/SPI/I2C/parallel)
  through FMC-LPC connectors or board headers.
- On future GT-equipped targets: internal GT primitives via DRP (Profile B).

The only SerDes physically present in the XC7Z020 is inside the PS (PS-GTR serving the two GEMs);
it is not accessible as a general-purpose transceiver from PL. See §4.

A low-rate SelectIO "soft-SerDes" (Profile C) is feasible as an optional, clearly-labeled,
non-equivalent capability. See §6.

## 2. What the XC7Z020 CAN implement

| Capability | Available on XC7Z020-CLG484 | Evidence |
|---|---|---|
| Full control-plane RTL (FSMs, arbiters, timers) | Yes — 53,200 LUTs, 106,400 FFs, 140 BRAM36, 220 DSP48E1 (85K logic cells) | DS190 Table 1 |
| AXI4-Lite PS↔PL control plane (M_AXI_GP0) | Yes | UG585 ch. 5 |
| PL interrupts to PS (IRQ_F2P) | Yes | UG585 ch. 7 |
| ISERDESE2 / OSERDESE2 (8:1, DDR; 10:1/14:1 w/ width expansion) | Yes — all four PL banks are HR banks; ISERDES/OSERDES exist in HR and HP banks | UG471; pinout file (banks 13/33/34/35 = HR) |
| IDELAYE2 (32 taps × ~78 ps @ 200 MHz IDELAYCTRL ref) | Yes (HR banks) | UG471; XAPP523 |
| LVDS I/O (LVDS_25 in HR banks) | Yes — requires VCCO = 2.5 V for TX and for RX with DIFF_TERM; ZC702 VADJ defaults to 2.5 V on banks 13/33/34/35 | UG471; UG850 Table 1-3 |
| MMCM/PLL clocking, BUFIO/BUFR regional clocks | Yes | UG472 (7-Series Clocking) |
| XADC on-die temperature/voltage monitoring | Yes — dual 12-bit 1 MSPS; external channels via header J40 | UG850 overview; DS190 |
| FCLK0–FCLK3 PS→PL clocks | Yes | UG585 ch. 2 |

## 3. What the XC7Z020 CANNOT implement

| Missing capability | Consequence | Mandate mapping |
|---|---|---|
| **No GTX/GTP/GTH transceivers in PL.** Per UG585: PL GTX exists only in 7z030/7z035/7z045/7z100; PL GTP only in 7z012S/7z015. The 7z010/**7z020**/7z007S/7z014S have **zero** PL transceivers. | No multi-gigabit serial links from PL. No hardware CDR, CTLE, DFE, TX pre/post emphasis drivers at GT line rates. | Profile A mandatory; Profile B deferred |
| No ODELAYE2 anywhere on this device (HP-bank-only primitive; XC7Z020 has only HR banks). | Output-side per-bit deskew unavailable; source-synchronous TX timing must be closed statically. | Profile C limitation |
| No analog CDR in fabric | Asynchronous serial recovery limited to oversampling techniques with severe rate/reach limits | §6 |
| No eye-scan / GT diagnostic hardware | Eye measurement requires external instrument or a backend that exposes one | Diagnostics spec |

**Gate check (Milestone 0):** No architecture element depends on GTX presence on ZC702. ✔

## 4. PS-GTR (the only SerDes present)

The Zynq-7000 PS embeds transceiver lanes dedicated to the two Gigabit Ethernet MACs for
SGMII/1000BASE-X operation ("PS-GTR", UG585). Constraints:

- Owned and sequenced by the PS (SIOU); not mapped into user PL fabric.
- Not usable as a generic multi-gigabit PHY backend by this IP.
- OPEN QUESTION OQ-003: exact supported line-rate ceiling and whether any debug access is
  possible on ZC702 (board does not route PS-GTR pairs to user-accessible connectors — confirm
  against schematic 0381449 before further claims).

## 5. ZC702 Board Facts Relevant to This Project (UG850)

| Item | Fact |
|---|---|
| FMC connectors | **Two LPC connectors only** (J3 = FMC1, J4 = FMC2). There is no HPC connector on ZC702. Each LPC exposes up to 34 differential LA pairs usable single-ended (AR#50949). |
| FMC1 (J3) PL banks | Banks 34, 35 (+ HDMI codec sharing) |
| FMC2 (J4) PL banks | Banks 13, 33 |
| Bank voltages | Banks 13/33/34/35 powered from VADJ; shipped at 2.5 V ⇒ LVDS_25 legal |
| System clock | 200 MHz 2.5 V LVDS oscillator (SiTime SIT9102) → PL (MMCM source) |
| User clock | SI570 programmable (default 156.25 MHz), controlled via PS I2C mux (PCA9548) |
| Ethernet PHY | Marvell tri-speed PHY (88E1111 on early boards; 88E1116R on later revisions) → GEM0 RGMII. MDIO/MDC ownership (PS MIO vs PL) must be confirmed against schematic before any shared use — see OQ-002. Do not assume PL can safely probe it. |
| XADC | On-chip + analog header J40 |
| Power monitors | TI UCD9248 PMBus chain (PS-side; PL access not planned) |
| Configuration bank | Bank 0 @ 2.5 V |

**External PHY integration path (Profile A):** management signals (MDIO/MDC, SPI, I2C, GPIO
reset/signal-detect) enter via FMC1/FMC2 LPC pins in HR banks at VADJ=2.5 V, plus optional
low-rate reference/status clocks on SRCC/MRCC pins. Actual external PHY card selection remains
open (OPEN_ISSUES OI-001); development proceeds unblocked per §59 of the mandate.

## 6. Profile C — SelectIO Soft-SerDes Feasibility Statement

Feasible but **explicitly NOT equivalent to GT-class SerDes**:

- Practical ceiling on -1 speed grade Artix-7-class I/O: DDR LVDS ≈ **950 Mb/s absolute max**
  (data-sheet class), with static-alignment designs realistically ≤ ~600 Mb/s; IDELAY-deskew
  capture techniques span ~400 Mb/s (32×78 ps tap limit) to ~1.6 Gb/s best case on faster grades.
  ISERDES oversampling mode permits asynchronous capture experiments near 1.25 Gb/s (DS190),
  without equalization guarantees.
- **No integrated CDR**: source-synchronous forwarding required below these limits;
  asynchronous operation requires oversampling with degraded jitter tolerance.
- **No ODELAYE2** on this device → TX deskew impossible; skew budget consumed by PCB+package.
- No TX pre-emphasis/de-emphasis, no CTLE/DFE, no eye monitor: signal integrity bounded by
  plain LVDS_25 drivers/receivers.
- Training/equalization engines can only exercise signal-detect/delay-like knobs, not real EQ.

Decision D-006: Profile C stays isolated behind the same `phy_backend_if` abstraction and is
never advertised as GT-equivalent.

## 7. Architecture Consequence

One reusable control engine + pluggable backends (`phy_backend_external*`, `phy_backend_gt_drp`,
optional `phy_backend_selectio`):

```
Control plane (this IP) ── phy_backend_if ──> MDIO/SPI/I2C/parallel (ZC702, external PHY)
                                          └─> GT DRP (future GTX/GTP-capable target)
```

Moving to a GT-equipped Zynq-7000-family device (7z015/7z030/7z035/7z045/7z100) primarily means
implementing `phy_backend_gt_drp`; training/calibration/lane/fault/software layers are unchanged.

## 8. Risks

| ID | Risk | Mitigation |
|---|---|---|
| R-001 | External PHY hardware unavailable → hardware validation blocked | Simulation-first; generic parallel backend + sim model; mark HW tests BLOCKED honestly |
| R-002 | FMC pins shared with HDMI codec nets on banks 33/34/35 | Pin plan review against UG850 Tables 1-28/1-29 before any XDC pinning |
| R-003 | VADJ changed from 2.5 V breaks LVDS_25 assumptions | Constraint checks + documentation; treat VADJ=2.5V as platform assumption |
| R-004 | Early-revision ZC702 units carry ES silicon (XC7Z020-...CES) | Document; behavior identical for this control-plane scope |
| R-005 | MDIO contention with PS GEM driver if onboard PHY reused | OQ-002 investigation gate before any such attempt |

## 9. Open Questions

- **OQ-001:** Which external PHY/retimer card? (blocks hardware validation only)
- **OQ-002:** Confirm ZC702 Ethernet MDIO/MDC routing (PS-MIO vs PL) from schematic sheet 25–26 before any reuse attempt.
- **OQ-003:** PS-GTR line-rate ceiling & accessibility — read UG585 PS-GTR chapter + schematic; low priority (non-goal).
- **OQ-004:** SI570 frequency setpoints available for SelectIO reference-clock studies (I2C-controlled via PS).
