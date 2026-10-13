# 进度记录

## 2026-09-08

- 阅读了项目规划和嵌入式仓库文档规范。
- 根据用户截图纠正了题目方向：本题是任意角度畸变矫正，不是机器视觉目标检测。
- 检索到盘古 50K + OV5640 的公开使用案例，以及 SFR/MTF 测试卡的成本区间。
- 创建 `task_plan.md`、`findings.md` 和本文件。
- 生成完整的初始方案文档。
- 根据用户开发习惯补充 VS Code + Codex + PDS 的目录结构、任务脚本、验证循环和 Codex 使用边界。
- 根据用户反馈，将文档目标从“可演示原型”升级为“覆盖全部题目任务的完整交付系统”，增加组合畸变模型、完整上位机、测试矩阵、最终验收和比赛交付物。

## 2026-10-03

- 用户正在下载官网盘古 50K“资料包1”，要求下载后整体分析并在项目内留下可复用记录；资料识别可交给 Luna，主要决策由 Sol 完成。
- 确认正式工程目录仍为 `C:\Users\Zhanglongsheng\Projects\pgl_project`；本次聊天提供的桌面工作目录不存在。常用的 Downloads、桌面、Documents、Projects 顶层以及 D 盘顶层尚未发现资料包。
- 已把研读阶段加入 `task_plan.md`。等待用户提供下载后的完整路径；尚未读取或验证资料包内容。
- 用户确认下载目录为 `D:\开发板资料\盘古50K开发板资料`，并说明尚未下载完成。目录当前有 58 个文件，其中 5 个为 `.baiduyun.p.downloading` 临时文件；尚未开始完整性判断或正式资料分析。
- 已建立当前聊天的临时自动检查（ID `50k-1`，每 15 分钟）：待目录下载完成后启动正式研读，写入 `docs/`，完成后通知用户并关闭检查。
- 下载完成后完成资料目录清点；关键三份工具链 ZIP 全条目 CRC 通过。按板卡、OV5640、DDR3、HDMI、PDS/IP 和例程研读，Luna 辅助识别，Sol 复核工程判断。
- 阅读官方赛题 PDF 第 12–14 页、MES50HP 硬件手册、OV5640 手册/原理图、摄像头/DDR3/HDMI 示例文档与实际 RTL/FDC，建立 `docs/盘古50K资料包1_研读记录.md`，保留出处、页码、版本与验证边界。
- 在项目 `build/lite_smoke` 由 PDS Lite 成功编译和综合全新 LED RTL；在 `build/legacy_led` 成功编译官方 2022.1 LED 工程。旧摄像头工程原样解压到 `build/legacy_camera` 后，Lite 编译报 DDR3 加密 `ipsxb_mcdq_wrapper_v1_2a` 未定义；记录完整日志，不能依据退出码 0 误报成功。
- 当前判断：保留 Lite 作为开发主工具，先补齐/重生成 DDR3 IP 并复测，再决定是否安装包内 PDS 2022.2 SP6.4。尚未完成布局布线、位流、下载及实板视频测试。
- 已把 A.7 资料包实证补充加入原初始方案 Markdown，并附加为原初始方案 PDF 第 18 页；原 17 页的内容流逐页比对保持一致。更新前 PDF 备份在 `build/initial_plan_before_package1.pdf`，详细研读记录仍以 `docs/盘古50K资料包1_研读记录.md` 为准。
- 尝试将临时检查 `50k-1` 设为暂停时，应用返回“Automation does not exist ... may have been deleted manually”；本机自动化配置目录也无该 ID。故未能执行显式暂停，但目前没有可定位的该项自动化；若应用仍显示检查卡片，需以卡片实际 ID 处理。
- 用户要求继续测试，并明确目前未连接开发板，只做前期工作。Lite 对旧 LED 工程的布局布线与 `.sbit` 位流生成成功；旧 HDMI 色条例程的编译与 `.sbit` 位流生成成功。均未烧录，且 HDMI 时序报告含未约束 IO、推断 1 MHz 目标，不能视为真实视频性能验证。
- 进一步运行 DDR3 `.idf` 的 `ip_generate.exe -i`，返回 `IPCompiler 0037: IP path is not specified or IP is not installed`（退出码 104）。从资料包解出 Lite HMIC `.iar` 到 `build/ip_packages/system_ip_lite/`；官方《03_IP核安装与查看用户指南.pdf》第 1–3 页确认需在 IP Compiler GUI 的 File → Update → Add Packages → Install 导入。本次会话未能控制该 GUI，尚未导入。
- 新建 `docs/PDS_Lite_离线验证记录_2026-10-03.md`，保存完整测试矩阵、日志路径、GUI 下一步和验证边界；同步修订资料包研读记录的工具选择结论。
- 将上述离线结果作为 A.8 追加到原初始方案 Markdown 与 PDF；PDF 现在 19 页，逐页核对原 18 页内容流不变，并渲染检查新增页。上次 18 页版本备份于 `build/initial_plan_before_offline_update.pdf`。
- 用户报告已安装 Lite HMIC `.iar`，本机在 Lite `ip/system_ip` 下确认 `ipsxb_hmic_s` 存在。重新从官方 RAR 解出 `build/legacy_camera_after_ip` 副本，`ip_generate.exe -i` 重生成 DDR3_50H 成功（0 错误），摄像头+DDR3+HDMI 工程编译、布局布线、`.sbit` 生成均成功；未连接开发板。
- 核查时序报告发现 178 条未约束 IO 警告；官方 FDC 的 `pix_clk` 约束为 67.5 MHz，而 PLL `.idf` 请求 37.125 MHz、top 注释 720p30，故参考工程 `All Constraints Met` 不代表实际视频时序正确。已将实证加入 `docs/PDS_Lite_离线验证记录_2026-10-03.md` 和资料包研读记录；后续先修约束/软件模型，再做实板验证。
- 将 HMIC 安装后复测结论作为 A.9 同步到初始方案 Markdown/PDF。PDF 现为 20 页，原 19 页内容流逐页比对未变；新增页已渲染检查。更新前版本备份在 `build/initial_plan_before_hmic_success.pdf`。
- 在 `build/clock_audit_2026-10-03` 独立副本中，把错误的 `pix_clk` 67.5 MHz 约束改为 PLL 参数推导的 37.121 MHz；PDS Lite 全流程构建和位流生成通过，新报告确认 37.121 MHz。178 条未约束 IO 与 38 条无时钟端点警告仍在，记录于 `docs/时钟约束与PC黄金模型_2026-10-03.md`。
- 添加 `tools/golden_model.py` 与 `tools/test_golden_model.py`，完成单目 Brown–Conrady 去畸变、任意角度逆向旋转/通用仿射及双线性采样，4 项单元测试通过，`build/golden_demo` 生成合成网格结果。
- 将本轮结论写入初始方案 A.10 并重建 PDF：现为 21 页，旧 20 页内容流逐页保持一致；最终第 21 页已渲染目视检查。

## 2026-10-05

- 用户确认标准和 200°鱼眼候选仅镜头不同；交流群的拍屏实拍显示鱼眼明显外围畸变，标准镜头畸变较弱。鱼眼目前作为优先开发镜头，但拍屏图不能用于标定或定量测评。
- 新增 `tools/fisheye_model.py`：鱼眼标定、逆向映射、视场取舍、动态角度/仿射、双线性采样；保留原普通镜头模型，防止系数混用。
- 新增 `tools/test_fisheye_model.py`，两个模型共 8 项自动测试通过。尚无真实鱼眼原始帧，鱼眼标定流程与实板画面未验证。
- 已写 `docs/鱼眼镜头离线准备_2026-10-05.md` 并把鱼眼准备摘要加入方案 A.11；方案 PDF 从 21 页更新为 22 页，旧 21 页内容流逐页保持一致，新页已渲染目视核验。更新前版本备份于 `build/initial_plan_before_fisheye_2026-10-05.pdf`。

## 2026-10-07

- 确认队友现有私有仓库 `Yling-1-PNG/pangu50k-distortion-correction` 的 `main` 起点为 `5c1804c`，本机 GitHub 账号有推送权限；正式项目目录已接入其历史，保留 `test.v`，不再创建第二个远端仓库。
- 增加团队协作规范、README、忽略规则和 Codex 工作边界。正式可维护文档、模型脚本及 PDF 底稿放在仓库；`build/` 和厂家资料整包不提交。
- 初始方案 Markdown 增加 A.12 协作附录；PDF 更新至 23 页，原 22 页内容流逐页相同，新增页已渲染目视检查。旧 PDF 备份在 `build/initial_plan_before_collaboration_20261007.pdf`。
- 运行 `py -3.10 -B -m unittest discover -s tools -p 'test_*model.py' -v`，8 项测试通过；`git diff --cached --check` 无问题。审查了 20 个待提交文件，未包含 `build/` 或厂家资料整包。
- 导入提交 `d3048dc` 已推送到队友私有仓库 `main`，`git ls-remote` 读回同一 SHA；队友原有 `5c1804c` 和 `test.v` 保留。后续本节记录更新会另行提交并推送。没有板卡连接，硬件验证状态不变。

## 2026-10-14

- 用户已连接板卡电源与 USB Cable。Windows 当前将 FTDI USB Composite、Converter A/B、COM10/COM11 全部报告为正常，设备问题码 0；这只证明驱动层恢复。
- PDS Lite 2022.2-SP1 Fabric Configuration 通过 USB Cable II 以 1 MHz 扫描 JTAG 链，识别到 PGL50H，下载前 DONE 位为 1。
- 复核 `build/legacy_led/01_led_test` 的 PGL50H/-6/FBG484 器件、LED1–8 引脚 B2/A2/B3/A3/C5/A5/F7/F8 与《MES50HP开发板硬件使用手册_1V1.pdf》第 33–34 页相符；KEY1=K18、50 MHz 时钟=P20。现有位流为 2026-10-03 的离线构建产物。旧工程中的时钟约束被推断为 1 MHz，不能把其时序报告当作 50 MHz 验收依据。
- 仅用 JTAG 将 LED `.sbit` 下载到 FPGA 易失配置，未写 Flash。配置工具报告 `Program successful`、DONE=1、CRC/ID 错误位=0；用户现场反馈 LED1–8 轮流亮，KEY1 可复位。因此 LED/JTAG 功能测试通过。下一阶段单独准备 DDR3 实板测试，不据此推断 DDR3、HDMI 或摄像头已经通过。
- 启动 DDR3 实板测试：从 `07_ddr3_test.rar` 解出测试副本。原厂 `ddr_test.fdc` 将 P20 时钟、K18 按键、R8/R9 UART 错误设为 1.2 V，与硬件手册所示 3.3 V Bank/接口不符；在 `build/legacy_ddr3` 副本中修为 LVCMOS33，并把 UART TX 驱动强度从不合法的 2 改为 8。DDR3 Bank 3 继续保持 1.5 V。原始资料包未改动。
- Lite HMIC IP 重生成成功（0 错误、0 警告），但生成器覆盖了板级 FDC，第一次布局布线因 DQS 引脚冲突而失败，旧 2023 位流未更新。随后从原始包恢复 MES50HP 的板级 FDC，再应用上述电压修正；重新编译、映射、布线、时序报告和新位流生成成功。需注意原始 `.idf` 的部分 PAD 参数与板级 FDC 不一致，后续若 DDR3 自检异常应优先审查该处，不能仅凭离线构建排除问题。
- 通过 USB Cable II 以 1 MHz 将新生成的 `build/legacy_ddr3/07_ddr3_test/ipcore/ddr3_test/pnr/generate_bitstream/test_ddr.sbit` 下载到 FPGA 易失配置（未写 Flash）。配置工具报告 `Program successful`、DONE=1、CRC/ID 错误位=0。用户现场确认 LED1 初始化完成常亮、LED2 错误指示常灭、LED3 心跳闪烁、LED4 PLL 锁定常亮，与厂家自检说明一致。因此 DDR3 初始化及例程读写自检通过；尚未测长时间稳定性、容量覆盖或实际吞吐量。
- 用户表示摄像头设备已备好，要求前置模块全部测试成功后提醒接入。当前状态：LED/JTAG 与 DDR3 自检通过，HDMI 色条尚未实板验证。摄像头保持未接；HDMI 等前置项通过后主动提醒断电并核对摄像头接线。
- 新增仓库级 `.agents/skills/pango-pds-workflow/`，用于团队复用 VS Code/Codex + PDS Lite 的 PGL50H 开发与实板验证流程。入口按需链接构建/IP 与板卡验证参考；只读 `audit_fdc.ps1` 对已修正 LED/DDR3 约束通过，并检出厂家原始 DDR3 FDC 中 P20/K18/R8/R9 的 1.2 V 错误。`AGENTS.md`、README 和团队规范加入调用入口；随后与 HDMI 准备记录一并提交到远程分支。
- HDMI 色条前置测试：按用户要求，先不接 HDMI 线、不下载到板。清除官方 `05_hdmi_test` 测试副本 FDC 中重复的旧板引脚，补 50/148.5/10 MHz 时钟约束，并将视频复位留在像素时钟域。PDS Lite 完整生成新 `.sbit`；实际像素时钟约束下慢角 setup WNS +1.826 ns，内部时钟时序通过。外部 HDMI IO 仍有未约束警告，未进行屏幕验证。详见 `docs/HDMI色条_离线准备_2026-10-14.md`。
- 已将本轮仓库文档和团队 skill 提交到 `bringup/hdmi-colorbar` 分支并推送 `origin`；厂家例程副本和 `.sbit` 均未上传。按团队规范尝试创建 PR，GitHub 集成返回 403 `Resource not accessible by integration`，需仓库成员在 GitHub 网页创建/审核 PR；当前没有 PR，也没有合并到 `main`。
- HDMI 色条实板测试进行中：用户已接 HDMI 线。PDS Lite USB Cable II 以 1 MHz 扫描 JTAG 识别到 PGL50H；将 `build/legacy_hdmi/05_hdmi_test/generate_bitstream/hdmi_test.sbit` 下载至 FPGA 易失配置（未写 Flash），工具报告 `cfg_program` 成功、DONE=1、PLL lock=1，状态寄存器 `0x001ffca0` 中 CRC/ID 错误位为 0。已请求用户确认彩条、显示器识别模式和初始化指示灯；收到观察前只算配置成功，不算 HDMI 出图通过。
