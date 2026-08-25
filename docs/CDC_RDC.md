# CDC / RDC PLAN (v0.1)

## Policy
Every asynchronous crossing uses an intentional, named mechanism. Multi-bit buses are never
synchronized bit-wise. Vivado `report_cdc` + `report_clock_interaction` must classify every
crossing as clean / intentional / waived-with-justification / defect before release.

## v0.1 crossings

| Crossing | Mechanism | Status |
|---|---|---|
| none inside phy_xact_engine (single domain) | — | clean by construction |
| aclk → transport clock (future backends) | wrapper-owned: shift/gray or handshake per wrapper; documented per backend | deferred to backend milestones |

## Planned mechanisms (library)
- `rtl/common/sync_2ff.sv` two-flop synchronizer (level)
- toggle-pulse synchronizer for events
- handshake (req/ack with stable data) for control+payload
- async FIFO (`xpm`-free portable implementation) for streaming telemetry later

## RDC
Reset removal synchronized per CLOCK_RESET.md; reset-domain crossings audited when soft-reset
(M12) is added; assertion checks reset-release ordering in TBs.

## Review gates
CDC review at M3 (trivial), M12 (CSR), M13 (full ZC702 build): archive report_cdc /
report_clock_interaction outputs under vivado/reports/<milestone>/.
