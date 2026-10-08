# BlackJack Cheater

> 把链式算分爆炸装进 21 点赌桌的 Roguelike —— 真正的对手不是庄家的点数，而是**庄家会出千**。

**English**: A blackjack roguelike where the dealer cheats — buy information, mark the shoe, accuse the cheat, and blow the scoring formula sky-high.

## 玩法特色

- **反出千博弈系统**：庄家五种千招各自绑定专属视觉痕迹，配合形似的假痕迹干扰项；按 `C` 指认，指认成功只看庄家是否**真正改动过牌**——读牌是真实力，不是掷骰。
- **赌信息经济**：窥牌 / 烧牌 / 切牌 / 爆注边注全部用当前牌靴成分**实时精确定价**，信息投资有显式价格曲线；`ShoeInfo` 同种子两次运行逐位一致，可被无头测试断言。
- **139 件遗物 + 链式算分**：`(基础筹码 + 遗物筹码) × (1 + 倍率) × ∏x_mult`，事件驱动的内容触发总线让每件遗物都是一条 hook。
- **三条玩法线**：基础模式（教学与首通）/ 困难模式（庄家全程持职阶）/ 酒吧模式（无筹码纯氛围的反差向第二体验）。
- **冠军牌组编辑器**：通关困难模式后从 290 个牌面里自选恰好 36 张组成一副牌，保存并上架到下周商店——玩家的构筑差异直接进游戏经济。

## 运行

1. 安装 [LÖVE 2D 11.5](https://love2d.org/)；
2. 本目录（含 `main.lua` / `conf.lua`）即为游戏源码，直接运行：

```bat
love "path\to\this\folder"
```

3. 或将目录打包为 `.love` 文件后与 `love.exe` 合并发布（见 LÖVE 官方 wiki 的 Game Distribution）。

## 素材与授权说明

- 全部 126 张遗物图标与美术均为**程序化生成的原创几何图案**，生成器随仓库发布：`python tools/gen_relic_art.py`（依赖 Pillow，可一键重新生成 `assets/relics/` 与预览拼图）。
- 音乐（`music/`）与字体（`fonts/`，含 SIL OFL 授权的思源黑体）为作者自有 / 已获授权素材。
- 界面为 LÖVE 绘制调用直绘，无第三方图集依赖。

## 致谢与灵感

玩法灵感来自《Balatro》（链式算分与构筑节奏）、《Slay the Spire》（遗物 / 商店骨架）与《Inscryption》（桌游气质）。本项目未使用上述作品的任何美术、音频或代码素材。

## 设计文档与开发日志

- 完整的系统设计、数值口径与模块地图见 [GDD_BlackJacky.md](GDD_BlackJacky.md)；
- 关键开发节点与技术复盘（坑与教训）见 [DEVLOG.md](DEVLOG.md)。

## License

[MIT](LICENSE)
