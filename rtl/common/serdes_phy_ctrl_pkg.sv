// -----------------------------------------------------------------------------
// serdes_phy_ctrl_pkg.sv
// Common types/constants for the SerDes/PHY control IP.
// Requirement refs: ARC-REQ-001/002, PHYIF family (docs/PRODUCT_REQUIREMENTS.md)
// -----------------------------------------------------------------------------
package serdes_phy_ctrl_pkg;
/* verilator lint_off UNUSEDPARAM */

  // Default geometry (overridable per module parameter)
  localparam int unsigned DEF_ADDR_W   = 16;
  localparam int unsigned DEF_DATA_W   = 16;
  localparam int unsigned DEF_LANE_W   = 4;
  localparam int unsigned DEF_TIMEOUT_W = 24;
  localparam int unsigned DEF_RETRY_W  = 4;
  localparam int unsigned DEF_CNT_W    = 32;
  localparam int unsigned DEF_TS_W     = 32;

  // PHY transaction opcodes (phy_backend_if contract, SYSTEM_ARCHITECTURE §2)
  typedef logic [1:0] phy_op_t;
  localparam phy_op_t PHY_OP_READ  = 2'b00;
  localparam phy_op_t PHY_OP_WRITE = 2'b01;
  localparam phy_op_t PHY_OP_RMW   = 2'b10;   // read -> merge -> write inside engine

  // Response status codes
  typedef logic [2:0] phy_status_t;
  localparam phy_status_t PHY_ST_OK          = 3'd0;
  localparam phy_status_t PHY_ST_TIMEOUT     = 3'd1;
  localparam phy_status_t PHY_ST_BUS_ERROR   = 3'd2;
  localparam phy_status_t PHY_ST_ABORTED     = 3'd3;
  localparam phy_status_t PHY_ST_UNSUPPORTED = 3'd4;
  localparam phy_status_t PHY_ST_VERIFY_FAIL = 3'd5;

  function automatic logic phy_status_is_error(phy_status_t s);
    return (s != PHY_ST_OK);
  endfunction

  // Expand byte strobes to a full-width data mask
  function automatic logic [63:0] phy_expand_strb(logic [7:0] strb, int unsigned nbytes);
    logic [63:0] m;
    m = '0;
    for (int b = 0; b < nbytes && b < 8; b++)
      if (strb[b]) m[8*b +: 8] = 8'hFF;
    return m;
  endfunction

  // Supervisor global FSM state encodings (specified now, implemented M4+).
  // Kept in package so telemetry encodings are frozen early.
  typedef logic [4:0] sup_state_t;
  localparam sup_state_t SUP_RESET          = 5'd0;
  localparam sup_state_t SUP_POWER_WAIT     = 5'd1;
  localparam sup_state_t SUP_PHY_RST_ASSERT = 5'd2;
  localparam sup_state_t SUP_PHY_RST_HOLD   = 5'd3;
  localparam sup_state_t SUP_PHY_RST_REL    = 5'd4;
  localparam sup_state_t SUP_DISCOVERY      = 5'd5;
  localparam sup_state_t SUP_CONFIGURE      = 5'd6;
  localparam sup_state_t SUP_PLL_WAIT       = 5'd7;
  localparam sup_state_t SUP_CDR_ACQUIRE    = 5'd8;
  localparam sup_state_t SUP_BASELINE_EQ    = 5'd9;
  localparam sup_state_t SUP_TRAINING       = 5'd10;
  localparam sup_state_t SUP_CALIBRATION    = 5'd11;
  localparam sup_state_t SUP_ALIGNMENT      = 5'd12;
  localparam sup_state_t SUP_LINK_READY     = 5'd13;
  localparam sup_state_t SUP_MONITOR        = 5'd14;
  localparam sup_state_t SUP_DEGRADED       = 5'd15;
  localparam sup_state_t SUP_RECOVERY       = 5'd16;
  localparam sup_state_t SUP_RETRAIN        = 5'd17;
  localparam sup_state_t SUP_FAULT          = 5'd18;
  localparam sup_state_t SUP_SAFE_STATE     = 5'd19;

/* verilator lint_on UNUSEDPARAM */
endpackage : serdes_phy_ctrl_pkg
