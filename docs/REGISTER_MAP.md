# REGISTER MAP — serdes_phy_ctrl_ip (draft v0.1)

| | |
|---|---|
| Document ID | SERDES-REG-001 |
| Bus | AXI4-Lite, 32-bit data, byte strobes, word-aligned |
| Convention | `RO`=read-only, `RW`=read/write, `W1C`=write-1-to-clear, `SC`=self-clearing command |

Regions below define the **target map**. Only the engine-facing semantics exist at M3 (as ports);
CSR hardware decode lands at Milestone 12 (see KNOWN_LIMITATIONS). Offsets are frozen design
intent so software can be developed against them:



## 0x000–0x0FF Identification & capabilities
| Offset | Name | Access | Description |
|---|---|---|---|
| 0x000 | ID_MAGIC | RO | 0x5344_5043 ("SDPC") |
| 0x004 | ID_VERSION | RO | [31:24] ABI, [23:16] major, [15:8] minor, [7:0] patch |
| 0x008 | ID_BUILD | RO | RTL revision hash (reproducible-build policy: 0 if unset) |
| 0x00C | CAPABILITIES0 | RO | bit0 CDR,1 TXEQ,2 RXEQ,3 TRAINING,4 CALIB,5 DIAG/PRBS,6 PVT,7 IRQ; [15:8] backend type enum; [23:16] NUM_LANES |
| 0x010 | CAPABILITIES1 | RO | per-lane capability bitmap summary |
| 0x014 | ABI_GUARD | RO | complement of ID_VERSION[31:16] (software sanity check) |

## 0x100–0x1FF Global control
| Offset | Name | Access | Description |
|---|---|---|---|
| 0x100 | CTRL_KEY | RW | unlock key: write 0xA5C3_1P7K sequence value before dangerous writes |
| 0x104 | GLOBAL_CTRL | RW* | [0] enable, [1] soft_reset(SC), [2] diag_mode, [3] arb_lock_override(key-gated) |
| 0x108 | ARB_LOCK_CTRL | RW | [3:0] lock_client, [4] lock_en |
| 0x10C | XACT_TIMEOUT_DEFAULT | RW | default backend timeout cycles |
| 0x110 | XACT_RETRY_DEFAULT | RW | default retry max |
| 0x114 | DEGRADE_POLICY | RW | lane failure policy select |

## 0x200–0x2FF Global status / telemetry
| 0x200 GLOBAL_STATE RO — supervisor FSM state
| 0x204 LANE_GROUP_STATE RO — per-lane state bitmap summary
| 0x208 UPTIME_CNT RO — free-running ms tick counter
| 0x20C LINK_UP_CNT / 0x210 LINK_DOWN_CNT / 0x214 RETRAIN_CNT RO

## 0x300–0x3FF Interrupts & faults
| 0x300 IRQ_EN RW | 0x304 IRQ_MASK RW | 0x308 IRQ_STATUS W1C | 0x30C IRQ_RAW RO
| 0x310 FAULT_FIRST_LO / 0x314 FAULT_FIRST_HI RO (ts|op|lane|status|addr)
| 0x318 FAULT_LAST_LO / 0x31C FAULT_LAST_HI RO
| 0x320 FAULT_CLEAR SC — any write clears fault records

## 0x700–0x77F PHY transaction engine (CSR decode at M12; semantics fixed now)
| Offset | Name | Access |
|---|---|---|
| 0x700 | XACT_COUNT | RO saturating total transactions |
| 0x704 | XACT_OK_CNT | RO |
| 0x708 | XACT_ERR_CNT | RO |
| 0x70C | XACT_TIMEOUT_CNT | RO |
| 0x710 | XACT_RETRY_CNT | RO |
| 0x714 | XACT_BUSY_STATUS | RO {busy, last_status[2:0], last_client[3:0]} |
| 0x718 | SW_XACT_CMD | SC software client doorbell (uses client index 0) |
| 0x71C | SW_XACT_ADDR | RW target PHY address |
| 0x720 | SW_XACT_WDATA | RW |
| 0x724 | SW_XACT_WSTRB | RW |
| 0x728 | SW_XACT_CTRL | RW timeout/retry/verify/op fields |
| 0x72C | SW_XACT_RSP | RO {done flag(W1C via 0x730), status, rdata} |

## 0x800+ Per-lane windows (stride 0x40)
Lane N base = 0x800 + N*0x40: ENABLE/POLARITY RW, STATE RO, CDR_STATUS RO,
TXEQ_CURRENT/CANDIDATE/BEST/LKG RW-RO mix, RXEQ_* , QUALITY METRIC RO,
LANE_FAULT_REASON RO (exact degrade reason code, not a generic error bit).

Reserved ranges: 0x400 training, 0x500 calibration, 0x600 diagnostics — defined at M9/M10/M12.

Safety notes (REG-REQ-002): GLOBAL_CTRL bits other than enable require KEY sequence;
mismatched key ⇒ write ignored + sticky SECURITY_FAULT in IRQ_RAW. Reserved fields read 0,
writes ignored.
