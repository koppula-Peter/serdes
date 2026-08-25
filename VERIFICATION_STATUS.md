# VERIFICATION STATUS — serdes_phy_ctrl_ip

Status vocabulary: PASS / FAIL / BLOCKED / NOT RUN / PARTIAL (VER-REQ-007).
All paths relative to repository root.

## Milestone M3 — PHY Register Interface Engine (rtl/phy_if)

| Gate item (docs/VERIFICATION_PLAN.md §5) | Status | Evidence |
|---|---|---|
| xsim unit regression, assertions ON | **PASS** — 104/104 checks, seeds 1, 42, 2026 | vivado/reports/m3_phyif/run_seed1.log, run_seed42.log, run_seed2026.log |
| Test matrix T01–T13 incl. negative tests | **PASS** (T01a/b reset, T02–T05 data paths, T06a/b arbitration+lock, T07/T08 timeout+retry+fault records, T09 bus error, T09b unsupported, T10 abort+orphan tolerance, T11 held requests, T12 200-xact randomized scoreboard, T13 counter consistency) | logs above |
| Verilator lint (-Wall) | **PASS** (clean; documented inline waivers only: UNUSEDPARAM pkg constants frozen for M4+, PINCONNECTEMPTY dbg_ts) | vivado/reports/m3_phyif/verilator_lint.log, tools/lint.sh |
| OOC synthesis xc7z020clg484-1 @ 10 ns | **PASS** — 428 LUT (0.80%), 448 FF (0.42%), WNS +2.933 ns, WHS +0.252 ns, 0 violating paths | vivado/reports/m3_phyif/util_m3_phyif_ooc.rpt, timing_m3_phyif_ooc.rpt, vivado_ooc_m3.log |
| Reproduce one-command | PASS | scripts/run_regression.sh |

### Coverage-lite summary (xsim runs)
- FSM states seen: IDLE, ISSUE, WAIT, RDEL (all implemented states).
- Statuses exercised: OK, TIMEOUT, BUS_ERROR, ABORTED, UNSUPPORTED, VERIFY_FAIL.
- Backend ops: READ/WRITE phases (core decomposes RMW into READ+WRITE by design).

### Defects found and fixed during gate execution
1. `phy_xact_core`: telemetry/fault outputs (`cnt_*`, `fault_*`) and top-level
   `last_owner` were never driven — ports now connected.
2. `phy_xact_core`: plain READs issued to backend with WRITE opcode (phase-mux
   default). Fixed to pass `op_q` through; RMW/verify phase behavior unchanged.
3. `phy_xact_core`: backend response ready gated to S_WAIT only — orphaned
   responses after abort stalled the engine. Now always-ready consumer
   (PHYIF-REQ-004 orphan tolerance, mandate §46).
4. `phy_arbiter`: RR index loop variable inferred latch under lint; replaced
   with automatic function; width cleanup.
5. Model: orphaned pending response blocked `cmd_ready`; contract corrected to
   cancel-on-new-accept (single outstanding response).

## Prior milestones

| Item | Status | Evidence |
|---|---|---|
| M0 feasibility review | DONE | docs/FEASIBILITY_ZC702.md |
| M1 requirements baseline v0.1 | DONE | docs/PRODUCT_REQUIREMENTS.md |
| M2 architecture/regmap/verplan/clock-reset/cdc | DONE | docs/ |

## NOT RUN / BLOCKED register

| Item | Status | Reason |
|---|---|---|
| Formal (arbiter fairness, bounded progress) | NOT RUN | scheduled post-M4 (plan §49) |
| Functional covergroups (`COVER`) | NOT RUN | coverage-lite trackers used at M3 gate; full model with M4 regression infra |
| Vivado CDC report | NOT RUN | single-clock design at M3; required from M12 (docs/CDC_RDC.md) |
| Hardware validation on ZC702 + external PHY | **BLOCKED — PHYSICAL PHY HARDWARE REQUIRED** (OI-001) | no external PHY/mezzanine selected yet |
