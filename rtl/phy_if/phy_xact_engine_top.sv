// -----------------------------------------------------------------------------
// phy_xact_engine_top.sv — PHY Register Interface Engine (Milestone 3 block).
// Implements: ARC-REQ-001/002, PHYIF family. See docs/SYSTEM_ARCHITECTURE.md §3.
//
// N clients -> deterministic round-robin arbiter (with atomic-sequence lock)
//           -> transaction core (timeout / retry / RMW / verify / fault records)
//           -> phy_backend_if (technology-independent transport contract).
//
// Flattened per-client arrays: field i occupies bits [W*i +: W].
// Backend contract: engine drives be_cmd_valid/be_rsp_ready; backend drives
// be_cmd_ready/be_rsp_valid and responds exactly once per accepted command.
// -----------------------------------------------------------------------------
module phy_xact_engine_top #(
  parameter int unsigned CLIENTS    = 4,
  parameter int unsigned ADDR_W     = 16,
  parameter int unsigned DATA_W     = 16,
  parameter int unsigned LANE_W     = 4,
  parameter int unsigned TIMEOUT_W  = 24,
  parameter int unsigned RETRY_W    = 4,
  parameter int unsigned CNT_W      = 32,
  parameter int unsigned TS_W       = 32,
  parameter int unsigned RETRY_DELAY= 8,
  parameter int unsigned IW         = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
  localparam int unsigned STRB_W    = DATA_W/8,
  localparam int unsigned FAULT_W   = TS_W + ADDR_W + LANE_W + 5 + RETRY_W
)(
  input  wire logic clk,
  input  wire logic rst_n,

  // ---- client request arrays ----
  input  wire logic [CLIENTS-1:0]           cr_valid,
  output wire logic [CLIENTS-1:0]           cr_ready,
  input  wire logic [CLIENTS*2-1:0]         cr_op,
  input  wire logic [CLIENTS*ADDR_W-1:0]    cr_addr,
  input  wire logic [CLIENTS*DATA_W-1:0]    cr_wdata,
  input  wire logic [CLIENTS*STRB_W-1:0]    cr_wstrb,
  input  wire logic [CLIENTS*LANE_W-1:0]    cr_lane,
  input  wire logic [CLIENTS*TIMEOUT_W-1:0] cr_timeout_cyc,
  input  wire logic [CLIENTS*RETRY_W-1:0]   cr_retry_max,
  input  wire logic [CLIENTS-1:0]           cr_verify_en,
  input  wire logic [CLIENTS-1:0]           cr_abort,

  // ---- client response arrays ----
  output wire logic [CLIENTS-1:0]          rsp_done,      // 1-cycle pulse
  output wire logic [CLIENTS*3-1:0]        rsp_status,
  output wire logic [CLIENTS*DATA_W-1:0]   rsp_rdata,

  // ---- arbitration sequence lock ----
  input  wire logic          lock_en,
  input  wire logic [IW-1:0] lock_client,

  // ---- phy_backend_if ----
  output wire logic              be_cmd_valid,
  input  wire logic              be_cmd_ready,
  output wire logic [1:0]        be_op,
  output wire logic [ADDR_W-1:0] be_addr,
  output wire logic [DATA_W-1:0] be_wdata,
  output wire logic [STRB_W-1:0] be_wstrb,
  output wire logic [LANE_W-1:0] be_lane,
  input  wire logic              be_rsp_valid,
  output wire logic              be_rsp_ready,
  input  wire logic [2:0]        be_rsp_status,
  input  wire logic [DATA_W-1:0] be_rsp_rdata,

  // ---- status / telemetry ----
  input  wire logic               fault_clear,
  output wire logic [CNT_W-1:0]   cnt_total,
  output wire logic [CNT_W-1:0]   cnt_ok,
  output wire logic [CNT_W-1:0]   cnt_err,
  output wire logic [CNT_W-1:0]   cnt_timeout,
  output wire logic [CNT_W-1:0]   cnt_retry,
  output wire logic               busy,
  output wire logic [2:0]         last_status,
  output wire logic [IW-1:0]      last_owner,
  output wire logic [FAULT_W-1:0] fault_first,
  output wire logic [FAULT_W-1:0] fault_last,
  output wire logic               fault_first_v,
  output wire logic               fault_last_v,
  output wire logic [2:0]         dbg_state,
  output wire logic [IW-1:0]      dbg_rr_ptr
);
  import serdes_phy_ctrl_pkg::*;

  // ---------------------------------------------------------------------
  // grant payload mux (combinational, selected by arbiter grant index)
  logic                 g_valid;
  logic [IW-1:0]        g_client;
  logic [1:0]           g_op;
  logic [ADDR_W-1:0]    g_addr;
  logic [DATA_W-1:0]    g_wdata;
  logic [STRB_W-1:0]    g_wstrb;
  logic [LANE_W-1:0]    g_lane;
  logic [TIMEOUT_W-1:0] g_timeout;
  logic [RETRY_W-1:0]   g_retry_max;
  logic                 g_verify;

  always_comb begin
    g_op        = cr_op        [2*g_client +: 2];
    g_addr      = cr_addr      [ADDR_W*g_client +: ADDR_W];
    g_wdata     = cr_wdata     [DATA_W*g_client +: DATA_W];
    g_wstrb     = cr_wstrb     [STRB_W*g_client +: STRB_W];
    g_lane      = cr_lane      [LANE_W*g_client +: LANE_W];
    g_timeout   = cr_timeout_cyc[TIMEOUT_W*g_client +: TIMEOUT_W];
    g_retry_max = cr_retry_max [RETRY_W*g_client +: RETRY_W];
    g_verify    = cr_verify_en [g_client];
  end

  wire              core_accept_ready;
  wire              x_done;
  wire [2:0]        x_status;
  wire [DATA_W-1:0] x_rdata;

  logic [IW-1:0] last_owner_q;
  logic [2:0]    last_status_q;

  wire owner_abort = cr_abort[last_owner_q];

  phy_arbiter #(
    .CLIENTS (CLIENTS),
    .IW      (IW)
  ) u_arb (
    .clk                (clk),
    .rst_n              (rst_n),
    .req_valid          (cr_valid),
    .req_ready          (cr_ready),
    .core_accept_ready  (core_accept_ready),
    .grant_valid        (g_valid),
    .grant_idx          (g_client),
    .lock_en            (lock_en),
    .lock_client        (lock_client),
    .dbg_rr_ptr         (dbg_rr_ptr)
  );

  phy_xact_core #(
    .ADDR_W      (ADDR_W),
    .DATA_W      (DATA_W),
    .LANE_W      (LANE_W),
    .TIMEOUT_W   (TIMEOUT_W),
    .RETRY_W     (RETRY_W),
    .CNT_W       (CNT_W),
    .TS_W        (TS_W),
    .RETRY_DELAY (RETRY_DELAY)
  ) u_core (
    .clk             (clk),
    .rst_n           (rst_n),
    .accept_ready    (core_accept_ready),
    .g_valid         (g_valid),
    .g_op            (g_op),
    .g_addr          (g_addr),
    .g_wdata         (g_wdata),
    .g_wstrb         (g_wstrb),
    .g_lane          (g_lane),
    .g_timeout_cyc   (g_timeout),
    .g_retry_max     (g_retry_max),
    .g_verify_en     (g_verify),
    .abort_req       (owner_abort),
    .be_cmd_valid    (be_cmd_valid),
    .be_cmd_ready    (be_cmd_ready),
    .be_op           (be_op),
    .be_addr         (be_addr),
    .be_wdata        (be_wdata),
    .be_wstrb        (be_wstrb),
    .be_lane         (be_lane),
    .be_rsp_valid    (be_rsp_valid),
    .be_rsp_ready    (be_rsp_ready),
    .be_rsp_status   (be_rsp_status),
    .be_rsp_rdata    (be_rsp_rdata),
    .x_done          (x_done),
    .x_status        (x_status),
    .x_rdata         (x_rdata),
    .fault_clear     (fault_clear),
    .fault_first     (fault_first),
    .fault_last      (fault_last),
    .fault_first_v   (fault_first_v),
    .fault_last_v    (fault_last_v),
    .cnt_total       (cnt_total),
    .cnt_ok          (cnt_ok),
    .cnt_err         (cnt_err),
    .cnt_timeout     (cnt_timeout),
    .cnt_retry       (cnt_retry),
    /* verilator lint_off PINCONNECTEMPTY */
    .dbg_ts          (),
    /* verilator lint_on PINCONNECTEMPTY */
    .dbg_state       (dbg_state)
  );

  // ---------------------------------------------------------------------
  // response routing to owning client
  genvar i;
  generate
    for (i = 0; i < CLIENTS; i++) begin : g_resp
      assign rsp_done[i]          = x_done && (last_owner_q == IW'(i));
      assign rsp_status[3*i +: 3] = x_status;
      assign rsp_rdata[DATA_W*i +: DATA_W] = x_rdata;
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_owner_q  <= '0;
      last_status_q <= 3'd0;
    end else begin
      if (g_valid && core_accept_ready)
        last_owner_q <= g_client;
      if (x_done)
        last_status_q <= x_status;
    end
  end

  assign busy        = (dbg_state != 3'd0);
  assign last_status = last_status_q;
  assign last_owner  = last_owner_q;

`ifndef SYNTHESIS
  a_no_grant_when_busy: assert property (@(posedge clk) disable iff (!rst_n)
      (dbg_state != 3'd0) |-> !g_valid)
    else $error("engine: grant accepted while core busy");
`endif
endmodule
