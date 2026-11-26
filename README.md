## 项目简介

FPGA Museum Guide 是“数芯天下”团队基于安路 EG4S20 FPGA 开发的文博多媒体展示系统。系统采用纯硬件架构，从 TF 卡读取 640×480 BMP 图片和 WAV 音频，图像经 SDRAM 双缓冲后通过 HDMI 显示。系统支持自动轮播、按键与手势交互、中文滚动字幕，并通过 FFT 将正在播放的音频实时显示为频谱。

图像处理模块支持亮度与色彩增强、轮廓强化、暖色海报效果、双线性缩放、透明度调节及渐变切换。展品图片和音频可通过 TF 卡更新，适用于文物介绍、参观路线展示与展厅信息提示。

当前版本为 **v7.9.3**。完整构建需要另行准备匹配的厂商 IP，依赖清单见 [EXCLUDED_VENDOR_FILES.txt](EXCLUDED_VENDOR_FILES.txt)，第三方代码来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 功能

- TF 卡 BMP 图片读取、SDRAM 缓冲和 HDMI 显示。
- WAV 音频播放及基于 FFT 的音频频谱可视化。
- 图片自动轮播、按键控制、APDS-9960 手势交互。
- 图像增强、轮廓及海报效果、缩放和透明度调节。
- 中文状态面板和固定内容的中文滚动字幕。

v7.9.3 字幕内容为“数芯天下的文博展览系统”，固化于 ROM，每帧向左移动 2 像素，循环显示；运行时不能通过上位机修改字幕内容。

## 系统数据路径

TF 卡 → SD/FAT 媒体读取 → SDRAM 图像缓冲 → 图像处理及 OSD → HDMI。
WAV PCM → 播放通路及 FFT → 音频输出和频谱叠加。
按键及 APDS-9960 → 控制逻辑 → 切图、轮播及显示参数。

## 硬件与素材

使用匹配工程引脚约束的 HX4S20C / EG4S20BG256 板卡、TF 卡及 HDMI 显示设备；手势模块可选。按板卡版本核对 `project/user_source/constraints_source/`，不能直接套用其他板卡接线。

图片使用 640×480、24 位、未压缩 BMP。音频入口为 `MUSIC.WAV`；具体 WAV 头解析、采样格式及目录扫描限制以 SD 控制器实现为准。仓库草稿不包含展品图片、音乐或厂商安装包，素材需自行准备并确认授权。

APDS-9960 接线及历史操作说明见 `docs/`。历史文档中的版本号、按键和手势映射应结合最新 RTL 核对。

## 目录

| 路径 | 内容 |
| --- | --- |
| `project/user_source/hdl_source/` | 媒体、图像、字幕、频谱、交互 RTL |
| `project/user_source/constraints_source/` | 引脚与时序约束 |
| `project/td_project/` | Tang Dynasty 工程文件 |
| `tests/` | 仿真测试和向量 |
| `tools/` | 历史构建、仿真及打包脚本 |
| `verification/` | 原基线构建与测试记录 |
| `docs/` | 版本行为、接线和来源说明 |

## 构建与仿真

原基线使用 Tang Dynasty 6.2.168116，目标器件 EG4S20BG256。请先从安路合法获取匹配的 HDMI、SDRAM、PLL 和 FIFO 依赖，并按 `EXCLUDED_VENDOR_FILES.txt` 恢复所需相对路径。取得许可前不要将这些文件上传仓库。

使用 TD 打开 `project/td_project/HDMI1.4b_Transmitter_v1.0.al`，检查工程根路径、器件、源文件及约束后运行综合和布局布线。

`tools/build_td.py` 和仿真脚本保留原版用于追溯，仍包含原电脑的 `E:`、`D:` 等工具及基线路径。它们尚未移植为通用脚本，使用前需调整安装路径及模板引用；不能直接视为一键构建入口。

字幕模块仿真入口为 `tools/test_scrolling_subtitle.py`，状态面板入口为 `tools/test_status_panel.py`。原脚本使用 ModelSim。历史 `test_fixed_subtitle.py` 不适用于当前滚动位置。

## 验证记录

原 v7.9.3 记录包含 420 次帧边界检查和 51200 个字幕 RTL 输出像素检查，建立时序裕量 +0.110 ns，保持裕量 +0.003 ns。记录见 `verification/`。

这些结果属于原始完整基线。本次整理仅做复制和完整性核对，未重新综合或仿真；排除依赖后的草稿不能继承为“已通过构建”。原记录也不能代表本次整理版本已完成实板播放或长期运行验证。

## 来源和许可证

基础工程来自安路示例，音频可视化保留了参考项目的设计影响。FFT 的 DIF 重构不意味着整个项目独立原创。详见 `THIRD_PARTY_NOTICES.md` 和 `docs/AUDIO_PROVENANCE.md`。

当前没有根目录 `LICENSE`，不能据此推定任何第三方代码已获得 MIT 等授权。完成来源及权利范围核对后，才为有权授权的文件选择许可证。
