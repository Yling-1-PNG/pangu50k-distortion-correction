# PGL50H 畸变矫正源码

PGL50H + OV5640 + DDR3 + HDMI 的 Fish/Brown 共享校正源码及 PC 参考界面。标定参数均为诊断候选，尚未最终签核。

- `host/`、`tools/`：桌面 GUI 与 PC 参考模型；`profiles/`：两模型候选标定与 Brown 寄存器。
- `rtl/correction/`、`rtl/pgl50h_camera_distortion_top.v`、`rtl/data/`：共享校正 RTL、顶层与 ROM。
- `constraints/`：当前 FDC；`scripts/`：独立参考工程的 PDS 构建辅助脚本。

Python 3.10+ 安装 `pip install -r host/requirements.txt`，Tkinter 随 Python 安装。Windows 启动：

```powershell
py -3.10 -m host.desktop_preview --calibration profiles/fisheye.json --output-focal-px 350 --device 1 --backend msmf
```

GUI 对原始画面可手动运行 PC 参考矫正；FPGA HDMI 流仅显示，不自动二次矫正。Fish/Brown 由顶层 `USE_FISHEYE` 编译期选择，默认 Fish；Brown 参数见 `profiles/brown_registers.json`。KEY1 切换原始/矫正显示，不切换模型。

PDS 构建需调用者提供匹配的 Pango 参考工程（含厂商 DDR3/相机/HDMI IP）和 PDS Shell 路径，例如 `scripts/build_pds.ps1 -ReferenceProject <参考工程路径> -PdsShell <pds_shell.exe路径> -Model Fisheye -PrepareOnly`。输出只在仓库 `build/` 下；本仓库不附厂商加密 IP。外部 DVP/HDMI 与配置约束尚未完整签核，不能当成最终交付工程。

历史 Fish 实板实时视频、KEY 切换与 Flash 启动曾完成；本次共享源码改动后仍需重建复验。Brown 非零参数内部时序及实际相机验收仍在进行。这里不声称已完成赛题验收。
