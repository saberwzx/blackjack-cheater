# 整局压力验收结果（stress_acceptance.lua）

## 1. 目的与定位

本文件记录 `tools/stress_acceptance.lua` 的覆盖范围、每步不变量与真实运行结果。

它回答的问题是：**用游戏真实的公开动作，把整局从开局随机游走驱动到合法终局，在每一步是否仍保持核心不变量**（牌实体守恒 / 筹码有限 / 手牌上限 / 结算无被吞错误 / 只读情报不污染 RNG / 进度只在合法事件写）。

它**不是**「139 个遗物 + 职阶 + 酒吧效果全部正确」的证明——见第 7 节诚实边界。

## 2. 运行方式

```
cd D:/dsh/Products/BlackjackCheater
python tools/run_lua.py tools/stress_acceptance.lua

# 用环境变量缩短（默认 normal=20 / hard=20 / bar=5）：
$env:STRESS_NORMAL='2'; $env:STRESS_HARD='2'; $env:STRESS_BAR='1'
python tools/run_lua.py tools/stress_acceptance.lua

# 调试开关
$env:STRESS_TRACE='1'    # 每步打印 TRACE <mode> st=.. round=.. hand=../.. draw=.. disc=.. rem=.. inzone=.. exp=..
$env:STRESS_PROBE='1'    # 猴补 Deck.toDiscard：当被丢弃的牌当前正在某方手牌时打印 HAND->DISCARD + traceback
$env:STRESS_LEDGER='1'   # 牌账本溯源：失败时打印 FOREIGN / UNCOUNTED 牌、initialTotal / syntheticCreated / synthPhysical
# 单 seed 回放（uid-free cardfaces，不含全局 uid，稳定可复现）：
$env:STRESS_REPLAY='2111'; $env:STRESS_REPLAY_MODE='hard'; $env:STRESS_REPLAY_STEPS='200'
python tools/run_lua.py tools/stress_acceptance.lua
```

全部走 `src.game` 最终生产链（`src/game_state.lua` 底部真实 require + install bar/relic/class/meta）。测试只注入 memory fs（`{read,write,mkdir,getInfo}`）、spy persist 与可种子的可调用 RNG，**不写正式 saves21**。

## 3. 覆盖矩阵

| 维度 | 覆盖 |
| --- | --- |
| 模式 | normal / hard（各 `STRESS_NORMAL/HARD` 个 seed）/ bar（`STRESS_BAR` 个 seed） |
| seed | 由 BASE（normal 1000 / hard 2000 / bar 3000）+ i\*37 派生；同 seed 可复现 |
| 流程状态 | relic_select → bet → player/dealer → result →（shop / stageClear / classSelect / classOffer / victory / forceExit）；bar：bar_brief → bar_gift → player → bar_next → bar_ending → title |
| 动作 | pick_relic, bet_preset/…/bet_confirm/toggle_bust_bet, hit, stand, double, surrender, accuse, buy_relic, buy_deck, reroll, leave_shop, choose_class, take_class_offer, skip_class_offer, bar_begin, bar_gift_pick, bar_drink, bar_ability, continue |
| 商店 | 买到无力再买为止（≤8 次），20% 概率重掷一次 |
| 酒吧 | 每局 ≤35% 概率喝 1 口；≤45% 概率使用 **无需目标的自包含技能**（9 个：redraw_hand / peek_sink_pick / burn_half / duplicate_lowest / dealer_stop / discard_highest / discard_random / take_dealer_highest_sink / give_lowest_to_dealer） |
| 终局 | 允许失败（forceExit 合法）；每 seed 到终局后 `continue` 回 title，再用 seed+7777 重开验证隔离 |

**策略随机数独立**：`drng = makeRng(seed\*7919+13)` 只做决策，绝不消耗游戏 `rng`（每一步断言只读情报前后 `rng.count` 不变）。

## 4. 每步不变量

1. `st.deck:audit(external)` 通过：**无重复 UID / 无缺 UID / total == expected**（expected = `initialTotal + syntheticCreated`）。
   `external` = 玩家手牌 + 庄家手牌 + **合法跨小局寄存区**（`st.cardPack` / `st.player.cardPack` / `st.salvageCard`）；寄存牌若仍在牌堆三区则跳过，避免重复计数。失败文本会标注真实 `holding[hand=n,cardPack=n,salvageCard=n]` 与消失牌来源。
2. 筹码为有限数（非 NaN / ±Inf）。
3. 玩家 / 庄家手牌 `<= 12`（`GS.HAND_MAX`）。
4. **`st.result.errors` 为空**——`src/scoring.lua` 用 pcall 包裹遗物/处理器 fx，失败会存入 `result.errors`；不检查会「假通过」。
5. 只读情报（`getView` / `audit`）不得消耗游戏 RNG。
6. 进度写合法性：bar 模式 **0 次** persist 写；normal/hard 恰好 **1 次** `writeProgress`，且只允许 `pre ∈ {stageClear, result}` → `post ∈ {victory, forceExit}`；`writeCollection` 全程 0 次。
7. 动作返回 `false` 立刻带 `[seed/mode/state/lastAction]` 上下文报错，**不做无条件回退继续**。

## 5. 最终结果（core 修复后，2026-10-09）

```
Stress acceptance: PASS=50 FAIL=0
```

| 分组 | PASS | FAIL |
| --- | --- | --- |
| 5 个 sanity 自检 | 5 | 0 |
| normal 20 seeds | 20 | 0 |
| hard 20 seeds | 20 | 0 |
| bar 5 seeds | 5 | 0 |

修复过程（同一断言集，未削弱）：

| 阶段 | 结果 | 阻塞缺陷 |
| --- | --- | --- |
| 初跑 | PASS=9 / FAIL=39 | `total < expected`，整局丢牌 |
| 回收手牌修复后 | PASS=47 / FAIL=3 | hard 2111/2148/2629 `total = expected + 1` |
| 合成牌账本修复后 | **PASS=50 / FAIL=0** | — |

## 6. 定位并已修复的核心缺陷

修复均落在 `src/` 核心（本测试文件只做检测，未改游戏逻辑）。以下行号为修复后现状。

### 6.1 正常/困难换靴不回收上一局手牌（丢牌）

- 旧现象：normal/hard 每个 `result → continue` 泄漏 4~8 张真牌，`total < expected` 且 `dup=0 missing=0`，消失牌全部来自双方手牌。
- 根因：`GS:beginBet` 直接整体替换 player/dealer，未把上一局手牌放回牌堆；bar 有显式回收故不受影响。
- 修复（现状）：
  - `src/game_state.lua:367 GS:recycleHands(targetDeck)`：把双方 `hand` 中除保留牌（`st.cardPack`）外的牌 `toDiscard` 回目标牌堆。
  - `src/game_state.lua:389 GS:beginBet()` 在第 391 行、替换 player/dealer **之前** 调用 `self:recycleHands()`。
  - `src/game_state.lua:496 GS:buildShoe()` 第 500 行先 `self:recycleHands(st.deck)` 再重建牌堆；`src/game_state.lua:2536` bar 换靴同款。

### 6.2 凭空多造的牌未记账（`total = expected + 1`）

- 现象：hard seed 2111/2148/2629 在 `state=bet lastAction=bet_confirm` 报
  `deck_audit_failed total=expected+1 dup=0 missing=0 holding[hand=4] vanished[]`。
- 溯源证据（`STRESS_LEDGER=1` 回放 2111）：
  ```
  UNCOUNTED@dhand[1] 10H uid=273 synth=nil counted=nil firstD=4 synthD=-1
  ledger: curDeck=4 initialTotal=110 syntheticCreated=0 syntheticRecycled=0 synthPhysical=0
  ```
  即庄家手牌里有一张**有 UID、但既非 `addCards` 计入 `initialTotal`、也未计入 `syntheticCreated`** 的实体牌——是当场凭空的补牌。
- 根因：庄家出千 `GS:executeCheatDeal` 的补牌与克隆补牌**漏标 `is_synthetic = true`**，而 `Deck:assignUid`（`src/deck.lua:38-41`）只在 `is_synthetic` 时累加 `syntheticCreated`；同一文件其余同类补牌（`dealer_magnet` / 千招 B/C/D / 遗物补牌等）都标了合成，唯独这两处漏标。酒吧自包含技能的克隆补牌同样漏标。
- 修复（现状，全部补 `is_synthetic = true`；克隆牌还需 `_synthCounted = nil`，因为 `DeckTypes.clone` 不清该字段）：
  - 出千 A 补牌：`src/game_state.lua:857-858`
  - 出千 E 镜像克隆：`src/game_state.lua:871-872`
  - 酒吧克隆技能：`src/game_state.lua:2681`（复制手牌）、`2696`（池中补牌）、`2721`（复制庄家牌）、`2758`（复制庄家明牌）

### 6.3 说明

两条缺陷互相独立：6.1 是**丢牌**（total < expected），6.2 是**多造牌未记账**（total > expected）。审计本身正确，**未为通过而放宽任何断言**；`external` 仅按现网语义纳入真实持有的 `cardPack` / `salvageCard` 寄存牌。

## 7. sanity 自检（证明检查有牙齿）

- `deck audit detects an injected duplicate UID`：`assignUid` 后放入 drawPile 并同时作为 external 传入 → audit 必须报 `duplicates`。
- `decision RNG is independent from game RNG`：决策 RNG 跑 100 次后游戏 `rng.count` 不变。
- `seeded runs reproduce the identical opening deal`：同 seed 两次开局手牌字符串完全一致。
- `seed replay is deterministic and uid-free`：同 seed 回放两次逐步一致，且记录内不含原始 uid。
- `holding zones (cardPack/salvageCard) count as audit external`：cardPack 移出牌堆后仍计入 external 且审计通过；salvageCard 仍留在弃牌堆时不得重复计入。

## 8. 诚实边界（本测试**不**覆盖）

- 策略是合法动作随机游走，不追求最优；一局可能提前 forceExit。
- 不覆盖 **forge**（需 10000 筹码）、需要目标的酒吧技能（`swap_hand_card` / `swap_with_dealer` / `pick_from_champion`，已有单项测试）、冠军编辑器 / 教程 UI（由 `tools/meta_acceptance.lua` 覆盖）。
- 不证明 139 个遗物 / 职阶 / 34 种酒的全部效果正确；只证明这些路径在随机长局中不破坏上述不变量。
- 酒吧的 34 项效果由既有单项测试覆盖，本压力测试只做「定时喝 + 9 个自包含技能」的烟测。
- 合成牌账本缺陷通过 `STRESS_LEDGER` 溯源定位；默认关闭，开启时也不改变游戏计数（只包装 `addCards` / `assignUid`）。

## 9. 回归基线（与本测试同源）

| 脚本 | 结果 |
| --- | --- |
| tools/acceptance.lua | 18/18 |
| tools/flow_acceptance.lua | 18/18 |
| tools/probability_acceptance.lua | 27/27 |
| tools/meta_acceptance.lua | 21/21 |

（以上为历史基线；最终以 core 修复后的联合重跑为准。）
