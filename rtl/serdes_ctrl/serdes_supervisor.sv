// -----------------------------------------------------------------------------
// serdes_supervisor.sv — global SerDes/PHY control FSM (Milestone 4).
// Implements: SUP-REQ-001..008 (PRODUCT_REQUIREMENTS.md), mandate §11.
//
// Product state machine (encodings frozen in serdes_phy_ctrl_pkg):
//   RESET -> POWER_WAIT -> PHY_RST_ASSERT -> PHY_RST_HOLD -> PHY_RST_REL
//         -> DISCOVERY -> CONFIGURE -> PLL_WAIT -> CDR_ACQUIRE
//         -> [BASELINE_EQ -> TRAINING -> CALIBRATION]   (bounded stubs until
//                                                        their engines land)
//         -> ALIGNMENT -> LINK_READY -> MONITOR
//   MONITOR --qualified link loss / failed health read--> DEGRADED -> RECOVERY
//         --(bounded)--> fast-path relock  |  exhausted -> FAULT -> SAFE_STATE
//   Any init failure -> bounded-retry decide -> FAULT -> SAFE_STATE.
//   A `start` edge in SAFE_STATE re-arms a complete fresh initialization.
//
// Layering: the supervisor occupies ONE client slot of phy_xact_engine; every
// PHY access is a transaction (backend timing never leaks upward, ARC-REQ-001).
// Safety: every wait counter-bounded; retries bounded + counted; fault reason
// and failing state latched (mandate §6, §25, §31).
// -----------------------------------------------------------------------------
module serdes_supervisor #(
  parameter int unsigned NUM_LANES      = 1,
  parameter int unsigned ADDR_W         = 16,
  parameter int unsigned DATA_W         = 16,
  parameter int unsigned TIMEOUT_W      = 24,
  parameter int unsigned CNT_W          = 16,
  // discovery/configuration window (backend register map)
  parameter logic [ADDR_W-1:0] DISC_ADDR     = 16'h0000,
  parameter logic [DATA_W-1:0] DISC_EXPECTED = 16'hA501,
  parameter logic [ADDR_W-1:0] CFG_ADDR      = 16'h0004,
  parameter logic [DATA_W-1:0] CFG_VALUE     = 16'h0001,
  parameter logic [ADDR_W-1:0] STAT_ADDR     = 16'h0006,
  // sequencing bounds [aclk cycles] — mandate §11: no indefinite waits
  parameter int unsigned PWR_WAIT_CYC   = 100,
  parameter int unsigned RST_HOLD_CYC   = 50,
  parameter int unsigned RST_REL_CYC    = 20,
  parameter int unsigned PLL_TMO_CYC    = 2000,
  parameter int unsigned PLL_QUAL_CYC   = 8,
  parameter int unsigned CDR_TMO_CYC    = 2000,
  parameter int unsigned CDR_QUAL_CYC   = 8,
  parameter int unsigned LOSS_QUAL_CYC  = 8,
  parameter int unsigned STUB_DWELL_CYC = 4,
  parameter int unsigned ALGN_CYC       = 10,
  parameter int unsigned MON_INTERVAL   = 200,
  parameter int unsigned CMD_TMO_CYC    = 1000,
  parameter int unsigned INIT_RETRY_MAX = 2,
  parameter int unsigned CDR_RETRY_MAX  = 2,
  parameter int unsigned RETRAIN_MAX    = 2,
  // engine stubs traversed but bounded until their milestones land
  parameter bit          ENABLE_BASELINE_EQ = 0,
  parameter bit          ENABLE_TRAINING    = 0,
  parameter bit          ENABLE_CALIBRATION = 0,
  // optional signal-detect gating of CDR qualification (mandate §12)
  parameter bit          USE_SIGNAL_DETECT = 0,
  localparam int unsigned SW = (DATA_W < 8) ? 1 : DATA_W/8
)(
  input  wire logic                    clk,
  input  wire logic                    rst_n,

  input  wire logic                    start,        // edge: begin (re)init

  // ---- phy_xact_engine client face ------------------------------------------
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

  // ---- PHY status/control pins (synchronous face; CDC owned by backend) -----
  input  wire logic                    pll_lock,
  input  wire logic [NUM_LANES-1:0]    cdr_lock,
  input  wire logic [NUM_LANES-1:0]    signal_detect,
  output logic                         phy_reset_n,

  // ---- events (single-cycle pulses; IRQ aggregation lands at M12) -----------
  output logic                         ev_init_done,
  output logic                         ev_link_up,
  output logic                         ev_link_down,
  output logic                         ev_fault,
  output logic                         ev_safe,

  // ---- telemetry -------------------------------------------------------------
  output logic [4:0]                   state_o,
  output logic [2:0]                   fail_reason_o,
  output logic [4:0]                   fail_state_o,
  output logic                         link_up_o,
  output logic [CNT_W-1:0]             cnt_init_retry,
  output logic [CNT_W-1:0]             cnt_cdr_reacq,
  output logic [CNT_W-1:0]             cnt_retrain,
  output logic [CNT_W-1:0]             cnt_faults
);
  import serdes_phy_ctrl_pkg::*;

  // failure reasons (telemetry contract)
  localparam logic [2:0] RSN_NONE     = 3'd0,
                         RSN_ID       = 3'd1,
                         RSN_PLL_TMO  = 3'd2,
                         RSN_CDR_TMO  = 3'd3,
                         RSN_BUSERR   = 3'd4,
                         RSN_LINKLOSS = 3'd5,
                         RSN_RETR_EXH = 3'd6;

  localparam logic [1:0] OP_RD = PHY_OP_READ, OP_WR = PHY_OP_WRITE;

  localparam logic [TIMEOUT_W-1:0] TMO_MAX =
    (TIMEOUT_W'(PLL_TMO_CYC) > TIMEOUT_W'(CDR_TMO_CYC)) ? TIMEOUT_W'(PLL_TMO_CYC)
                                                        : TIMEOUT_W'(CDR_TMO_CYC);

  // --------------------------------------------------------------------- regs
  logic [4:0]           state_q;
  logic [TIMEOUT_W-1:0] tmr_q;
  logic                 tmr_load, tmr_en, tmr_zero;
  logic [TIMEOUT_W-1:0] tmr_val;

  logic [$clog2(PLL_QUAL_CYC+1)-1:0]  pll_qual_q;
  logic [$clog2(CDR_QUAL_CYC+1)-1:0]  cdr_qual_q;
  logic [$clog2(LOSS_QUAL_CYC+1)-1:0] loss_qual_q;

  logic [CNT_W-1:0] c_init_q, c_reacq_q, c_retr_q, c_fault_q;
  logic [2:0]       reason_q;
  logic             link_up_q, fast_path_q;
  logic             start_q;

  // command executor
  logic                 cmd_fire, cmd_is_wr;
  logic [ADDR_W-1:0]    cmd_addr;
  logic [DATA_W-1:0]    cmd_wdata;
  logic [1:0]           cmd_phase_q;            // 0 idle | 1 issue | 2 wait
  logic                 cmd_done;
  logic [2:0]           cmd_st_q;
  logic [DATA_W-1:0]    cmd_rd_q;

  wire cmd_ok     = (cmd_st_q == PHY_ST_OK);
  wire all_lock   = &cdr_lock;
  wire sd_ok      = !USE_SIGNAL_DETECT || (&signal_detect);
  wire lock_cond  = all_lock && sd_ok;
  wire any_unlock = ~(&cdr_lock);

  function automatic logic [CNT_W-1:0] sat_inc(input logic [CNT_W-1:0] c);
    return (&c) ? c : c + CNT_W'(1);
  endfunction

  // ------------------------------------------------------------------ timers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                   tmr_q <= '0;
    else if (tmr_load)            tmr_q <= tmr_val;
    else if (tmr_en && !tmr_zero) tmr_q <= tmr_q - TIMEOUT_W'(1);
  end
  assign tmr_zero = (tmr_q == '0);

  // qualifier counters (saturating up-counters, cleared when condition drops)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pll_qual_q  <= '0; cdr_qual_q <= '0; loss_qual_q <= '0;
    end else begin
      pll_qual_q  <= pll_lock   ? ((pll_qual_q  == PLL_QUAL_CYC[$clog2(PLL_QUAL_CYC+1)-1:0])
                                   ? pll_qual_q : pll_qual_q + 1'b1) : '0;
      cdr_qual_q  <= lock_cond  ? ((cdr_qual_q  == CDR_QUAL_CYC[$clog2(CDR_QUAL_CYC+1)-1:0])
                                   ? cdr_qual_q : cdr_qual_q + 1'b1) : '0;
      loss_qual_q <= any_unlock ? ((loss_qual_q == LOSS_QUAL_CYC[$clog2(LOSS_QUAL_CYC+1)-1:0])
                                   ? loss_qual_q : loss_qual_q + 1'b1) : '0;
    end
  end
  wire pll_ok   = (pll_qual_q  == PLL_QUAL_CYC[$clog2(PLL_QUAL_CYC+1)-1:0]);
  wire cdr_ok   = (cdr_qual_q  == CDR_QUAL_CYC[$clog2(CDR_QUAL_CYC+1)-1:0]);
  wire link_bad = (loss_qual_q == LOSS_QUAL_CYC[$clog2(LOSS_QUAL_CYC+1)-1:0]);

  // start edge detect
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) start_q <= 1'b0;
    else        start_q <= start;
  end
  wire start_edge = start & ~start_q;

  // ------------------------------------------------------- command executor
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_phase_q <= 2'd0; cmd_st_q <= PHY_ST_OK; cmd_rd_q <= '0;
    end else begin
      case (cmd_phase_q)
        2'd0: if (cmd_fire) cmd_phase_q <= 2'd1;
        2'd1: if (cr_ready) cmd_phase_q <= 2'd2;
        2'd2: if (rsp_done) begin
                cmd_st_q    <= rsp_status;
                cmd_rd_q    <= rsp_rdata;
                cmd_phase_q <= 2'd0;
              end
        default: cmd_phase_q <= 2'd0;
      endcase
    end
  end
  assign cmd_done = (cmd_phase_q == 2'd2) && rsp_done;

  always_comb begin
    cr_valid       = (cmd_phase_q == 2'd1);
    cr_op          = cmd_is_wr ? OP_WR : OP_RD;
    cr_addr        = cmd_addr;
    cr_wdata       = cmd_wdata;
    cr_wstrb       = {SW{1'b1}};
    cr_lane        = '0;
    cr_timeout_cyc = TIMEOUT_W'(CMD_TMO_CYC);
    cr_retry_max   = 4'd1;
    cr_verify_en   = 1'b0;
    cr_abort       = 1'b0;
  end

  // ------------------------------------------------------------------ main FSM
  logic [4:0] state_d;
  logic       inc_init, inc_reacq, inc_retr, clr_init;
  logic       fast_path_set;
  logic       reason_wr;
  logic [2:0] reason_val;
  logic       mon_wait_q;
  logic       mon_wait_set, mon_wait_clr;

  // next-state + per-cycle actions
  always_comb begin
    state_d    = state_q;
    tmr_en     = 1'b1;
    tmr_load   = 1'b0;
    tmr_val    = '0;
    cmd_fire   = 1'b0;
    cmd_is_wr  = 1'b0;
    cmd_addr   = DISC_ADDR;
    cmd_wdata  = '0;
    inc_init   = 1'b0;
    inc_reacq  = 1'b0;
    inc_retr   = 1'b0;
    clr_init   = 1'b0;
    fast_path_set = 1'b0;
    reason_wr  = 1'b0;
    reason_val = RSN_NONE;
    mon_wait_set = 1'b0;
    mon_wait_clr = 1'b0;

    case (state_q)
      // ------------------------------------------------ power-on / re-init gate
      SUP_RESET: begin
        tmr_en = 1'b0;
        if (start_edge) begin
          tmr_load = 1'b1; tmr_val = TIMEOUT_W'(PWR_WAIT_CYC);
          state_d  = SUP_POWER_WAIT;
        end
      end

      SUP_POWER_WAIT: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(RST_HOLD_CYC);
        state_d  = SUP_PHY_RST_ASSERT;
      end

      SUP_PHY_RST_ASSERT: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(RST_REL_CYC);
        state_d  = SUP_PHY_RST_HOLD;
      end

      SUP_PHY_RST_HOLD: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(RST_REL_CYC);
        state_d  = SUP_PHY_RST_REL;
      end

      SUP_PHY_RST_REL: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(CMD_TMO_CYC);
        state_d  = fast_path_q ? SUP_PLL_WAIT : SUP_DISCOVERY;
      end

      // ------------------------------------------------ discovery & configure
      SUP_DISCOVERY: begin
        tmr_en = 1'b0;
        if (cmd_phase_q == 2'd0 && !cmd_done && !cmd_fire) begin
          cmd_fire = 1'b1;
          cmd_addr = DISC_ADDR;
        end else if (cmd_done) begin
          if (!cmd_ok) begin
            if (c_init_q < CNT_W'(INIT_RETRY_MAX)) begin
              inc_init      = 1'b1;
              fast_path_set = 1'b1;
              tmr_load      = 1'b1; tmr_val = TIMEOUT_W'(RST_HOLD_CYC);
              state_d       = SUP_PHY_RST_ASSERT;
            end else begin
              reason_wr = 1'b1; reason_val = RSN_BUSERR;
              state_d   = SUP_FAULT;
            end
          end else if (cmd_rd_q != DISC_EXPECTED) begin
            reason_wr = 1'b1; reason_val = RSN_ID;
            state_d = SUP_FAULT;
          end else begin
            clr_init = 1'b1;
            state_d  = SUP_CONFIGURE;
          end
        end
      end

      SUP_CONFIGURE: begin
        tmr_en = 1'b0;
        if (cmd_phase_q == 2'd0 && !cmd_done && !cmd_fire) begin
          cmd_fire  = 1'b1;
          cmd_is_wr = 1'b1;
          cmd_addr  = CFG_ADDR;
          cmd_wdata = CFG_VALUE;
        end else if (cmd_done) begin
          if (cmd_ok) begin
            state_d = SUP_PLL_WAIT;
          end else if (c_init_q < CNT_W'(INIT_RETRY_MAX)) begin
            inc_init      = 1'b1;
            fast_path_set = 1'b1;
            tmr_load      = 1'b1; tmr_val = TIMEOUT_W'(RST_HOLD_CYC);
            state_d       = SUP_PHY_RST_ASSERT;
          end else begin
            reason_wr = 1'b1; reason_val = RSN_BUSERR;
            state_d   = SUP_FAULT;
          end
        end
      end

      // ------------------------------------------------ PLL / CDR bring-up
      SUP_PLL_WAIT: begin
        if (pll_ok) begin
          tmr_load = 1'b1; tmr_val = TIMEOUT_W'(CDR_TMO_CYC);
          state_d  = SUP_CDR_ACQUIRE;
        end else if (tmr_zero) begin
          if (c_init_q < CNT_W'(INIT_RETRY_MAX)) begin
            inc_init      = 1'b1;
            fast_path_set = 1'b1;
            tmr_load      = 1'b1; tmr_val = TIMEOUT_W'(RST_HOLD_CYC);
            state_d       = SUP_PHY_RST_ASSERT;
          end else begin
            reason_wr = 1'b1; reason_val = RSN_PLL_TMO;
            state_d   = SUP_FAULT;
          end
        end
      end

      SUP_CDR_ACQUIRE: begin
        if (cdr_ok) begin
          tmr_load = 1'b1; tmr_val = TIMEOUT_W'(STUB_DWELL_CYC);
          state_d  = ENABLE_BASELINE_EQ ? SUP_BASELINE_EQ
                   : ENABLE_TRAINING    ? SUP_TRAINING
                   : ENABLE_CALIBRATION ? SUP_CALIBRATION
                                        : SUP_ALIGNMENT;
        end else if (tmr_zero) begin
          if (c_reacq_q < CNT_W'(CDR_RETRY_MAX)) begin
            inc_reacq = 1'b1;
            tmr_load  = 1'b1; tmr_val = TIMEOUT_W'(CDR_TMO_CYC);
            state_d   = SUP_CDR_ACQUIRE;     // re-arm within same state
          end else begin
            reason_wr = 1'b1; reason_val = RSN_CDR_TMO;
            state_d = SUP_FAULT;
          end
        end
      end

      // bounded stubs until their engines exist (M6+/M9/M10)
      SUP_BASELINE_EQ: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(STUB_DWELL_CYC);
        state_d  = ENABLE_TRAINING ? SUP_TRAINING :
                   ENABLE_CALIBRATION ? SUP_CALIBRATION : SUP_ALIGNMENT;
      end
      SUP_TRAINING: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(STUB_DWELL_CYC);
        state_d  = ENABLE_CALIBRATION ? SUP_CALIBRATION : SUP_ALIGNMENT;
      end
      SUP_CALIBRATION: if (tmr_zero) begin
        tmr_load = 1'b1; tmr_val = TIMEOUT_W'(ALGN_CYC);
        state_d  = SUP_ALIGNMENT;
      end

      SUP_ALIGNMENT: if (tmr_zero) state_d = SUP_LINK_READY;

      SUP_LINK_READY: begin
        tmr_en  = 1'b0;
        state_d = SUP_MONITOR;
      end

      // ------------------------------------------------ monitor & recovery
      SUP_MONITOR: begin
        tmr_en = 1'b0;
        if (link_bad && !mon_wait_q) begin
          reason_wr = 1'b1; reason_val = RSN_LINKLOSS;
          state_d = SUP_DEGRADED;
        end else if (mon_wait_q) begin
          if (cmd_done) begin
            mon_wait_clr = 1'b1;
            tmr_load = 1'b1; tmr_val = TIMEOUT_W'(MON_INTERVAL);
            if (!cmd_ok) begin
              reason_wr = 1'b1; reason_val = RSN_BUSERR;
              state_d   = SUP_DEGRADED;
            end
          end
        end else if (tmr_zero && cmd_phase_q == 2'd0 && !cmd_done) begin
          cmd_fire     = 1'b1;
          cmd_addr     = STAT_ADDR;
          mon_wait_set = 1'b1;
        end
      end

      SUP_DEGRADED: state_d = SUP_RECOVERY;    // telemetry-visible hop

      SUP_RECOVERY: begin
        tmr_en = 1'b0;
        if (c_retr_q < CNT_W'(RETRAIN_MAX)) begin
          inc_retr     = 1'b1;
          fast_path_set= 1'b1;
          clr_init     = 1'b1;                 // fresh init-retry budget
          tmr_load     = 1'b1; tmr_val = TIMEOUT_W'(RST_HOLD_CYC);
          state_d      = SUP_PHY_RST_ASSERT;   // abbreviated relock sequence
        end else begin
          reason_wr = 1'b1; reason_val = RSN_RETR_EXH;
          state_d = SUP_FAULT;
        end
      end

      // ------------------------------------------------ terminal states
      SUP_FAULT: state_d = SUP_SAFE_STATE;

      SUP_SAFE_STATE: begin
        tmr_en = 1'b0;
        if (start_edge) begin
          clr_init   = 1'b1;
          tmr_load   = 1'b1; tmr_val = TIMEOUT_W'(PWR_WAIT_CYC);
          state_d    = SUP_RESET;
        end
      end

      default: state_d = SUP_SAFE_STATE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= SUP_RESET;
      reason_q    <= RSN_NONE;
      link_up_q   <= 1'b0;
      fast_path_q <= 1'b0;
      c_init_q    <= '0; c_reacq_q <= '0; c_retr_q <= '0; c_fault_q <= '0;
      phy_reset_n <= 1'b0;
      ev_init_done<= 1'b0; ev_link_up <= 1'b0; ev_link_down <= 1'b0;
      ev_fault    <= 1'b0; ev_safe <= 1'b0;
      fail_reason_o <= RSN_NONE; fail_state_o <= SUP_RESET;
    end else begin
      state_q <= state_d;

      ev_init_done <= 1'b0; ev_link_up <= 1'b0; ev_link_down <= 1'b0;
      ev_fault <= 1'b0; ev_safe <= 1'b0;

      // counters / flags driven by FSM decisions
      if (inc_init)   c_init_q  <= sat_inc(c_init_q);
      if (inc_reacq)  c_reacq_q <= sat_inc(c_reacq_q);
      if (inc_retr)   c_retr_q  <= sat_inc(c_retr_q);
      if (clr_init)   c_init_q  <= '0;
      if (fast_path_set) fast_path_q <= 1'b1;
      if (state_q != SUP_MONITOR || state_d != SUP_MONITOR) mon_wait_q <= 1'b0;
      if (mon_wait_set) mon_wait_q <= 1'b1;
      if (mon_wait_clr) mon_wait_q <= 1'b0;
      if (reason_wr) reason_q <= reason_val;

      // fast path cleared once a full init completes again via LINK_READY
      if (state_q == SUP_LINK_READY) fast_path_q <= 1'b0;

      // PHY reset pin policy: asserted from RESET until HOLD completes,
      // released for REL, forced safe in FAULT/SAFE_STATE
      case (state_q)
        SUP_RESET, SUP_POWER_WAIT, SUP_PHY_RST_ASSERT,
        SUP_PHY_RST_HOLD, SUP_FAULT, SUP_SAFE_STATE: phy_reset_n <= 1'b0;
        default:                                     phy_reset_n <= 1'b1;
      endcase

      // link-up events on first entry to LINK_READY
      if (state_q == SUP_LINK_READY && !link_up_q) begin
        link_up_q    <= 1'b1;
        ev_link_up   <= 1'b1;
        ev_init_done <= 1'b1;
      end

      // qualified link loss while up (monitored states only)
      if (link_bad && link_up_q &&
          (state_q == SUP_MONITOR || state_q == SUP_ALIGNMENT)) begin
        link_up_q    <= 1'b0;
        ev_link_down <= 1'b1;
      end

      // fault entry capture
      if (state_q != SUP_FAULT && state_d == SUP_FAULT) begin
        ev_fault      <= 1'b1;
        c_fault_q     <= sat_inc(c_fault_q);
        fail_reason_o <= reason_q;
        fail_state_o  <= state_q;
      end

      if (state_q != SUP_SAFE_STATE && state_d == SUP_SAFE_STATE)
        ev_safe <= 1'b1;

      // leaving FAULT clears latched reason source
      if (state_q == SUP_SAFE_STATE && state_d == SUP_RESET)
        reason_q <= RSN_NONE;
    end
  end

  assign state_o         = state_q;
  assign link_up_o       = link_up_q;
  assign cnt_init_retry  = c_init_q;
  assign cnt_cdr_reacq   = c_reacq_q;
  assign cnt_retrain     = c_retr_q;
  assign cnt_faults      = c_fault_q;

`ifndef SYNTHESIS
  a_bounded_wait: assert property (@(posedge clk) disable iff (!rst_n)
      (state_q inside {SUP_PLL_WAIT, SUP_CDR_ACQUIRE}) |-> (tmr_q <= TMO_MAX))
    else $error("supervisor: unbounded wait");
  a_no_cmd_from_safe: assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == SUP_SAFE_STATE) |-> !cr_valid)
    else $error("supervisor: PHY access from SAFE_STATE");
  a_fault_has_reason: assert property (@(posedge clk) disable iff (!rst_n)
      (state_q != SUP_FAULT && state_d == SUP_FAULT) |-> (fail_reason_o != RSN_NONE))
    else $error("supervisor: fault without reason");
`endif
endmodule
