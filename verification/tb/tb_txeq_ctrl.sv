// -----------------------------------------------------------------------------
// tb_txeq_ctrl.sv — M6 unit tests: convergence to ideal, flat-metric fallback,
// bounds/step coverage, rollback on persistent transport errors.
// Metric model: TB watches APPLY writes and preloads mem[METRIC]=|cand-IDEAL|.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_txeq_ctrl;
  import serdes_phy_ctrl_pkg::*;
  logic clk=1'b0, rst_n=1'b0;
  always #5 clk=~clk;
  integer errors=0, checks=0;

  task automatic check(input string n, input logic c);
    checks++; if(c) $display("TEST %0d: %-40s PASS",checks,n);
    else begin errors++; $display("TEST %0d: %-40s FAIL",checks,n); end
  endtask

  localparam logic [15:0] TXEQ_ADDR=16'h0010, METRIC_ADDR=16'h0012;
  localparam int IDEAL=5;

  logic start=1'b0;
  wire cr_valid, cr_ready; wire [1:0] op; wire [15:0] addr, wdata; wire [1:0] wstrb;
  wire [3:0] lane; wire [23:0] tmo; wire [3:0] rmax; wire vfy, abort;
  wire rsp_done_v; wire [2:0] rsp_status; wire [15:0] rsp_rdata;

  wire done_w, ok_w; wire [15:0] iters; wire [15:0] best_val, best_metric;

  txeq_ctrl #(.TXEQ_ADDR(TXEQ_ADDR),.METRIC_ADDR(METRIC_ADDR),
              .CUR_MAX(16'd10),.CUR_STEP(16'd1),
              .DWELL_CYC(10),.CMD_TMO(300),.MAX_ERR(2))
  dut (.clk(clk),.rst_n(rst_n),.start(start),
    .cr_valid(cr_valid),.cr_ready(cr_ready),.cr_op(op),.cr_addr(addr),
    .cr_wdata(wdata),.cr_wstrb(wstrb),.cr_lane(lane),.cr_timeout_cyc(tmo),
    .cr_retry_max(rmax),.cr_verify_en(vfy),.cr_abort(abort),
    .rsp_done(rsp_done_v),.rsp_status(rsp_status),.rsp_rdata(rsp_rdata),
    .done(done_w),.ok(ok_w),.iter_cnt(iters),.best_val(best_val),
    .best_metric(best_metric));

  phy_backend_sim_model #(.ADDR_W(16),.DATA_W(16),.MEM_IDX_W(8),
                          .UNSUPPORTED_EN(0))
  u_bem (.clk(clk),.rst_n(rst_n),
    .cmd_valid(cr_valid),.cmd_ready(cr_ready),.cmd_op(op),.cmd_addr(addr),
    .cmd_wdata(wdata),.cmd_wstrb(wstrb),.cmd_lane(lane),
    .rsp_valid(rsp_done_v),.rsp_ready(1'b1),.rsp_rdata(rsp_rdata),
    .rsp_status(rsp_status));

  // channel model: metric = |applied - IDEAL| (perfect 0 => early exit)
  int applied_q [$];
  always @(posedge clk)
    if (rst_n && cr_valid && cr_ready && op==PHY_OP_WRITE && addr==TXEQ_ADDR) begin
      applied_q.push_back(int'(wdata));
      u_bem.mem[METRIC_ADDR[7:0]] <= 16'((wdata > IDEAL) ? (wdata-IDEAL) : (IDEAL-wdata));
    end

  int n, seen_done_ev, d0;
  bit flat_en = 1'b0;
  initial begin : done_cnt
    seen_done_ev=0;
    forever @(posedge dut.done_q) seen_done_ev++;
  end

  task automatic reset_dut();
    begin rst_n<=0; start<=0; applied_q.delete();
      repeat(4) @(negedge clk); rst_n<=1; repeat(2) @(negedge clk); end
  endtask
  task automatic kick();
    begin @(negedge clk); start<=1'b1; @(negedge clk); start<=1'b0; end
  endtask

  initial begin : main
    // T01 converge to ideal with early exit
    reset_dut();
    d0=seen_done_ev; kick();
    n=0; while(seen_done_ev==d0 && n<5000) begin @(posedge clk); n++; end
    check("T01:sweep_done", seen_done_ev==d0+1);
    check("T01:ok_status", ok_w===1'b1);
    check("T01:best_is_ideal", best_val==16'd5);
    check("T01:early_exit_iters", iters==16'(IDEAL+1));   // 0..5 evaluated
    check("T01:final_applied_best", applied_q[applied_q.size()-1]==IDEAL);

    // T02 flat metric -> best stays first candidate, full bounds swept
    reset_dut();
    flat_en=1;
    d0=seen_done_ev; kick();
    n=0; while(seen_done_ev==d0 && n<9000) begin @(posedge clk); n++; end
    check("T02:done_ok", seen_done_ev==d0+1 && ok_w===1'b1);
    check("T02:best_first_candidate", best_val=='0);
    check("T02:full_sweep_iters", iters==16'd11);          // MIN..MAX inclusive
    flat_en=0;

    // T03 bounds respected across sweep
    begin
      bit inb = 1'b1;
      foreach (applied_q[i]) if (applied_q[i]>10 || applied_q[i]<0) inb=0;
      check("T03:writes_within_bounds", inb && applied_q.size()>0);
    end

    // T04 persistent bus error -> rollback to INITIAL_VALUE, err status
    reset_dut();
    u_bem.inj_bus_err_n=99;
    d0=seen_done_ev; kick();
    n=0; while(seen_done_ev==d0 && n<9000) begin @(posedge clk); n++; end
    u_bem.inj_bus_err_n=0;
    check("T04:done_err", seen_done_ev==d0+1 && ok_w===1'b0);
    check("T04:rolled_back_initial", applied_q[applied_q.size()-1]=='0);

    $display("----------------------------------------------");
    if(errors==0) $display("REGRESSION_RESULT PASS (%0d checks)",checks);
    else          $display("REGRESSION_RESULT FAIL (%0d/%0d failed)",errors,checks);
    $finish;
  end

  // flat override runs while enabled (after channel-model write)
  always @(posedge clk)
    if (rst_n && flat_en && cr_valid && cr_ready && op==PHY_OP_WRITE && addr==TXEQ_ADDR)
      u_bem.mem[METRIC_ADDR[7:0]] <= 16'd7;   // constant bad-ish metric

  initial begin #9_000_000; $display("REGRESSION_RESULT FAIL (watchdog)"); $finish; end
endmodule
