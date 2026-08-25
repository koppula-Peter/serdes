// -----------------------------------------------------------------------------
// phy_arbiter.sv — deterministic round-robin grant with sequence lock.
// Implements: PHYIF-REQ-002, PHYIF-REQ-009.
//
// Contract:
//  * A grant is issued only while core_accept_ready is high (single-cycle window).
//  * Clients hold req_valid until req_ready observed high in the same cycle.
//  * lock_en=1 restricts service to lock_client; other requests wait, bounded by
//    the lock owner's own timeouts (protects critical sequences).
//  * rr_ptr advances past the granted client -> strict fairness when unlocked.
// -----------------------------------------------------------------------------
module phy_arbiter #(
  parameter int unsigned CLIENTS  = 4,
  parameter int unsigned IW       = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS)
)(
  input  wire logic clk,
  input  wire logic rst_n,

  input  wire logic [CLIENTS-1:0] req_valid,
  output logic      [CLIENTS-1:0] req_ready,

  input  wire logic core_accept_ready,

  output wire logic         grant_valid,
  output wire logic [IW-1:0] grant_idx,

  input  wire logic        lock_en,
  input  wire logic [IW-1:0] lock_client,

  output wire logic [IW-1:0] dbg_rr_ptr
);
  logic [IW-1:0] rr_ptr_q;
  logic          grant_v;
  logic [IW-1:0] grant_i;

  // round-robin index at priority distance p from pointer (automatic: no state)
  function automatic logic [IW-1:0] rr_index(input int unsigned p,
                                             input logic [IW-1:0] ptr);
    return IW'((p + int'(ptr)) % CLIENTS);
  endfunction

  always_comb begin
    grant_v = 1'b0;
    grant_i = '0;
    if (core_accept_ready) begin
      // ascending priority distance from round-robin pointer
      for (int p = 0; p < CLIENTS; p++) begin
        if (!grant_v && req_valid[rr_index(p, rr_ptr_q)] &&
            (!lock_en || (rr_index(p, rr_ptr_q) == lock_client))) begin
          grant_v = 1'b1;
          grant_i = rr_index(p, rr_ptr_q);
        end
      end
    end
  end

  assign grant_valid = grant_v;
  assign grant_idx   = grant_i;

  always_comb begin
    req_ready = '0;
    if (grant_v)
      req_ready[grant_i] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      rr_ptr_q <= '0;
    else if (grant_v)
      rr_ptr_q <= (IW'(CLIENTS-1) == grant_i) ? '0 : grant_i + IW'(1);
  end

  assign dbg_rr_ptr = rr_ptr_q;

`ifndef SYNTHESIS
  a_no_grant_when_not_ready: assert property (@(posedge clk) disable iff (!rst_n)
      grant_v |-> core_accept_ready)
    else $error("arbiter: grant while core not ready");
  a_lock_exclusive: assert property (@(posedge clk) disable iff (!rst_n)
      (lock_en && grant_v) |-> (grant_idx == lock_client))
    else $error("arbiter: granted non-locked client during lock");
`endif
endmodule
