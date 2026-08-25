# CURRENT_WORK

**Session 1 — 2026-08-25**

## Completed
- M0: FEASIBILITY_ZC702.md (sourced from UG850/DS190/UG585/UG471/pinout data)
- M1: PRODUCT_REQUIREMENTS.md v0.1 baseline
- M2: SYSTEM_ARCHITECTURE.md, REGISTER_MAP.md v0.1, VERIFICATION_PLAN.md,
      IMPLEMENTATION_PLAN.md, CLOCK_RESET.md, CDC_RDC.md, REFERENCES.md
- Repo scaffolded; git initialized with checkpoint commits
- M3: PHY Register Interface Engine implemented (rtl/phy_if/) + sim model + TB

**Session 2 — 2026-08-25**

## Completed
- Repo extracted to standalone project (github.com/koppula-Peter/serdes);
  full history preserved; monorepo experiment rolled back cleanly
- M3 gate execution (VERIFICATION_STATUS.md):
  - xsim regression PASS 104/104 on seeds 1/42/2026, assertions ON
  - verilator -Wall lint clean (tools/lint.sh)
  - OOC synthesis xc7z020clg484-1 @100 MHz: 428 LUT / 448 FF, WNS +2.933 ns
  - Defects fixed: undriven telemetry/fault outputs; READ-as-WRITE backend
    opcode bug; orphan-response stall (always-ready consumer); arbiter latch
  - scripts/run_regression.sh one-command gate; evidence archived under
    vivado/reports/m3_phyif/

## Next bounded task
- M4 SerDes Supervisor: spec (FSM table per mandate §11) + RTL + unit TB;
  reuse phy_backend_sim_model via the engine client port.

## Toolchain
Vivado/xvlog/xsim 2025.2 (/home/peter/Desktop/xilinx_tools/2025.2), Verilator 5.032, Icarus 12.0.
Note: xsim needs libncurses.so.5 shim on this host (NCURSES5_SHIM env for run_regression.sh).
