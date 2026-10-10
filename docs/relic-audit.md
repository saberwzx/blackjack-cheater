# Blackjack Cheater 遗物全量审计与修复报告（relic-audit）

> 只读审计代理产出。对象：src/relics.lua 全部 **139** 件遗物定义 vs src/game_state.lua 的 special / pre / on_hit / on_score 实际实现。
> 结论以**行为**为准，不以“存在 139 条定义”或“注册了 handler”冒充实现。

## 0. 快照与说明

| 文件 | 行数 | sha256(前 16) |
| --- | --- | --- |
| src/game_state.lua | 3022 | eadfec052a452de4 |
| src/relics.lua | 303 | 6c7f87569dbc063e |
| src/relic_actions.lua | 965 | 2ddbac4b6273622f |
| src/class_actions.lua | 572 | 92e67c4c335bf474 |
| tools/relic_acceptance.lua | 275 | 97f518e52a9dafd4 |
| tools/scoring_acceptance.lua | 391 | 7b983f870741452d |

- 审计期间 game_state.lua / relics.lua 正被核心/商品代理**并行改动**，上表是写入本报告时的快照；行号会漂移，定位以函数名/字符串为准。
- 修复落在 **新模块 src/relic_actions.lua**（不改 game_state.lua），加上 relics.lua 的定义修正与两份独立验收脚本。
- 安装顺序（game_state.lua 末尾 require 块）：bar → relic → class → meta。class 在 relic 之后安装，因此 class 的 skip_round 最终生效（见 §5）。

## 1. 结论：区分“审计前”与“修复后”

### 1.1 审计前（基线）：约 45 件缺陷

139 条定义全部存在，但当年核心实现里约 45 件是空壳/错误条件/错误消耗/从不触发。主要类别：

1. **从不触发**：always_10_on_third（发牌后 #hand==2，核心却要求 >=3，死分支）、card_pack、black_hole、eight_ball、last_card_save、cheat_trap.auto_stand_next。
2. **错误条件**：ace_guarantee 改的是第二张；second_ace 无条件给 A♥ 且 100%；ten_guarantee 固定 10♦ 且仅当两张都非十；jackpot_two 不比 J/Q/K；ten_magnet 用 0.12 而非 param1=0.38；ace_revolution 只在 total<=21 才改写（应为 A 恒 11）；discard_salvager 从 removed 取；burn 进 removed（应进弃牌堆）。
3. **从不扣次**：twentyone_supreme、soft_22_safe、soft_bust_shield、first_hit_safe、bust_shield、last_card_save、hedge_fund、ink_thief、reveal_ink、所有 mark_*（gain_mark）、所有 rod_*。
4. **错误消耗**：核心 activateRelic 在效果失败时仍无条件 _usesLeft-1；discard_rinse 空堆也扣次；toggle_relic 无每小局重置、无被动/激活区分。
5. **错误阈值/判定**：残卷 Berserker 用 >=（GDD 为严格 >）；shard_saber 只给 +0.5 倍率而非斩庄家最小牌。
6. **钓具整体错位**：deep 插到牌库顶、lost 把牌塞进弃牌堆、golden 只动一张、无“仅已标记牌”过滤、无扣次。
7. **钩子时序**：核心 playerHit 在 hookPlayerHit() 之后才 refreshPlayer()，所以钩子里 p.total/p.busted 是抽牌前的旧值 —— 使用旧值的 first_hit_safe / last_card_save 永不触发。
8. **经济/商店**：bet_syndicate 每 RUN 只翻倍一次（应每小局）；bet_minimizer 在 beginBet 时 bet=0 无意义；openShopEarly 归零 roundsSinceShop（破坏商店节奏）且不扣次。
9. **软 22 判定死条件**（本次数值测试新发现）：核心/初版 soft_22_safe 与 soft_bust_shield 用 “total==22 且 BJ.isSoft(hand)”。但 BJ.isSoft 的定义使其在 total==22 时**恒为 false**（total>21 时 A 会被降到 <=21），所以这两个遗物原本是**永久死效果**。已改为“含 A 且按 A=11 计恰好 22”。

### 1.2 修复后（当前状态）：139 件均已实现

- **真正未实现：0 件。** 4 件（deck_weight_low / deck_weight_high / exclusive_supreme / seclusion）按 GDD 标注为 POOL_EXCLUDED，只保留定义，属**刻意停用**，不计为未实现。
- 其余 135 件都有可触发实现：39 件纯结算 fx + 8 件 scoreHandler + 14 件 on_hit（钩子/特殊）+ 6 件 on_deal + 5 件 on_bet + 情报/钓具/标记/残卷/移动网络等主动件。
- 其中 **55 件**有独立行为/数值断言（§3）；其余为“读码 + 全链套件核验”。
- 需澄清：game_state.lua 内被 relic_actions 覆盖的旧 handler/钩子代码仍可读到，但**生产走的是覆盖后的实现**；旧 base 的错已在覆盖层修正，不再算作生产未实现。这一点是上一版文档措辞的歧义来源，特此更正。

## 2. 逐项修复（src/relic_actions.lua）

安装时包装核心同名方法（不复制核心）：

- registerSpecials：覆盖 8 个 scoreHandler。
  - H.stage_win：21 点触发时 consumeRelic('twentyone_supreme')。
  - H.soft_22_safe / H.soft_22_win：条件改为 isSoft22(hand) = 含 A 且 BJ.handRawTotal==22（原 BJ.isSoft 在 total==22 时恒 false，效果永久死亡）；生效才扣次。
  - H.last_card_save：置空（改由 on_hit 处理）。
  - H.ace_revolution：总点改为所有 A=11 的 handRawTotal；busted=total>21；67 优先强制胜。
  - H.shard_saber：仅残卷 _active 且非剑阶时调用 classActions.saberSlash(gs,'dealer')（斩庄家最小牌），成功才扣次。
  - H.shard_berserker：仅残卷 _active；22..25 且**严格大于**庄家才判胜，生效才扣次。
  - 另用 no-op 覆盖核心的空壳/即时 special，避免被 use_relic 误触发。
- S.peek/burn/reveal/rod/discard_rinse/discard_backflow/discard_salvager/gain_mark/shard_*/open_shop_early：即发型/本小局型完整实现，扣次下放 special 且只在生效时。
- relicApplyPeekAuto + hookBetPre：peek_auto 每小局自动亮牌并扣次；mind_memory 深度 +1（去掉核心“50% 掀庄家暗牌”的错误语义）。
- hookBetPre：每小局重置所有 trigger=='active' 与本小局型残卷/黑洞的 _active；重置 bet_syndicate._usedThisGame、doubleBetUsed；清理 shardRiderArmed、salvage 等。
- hookDealAfter：A♠ 保证（第一张）、第二张 10/J/Q/K 随机、第二张 40% A♣、JQK 配对、枪/弓/杀残卷。
- playerHit 包装：记录抽牌前状态；hookPlayerHit 用**当前手牌重算**点数（核心在钩子后才 refreshPlayer）。
- hookPlayerHit：打捞 → 卡包（跨小局存于 st.cardPack）→ 黑洞（吸收第一张、用后熄灭）→ 给牌 2..8（2×）→ 第三张必 10 → 凑 20 → 对子凑 21（间隙 >10 只加 10）→ 八球 → 第一次 Hit 安全（避免爆才扣）→ 最后一张救命 → 四磁铁（def.param1：ten_magnet 0.38 / peek_and_chase 0.30 / ace_magnet 0.12 / soft_hand_magnet 0.25）。
- activateRelic/use_relic/toggle_relic：重写 —— 被动遗物不可点亮；即发型走 use_relic；本小局型只置 _active；失败不再扣次。
- markCard：放置墨水标记时按是否真实受益扣 ink_thief/reveal_ink；放置特种标记时扣对应 gain_mark 遗物（mark_void 前面无牌不扣）。
- mark_card：为 UI 增加路由 —— 打捞待选时点弃牌堆选牌；钓具就绪时点已标记牌即 rod_pick/confirm（非 swap 自动确认）。
- rod_pick/rod_confirm + applyRod：仅接受已标记牌；deep→牌库底、standard→顶、trawl→上移 3、lost→弃牌堆所有标记牌回顶（越晚弃越靠顶）、golden→按 marked.order 全量置顶、rogue→全量随机抛回；成功才扣次。
- refreshPlayer：残卷 Berserker 25 内不爆。
- bet_set/bet_confirm：最小下注者强制 $50；下注集团在确认时翻倍（受 betLimits 上限约束）。
- skip_round：正确消耗骑残卷、去掉 rod_lost 误判（但 class_actions 随后覆盖，见 §5）。
- accuse：反作弊陷阱指认成功后置 flags.autoStandNext。
- openShopEarly/leave_shop：不再清零 roundsSinceShop；移动网络扣次；提前开店离开后回到原状态（不推进新一局）。
- finalizeRound：对冲基金真实赔付才扣次；术残卷 3 连胜开替换（不预先扣次，由 class 的“替换自身”移除；放弃则不扣）。

relics.lua 定义修正：
- ace_and_ten_exact：新增 totalA1()（A 记 1），修正原用 A=11 的 total（实测 {A,A} 原会误判 12，现在正确不触发）。
- bust_shield：fx 在爆牌改判平局时调用 ctx.gs:consumeRelic('bust_shield')。

## 3. 行为验证

- tools/relic_acceptance.lua（22 项行为断言，独立于核心主测试）：A=1 正反例、给牌 4、第三张必 10、凑 20、对子凑 21（含 >10 只加 10）、八球、第一次 Hit 安全、最后一张救命、卡包存取、黑洞、21 至尊扣次、爆牌护盾扣次、窥牌、焚牌入弃牌堆、淘洗空堆不扣、deep 钓具、最小下注者、下注集团、被动不可点亮、特种标记扣次。
- tools/scoring_acceptance.lua（**75 项数值断言**）：对 39 件纯 fx 逐件按 GDD 断言 mult / x_mult / chips / 最终 winnings 的**正反例**；重点包含 pair_royalty 的 J/Q/K 同点数边界（J+J/Q+Q/K+K 触发，J+Q、10+J、10+10 不触发）、clockwork_dragon 的“非自然”边界（自然 BJ 不触发）、face/suit 判定、22 规则、叠加顺序无关、67 组合 ×67 优先级；并直接测 soft_22_safe / soft_bust_shield 经真实 GS scoreHandlers 的生效与扣次。
- 真实链（bar→relic→class→meta）全套命令输出：
```
Independent acceptance: PASS=18 FAIL=0
relic acceptance: PASS=22 FAIL=0
scoring_acceptance: PASS=75 FAIL=0
class_acceptance: 33 passed, 0 failed
meta_acceptance: PASS=21 FAIL=0
bar_acceptance: 61 passed, 0 failed
Flow acceptance: PASS=18 FAIL=0
Probability acceptance: PASS=27 FAIL=0
```

## 4. 全 139 件逐项状态

状态含义：✅ 有独立断言 = scoring_acceptance / relic_acceptance 直接覆盖率；🔧 已修复/已接线 = 本次改造，读码 + 全链套件核验，但未逐件独立断言；✅ 已实现 = 核心内联/结算 fx，读码核验；⛔ 停用 = GDD 标注 POOL_EXCLUDED，刻意只保留定义。

| id | trigger | special | 状态 |
| --- | --- | --- | --- |

**group=score**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| mult_ring | on_score_calc | - | ✅ 有独立断言 |
| gold_charm | on_score_calc | - | ✅ 有独立断言 |
| super_mult | on_score_calc | - | ✅ 有独立断言 |
| divine_blessing | on_score_calc | - | ✅ 有独立断言 |
| perfect_21 | on_score_calc | - | ✅ 有独立断言 |
| twentyone_supreme | on_score_calc | stage_win | ✅ 有独立断言 |
| ace_and_ten_exact | on_score_calc | - | ✅ 有独立断言 |
| fives_15 | on_score_calc | - | ✅ 有独立断言 |
| low_buff | on_score_calc | - | ✅ 有独立断言 |
| dealer_mirror_17 | on_score_calc | - | ✅ 有独立断言 |
| blackjack_master | on_score_calc | - | ✅ 有独立断言 |
| bj_insurance | on_score_calc | - | ✅ 有独立断言 |
| pair_boost | on_score_calc | - | ✅ 有独立断言 |
| pair_royalty | on_score_calc | - | ✅ 有独立断言 |
| flush_master | on_score_calc | - | ✅ 有独立断言 |
| double_seven | on_score_calc | - | ✅ 有独立断言 |
| rainbow_21 | on_score_calc | - | ✅ 有独立断言 |
| clockwork_dragon | on_score_calc | - | ✅ 有独立断言 |
| push_king | on_score_calc | - | ✅ 有独立断言 |
| push_as_win | on_score_calc | - | ✅ 有独立断言 |
| dealer_22_push | on_score_calc | - | ✅ 有独立断言 |
| insurance_master | on_score_calc | - | ✅ 有独立断言 |
| ten_spotlight | on_score_calc | - | ✅ 有独立断言 |
| dealer_killer | on_score_calc | - | ✅ 有独立断言 |
| steal_money | on_score_calc | - | ✅ 有独立断言 |
| conservative_bet | on_score_calc | - | ✅ 有独立断言 |
| balanced_bet | on_score_calc | - | ✅ 有独立断言 |
| small_bet_master | on_score_calc | - | ✅ 有独立断言 |
| aggressive_bet | on_score_calc | - | ✅ 有独立断言 |
| all_in_fanatic | on_score_calc | - | ✅ 有独立断言 |
| bet_sniper | on_score_calc | - | ✅ 有独立断言 |
| chip_magnet | on_score_calc | - | ✅ 有独立断言 |
| all_in_master | on_score_calc | - | ✅ 有独立断言 |
| debt_collector_pro | on_score_calc | - | ✅ 有独立断言 |
| streak_master | on_score_calc | - | ✅ 有独立断言 |
| streak_hammer | on_score_calc | - | ✅ 有独立断言 |
| stage_champion | on_score_calc | - | ✅ 有独立断言 |

**group=protection**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| first_hit_safe | on_hit | first_hit_safe | ✅ 有独立断言 |
| bust_shield | on_score_calc | - | ✅ 有独立断言 |
| soft_22_safe | on_score_calc | soft_22_safe | ✅ 有独立断言 |
| soft_bust_shield | on_score_calc | soft_22_win | ✅ 有独立断言 |
| last_card_save | on_hit | last_card_save | ✅ 有独立断言 |

**group=deal**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| ace_blessing | on_score_calc | - | ✅ 有独立断言 |
| ace_guarantee | on_deal | ace_guarantee | 🔧 已修复/已接线（读码+全链套件核验） |
| ace_magnet | on_hit | ace_magnet | 🔧 已修复/已接线（读码+全链套件核验） |
| ace_revolution | on_score_calc | ace_revolution | 🔧 已修复/已接线（读码+全链套件核验） |
| second_ace | on_deal_after | second_ace | 🔧 已修复/已接线（读码+全链套件核验） |
| ten_guarantee | on_deal | ten_guarantee | 🔧 已修复/已接线（读码+全链套件核验） |
| ten_magnet | on_hit | ten_magnet | 🔧 已修复/已接线（读码+全链套件核验） |
| jackpot_two | on_deal_after | jackpot_two | 🔧 已修复/已接线（读码+全链套件核验） |

**group=control**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| always_10_on_third | on_hit | third_ten | ✅ 有独立断言 |
| auto_surrender_16 | on_hit | auto_stand_16 | ✅ 已实现（核心内联/结算 fx，读码核验） |
| peek_and_chase | on_hit | chase_ten | 🔧 已修复/已接线（读码+全链套件核验） |
| soft_hand_magnet | on_hit | chase_ace | 🔧 已修复/已接线（读码+全链套件核验） |
| hit_to_20 | on_hit | hit_to_20 | ✅ 有独立断言 |
| pair_to_21 | on_hit | pair_to_21 | ✅ 有独立断言 |
| eight_ball | on_hit | eight_ball | ✅ 有独立断言 |
| black_hole | on_hit | black_hole_absorb | ✅ 有独立断言 |
| card_pack | on_hit | card_pack | ✅ 有独立断言 |

**group=give**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| give_card_8 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |
| give_card_7 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |
| give_card_6 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |
| give_card_5 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |
| give_card_4 | on_hit | give_card | ✅ 有独立断言 |
| give_card_3 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |
| give_card_2 | on_hit | give_card | 🔧 已修复/已接线（读码+全链套件核验） |

**group=excluded**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| deck_weight_low | on_deal | excluded | ⛔ 停用（GDD 标注 POOL_EXCLUDED，保留定义） |
| deck_weight_high | on_deal | excluded | ⛔ 停用（GDD 标注 POOL_EXCLUDED，保留定义） |
| exclusive_supreme | on_round_start | excluded | ⛔ 停用（GDD 标注 POOL_EXCLUDED，保留定义） |
| seclusion | on_round_start | excluded | ⛔ 停用（GDD 标注 POOL_EXCLUDED，保留定义） |

**group=dealer**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| coward_curse | on_score_calc | - | ✅ 有独立断言 |
| dealer_fatigue | on_dealer_turn | dealer_fatigue | ✅ 已实现（核心内联/结算 fx，读码核验） |
| dealer_blind | on_dealer_turn | dealer_blind | ✅ 已实现（核心内联/结算 fx，读码核验） |
| anti_cheat | on_dealer_turn | anti_cheat | ✅ 已实现（核心内联/结算 fx，读码核验） |
| dealer_magnet | on_dealer_hit | dealer_magnet | ✅ 已实现（核心内联/结算 fx，读码核验） |
| no_face_dealer | on_dealer_hit | no_face_dealer | ✅ 已实现（核心内联/结算 fx，读码核验） |

**group=bet**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| bet_syndicate | on_bet | double_bet | ✅ 有独立断言 |
| bet_minimizer | on_bet | force_min_bet | ✅ 有独立断言 |
| late_surrender | active | late_surrender | ✅ 已实现（核心内联/结算 fx，读码核验） |

**group=credit**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| credit_line | on_bet | credit | ✅ 已实现（核心内联/结算 fx，读码核验） |
| all_in_fanatic_rel | on_bet | credit | ✅ 已实现（核心内联/结算 fx，读码核验） |
| high_roller | on_bet | credit | ✅ 已实现（核心内联/结算 fx，读码核验） |

**group=flow**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| stage_survivor | on_stage_clear | stage_bonus | ✅ 已实现（核心内联/结算 fx，读码核验） |
| debt_collector | on_stage_start | debt_borrow | ✅ 已实现（核心内联/结算 fx，读码核验） |
| mobile_network | active | open_shop_early | 🔧 已修复/已接线（读码+全链套件核验） |

**group=cheat**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| ink_thief | passive | ink_half | 🔧 已修复/已接线（读码+全链套件核验） |
| cheat_consort | passive | mark_limit_up | ✅ 已实现（核心内联/结算 fx，读码核验） |
| sharp_family | passive | sharp_family | ✅ 已实现（核心内联/结算 fx，读码核验） |
| hedge_fund | passive | hedge_fund | 🔧 已修复/已接线（读码+全链套件核验） |
| iron_evidence | passive | iron_evidence | ✅ 已实现（核心内联/结算 fx，读码核验） |
| mind_memory | passive | mind_memory | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_ink | passive | reveal_ink | 🔧 已修复/已接线（读码+全链套件核验） |

**group=anticheat**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| cheat_probe | on_deal | suppress_distractor | ✅ 已实现（核心内联/结算 fx，读码核验） |
| cheat_eye | on_deal | suppress_distractor | ✅ 已实现（核心内联/结算 fx，读码核验） |
| cheat_buster_1 | on_dealer_turn | cheat_force_bust | ✅ 已实现（核心内联/结算 fx，读码核验） |
| cheat_reverse | passive | accuse_bonus | ✅ 已实现（核心内联/结算 fx，读码核验） |
| scales_of_justice | on_accuse | accuse_bonus | ✅ 已实现（核心内联/结算 fx，读码核验） |
| cheat_sniffer | on_accuse | accuse_bonus | ✅ 已实现（核心内联/结算 fx，读码核验） |
| cheat_trap | on_accuse | auto_stand_next | 🔧 已修复/已接线（读码+全链套件核验） |
| cheat_fear | on_game_start | halve_cheat | ✅ 已实现（核心内联/结算 fx，读码核验） |

**group=info**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| peek_1 | active | peek | ✅ 有独立断言 |
| peek_2 | active | peek | 🔧 已修复/已接线（读码+全链套件核验） |
| peek_3 | active | peek | 🔧 已修复/已接线（读码+全链套件核验） |
| far_sight | active | peek | 🔧 已修复/已接线（读码+全链套件核验） |
| peek_auto | on_round_start | peek_auto | 🔧 已修复/已接线（读码+全链套件核验） |
| burn_1 | active | burn | ✅ 有独立断言 |
| burn_3 | active | burn | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_12 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_34 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_56 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_78 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_123 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_345 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_456 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_15 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_20_30 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |
| reveal_10_20 | active | reveal | 🔧 已修复/已接线（读码+全链套件核验） |

**group=rod**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| rod_deep | active | rod | ✅ 有独立断言 |
| rod_trawl | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |
| rod_rogue | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |
| rod_swap | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |
| rod_standard | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |
| rod_lost | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |
| rod_golden | active | rod | 🔧 已修复/已接线（读码+全链套件核验） |

**group=discard**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| discard_rinse | active | discard_rinse | ✅ 有独立断言 |
| discard_backflow | active | discard_backflow | 🔧 已修复/已接线（读码+全链套件核验） |
| discard_salvager | active | discard_salvager | 🔧 已修复/已接线（读码+全链套件核验） |

**group=mark**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| mark_vanish | active | gain_mark | 🔧 已修复/已接线（读码+全链套件核验） |
| mark_flame | active | gain_mark | ✅ 有独立断言 |
| mark_bounty | active | gain_mark | 🔧 已修复/已接线（读码+全链套件核验） |
| mark_void | active | gain_mark | 🔧 已修复/已接线（读码+全链套件核验） |
| mark_bomb | active | gain_mark | 🔧 已修复/已接线（读码+全链套件核验） |

**group=shard**

| id | trigger | special | 状态 |
| --- | --- | --- | --- |
| class_rider_shard | active | shard_rider | 🔧 已修复/已接线（读码+全链套件核验） |
| class_archer_shard | active | shard_archer | 🔧 已修复/已接线（读码+全链套件核验） |
| class_lancer_shard | active | shard_lancer | 🔧 已修复/已接线（读码+全链套件核验） |
| class_assassin_shard | active | shard_assassin | 🔧 已修复/已接线（读码+全链套件核验） |
| class_caster_shard | passive | shard_caster | 🔧 已修复/已接线（读码+全链套件核验） |
| class_saber_shard | on_score_calc | shard_saber | 🔧 已修复/已接线（读码+全链套件核验） |
| class_berserker_shard | on_score_calc | shard_berserker | 🔧 已修复/已接线（读码+全链套件核验） |


## 5. 剩余真实未实现 / 验证边界 / 接口

### 5.1 真实未实现
**0 件。** 4 件 POOL_EXCLUDED 按 GDD 刻意停用。

### 5.2 验证边界（已实现但未逐件独立断言）
- 核心内联的 dealer 行为：dealer_fatigue / dealer_blind / anti_cheat / dealer_magnet / no_face_dealer（读码核验，靠共享套件）。
- 核心内联的经济/指认：credit_line、all_in_fanatic_rel、high_roller、accuse_bonus 类、iron_evidence、sharp_family、cheat_probe/cheat_eye、cheat_buster_1、cheat_fear、ink_thief、cheat_consort、stage_survivor、debt_collector、late_surrender。
- relic_actions 中已接线但未逐件断言：ace_guarantee / second_ace / ten_guarantee / jackpot_two、ace_magnet / ten_magnet / peek_and_chase / soft_hand_magnet、give_card_2/3/5/6/7/8、peek_2/3/far_sight/peek_auto、burn_3、reveal_*（10 件）、rod_trawl/rogue/swap/standard/lost/golden、discard_backflow/salvager、mark_vanish/bounty/void/bomb、6 个 class_*_shard、mobile_network、hedge_fund、ink_thief、mind_memory、reveal_ink、cheat_trap。
- 依赖 class_actions 的 shard_saber / shard_berserker：逻辑在 relic_actions，实际斩牌/替换走 classActions；需全链才有意义。
- UI 集成边界：钓具目标选择走 mark_card 路由、打捞选择、card_pack/黑洞/本小局点亮态展示，需 shoe/状态栏配合。

### 5.3 语义解释边界
- clockwork_dragon：GDD 附录原句为“同时含 A 与 10 点牌且非自然 21 时最终 ×10”。当前实现 = 含 A + 含十点牌 + 非自然（Blackjack），**不要求总点恰为 21**；scoring_acceptance 按此字面口径断言（{A,10,5} 触发、自然 BJ 不触发）。若设计意图是“恰好 21 且非自然”，则需产品确认后再改 fx，属规格澄清而非代码 bug。

### 5.4 接口/协作
- skip_round 归属：安装顺序 relic→class，class 的 skip_round 最终生效。契约：点亮骑残卷时 S.shard_rider 置 st.shardRiderArmed=true、flags.riderUsedThisRound=false 并扣次；class 的 skip 用 st.shardRiderArmed 判定，成功后清旗标、不再扣次，删除 hasRelic('rod_lost') 分支。relic_actions 保留 M.postInstall 兜底但按父要求不启用。
- 审计口径：st.cardPack / st.salvageCard 是合法寄存区（跨小局保留），UID 计数审计需计入，否则会误报“UID 消失”。
- 术残卷替换：openCasterOffer 记录 replaceId='class_caster_shard'，由 class 的 replaceRelicById 完成；relic_actions 不预先扣次，避免 _expired 导致查不到目标。
