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
  $ROOT/rtl/phy_if/phy_arbiter.sv   $ROOT/rtl/phy_if/phy_xact_core.sv \
  $ROOT/rtl/phy_if/phy_xact_engine_top.sv \
  $ROOT/rtl/serdes_ctrl/serdes_supervisor.sv \
  $ROOT/rtl/cdr_ctrl/cdr_ctrl.sv \
  $ROOT/verification/models/phy_backend_sim_model.sv \
  $ROOT/verification/tb/tb_phy_xact_engine.sv \
  $ROOT/verification/tb/tb_serdes_supervisor.sv \
  $ROOT/verification/tb/tb_cdr_ctrl.sv"
SRCS_EXTRA=""

TBS="${TBS:-tb_phy_xact_engine tb_serdes_supervisor}"

( cd "$WORK" && xvlog -sv $SRC $SRCS_EXTRA > "$OUT/xvlog.log" 2>&1 ) \
  || { echo "   compile FAIL"; tail -5 "$OUT/xvlog.log"; exit 3; }

for tb in $TBS; do
  ( cd "$WORK" && xelab $tb -s "snap_$tb" -debug typical -timescale 1ns/1ps \
      > "$OUT/xelab_$tb.log" 2>&1 ) || { echo "   elab FAIL: $tb"; tail -5 "$OUT/xelab_$tb.log"; exit 3; }
  for sd in $SEEDS; do
    ( cd "$WORK" && xsim "snap_$tb" -R -testplusarg "SEED=$sd" ) > "$OUT/${tb}_seed$sd.log" 2>&1
    res=$(grep -o 'REGRESSION_RESULT .*' "$OUT/${tb}_seed$sd.log" || true)
    echo "   $tb seed=$sd => ${res:-NO-RESULT}"
    [[ "$res" == *"PASS"* ]] || fail=1
  done
done

echo "== [3/3] summary =="
if [ "$fail" -eq 0 ]; then
  echo "REGRESSION GATE: PASS (evidence: $OUT)"
else
  echo "REGRESSION GATE: FAIL (evidence: $OUT)"
fi
exit "$fail"
