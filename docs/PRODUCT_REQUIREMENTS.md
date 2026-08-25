# PRODUCT REQUIREMENTS — serdes_phy_ctrl_ip

| | |
|---|---|
| Document ID | SERDES-PRD-001 |
| Status | v0.1 BASELINE (frozen for M3 development) |
| Applies to | serdes_phy_ctrl_ip, all hardware profiles |

Requirement ID scheme: `<FAMILY>-REQ-<nnn>`. Families: SYS, FEAS, ARC, PHYIF, SUP, CDR, TXEQ,
RXEQ, EQ, TRAIN, CAL, LANE, DIAG, REG, IRQ, SW, VER, DOC, PKG. Each requirement is
verifiable; verification method codes: **A**=analysis/review, **S**=simulation, **F**=formal,
**T**=synthesis/implementation tool evidence, **H**=hardware (may be BLOCKED).

## 1. System & Feasibility

| ID | Requirement | Method |
|---|---|---|
| FEAS-REQ-001 | Architecture SHALL NOT depend on GTX/GTP/GTH presence in ZC702 PL. | A |
| FEAS-REQ-002 | All analog PHY functions (CDR loop, CTLE, DFE, TX driver emphasis, eye scan) SHALL reside in the backend (external PHY or future GT), never in control RTL. | A |
| SYS-REQ-001 | IP SHALL operate as SerDes/PHY control plane over AXI4-Lite from Zynq PS. | S,T,H |
| SYS-REQ-002 | IP SHALL support 1–8 lanes parameterized (`NUM_LANES`), architecture extensible beyond. | S,T |
| SYS-REQ-003 | All engines SHALL be parameterizable and individually excludable via ENABLE_* parameters. | T,S |

## 2. Backend Abstraction

| ID | Requirement | Method |
|---|---|---|
| ARC-REQ-001 | Upper layers SHALL communicate with any PHY exclusively through `phy_backend_if` transactions (read/write/rmw/poll/reset/status primitives). | A,S |
| ARC-REQ-002 | Backends (MDIO/SPI/I2C/parallel/GT-DRP) SHALL implement the identical transaction contract; upper-layer FSMs SHALL NOT contain transport-specific timing. | A,S |
| ARC-REQ-003 | Generic core RTL SHALL NOT instantiate vendor GT primitives. | A,T |
| ARC-REQ-004 | Capability bitmaps per lane SHALL declare supported operations; engines SHALL refuse unsupported operations with explicit status. | S |

## 3. PHY Register Interface Engine (first block)

| ID | Requirement | Method |
|---|---|---|
| PHYIF-REQ-001 | Engine SHALL support READ, WRITE, masked READ-MODIFY-WRITE transactions issued by N concurrent clients. | S,F |
| PHYIF-REQ-002 | Arbitration SHALL be deterministic round-robin; an atomic-sequence lock SHALL restrict service to the locking client while active. | S,F |
| PHYIF-REQ-003 | Every transaction SHALL have a configurable timeout; expiry yields TIMEOUT status after bounded retry attempts (configurable per request). | S |
| PHYIF-REQ-004 | Engine SHALL support transaction abort by the owning client; result status ABORTED; no unbounded wait. | S |
| PHYIF-REQ-005 | Backend-reported bus errors SHALL propagate as BUS_ERROR without retry storming beyond configured retries. | S |
| PHYIF-REQ-006 | Optional write-verify: WRITE followed by read-back compare against written data (masked); mismatch ⇒ VERIFY_FAIL status. | S |
| PHYIF-REQ-007 | First-fault and last-fault records (timestamp, op, addr, lane, status, attempt count) SHALL be captured, exposed, and clearable. | S |
| PHYIF-REQ-008 | Engine SHALL maintain saturating counters: total, ok, error, timeout, retry counts. | S,T |
| PHYIF-REQ-009 | No client SHALL be able to corrupt an active locked critical sequence without asserting the explicit override path. | F,S |
| PHYIF-REQ-010 | Reset at ANY point of an active transaction SHALL leave engine in deterministic idle state with no stuck backend command valid >1 cycle after reset release. | S,A |
| PHYIF-REQ-011 | Unsupported addresses/operations reported by a backend SHALL yield UNSUPPORTED status to the requester. | S |

## 4. Supervisor / CDR / EQ / Training / Calibration / Lanes (subsequent milestones)

| ID | Requirement | Method |
|---|---|---|
| SUP-REQ-001 | Global supervisor FSM SHALL implement documented states (RESET…SAFE_STATE) with entry conditions, bounded timeouts, retry limits, telemetry and interrupt hooks for every transition. | S |
| CDR-REQ-001..012 | CDR control per docs/CDR_CONTROL.md v0.1 scope: enable/disable sequencing, lock/unlock qualification counters, acquisition timeout, reacquisition policy, hold/freeze, statistics. Analog CDR itself is backend-owned. | S,H(BLOCKED until HW) |
| TXEQ-REQ-001..010 | TX pre-emphasis control: abstract main/pre/post cursor + swing/strength within backend-declared bounds; manual/sweep/training modes; current/candidate/best/last-known-good settings; rollback on metric degradation. | S,H(BLOCKED) |
| RXEQ-REQ-001..010 | RX equalization control gated by capability bitmap (CTLE/DFE/AGC/adapt); unsupported ops refused; convergence + rollback policies. | S,H(BLOCKED) |
| EQ-REQ-001..008 | Coordinated search engine: candidate generation, evaluation windows, normalized metrics, saturation detection, bounded iterations, rollback to known-good. | S |
| TRAIN-REQ-001..012 | Protocol-independent training FSM per docs/LINK_TRAINING.md; success requires measured quality criteria ≥ thresholds; bounded retraining; per-lane/group modes. | S |
| CAL-REQ-001..010 | Calibration controller: startup/on-demand/periodic/PVT-triggered policies; verify-before-store; rollback preserves last known-good profile. | S |
| LANE-REQ-001..014 | Multi-lane manager: per-lane state, group readiness, configurable degrade policy (FAIL_ALL_ON_SINGLE_LANE, ALLOW_DEGRADED_OPERATION, ISOLATE_FAILED_LANE, RETRAIN_*), single failed lane never deadlocks controller. | S |
| DIAG-REQ-001..010 | Diagnostics: PRBS gen/check hooks (PRBS7/15/23/31 where backend supports), error counters, BER estimate with window normalization, loopback control, distinguishable diagnostic mode. | S,H(BLOCKED) |

## 5. Registers, Interrupts, Telemetry

| ID | Requirement | Method |
|---|---|---|
| REG-REQ-001 | AXI4-Lite CSR map per docs/REGISTER_MAP.md; identification block exposes magic/version/ABI/capabilities/lane count/backend type — software MUST NOT infer capabilities from version alone. | S,H |
| REG-REQ-002 | Dangerous global commands SHALL require UNLOCK key sequencing; command bits self-clearing; W1C status semantics where specified. | S |
| IRQ-REQ-001 | Interrupt block: enable/mask/status(W1C)/level-to-PS with sources per §30 of mandate incl. per-lane aggregation. | S,H |
| TELE-REQ-001 | Telemetry sufficient to reconstruct cause of link failure (state history pointers, fault records, counters, timestamps). | S |

## 6. Software

| ID | Requirement | Method |
|---|---|---|
| SW-REQ-001 | Bare-metal driver with API per mandate §52, versioned ABI check on init. | H/SIL |
| SW-REQ-002 | 8 Vitis examples with documented expected output. | H(BLOCKED until board run) |
| SW-REQ-003 | FreeRTOS-safe wrappers (ISR→task notification, mutexed access). | A,H |
| SW-REQ-004 | Linux platform driver + DT binding + debugfs diagnostics + userspace libserdesphy + serdesctl CLI. | H(BLOCKED until Linux env/board) |
| SW-REQ-005 | Software reads magic → ABI → capabilities → lanes before operating; refuses incompatible ABI. | S(ABI sim)/H |

## 7. Verification & Quality

| ID | Requirement | Method |
|---|---|---|
| VER-REQ-001 | Every subsystem has self-checking TB with reset/boundary/illegal-input/timeout/fault-injection coverage before integration. | S |
| VER-REQ-002 | Regression runs via one command; machine-readable summary; PASS/FAIL exit code. | S |
| VER-REQ-003 | Assertions active in regression; zero assertion failures allowed at gate. | S |
| VER-REQ-004 | Functional covergroups for FSMs/faults/timeouts reviewed each milestone; gaps drive new tests. | S |
| VER-REQ-005 | CDC report clean or waived-with-justification before release; no inferred latches; no comb loops. | T |
| VER-REQ-006 | Timing closure on target part recorded from implementation, never estimated in reports. | T |
| VER-REQ-007 | Verification statuses use PASS/FAIL/BLOCKED/NOT RUN/PARTIAL with evidence paths. | A |

## 8. Documentation & Packaging

| ID | Requirement | Method |
|---|---|---|
| DOC-REQ-001 | Full doc set per repository structure §7 exists and is internally consistent. | A |
| DOC-REQ-002 | REQUIREMENTS_TRACEABILITY.md links every requirement → architecture element → RTL/API → test → result. | A |
| PKG-REQ-001 | Vivado IP-packaged (VLNV, AXI metadata, XDC, example design) buildable purely from scripts. | T |

## 9. Non-goals

Per mandate §91: not a PCIe/Ethernet-MAC/PCS/JESD/SpaceWire implementation; not analog CDR/CTLE/DFE.
