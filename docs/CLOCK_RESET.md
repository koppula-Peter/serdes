# CLOCK & RESET PLAN (v0.1)

## Clock domains

| Domain | Source | Freq (ZC702) | Used by | Notes |
|---|---|---|---|---|
| aclk | PS FCLK0 via BD | 100 MHz nominal (param) | entire control plane v0.1 incl. phy_xact_engine + parallel backend face | single domain by design (D-002) |
| ps_axi_aclk | same net as aclk v1 | — | AXI CSR (M12) | identical domain; formal CDC check still run |
| backend-local | owned inside each backend | per transport (e.g., MDIO MDC ≪1 MHz enable-divided) | mdio/spi/i2c/gt_drp wrappers | CDC contained behind phy_backend_if; each crossing documented in that wrapper's header |

Future SelectIO profile adds: refclk (200 MHz board osc), IDELAYCTRL ref (200 MHz), BUFIO/BUFR
per-bank capture clocks — specified in Profile C doc before any RTL.

## Resets

| Reset | Origin | Scope | Synchronization |
|---|---|---|---|
| por | board/PS | everything | assumed held ≥1 ms after rails stable (UG850 power section) |
| aresetn | PS FCLK_RESET_N / proc_sys_reset in BD | control plane | deassert synced to aclk (proc_sys_reset) |
| soft reset | GLOBAL_CTRL bit (M12) | engines, not CSR | internally synchronized; self-clearing |
| backend reset | per-backend | PHY transport state | owned by wrapper |

Rules: no logic may depend on unrecorded clock relations; every crossing intentional
(see CDC_RDC.md); reset-during-operation tests are mandatory per milestone (T01 family).
