// -----------------------------------------------------------------------------
// phy_xact_core.sv — PHY transaction engine core.
// Implements: PHYIF-REQ-001/003/004/005/006/007/008/010/011.
//
// One logical client operation = one arbitration slot. RMW is decomposed here
// into backend READ + masked WRITE so upper layers stay transport-agnostic.
// Optional write verification reads back and compares ONLY the strobed bytes.
//
// Client contract: hold request until req_ready; hold abort until done pulse;
// done/status/rdata are valid during the single-cycle rsp_done pulse.
//
// Counter semantics (telemetry contract):
//   cnt_total   : completed transactions (any status)
//   cnt_ok      : completed with PHY_ST_OK
//   cnt_err     : completed with non-OK status (incl. aborted)
//   cnt_timeout : timed-out ATTEMPTS
//   cnt_retry   : retries issued
//
// Fault records capture first and last failed attempt (timestamp, op, address,
// lane, status, attempt index). All counters saturate at all-ones.
// -----------------------------------------------------------------------------
module phy_xact_core #(
  parameter int unsigned ADDR_W      = 16,
  parameter int unsigned DATA_W      = 16,
  parameter int unsigned LANE_W      = 4,
  parameter int unsigned TIMEOUT_W   = 24,
  parameter int unsigned RETRY_W     = 4,
  parameter int unsigned CNT_W       = 32,
  parameter int unsigned TS_W        = 32,
  parameter int unsigned RETRY_DELAY = 8,
  localparam  int unsigned STRB_W    = DATA_W/8,
  localparam  int unsigned RD_W      = (RETRY_DELAY <= 1) ? 1 : $clog2(RETRY_DELAY),
  localparam  int unsigned FAULT_W   = TS_W + ADDR_W + LANE_W + 5 + RETRY_W
)(
  input  wire logic clk,
  input  wire logic rst_n,

  output wire logic accept_ready,
  input  wire logic                 g_valid,
  input  wire logic [1:0]           g_op,
  input  wire logic [ADDR_W-1:0]    g_addr,
  input  wire logic [DATA_W-1:0]    g_wdata,
  input  wire logic [STRB_W-1:0]    g_wstrb,
  input  wire logic [LANE_W-1:0]    g_lane,
  input  wire logic [TIMEOUT_W-1:0] g_timeout_cyc,
  input  wire logic [RETRY_W-1:0]   g_retry_max,
  input  wire logic                 g_verify_en,

  input  wire logic abort_req,

  output wire logic              be_cmd_valid,
  input  wire logic              be_cmd_ready,
  output logic      [1:0]        be_op,
  output wire logic [ADDR_W-1:0] be_addr,
  output wire logic [DATA_W-1:0] be_wdata,
  output wire logic [STRB_W-1:0] be_wstrb,
  output wire logic [LANE_W-1:0] be_lane,
  input  wire logic              be_rsp_valid,
  output wire logic              be_rsp_ready,
  input  wire logic [2:0]        be_rsp_status,
  input  wire logic [DATA_W-1:0] be_rsp_rdata,

  output wire logic              x_done,
  output wire logic [2:0]        x_status,
  output wire logic [DATA_W-1:0] x_rdata,

  input  wire logic             fault_clear,
  output wire logic [FAULT_W-1:0] fault_first,
  output wire logic [FAULT_W-1:0] fault_last,
  output wire logic             fault_first_v,
  output wire logic             fault_last_v,
  output wire logic [CNT_W-1:0] cnt_total,
  output wire logic [CNT_W-1:0] cnt_ok,
  output wire logic [CNT_W-1:0] cnt_err,
  output wire logic [CNT_W-1:0] cnt_timeout,
  output wire logic [CNT_W-1:0] cnt_retry,
  output wire logic [TS_W-1:0]  dbg_ts,
  output wire logic [2:0]       dbg_state
);
  import serdes_phy_ctrl_pkg::*;

  localparam logic [2:0] S_IDLE  = 3'd0,
                         S_ISSUE = 3'd1,
                         S_WAIT  = 3'd2,
                         S_RDEL  = 3'd3;

  logic [2:0] state_q;

  logic [1:0]           op_q;
  logic [ADDR_W-1:0]    addr_q;
  logic [DATA_W-1:0]    wdata_q;
  logic [DATA_W-1:0]    cmp_data_q;
  logic [STRB_W-1:0]    strb_q;
  logic [LANE_W-1:0]    lane_q;
  logic [TIMEOUT_W-1:0] tmo_q;
  logic [RETRY_W-1:0]   rmax_q;
  logic                 vfy_en_q;

  logic wr_phase_q, rd_phase_q, vfy_phase_q;
  logic [RETRY_W-1:0] attempts_q;

  logic [TIMEOUT_W-1:0] timer_q;
  logic                 timer_zero;

  logic [RD_W-1:0] rdel_q;

  logic [TS_W-1:0] ts_q;

  logic [FAULT_W-1:0] ffault_q, lfault_q;
  logic               ffault_v_q, lfault_v_q;

  logic [CNT_W-1:0] c_total_q, c_ok_q, c_err_q, c_tmo_q, c_rty_q;

  logic              done_q;
  logic [2:0]        status_q;
  logic [DATA_W-1:0] rdata_q;

  // ---------------------------------------------------------------------
  function automatic logic [DATA_W-1:0] expand_strb(logic [STRB_W-1:0] s);
    logic [DATA_W-1:0] m;
    m = '0;
    for (int b = 0; b < STRB_W; b++)
      if (s[b]) m[8*b +: 8] = 8'hFF;
    return m;
  endfunction

  function automatic logic [CNT_W-1:0] sat_inc(logic [CNT_W-1:0] c);
    return (&c) ? c : c + CNT_W'(1);
  endfunction

  function automatic logic [FAULT_W-1:0] pack_fault(
      logic [TS_W-1:0] ts, logic [1:0] op, logic [ADDR_W-1:0] a,
      logic [LANE_W-1:0] ln, logic [2:0] st, logic [RETRY_W-1:0] at);
    return {ts, op, a, ln, st, at};
  endfunction

  wire logic [DATA_W-1:0] strb_mask = expand_strb(strb_q);

  // ---------------------------------------------------------------------
  assign accept_ready = (state_q == S_IDLE);
  assign timer_zero   = (timer_q == '0);

  always_comb begin
    if (vfy_phase_q || rd_phase_q) be_op = PHY_OP_READ;
    else                           be_op = PHY_OP_WRITE;
  end

  assign be_cmd_valid = (state_q == S_ISSUE) && !abort_req;
  assign be_addr      = addr_q;
  assign be_wdata     = wdata_q;
  assign be_wstrb     = strb_q;
  assign be_lane      = lane_q;
  assign be_rsp_ready = (state_q == S_WAIT);

  assign x_done    = done_q;
  assign x_status  = status_q;
  assign x_rdata   = rdata_q;
  assign dbg_ts    = ts_q;
  assign dbg_state = state_q;

  assign fault_first   = ffault_q;
  assign fault_last    = lfault_q;
  assign fault_first_v = ffault_v_q;
  assign fault_last_v  = lfault_v_q;
  assign cnt_total     = c_total_q;
  assign cnt_ok        = c_ok_q;
  assign cnt_err       = c_err_q;
  assign cnt_timeout   = c_tmo_q;
  assign cnt_retry     = c_rty_q;

  // ---------------------------------------------------------------------
  // outcome decode (combinational)
  logic       do_fail;
  logic [2:0] fail_status;
  logic       do_success;
  logic       do_abort;

  always_comb begin
    do_fail     = 1'b0;
    fail_status = PHY_ST_OK;
    do_success  = 1'b0;
    do_abort    = 1'b0;

    if (state_q == S_WAIT) begin
      if (be_rsp_valid) begin
        if (be_rsp_status != PHY_ST_OK) begin
          do_fail     = 1'b1;
          fail_status = be_rsp_status;
        end else if (vfy_phase_q) begin
          if ((be_rsp_rdata & strb_mask) != (cmp_data_q & strb_mask)) begin
            do_fail     = 1'b1;
            fail_status = PHY_ST_VERIFY_FAIL;
          end else
            do_success = 1'b1;
        end else
          do_success = 1'b1;
      end else if (abort_req) begin
        do_abort    = 1'b1;
        fail_status = PHY_ST_ABORTED;
      end else if (timer_zero) begin
        do_fail     = 1'b1;
        fail_status = PHY_ST_TIMEOUT;
      end
    end else if (state_q == S_ISSUE) begin
      if (abort_req) begin
        do_abort    = 1'b1;
        fail_status = PHY_ST_ABORTED;
      end else if (!be_cmd_ready && timer_zero) begin
        do_fail     = 1'b1;
        fail_status = PHY_ST_TIMEOUT;
      end
    end
  end

  // ---------------------------------------------------------------------
  // main sequencer
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      done_q  <= 1'b0;
      status_q<= PHY_ST_OK;
      rdata_q <= '0;
      ts_q    <= '0;
      ffault_q<= '0; lfault_q<='0; ffault_v_q<=1'b0; lfault_v_q<=1'b0;
      c_total_q<='0; c_ok_q<='0; c_err_q<='0; c_tmo_q<='0; c_rty_q<='0;
      timer_q <='0; rdel_q<='0;
      op_q<='0; addr_q<='0; wdata_q<='0; cmp_data_q<='0; strb_q<='0; lane_q<='0;
      tmo_q<='0; rmax_q<='0; vfy_en_q<=1'b0;
      wr_phase_q<=1'b0; rd_phase_q<=1'b0; vfy_phase_q<=1'b0; attempts_q<='0;
    end else begin
      done_q <= 1'b0;
      ts_q   <= ts_q + TS_W'(1);

      if (fault_clear) begin
        ffault_q   <= '0;
        lfault_q   <= '0;
        ffault_v_q <= 1'b0;
        lfault_v_q <= 1'b0;
      end

      case (state_q)
        // -------------------------------------------------------------
        S_IDLE: begin
          if (g_valid) begin
            op_q       <= g_op;
            addr_q     <= g_addr;
            strb_q     <= g_wstrb;
            lane_q     <= g_lane;
            tmo_q      <= (g_timeout_cyc == '0) ? TIMEOUT_W'(1) : g_timeout_cyc;
            rmax_q     <= g_retry_max;
            vfy_en_q   <= g_verify_en && (g_op != PHY_OP_READ);
            attempts_q <= '0;
            wr_phase_q <= (g_op == PHY_OP_WRITE);
            rd_phase_q <= (g_op == PHY_OP_RMW);
            vfy_phase_q<= 1'b0;
            wdata_q    <= g_wdata;
            cmp_data_q <= g_wdata;
            timer_q    <= (g_timeout_cyc == '0) ? TIMEOUT_W'(1) : g_timeout_cyc;
            state_q    <= S_ISSUE;
          end
        end
        // -------------------------------------------------------------
        S_ISSUE: begin
          if (do_abort) begin
            done_q    <= 1'b1;
            status_q  <= PHY_ST_ABORTED;
            c_err_q   <= sat_inc(c_err_q);
            c_total_q <= sat_inc(c_total_q);
            state_q   <= S_IDLE;
          end else if (do_fail) begin
            c_tmo_q <= (fail_status == PHY_ST_TIMEOUT) ? sat_inc(c_tmo_q) : c_tmo_q;
            if (!ffault_v_q) begin
              ffault_q   <= pack_fault(ts_q, op_q, addr_q, lane_q, fail_status, attempts_q);
              ffault_v_q <= 1'b1;
            end
            lfault_q   <= pack_fault(ts_q, op_q, addr_q, lane_q, fail_status, attempts_q);
            lfault_v_q <= 1'b1;
            if (attempts_q < rmax_q) begin
              attempts_q <= attempts_q + RETRY_W'(1);
              c_rty_q    <= sat_inc(c_rty_q);
              rdel_q     <= RD_W'(RETRY_DELAY - 1);
              timer_q    <= tmo_q;
              state_q    <= S_RDEL;
            end else begin
              done_q    <= 1'b1;
              status_q  <= fail_status;
              c_err_q   <= sat_inc(c_err_q);
              c_total_q <= sat_inc(c_total_q);
              state_q   <= S_IDLE;
            end
          end else if (be_cmd_valid && be_cmd_ready) begin
            state_q <= S_WAIT;
          end else if (!timer_zero) begin
            timer_q <= timer_q - TIMEOUT_W'(1);
          end
        end
        // -------------------------------------------------------------
        S_WAIT: begin
          if (!timer_zero)
            timer_q <= timer_q - TIMEOUT_W'(1);

          if (do_abort) begin
            done_q    <= 1'b1;
            status_q  <= PHY_ST_ABORTED;
            c_err_q   <= sat_inc(c_err_q);
            c_total_q <= sat_inc(c_total_q);
            state_q   <= S_IDLE;
          end else if (do_fail) begin
            c_tmo_q <= (fail_status == PHY_ST_TIMEOUT) ? sat_inc(c_tmo_q) : c_tmo_q;
            if (!ffault_v_q) begin
              ffault_q   <= pack_fault(ts_q, op_q, addr_q, lane_q, fail_status, attempts_q);
              ffault_v_q <= 1'b1;
            end
            lfault_q   <= pack_fault(ts_q, op_q, addr_q, lane_q, fail_status, attempts_q);
            lfault_v_q <= 1'b1;
            if (attempts_q < rmax_q) begin
              attempts_q <= attempts_q + RETRY_W'(1);
              c_rty_q    <= sat_inc(c_rty_q);
              rdel_q     <= RD_W'(RETRY_DELAY - 1);
              timer_q    <= tmo_q;
              state_q    <= S_RDEL;
            end else begin
              done_q    <= 1'b1;
              status_q  <= fail_status;
              c_err_q   <= sat_inc(c_err_q);
              c_total_q <= sat_inc(c_total_q);
              state_q   <= S_IDLE;
            end
          end else if (do_success) begin
            if (rd_phase_q) begin
              wdata_q    <= (wdata_q & strb_mask) | (be_rsp_rdata & ~strb_mask);
              cmp_data_q <= (wdata_q & strb_mask) | (be_rsp_rdata & ~strb_mask);
              rd_phase_q <= 1'b0;
              wr_phase_q <= 1'b1;
              timer_q    <= tmo_q;
              state_q    <= S_ISSUE;
            end else if (vfy_en_q && wr_phase_q) begin
              vfy_phase_q<= 1'b1;
              wr_phase_q <= 1'b0;
              timer_q    <= tmo_q;
              state_q    <= S_ISSUE;
            end else begin
              done_q      <= 1'b1;
              status_q    <= PHY_ST_OK;
              rdata_q     <= be_rsp_rdata;
              c_ok_q      <= sat_inc(c_ok_q);
              c_total_q   <= sat_inc(c_total_q);
              vfy_phase_q <= 1'b0;
              state_q     <= S_IDLE;
            end
          end
        end
        // -------------------------------------------------------------
        S_RDEL: begin
          if (rdel_q == '0)
            state_q <= S_ISSUE;
          else
            rdel_q <= rdel_q - RD_W'(1);
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  a_cmd_only_when_issuing: assert property (@(posedge clk) disable iff (!rst_n)
      be_cmd_valid |-> (state_q == S_ISSUE))
    else $error("xact_core: be_cmd_valid outside ISSUE");
  a_timer_exits: assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == S_WAIT && timer_q == '0) |=> (state_q != S_WAIT || be_rsp_valid))
    else $error("xact_core: stalled WAIT past timeout");
`endif
endmodule
