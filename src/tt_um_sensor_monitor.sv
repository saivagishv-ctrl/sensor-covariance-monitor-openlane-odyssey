/*
 * Copyright (c) 2026 OpenLane Odyssey
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout top-level wrapper for `sensor_monitor` (running-sum,
 * shared-datapath, fully byte-serial revision). This wrapper is now a
 * pure pass-through -- sensor_monitor handles both calibration and
 * detection one byte at a time internally, so there is no buffering
 * or counting logic left in the wrapper at all.
 *
 * ---------------------------------------------------------------
 * Protocol
 * ---------------------------------------------------------------
 * Calibration: pulse uio_in[0] once (calib_start), then stream the
 * SAME 64 raw calibration bytes TWICE in a row (row-major: sample0
 * ch0..7, sample1 ch0..7, ...) via uio_in[1] -- 128 total strobes.
 * Poll uo_out[0] (calib_done) until it goes high.
 *
 * Detection: stream exactly 8 reading bytes (channel 0 first) via
 * uio_in[2]. The 8th byte's strobe finishes the detection directly --
 * wait for uo_out[2] (anomaly_valid) to pulse, then read uo_out[1]
 * (anomaly_flag).
 *
 * For both: put the byte on ui_in[7:0], then pulse the relevant
 * uio_in bit high for exactly one clock.
 *
 * Outputs:
 *   uo_out[0] = calib_done
 *   uo_out[1] = anomaly_flag (valid once anomaly_valid has pulsed)
 *   uo_out[2] = anomaly_valid (one-cycle pulse)
 *   uo_out[7:3] = 0 (unused)
 *   uio_out = 0, uio_oe = 0 (all uio pins are inputs only, no
 *   contention -- this design never drives uio_out)
 */

`default_nettype none

module tt_um_sensor_monitor #(
    parameter N     = 8,
    parameter DW    = 8
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (1 = output)
    input  wire       ena,      // high when design is powered/selected
    input  wire       clk,
    input  wire       rst_n
);

    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire calib_done;
    wire anomaly_flag;
    wire anomaly_valid;

    sensor_monitor #(
        .N(N), .DW(DW)
    ) u_sensor_monitor (
        .clk             (clk),
        .rst_n           (rst_n),
        .calib_start     (uio_in[0]),
        .calib_ld_en     (uio_in[1]),
        .calib_ld_data   (ui_in),
        .calib_done      (calib_done),
        .reading_ld_en   (uio_in[2]),
        .reading_ld_data (ui_in),
        .anomaly_flag    (anomaly_flag),
        .anomaly_valid   (anomaly_valid)
    );

    assign uo_out = {5'b0, anomaly_valid, anomaly_flag, calib_done};

    wire _unused = &{ena, uio_in[7:3], 1'b0};

endmodule
