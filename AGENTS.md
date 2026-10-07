# Project instructions

- The source for competition requirements is `docs/紫光赛题.pdf`. Confirm the exact question number and wording before selecting an algorithm or asserting a requirement. Keep proposals separate from confirmed requirements.
- This project's topic is FPGA arbitrary-angle distortion correction. Do not substitute object detection or YOLO from a different contest task.
- Use `docs/紫光同创_FPGA_任意角度畸变矫正_初始方案.md` as an existing proposal, not proof that its hardware assumptions, PDS commands, or performance targets have been verified.
- VS Code and Codex can edit sources and analyze reports; PDS is the synthesis, implementation, bitstream, and download backend. Check the installed PDS interface before claiming a command-line build works.
- When asked to create a project document, save it in the requested location and read the saved file before reporting completion.
- Before team changes, read `docs/团队协作规范.md` for branch, file, evidence and hardware-test boundaries. Work in a focused branch or worktree; preserve teammates' uncommitted work and existing remote history.
- Keep `build/`, raw captures, downloaded vendor packages, credentials and PDS-generated output out of commits. Track authoritative RTL, constraints, project/IP configuration and tests after verifying their source and sharing rights.
- Keep the Brown-Conrady base model and fisheye extension distinct; use real-camera calibration records for hardware claims. PDF plan updates must follow the Markdown source and be rendered and checked.
