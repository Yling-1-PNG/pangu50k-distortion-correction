# 盘古 50K：单目任意角度畸变矫正

本项目针对 2026 年紫光同创 FPGA 赛题二，目标是在盘古 50K（MES50HP / PGL50H）上实现单路 OV5640 视频的标定、畸变矫正、动态角度变换和实时显示。团队远端为 `Yling-1-PNG/pangu50k-distortion-correction`；原有 `test.v` 占位文件保持不变。鱼眼镜头是当前优先验证的真实输入；普通二阶径向/切向模型仍是赛题基础任务，不能用鱼眼扩展代替。

## 当前状态

- `tools/golden_model.py`：普通径向/切向模型的 PC 浮点参考。
- `tools/fisheye_model.py`：独立的鱼眼标定、逆向映射和视场取舍 PC 参考；尚无真实镜头标定数据。
- `tools/test_*model.py`：两分支共 8 项离线测试，曾在 Windows / Python 3.10 / OpenCV 4.11.0 / NumPy 1.26.4 下通过。
- `docs/`：官方题面、赛前方案、资料包分析、离线验证记录和到货后取样计划。
- `build/`：本机 PDS Lite 参考工程、日志和位流；**不纳入仓库**。官方 OV5640→DDR3→HDMI 例程离线生成过位流，但尚未在实板验证出图，也没有本赛题的 FPGA 矫正 RTL。

## 入门与测试

在 VS Code 打开仓库根目录。PC 数值测试使用已安装的 Python 3.10、NumPy、OpenCV：

```powershell
py -3.10 -B -m unittest discover -s tools -p 'test_*model.py' -v
```

PDS Lite 是综合、布局布线、位流和下载工具；VS Code/Codex 负责源代码、脚本、仿真、检查与文档。当前本机已验证的版本为 PDS Lite 2022.2-SP1，DDR3 示例需安装 Lite HMIC IP。官方示例和厂家资料包应从官方来源各自获取，不能把本机 `build/` 当正式工程源。未来接入的正式 `.pds`、`.fdc`、`.idf`、RTL 和可合法共享的必要 IP 配置应纳入版本控制，具体文件由首次实板集成时核对。

协作分支、PR、证据和文件边界见 [团队协作规范](docs/团队协作规范.md)。项目约束见 [AGENTS.md](AGENTS.md)，赛题需求以 [官方题面](docs/紫光赛题.pdf) 为准。方案 Markdown 是可编辑正文；对应 PDF 由一名集成负责人更新，以减少二进制冲突。历史底稿在 `tools/assets/initial_plan_base_17p.pdf`，更新脚本为 `tools/append_plan_update.py`。

PGL50H/PDS 开发可在仓库根目录用 `$pango-pds-workflow` 调用团队 skill；Codex 也可在匹配的任务中自动选用。skill 位于 `.agents/skills/pango-pds-workflow/`，随仓库共享，无需复制到每位成员的个人 skills 目录。它包含按需加载的构建/上板参考和只读 FDC 预检脚本；具体 PDS 安装路径、板卡修订、参考例程与实测结果仍由各成员在本机核实。

## 尚未验证

真实 OV5640 鱼眼内参与畸变参数、HDMI/摄像头实际运行、端到端帧率与延迟、FPGA 畸变 RTL、MTF50/SFR 与最终时序闭合，仍需实物和测量记录确认。2026-10-14 的 LED/JTAG 与 DDR3 厂家例程自检已在本机板卡通过；细节及边界见 `progress.md`，不能外推为视频链路或长时间 DDR3 性能通过。
