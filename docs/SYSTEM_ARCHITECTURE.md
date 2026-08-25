# SYSTEM ARCHITECTURE — serdes_phy_ctrl_ip

| | |
|---|---|
| Document ID | SERDES-ARC-001 |
| Status | v0.1 (M3 scope implemented; later blocks specified) |

## 1. Layering (strict separation)

```
L5  Software        bare-metal / FreeRTOS / Linux + libserdesphy + serdesctl
L4  CSR/IRQ         AXI4-Lite register block, interrupts, telemetry      (rtl/registers, top)
L3  Policy engines  supervisor, training, calibration, diagnostics       (rtl/serdes_ctrl …)
L2  Per-lane algos  CDR ctrl, TX EQ, RX EQ, EQ coordinator               (rtl/cdr_ctrl …)
L1  Lane manager    multi-lane scheduling/degrade policy                 (rtl/lane)
L0  Transport       phy_xact_engine: arbitration+timeout+retry+faults    (rtl/phy_if)   ← M3
B   Backend         phy_backend_if → mdio/spi/i2c/parallel/gt_drp        (backend/*)
```

Rule: layer N never sees timing of layer B; all PHY access is transaction-based.

## 2. phy_backend_if contract (v0.1)

Single synchronous request/response channel, all signals in `aclk` domain for v0.1
(backends that cross domains own their CDC internally and present this face):

```
cmd_valid/cmd_ready : handshake (ready may be 0 while busy)
cmd_op              : PHY_OP_READ=00 | PHY_OP_WRITE=01 | PHY_OP_RMW=10
cmd_addr[A-1:0], cmd_wdata[D-1:0], cmd_wstrb[D/8-1:0], cmd_lane[3:0]
rsp_valid/rsp_ready : response handshake (engine holds rsp_ready low when not waiting)
rsp_rdata[D-1:0], rsp_status: OK|TIMEOUT|BUS_ERROR|ABORTED|UNSUPPORTED|VERIFY_FAIL
```

RMW is executed by L0 (read→merge→write) so upper layers issue one logical RMW.
Backend must respond exactly once per accepted command.

## 3. M3 block — phy_xact_engine (implemented)

```
client[0..C-1] ──req──> ┌───────────┐  grant  ┌─────────────┐  cmd  ┌─────────┐
                        │ phy_      │────────>│ phy_xact_   │──────>│ backend │
                        │ arbiter   │         │ core        │<──────│ if      │
                        │ (RR+lock) │         │ timeout/retry/rmw/verify │
client[0..C-1] <─resp── │           │         │ first/last fault recs    │
                        └───────────┘         └─────────────┘        └─────────┘
```

- **phy_arbiter**: deterministic round-robin from last grant; `lock_en/lock_client` pins the
  arbiter to one client during atomic sequences (PHYIF-REQ-002/-009).
- **phy_xact_core**: IDLE→ISSUE→WAIT(+RMW read phase, verify phase)→RETRY_DELAY→done.
  Per-request `timeout_cyc`, `retry_max`, `verify_en`; abort input; fault records with
  timestamp from internal free-running counter; saturating counters.
- **phy_xact_engine_top**: arrayed client ports, backend port, status/counters/fault outputs,
  global clear, parameters: CLIENTS, ADDR_W, DATA_W, TIMEOUT_W, CNT_W.

Client protocol: hold `cr_valid` until `*_ready` sampled high in same cycle; `rsp_done` is a
1-cycle pulse; response fields valid with pulse. Abort accepted only from the owning client
while its transaction is in flight.

## 4. Planned hierarchy (subsequent milestones)

```
serdes_phy_ctrl_top
├── axi_csr            (AXI4-Lite slave, REG-REQ-001/002)
├── irq_ctrl           (level→pulse, W1C, per-lane aggregation)
├── supervisor_fsm     (SUP states, reset sequencing, monitor)
├── training_engine    (TRAIN states; policy_if for future protocols)
├── calib_controller   (CAL states; profile store w/ CRC)
├── diag_engine        (PRBS/BERT hooks, loopback, dumps)
├── lane_mgr[NUM_LANES]
│   ├── cdr_ctrl       (lock qualify/debounce/reacquire)
│   ├── txeq_ctrl      (cursor bounds, sweeps, rollback)
│   ├── rxeq_ctrl      (capability-gated CTLE/DFE/adapt)
│   └── eq_coord       (search strategy, metrics normalization)
├── metrics_blk        (windowed normalized quality, saturating counters)
├── pvt_monitor        (XADC PS interface where available)
└── phy_xact_engine    (this milestone)
        └── phy_backend_* (selected at integration)
```

## 5. Clock & Reset (summary — full doc CLOCK_RESET.md)

- v0.1 single domain `aclk` (=FCLK0 100 MHz target on ZC702), active-low `aresetn`.
- Backend CDC owned inside backends (e.g., MDIO clock enable divider, GT DRP DRPCLK domain).
- All resets synchronized deassertion (`sync_2ff` on release); reset-domain crossing reviewed at CDC stage.

## 6. Determinism & Safety Rules

1. No unbounded waits: every wait has a counter bound (param or register field).
2. Retry policies bounded by configured maxima; failure escalates to explicit error status.
3. Fault records capture first/last events with timestamp — telemetry reconstructs history.
4. Software participates in round-robin like any client but **cannot preempt a locked critical
   sequence**; the only override is the explicit `arb_lock_override`, UNLOCK-key protected at
   CSR level (implemented at M12, REGISTER_MAP 0x104/0x108).
5. Generic core contains no vendor primitives (ARC-REQ-003).

## 7. Verification architecture

Unit TB per module (self-checking, assertions on), simulated backend model with fault injection,
scoreboard regression, covergroups behind `ifdef COVER, formal targets: arbiter fairness,
no-deadlock, bounded progress (VER plan). One-command regression via scripts/run_regression.sh.
