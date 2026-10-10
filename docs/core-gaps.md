# Blackjack Cheater 核心实现缺口与偏差（core-gaps）

本文件记录核心层（src/ 与 tests/）相对 GDD 的**真实缺口、近似实现与已知偏差**，供评审与 UI 集成对齐。
原则：宁可写清缺口，也不以空壳冒充实现；未复刻原版（从未见过原版源码，不宣称复刻其 646 项测试）。

## 1. 规格数字本身不一致（已按可核对的分项实现）

- **冠军牌池**：GDD 正文宣称 290，附录 C4 分项相加 = 345（52+44+40+40+8+3+52+52+52+1+1）。
  实现取**分项相加 345**：`src/deck_types.lua` 的 `championPoolSize()` 返回 345，`deck_types.championGroupCounts()` 可逐组核对。
- **教程步骤**：GDD 表格第 [10]/[11] 项键名重复（实际会少走 2 步）。本实现修正为**真正的 14 步**（`src/tutorial.lua` `PHASES`，id 无重复，tests 断言 14）。
- **遗物触发计数**：`src/relics.lua` 的 `R.TRIGGER_COUNTS` 是 GDD 附录的触发分类统计；实际实现为 39 件走 `fx`（数值结算）、100 件走 `special` 分发。若 UI 需要按触发类型展示，请以每条的 `trigger` 字段为准，而非 TRIGGER_COUNTS 的汇总。

## 2. 近似 / 不进入随机池的遗物

- 139 件遗物全部有定义；其中 4 件标记 `approx=true` 且列入 `POOL_EXCLUDED`：
  `deck_weight_low`、`deck_weight_high`、`exclusive_supreme`、`seclusion`。
  它们**不进商店、不进开局三选一**，当前也没有获取途径，效果为最小占位（仅标记 excluded），不参与对局计算。
- 其余 135 件：`relics.lua` 共 139 条 = 39 件 `fx`（直接在算分链上生效）+ 100 件 `special`（其中 4 件即上面的 excluded 占位）。
  独立审计现已完成，发现的约 45 件行为缺陷已通过生产覆盖模块修复；逐项状态见 `relic-audit.md`。
  **注册/分发路径存在不等于逐条独立断言**：55 件具有独立行为或数值断言，其余通过读码与完整生产链核验。
  39 件纯算分 fx 的正反例及组合规则由 `tools/scoring_acceptance.lua` 覆盖，75 项通过。

## 3. 情报（src/shoe_info.lua）的诚实边界

- **标准桶精确枚举 + 明确数值牌精确参与**：A / 2..9 / 10（J/Q/K 并入 10）按桶枚举。
- `SI.bustOdds(total, cards)`（下一张爆率）：带明确 `value` 的牌（含非标准牌但 `rank` 为数字者）**按其精确点数参与枚举**；
  只有不定值牌（骰子 / RPS / 非数字 rank）无法估值，返回 `nil` + `reason='unknown_cards'` + `coverageGap`。
- `SI.dealerBustOdds(upcards, difficulty, opts)`（庄家爆率递归）：已亮的自定义值明牌/暗牌**精确并入基准点数**；
  待抽牌靴中带明确 `value` 的牌**不参与递归分支**，但计入 `coverageGap`，仍返回数字（非致命）；
  只有不定值牌（或不确定的明牌）才返回 `nil` + `reason`（`unknown_cards` / `unknown_upcard` / `no_standard_cards`）。
  UI 收到 `nil` 时应显示 `--`，不得编造数字。
- 庄家爆率递归有界：深度 ≤10、节点预算 150000、追加上限 5 张；超出预算返回 `nil` + `budget_exceeded`，不降级为假精度。
- 未知暗牌按“剩余牌靴的数值多重集”枚举，不假设其具体身份；已摊开暗牌按已知牌扣减。
- **爆注（边注）赔率**：`GS:lockBustBetOdds()` 只用真实爆率，`odds = clamp(0.9 / p, 1.2, 8.0)`；
  当情报不可用（未知/预算失败）时 `prob=nil`、`odds=8.0`、保留 `reason`，绝不使用硬编码赌场 fallback。
  `p=0` 视为已知零爆率（odds=8），`p=1` 夹到最小 1.2。

## 4. 明确属于表现层、不由核心渲染

- 出千的 5 种真痕迹与 5 种干扰项：核心发 `kind='tell'` 事件（`tellKind='A'..'E'` 为真痕迹、`'dA'..'dE'` 为干扰项，字段 `uid`/`slot`/`card`；E 另发玩家 `link=true` 关联，C 带 `oldRank`），实际描边/抖动/脉冲由 UI 呈现。
- 宿醉：核心只计算“到期酒水的颜色算术平均”供滤镜使用，**不改动任何对局数值**（符合 GDD）。
- 震屏、音效、动画：核心通过 `drainFx()` / `drainLog()` 暴露事件，UI 负责播放。

## 5. 委派模块与当前集成状态

- 生产版 `src/game_state.lua` 底部已改为**普通 require 顺序安装**（无 `pcall`、无静默降级）：
  `bar_actions` → `relic_actions` → `class_actions` → `meta_actions`，四者均以 `install(GS)` 通过 `for k,v in pairs(...) do GS[k]=v end` 覆盖对应方法。
- `src/bar_actions.lua` **已交付并集成**：覆盖全部 `bar*` 方法；`GS.action` 已正确路由 `bar_pick` / `bar_confirm`。
- `src/relic_actions.lua`（父代理委派）**已交付并集成**：补全遗物 hook / toggle / use / scoreHandlers / `openShopEarly` / `leave_shop` / `finalizeRound`（`O('finalizeRound', ...)` 包装原函数，基础 21 加速仍生效）/ `card_pack` 等 override。
- `src/class_actions.lua`（父代理委派）**已交付并集成**：术阶主动执行路径可达。
- `src/meta_actions.lua`（父代理委派）**已交付并集成**：覆盖 `start_tutorial` / `tutorial_*` / `champion_*` / `open_deck_editor`；
  冠军编辑器使用 `DT.championPool()`（345 全池）；教程 `start_tutorial` 的旧 `st` 问题由该模块处理，细节见 `docs/meta-implementation.md`。
- 四个模块的 acceptance 套件（`tools/bar_acceptance.lua` / `relic_acceptance.lua` / `class_acceptance.lua` / `meta_acceptance.lua`）
  与父代理 `tools/verify.py` 均已通过。

## 6. 其他已知降级

- **57 张填充（67 组合）**：每填充位消耗牌靴一张；牌靴抽空时立即停止，**不凭空造牌**（守恒优先），
  因此极端牌靴枯竭时可能填不满 12 张；可通过弃牌堆洗回继续供牌。
- **酒吧文案**：`src/bar_lines.lua` 提供通用 200 条 + 每款酒 2 条（共 68 条）加结局文案，非 GDD 全文。
- **存档**：`src/persist.lua` 为纯 Lua 序列化，`loadstring` 在空环境沙箱执行；宿主若禁用 `loadstring`，
  读取会静默降级为默认值；写盘失败返回 `false` 且不抛错（`tools/flow_acceptance.lua` 已覆盖写拒绝场景）。
- **删除牌组保护（已实现）**：`GS:buy_deck` / `GS:rollShopSlot('deck')` 以 `inherentDeckTotal()=(stageCfg(stage).decks or 1)*52` 与 `removedBasicCount()` 判断，
  剩余 ≤1 或阶段固有套数 ≤1 时拒绝购买/不再进池，返回 `empty_deck`（GDD §16.5）。细节见 §10。
- **带 `markDot` 的商品（已实现）**：`src/relics.lua` 有五件特种标记 `mark_vanish` / `mark_flame` / `mark_bounty` / `mark_void` / `mark_bomb`
  （`group='mark'`、`markDot=true`、`uses=3`）。`GS:buy_relic` 对该类商品只扣款并 `Marks.gainSpecial(state, id)`——不占 5 格遗物栏、同时只持一枚、新购直接替换；普通遗物满栏仍返回 `relic_slots_full`。
- **在线/成就/排行榜**等 GDD 未要求项不在核心范围。

## 7. 已裁决的口径偏差（有意为之，非缺陷）

- 自然 Blackjack 返还 **1.5×下注**（`baseChips = bet*1.5`），不采用经典 2.5。
- 阶段晋级：Stage 1/2 **跑满 15 局后**才判定达标；Stage 3 即时达标通关；“21 至尊”强制跳级且不占本局计数。
- “Assassin / 杀之残卷”只屏蔽 **A、E** 两招（`isCheating` 归零、痕迹清空），B/C/D 保留。
- 指认可在**玩家回合或庄家回合**发起；成功时清空庄家待执行队列，失败后庄家继续。
- 干扰项只在『不出千』分支掷出（GDD 476-481 伪代码）：进入出千分支后即使选中的 A/E 被 Assassin/杀之残卷屏蔽放弃，本小局也不再掷干扰项。痕迹仍只在真正改动手牌/牌堆时绑定。
- 商店「加速」通道（GDD §16.1）：玩家本局**恰好 21 点**时 `roundsSinceShop` 额外 +1（含加倍后 21），可累加；酒吧模式排除。由 `GS:finalizeRound` 在结算时判定。

## 8. 特种标记与短牌靴（本轮 m00757/m00758 落实口径）

- **虚空标记**：锚定玩家手牌；标记瞬间吸收其前一张牌并继承全部词条（倍率/RPS/67/牢笼/筹码/骰子/移除/冠军）；前面没有牌则不消耗次数、不放置标记。
- **消失标记**：只对玩家触发；最多连锁跳过 3 张，第 4 张返回真实牌（不再吞牌）。
- **火焰标记**：庄家回合读牌靴顶（而非扫已有手牌）；顶牌为火焰则不放行该张、直接停牌。
- **爆炸标记**：任何一方摸到即炸掉其后 2 张进弃牌堆，牌靴守恒。
- **赏金标记**：仅庄家要到此牌时 +$500。
- **牌靴枯竭**：发牌/填充不再用 `DT.cardSpec` 凭空造牌；`drawCard` 返回 nil 时宁缺毋滥，短牌靴逻辑在 `tests/marks_acceptance.lua` 覆盖。
- **酒吧 forcedStand**：`dealerStep` 优先读 `dealer.forcedStand`（`dealer_stop` / `dealer_draw_2_stop` 设置），命中即停牌且不再抽牌，端到端已验证。
- **千招痕迹接线**：真招 A–E 只在真正改动手牌/牌堆后 emit `kind='tell'`（`tellKind`/`uid`/`slot`；E 另发玩家首张关联 uid；C 带 `oldRank`）；空招或被屏蔽的 A/E 不发 tell。
- **干扰项**：只在「不出千」分支掷出，发牌后最多物化一次（`_distractorShown` 闩），绑定庄家明牌；真痕迹不写该闩。

## 9. 验证基线

- `tests/run.lua`：**132 PASS / 0 FAIL**（内置 83 + `tests/marks_acceptance.lua` 12 + `tests/shop_acceptance.lua` 31 + `tests/conservation_acceptance.lua` 6），`python tools\run_lua.py tests\run.lua` 可自跑；`main.lua --test` 走同一套。
- `tests/marks_acceptance.lua`：12/12（虚空/消失/火焰/爆炸/赏金/空牌靴/forcedStand 酒吧 e2e）。
- `tests/shop_acceptance.lua`：31/31（每 5 轮店 / 21 加速 / 2% 全牌组 / 折扣跟位 / reroll 倍增 / 重复购买与买不起 / 熔炉三态 / 三种信用与负筹码 / autoEndOnBroke / 21 至尊 / 阶段晋级边界 / 删除牌组底线保护 / markDot 独立单格库存）。
- `tests/conservation_acceptance.lua`：6/6（多回合 beginBet 回收、换靴回收且新牌堆不复用旧 UID、card_pack 跨回合寄存与换靴归还、酒吧 `st.barDeck` 回收、千招 A 替换暗牌计入合成牌、千招 E 镜影复制计入合成牌）。
- `tools/flow_acceptance.lua`（父代理维护）：18/18。
- LÖVE 实跑：`runtime\love-11.5-win64\love.exe . --test` 上一轮 `pass=95 fail=0`；本轮新增用例尚未在 LÖVE 内复跑（UI 侧正在 smoke），headless lua51 为 132/0。
- 父代理 `tools/verify.py`：全部 PASS（含 scoring 与 `tools/stress_acceptance.lua` 50/50，exit 0）。
- 模块加载：`tests/syntax_check.lua` 19 个模块全部 OK。

## 10. 牌堆 UID 守恒与商店库存隔离（本轮修复）

- **新回合回收**：`GS:beginBet` 先 `self:recycleHands()`，把双方手牌 `toDiscard` 回当前 `st.deck` 后再重建 player/dealer；`st.cardPack` 的寄存牌不在手牌里，跨小局保留（GDD card_pack 合法寄存）。
- **换靴跨代清理**：`GS:buildShoe` 先把旧手牌回收进旧牌堆并把 `st.cardPack` 归还旧牌堆，再替换为新 Deck，绝不把旧 UID 塞进新牌堆。
- **酒吧**：`GS:barDeal` 用 `self:recycleHands(st.barDeck)`（酒吧手牌属于 `st.barDeck`，不混入 `st.deck`）。
- **删除牌组底线**：`buy_deck`/`rollShopSlot('deck')` 以 `inherentDeckTotal()=(stageCfg(stage).decks or 1)*52` 与 `removedBasicCount()` 判断，剩余 ≤1 或阶段固有套数 ≤1 时不再提供/购买删除牌组，返回 `empty_deck`。
- **markDot 独立槽**：`buy_relic` 对 `markDot==true` 或 `group=='mark'` 的商品只扣款并 `Marks.gainSpecial`（同时只持一枚，直接替换），不占用 5 格遗物栏；普通遗物满栏仍 `relic_slots_full`。
- **错误码同步**：`GS:fail(code)` 同时写 `self.lastError` 与 `st.lastError`，UI/测试可稳定读取。

## 11. 千招/技能新建牌的合成计账（hard +1 UID 修复）

- **症状**：`tools/stress_acceptance.lua` hard seed 2111 / 2148 / 2629 在 `bet_confirm` 时报 `deck_audit_failed total=expected+1 dup=0 missing=0`。
- **根因**：`Deck:audit` 的 `expected = initialTotal + syntheticCreated`。回合中新建/复制的实体牌必须标记 `is_synthetic=true` 才会在 `assignUid` 时计入 `syntheticCreated`；
  而 `DT.clone` 会原样复制源牌的 `is_synthetic` 与 `_synthCounted`，`DT.mk` 不默认合成。千招 A 的替换暗牌、千招 E 的镜影复制（以及若干调酒技能复制）当时未标记，导致 `syntheticCreated` 少算一张。
- **修复（src/game_state.lua）**：
  - 千招 A：`repl = DT.mk({ ..., is_synthetic = true })`。
  - 千招 E：`local cp = DT.clone(pc); cp.is_synthetic = true; cp._synthCounted = nil`。
  - 调酒技能 `duplicate_lowest` / `pick_from_champion` / `dealer_copy_last` / `dealer_duplicate_ups`：同样在 `assignUid` 前标记 `is_synthetic=true` 并清 `_synthCounted`（源牌本身是合成牌时也必须再计一张）。
- **验证**：`tools/stress_acceptance.lua` 50/50 PASS；`tests/conservation_acceptance.lua` 新增 A/E 两项回归（共 6/6）；`tests/run.lua` 132/0；父代理 `tools/verify.py` 全 PASS。
- **注意**：`DT.clone` 不全局改为合成（会污染 `standard52`/牌组生成，使 `initialTotal` 语义改变并破坏短牌靴判定）；只在回合中真正新增实体牌处显式标记。
