# DECISIONS

| ID | Decision | Rationale | Date |
|---|---|---|---|
| D-001 | Product = control/management subsystem over abstract `phy_backend_if`; analog PHY behavior never faked in RTL (simulation models excepted, explicitly labelled) | Mandate §0/§95; XC7Z020 has no PL GT | 2026-08-25 |
| D-002 | Single `aclk` control domain v0.1; backends own their CDC and present a synchronous face | Simplicity + verifiable CDC story; documented in CDC_RDC.md | 2026-08-25 |
| D-003 | RMW executed inside phy_xact_core (read→merge→write) as one logical client operation | Upper FSMs stay transport-agnostic; one arbitration slot per logical op | 2026-08-25 |
| D-004 | Deterministic round-robin arbiter with explicit sequence-lock input; software cannot preempt locked critical sequences; override is key-gated at CSR (M12) | Mandate §10 determinism + anti-corruption requirement | 2026-08-25 |
| D-005 | xsim primary simulator (evidence grade), Verilator for lint, Icarus fallback | Available toolchain: Vivado 2025.2 + Verilator 5.032 + Icarus 12.0 | 2026-08-25 |
| D-006 | SelectIO soft-SerDes optional/isolated, never advertised as GT-equivalent | FEASIBILITY §6 | 2026-08-25 |
| D-007 | License BSD-3-Clause | Permissive IP redistribution norm | 2026-08-25 |
| D-008 | Fault records = first+last with timestamp; all counters saturating | Telemetry reconstruction mandate §31 | 2026-08-25 |
