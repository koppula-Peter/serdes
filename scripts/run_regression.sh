#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_regression.sh — one-command verification gate (mandate §51).
#
# Runs: verilator lint (-Wall) then the phy_xact_engine xsim regression across
# fixed seeds. Assertions compile automatically under xsim SV mode.
# Exits non-zero if any stage fails. Evidence -> verification/regressions/latest
#
# Environment overrides:
#   VIVADO_SETTINGS  path to settings64.sh   (default: 2025.2 install)
#   NCURSES5_SHIM    dir containing libncurses.so.5 symlink (optional; needed
#                    when the host only ships ncurses6)
#   SEEDS            space-separated seed list (default: "1 42 2026")
# -----------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/verification/regressions/latest"
mkdir -p "$OUT"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/home/peter/Desktop/xilinx_tools/2025.2/Vivado/settings64.sh}"
SEEDS="${SEEDS:-1 42 2026}"

fail=0

echo "== [1/3] verilator lint =="
if verilator --lint-only -Wall --top-module phy_xact_engine_top \
     "$ROOT/rtl/common/serdes_phy_ctrl_pkg.sv" \
     "$ROOT/rtl/phy_if/phy_arbiter.sv" \
     "$ROOT/rtl/phy_if/phy_xact_core.sv" \
     "$ROOT/rtl/phy_if/phy_xact_engine_top.sv" \
     > "$OUT/verilator_lint.log" 2>&1; then
  echo "   lint: CLEAN"
else
  echo "   lint: FAIL ($OUT/verilator_lint.log)"; fail=1
fi

echo "== [2/3] xsim regression (assertions ON) =="
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS" >/dev/null 2>&1 || { echo "cannot source $VIVADO_SETTINGS"; exit 2; }
[ -n "${NCURSES5_SHIM:-}" ] && export LD_LIBRARY_PATH="$NCURSES5_SHIM:${LD_LIBRARY_PATH:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$ROOT/rtl/common/serdes_phy_ctrl_pkg.sv \
  $ROOT/rtl/phy_if/phy_arbiter.sv \
  $ROOT/rtl/phy_if/phy_xact_core.sv \
  $ROOT/rtl/phy_if/phy_xact_engine_top.sv \
  $ROOT/verification/models/phy_backend_sim_model.sv \
  $ROOT/verification/tb/tb_phy_xact_engine.sv"

( cd "$WORK" \
  && xvlog -sv $SRC        > "$OUT/xvlog.log" 2>&1 \
  && xelab tb_phy_xact_engine -s tb_gate -debug typical -timescale 1ns/1ps \
                           > "$OUT/xelab.log" 2>&1 ) || { echo "   compile/elab FAIL"; exit 3; }

for sd in $SEEDS; do
  ( cd "$WORK" && xsim tb_gate -R -testplusarg "SEED=$sd" ) > "$OUT/run_seed$sd.log" 2>&1
  res=$(grep -o 'REGRESSION_RESULT .*' "$OUT/run_seed$sd.log" || true)
  echo "   seed=$sd => ${res:-NO-RESULT}"
  [[ "$res" == *"PASS"* ]] || fail=1
done

echo "== [3/3] summary =="
if [ "$fail" -eq 0 ]; then
  echo "REGRESSION GATE: PASS (evidence: $OUT)"
else
  echo "REGRESSION GATE: FAIL (evidence: $OUT)"
fi
exit "$fail"
