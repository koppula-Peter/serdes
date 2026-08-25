// -----------------------------------------------------------------------------
// cdr_ctrl.sv — CDR lock policy engine (Milestone 5).
// Implements: CDR-REQ-001..008 (PRODUCT_REQUIREMENTS.md), mandate §12.
//
// Supervises the external/analog CDR's raw lock indication:
//   IDLE -> RESET -> CONFIG -> ACQUIRE -> VERIFY -> LOCKED <-> TRACK
//   TRACK --qualified unlock--> LOSS -> REACQUIRE -> (LOCKED | DLY | FAILED)
// Bounded retries with restart delay; FAILED terminal until `start` re-arms.
// Signal-detect gating and adaptation-freeze hooks per §12.
// State encodings 0..10 follow the frozen CDR_* set; 11 is a documented
// internal extension (restart delay) surfaced via state_o for debug only.
// -----------------------------------------------------------------------------
module cdr_ctrl #(
  parameter int unsigned ACQ_TMO_CYC     = 500,
  parameter int unsigned LOCK_QUAL_CYC   = 8,
  parameter int unsigned UNLOCK_QUAL_CYC = 4,
  parameter int unsigned RETRY_MAX       = 2,
  parameter int unsigned RESTART_DLY_CYC = 16,
  parameter bit          USE_SIGNAL_DETECT = 0
)(
  input  wire logic clk,
  input  wire logic rst_n,

  input  wire logic start,
  input  wire logic enable,
  input  wire logic cdr_lock_raw,
  input  wire logic signal_detect,

  output logic       cdr_enable,
  output logic       adapt_freeze,
  output logic       locked,
  output logic       ev_lock,
  output logic       ev_loss,
  output logic       ev_failed,
  output logic [3:0] state_o,
  output logic [15:0] cnt_acq,
  output logic [15:0] cnt_loss,
  output logic [15:0] cnt_reacq,
  output logic [15:0] cnt_tmo,
  output logic [31:0] acq_time_last
);
  localparam int unsigned CNT_W = 16;

  typedef enum logic [3:0] {CDR_IDLE=4'd0, CDR_RESET=4'd1, CDR_CONFIG=4'd2,
                            CDR_ACQUIRE=4'd3, CDR_VERIFY=4'd4, CDR_LOCKED=4'd5,
                            CDR_TRACK=4'd6, CDR_HOLD=4'd7, CDR_LOSS=4'd8,
                            CDR_REACQUIRE=4'd9, CDR_FAILED=4'd10,
                            CDR_DLY=4'd11} cdr_st_t;

  cdr_st_t  state_q, prev_q;
  localparam int QL = $clog2(LOCK_QUAL_CYC+1);
  localparam int QU = $clog2(UNLOCK_QUAL_CYC+1);
  logic [QL-1:0] lockq_q;
  logic [QU-1:0] unlockq_q;
  logic [31:0]   tmr_q, acq_q;
  logic [CNT_W-1:0] c_acq, c_loss, c_reacq, c_tmo, retry_q;

  wire sd_ok       = !USE_SIGNAL_DETECT || signal_detect;
  wire lock_eff    = cdr_lock_raw && sd_ok && enable;
  wire lockq_hit   = (lockq_q == QL'(LOCK_QUAL_CYC));
  wire unlockq_hit = (unlockq_q == QU'(UNLOCK_QUAL_CYC));
  wire tmo         = (tmr_q == '0);

  function automatic logic [CNT_W-1:0] sat_inc(input logic [CNT_W-1:0] c);
    return (&c) ? c : c + CNT_W'(1);
  endfunction

  // lock/unlock qualifiers (single driver for these regs)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lockq_q<='0; unlockq_q<='0;
    end else begin
      lockq_q   <= lock_eff  ? (lockq_hit    ? lockq_q    : lockq_q    + 1'b1) : '0;
      unlockq_q <= !lock_eff ? (unlockq_hit  ? unlockq_q  : unlockq_q  + 1'b1) : '0;
    end
  end

  logic ev_lock_q, ev_loss_q, ev_failed_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_q<=CDR_IDLE; state_q<=CDR_IDLE;
      locked<=1'b0; adapt_freeze<=1'b0; cdr_enable<=1'b0;
      ev_lock_q<=1'b0; ev_loss_q<=1'b0; ev_failed_q<=1'b0;
      c_acq<='0; c_loss<='0; c_reacq<='0; c_tmo<='0; retry_q<='0;
      acq_time_last<='0;
    end else begin
      prev_q      <= state_q;

      // single-driver timer/acq bookkeeping
      unique case (state_q)
        CDR_CONFIG, CDR_DLY: ;               // loaded on entry edges below
        CDR_ACQUIRE, CDR_REACQUIRE: begin
          if (!tmo) tmr_q <= tmr_q - 1'b1;
          acq_q    <= acq_q + 1'b1;
        end
        CDR_DLY: begin
          if (prev_q != CDR_DLY)      tmr_q <= 32'(RESTART_DLY_CYC);
          else if (!tmo)              tmr_q <= tmr_q - 1'b1;
        end
        default: begin tmr_q <= '0; acq_q <= '0; end
      endcase
      ev_lock_q   <= 1'b0; ev_loss_q <= 1'b0; ev_failed_q <= 1'b0;

      case (state_q)
        CDR_IDLE: if (enable && start) begin
                    retry_q<='0; cdr_enable<=1'b1; adapt_freeze<=1'b0;
                    state_q<=CDR_RESET;
                  end
        CDR_RESET:  state_q<=CDR_CONFIG;
        CDR_CONFIG: begin tmr_q<=32'(ACQ_TMO_CYC); acq_q<='0; state_q<=CDR_ACQUIRE; end

        CDR_ACQUIRE:
          if (lockq_hit) begin
            locked<=1'b1; ev_lock_q<=1'b1; c_acq<=sat_inc(c_acq);
            acq_time_last<=acq_q; state_q<=CDR_VERIFY;
          end else if (tmo) begin
            c_tmo<=sat_inc(c_tmo);
            state_q<=(retry_q<CNT_W'(RETRY_MAX)) ? CDR_DLY : CDR_FAILED;
          end

        CDR_VERIFY:  state_q<=lock_eff ? CDR_LOCKED : CDR_LOSS;
        CDR_LOCKED:  state_q<=CDR_TRACK;

        CDR_TRACK:
          if (unlockq_hit) begin
            locked<=1'b0; ev_loss_q<=1'b1; c_loss<=sat_inc(c_loss);
            adapt_freeze<=1'b1; retry_q<='0; state_q<=CDR_LOSS;
          end

        CDR_HOLD:    state_q<=CDR_LOSS;

        CDR_LOSS:    state_q<=CDR_REACQUIRE;      // freeze held during attempt

        CDR_REACQUIRE:
          if (lockq_hit) begin
            locked<=1'b1; ev_lock_q<=1'b1; c_reacq<=sat_inc(c_reacq);
            adapt_freeze<=1'b0; state_q<=CDR_TRACK;
          end else if (tmo) begin
            c_tmo<=sat_inc(c_tmo); adapt_freeze<=1'b0;
            state_q<=(retry_q<CNT_W'(RETRY_MAX)) ? CDR_DLY : CDR_FAILED;
          end

        CDR_DLY: if (prev_q == CDR_DLY && tmo) begin   // load done in timer mgmt
                   retry_q<=sat_inc(retry_q);
                   tmr_q<=32'(ACQ_TMO_CYC); acq_q<='0;
                   state_q<=CDR_REACQUIRE;
                 end

        CDR_FAILED: begin
                      cdr_enable<=1'b0; adapt_freeze<=1'b0;
                      ev_failed_q<=1'b1; state_q<=CDR_IDLE;
                    end

        default: state_q<=CDR_IDLE;
      endcase
    end
  end
  assign state_o=state_q; assign ev_lock=ev_lock_q;
  assign ev_loss=ev_loss_q; assign ev_failed=ev_failed_q;
  assign cnt_acq=c_acq; assign cnt_loss=c_loss;
  assign cnt_reacq=c_reacq; assign cnt_tmo=c_tmo;

`ifndef SYNTHESIS
  a_bounded_acquire: assert property (@(posedge clk) disable iff (!rst_n)
      (state_q inside {CDR_ACQUIRE, CDR_REACQUIRE}) |-> (tmr_q <= 32'(ACQ_TMO_CYC)))
    else $error("cdr: unbounded acquire");
`endif
endmodule
