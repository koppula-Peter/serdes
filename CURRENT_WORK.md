# CURRENT_WORK

> **SESSION HANDOFF — read this block first in every new session.**
> It is updated in real time. If a session dies/rolls over, the next one resumes
> from "Immediate next action" without re-deriving anything.

## SESSION HANDOFF
| Field | Value |
|---|---|
| Repo | `/home/peter/Desktop/serdes` → `github.com/koppula-Peter/serdes` (private), branch `main` |
| Milestone now | **M4 SerDes Supervisor** — RTL lint-clean, unit TB RED, mid-debug |
| Immediate next action | Rebuild & rerun M4 sim, read `[RSP]` trace lines: compare returned `rd` vs `A501`. Suspects: engine rdata path / executor capture timing. Then fix, get T01–T07 green, strip `[SUP]`/`[RSP]` temp traces |
| Env quirks | xsim needs `LD_LIBRARY_PATH=/tmp/opencode/ncurses5-shim` (host lacks libncurses.so.5). Vivado settings: `/home/peter/Desktop/xilinx_tools/2025.2/Vivado/settings64.sh`. Keep sim scratch OUT of repo: build in `/tmp/opencode/sim/` with absolute source paths |
| Commands | Lint: `./tools/lint.sh` · Full gate: `NCURSES5_SHIM=/tmp/opencode/ncurses5-shim ./scripts/run_regression.sh` · Quick status: `./scripts/status.sh` |
| Sim file list | pkg + rtl/phy_if/{arbiter,core,top} + rtl/serdes_ctrl/serdes_supervisor.sv + models/phy_backend_sim_model.sv + tb/tb_serdes_supervisor.sv |

## ROADMAP SNAPSHOT (authoritative: docs/IMPLEMENTATION_PLAN.md)

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Feasibility | ✅ DONE | docs/FEASIBILITY_ZC702.md |
| M1 Requirements v0.1 | ✅ DONE | docs/PRODUCT_REQUIREMENTS.md |
| M2 Architecture set | ✅ DONE | docs/SYSTEM_ARCHITECTURE.md et al. |
| M3 PHY Register Interface | ✅ **GATED GREEN** | xsim 104/104 ×seeds{1,42,2026}; lint clean; OOC xc7z020 @100MHz WNS +2.933ns; vivado/reports/m3_phyif/ |
| **M4 SerDes Supervisor** | 🔨 IN PROGRESS (~80%) | RTL done+linted; TB T01–T07 written; debug: init hits FAULT(ID) at DISCOVERY despite preload |
| M5 CDR Controller | ⬜ NEXT after M4 | plan §12 states; tests: immediate/delayed/unstable/no-lock/loss/reacq/repeat-fail |
| M6 TX Pre-emphasis | ⬜ | bounds/sweep/converge/bad-metric |
| M7 RX Equalization | ⬜ | capability-gated CTLE/DFE/adapt |
| M8 EQ Coordinator | ⬜ | joint search, multi-channel model |
| M9 Link Training | ⬜ | TRAIN FSM + failure matrix |
| M10 Calibration | ⬜ | verify-before-store, rollback |
| M11 Multi-lane manager | ⬜ | 1→2→4 lanes, degrade policy |
| M12 AXI/IRQ productization | ⬜ | CSR map freeze, AXI stress |
| M13 ZC702 integration | ⬜ | BD scripts, timing/CDC/DRC |
| M14 Vitis bare-metal | ⬜ | driver + 8 examples |
| M15 Linux stack | ⬜ | DT binding, driver, serdesctl |
| M16 Hardening | ⬜ | long regress, reviews |
| M17 Release | ⬜ | manifest + checklist |
| HW validation (ZC702+ext PHY) | 🚫 BLOCKED | OI-001: no physical PHY card selected — stays BLOCKED, never faked |

Overall program: ~35% (all control-plane docs + transport layer gated; supervisor landing).

## SESSION LOG
- **S1**: M0–M2 docs; repo scaffold.
- **S2**: M3 implemented + GATED (see VERIFICATION_STATUS.md); repo extracted from
  IP_dev monorepo to standalone `koppula-Peter/serdes`; monorepo rolled back cleanly.
- **S3 (current)**: Session-continuity protocol added (this doc + scripts/status.sh).
  M4 supervisor RTL authored & linted (`rtl/serdes_ctrl/serdes_supervisor.sv`);
  TB authored; **debugging**: DISCOVERY→FAULT(ID) though model preloaded with A501
  after reset-release; `[RSP]` transaction trace added, rerun pending.
