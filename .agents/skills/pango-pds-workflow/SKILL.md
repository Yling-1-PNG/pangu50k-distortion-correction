---
name: pango-pds-workflow
description: Develop and validate PGL50H/MES50HP FPGA projects with PDS or PDS Lite from VS Code/Codex. Use for RTL, IP, FDC constraints, builds, JTAG bring-up, DDR3, HDMI, or OV5640 in this repository; not for PC-only image-model work.
---

# PGL50H + PDS workflow

Use the repository's `AGENTS.md` and the current task as authority. This skill is a workflow, not permission to program hardware, modify Flash, install tools, or push changes. Locate the actual repository and PDS installation on the current teammate's machine; never reuse another member's absolute paths.

1. Identify the target board revision and FPGA part, the active `.pds` project, top RTL, `.fdc`, `.idf`/IP package, installed PDS version, Git status, and the intended output. Keep vendor examples and generated artifacts in ignored `build/`; do not treat them as maintained competition RTL.
2. Make source changes in VS Code/Codex. PDS/PDS Lite remains the backend for IP generation, compile, mapping, place-and-route, timing, bitstream, and configuration. Inspect the installed CLI/help before using version-specific commands; read [PDS build and IP notes](references/pds-build.md) only when running or diagnosing that flow.
3. Before building or downloading, compare the live constraint file to the exact board manual/schematic: part/package, pin direction, VCCIO/IO standard, clocks, DDR3 pins, and every active external interface. Run `scripts/audit_fdc.ps1` on the chosen FDC as a fast read-only check; it does **not** establish electrical safety. A generated DDR3 IP may overwrite the board FDC with example pins, so compare the FDC and `.idf` again **after** generation.
4. Build the smallest affected stage. Check the command log, individual stage logs, timing/unconstrained endpoints, output timestamp, and file path. PDS can exit with code 0 after a stage error; an existing `.sbit` may be stale. Never equate `All Constraints Met` with complete timing if clocks or IO are unconstrained.
5. For real-board work, read [board bring-up and evidence](references/board-bringup.md). Default to JTAG volatile configuration, not Flash. Verify cable scan and device ID before download, then check DONE/status and the expected external observation. Ask the person at the board for LED/display/camera observations when Codex cannot sense them.
6. Report the achieved evidence level separately: PC test, PDS offline build, board function, or quantitative acceptance. Record exact tool version, source/constraint revision, commands, relevant log paths, board revision, observations, and unresolved checks in project-local documentation. Do not claim arbitrary-angle correction from a vendor camera-to-HDMI pass-through example.

For this team's staged path, complete LED/JTAG, DDR3 self-test, and HDMI color bars before asking for the single OV5640 camera to be connected **with power off**. Camera raw video and real calibration precede correction RTL and performance claims. Do not require every earlier stage for an unrelated, explicitly scoped PC-only task.
