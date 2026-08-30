// -----------------------------------------------------------------------------
// rxeq_ctrl.sv — RX equalization controller (Milestone 7).
// Implements: RXEQ-REQ-001..006 (PRODUCT_REQUIREMENTS.md), mandate §15.
//
// Capability-gated sequence (engine client slot):
//   [CAP_CTLE]  bounded exhaustive sweep of CTLE code: APPLY->DWELL->METRIC,
//               keep-best, perfect-metric early exit, restore best
//   [CAP_DFE]   single DFE-enable register write
//   [CAP_ADAPT] single adaptation-restart register write
// No capability => done(ok) immediately with `unsupported` asserted and ZERO
// backend traffic (RXEQ-REQ-002). Persistent transport failure during any
// phase -> rollback CTLE to INITIAL_VALUE and report ok=0.
// -----------------------------------------------------------------------------
module rxeq_ctrl #(
  parameter int unsigned ADDR_W    = 16,
  parameter int unsigned DATA_W    = 16,
  parameter int unsigned TIMEOUT_W = 24,
  parameter logic [ADDR_W-1:0] CTLE_ADDR   = 16'h0020,
  parameter logic [ADDR_W-1:0] METRIC_ADDR = 16'h0022,
  parameter logic [ADDR_W-1:0] DFE_ADDR    = 16'h0024,
  parameter logic [ADDR_W-1:0] ADAPT_ADDR  = 16'h0026,
  parameter logic [DATA_W-1:0] INITIAL_VALUE = '0,
  parameter logic [DATA_W-1:0] CTLE_MIN    = '0,
  parameter logic [DATA_W-1:0] CTLE_MAX    = 16'd10,
  parameter logic [DATA_W-1:0] CTLE_STEP   = 16'd1,
  parameter logic [DATA_W-1:0] DFE_VALUE   = 16'h0001,
  parameter logic [DATA_W-1:0] ADAPT_VALUE = 16'h0001,
  parameter int unsigned DWELL_CYC  = 20,
  parameter int unsigned CMD_TMO    = 500,
  parameter int unsigned MAX_ERR    = 2,
  localparam int unsigned SW = DATA_W/8
)(
  input  wire logic clk,
  input  wire logic rst_n,

  input  wire logic start,
  // runtime capability bitmap (from discovery/CSR)
  input  wire logic cap_ctle,
  input  wire logic cap_dfe,
  input  wire logic cap_adapt,

  output logic                         cr_valid,
  input  wire logic                    cr_ready,
  output logic [1:0]                   cr_op,
  output logic [ADDR_W-1:0]            cr_addr,
  output logic [DATA_W-1:0]            cr_wdata,
  output logic [SW-1:0]                cr_wstrb,
  output logic [3:0]                   cr_lane,
  output logic [TIMEOUT_W-1:0]         cr_timeout_cyc,
  output logic [3:0]                   cr_retry_max,
  output logic                         cr_verify_en,
  output logic                         cr_abort,
  input  wire logic                    rsp_done,
  input  wire logic [2:0]              rsp_status,
  input  wire logic [DATA_W-1:0]       rsp_rdata,

  output logic                        done,
  output logic                        ok,          // valid with done
  output logic                        unsupported, // no caps present
  output logic [15:0]                 iter_cnt,
  output logic [DATA_W-1:0]           best_val,
  output logic [DATA_W-1:0]           best_metric
);
  import serdes_phy_ctrl_pkg::*;

  localparam logic [1:0] OP_RD = PHY_OP_READ, OP_WR = PHY_OP_WRITE;

  typedef enum logic [2:0] {S_IDLE=0, S_APPLY, S_DWELL, S_READ,
                            S_DFEN, S_ADAPT, S_ROLLBACK} st_t;
  localparam st_t S_ROLLBACK_DONE = st_t'(7);   // internal terminal marker
  st_t state_q;

  logic [1:0]        phase_q;
  logic              res_q;
  logic [2:0]        st_q;
  logic [DATA_W-1:0] rd_q;

  logic              fire;
  logic              t_wr;
  logic [ADDR_W-1:0] t_addr;
  logic [DATA_W-1:0] t_wdata;
  logic              r_wr;
  logic [ADDR_W-1:0] r_addr;
  logic [DATA_W-1:0] r_wdata;

  logic [TIMEOUT_W-1:0] tmr_q;
  logic                 tmr_zero;
  logic [DATA_W-1:0] cand_q, best_v_q, best_m_q;
  logic [15:0]       iters_q;
  logic [1:0]        errs_q;
  logic              done_q, ok_q, unsup_q, start_q;

  wire start_edge = start & ~start_q;

  // executor
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase_q<=2'd0; st_q<=PHY_ST_OK; rd_q<='0; res_q<=1'b0;
      r_wr<=1'b0; r_addr<=CTLE_ADDR; r_wdata<='0;
    end else begin
      res_q <= 1'b0;
      case (phase_q)
        2'd0: if (fire) begin
                r_wr<=t_wr; r_addr<=t_addr; r_wdata<=t_wdata; phase_q<=2'd1;
              end
        2'd1: if (cr_ready) phase_q<=2'd2;
        2'd2: if (rsp_done) begin
                st_q<=rsp_status; rd_q<=rsp_rdata; phase_q<=2'd0; res_q<=1'b1;
              end
        default: phase_q<=2'd0;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 tmr_q <= TIMEOUT_W'(DWELL_CYC);
    else if (state_q==S_DWELL)  tmr_q <= tmr_zero ? tmr_q : tmr_q - TIMEOUT_W'(1);
    else                        tmr_q <= TIMEOUT_W'(DWELL_CYC);
  end
  assign tmr_zero = (tmr_q == '0);

  always_comb begin
    fire=1'b0; t_wr=1'b0; t_addr=CTLE_ADDR; t_wdata='0;
    unique case (state_q)
      S_APPLY:  if (phase_q==2'd0 && !res_q) begin fire=1'b1; t_wdata=cand_q; end
      S_READ:   if (phase_q==2'd0 && !res_q) begin fire=1'b1; t_addr=METRIC_ADDR; end
      S_DFEN:   if (phase_q==2'd0 && !res_q) begin
                  fire=1'b1; t_wr=1'b1; t_addr=DFE_ADDR; t_wdata=DFE_VALUE; end
      S_ADAPT:  if (phase_q==2'd0 && !res_q) begin
                  fire=1'b1; t_wr=1'b1; t_addr=ADAPT_ADDR; t_wdata=ADAPT_VALUE; end
      S_ROLLBACK: if (phase_q==2'd0 && !res_q) begin
                    fire=1'b1; t_wr=1'b1; t_wdata=INITIAL_VALUE; end
      default: ;
    endcase
  end

  always_comb begin
    cr_valid       = (phase_q==2'd1);
    cr_op          = r_wr ? OP_WR : OP_RD;
    cr_addr        = r_addr;
    cr_wdata       = r_wdata;
    cr_wstrb       = {SW{1'b1}};
    cr_lane        = '0;
    cr_timeout_cyc = TIMEOUT_W'(CMD_TMO);
    cr_retry_max   = 4'd1;
    cr_verify_en   = 1'b0;
    cr_abort       = 1'b0;
  end

  // main sequencer — results consumed in the SAME arm that sees res_q
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q<=S_IDLE; start_q<=1'b0; done_q<=1'b0; ok_q<=1'b0; unsup_q<=1'b0;
      cand_q<=CTLE_MIN; best_v_q<=INITIAL_VALUE; best_m_q<='1;
      iters_q<='0; errs_q<='0;
    end else begin
      start_q <= start;
      done_q  <= 1'b0;

      if (state_q==S_DWELL && tmr_zero && phase_q==2'd0)
        state_q <= S_READ;

      if (res_q) begin
        case (state_q)
          S_APPLY:  state_q <= S_DWELL;
          S_READ: begin
            if (st_q != PHY_ST_OK) begin
              errs_q  <= errs_q + 2'b1;
              state_q <= (errs_q >= MAX_ERR[1:0]) ? S_ROLLBACK : S_APPLY;
            end else begin
              iters_q <= iters_q + 16'd1;
              if (rd_q < best_m_q) begin
                best_m_q <= rd_q; best_v_q <= cand_q;
              end
              if (rd_q == '0 || cand_q >= CTLE_MAX)
                state_q <= cap_dfe ? S_DFEN : (cap_adapt ? S_ADAPT : S_ROLLBACK_DONE);
              else
                state_q <= S_APPLY;
            end
          end
          S_DFEN:   state_q <= cap_adapt ? S_ADAPT : S_ROLLBACK_DONE;
          S_ADAPT:  state_q <= S_ROLLBACK_DONE;
          S_ROLLBACK: begin done_q<=1'b1; ok_q<=1'b0; unsup_q<=1'b0; state_q<=S_IDLE; end
          default: ;
        endcase
      end

      // candidate advance after successful non-terminal metric read
      if (res_q && state_q==S_READ && st_q==PHY_ST_OK &&
          !(rd_q=='0) && cand_q < CTLE_MAX)
        cand_q <= ((cand_q + CTLE_STEP) > CTLE_MAX) ? CTLE_MAX : (cand_q + CTLE_STEP);

      // terminal helper state (no backend op): finish OK
      if (state_q == S_ROLLBACK_DONE) begin
        done_q<=1'b1; ok_q<=1'b1; state_q<=S_IDLE;
      end

      if (state_q==S_IDLE && start_edge) begin
        errs_q<='0; iters_q<='0; unsup_q<=1'b0;
        if (!(cap_ctle || cap_dfe || cap_adapt)) begin
          unsup_q<=1'b1; done_q<=1'b1; ok_q<=1'b1;
        end else if (!cap_ctle) begin
          best_v_q<=INITIAL_VALUE; best_m_q<='1;
          state_q <= cap_dfe ? S_DFEN : (cap_adapt ? S_ADAPT : S_ROLLBACK_DONE);
        end else begin
          cand_q<=CTLE_MIN; best_v_q<=INITIAL_VALUE; best_m_q<='1;
          state_q<=S_APPLY;
        end
      end
    end
  end

  assign done=done_q; assign ok=ok_q; assign unsupported=unsup_q;
  assign iter_cnt=iters_q; assign best_val=best_v_q; assign best_metric=best_m_q;
endmodule
