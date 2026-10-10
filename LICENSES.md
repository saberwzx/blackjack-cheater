# 第三方运行时与字体

本项目根据用户提供的 Blackjack Cheater 游戏设计文档重新实现。附件未提供原版源码、立绘、音乐与字体，因此不包含或宣称拥有原版游戏素材。程序绘制的界面与合成音效属于本次实现。游戏设计内容的权利归原权利人，本文件不为其另行授予许可。

## LÖVE 11.5

官方 Windows x64 运行时：https://github.com/love2d/love/releases/tag/11.5

下载来源：https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip

引擎及其依赖的完整许可随 runtime/love-11.5-win64/license.txt 分发；Windows 便携包也包含 license.txt。

## Noto Sans SC

项目来源：https://github.com/google/fonts/tree/main/ofl/notosanssc

发布字体 assets/fonts/cjk-regular.otf 来自 https://github.com/notofonts/noto-cjk/blob/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf，使用静态 Regular 字重以确保中文清晰。开发目录保留早期下载的变量字体 cjk.ttf，发布包不再包含它。字体使用 SIL Open Font License 1.1，完整许可证保存在 assets/fonts/OFL.txt 并随 .love 包及便携包 FONT-LICENSE.txt 分发。

## 开发工具

构建与辅助检查脚本仅使用 Python 标准库，游戏运行不需要安装 Python、Node.js 或任何包管理器。
