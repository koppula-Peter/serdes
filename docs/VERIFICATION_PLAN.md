# VERIFICATION PLAN — serdes_phy_ctrl_ip

| | |
|---|---|
| Document ID | SERDES-VER-001 |
| Simulators | AMD xsim (primary, evidence), Verilator lint, Icarus fallback |
| Method | Self-checking TBs + scoreboard + SVA + fault injection + covergroups (`ifdef COVER) |

## 1. Testbench architecture

- `verification/models/phy_backend_sim_model.sv` — configurable fake PHY: memory-backed regs,
  programmable response latency, timeout injection, bus-error injection, corrupted readback,
  UNSUPPORTED address region; deterministic via `+SEED=` plusarg.
- Unit TBs in `verification/tb/tb_<module>.sv`; each prints
  `TEST n: <name> ... PASS/FAIL` lines and final `REGRESSION <PASS|FAIL>` plus nonzero exit on fail.
- Assertions compiled under xsim; failures abort regression.

## 2. Milestone test matrix (M3 — phy_xact_engine)

| Test ID | Stimulus | Expected / Requirement |
|---|---|---|
| T01 | Reset pulse mid-idle and mid-transaction | No spurious cmd_valid after reset release; engine idle; PHYIF-REQ-010 |
| T02 | WRITE then READ same addr | rdata == wdata; OK status; counters advance; PHYIF-REQ-001 |
| T03 | READ of untouched location | model default value; OK |
| T04 | RMW with partial strobes | untouched bytes preserved in model & readback; PHYIF-REQ-001 |
| T05 | Back-to-back transactions from one client | no dead cycle deadlock; correct ordering |
| T06a | 4 clients contend simultaneously | strict RR order 0,1,2,3 wrap; all complete; PHYIF-REQ-002 |
| T06b | arb lock to client2 during contention | only client2 served until unlock; others pending not lost; PHYIF-REQ-009 |
| T07 | Timeout injected once, retry_max=2 | TIMEOUT attempt → retry → OK; retry_cnt=1; PHYIF-REQ-003 |
| T08 | Persistent timeout | final TIMEOUT status; first_fault==last_fault record fields correct; PHYIF-REQ-007 |
| T09 | Backend BUS_ERROR injection | BUS_ERROR propagates; err counter increments; bounded retries; PHYIF-REQ-005 |
| T09b | Address beyond supported window | UNSUPPORTED status; PHYIF-REQ-011 |
| T10 | Abort while waiting for slow rsp | ABORTED within bounded cycles; late orphan response ignored; PHYIF-REQ-004 |
| T11 | Request held while busy | ready gating honored; no dropped/duplicated grants |
| T12 | Randomized: 200 xacts, random client/op/strobe/fault windows, seed-controlled | scoreboard matches model state; zero mismatches; all statuses legal |

Assertions (SVA, active in xsim runs): backend single-response-per-cmd; cmd stable until ready;
no grant when core busy; done pulses exactly once per completed transaction; fault-record fields
never X on error; RR pointer advances only on grant.

## 3. Coverage model

Coverpoints per milestone: FSM states × transitions, op codes, status codes, retry counts 0..max,
timeout vs success paths, lock mode on/off, concurrent-client combinations. Reviewed at each gate;
gaps → new tests (VER-REQ-004).

## 4. Fault injection catalogue (mandate §46 subset applicable to M3)

PHY read/write timeout, bus error, orphaned responses, reset-during-operation, interrupt-free
deterministic recovery verified by post-fault healthy transaction.

## 5. Gates

M3 exits when: all tests PASS on xsim with assertions ON; verilator lint clean;
OOC synthesis clean for xc7z020clg484-1 with utilization report archived; coverage reviewed;
VERIFICATION_STATUS.md updated with evidence paths.
