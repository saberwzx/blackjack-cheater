# 职阶实现说明（src/class_actions.lua）

> 覆盖：玩家 7 职阶（Saber/Lancer/Archer/Rider/Caster/Assassin/Berserker）+ 困难模式庄家 7 职阶。
> 兼容：仅新增模块，**不改** src/game_state.lua、src/classes.lua、src/relics.lua、src/relic_actions.lua。
> 验收：python tools/run_lua.py tools/class_acceptance.lua（28 项全通过）；python tools/check_lua.py 0 错误。

## 1. 安装

父代理在 src/game_state.lua 底部按 **bar → relic → class → meta** 顺序安装（meta 最后，避免教程断联）。
当前底部只有 bar 与 meta 两段 pcall，需在 meta 段之前插入：

    pcall(function()
      local m = require('src.relic_actions')
      if m and m.install then m.install(GS) end
    end)
    pcall(function()
      local m = require('src.class_actions')
      if m and m.install then m.install(GS) end
    end)

M.install(GS) 带守卫 GS.__classActionsV1，重复调用幂等；成功后 GS.classActions = M。

## 2. 包裹的方法（内层保留原实现）

| 方法 | 职阶效果 |
| --- | --- |
| start | 困难模式**阶段 1 也分配庄家职阶**（原实现只在阶段 2/3 分配）。 |
| beginBet | 重置 st.classEffect = {}；庄家弓把 dealer.difficulty 设为 3；玩家弓窥视牌靴顶。残卷的每局复位由 relic_actions 的 hookBetPre 负责，本模块不干预。 |
| dealInitial | 玩家枪阶第三张改为「窥视式」（会爆则收回，见 §3）；玩家弓给首牌打 _peek；庄家弓记录 dealer._archerPreview。 |
| decideCheat | 杀阶屏蔽 A/E 读牌千招后清空 st.cheatTrace 并补特效。 |
| dealerStep | 庄家骑阶 50% 跳过时补 dealer_rider_skip 特效（跳过本体在核心）。 |
| settle | 庄家术阶按 #dealerClass.relics 写入 st.classEffect.casterDebuff。 |
| refreshPlayer | 应用术阶级差（-n）；GDD 1745 硬性下限：玩家点数最低 2（不足则钳制为 2，并 assert 校验）；重算爆点（枪/狂宽松爆点由核心决定）。 |
| refreshDealer | 应用术阶级差（+floor(n/2)）；庄家枪/狂 22–25 不算爆。 |
| collectFinalResult | 结算前先执行双方剑阶斩牌；结算后应用 67 优先、狂阶 22–25 判胜、庄家狂阶强制。 |
| finalizeRound | 玩家术阶连胜 3 开替换弹层；庄家术阶连胜 3 夺 1 遗物（上限 5）。 |
| skip_round | **整体替换**：修正下注阶段幻影归还；骑阶次数在下注/玩家两态都消耗；边注全额归还。残卷跳过看 relic 契约旗标 st.shardRiderArmed（点亮时 relic 已扣次），跳成功清 nil，本模块不重复扣次；rod_lost 不再允许跳过。 |
| take_class_offer | 术阶两阶段（pick → target），复用同一动作名（见 §5）。 |
| skip_class_offer | 术阶弹层放弃时回到 resumeState；其余走原实现。 |
| finishClassFlow | **整体替换**：阶段 2→3 庄家职阶必须与阶段 2 不同（修正随机重复）。 |

## 3. 玩家职阶语义

- **Saber 剑阶**：collectFinalResult 时斩断庄家点数最小的一张（A=1），真进弃牌堆，每回合每侧一次；庄家剑阶对称斩玩家。
- **Lancer 枪阶**：初始第三张改为窥视式——若三张合计 > 21，把第三张放回牌靴顶（若该牌带吸收词则改入弃牌堆，无法还原）。庄家枪阶由核心处理（爆则弃牌），并享受 22–25 不爆。
- **Archer 弓阶**：beginBet 时窥视牌靴顶写入 st.classPreview.player，不抽牌/不动牌靴/不消耗随机数；发牌后首牌带 _peek。庄家弓使用读玩家点数的 AI（difficulty=3）并记录 dealer._archerPreview。
- **Rider 骑阶**：3 次跳过本局。下注阶段跳过不扣注也不归还（修正幻影筹码）；玩家阶段跳过全额归还注码与边注；次数在下注/玩家两态都消耗。
  - 骑之残卷（class_rider_shard）只能通过本模块的 skip_round 跳过：进入跳局判定只看 `st.shardRiderArmed == true`（relic_actions 点亮残卷时置 true 并已 consumeRelic 扣次）。跳成功本模块把该旗标清为 nil，同一小局不能二次跳；下一小局由 relic 的 hookBetPre 重置。仅持有残卷而未点亮**不再**获得被动跳过（不判 hasRelic）。
  - 钓具 `rod_lost`（遗弃钓具）***不提供跳过***；按 GDD §12.4 它只把弃牌堆已标记牌钓回牌堆顶。
- **Caster 术阶**：连胜达到 3 的倍数时开 3 选 1 遗物替换弹层，替换后**槽位数与顺序不变**。
- **Assassin 杀阶**：isCheatShielded() 使 A/E 读牌千招失效；核心已在庄家行动时对其隐藏玩家点数（盲打）。
- **Berserker 狂阶**：点数 22–25 不爆；未爆且 p.total > d.total 判玩家胜（GDD 1717「比庄家大」；同点保留基础 push）。庄家狂阶的「不比玩家小即庄家」是唯一平局例外。67 组合优先，任何职阶不得覆盖。

## 4. 庄家职阶语义

- **Saber**：结算前斩玩家最小牌。
- **Lancer**：第三张爆牌由核心弃掉；22–25 不算爆。
- **Archer**：difficulty = 3（读玩家点数），可看到玩家首牌。
- **Rider**：核心 50% 跳过（3 次）。
- **Caster**：每 3 连胜夺 1 件遗物（上限 5）；每件使玩家 -1（最低 2 点，见 refreshPlayer）、庄家 +floor(n/2)。
- **Assassin**：核心 dealerStep 在阶段 3 对玩家隐藏点数。
- **Berserker**：22–25 不爆；未爆且 p.total <= d.total 强制庄家胜（平局也判庄家）。

## 5. UI / 动作契约

- 术阶弹层：st.classOffer = { mode='classOffer', source, purpose='caster_replace'|'caster_shard', phase='pick'|'target', candidates, targetCandidates, pending, replaceId, resumeState }。
  - pick 阶段：take_class_offer(i) 选中候选，进入 target 并把 candidates 换成「可替换的现有遗物」条目；target 阶段同一动作名 take_class_offer(i) 用 i 作为目标槽位完成替换。UI 只需按 classOffer.candidates 重绘即可复用现有 classOffer.lua。
  - Esc/close_top → skip_class_offer → 回到 resumeState（通常 result）。
- 特效（g.fx）：class_fx 系列——saber_slash、archer_preview、dealer_archer_preview、lancer_peek、rider_skip、dealer_rider_skip、caster_offer、caster_pick、caster_replace、caster_resolved、dealer_caster_gain、dealer_class、assassin_shield。

## 6. 供残卷 / 其它模块复用的 helper

| 函数 | 说明 |
| --- | --- |
| M.isPlayerClass(gs, id) / M.isDealerClass | **只认职阶**，内部效果统一走它，避免与残卷双重生效。 |
| M.anyPlayerClass(gs, id) / M.anyDealerClass | 职阶或点亮中的 class_<id>_shard，仅供查询/UI。 |
| M.activeShard(gs, id) | 返回点亮且未过期的残卷实例。 |
| M.saberSlash(gs, side) | 斩最小牌，返回 true, {side,card,value,index,label}。 |
| M.archerPreview(gs, source) | 窥视牌靴顶，返回牌。 |
| M.lancerThirdCard(gs, side) | 窥视式第三张，返回 true,'safe'|'returned'。 |
| M.rollCasterCandidates / M.replaceRelic / M.replaceRelicById / M.openCasterOffer / M.resolveCasterOffer | 术阶候选与替换。 |
| M.dealerCasterGain(gs) | 庄家术阶夺遗物（上限 5）。 |
| M.dealerClassForStage(gs, prev) | 换阶段庄家职阶，保证与 prev 不同。 |

## 7. 调用者需知

- 本模块不自带 opts 字段，全部读 game_state 状态；父代理只需在正确位置安装。
- skip_round 已被整体替换：调用者无需再处理骑阶/残卷次数与幻影归还。
- 残卷（class_*_shard）的实际触发点归 src/relic_actions.lua；但 class_caster_shard / class_saber_shard 等可用上表 helper 复用同一套实现。
- **给 relic_actions 的残卷契约（最终旗标）**：点亮型残卷 `class_*_shard` 由 relic 模块维护 `_active`（点亮）与 `_usesLeft`（点亮即扣次）。骑之残卷点亮时必须置 `st.shardRiderArmed = true` 并重置 `st.flags.riderUsedThisRound = false`，且在 hookBetPre 每局把它复位；本模块 `skip_round` 只判该旗标，跳成功清 nil、不再 consume、不判 hasRelic。saber/berserker/caster 残卷可分别复用 `M.saberSlash` / 狂阶判定 / `M.openCasterOffer(gs,'caster_shard')`。`rod_lost` 不是跳局遗物，禁止在跳局路径使用。玩家 Berserker 判定无论职阶还是残卷都必须是严格 `>`（GDD L1717/L1731），庄家 Berserker 才用 `>=`（GDD L1740）。
- 新增 st.classEffect 字段用于每回合职阶状态（beginBet 重置；settle/finalizeRound 写入）。
