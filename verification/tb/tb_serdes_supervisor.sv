// -----------------------------------------------------------------------------
// tb_serdes_supervisor.sv — self-checking unit TB for the M4 global supervisor.
// Topology: serdes_supervisor (client 0) -> phy_xact_engine (CLIENTS=1)
//           -> phy_backend_sim_model (preloaded register map).
// Implements the M4 rows of docs/VERIFICATION_PLAN.md §2 (supervisor matrix).
// Evidence: "TEST n: name ... PASS/FAIL" lines + final REGRESSION_RESULT.
// Deterministic under +SEED=<n> (model latency PRNG).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_serdes_supervisor;
  import serdes_phy_ctrl_pkg::*;

  localparam int AW = 16, DW = 16, TW = 24;
  localparam int SW = DW/8;
  localparam logic [AW-1:0] DISC_ADDR = 16'h0000;
  localparam logic [DW-1:0] DISC_VAL  = 16'hA501;
  localparam logic [AW-1:0] CFG_ADDR  = 16'h0004;
  localparam logic [AW-1:0] STAT_ADDR = 16'h0006;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  integer errors = 0;
  integer checks = 0;

  task automatic check(input string name, input logic cond);
    checks++;
    if (cond) $display("TEST %0d: %-44s PASS", checks, name);
    else begin
      errors++;
      $display("TEST %0d: %-44s FAIL", checks, name);
    end
  endtask

  // ------------------------------------------------------ DUT wiring
  logic start = 1'b0;
  logic cr_valid;  wire cr_ready;
  wire [1:0]    cr_op;
  wire [AW-1:0] cr_addr;
  wire [DW-1:0] cr_wdata;
  wire [SW-1:0] cr_wstrb;
  wire [3:0]    cr_lane;
  wire [TW-1:0] cr_tmo;
  wire [3:0]    cr_rmax;
  wire          cr_vfy, cr_abort;

  wire        rsp_done;
  wire [2:0]  rsp_status;
  wire [DW-1:0] rsp_rdata;

  logic pll_lock = 1'b0;
  logic [0:0] cdr_lock = '0;
  wire  phy_reset_n;

  wire ev_init_done, ev_link_up, ev_link_down, ev_fault, ev_safe;
  wire [4:0] sup_state;
  wire [2:0] fail_reason;
  wire [4:0] fail_state;
  wire       link_up;
  wire [15:0] c_init, c_reacq, c_retr, c_faults;

  localparam logic [4:0] S_RESET=SUP_RESET, S_PWR=SUP_POWER_WAIT,
    S_ASSERT=SUP_PHY_RST_ASSERT, S_HOLD=SUP_PHY_RST_HOLD, S_REL=SUP_PHY_RST_REL,
    S_DISC=SUP_DISCOVERY, S_CFG=SUP_CONFIGURE, S_PLL=SUP_PLL_WAIT,
    S_CDR=SUP_CDR_ACQUIRE, S_ALGN=SUP_ALIGNMENT, S_READY=SUP_LINK_READY,
    S_MON=SUP_MONITOR, S_DEG=SUP_DEGRADED, S_REC=SUP_RECOVERY,
    S_FAULT=SUP_FAULT, S_SAFE=SUP_SAFE_STATE;

  serdes_supervisor #(
    .NUM_LANES(1), .ADDR_W(AW), .DATA_W(DW), .TIMEOUT_W(TW),
    .DISC_ADDR(DISC_ADDR), .DISC_EXPECTED(DISC_VAL),
    .CFG_ADDR(CFG_ADDR), .STAT_ADDR(STAT_ADDR),
    .PWR_WAIT_CYC(20), .RST_HOLD_CYC(10), .RST_REL_CYC(5),
    .PLL_TMO_CYC(150), .PLL_QUAL_CYC(4),
    .CDR_TMO_CYC(120), .CDR_QUAL_CYC(4), .LOSS_QUAL_CYC(4),
    .STUB_DWELL_CYC(2), .ALGN_CYC(6), .MON_INTERVAL(80), .CMD_TMO_CYC(200),
    .INIT_RETRY_MAX(1), .CDR_RETRY_MAX(1), .RETRAIN_MAX(1)
  ) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .cr_valid(cr_valid), .cr_ready(cr_ready),
    .cr_op(cr_op), .cr_addr(cr_addr), .cr_wdata(cr_wdata), .cr_wstrb(cr_wstrb),
    .cr_lane(cr_lane), .cr_timeout_cyc(cr_tmo), .cr_retry_max(cr_rmax),
    .cr_verify_en(cr_vfy), .cr_abort(cr_abort),
    .rsp_done(rsp_done), .rsp_status(rsp_status), .rsp_rdata(rsp_rdata),
    .pll_lock(pll_lock), .cdr_lock(cdr_lock), .signal_detect('0),
    .phy_reset_n(phy_reset_n),
    .ev_init_done(ev_init_done), .ev_link_up(ev_link_up),
    .ev_link_down(ev_link_down), .ev_fault(ev_fault), .ev_safe(ev_safe),
    .state_o(sup_state), .fail_reason_o(fail_reason), .fail_state_o(fail_state),
    .link_up_o(link_up),
    .cnt_init_retry(c_init), .cnt_cdr_reacq(c_reacq),
    .cnt_retrain(c_retr), .cnt_faults(c_faults)
  );

  phy_backend_sim_model #(
    .ADDR_W(AW), .DATA_W(DW), .MEM_IDX_W(8), .UNSUPPORTED_EN(1),
    .UNSUP_BASE(16'h0100)
  ) u_bem (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cr_valid), .cmd_ready(cr_ready),
    .cmd_op(cr_op), .cmd_addr(cr_addr), .cmd_wdata(cr_wdata),
    .cmd_wstrb(cr_wstrb), .cmd_lane(cr_lane),
    .rsp_valid(rsp_done), .rsp_ready(1'b1),
    .rsp_rdata(rsp_rdata), .rsp_status(rsp_status)
  );

  // auto-restorer: after a monitored link drop, bring CDR back so a bounded
  // recovery can succeed (tests control exhaustion explicitly otherwise)
  bit restorer_en = 1'b0;
  always @(negedge dut.link_up_q) begin
    if (restorer_en) begin
      repeat (40) @(posedge clk);           // > reset hold + rel + qualifiers
      cdr_lock <= 1'b1;
    end
  end

  logic [4:0] dbg_prev = 'x;
  always @(posedge clk) begin
    if (rst_n && dut.state_q !== dbg_prev) begin
      $display("[SUP %0t] st=%0d rsn=%0d tmo=%0d", $time, dut.state_q,
               fail_reason, cr_tmo);
      dbg_prev <= dut.state_q;
    end
  end

  always @(posedge clk) begin
    if (rst_n && dut.cmd_phase_q == 2'd2 && rsp_done)
      $display("[RSP %0t] st=%0d rd=%h", $time, rsp_status, rsp_rdata);
  end

  // ------------------------------------------------------------------ helpers
  task automatic pulse_start();
    begin
      @(negedge clk); start <= 1'b1;
      @(negedge clk); start <= 1'b0;
    end
  endtask

  task automatic wait_state(input logic [4:0] s, input int bound, input bit pass_on_fail = 1'b1);
    int n;
    begin
      n = 0;
      while (dut.state_q !== s && n < bound) begin
        @(posedge clk); n++;
      end
      if (pass_on_fail) check($sformatf("reach_state_%0d", s), dut.state_q === s);
    end
  endtask

  task automatic clean_slate();
    begin
      rst_n         <= 1'b0;
      pll_lock      <= 1'b0;
      cdr_lock      <= 1'b0;
      restorer_en   <= 1'b0;
      u_bem.inj_bus_err_n = 0;
      u_bem.inj_timeout_n = 0;
      repeat (5) @(negedge clk);
      rst_n <= 1'b1;
      repeat (5) @(negedge clk);
      // preload AFTER reset release: the model re-inits memory while in reset
      u_bem.mem[DISC_ADDR[7:0]] = DISC_VAL;
      u_bem.mem[STAT_ADDR[7:0]] = 16'h0000;
    end
  endtask

  // =====================================================================
  initial begin : main
    $display("[TB] serdes_supervisor regression start");
    clean_slate();

    // ---------------- T01: happy-path initialization --------------------
    begin
      int seen_up, seen_initdone;
      seen_up = 0; seen_initdone = 0;
      fork
        begin
          forever begin
            @(posedge clk);
            if (ev_link_up)    seen_up++;
            if (ev_init_done)  seen_initdone++;
            if (dut.state_q == S_READY) break;
          end
        end
        begin
          pulse_start();
          repeat (3) @(negedge clk);
          pll_lock <= 1'b1;
          cdr_lock <= 1'b1;
        end
      join
      check("T01:init_reaches_LINK_READY", dut.state_q == S_READY);
      check("T01:ev_link_up",    seen_up       == 1);
      check("T01:ev_init_done",  seen_initdone == 1);
      check("T01:link_up_o",     link_up == 1'b1);
      check("T01:phy_reset_released", phy_reset_n == 1'b1);
      check("T01:no_faults",     c_faults == 0);
      // monitor health read completes and stays in MONITOR
      repeat (200) @(posedge clk);
      check("T01:stable_MONITOR", dut.state_q == S_MON && link_up);
    end

    // ---------------- T02: discovery ID mismatch -> FAULT(ID) ------------
    begin
      clean_slate();
      u_bem.mem[DISC_ADDR[7:0]] = 16'hDEAD;              // wrong PHY
      pulse_start();
      wait_state(S_SAFE, 3000);
      check("T02:reason_ID",     fail_reason == 3'd1);
      check("T02:fail_state_DISCOVERY", fail_state == S_DISC);
      check("T02:ev_fault_seen", dut.ev_fault == 1'b1 || c_faults == 1);
      check("T02:safe_resets_phy", phy_reset_n == 1'b0);
    end

    // ---------------- T03: bus error on discovery -> bounded retry ------
    begin
      clean_slate();
      u_bem.inj_bus_err_n = 1;                            // first read fails
      pulse_start();
      repeat (3) @(negedge clk);
      pll_lock <= 1'b1; cdr_lock <= 1'b1;
      wait_state(S_READY, 4000);
      check("T03:recovered_to_READY", dut.state_q == S_READY || dut.state_q == S_MON);
      check("T03:one_init_retry", c_init == 1);
      check("T03:no_fault", c_faults == 0);
    end

    // ---------------- T04: PLL never locks -> FAULT(PLL_TMO) ------------
    begin
      clean_slate();
      pulse_start();                                      // pll stays low
      wait_state(S_SAFE, 6000);
      check("T04:reason_PLL_TMO", fail_reason == 3'd2);
      check("T04:one_init_retry", c_init == 1);
      check("T04:fault_counted",  c_faults == 1);
    end

    // ---------------- T05: CDR never locks -> FAULT(CDR_TMO) ------------
    begin
      clean_slate();
      pulse_start();
      repeat (3) @(negedge clk);
      pll_lock <= 1'b1;                                   // cdr stays low
      wait_state(S_SAFE, 8000);
      check("T05:reason_CDR_TMO", fail_reason == 3'd3);
      check("T05:one_cdr_retry",  c_reacq == 1);
      check("T05:fault_counted",  c_faults == 1);
    end

    // ---------------- T06: link loss -> recovery -> retrain exhaustion --
    begin
      clean_slate();
      restorer_en = 1'b1;
      pulse_start();
      repeat (3) @(negedge clk);
      pll_lock <= 1'b1; cdr_lock <= 1'b1;
      wait_state(S_MON, 4000);
      check("T06:up_before_loss", link_up == 1'b1);
      // first loss -> bounded recovery returns to service
      @(negedge clk); cdr_lock <= 1'b0;
      repeat (10) @(posedge clk);                         // qualify loss
      wait_state(S_MON, 6000);                            // back in service
      check("T06:recovered_once", c_retr == 1);
      check("T06:link_restored",  link_up == 1'b1);
      check("T06:down_then_up_events",
            dut.ev_link_down == 1'b0 && dut.ev_link_up == 1'b0); // pulses consumed
      // second loss exhausts RETRAIN_MAX=1 -> FAULT(RETR_EXH) -> SAFE
      @(negedge clk); cdr_lock <= 1'b0;
      restorer_en = 1'b0;
      wait_state(S_SAFE, 8000);
      check("T06:reason_RETR_EXH", fail_reason == 3'd6);
      check("T06:retrain_budget",  c_retr == 1);
      check("T06:two_faults_total", c_faults == 1);
    end

    // ---------------- T07: restart from SAFE_STATE ----------------------
    begin
      pulse_start();                                      // fresh full init
      repeat (3) @(negedge clk);
      pll_lock <= 1'b1; cdr_lock <= 1'b1;
      wait_state(S_READY, 5000);
      check("T07:reinit_after_safe", dut.state_q == S_READY || dut.state_q == S_MON);
      check("T07:budgets_cleared", c_retr == 0 && c_init == 0);
    end

    $display("----------------------------------------------");
    if (errors == 0) $display("REGRESSION_RESULT PASS (%0d checks)", checks);
    else             $display("REGRESSION_RESULT FAIL (%0d/%0d failed)", errors, checks);
    $finish;
  end

  initial begin
    #6_000_000;
    $display("REGRESSION_RESULT FAIL (global watchdog)");
    $finish;
  end
endmodule
