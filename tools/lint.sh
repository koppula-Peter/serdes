#!/usr/bin/env bash
# tools/lint.sh — Verilator lint waiver of record for the RTL tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec verilator --lint-only -Wall --top-module phy_xact_engine_top \
  "$ROOT/rtl/common/serdes_phy_ctrl_pkg.sv" \
  "$ROOT/rtl/phy_if/phy_arbiter.sv" \
  "$ROOT/rtl/phy_if/phy_xact_core.sv" \
  "$ROOT/rtl/phy_if/phy_xact_engine_top.sv"
