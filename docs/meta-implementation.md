# 元系统实现说明（教程 + 冠军牌组编辑器）

范围：本文件记录 `src/meta_actions.lua` 的独立实现，以及配套的 `tools/meta_acceptance.lua`。
实现方式为「由核心在 return 前 `install(GS)` 覆盖相关方法」，**不修改** `src/game_state.lua`、
`src/champion.lua`、`src/tutorial.lua` 与任何 UI 文件。

---

## 1. 集成点

`src/game_state.lua:2811-2821` 已有可选扩展钩子：

```lua
-- 可选扩展模块（由父代理委派的独立实现通过 install(GS) 覆盖对应方法）
pcall(function()
  local m = require('src.bar_actions')
  if m and m.install then m.install(GS) end
end)
pcall(function()
  local m = require('src.meta_actions')
  if m and m.install then m.install(GS) end
end)

return GS
```

- `install(GS)` 幂等（守卫 `GS.__metaActionsV1`），重复调用无副作用。
- 只覆盖方法，不新增全局状态；教程运行器放在 `st.tutorialRun`，UI 投影放在 `st.tutorial`，
  编辑器状态放在 `st.deckEditor`。
- 测试可直接 `require('src.game_state')`；模块会在 require 时自动安装。

## 2. 交付文件

| 文件 | 说明 |
| --- | --- |
| `src/meta_actions.lua` | 教程运行器 + 冠军编辑器实现（`install(GS)`） |
| `tools/meta_acceptance.lua` | 内存文件系统上的独立验收（21 项） |
| `docs/meta-implementation.md` | 本文件 |

---

## 3. 教程运行器

### 3.1 修复的核心缺陷

原 `GS:start_tutorial` 在 `self:resetState()` **之前**抓取了 `local st = self.state`；而
`resetState()` 会**整表替换** `self.state`（`src/game_state.lua:81`），因此旧 `st` 是悬空引用：
写入的 `tutorial`、`chips` 全部落空，教程不可推进。本实现改为 reset 之后再取 `self.state`，
所有写入都落在活状态表上。

同时核心把 `st.tutorial` 当作 Tutorial 实例使用，与 UI 期望的**数据投影**不一致。
本实现拆成两层：

- `st.tutorialRun`：内部 `Tutorial` 实例（`src/tutorial.lua`，只读复用）；
- `st.tutorial`：UI 投影，字段与 `docs/API.md` §4.11、`ui/demo.lua:224-244` 完全一致：

```lua
st.tutorial = {
  active = true, step = 1, total = 14,
  phase = { index = 1, id = "welcome", title = "...", text = "...",
            requireAction = nil, actionHint = "" },
  done = false,
  lastRejected = nil, -- 被拒时的 { id, need, hint }（超集，UI 可忽略）
}
```

`ui/ui.lua:270/339/468` 的 `st.tutorial.active and not st.tutorial.done` 门控因此可直接工作。

### 3.2 14 步与 6 个动作门

教程强制**基础模式**（无庄家职业），起始筹码 `$2500`（`Tutorial.START_CHIPS`），
第 10 步前不发放任何遗物。门定义来自 `src/tutorial.lua` 的 `T.PHASES`：

| # | id | 类型 | 动作门 | 通过条件 |
| --- | --- | --- | --- | --- |
| 1 | welcome | 纯文字 | — | 点继续 |
| 2 | winloss | 纯文字 | — | 点继续 |
| 3 | bet | 动作 | `bet` | `bet_confirm` 成功（真实下注） |
| 4 | play_round | 动作 | `round_end` | `finalizeRound` 真正结算一局 |
| 5 | hand_limit | 纯文字 | — | 点继续 |
| 6 | open_deck | 动作 | `open_deck` | `action('open_deck')` 且 `st.deckOpen==true` |
| 7 | deck_system | 纯文字 | — | 点继续 |
| 8 | close_deck | 动作 | `close_deck` | `action('close_deck')` 且牌堆已收起 |
| 9 | relic_intro | 纯文字 | — | 点继续 |
| 10 | pick_relic | 动作 | `pick_relic` | `pick_relic` 成功（真实选一遗物） |
| 11 | activate_relic | 动作 | `activate_relic` | `use_relic` / `toggle_relic` 成功 |
| 12 | shop_stage | 纯文字 | — | 点继续 |
| 13 | cheat_accuse | 纯文字 | — | 点继续 |
| 14 | advanced | 纯文字 | — | 点继续 → 完成 |

### 3.3 反「跨层快捷键」

- `tutorial_advance` 在动作门上**恒**返回 `false, 'tutorial_action_required'`，
  并写入 `st.tutorial.lastRejected`（含 `actionHint`）。不能用「继续」跳过。
- `ESC / close_top` 不会替玩家完成牌堆门（不把 `close_top` 映射到 `close_deck`）。
- 方法级包装（`bet_confirm / finalizeRound / pick_relic / use_relic / toggle_relic`）
  与动作级包装（`open_deck / close_deck`，因核心走直通分支、不过 `tutorialNotify`）
  保证「真实动作」是唯一放行途径。
- `tutorialNotify` 被覆盖为**诊断空操作**（只记 `st.lastAction`），避免核心的收尾通知
  与包装层重复推进。

### 3.4 自然衔接与不卡死

- `AUTO_GATES = { round_end, open_deck }`：若进入某步时该动作其实已由当前状态满足
  （例如下注即自然 21 直接结算，`round_end` 紧随 `bet`；或进入 open_deck 步骤前牌堆已打开），
  在同一次事件里级联放行，避免教程卡在已完成的动作上。
- 第 10 步「选遗物」：在下注阶段弹出确定性三选一
  `M.TUTORIAL_RELIC_IDS = { 'peek_1', 'burn_1', 'discard_rinse' }`（全部为 active 消耗品），
  由包裹后的 `beginBet` 在自然时机弹出（结算后点「继续」→ 进入下一轮下注）。
  若当前不在可弹出时机则挂起 `st.tutorialPendingRelic`，绝不打断 dealer/result 流程。
- 教程**不会**伪造通关：完成 14 步后 `st.progress.hardCleared` 与
  `self.progress.meta.hardCleared` 仍为 `false`，冠军编辑器仍为 `locked`。

---

## 4. 冠军牌组编辑器

### 4.1 牌池：附录 C4 分项 = 345（不是正文合计 290）

GDD 附录 C4（`GDD_BlackjackCheater.md:1609-1624`）的**分项**为：

| 分组 | 牌面数 | 分组 | 牌面数 |
| --- | --- | --- | --- |
| 固有牌堆 basic | 52 | 黑洞 blackhole | 52 |
| 小数牌组 decimal | 44 | 牢笼 cage | 52 |
| 负整数牌组 negative | 40 | 筹码 chip | 52 |
| 倍率牌组 multiplier | 40 | 六面骰子 dice6 | 1 |
| 67 卡组 s67 | 8 | 二十面骰子 dice20 | 1 |
| RPS 牌组 rps | 3 | | |

`52+44+40+40+8+3+52+52+52+1+1 = **345**`。GDD 正文（:125、:163）与 C4 表头/合计（:1609、:1624）
写的是 290，与其分项自相矛盾。`docs/SPEC-DECISIONS.md:12` 已裁定按分项构造：

> 冠军牌池按附录 C4 逐项牌面构造：52+44+40+40+8+3+52+52+52+1+1=345。文档写的合计 290 与其分项不一致，采用可核对的分项定义。

本实现直接复用 `DeckTypes.championGroups()/championPool()`（`src/deck_types.lua:196/212`）的
11 组 345 张，不另做计数近似；`tools/meta_acceptance.lua` 逐组断言 52/44/40/40/8/3/52/52/52/1/1
且合计 345。

### 4.2 其它不变式

- 解锁：`hardCleared == true`（同时接受 `self.progress.meta.hardCleared` 与
  `st.progress.hardCleared`，兼容 `main.lua:137-140` 的 smoke 解锁路径）。
  未解锁时 `open_deck_editor` 返回 `false, 'locked'`。
- 容量恰 36（`Champion.SIZE`）；扩容 36/72/108 由 `Champion.expand` 提供；`$21` 由
  `Champion.price()` 提供。
- 保存必须**恰 36 张**且逐张经白名单校验（`src/persist.lua` 的 `CARD_FIELDS` 16 项），
  否则 `champion_size`；含白名单外字段（例如 `uid`）则 `invalid_arg`。
- 可重复加载/保存：保存后关再开，编辑器会预选已保存的 36 张并允许再次修改保存。
  预选优先用内存中的 `st.championCards`（36 张时），否则用 `persist:readCollection()`；
  按稳定签名（`rank/suit/kind` 及各 flag 字段）逐张匹配到 345 池的牌面。

### 4.3 `st.deckEditor`（UI 契约）

`ui/ui.lua:49` 将 `st.state == 'deckEditor'` 映射为**全屏** screen
`'deckEditor'`（即 UI 侧文件应为 `ui/screens/deckEditor.lua`）。ESC（`ui/ui.lua:415`）
会 `action('close_deck_editor')`。编辑器期间 `ui/ui.lua:477` 会屏蔽全局 I/D 面板。

```lua
st.deckEditor = {
  pool          = { { group = "basic", groupName = "固有牌堆", card = {...} }, ... }, -- 345
  groups        = { { key = "basic", name = "固有牌堆", count = 52 }, ... },         -- 11
  selected      = { [faceIndex] = true, ... }, -- 以 1..345 牌面序号为键
  selectedFaces = { 1, 2, ... },               -- 升序数组（UI 直接画勾选）
  selectedCount = 36,
  chosen        = { cloned card, ... },        -- 已按牌池顺序克隆，可直接持久化
  max           = 36,
  unlocked      = true,
  filter        = "all",             -- 'all' 或某个 group key
  saved         = <readCollection()>,
  savedCards    = {...}, savedCount = 36,
  loadedFromSave = true,
  preselected   = 36,
  dirty         = false,
  message       = "",
}
```

`champion_toggle` 的 `index` 始终是**全局池序号 1..345**（与当前 `filter` 无关）。
`u`i/demo.lua:120-136` 的 `{pool,selected,max,unlocked,filter,scroll}` 是子集，字段兼容。

### 4.4 动作

| 动作 | 参数 | 结果 |
| --- | --- | --- |
| `open_deck_editor` | — | 解锁则进入 `deckEditor` 并预选；否则 `locked` |
| `close_deck_editor` | — | 回到 `title`，清空 `st.deckEditor` |
| `champion_toggle` | face 1..345 | 切换；超 36 返回 `champion_full` |
| `champion_clear` | — | 清空选择 |
| `champion_filter` | group key 或 `'all'` | 非法 key 返回 `invalid_arg` |
| `champion_save` | — | 恰 36 且校验通过则写 `saves21/collection.lua` 并上架 |

### 4.5 错误码

沿用 `docs/API.md` §7：`locked`、`champion_size`、`tutorial_action_required`、
`invalid_arg`、`action_unavailable`。新增两个：

- `champion_full`：`champion_toggle` 试图超过 36 张；
- `save_failed`：持久化不可用或写入失败。

---

## 5. 验收

运行（在 `D:/dsh/Products/BlackjackCheater`，无系统 Lua，用自带 LuaJIT 运行器）：

```
python tools/run_lua.py tools/meta_acceptance.lua
```

结果：**PASS=21 FAIL=0**。覆盖：

- C4 逐组 345 与合计；价格 21、恰 36、扩容 36/72/108；
- 教程起始落在活状态、UI 投影形状、动作门拒绝「继续/ESC」捷径；
  下注 / 真实结算一局 / 开牌堆 / 关牌堆 / 选遗物 / 激活遗物 六个门逐一走通；
- 完整 14 步完成，且不伪造 `hardCleared`、不解锁编辑器；
- 别名 `placeBet` 仍经过门；`install` 幂等；
- 编辑器锁定/两种解锁路径、345 池 UI 形状、36 上限与清空、
  恰 36 保存 + 白名单 + 篡改字段拒绝、重复加载/预选/再保存、
  由内存 `championCards` 预选、filter 校验；
- 所有写入只落在注入的内存文件系统（`saves21/` 前缀），不污染正式存档。

回归：`tools/acceptance.lua`(18/18)、`tools/flow_acceptance.lua`(18/18)、
`tools/probability_acceptance.lua`(27/27) 在安装本模块后仍全绿。

---

## 6. 未改动的文件

`src/game_state.lua`、`src/champion.lua`、`src/tutorial.lua`、`src/deck_types.lua`、
`src/persist.lua`、`ui/*` 均为只读复用。若后续核心改写方法签名，本模块只依赖：
`resetState/applyStage/beginBet/setState/msg/fail/flush/action/ALIASES/finalizeRound/persist/progress`
与 `st.{state,chips,relics,deckOpen,result,progress,flags,championCards,relicSelect}`。
