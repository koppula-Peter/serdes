# REQUIREMENTS TRACEABILITY

Chain: Requirement → Architecture element → RTL/API → Verification test → Result.

Status vocabulary: PASS / FAIL / BLOCKED / NOT RUN / PARTIAL (mandate §70). Evidence = path.

## M3 scope (PHY Register Interface Engine) — detailed

| Req | Architecture element | RTL / API | Test(s) | Result | Evidence |
|---|---|---|---|---|---|
| PHYIF-REQ-001 read/write/rmw, N clients | L0 engine, §3 SYSTEM_ARCHITECTURE | rtl/phy_if/phy_xact_core.sv, phy_xact_engine_top.sv | T02,T03,T04,T05,T12 | see VERIFICATION_STATUS.md | verification/tb/tb_phy_xact_engine.sv + logs |
| PHYIF-REQ-002 deterministic RR arbitration | phy_arbiter | rtl/phy_if/phy_arbiter.sv | T06a | (gate) | xsim log |
| PHYIF-REQ-003 timeout+retry | xact core FSM | phy_xact_core.sv | T07,T08 | (gate) | xsim log |
| PHYIF-REQ-004 abort | core abort path | phy_xact_core.sv | T10 | (gate) | xsim log |
| PHYIF-REQ-005 bus error bounded retry | core status propagation | phy_xact_core.sv | T09 | (gate) | xsim log |
| PHYIF-REQ-006 write-verify | core verify phase | phy_xact_core.sv | T04b/T12 (corrupt-readback inject) | (gate) | xsim log |
| PHYIF-REQ-007 first/last fault records | fault capture regs | phy_xact_core.sv | T08 | (gate) | xsim log |
| PHYIF-REQ-008 saturating counters | counter block | phy_xact_core.sv | T02..T09 aggregate + wrap test T13 | (gate) | xsim log |
| PHYIF-REQ-009 lock protects critical sequence | arbiter lock_en | phy_arbiter.sv | T06b | (gate) | xsim log |
| PHYIF-REQ-010 reset determinism | global rst_n handling | all M3 RTL | T01a,T01b | (gate) | xsim log |
| PHYIF-REQ-011 unsupported op/address | backend status mapping | sim model + core pass-through | T09b | (gate) | xsim log |
| ARC-REQ-001/002 backend abstraction | phy_backend_if contract | docs/SYSTEM_ARCHITECTURE.md §2 | A-review + TB uses contract only | PASS (review) | this doc + TB |
| ARC-REQ-003 no vendor prims in generic core | coding rule | grep audit at gate | lint/synth scan | (gate) | synth log |
| FEAS-REQ-001 no GT dependency | feasibility gate | FEASIBILITY_ZC702.md | review | PASS | docs/FEASIBILITY_ZC702.md |
| SYS-REQ-003 parameterization | module params | all M3 RTL params | elaboration variants 1/2/4 clients | (gate) | regression matrix |

## Later-milestone requirements

SUP/CDR/TXEQ/RXEQ/EQ/TRAIN/CAL/LANE/DIAG/REG/IRQ/SW/VER/DOC/PKG requirement families are
registered in PRODUCT_REQUIREMENTS.md; rows are appended here as each milestone completes its
chain. No requirement is marked satisfied without evidence.
