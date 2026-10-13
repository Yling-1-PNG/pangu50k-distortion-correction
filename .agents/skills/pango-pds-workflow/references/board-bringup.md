# MES50HP board bring-up and evidence

Apply this only when the task includes real hardware. First match the physical board revision, PGL50H package, 12 V supply, cable orientation, bank voltages, and active connector pins against the board manual/schematic. Power off before changing cables or adding the camera. Do not put 5 V onto FPGA IO. The particular MES50HP manual in the vendor bundle gives Bank 3 DDR3 at 1.5 V, common clock/key/UART interfaces at 3.3 V, and LED1-8 on B2/A2/B3/A3/C5/A5/F7/F8; verify the teammate's board rather than assuming identical revisions.

## Configuration boundary

1. Use Fabric Configuration's Boundary Scan (or a verified `cdt_cfg_shell.exe` flow) to detect `PGL50H` over the selected USB Cable. A healthy Windows FTDI device is not proof of a working JTAG chain.
2. Assign only the freshly checked `.sbit` to the detected FPGA and program volatile FPGA configuration. Do **not** select external SPI/QSPI Flash operations for bring-up. A DONE bit of 1 proves configuration, not peripheral function.
3. Observe the output specific to the test. For the vendor DDR3 BIST, the documented expectation is LED1 initialization steady on, LED2 error steady off, LED3 heartbeat blinking, LED4 PLL lock steady on. Note observation duration and who observed it; this does not quantify full capacity, sustained bandwidth, or long-term stability.
4. For HDMI, first use color bars without DDR3/camera, confirm the display mode and visual result, then test camera input. The official OV5640 reference is a raw video path, not the competition's distortion-correction implementation. Save original camera frames before calibration.

The team's current order is LED/JTAG -> DDR3 BIST -> HDMI color bars -> remind the user to power off and attach **one** OV5640 -> raw video -> calibration -> correction. Keep Brown-Conrady baseline and fisheye extension distinct. Report untested stages as untested, even when PDS generated a bitstream.
