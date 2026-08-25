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
