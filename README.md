# Blackjack Cheater

根据随任务提供的游戏设计文档重建的中文单机卡牌游戏。LÖVE 11.5 / LuaJIT，Windows x64，键盘与鼠标操作。

## 直接游玩

便携包用户直接打开同目录的 BlackjackCheater.exe。源工程用户可打开 dist/BlackjackCheater-Windows/BlackjackCheater.exe，或将 dist/BlackjackCheater-Windows.zip 解压后打开其中 BlackjackCheater.exe。便携目录内的 DLL 和 saves21 文件夹应与程序一起保留，不要仅复制 EXE。

开发工程可双击 Start-BlackjackCheater.bat 启动；工程内已经附带 LÖVE 运行时，无需额外安装。dist/BlackjackCheater.love 也可交给已安装的 LÖVE 11.5 运行。

## 游戏目标

基础模式从 2500 筹码出发，在有限局数内达到阶段目标，购买遗物和特殊牌组形成组合。困难模式加入庄家职阶；酒吧模式独立使用酒水与主动技能推进，不积累主模式经济进度。

先选开局遗物，再下注。要牌会增加点数，停牌后由庄家行动。A 通常按 11 计，超过 21 时可降为 1；特殊牌以自己的点数规则为准。自然 Blackjack 按设计文档返还下注的 1.5 倍，下注已经提前扣除，这与常见赌场规则不同。

庄家在后续阶段可能出千，注意真实牌面上的痕迹。错误指认会罚款并结束玩家行动。牌靴情报、标记、钓具与遗物激活是主要策略工具；不足以精确计算的情报会显示未知。启用钓具后，打开情报面板并点击已标记牌执行操作；换位钓具依次选择两张已标记牌。

鼠标可完成游戏内主要交互，按钮旁显示相应快捷键。Esc 优先关闭当前弹层或打开设置。设置中可调整音量、窗口大小和全屏。

## 存档

元进度与冠军牌组分别保存在游戏旁 saves21/progress.lua 和 saves21/collection.lua。源工程运行时位于工程的 saves21；便携版本位于 EXE 旁 saves21。测试与自动截图使用隔离的内存存档，不应污染正式进度。迁移时复制整个 saves21 文件夹。

存档保存的是元进度与设置，不是可以随时恢复的进行中对局。文件损坏或无法读写时会回退默认状态；请将整个游戏放在可写目录，不建议在压缩包中直接双击运行。

## 工程与重建

main.lua 与 ui/ 负责窗口、界面、输入、程序化绘图和音频。src/ 包含可在无图形环境下运行的游戏规则；tests/ 为核心验证；tools/ 为独立验收与打包工具；docs/ 包含接口、规格解释与覆盖说明；artifacts/ 保存实际验收产物。

安装 Python 3 后双击 Build.bat，生成 .love、Windows 便携目录及 ZIP，dist/manifest.json 记录 SHA-256 校验值。游戏运行本身不需要 Python。

## 素材与规格边界

输入只包含设计文档，没有原版源码、人物立绘或音乐。本次实现采用重新设计的程序化视觉、合成音效与 Noto Sans SC 中文字体；不宣称原版素材复刻。冠军牌池按附录分项构造，分项合计 345，与原文写的 290 不一致。详细解释见 docs/SPEC-DECISIONS.md，第三方许可见 LICENSES.md。

验收结果以 artifacts/ 下实际日志及 docs/IMPLEMENTATION.md 为准，不沿用设计文档中原版项目的测试数量。
