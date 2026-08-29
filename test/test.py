import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

# uio_in control bit positions (see tt_um_sensor_monitor.sv header)
BIT_CALIB_START = 0
BIT_CAL_LD      = 1
BIT_READING_LD  = 2

CALIB_RAW = [
    [27, 22, 24, 29, 27, 16, 24, 19],
    [20, 22, 21, 26, 23, 20, 22, 21],
    [26, 19, 21, 17, 10, 23, 23, 17],
    [29, 14, 20, 19, 26, 26, 21, 22],
    [16, 12, 19, 21, 25, 25, 18, 19],
    [16, 14, 13, 28, 18, 18, 15, 23],
    [14, 19, 16, 22, 18, 15, 20, 22],
    [20, 21, 17, 19, 17, 19, 17, 13],
]

TEST_READINGS = [
    ("normal_1",          [27, 22, 24, 29, 27, 16, 24, 19], False),
    ("normal_2",          [22, 16, 18, 23, 19, 20, 21, 18], False),
    ("anomalous_1",       [51, 47, 48, 52, 50, 50, 50, 49], True),
    ("borderline_noflag", [42, 17, 18, 22, 20, 20, 20, 19], False),
    ("borderline_flag",   [43, 17, 18, 22, 20, 20, 20, 19], True),
    ("negative_ch0",      [-20, 17, 18, 22, 20, 20, 20, 19], True),
    ("negative_ch3",      [21, 17, 18, -3, 20, 20, 20, 19], True),
]


def to_u8(v):
    return v & 0xFF


async def pulse_strobe(dut, bit, byte_val):
    dut.ui_in.value = to_u8(byte_val)
    dut.uio_in.value = (1 << bit)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)


async def pulse_reading_byte(dut, byte_val):
    """Like pulse_strobe, but samples uo_out just before the NEXT clock
    edge (not a fixed short delay after this one) since anomaly_valid is
    a single-cycle pulse that needs to be sampled once fully settled.
    A fixed short delay (e.g. 1ns) is enough margin for RTL simulation
    (zero-delay logic) but not for gate-level simulation, where every
    synthesized cell has a real UNIT_DELAY and a deep combinational path
    (like the shared subtract/multiply/compare datapath here) can take
    longer than that to settle -- sampling too early reads a stale value
    even though the real hardware gets the correct answer only slightly
    later in the same cycle."""
    dut.ui_in.value = to_u8(byte_val)
    dut.uio_in.value = (1 << BIT_READING_LD)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)  # sample mid-cycle, well after any gate-level settling
    uo = int(dut.uo_out.value)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)
    return uo


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_calibration(dut, matrix, timeout_cycles=5000):
    # calib_start FIRST, then stream the same 64 bytes TWICE (sum pass,
    # then variance pass) -- no address bus at all.
    await pulse_strobe(dut, BIT_CALIB_START, 0)
    for _ in range(2):
        for row in matrix:
            for byte_val in row:
                await pulse_strobe(dut, BIT_CAL_LD, byte_val)

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & 0x1:
            return
    raise TimeoutError("calib_done never asserted")


async def send_reading_and_get_flag(dut, reading_bytes):
    got_valid, got_flag = False, False
    for byte_val in reading_bytes:
        uo = await pulse_reading_byte(dut, byte_val)
        if uo & 0x4:  # anomaly_valid pulse (fires on the 8th byte)
            got_valid, got_flag = True, bool(uo & 0x2)
    if not got_valid:
        raise TimeoutError("anomaly_valid never pulsed")
    return got_flag


@cocotb.test()
async def test_calibration_and_detection(dut):
    cocotb.start_soon(Clock(dut.clk, 25, unit="ns").start())  # 40MHz -- matches the
    # real, OpenLane-verified safe clock period (post-route STA: worst setup slack
    # 3.24ns at 25ns across all PVT corners). The gate-level test specifically needs
    # this to be realistic, since it's the one test that models real gate delay
    # (UNIT_DELAY=#1) -- RTL simulation doesn't care about clock speed since it
    # treats all logic as instantaneous, but gate-level sim will actually expose a
    # too-fast clock as a real timing failure, which is exactly what happened here.

    await reset_dut(dut)

    dut._log.info("Starting calibration, streaming 128 bytes (2 passes)")
    await run_calibration(dut, CALIB_RAW)
    assert int(dut.uo_out.value) & 0x1, "calib_done should be high after calibration"

    for name, reading, expected_flag in TEST_READINGS:
        dut._log.info(f"Sending reading '{name}': {reading}")
        got_flag = await send_reading_and_get_flag(dut, reading)
        assert got_flag == expected_flag, (
            f"{name}: expected anomaly_flag={expected_flag}, got {got_flag}"
        )
        dut._log.info(f"'{name}' OK (anomaly_flag={got_flag})")
