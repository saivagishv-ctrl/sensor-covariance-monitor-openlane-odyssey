# How it works

This chip watches an 8-channel sensor (think: 8 independent readings coming
off some physical system) and flags when a new reading looks statistically
out of line with how that sensor normally behaves.

It works in two phases:

**Calibration.** You feed it a set of 8 baseline samples per channel (64
bytes total, row-major: sample 0's 8 channels, then sample 1's 8 channels,
and so on). The chip computes each channel's mean, then -- since the
variance can only be computed once the mean is known -- you send the exact
same 64 bytes a second time, and the chip computes each channel's variance
(more precisely, the sum of squared deviations from the mean) using that
now-known mean. Both passes are handled internally by 8 small per-channel
running-sum accumulators; there's no on-chip storage of the raw calibration
matrix itself.

**Detection.** Once calibrated, you feed it a new 8-channel reading, one
byte per channel. For each channel, the chip computes how far that reading's
value deviates from the calibrated mean, squares it, and compares it against
2x that channel's calibrated variance. If any channel's deviation is too
large, the whole reading is flagged as anomalous.

Both the calibration-variance step and the detection step are built from
the same shared hardware (one subtractor, one squaring multiplier) since
they never run at the same time -- this was a deliberate area optimization
to fit the design into a small number of tiles.

# How to test

All communication happens by putting a byte on `ui_in` and pulsing one of
`uio_in[0:2]` for exactly one clock cycle per byte.

**1. Calibrate:**
- Pulse `uio_in[0]` (`calib_start`) once.
- Stream the same 64 calibration bytes twice in a row (row-major: sample 0's
  8 channel bytes, then sample 1's, ... through sample 7), pulsing
  `uio_in[1]` (`calib_ld_en`) once per byte, with the byte value on `ui_in`.
- Poll `uo_out[0]` (`calib_done`) until it goes high.

**2. Send a reading and check for an anomaly:**
- Stream 8 bytes (one per channel, channel 0 first), pulsing `uio_in[2]`
  (`reading_ld_en`) once per byte, with the byte value on `ui_in`.
- The 8th byte's strobe finishes the detection directly. Watch `uo_out[2]`
  (`anomaly_valid`) -- it pulses high for one cycle right when the result is
  ready.
- Read `uo_out[1]` (`anomaly_flag`) once `anomaly_valid` has pulsed: high
  means this reading was flagged as anomalous.

You can send as many readings as you like after one calibration; re-run
calibration (from step 1) any time you want to recalibrate against a new
baseline.

# External hardware

None. All inputs are digital byte/control-strobe signals; no analog
front-end, sensors, or external components are required to exercise the
design in simulation or on the demo board -- an external microcontroller or
test harness would typically supply the actual sensor bytes in a real
deployment.
