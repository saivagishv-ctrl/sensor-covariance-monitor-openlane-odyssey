![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Sensor Covariance Anomaly Detector

A Tiny Tapeout SKY130 project by **OpenLane Odyssey**.

This chip calibrates a per-channel mean and variance profile from an 8-channel
sensor's baseline readings, then flags new readings that deviate too far from
that calibrated profile -- entirely in a small, self-contained running-sum
digital design (no matrix-multiply hardware, no on-chip storage of the raw
calibration data).

- [Read the full documentation for this project](docs/info.md)

## How it works

Calibration runs in two passes over the same 64 baseline bytes: the first
pass computes each channel's mean via a running sum; the second pass, now
that the mean is known, computes each channel's variance (sum of squared
deviations) directly against the same bytes streamed a second time. Detection
then checks a new 8-channel reading, one channel per cycle, against that
calibrated profile, flagging the reading if any channel's deviation is too
large relative to its calibrated variance.

The calibration-variance step and the detection step share the same
underlying hardware (one subtractor, one squaring multiplier) since they
never run at the same time -- a deliberate area optimization that helped
this design fit into two tiles instead of the nine-plus an earlier,
matrix-multiplication-based version would have needed.

See [docs/info.md](docs/info.md) for the full byte-serial protocol and a
step-by-step guide to testing it.

## Verification

This design is verified two ways: a cocotb testbench (`test/test.py`, run
automatically by this repo's CI against both RTL and the hardened gate-level
netlist) and a plain SystemVerilog self-checking testbench
(`test/tb_tt_um_sensor_monitor.sv`) for local simulation without a Python
toolchain. Both drive the same set of calibration data and seven test
readings -- normal, clearly anomalous, a borderline pair straddling the exact
flagging threshold, and two readings with negative-byte values specifically
exercising sign-extension in the shared datapath.

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and
cheaper than ever to get your digital and analog designs manufactured on a
real chip.

To learn more, visit https://tinytapeout.com.

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## License

Apache-2.0, see [LICENSE](LICENSE).
