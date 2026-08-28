/*
 * Copyright (c) 2026 OpenLane Odyssey
 * SPDX-License-Identifier: Apache-2.0
 */

module sensor_monitor #(
    parameter N     = 8,
    parameter DW    = 8,
    parameter SUM_W = 11,   // exact width for sum of N=8 signed DW=8 samples (-1024..+1016)
    parameter DEV_W = 9,    // exact width for a single deviation (-255..+255)
    parameter VAR_W = 20    // exact width for sum of N=8 squared deviations (0..520200)
)(
    input  logic clk,
    input  logic rst_n,

    // ================================================================
    // Calibration -- byte-serial, no address bus at all.
    // Protocol: pulse calib_start once, then stream the SAME N*N raw
    // calibration bytes TWICE in a row (row-major: sample0 ch0..7,
    // sample1 ch0..7, ...). Pass 0 accumulates each channel's running
    // sum (-> mean); pass 1, now that each channel's mean is known,
    // accumulates each channel's sum of squared deviations (the
    // covariance diagonal) directly against the raw bytes as they
    // stream past a second time.
    // ================================================================
    input  logic calib_start,
    input  logic calib_ld_en,
    input  logic signed [DW-1:0] calib_ld_data,
    output logic calib_done,

    // ================================================================
    // Detection -- ALSO byte-serial now, symmetric with calibration:
    // pulse reading_ld_en once per channel byte (8 pulses per reading,
    // channel 0 first). No wide "assemble the whole reading" bus and
    // no separate detect_en pulse -- the 8th byte's strobe finishes
    // the detection and updates anomaly_flag/anomaly_valid directly.
    // ================================================================
    input  logic reading_ld_en,
    input  logic signed [DW-1:0] reading_ld_data,
    output logic anomaly_flag,
    output logic anomaly_valid
);

    localparam COLBITS  = $clog2(N);
    localparam THRESH   = 2;
    localparam CNT_W    = $clog2(N*N*2);

    // ================================================================
    // Persistent per-channel state
    // ================================================================
    logic signed [SUM_W-1:0] chan_sum        [N]; // pass-0 scratch: running sum of raw samples
    logic signed [DW-1:0]    mean_profile    [N]; // finalized after each channel's Nth pass-0 sample
    logic signed [VAR_W-1:0] variance_profile[N]; // finalized after each channel's Nth pass-1 sample

    logic [CNT_W-1:0] byte_cnt;                    // 0..127: counts both calibration passes
    wire              cal_phase    = byte_cnt[CNT_W-1];        // 0 = sum pass, 1 = variance pass
    wire [COLBITS-1:0] channel     = byte_cnt[COLBITS-1:0];
    wire [COLBITS-1:0] row         = byte_cnt[2*COLBITS-1:COLBITS];
    wire              is_last_byte = (byte_cnt == (N*N*2 - 1));

    logic [COLBITS-1:0] det_ch;
    logic                det_any_flag;
    wire                 det_active = reading_ld_en; // calib_ld_en / reading_ld_en are mutually
                                                      // exclusive by protocol (the host only ever
                                                      // pulses one at a time), so this is a safe
                                                      // mux select for sharing the datapath below.

    // Precompute sign bits via genvar (constant at elaboration time),
    // so the shared datapath only ever does plain variable-indexed
    // *array* reads -- never a bit-select chained onto a variable
    // array index, which some simulators only partially support.
    logic mean_sign [N];
    logic var_sign  [N];
    genvar gs;
    generate
        for (gs = 0; gs < N; gs = gs + 1) begin : gen_signs
            assign mean_sign[gs] = mean_profile[gs][DW-1];
            assign var_sign[gs]  = variance_profile[gs][VAR_W-1];
        end
    endgenerate

    // ================================================================
    // SHARED datapath: one subtractor, one squaring multiplier, one
    // pair of array read ports -- reused by calibration's variance
    // pass AND by detection, since the two never run concurrently.
    // ================================================================
    wire [COLBITS-1:0]   idx         = det_active ? det_ch : channel;
    wire signed [DW-1:0] val_in      = det_active ? reading_ld_data : calib_ld_data;

    logic signed [SUM_W-1:0] new_chan_sum;
    logic signed [DEV_W-1:0] deviation;
    logic signed [VAR_W-1:0] dev_sq;
    logic signed [VAR_W-1:0] new_var_sum;
    logic signed [VAR_W:0]   var_thresh;
    logic                    ch_is_anomalous;
    logic                    next_any_flag;

    always_comb begin
        new_chan_sum = (row == 0) ? $signed(calib_ld_data) : (chan_sum[channel] + $signed(calib_ld_data));

        deviation = $signed({{(DEV_W-DW){val_in[DW-1]}}, val_in})
                  - $signed({{(DEV_W-DW){mean_sign[idx]}}, mean_profile[idx]});
        dev_sq    = deviation * deviation;

        new_var_sum     = (row == 0) ? dev_sq : (variance_profile[idx] + dev_sq);
        var_thresh      = {var_sign[idx], variance_profile[idx]} <<< 1; // *THRESH(=2)
        ch_is_anomalous = ({dev_sq[VAR_W-1], dev_sq} > var_thresh);
        next_any_flag   = (det_ch == 0) ? ch_is_anomalous : (det_any_flag | ch_is_anomalous);
    end

    // ================================================================
    // Calibration control
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt   <= '0;
            calib_done <= 1'b0;
            for (int c = 0; c < N; c++) begin
                chan_sum[c]         <= '0;
                mean_profile[c]     <= '0;
                variance_profile[c] <= '0;
            end
        end else if (calib_start) begin
            byte_cnt   <= '0;
            calib_done <= 1'b0;
        end else if (calib_ld_en) begin
            if (!cal_phase) begin
                chan_sum[channel] <= new_chan_sum;
                if (row == N-1)
                    mean_profile[channel] <= new_chan_sum >>> COLBITS; // /N, N is a power of 2
            end else begin
                variance_profile[channel] <= new_var_sum;
            end

            byte_cnt <= byte_cnt + 1'b1;
            if (is_last_byte)
                calib_done <= 1'b1;
        end
    end

    // ================================================================
    // Detection control -- byte-serial, symmetric with calibration:
    // one channel processed per reading_ld_en pulse, using the shared
    // datapath above.
    // ================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            det_ch        <= '0;
            det_any_flag  <= 1'b0;
            anomaly_flag  <= 1'b0;
            anomaly_valid <= 1'b0;
        end else begin
            anomaly_valid <= 1'b0; // default: single-cycle pulse
            if (reading_ld_en && calib_done) begin
                det_any_flag <= next_any_flag;
                if (det_ch == N-1) begin
                    det_ch        <= '0;
                    anomaly_flag  <= next_any_flag;
                    anomaly_valid <= 1'b1;
                end else begin
                    det_ch <= det_ch + 1'b1;
                end
            end
        end
    end

endmodule
