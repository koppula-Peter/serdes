// -----------------------------------------------------------------------------
// tb_phy_xact_engine.sv — self-checking unit TB for the M3 PHY Register
// Interface Engine. Implements the test matrix in docs/VERIFICATION_PLAN.md.
//
// Evidence: prints "TEST nn: name .... PASS/FAIL" per check and a final
// "REGRESSION_RESULT PASS|FAIL". Exit code via $finish after summary.
// Deterministic under +SEED=<n>.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_phy_xact_engine;
  import serdes_phy_ctrl_pkg::*;

  // ------------------------------------------------------------------
  localparam int CLIENTS = 4;
  localparam int AW = 16, DW = 16, LW = 4, TW = 24, RW = 4, CW = 32;
  localparam int SW = DW/8;
  localparam int IW = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS);

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  integer errors = 0;
  integer checks = 0;

  // ---------------- DUT wiring ----------------
  logic  [CLIENTS-1:0]           cr_valid;
  wire   [CLIENTS-1:0]           cr_ready;
  logic  [CLIENTS*2-1:0]         cr_op;
  logic  [CLIENTS*AW-1:0]        cr_addr;
  logic  [CLIENTS*DW-1:0]        cr_wdata;
  logic  [CLIENTS*SW-1:0]        cr_wstrb;
  logic  [CLIENTS*LW-1:0]        cr_lane;
  logic  [CLIENTS*TW-1:0]        cr_timeout_cyc;
  logic  [CLIENTS*RW-1:0]        cr_retry_max;
  logic  [CLIENTS-1:0]           cr_verify_en;
  logic  [CLIENTS-1:0]           cr_abort;
  wire   [CLIENTS-1:0]           rsp_done;
  wire   [CLIENTS*3-1:0]         rsp_status;
  wire   [CLIENTS*DW-1:0]        rsp_rdata;

  logic                          lock_en = 1'b0;
  logic [IW-1:0]                 lock_client = '0;

  wire                           be_cmd_valid;
  wire                           be_cmd_ready;
  wire [1:0]                     be_op;
  wire [AW-1:0]                  be_addr;
  wire [DW-1:0]                  be_wdata;
  wire [SW-1:0]                  be_wstrb;
  wire [LW-1:0]                  be_lane;
  wire                           be_rsp_valid;
  wire                           be_rsp_ready;
  wire [2:0]                     be_rsp_status;
  wire [DW-1:0]                  be_rsp_rdata;

  logic                          fault_clear = 1'b0;
  wire [CW-1:0]                  cnt_total, cnt_ok, cnt_err, cnt_timeout, cnt_retry;
  wire                           busy;
  wire [2:0]                     last_status;
  wire [IW-1:0]                  last_owner;
  wire [60:0]                    fault_first, fault_last;
  wire                           fault_first_v, fault_last_v;
  wire [2:0]                     dbg_state;
  wire [IW-1:0]                  dbg_rr_ptr;

  phy_xact_engine_top #(
    .CLIENTS(CLIENTS), .ADDR_W(AW), .DATA_W(DW), .LANE_W(LW),
    .TIMEOUT_W(TW), .RETRY_W(RW), .CNT_W(CW), .TS_W(32), .RETRY_DELAY(8)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .cr_valid(cr_valid), .cr_ready(cr_ready),
    .cr_op(cr_op), .cr_addr(cr_addr), .cr_wdata(cr_wdata), .cr_wstrb(cr_wstrb),
    .cr_lane(cr_lane), .cr_timeout_cyc(cr_timeout_cyc), .cr_retry_max(cr_retry_max),
    .cr_verify_en(cr_verify_en), .cr_abort(cr_abort),
    .rsp_done(rsp_done), .rsp_status(rsp_status), .rsp_rdata(rsp_rdata),
    .lock_en(lock_en), .lock_client(lock_client),
    .be_cmd_valid(be_cmd_valid), .be_cmd_ready(be_cmd_ready),
    .be_op(be_op), .be_addr(be_addr), .be_wdata(be_wdata),
    .be_wstrb(be_wstrb), .be_lane(be_lane),
    .be_rsp_valid(be_rsp_valid), .be_rsp_ready(be_rsp_ready),
    .be_rsp_status(be_rsp_status), .be_rsp_rdata(be_rsp_rdata),
    .fault_clear(fault_clear),
    .cnt_total(cnt_total), .cnt_ok(cnt_ok), .cnt_err(cnt_err),
    .cnt_timeout(cnt_timeout), .cnt_retry(cnt_retry),
    .busy(busy), .last_status(last_status), .last_owner(last_owner),
    .fault_first(fault_first), .fault_last(fault_last),
    .fault_first_v(fault_first_v), .fault_last_v(fault_last_v),
    .dbg_state(dbg_state), .dbg_rr_ptr(dbg_rr_ptr)
  );

  phy_backend_sim_model #(
    .ADDR_W(AW), .DATA_W(DW), .MEM_IDX_W(10), .MEM_INIT('0), .UNSUPPORTED_EN(1),
    .UNSUP_BASE(16'h0100)
  ) u_bem (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(be_cmd_valid), .cmd_ready(be_cmd_ready),
    .cmd_op(be_op), .cmd_addr(be_addr), .cmd_wdata(be_wdata),
    .cmd_wstrb(be_wstrb), .cmd_lane(be_lane),
    .rsp_valid(be_rsp_valid), .rsp_ready(be_rsp_ready),
    .rsp_rdata(be_rsp_rdata), .rsp_status(be_rsp_status)
  );

  // ------------------------------------------------------------------
  // bookkeeping
  task automatic check(input string name, input logic cond);
    checks++;
    if (cond) $display("TEST %0d: %-46s PASS", checks, name);
    else begin
      errors++;
      $display("TEST %0d: %-46s FAIL", checks, name);
    end
  endtask

  // expected-counter oracle
  integer exp_total = 0, exp_ok = 0, exp_err = 0, exp_tmo = 0, exp_rty = 0;

  task automatic snap_counters(output int t, output int o, output int e,
                               output int tm, output int r);
    t = cnt_total; o = cnt_ok; e = cnt_err; tm = cnt_timeout; r = cnt_retry;
  endtask

  task automatic chk_counters(input string tag);
    check({tag, ":cnt_total"}, cnt_total == exp_total);
    check({tag, ":cnt_ok"},    cnt_ok    == exp_ok);
    check({tag, ":cnt_err"},   cnt_err   == exp_err);
    check({tag, ":cnt_tmo"},   cnt_timeout == exp_tmo);
    check({tag, ":cnt_rty"},   cnt_retry == exp_rty);
  endtask

  // golden memory oracle (mirrors model immediate-commit semantics)
  logic [DW-1:0] golden [logic [AW-1:0]];
  function automatic logic [DW-1:0] gget(input logic [AW-1:0] a);
    return golden.exists(a) ? golden[a] : '0;
  endfunction

  function automatic logic [DW-1:0] expand_strb_f(input logic [SW-1:0] s);
    logic [DW-1:0] m;
    m = '0;
    for (int b = 0; b < SW; b++)
      if (s[b]) m[8*b +: 8] = 8'hFF;
    return m;
  endfunction

  // ------------------------------------------------------------------
  // client drivers
  task automatic drv_req(input int c,
                         input logic [1:0] op,
                         input logic [AW-1:0] addr,
                         input logic [DW-1:0] wdata,
                         input logic [SW-1:0] wstrb,
                         input logic [TW-1:0] tmo,
                         input logic [RW-1:0] rmax,
                         input logic vfy);
    begin
      @(negedge clk);
      cr_valid[c]      <= 1'b1;
      cr_op     [2*c +: 2]   <= op;
      cr_addr   [AW*c +: AW] <= addr;
      cr_wdata  [DW*c +: DW] <= wdata;
      cr_wstrb  [SW*c +: SW] <= wstrb;
      cr_lane   [LW*c +: LW] <= '0;
      cr_timeout_cyc[TW*c +: TW] <= tmo;
      cr_retry_max[RW*c +: RW]   <= rmax;
      cr_verify_en[c]   <= vfy;
      forever begin
        @(posedge clk);
        if (cr_ready[c]) break;
      end
      @(negedge clk);
      cr_valid[c] <= 1'b0;
    end
  endtask

  task automatic wait_done(input int c, output logic [2:0] st,
                           output logic [DW-1:0] rd, input int maxcyc);
    int n;
    begin
      n = 0;
      st = 'x; rd = 'x;
      while (!rsp_done[c]) begin
        @(posedge clk);
        n++;
        if (n > maxcyc) begin
          check("wait_done_bounded", 1'b0);
          return;
        end
      end
      st = rsp_status [3*c +: 3];
      rd = rsp_rdata  [DW*c +: DW];
    end
  endtask

  task automatic xact(input int c, input logic [1:0] op,
                      input logic [AW-1:0] addr, input logic [DW-1:0] wdata,
                      input logic [SW-1:0] wstrb, input logic [TW-1:0] tmo,
                      input logic [RW-1:0] rmax, input logic vfy,
                      output logic [2:0] st, output logic [DW-1:0] rd,
                      input int maxcyc = 100000);
    begin
      drv_req(c, op, addr, wdata, wstrb, tmo, rmax, vfy);
      wait_done(c, st, rd, maxcyc);
    end
  endtask

  task automatic do_write(input int c, input logic [AW-1:0] a,
                          input logic [DW-1:0] d, input logic [SW-1:0] sb);
    logic [2:0] st; logic [DW-1:0] rd;
    xact(c, PHY_OP_WRITE, a, d, sb, 300, 1, 1'b0, st, rd);
  endtask

  task automatic do_read(input int c, input logic [AW-1:0] a,
                         output logic [DW-1:0] d, output logic [2:0] st);
    xact(c, PHY_OP_READ, a, '0, '0, 300, 1, 1'b0, st, d);
  endtask

  // fault record unpack: {ts[32], op[2], addr[16], lane[4], st[3], att[4]}
  task automatic unpack_fault(input logic [60:0] f,
                              output logic [1:0] op, output logic [AW-1:0] a,
                              output logic [2:0] st, output logic [RW-1:0] at);
    begin
      op = f[28:27]; a = f[26:11]; st = f[6:4]; at = f[3:0];
    end
  endtask

  // service-order monitor: records client index at each arbiter grant
  // handshake (completion order may legally reorder under random latency)
  int unsigned issue_q[$];
  always @(posedge clk) begin
    if (rst_n && dut.g_valid && dut.core_accept_ready)
      issue_q.push_back(int'(dut.g_client));
  end

  // coverage-lite trackers
  bit seen_state [0:7];
  bit seen_status[0:7];
  bit seen_op    [0:3];
  always @(posedge clk) if (rst_n) begin
    seen_state[dut.dbg_state] = 1'b1;
    for (int i = 0; i < CLIENTS; i++) begin
      if (rsp_done[i]) seen_status[rsp_status[3*i +: 3]] = 1'b1;
    end
    if (be_cmd_valid) seen_op[be_op] = 1'b1;
  end

  // ------------------------------------------------------------------
  task automatic reset_dut();
    begin
      rst_n = 1'b0;
      repeat (5) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // deterministic PRNG (xorshift32) — seeded from +SEED=, portable across
  // simulators ($urandom seeding is not supported by xsim)
  integer rng_q = 32'hDEADBEEF;

  function automatic logic [31:0] rng_next();
    rng_q = rng_q ^ (rng_q << 13);
    rng_q = rng_q ^ (rng_q >> 17);
    rng_q = rng_q ^ (rng_q << 5);
    return rng_q;
  endfunction

  function automatic int unsigned rng_range(input int unsigned n);
    return (n == 0) ? 0 : (rng_next() % n);
  endfunction

  // ==================================================================
  integer seed;
  initial begin : main
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng_q = 32'(seed) ^ 32'hDEADBEEF;
    if (rng_q == 0) rng_q = 32'h1;
    $display("[TB] phy_xact_engine regression start, SEED=%0d", seed);

    cr_valid='0; cr_op='0; cr_addr='0; cr_wdata='0; cr_wstrb='0; cr_lane='0;
    cr_timeout_cyc='0; cr_retry_max='0; cr_verify_en='0; cr_abort='0;
    reset_dut();

    // ---------------- T01a: reset idle behaviour ----------------
    begin
      int t,o,e,tm,r; int bad=0;
      snap_counters(t,o,e,tm,r);
      repeat (20) @(posedge clk);
      if (busy || be_cmd_valid) bad=1;
      check("T01a:idle_no_spurious_cmd", !bad);
      check("T01a:counters_cleared", (t==0)&&(o==0)&&(e==0)&&(tm==0)&&(r==0));
      check("T01a:no_fault_records", !fault_first_v && !fault_last_v);
    end

    // ---------------- T01b: reset mid-transaction ----------------
    begin
      int t,o,e,tm,r; int bad=0;
      u_bem.lat_min = 3000; u_bem.lat_max = 3000;
      fork
        drv_req(0, PHY_OP_READ, 16'h0001, '0, '0, 24'hFFFFFF, 4'd0, 1'b0);
        begin
          repeat (50) @(posedge clk);
          rst_n = 1'b0;
          repeat (5) @(negedge clk);
          rst_n = 1'b1;
        end
      join
      cr_valid[0] <= 1'b0;
      u_bem.lat_min = 1; u_bem.lat_max = 4;
      repeat (10) @(posedge clk);
      if (busy || be_cmd_valid) bad = 1;
      check("T01b:reset_recovers_idle", !bad);
      snap_counters(t,o,e,tm,r);
      check("T01b:counters_zero_after_reset", (t==0)&&(r==0));
    end

    // ---------------- T02: write/readback ----------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      do_write(0, 16'h0010, 16'hABCD, 2'b11);
      golden[16'h0010] = 16'hABCD;
      do_read (0, 16'h0010, rd, st);
      exp_total+=2; exp_ok+=2;
      check("T02:write_ok",  st == PHY_ST_OK);
      check("T02:readback",  rd == 16'hABCD);
      chk_counters("T02");
    end

    // ---------------- T03: untouched read default ----------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      do_read(1, 16'h0020, rd, st);
      exp_total++; exp_ok++;
      check("T03:default_value", (st==PHY_ST_OK) && (rd == 16'h0000));
      chk_counters("T03");
    end

    // ---------------- T04: RMW partial strobe (+verify success) --------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      do_write(0, 16'h0030, 16'h1234, 2'b11);
      golden[16'h0030] = 16'h1234;
      // RMW low byte only -> expect 0x1200 ; verify enabled exercises path
      drv_req(0, PHY_OP_RMW, 16'h0030, 16'hFF00, 2'b01, 400, 1, 1'b1);
      wait_done(0, st, rd, 10000);
      exp_total+=2; exp_ok+=2;
      check("T04:rmw_status", st == PHY_ST_OK);
      // scoreboard: peek committed model memory directly
      check("T04:rmw_merge",  u_bem.mem[16'h030] == 16'h1200);
      golden[16'h0030] = 16'h1200;
      do_read(0, 16'h0030, rd, st);
      exp_total++; exp_ok++;
      check("T04:rmw_readback", rd == 16'h1200);
      chk_counters("T04");
    end

    // ---------------- T04b: write verify failure injection -------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      logic [1:0] fop; logic [AW-1:0] fa; logic [2:0] fst; logic [RW-1:0] fat;
      int te,ee;
      snap_counters(te,te,ee,te,te);
      u_bem.inj_bad_read_n = 1;
      drv_req(1, PHY_OP_WRITE, 16'h0032, 16'hCAFE, 2'b11, 500, 0, 1'b1);
      wait_done(1, st, rd, 10000);
      u_bem.inj_bad_read_n = 0;
      golden[16'h0032] = 16'hCAFE;   // committed despite failed verify
      exp_total++; exp_err++;
      check("T04b:verify_fail_status", st == PHY_ST_VERIFY_FAIL);
      unpack_fault(fault_last, fop, fa, fst, fat);
      check("T04b:fault_record", fault_last_v && (fst==PHY_ST_VERIFY_FAIL) && (fa==16'h0032));
      check("T04b:err_counted", cnt_err == ee+1);
      fault_clear = 1'b1; @(posedge clk); fault_clear = 1'b0; @(negedge clk);
      check("T04b:fault_clear", !fault_first_v && !fault_last_v);
    end

    // ---------------- T05: back-to-back single client ------------------
    begin
      logic [2:0] st; logic [DW-1:0] rd; int k;
      for (k = 0; k < 10; k++) begin
        do_write(2, 16'h0040, 16'h0100+k[15:0], 2'b11);
        golden[16'h0040] = 16'h0100+k[15:0];
        do_read (2, 16'h0040, rd, st);
        if (rd != 16'h0100+k[15:0]) begin
          check("T05:b2b_data", 1'b0);
          k = 99;
        end
        exp_total+=2; exp_ok+=2;
      end
      if (k == 10) check("T05:b2b_10_xacts", 1'b1);
      chk_counters("T05");
    end

    // ---------------- T06a: round-robin fairness -----------------------
    begin
      logic [2:0] s0,s1,s2,s3; logic [DW-1:0] r0,r1,r2,r3;
      issue_q.delete();
      fork
        xact(0, PHY_OP_READ, 16'h0050, '0,'0, 2000, 0, 0, s0, r0);
        xact(1, PHY_OP_READ, 16'h0051, '0,'0, 2000, 0, 0, s1, r1);
        xact(2, PHY_OP_READ, 16'h0052, '0,'0, 2000, 0, 0, s2, r2);
        xact(3, PHY_OP_READ, 16'h0053, '0,'0, 2000, 0, 0, s3, r3);
      join
      exp_total+=4; exp_ok+=4;
      // fairness = strict round-robin DISTANCE order; the starting point
      // rotates with the persistent rr pointer, so accept any rotation
      begin
        bit rot_ok;
        rot_ok = (issue_q.size() == CLIENTS);
        for (int k = 0; rot_ok && k < CLIENTS; k++)
          if (issue_q[k] != ((issue_q[0] + k) % CLIENTS)) rot_ok = 0;
        if (!rot_ok) $display("[T06a] issue_q=%p", issue_q);
        check("T06a:rr_rotation_fair", rot_ok);
      end
      chk_counters("T06a");
    end

    // ---------------- T06b: sequence lock exclusivity ------------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      int viol;
      int crit_done;
      issue_q.delete();
      lock_client = IW'(2); lock_en = 1'b1;
      viol = 0; crit_done = 0;
      fork
        begin : crit
          logic [DW-1:0] wd2;
          repeat (3) begin
            wd2 = rng_next();
            xact(2, PHY_OP_WRITE, 16'h0060, wd2, 2'b11, 1000, 0, 0, st, rd);
            golden[16'h0060] = wd2;   // track model commit for later reads
          end
          crit_done = 1;
        end
        begin : unlocker
          // release the lock shortly after the critical section drains,
          // otherwise locked-out drivers would deadlock the join below
          wait (crit_done == 1);
          repeat (5) @(posedge clk);
          lock_en = 1'b0;
        end
        begin : blocked0
          drv_req(0, PHY_OP_READ, 16'h0061,'0,'0,24'hFFFFFF,0,0);
          wait_done(0, st, rd, 50000);
        end
        begin : blocked1
          drv_req(1, PHY_OP_READ, 16'h0062,'0,'0,24'hFFFFFF,0,0);
          wait_done(1, st, rd, 50000);
        end
        begin : blocked3
          drv_req(3, PHY_OP_READ, 16'h0063,'0,'0,24'hFFFFFF,0,0);
          wait_done(3, st, rd, 50000);
        end
        begin : watch
          while (lock_en) begin
            @(posedge clk);
            if ((rsp_done[0]||rsp_done[1]||rsp_done[3])) viol++;
          end
        end
      join
      lock_en = 1'b0;
      check("T06b:no_service_while_locked", viol == 0);
      check("T06b:post_unlock_order_301", issue_q.size()==6 &&
            issue_q[3]==3 && issue_q[4]==0 && issue_q[5]==1);
      exp_total+=6; exp_ok+=6;
      chk_counters("T06b");
    end

    // ---------------- T07: timeout then retry succeeds -----------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      int t,o,e,tm,r;
      snap_counters(t,o,e,tm,r);
      u_bem.inj_timeout_n = 1;
      drv_req(0, PHY_OP_READ, 16'h0070, '0,'0, 300, 2, 0);
      wait_done(0, st, rd, 50000);
      u_bem.inj_timeout_n = 0;
      exp_total++; exp_ok++; exp_tmo++; exp_rty++;
      check("T07:retry_final_ok", st == PHY_ST_OK);
      check("T07:one_retry",  cnt_retry == r+1);
      check("T07:one_tmo",    cnt_timeout == tm+1);
      chk_counters("T07");
    end

    // ---------------- T08: persistent timeout -> fault records ---------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      logic [1:0] fop; logic [AW-1:0] fa; logic [2:0] fst; logic [RW-1:0] fat;
      // T07 legitimately recorded a fault; clear so this test owns the
      // first/last capture window
      fault_clear = 1'b1; @(posedge clk); fault_clear = 1'b0; @(negedge clk);
      u_bem.inj_timeout_n = 99;
      drv_req(1, PHY_OP_READ, 16'h0071, '0,'0, 80, 2, 0);
      wait_done(1, st, rd, 50000);
      u_bem.inj_timeout_n = 0;
      exp_total++; exp_err++; exp_tmo+=3; exp_rty+=2;
      check("T08:final_timeout", st == PHY_ST_TIMEOUT);
      check("T08:tmo_attempts3", cnt_timeout == exp_tmo);
      check("T08:first_v_last_v", fault_first_v && fault_last_v);
      unpack_fault(fault_first, fop, fa, fst, fat);
      check("T08:first_fields",
            (fop==PHY_OP_READ)&&(fa==16'h0071)&&(fst==PHY_ST_TIMEOUT)&&(fat==0));
      unpack_fault(fault_last, fop, fa, fst, fat);
      check("T08:last_fields",
            (fop==PHY_OP_READ)&&(fa==16'h0071)&&(fst==PHY_ST_TIMEOUT)&&(fat==2));
      // recovery after clearing injection; records stay sticky
      do_read(1, 16'h0072, rd, st);
      exp_total++; exp_ok++;
      check("T08:recovered", st == PHY_ST_OK);
      check("T08:records_sticky", fault_first_v && fault_last_v);
      chk_counters("T08");
      fault_clear = 1'b1; @(posedge clk); fault_clear = 1'b0; @(negedge clk);
    end

    // ---------------- T09: bus error then retry succeeds ---------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      u_bem.inj_bus_err_n = 1;
      drv_req(2, PHY_OP_READ, 16'h0074, '0,'0, 300, 1, 0);
      wait_done(2, st, rd, 50000);
      u_bem.inj_bus_err_n = 0;
      exp_total++; exp_ok++; exp_rty++;
      check("T09:buserr_recovered", st == PHY_ST_OK);
      chk_counters("T09");
    end

    // ---------------- T09b: unsupported address ------------------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      drv_req(3, PHY_OP_READ, 16'h0200, '0,'0, 300, 0, 0);
      wait_done(3, st, rd, 50000);
      exp_total++; exp_err++;
      check("T09b:unsupported_status", st == PHY_ST_UNSUPPORTED);
      check("T09b:no_side_effect", !golden.exists(16'h0200));
      chk_counters("T09b");
      fault_clear = 1'b1; @(posedge clk); fault_clear = 1'b0; @(negedge clk);
    end

    // ---------------- T10: abort bounded exit + orphan tolerance -------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      int waited; int t0,t1;
      u_bem.lat_min = 800; u_bem.lat_max = 800;
      fork
        begin
          drv_req(0, PHY_OP_READ, 16'h0080, '0,'0, 24'hFFFFFF, 0, 0);
          t0 = $time;
          while (!rsp_done[0]) @(posedge clk);
          t1 = $time;
          st = rsp_status[2:0];
        end
        begin
          repeat (100) @(posedge clk);
          cr_abort[0] = 1'b1;
        end
      join
      cr_abort[0] = 1'b0;
      u_bem.lat_min = 1; u_bem.lat_max = 4;
      exp_total++; exp_err++;
      check("T10:aborted_status", st == PHY_ST_ABORTED);
      check("T10:bounded_exit", (t1-t0) < 4000);   // << infinite-wait guard
      // orphan pending response must not disturb next transaction
      do_read(0, 16'h0081, rd, st);
      exp_total++; exp_ok++;
      check("T10:healthy_after_abort", st == PHY_ST_OK && rd == gget(16'h0081));
      chk_counters("T10");
    end

    // ---------------- T11: request held while busy ---------------------
    begin
      logic [2:0] st0,st1; logic [DW-1:0] r0,r1;
      fork
        begin
          xact(0, PHY_OP_READ, 16'h0090, '0,'0, 24'hFFFFF0, 0, 0, st0, r0);
        end
        begin
          drv_req(1, PHY_OP_READ, 16'h0091, '0,'0, 24'hFFFFF0, 0, 0);
          wait_done(1, st1, r1, 100000);
        end
      join
      exp_total+=2; exp_ok+=2;
      // completion order may legally invert under random latency; what
      // matters is both requests were held and served exactly once
      check("T11:both_ok", (st0==PHY_ST_OK)&&(st1==PHY_ST_OK));
      chk_counters("T11");
    end

    // ---------------- T12: randomized scoreboard -----------------------
    begin
      logic [2:0] st; logic [DW-1:0] rd;
      int c,i; logic [1:0] op; logic [AW-1:0] a; logic [DW-1:0] wd;
      logic [SW-1:0] sb; logic [TW-1:0] tmo; logic [RW-1:0] rmx; logic vf;
      int tmo_inj, bus_inj;
      logic expect_unsup;
      for (i = 0; i < 200; i++) begin
        c   = rng_range(CLIENTS);
        case (rng_range(10))
          0,1,2,3:      op = PHY_OP_READ;
          4,5,6,7,8:    op = PHY_OP_WRITE;
          default:      op = PHY_OP_RMW;
        endcase
        if (rng_range(10) < 9)       a = AW'(rng_range(16'h00FF));
        else                         a = AW'(16'h0100 + rng_range(16));
        wd  = DW'(rng_next());
        sb  = (op==PHY_OP_READ) ? SW'('0)
            : SW'(2'b11 >> rng_range(2));   // 11 or 01 or 10 mix
        if (sb == 2'b00) sb = 2'b11;
        tmo = TW'(100 + rng_range(301));
        rmx = RW'(rng_range(2));
        vf  = (op!=PHY_OP_READ) && ((rng_range(10))==0);
        tmo_inj = 0; bus_inj = 0;
        expect_unsup = (a >= 16'h0100);
        if (!expect_unsup) begin
          if (i % 37 == 35) begin u_bem.inj_timeout_n = 1; tmo_inj = 1; end
          else if (i % 53 == 17) begin u_bem.inj_bus_err_n = 1; bus_inj = 1; end
        end
        // immediate-commit rules: an accepted WRITE mutates memory even if
        // its acknowledgement is lost or error-injected. An RMW reaches its
        // write phase unless its read phase fails terminally, i.e. only an
        // INJECTED fault with no retry budget (rmx==0) ends before mutating.
        if (!expect_unsup) begin
          if ((op == PHY_OP_WRITE) ||
              ((op == PHY_OP_RMW) && ((rmx > 0) || (tmo_inj == 0 && bus_inj == 0))))
            golden[a] = (gget(a) & ~expand_strb_f(sb)) | (wd & expand_strb_f(sb));
        end
        drv_req(c, op, a, wd, sb, tmo, rmx, vf);
        wait_done(c, st, rd, 100000);
        if (tmo_inj) u_bem.inj_timeout_n = 0;
        if (bus_inj) u_bem.inj_bus_err_n = 0;

        // ---- oracle ----
        if (expect_unsup) begin
          if (st != PHY_ST_UNSUPPORTED) begin
            $display("[T12 iter%0d] unsup mismatch st=%0d a=%h", i, st, a);
            check("T12:oracle", 1'b0);
          end
          exp_total++; exp_err++;
          // non-OK statuses are retryable like any other failure
          exp_rty += rmx;
        end else if (tmo_inj || bus_inj) begin
          if (rmx == 0) begin
            // no retry budget -> transaction terminates on the injected fault
            if (st != ((tmo_inj != 0) ? PHY_ST_TIMEOUT : PHY_ST_BUS_ERROR)) begin
              $display("[T12 iter%0d] inj-final mismatch st=%0d", i, st);
              check("T12:oracle", 1'b0);
            end
            exp_total++; exp_err++;
            if (tmo_inj != 0) exp_tmo++;
          end else begin
            if (st != PHY_ST_OK) begin
              $display("[T12 iter%0d] inj-recover mismatch st=%0d", i, st);
              check("T12:oracle", 1'b0);
            end
            exp_total++; exp_ok++; exp_rty++;
            if (tmo_inj != 0) exp_tmo++;
          end
        end else begin
          if (st != PHY_ST_OK) begin
            $display("[T12 iter%0d] clean mismatch st=%0d a=%h op=%0d", i, st, a, op);
            check("T12:oracle", 1'b0);
          end
          exp_total++; exp_ok++;
          if (op == PHY_OP_READ) begin
            if (rd !== gget(a)) begin
              $display("[T12 iter%0d] read data a=%h got=%h want=%h",
                       i, a, rd, gget(a));
              check("T12:oracle", 1'b0);
            end
          end
        end
      end
      check("T12:scoreboard_complete", 1'b1);
      chk_counters("T12");
    end

    // ---------------- T13: counter consistency --------------------------
    begin
      check("T13:total_split", cnt_total == cnt_ok + cnt_err);
      check("T13:exp_match", (cnt_total==exp_total)&&(cnt_ok==exp_ok)&&
                             (cnt_err==exp_err)&&(cnt_timeout==exp_tmo)&&(cnt_retry==exp_rty));
    end

    // ---------------- summary -------------------------------------------
    $display("----------------------------------------------");
    $display("COVERAGE states_seen   = %0d%0d%0d%0d%0d%0d%0d%0d (IDLE,ISSUE,WAIT,RDEL)",
             seen_state[7],seen_state[6],seen_state[5],seen_state[4],
             seen_state[3],seen_state[2],seen_state[1],seen_state[0]);
    $display("COVERAGE statuses_seen = OK=%0d TMO=%0d BUSERR=%0d ABRT=%0d UNSUP=%0d VFYFAIL=%0d",
             seen_status[0],seen_status[1],seen_status[2],seen_status[3],
             seen_status[4],seen_status[5]);
    $display("COVERAGE ops_seen (backend face; core decomposes RMW) = RD=%0d WR=%0d RMW=%0d",
             seen_op[0],seen_op[1],seen_op[2]);
    $display("COVERAGE model_accepted=%0d responses=%0d", u_bem.m_accepted, u_bem.m_responses);
    $display("----------------------------------------------");
    if (errors == 0)
      $display("REGRESSION_RESULT PASS (%0d checks)", checks);
    else
      $display("REGRESSION_RESULT FAIL (%0d/%0d checks failed)", errors, checks);
    $finish;
  end

  // global watchdog
  initial begin
    #20_000_000;
    $display("REGRESSION_RESULT FAIL (global watchdog)");
    $finish;
  end
endmodule
