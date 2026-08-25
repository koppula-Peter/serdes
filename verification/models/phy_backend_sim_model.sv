// -----------------------------------------------------------------------------
// phy_backend_sim_model.sv  —  SIMULATION ONLY (mandate §95: labelled model).
//
// Configurable fake PHY behind phy_backend_if:
//   * memory-backed registers (immediate write-commit at command acceptance)
//   * randomized response latency window
//   * fault injection: dropped responses (timeout), BUS_ERROR, corrupted reads
//   * UNSUPPORTED address region (>= UNSUP_BASE)
//   * deterministic via +SEED= plusarg
//
// Semantics chosen to mirror real management buses:
//   - a supported WRITE commits even if its acknowledgement is lost/injected.
//   - an unsupported address has NO side effects.
//   - exactly one outstanding scheduled response; a newly accepted command
//     cancels any orphaned pending response (engine-abort scenario).
// -----------------------------------------------------------------------------
module phy_backend_sim_model #(
  parameter int unsigned ADDR_W      = 16,
  parameter int unsigned DATA_W      = 16,
  parameter int unsigned MEM_IDX_W   = 10,
  parameter logic [DATA_W-1:0] MEM_INIT = '0,
  parameter bit           UNSUPPORTED_EN = 1,
  parameter logic [ADDR_W-1:0] UNSUP_BASE = 16'h0100
)(
  input wire logic clk,
  input wire logic rst_n,

  // backend command face
  input  wire logic              cmd_valid,
  output wire logic              cmd_ready,
  input  wire logic [1:0]        cmd_op,       // READ / WRITE only at this face
  input  wire logic [ADDR_W-1:0] cmd_addr,
  input  wire logic [DATA_W-1:0] cmd_wdata,
  input  wire logic [DATA_W/8-1:0] cmd_wstrb,
  input  wire logic [3:0]        cmd_lane,
  output logic                   rsp_valid,
  input  wire logic              rsp_ready,
  output logic [DATA_W-1:0]      rsp_rdata,
  output logic [2:0]             rsp_status
);
  import serdes_phy_ctrl_pkg::*;

  // ---------------- public TB knobs (hierarchical access) ----------------
  integer lat_min         = 1;     // response latency window [cycles]
  integer lat_max         = 4;
  integer inj_timeout_n   = 0;     // next N commands get NO response
  integer inj_bus_err_n   = 0;     // next N commands respond BUS_ERROR
  integer inj_bad_read_n  = 0;     // next N reads return inverted data

  integer m_accepted = 0;
  integer m_responses = 0;

  // ---------------------------------------------------------------------
  logic [DATA_W-1:0] mem [0:(1<<MEM_IDX_W)-1];

  logic              pend_v;
  integer            pend_delay;
  logic [DATA_W-1:0] pend_data;
  logic [2:0]        pend_status;

  wire do_accept = cmd_valid && cmd_ready;

  // Always-ready command face: the model keeps at most one scheduled
  // response, and a newly accepted command CANCELS any orphaned pending
  // response (engine-abort / lost-ack scenario, mandate §46). Gating
  // cmd_ready on pending state would let an orphan stall the engine.
  assign cmd_ready = rst_n;

  function automatic logic [DATA_W-1:0] expand_strb(logic [DATA_W/8-1:0] s);
    logic [DATA_W-1:0] m;
    m = '0;
    for (int b = 0; b < DATA_W/8; b++)
      if (s[b]) m[8*b +: 8] = 8'hFF;
    return m;
  endfunction

  integer rnd_lat;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_v      <= 1'b0;
      pend_delay  <= 0;
      pend_data   <= '0;
      pend_status <= PHY_ST_OK;
      rsp_valid   <= 1'b0;
      rsp_rdata   <= '0;
      rsp_status  <= PHY_ST_OK;
      for (int k = 0; k < (1<<MEM_IDX_W); k++)
        mem[k] <= MEM_INIT;
    end else begin
      // ---- response delivery ----
      if (pend_v) begin
        if (pend_delay == 0) begin
          rsp_valid  <= 1'b1;
          rsp_rdata  <= pend_data;
          rsp_status <= pend_status;
          pend_v     <= 1'b0;
          m_responses++;
        end else
          pend_delay <= pend_delay - 1;
      end

      // ---- response consumed ----
      if (rsp_valid && rsp_ready)
        rsp_valid <= 1'b0;

      // ---- new command accepted ----
      if (do_accept) begin
        m_accepted++;
        pend_v     <= 1'b0;             // cancel any orphan
        rsp_valid  <= 1'b0;             // cancel stale response

        if (inj_timeout_n > 0) begin
          inj_timeout_n--;              // drop on the floor -> engine timeout
        end else begin
          rnd_lat = lat_min + rng_range_m((lat_max >= lat_min) ? (lat_max-lat_min+1) : 1);

          if (UNSUPPORTED_EN && (cmd_addr >= UNSUP_BASE)) begin
            pend_v      <= 1'b1;
            pend_delay  <= rnd_lat;
            pend_data   <= '0;
            pend_status <= PHY_ST_UNSUPPORTED;   // no side effects
          end else begin
            // commit writes immediately (ack may still be lost later)
            if (cmd_op == PHY_OP_WRITE) begin
              mem[cmd_addr[MEM_IDX_W-1:0]] <= (mem[cmd_addr[MEM_IDX_W-1:0]] & ~expand_strb(cmd_wstrb))
                                              | (cmd_wdata & expand_strb(cmd_wstrb));
            end
            pend_v     <= 1'b1;
            pend_delay <= rnd_lat;
            if (inj_bus_err_n > 0) begin
              inj_bus_err_n--;
              pend_data   <= '0;
              pend_status <= PHY_ST_BUS_ERROR;
            end else begin
              pend_data   <= (cmd_op == PHY_OP_READ) ? mem[cmd_addr[MEM_IDX_W-1:0]] : '0;
              pend_status <= PHY_ST_OK;
              if ((cmd_op == PHY_OP_READ) && (inj_bad_read_n > 0)) begin
                inj_bad_read_n--;
                pend_data <= ~mem[cmd_addr[MEM_IDX_W-1:0]];   // corrupted readback
              end
            end
          end
        end
      end
    end
  end

  // ---------------- deterministic PRNG (xorshift32) ----------------------
  // Portable across xsim/iverilog/verilator; seeded once from +SEED= so any
  // run reproduces identical latency sequences for the same seed.
  integer rng_m = 32'h1;

  function automatic logic [31:0] rng_next_m();
    rng_m = rng_m ^ (rng_m << 13);
    rng_m = rng_m ^ (rng_m >> 17);
    rng_m = rng_m ^ (rng_m << 5);
    return rng_m;
  endfunction

  function automatic int unsigned rng_range_m(input int unsigned n);
    return (n == 0) ? 0 : (rng_next_m() % n);
  endfunction

  initial begin : init_seed
    if (!$value$plusargs("SEED=%d", rng_m)) rng_m = 32'h1;
    if (rng_m == 0) rng_m = 32'h1;
  end
endmodule
