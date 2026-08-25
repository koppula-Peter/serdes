// -----------------------------------------------------------------------------
// tb_cdr_ctrl.sv — M5 unit tests: immediate / delayed / unstable / no-lock /
// lock-loss+reacquire / repeat-fail / restart. Self-checking, REGRESSION_RESULT.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_cdr_ctrl;
  logic clk=1'b0, rst_n=1'b0;
  always #5 clk=~clk;
  integer errors=0, checks=0;

  task automatic check(input string n, input logic c);
    checks++; if(c) $display("TEST %0d: %-40s PASS",checks,n);
    else begin errors++; $display("TEST %0d: %-40s FAIL",checks,n); end
  endtask

  logic start=1'b0, enable=1'b0, cdr_lock_raw=1'b0, signal_detect=1'b1;
  wire cdr_enable, adapt_freeze, locked, ev_lock, ev_loss, ev_failed;
  wire [3:0] st; wire [15:0] ca,cl,cr,ct; wire [31:0] acqt;
  int seen_lock_ev, seen_loss_ev;

  localparam logic [3:0] S_IDLE=0,S_ACQ=3,S_LOCKED=5,S_TRACK=6,S_LOSS=8,
                         S_REACQ=9,S_DLY=11;

  cdr_ctrl #(.ACQ_TMO_CYC(200),.LOCK_QUAL_CYC(4),.UNLOCK_QUAL_CYC(3),
             .RETRY_MAX(2),.RESTART_DLY_CYC(8))
  dut (.clk(clk),.rst_n(rst_n),.start(start),.enable(enable),
       .cdr_lock_raw(cdr_lock_raw),.signal_detect(signal_detect),
       .cdr_enable(cdr_enable),.adapt_freeze(adapt_freeze),.locked(locked),
       .ev_lock(ev_lock),.ev_loss(ev_loss),.ev_failed(ev_failed),
       .state_o(st),.cnt_acq(ca),.cnt_loss(cl),.cnt_reacq(cr),.cnt_tmo(ct),
       .acq_time_last(acqt));

  always @(posedge dut.ev_lock) seen_lock_ev++;
  always @(posedge dut.ev_loss) seen_loss_ev++;

  task automatic pulse_start();
    begin @(negedge clk); start<=1'b1; @(negedge clk); start<=1'b0; end
  endtask

  task automatic reset_dut();
    begin
      rst_n<=0; enable<=0; cdr_lock_raw<=0; start<=0;
      repeat(4) @(negedge clk); rst_n<=1; repeat(2) @(negedge clk);
    end
  endtask

  initial begin : main
    int n1;
    // ------------------ T01 immediate lock ------------------------------
    reset_dut();
    n1 = 0;
    enable<=1; pulse_start(); cdr_lock_raw<=1;
    while (!locked && n1<300) begin @(posedge clk); n1++; end
    @(posedge clk);                                  // settle registered state
    check("T01:immediate_lock", locked===1'b1 && (st==S_LOCKED || st==S_TRACK));

    // ------------------ T02 delayed lock within timeout -----------------
    reset_dut();
    enable<=1;
    fork pulse_start(); begin repeat(50) @(posedge clk); cdr_lock_raw<=1; end join
    n1 = 0;
    while (!locked && n1<600) begin @(posedge clk); n1++; end
    check("T02:delayed_lock", locked===1'b1);

    // ------------------ T03 unstable chatter never qualifies ------------
    reset_dut();
    enable<=1; pulse_start();
    repeat(6) begin cdr_lock_raw<=1; repeat(2)@(posedge clk); cdr_lock_raw<=0; repeat(3)@(posedge clk); end
    check("T03:chatter_not_qualified", !locked && st inside {S_ACQ,S_DLY,S_REACQ});
    n1 = 0;
    while (st!=S_IDLE && n1<3000) begin @(posedge clk); n1++; end
    check("T03:chatter_eventually_fails", st==S_IDLE && ct>0);

    // ------------------ T04 no-lock -> FAILED, budget consumed ----------
    reset_dut();
    enable<=1; pulse_start();
    n1 = 0;
    while (st!=S_IDLE && n1<3000) begin @(posedge clk); n1++; end
    check("T04:no_lock_fails", st==S_IDLE);
    check("T04:tmo_count", ct==3);          // initial attempt + 2 retries

    // ------------------ T05 loss then successful reacquire --------------
    reset_dut();
    enable<=1; pulse_start(); cdr_lock_raw<=1;
    n1 = 0; while (!locked && n1<300) begin @(posedge clk); n1++; end
    @(posedge clk); cdr_lock_raw<=0;
    repeat(6) @(posedge clk);
    check("T05:loss_detected", cl>=1 && !locked);
    check("T05:freeze_asserted", adapt_freeze===1'b1);
    repeat(5) @(posedge clk); cdr_lock_raw<=1;
    n1 = 0; while (!locked && n1<900) begin @(posedge clk); n1++; end
    check("T05:reacquired", locked && cr>=1 && adapt_freeze===1'b0);

    // ------------------ T06 persistent loss -> FAILED --------------------
    reset_dut();
    enable<=1; pulse_start(); cdr_lock_raw<=1;
    n1 = 0; while (!locked && n1<300) begin @(posedge clk); n1++; end
    @(negedge clk); cdr_lock_raw<=0;
    n1 = 0; while (st!=S_IDLE && n1<3000) begin @(posedge clk); n1++; end
    check("T06:persistent_loss_fails", st==S_IDLE);

    // ------------------ T07 restart from terminal state ------------------
    enable<=1; pulse_start(); cdr_lock_raw<=1;
    n1 = 0; while (!locked && n1<400) begin @(posedge clk); n1++; end
    check("T07:restart_works", locked===1'b1);

    $display("----------------------------------------------");
    $display("COVERAGE lock_events=%0d loss_events=%0d tmo=%0d reacq=%0d",
             seen_lock_ev, seen_loss_ev, ct, cr);
    if(errors==0) $display("REGRESSION_RESULT PASS (%0d checks)",checks);
    else          $display("REGRESSION_RESULT FAIL (%0d/%0d failed)",errors,checks);
    $finish;
  end

  initial begin #4_000_000; $display("REGRESSION_RESULT FAIL (watchdog)"); $finish; end
endmodule
