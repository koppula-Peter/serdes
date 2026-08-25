# KNOWN LIMITATIONS

1. **No GT transceivers on XC7Z020** (device property, see FEASIBILITY_ZC702.md §3). Any
   multi-gigabit link requires an external PHY/SerDes today; a future GT backend targets
   GTX/GTP-equipped Zynq-7000 family members (7z015/7z030/7z035/7z045/7z100).
2. **No ODELAYE2 anywhere on this device** (HR-banks-only silicon) → no output-side per-bit deskew.
3. **Hardware link validation BLOCKED** until external PHY hardware is integrated (OI-001):
   CDR/TXEQ/RXEQ/TRAIN/CAL/DIAG physical-layer results cannot be claimed. Simulation evidence only.
4. CSR/AXI block lands at M12; M3 engine is exposed via ports for later wiring.
5. Bare-metal/Linux software execution evidence requires target board runs; builds can be verified
   earlier; runtime tests stay NOT RUN/BLOCKED until then.
6. Profile C SelectIO rates bounded per FEASIBILITY §6; never GT-equivalent.
