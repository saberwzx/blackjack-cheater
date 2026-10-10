# Blackjack Cheater 只读整合审计（core ↔ UI）

范围：核查核心 `src` 的事件 emit、`GS.action` 派发、`GS:can/getView`、UI
`ui/ui.lua` 的 fx 消费与状态映射、`ui/screens/*` 的动作名/参数形状和字段读取。
方法：仅静态阅读源码 + 交叉引用，**未修改任何代码、未运行 LÖVE**。
审计期间 `ui/screens/bar.lua` 由 UI 代理落盘，故对它的判断仅限静态检查，可能随其后续编辑变化。

---

## 1. 会导致「游戏不能用」的项

### 1.1 [已缓解] `ui/screens/bar.lua` 缺失会让所有 bar_* 状态硬崩
- 证据：`ui/ui.lua:36-44` 的 `screen()` 直接 `require('ui.screens.'..name)`，**无 pcall**；
  `ui/ui.lua:46-52` 把 `bar_brief/bar_gift/bar_drink/bar_ending/bar_alcpick` 映射到 `'bar'`，
  `ui.lua:53-57` 把 `bar_pick` 映射到 `'bar'`。另 `ui/screens/table.lua:722` 在
  `st.mode=='bar'` 时无条件 `require('ui.screens.bar').tableOverlay(g,st)`，`:775` 调 `toggleBrief()`。
- 影响：bar.lua 落地前，进入酒吧模式即 require 报错，整模式不可用。
- 现状：`ui/screens/bar.lua`（479 行）已落盘，导出
  `Bar.draw / Bar.pickOverlay / Bar.tableOverlay / Bar.toggleBrief / Bar.isBriefOpen / Bar.setBriefPage / Bar.onBriefClick / Bar.onClick / Bar.onKey / Bar.onBackdrop`，
  且已调用 `bar_begin / bar_gift_pick / bar_pick / bar_confirm`。此前的覆盖缺口现已闭合；
  由于 UI 代理仍在编辑，此项保留为**回归观察点**而非最终结论。

## 2. 静默失败 / 死回退

### 2.1 `open_mode_select` 未注册，但只是死代码
- 证据：`ui/screens/modeSelect.lua:97` 调 `g:action('open_mode_select')`；`GS:action` 派发表
  `src/game_state.lua:2765-2831` 不含该名 → 恒返回 `false, 'unknown_action'`。
- 可达性：同一分支 `game_state.lua:2777` 的 `select_mode` 以 `return self:start(...)` 直接返回，
  成功即 `true`；只有 `select_mode` 失败才会走到 line 96-97 的回退。因此目前无害，
  但若核心开始合法拒绝 `select_mode`，UI 无法补救（回退动作不存在）。

## 3. 已验证安全（无需处理）

| 项 | 证据 |
| --- | --- |
| `GS:action` 成功返回 `true` | `src/game_state.lua:2835` `return true`，UI 的 `ok,err` 判断成立 |
| 无 missing-method 崩溃 | 派发表调用的 51 个方法全部有定义（game_state 146 + bar_actions 15 + meta_actions 1 + class_actions 18） |
| UI 静态动作名 | 40 个动作名除 `open_mode_select` 外全部在派发表中 |
| 状态覆盖 | `src` 所有 `setState` 状态都被 `ui/ui.lua:46-52` FULL 覆盖；唯一 `result_pending` 在 `game_state.lua:1157→1275` 同一次同步调用内完成，无绘制帧 |
| bar 字段一致 | `src/bar_actions.lua:82-97` `sync()` 与 `ui/screens/table.lua` 读取的 `cup.mouth/buffLeft/ability.name/desc` 一致；`barBeginRound` 在 `setState('bar_gift')` 前先设 `b.giftOptions`（`bar_actions.lua:745-748`） |
| 暗牌不泄漏 | `ui/screens/table.lua` `hiddenIndex` = 庄家明牌 index 1，总点只累加 `i=2..` 并显 `'?'` |
| ESC 路径 | `ui/ui.lua:439` 对 `bar_brief/bar_gift` 走 `close_top` 无分支=无操作不崩溃；`bar_ending` → `continue()` → title（`game_state.lua:2858,1330-1332`） |
| BGM / 面板 | `ui/ui.lua:88-96` 按 `st.mode`/状态前缀判定 bar；bar 内屏蔽 I/D 面板（`ui/ui.lua:500-511`） |
| tell 事件 | 核心现已 `emitTell`（`src/game_state.lua:127-132`，调用点 147/614/820/834/836/875/907/923），`ui/ui.lua:157-166` 已消费；`_distractorShown` 每局重置（`game_state.lua:573`） |

## 4. 已知、不重复计为本次新发现

- `src/relic_actions.lua` 不存在；`src/class_actions.lua` 的 `install` 未被
  `game_state.lua:2909-2917` 挂钩（只 pcall `bar_actions` + `meta_actions`），
  术/职阶 override 不可达 —— 已记录于 `docs/core-gaps.md:52`。
- `d.forcedStand` 已由 `game_state.lua:955-956` 读取并清除。
- `bar_pick / bar_confirm` 路由已落地（`game_state.lua:2825-2828`）。
- `bar / meta / class` 等模块仍在持续新增，不属于稳定结论。

## 5. 未覆盖 / 待复核（诚实标注）

- 本次审计是静态的：未运行 LÖVE，故无法验证 `ui/screens/bar.lua` 的实际渲染、
  点击热区与 `Bar.onBackdrop` 行为。
- 未逐一核对每个 UI 按钮的 `g:action` 返回值处理（`ui/screens/shop.lua` 与
  `table.lua` 已确认会 toast；其余屏幕只做了动作名存在性检查）。
- `GS:getView()` 直接 `return self.state`（`game_state.lua:2903`），返回的是活引用而非浅拷贝；
  当前 UI 只读，但文档若承诺只读视图，此处与实现有措辞差异。
- `GS:can(action)` 只处理 `hit/stand/double/accuse/bet_confirm`，其余一律 `return true`；
  UI 以 `can()` 做按钮启用态的地方可能显示为可用但实际被 action 拒绝（有 toast，不算静默）。
