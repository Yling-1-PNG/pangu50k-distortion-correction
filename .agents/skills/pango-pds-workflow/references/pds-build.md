# PDS Lite build and IP notes

These commands were observed with PDS Lite 2022.2-SP1 on Windows, not guaranteed for another release. Resolve the installation directory on each machine. Run from the directory containing the indicated project/IP file; keep all generated files in ignored `build/` or another agreed local output directory.

```powershell
& '<PDS-bin>/ip_generate.exe' -i '<instance>.idf' -verbose
& '<PDS-bin>/pds_shell.exe' -project '<project>.pds' -run compile
& '<PDS-bin>/pds_shell.exe' -project '<project>.pds' -run gen_bit_stream
```

`gen_bit_stream` runs prerequisite stages when needed. Confirm `Process "Generate Bitstream" done.`, inspect `compile/run.log`, `place_route/run.log`, `report_timing/run.log`, `generate_bitstream/run.log`, and confirm a **new** `.sbit` at the expected path. The shell may return exit code 0 even when an earlier stage prints `Program Error Out.` or stops short of bitstream generation.

For the legacy DDR3 reference, Lite needed the matching HMIC package installed in IP Compiler. The 2022.1 `.idf` was regenerated under 2022.2-SP1-Lite before compilation. Generation can replace `pnr/ddr_test.fdc` with generic example pins: in the 2026-10-14 test it changed board `ref_clk=P20` to `F14`, `pll_lock=A3` to `U19`, and swapped a DQS pair, causing place-and-route failure. Preserve an independently reviewed board FDC, inspect the post-generation diff, and rerun the FDC audit before building. The example `.idf` PAD mapping also disagreed with the board FDC on some DDR signals; a successful build or a brief BIST pass is not a substitute for full pin/throughput review.

This repository's `docs/PDS_Lite_离线验证记录_2026-10-03.md` and `progress.md` contain historical evidence, not a promise that a teammate's environment or new build passes. The official board manual, actual schematic, installed tool help, and current logs take precedence.
