# IMPLEMENTATION PLAN — dependency-ordered (mandate §5/§96 compliant)

Rule: no engine starts until the previous milestone gate is PASSED and regression stays green.

| Milestone | Scope | Depends on | Gate evidence |
|---|---|---|---|
| M0 Feasibility | FEASIBILITY_ZC702.md, risk register | — | doc review ✔ |
| M1 Requirements | PRODUCT_REQUIREMENTS.md v0.1 freeze | M0 | traceability skeleton ✔ |
| M2 Architecture | SYSTEM_ARCHITECTURE.md, REGISTER_MAP.md, VERIFICATION_PLAN.md, CLOCK_RESET/CDC drafts | M1 | consistency cross-review |
| **M3 PHY Register Interface** | rtl/phy_if/* + TB + model + lint + OOC synth | M2 | xsim regression PASS + synth report ← current |
| M4 SerDes Supervisor | global FSM, init sequencing, fault state | M3 | unit PASS + full regression |
| M5 CDR Controller | lock/debounce/reacquire policy engine | M4 | unit tests: immediate/delayed/unstable/no-lock/loss/reacq/repeat-fail |
| M6 TX Pre-emphasis | cursor control, sweeps, rollback | M4+M3 | limits/sweep/converge/bad-metric tests |
| M7 RX Equalization | capability-gated CTLE/DFE/adapt | M6 | unsupported/saturation/rollback tests |
| M8 EQ Coordinator | joint TX/RX search, metrics normalization | M6,M7 | multi-channel-model convergence |
| M9 Link Training | TRAIN FSM, thresholds, retraining | M5–M8 | channel-quality matrix incl. failure paths |
| M10 Calibration | policies, verify-before-store, rollback | M9 | interruption & fail-path tests |
| M11 Multi-lane | lane manager 1→2→4→8 lanes | M9 | independent/simultaneous faults, degraded mode |
| M12 AXI/IRQ productization | CSR map final, interrupts, telemetry | M3–M11 | AXI stress TB, reg map freeze |
| M13 ZC702 Vivado integration | BD, XDC, ILA option, timing/CDC/DRC | M12 | impl reports archived |
| M14 Vitis bare-metal | driver + 8 examples | M13 | build logs; HW run when board available |
| M15 Linux | DT binding, driver, libserdesphy, serdesctl | M13 | kernel build; HIL marked BLOCKED until env |
| M16 Hardening | long regress, random/fault/CDC/reset reviews | M14 | release blocker list empty |
| M17 Release | manifest, checksums, docs set | M16 | RELEASE_CHECKLIST complete |

## Session log

- S1 (2026-08-25): M0–M2 documents created and cross-reviewed (2 inconsistencies found and
  corrected: CSR timing vs M3 scope; arbitration class wording). M3 RTL+TB authored;
  gate execution recorded in VERIFICATION_STATUS.md.
