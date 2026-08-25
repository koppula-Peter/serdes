# CHANGELOG

All notable changes. Format based on Keep a Changelog; versioning SemVer.

## [0.1.0] - 2026-08-25
### Added
- Repository scaffold (rtl/, backend/, verification/, constraints/, vivado/, software/, tools/, scripts/, ci/, release/)
- Governance: README, LICENSE (BSD-3-Clause), CURRENT_WORK, OPEN_ISSUES, DECISIONS,
  KNOWN_LIMITATIONS, REQUIREMENTS_TRACEABILITY
- docs/: FEASIBILITY_ZC702, PRODUCT_REQUIREMENTS (v0.1 baseline), SYSTEM_ARCHITECTURE,
  REGISTER_MAP (v0.1), VERIFICATION_PLAN, IMPLEMENTATION_PLAN, CLOCK_RESET, CDC_RDC, REFERENCES
- rtl/phy_if: serdes_phy_ctrl_pkg.sv, phy_arbiter.sv, phy_xact_core.sv, phy_xact_engine_top.sv
- verification/models/phy_backend_sim_model.sv, verification/tb/tb_phy_xact_engine.sv
- scripts/run_regression.sh, tools/lint.sh
- vivado/scripts/synth_ooc.tcl (+ project scripts skeleton)

## [0.2.0] - 2026-08-25
### Added
- rtl/serdes_ctrl/serdes_supervisor.sv — global FSM (frozen SUP_* encodings),
  init sequencing via engine client slot, bounded retries, DEGRADED/RECOVERY/
  FAULT/SAFE paths, event pulses + telemetry; unit TB T01–T07
- rtl/cdr_ctrl/cdr_ctrl.sv — CDR lock policy engine (qualify/debounce/reacquire,
  restart delay, adapt-freeze hook, signal-detect gating); unit TB 7 scenarios
- Regression now runs all unit TBs across seeds {1,42,2026} in one command

## [0.1.1] - 2026-08-25
### Fixed
- phy_xact_core: drive cnt_*/fault_* telemetry ports and top last_owner (were undriven)
- phy_xact_core: plain READ no longer issued to backend as WRITE opcode
- phy_xact_core: always-ready backend response consumer -> orphan tolerance
  after abort/retry (PHYIF-REQ-004)
- phy_arbiter: RR index computed via automatic function (no latch inference)
- sim model: cancel-on-new-accept response contract; deterministic xorshift PRNG
  seeded by +SEED= (xsim lacks $urandom(seed))
- TB: xsim-strict port widths, grant-order monitors, immediate-commit oracle
  incl. injected-fault/unsupported retry bookkeeping

### Added
- M3 gate evidence: 3-seed xsim regression PASS (104 checks each), verilator
  -Wall clean, OOC synth xc7z020clg484-1 @100 MHz (428 LUT / 448 FF, WNS +2.933 ns)
  -> vivado/reports/m3_phyif/, VERIFICATION_STATUS.md
- vivado/scripts/ooc_synth_m3.tcl (constrained OOC flow)
