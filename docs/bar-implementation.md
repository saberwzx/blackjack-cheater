# 酒吧实现说明（Blackjack Cheater Bar）

范围：本文件记录 `src/bar_actions.lua` 的独立实现，以及配套的 `tools/bar_acceptance.lua`。
实现方式为「由核心在 return 前 `install(GS)` 覆盖全部 `bar*` 方法」，**不修改**
`src/game_state.lua`、`src/bar_mode.lua` 与任何 `ui/` 文件。
依据：GDD 酒吧章节（100 局 / 6 杯 / 5 口 / 5 局 buff / 宿醉 / 赠酒 / 结局）与 34 技能附录。

---

## 1. 交付文件

| 文件 | 说明 |
| --- | --- |
| `src/bar_actions.lua` | 酒吧全部真实机制（`install(GS)` 覆盖 14 个方法） |
| `tools/bar_acceptance.lua` | 内存文件系统上的独立验收（61 项） |
| `docs/bar-implementation.md` | 本文件 |

## 2. 安装与依赖

`src/game_state.lua:2811-2821` 已有可选扩展钩子，require 时自动安装：

```lua
pcall(function()
  local m = require('src.bar_actions')
  if m and m.install then m.install(GS) end
end)
```

- `install(GS)` 幂等（守卫 `GS.__barActionsV1`），重复调用无副作用，只覆盖方法。
- 依赖（只读）：`src.cocktails / src.bar_mode / src.bar_lines / src.deck_types /
  src.blackjack / src.champion / src.deck`。
- 随机统一走 `GS:self:rfloat()/rint()/rchance()/rpick()`，不新增 RNG。
- 共享状态全部写在既有字段：`st.bar`（`BarMode.newState()`）、`st.player / st.dealer`、
  `st.deck = st.barDeck`、`st.championCards`（`pick_from_champion` 用）。

覆盖的方法：

```
barStart  bar_begin  barBeginRound  bar_gift_pick  barDeal
barFindCupIndex  bar_drink  barAfterRound  barEnding
bar_ability  barApplyAbility  barPrepareSelection  bar_pick  bar_confirm
```

---

## 3. 核心集成点（3.1 / 3.2 均已由核心落地，见 §8）

### 3.1 `GS.action` 路由 `bar_pick` / `bar_confirm`

核心已按下面方式路由（`src/game_state.lua:2825-2828`）：

```lua
elseif name == 'bar_pick' then st.barPick = arg; return true   -- 占位
elseif name == 'bar_confirm' then return true                  -- 占位
```

请替换为：

```lua
elseif name == 'bar_pick' then return self:bar_pick(arg)
elseif name == 'bar_confirm' then return self:bar_confirm()
```

`GS.ALIASES` 已把 `barDrink -> bar_drink`、`barUseAbility -> bar_ability`，无需改动。
两个方法成功返回 `true`，失败返回 `false, code`（与其它 action 一致）。

### 3.2 `GS:dealerStep` 读取 `d.forcedStand`

`game_state.lua` 的 `dealerStep` 已读取 `d.forcedStand`（`game_state.lua:955-956`）。两个技能会设置它：
`dealer_stop`（封口，酒保本局停牌）与 `dealer_draw_2_stop`（先补 2 明牌再停）。
请在 `dealerStep` 的「`#hand>=HAND_MAX` 结算」之后、`BJ.dealerShouldHit` 之前插入：

```lua
if d.forcedStand then
  d.forcedStand = nil          -- 清除，避免污染后续局
  return self:settle()         -- 按现有收尾路径结算
end
```

（`d.forcedStand` 由 bar_actions 在技能生效的当前局设置；局结束由核心清除或保留给 UI 只读。）

### 3.3 UI 状态扩展

状态机新增一环：`player -> bar_pick -> player`（取消或确认后回到 `player`）。
UI 在 `st.state == 'bar_pick'` 时读取 `st.bar.pending` 渲染选择面板，动作：

| UI 动作 | action | arg |
| --- | --- | --- |
| 选择/切换一项 | `bar_pick` | 见 §6 |
| 确认 | `bar_confirm` | 无 |
| 取消（不消耗技能） | `bar_pick` | `{ cancel = true }` |
| 使用技能 | `bar_ability` | `{ id = cup.drink }` |

### 3.4 `docs/API.md` 错误码需补齐

`API.md` 现有错误码不含以下新码，建议登记：
`unknown_skill`、`ability_locked`、`ability_used`、`ability_failed`、
`no_hand`、`no_up`、`empty_deck`、`no_choice`、`no_card`。

---

## 4. 机制规则

- **100 局**：`b.round` 1→100。`barBeginRound` 在 `round>=100` 时先 `barEnding`；
  第 100 局结算后 `barAfterRound` 也返回 `bar_ending`。
- **6 杯 / 5 口**：`BarMode.MAX_CUPS=6`、`MOUTHS=5`；喝一口 `mouth+1` 并把该杯
  `buffLeft=5`（刷新不叠加）；满杯再赠返回 `cups_full`。
- **每局技能一次**：`bar_ability` 开头检查 `b.usedAbilityThisRound`，失败 `ability_used`；
  只有真正生效（即时执行成功，或两步确认成功）才置位并记 `abilitiesUsed[cup.drink]`；
  取消/失败不消耗。
- **5 局 buff**：`BarMode.tickBuffs` 每局末无条件 -1（不看胜负）；归零的杯进入当夜宿醉。
- **赠酒概率**：基础 `GIFT_BASE=0.01`；每胜 +`GIFT_STEP=0.005`（上限 1）；
  输一局与**成功赠出一杯**都重置回 0.01。保底轮 `1/20/40/60/80/100` 强制三选一，
  候选来自 `offered` 之外的未见酒（`pickGiftOptions` 用 `self:rpick`）。
- **宿醉仅显示**：`b.hangover=true`、`b.hangoverColor={r,g,b,1,2,3}`、`b.hangoverNames`；
  不改变任何计算（口数、手牌、概率）。
- **空栏立即失败**：任何时刻 `BarMode.totalRemaining<=0` 立刻 `barEnding`（ending=fail）。
- **结局优先**：`date`（恰好剩 1 口）> `fish`（满 6 杯且全有余量）> `buddies`（>0）> `fail`；
  失败文案「调酒栏空了——酒保把你请了出去。」
- **牌靴**：`BarMode.buildDeck()` = 10 组样牌 × 10 = 100 张；`barDeal` 在 `#drawPile<4`
  时整靴重灌。
- **实体守恒 / UID**：技能新增牌用 `DT.clone + is_synthetic=true + assignUid`；
  `barDeal` 在换新局前把**上一局双方手牌**回收到弃牌堆（这是对原实现丢牌的修复）；
  牌一律经 `pushHand / deck:toDiscard / deck:toRemoved / sinkBottom` 迁移，绝不凭空增删。
  12 张上限由 `GS.HAND_MAX` 与 `pushHand` 统一把关，技能额外做前置检查。

---

### 4.1 文案洗牌袋（200 通用 + 68 逐酒）

- `src/bar_lines.lua` 提供 `B.generic`（200 条互不重复的通用文案）、
  `B.byDrink`（34 种酒 × 2 条 = 68 条逐酒文案）、`B.endings`（4 条结局）与
  `B.shuffleBag(list, rng)`（Fisher-Yates，出袋用 `table.remove`，取空后重新装袋）。
- **两套独立洗牌袋**：每局开始由 `bar_actions.lua` 的 `barBeginRound` 调
  `drawLine(self, b, nil)` 从 `__generic` 袋取一条通用文案；赠酒（`bar_gift_pick`）与胜局
  （`barAfterRound`）调 `drawLine(self, b, cup)` 从该酒的逐酒袋取一条（袋键 = `cup.drink`）。
- 一个完整周期内 200 / 68 条各自不重复；通用袋与逐酒袋键不同、互不消耗。
- 画在 `b.lastLine` 上，即 `ui/screens/table.lua:417` 显示的那行文案。

---

## 5. 34 技能真实效果

| # | special | 酒 | 交互 | 效果 |
| --- | --- | --- | --- | --- |
| 1 | redraw_hand | mercury | instant | 玩家手牌全部弃掉，重抽同数量 |
| 2 | swap_hand_card | venus | two_step | 选一张手牌→从该牌型牌池选一张不同面替换 |
| 3 | peek_sink_pick | earth | checklist | 揭示牌堆顶 3 张，勾选任意张沉底 |
| 4 | burn_half | mars | instant | 洗牌后烧掉牌堆下半张数（进 removed） |
| 5 | duplicate_lowest | jupiter | instant | 复制手牌中点数最低的一张（合成牌） |
| 6 | dealer_stop | saturn | instant | 置 `d.forcedStand`，酒保本局停牌 |
| 7 | discard_highest | uranus | instant | 弃掉手牌中点数最高的一张 |
| 8 | swap_with_dealer | neptune | two_step | 选自己一张手牌↔选酒保一张明牌交换 |
| 9 | discard_random | pluto | instant | 随机弃掉一张手牌 |
| 10 | pick_from_champion | planetx | pick_champion | 从冠军池（`st.championCards`，缺省现生成 36）选一张入手 |
| 11 | take_dealer_highest_sink | ceres | instant | 抽走酒保最大明牌沉底 |
| 12 | give_lowest_to_dealer | eris | instant | 把手牌最低一张塞给酒保 |
| 13 | dealer_last_sink_draw | fool | instant | 酒保最后一张明牌沉底，再补 1 明牌 |
| 14 | dealer_extra_up | magician | instant | 酒保补 1 张明牌 |
| 15 | dealer_lowest_sink_draw | high_priestess | instant | 酒保最小明牌沉底，再补 1 明牌 |
| 16 | dealer_fill_to_2 | empress | instant | 补明牌至明牌数=2 |
| 17 | dealer_draw_1 | emperor | instant | 酒保补 1 张 |
| 18 | dealer_draw_2 | hierophant | instant | 酒保补 2 张 |
| 19 | dealer_copy_last | lovers | instant | 复制酒保最后一张明牌 |
| 20 | dealer_draw_2_stop | chariot | instant | 酒保补 2 张后置 `forcedStand` |
| 21 | deck_sort_asc | justice | instant | 牌堆按点数升序排序 |
| 22 | sink_top_5 | hermit | instant | 牌堆顶 5 张沉底 |
| 23 | deck_rebuild_shuffle | wheel | instant | 现有 drawPile 进弃牌堆，重灌整靴并洗牌 |
| 24 | dealer_draw_1_give_random | strength | instant | 酒保补 1 张，再随机把玩家一张手牌给酒保 |
| 25 | swap_dealer_lowest_with_draw | hanged | instant | 抽牌堆顶与酒保最小明牌互换（旧牌回牌堆顶） |
| 26 | dealer_draw_3 | death | instant | 酒保补 3 张 |
| 27 | deck_remove_random_10 | temperance | instant | 随机移除牌堆 10 张（进 removed） |
| 28 | dealer_draw_highest | devil | instant | 从牌堆取点数最大的一张给酒保 |
| 29 | dealer_draw_until_21 | tower | instant | 酒保补牌直到 ≥21 或到上限 |
| 30 | deck_insert_5_tens | star | instant | 随机位置插入 5 张合成 10 |
| 31 | dealer_fill_to_player_count | moon | instant | 补明牌至明牌数=玩家手牌数 |
| 32 | dealer_duplicate_ups | sun | instant | 复制酒保全部明牌 |
| 33 | deck_compress_top_half | judgement | instant | 牌堆按点数降序后只保留上半（值大者进 removed） |
| 34 | dealer_fill_to_3 | world | instant | 补明牌至明牌数=3 |

所有"补明牌"都尊重 12 张上限且带 `guard`，不会无限循环。

---

## 6. 精确选择结构（两步 / 清单 / 冠军）

`bar_ability({id=cup.drink})` 对四种选择技能只做「准备」，写入 `st.bar.pending` 并
`setState('bar_pick')`；其余 30 种同一调用内即时完成。

`st.bar.pending` 公共字段：

```lua
{
  special   = 'swap_hand_card'|'swap_with_dealer'|'peek_sink_pick'|'pick_from_champion',
  cupId     = <drink id>,
  interaction = 'two_step'|'checklist'|'pick_champion',
  step      = 1|2,
  handIndex = <第一步选中的手牌序号>,        -- 两步技能
  candidates= { ... },                      -- 见下
  choice    = <第二步/单项选择序号>,
  picks     = { [candidateIndex]=true },    -- 清单技能多选
}
```

- `swap_hand_card`：step1 候选 = 手牌 `{index,label,kind}`；
  选中后 step2 `candidates = {index, card, label, kind}`（该牌型牌池去掉同面）。
- `swap_with_dealer`：step1 同手牌；step2 `candidates = {index, dealerIndex(2..), card, label}`。
- `peek_sink_pick`：`candidates = {index, card, label}`（牌堆顶 ≤3 张，已 `revealed`）；
  `bar_pick` 对同一 index 反复调用即勾选/取消。
- `pick_from_champion`：`candidates = {index, card, label, group}`（`st.championCards`）。

`bar_pick(arg)` 接受：数字 `index` / `{ index = n }` / `{ uid = '<uid>' }` /
`{ cancel = true }`；清单技能用 index 切换勾选，两步技能第一次调用设 `handIndex` 并进入
step2，第二次设 `choice`。`bar_confirm()` 无参，执行并消费技能（`usedAbilityThisRound`、
`abilitiesUsed[cupId]`），随后 `refreshAll` 并回到 `player`。

---

## 7. 测试

```
python tools/run_lua.py tools/bar_acceptance.lua
```

当前结果：**bar_acceptance: 61 passed, 0 failed**（`python tools/check_lua.py` →
`65 files, 0 errors`）。

覆盖：34 技能各自关键可见效果；四种选择技能的完整两步/清单流程与取消不消耗；
费用（喝 1 口 + buff 5）；每局一次限制；未知技能 `unknown_skill`、未激活 `ability_locked`；
12 张上限（`duplicate_lowest / pick_from_champion`）；6 杯上限；保底第 1 局与第 20 局（概率 0 也触发）；
成功赠酒与失败都把概率重置 0.01；胜利 +0.005；宿醉仅显示；空栏立即 fail；
date/buddies/fish/fail 结局；第 100 局触发结局；两次全流程 drive（随机驱动到自然失败，
以及强制跑到第 100 局）均终止且 `deck:audit` 实体守恒。

---

## 8. 已知 / 剩余（交由核心与父代理）

1. **路由**：已由核心集成，`game_state.lua:2825-2828` 会调用 `self:bar_pick(arg)` /
   `self:bar_confirm()`（`self.bar_pick` 存在时）。
2. **`dealerStep`**：已由核心集成，`game_state.lua:955-956` 读取并清除 `d.forcedStand`。
3. **错误码**：`API.md` 需补齐 §3.4 的新码。
4. `src/bar_mode.lua` 的 `Bar.giftCandidates` 用 `_pickSeed` 而非 rng（本实现**未使用**它，
   改用 `GS:rpick`），属核心文件，未改。
5. 记忆/持久化：`barStart` 与核心一致只重置 `st.bar`；跨存档继续酒吧周目是否保留由核心决定。
