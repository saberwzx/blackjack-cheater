# Blackjack Cheater 核心层 API 契约（供 UI 层调用）

> 版本：core-api v1.1 · 2026-10-01
> 归属：本文件与 src/、tests/ 由核心实现负责；main.lua / conf.lua / ui/ 由界面实现负责。
> 运行环境：LOVE 11.5 / LuaJIT（Lua 5.1 语义），零第三方运行时依赖。
> 本契约描述当前已实现接口。未实现机制集中列在 docs/core-gaps.md。

---

## 0. 模块清单

UI 层只需要 require 一个模块：

    local Game = require('src.game')
    local g = Game.new()          -- 可选 opts，见 §1
    g:start('normal', 12345)      -- 模式 + 种子
    g:action('hit')
    g:update(dt)
    local st = g.state

核心模块（全部位于 src/，均可在无 LÖVE 环境下 require）：

| 模块 | 职责 |
| --- | --- |
| src/game.lua | 唯一公开门面：Game.new / start / action / update / can / getView / flush |
| src/game_state.lua | 对局状态机、下注、发牌、行动、结算、商店、标记、钓具、职阶 |
| src/blackjack.lua | 点数、原始值、牌型、庄家 AI、胜负判定、自然 Blackjack |
| src/deck.lua | 守恒牌堆、uid、弃牌、洗回、切牌、审计 |
| src/deck_types.lua | 12 种特殊牌组生成与定价、固有牌堆 |
| src/relics.lua | 139 件遗物定义、定价、抽取池 |
| src/classes.lua | 7 玩家职阶 + 7 残卷 + 7 庄家职阶 |
| src/scoring.lua | 五阶段链式算分 |
| src/event_manager.lua | 内容触发总线（pub/sub + 效果合并） |
| src/shoe_info.lua | 情报计算（成分 / 下一张爆率 / 庄家爆率 / 顺序带） |
| src/marks.lua | 墨水标记 + 5 种特种标记 + 发现判定 |
| src/cocktails.lua | 34 款调酒 + 倒计时 + 混色 |
| src/bar_lines.lua | 酒吧科普文案（通用 + 专属，洗牌袋） |
| src/bar_mode.lua | 酒吧模式全量（100 局、赠酒、结局、34 技能） |
| src/champion.lua | 冠军牌组模型 + 牌面池 |
| src/persist.lua | 存档序列化 / 消毒 / 沙箱反序列化 / 元进度 |
| src/tutorial.lua | 14 步教程数据与推进 |
| src/rng.lua | 随机封装（默认 love.math.random，可注入 stub） |
| src/util.lua | 深拷贝、钳制、序列化辅助 |

---

## 1. 构造与生命周期

### Game.new(opts)

    local g = Game.new({
      rng        = nil,   -- 可选：function(...) 替代 love.math.random；测试注入
      rngSeed    = nil,   -- 可选：number，安装随机种子
      filesystem = nil,   -- 可选：{read=fn, write=fn, getInfo=fn, mkdir=fn, remove=fn}
      settings   = nil,   -- 可选：覆盖默认设置字段
      progress   = nil,   -- 可选：预置元进度（测试用）
    })

### g:start(mode, seed)

- mode：'normal'（基础）/ 'hard'（困难）/ 'bar'（酒吧）。缺省 'normal'。
- seed：number 或 nil。传入时以该种子重置随机序列并写 state.seed。
- 行为：重置整个 g.state；normal/hard 从 relic_select 起步（relicSelect 已生成），bar 从 bar_brief 起步。
- 返回：ok(boolean), err(string|nil)。

### g:action(name, arg)

唯一入口。返回 ok(boolean), err(string|nil)。
- ok == false 时 err 为稳定错误码（见 §7），同时写入 g.lastError。
- 未定义 name 返回 false, 'unknown_action'。
- 非法动作返回 false, 'action_unavailable'，且不改变任何 state。
- 接受 §5.8 列出的 method 风格别名（placeBet / hitPlayer 等）。

### g:update(dt)

推进核心计时器（庄家逐张要牌、结算演出等）。UI 每帧调用，dt 为秒。核心不含动画曲线。

### g:flush()

把当前所有待执行定时器立刻跑完（测试 / 跳过演出）。返回执行步数。

### g:can(name, arg)

返回 ok(boolean), reason(string|nil)，无副作用。UI 用它决定按钮可用性。

### g:getView()

返回 UI 友好的只读视图（state 关键字段浅拷贝 + 动作列表 + 派生标签）。

### g:drainFx() / g:drainLog()

取出并清空 state.fx / state.log 队列，返回数组。UI 每帧调用一次。

### 测试入口

main.lua --test 时 require('tests.run')，返回的表可调用，也提供 .run()。

    local tests = require('tests.run')
    local ok, report = tests.run({ verbose = true })   -- 或 tests({...})

report = { pass=n, fail=n, errors={...}, logs={...}, reproducible=true }

---

## 2. state 顶层字段（稳定契约）

    state = {
      state        = 'title',   -- 当前屏，取值见 §3
      prevState    = nil,
      mode         = 'normal',  -- 'normal'|'hard'|'bar'
      seed         = 12345,
      stage        = 1,
      stageName    = '新手赌场',
      stageTarget  = 2000,
      stageRounds  = 15,
      roundsInStage= 0,
      round        = 0,         -- 全局小局计数（未开始为 0）
      chips        = 2500,
      bet          = 0,
      bustBet      = { on=false, amount=0, odds=nil, hit=false, locked=false },
      player       = { ... },   -- §4.1
      dealer       = { ... },   -- §4.2
      deck         = Deck,      -- §4.3
      relics       = { ... },   -- §4.4 遗物栏数组
      relicSlotMax = 5,
      specialMarks = { ... },   -- §4.5
      playerClass  = nil,       -- §4.6 （别名 state.class）
      dealerClass  = nil,
      shop         = { ... },   -- §4.7
      relicSelect  = { ... },   -- 开局三选一候选（relic_select 屏）
      classOffer   = nil,       -- { candidates={relic...}, source='caster'|'shard' }
      message      = '',
      messageTone  = 'info',
      result       = nil,       -- §4.8
      shoe         = { ... },   -- §4.9
      streak       = 0,
      fx           = { ... },   -- §6
      log          = { ... },
      progress     = { ... },   -- §4.10
      settings     = { autoEndOnBroke=true, volume=0.6, resolution=1, fullscreen=false },
      tutorial     = nil,       -- §4.11
      bar          = nil,       -- §4.12
      flags        = { ... },
    }

数值口径：mult 一律加法，x_mult 一律乘法。UI 文案不得混用。

---

## 3. state.state 取值

主模式：title -> modeSelect -> relic_select -> bet -> player -> dealer -> result -> shop -> 下一局
支线：classSelect（阶段 2->3）、stageClear、classOffer、victory、forceExit、deckEditor、deckOverview、shoeInfo。

deckOverview / shoeInfo 是叠加模态：打开时保留 prevState，关闭后回到 prevState。
酒吧模式：bar_brief -> bar_gift -> player -> dealer -> result -> bar_drink(可选) -> ... -> bar_ending / forceExit。

---

## 4. 子结构

### 4.1 player

    player = {
      hand        = { card, ... },
      total       = 17,
      rawTotal    = 27,
      busted      = false,
      stood       = false,
      blackjack   = false,
      is67        = false,
      isRps       = false,
      surrendered = false,
      doubled     = false,
      cageBlocked = false,
      peekIndex   = nil,
    }

### 4.2 dealer

    dealer = {
      hand         = { card, ... },
      total        = 20,
      rawTotal     = 20,
      busted       = false,
      holeRevealed = false,
      difficulty   = 1,
      standOn      = 17,
    }

### 4.3 deck

    deck = {
      drawPile       = { card, ... },   -- 顶部为 [1]
      discardPile    = { card, ... },
      removed        = { card, ... },
      syntheticCount = 0,
      shuffleCount   = 0,
      removedDecks   = 0,
    }
方法（核心/测试用）：deck:draw() / deck:toDiscard(card) / deck:shuffleDiscardIn() / deck:auditTotal()
/ deck:addCards(cards,label) / deck:findByUid(uid) / deck:peek(n) / deck:cut(k)。

### 4.4 relics（数组，最多 relicSlotMax 件）

    relic = {
      id='mult_ring', name='倍率戒指', desc='每局倍率 +1',
      rarity='uncommon', price=1200, icon=3,
      triggers={'on_score_calc'},
      _active=false,      -- 已点亮（手动件）
      _auto=false,        -- 常驻被动
      _preGame=false,     -- Pre 类，不可点亮
      _consumable=false,  -- 限次
      _usesLeft=nil,      -- 剩余次数（nil=永久）
      _forged=false,      -- 已铸造永久
      _roundActive=false, -- 本小局真实起过作用
      _sold=false,
      group=nil, markDot=false, kind=nil,
      active=false, consumable=false, usesLeft=nil, forged=false,  -- 兼容别名，与上同步
    }

### 4.5 specialMarks

    specialMarks = { held = nil }
    -- held = { id='mark_bomb', name='爆炸标记', usesLeft=3, forged=false, color='red' }
每回合限用 1 次：flags.specialMarkUsedThisRound。

### 4.6 playerClass / dealerClass

    playerClass = { id='saber', name='Saber 剑', letter='S', desc='...', kind='trigger', used=false }
    dealerClass = { id='assassin', name='Assassin 杀', ... }

### 4.7 shop

    shop = {
      open      = true,
      shelves   = { {kind='relic', item=item, price=1800, sold=false, basePrice=1200}, ... ,
                    {kind='deck',  item=deckItem, price=900, sold=false} },
      relics    = { item, item, item, item },   -- shelves 1..4 别名
      deckItem  = deckItem,                     -- shelves[5] / 别名
      allDecks  = false,
      discount  = { slot=2, factor=0.5 },
      rerollCost= 200,
      forgeOffer= nil,   -- { available=true, price=10000, candidates={...} }
      forgeUsed = false,
      returnState='player',
    }
item（遗物）: { relic=<浅拷贝>, price, basePrice, sold, slot }
deckItem:     { type='decimal', size='small', name='小数牌组', price=900, sold=false }

### 4.8 result

    result = {
      outcome='player', bet=200, baseChips=400, additiveChips=500,
      mult=3, xMult=2.0, winnings=2700, netChange=2500, chips=3200,
      breakdown={ {label='倍率戒指', kind='mult', value=1}, ... },
      bustBet={ on=false, amount=0, odds=nil, hit=false, payout=0 },
      accuse={ attempted=false, correct=false, bonus=0 },
      marks={ discovered=0, penalty=0 },
      forcedStage=false, events={ '...' },
    }

### 4.9 shoe（情报缓存）

    shoe = {
      order = { { card=card, revealed=true|false }, ... },
      composition = { {label='A', count=4}, ..., unknown=0 },
      nextBustOdds = 0.42,      -- number 或 nil
      dealerBustOdds = 0.28,    -- number 或 nil
      discard = { card, ... },
      revealSlots = { [1]=true, [3]=true },
      coverageGap = '',
      offset = 0,
    }

### 4.10 progress

    progress = {
      hardCleared=false, hardClearCount=0, maxStage=1, maxChips=2500,
      totalRuns=0, bestRoundsBasic=0, bestRoundsHard=0,
    }

### 4.11 tutorial

    tutorial = { active=true, step=1, total=14,
      phase={ index=1, title='21 点的胜负', text='...', requireAction=nil, actionHint='' },
      done=false }

### 4.12 bar

    bar = {
      round=1, totalRounds=100,
      cups = { { id='mercury', name='莫斯科骡子', mouth=2, color={...} }, ... },
      buffs = { [id]=5 },
      prob = 0.01,
      giftOptions = { ... },
      pendingDrink = nil,
      hangover = false, hangoverColor = {r,g,b},
      abilitiesUsed = {},
      lastLine = '', ending = nil,
      wins=0, losses=0,
    }

---

## 5. 公开动作表 g:action(name, arg)

### 5.0 通用

| 动作 | arg | 屏 | 说明 |
| --- | --- | --- | --- |
| close_top | - | 任意 | 等价 ESC，按优先级链关闭最上层模态 |
| continue | - | result/stageClear/victory/forceExit/bar_ending | 推进 |
| set_setting | {key,value} | 任意 | autoEndOnBroke/volume/resolution/fullscreen |
| toggle_setting | key | 任意 | 布尔设置取反 |
| reset_progress | - | title/任意 | 删除存档回默认 |
| dismiss | - | 任意说明弹窗 | 关闭一次性说明 |

### 5.1 流程

| 动作 | arg | 屏 | 说明 |
| --- | --- | --- | --- |
| select_mode | 'normal'|'hard'|'bar' | modeSelect | 进入所选模式 |
| pick_relic | index 1..3 | relic_select | 开局三选一 |
| start_tutorial | - | title | 启动 14 步教程 |
| tutorial_advance | - | 任意 | 推进教程；requireAction 未完成返回 false,'tutorial_action_required' |
| choose_class | class id | classSelect | 阶段 2->3 选职阶 |
| take_class_offer | index 1..3 | classOffer | Caster / 残卷替换 |
| skip_class_offer | - | classOffer | 不替换 |

### 5.2 下注

| 动作 | arg | 屏 | 说明 |
| --- | --- | --- | --- |
| bet_preset | 1..5 | bet | $50/$100/$200/$500/$1000 |
| bet_set | number | bet | 直接设主注（钳制） |
| bet_adjust | delta | bet | 相对调整 |
| bet_confirm | - | bet | 确认并进入发牌 |
| toggle_bust_bet | - | bet/player | 爆注开关 |
| skip_round | - | bet/player | Rider / 骑之残卷 跳过 |
| toggle_relic | index 或 id | bet/player | 点亮/熄灭 |
| use_relic | index 或 id | bet/player | 点亮即生效类（窥视/焚牌/揭示/钓具/弃牌道具/移动网络） |
| open_shop_early | - | player | 移动网络开店 |

### 5.3 玩家行动

| 动作 | arg | 屏 | 说明 |
| --- | --- | --- | --- |
| hit | - | player | 要牌 |
| stand | - | player | 停牌 -> 庄家行动 |
| double | - | player | 加倍 |
| surrender | - | player | 投降 |
| accuse | - | player | 指认（每小局 1 次） |
| mark_card | {zone='shoe'|'player'|'dealer'|'discard', index=n} 或 {uid=n} | 牌桌/面板 | 标记/取消 |
| unmark_card | 同上 | 同上 | 显式取消 |
| rod_pick | {uid=n} | shoeInfo | 钓具目标（点选型） |
| rod_confirm | - | shoeInfo | 换位钓具第二目标确认 |

### 5.4 面板

| 动作 | arg | 屏 |
| --- | --- | --- |
| open_shoe / close_shoe | - | 牌桌 / shoeInfo |
| shoe_scroll | dir(±1/±3) | shoeInfo |
| shoe_tab | 'order'|'composition'|'odds'|'discard' | shoeInfo |
| open_deck / close_deck | - | 牌桌 / deckOverview |
| deck_scroll | dir(±1/±5) | deckOverview |

### 5.5 商店

| 动作 | arg | 屏 |
| --- | --- | --- |
| buy_relic | slot 1..5 | shop |
| buy_deck | - | shop |
| reroll | - | shop |
| open_forge | - | shop |
| forge_select | {kind='relic'|'mark', index=n} | shop |
| confirm_forge / cancel_forge | - | shop |
| leave_shop | - | shop |

### 5.6 酒吧模式

| 动作 | arg | 屏 |
| --- | --- | --- |
| bar_begin | - | bar_brief |
| bar_gift_pick | index 1..3 | bar_gift |
| bar_drink | cup index 或 id | result/bar_drink |
| bar_ability | {id=..., target=...} | player |
| bar_pick | index/uid | player |
| bar_confirm | - | player |

bar_ability 失败返回上述 ability_* / unknown_skill / no_hand / no_up / empty_deck / no_choice / no_card；需要选目标的技能先返回 no_choice，UI 打开面板后调 bar_pick 选择，再 bar_confirm 确认。

### 5.7 冠军牌组编辑器

| 动作 | arg | 屏 |
| --- | --- | --- |
| open_deck_editor | - | title/modeSelect |
| close_deck_editor | - | deckEditor |
| champion_toggle | face index 1..N | deckEditor |
| champion_clear | - | deckEditor |
| champion_filter | group key | deckEditor |
| champion_save | - | deckEditor |

### 5.8 method 风格别名（UI 可直接用）

    placeBet->bet_confirm        hitPlayer->hit          standPlayer->stand
    doubleDown->double            surrenderPlayer->surrender  accuseDealer->accuse
    skipRound->skip_round         toggleRelicActive->toggle_relic
    useRelicPassive->use_relic    buyRelic->buy_relic     buyDeck->buy_deck
    rerollShop->reroll            leaveShop->leave_shop   openShop->open_shop_early
    markCardAt->mark_card         markHandCard->mark_card markDiscardAt->mark_card
    chooseClass->choose_class     takeClassOffer->take_class_offer
    barDrink->bar_drink           barUseAbility->bar_ability
    openDeckEditor->open_deck_editor  championToggle->champion_toggle
    openShoeInfo->open_shoe       openDeckOverview->open_deck

---

## 6. state.fx 表现事件队列

    { kind='deal',         target='player'|'dealer', card=card, index=n }
    { kind='card_hit',     target='player'|'dealer', card=card }
    { kind='card_discard', card=card, from='player'|'dealer'|'tell' }
    { kind='score_popup',  text='$2,700', value=2700, big=true }
    { kind='counter',      counterKind='chips'|'mult'|'x_mult', label='倍率戒指', value=1 }
    { kind='shake',        amount=10 }
    { kind='sfx',          name='blackjack'|'67'|'getout'|'deal'|'win'|'lose'|'accuse_ok'|'accuse_bad'|'mark'|'forge'|'chip' }
    { kind='bgm',          name='phase1'|'phase2'|'phase3'|'bar' }
    { kind='message',      text='...', tone='info' }
    { kind='tell',         tellKind='A'..'E'|'dA'..'dE', card=card, slot='hole'|'up'|'player', uid=n }
    { kind='mark_fx',      markId='mark_bomb', anchor='shoe'|'player'|'dealer', card=card }
    { kind='saber_slash',  target='dealer'|'player', card=card }
    { kind='rod_fx',       rodId='rod_standard', count=n }
    { kind='state',        from='player', to='dealer' }

tell 事件契约（千招痕迹 / 干扰项）：
- 真痕迹：A/E 在 executeCheatDeal 真正替换后发出，B/C/D 在 dealerDrawOne 真正替换后发出；
  不再只写 intent.tell 字符串。字段：tellKind='A'..'E'、uid=被改动牌的 uid、card=该牌、slot='hole'|'dealer'。
- E 额外再发一条 tell 绑定玩家第一张明牌（uid=该玩家牌，link=true），供 UI 画蓝色菱形关联。
- C 额外带 oldRank=被换掉那张牌的原 rank（原牌仍在弃牌堆，_tellOldRank 也存该 rank 字符串）。
- 干扰项：decideCheat 走「不出千」分支后才掷；发牌结束（dealInitial 末尾）最多物化一次，
  tellKind='dA'..'dE'，绑定庄家明牌（slot='up'，无明牌时退玩家首张），并置 state._distractorShown；
  真痕迹不写该闩。空招 / 被屏蔽 A·E 不发出任何 tell。

state.log 为字符串数组。

---

## 7. 错误码表

| 错误码 | 含义 |
| --- | --- |
| unknown_action | 未注册动作 |
| action_unavailable | 当前屏不允许 |
| invalid_arg | 参数非法 |
| not_enough_chips | 筹码不足 |
| hand_full | 手牌已满 12 |
| cannot_double | 不满足加倍条件 |
| cannot_surrender | 不满足投降条件 |
| accuse_used | 本小局已指认 |
| mark_limit | 墨水标记达上限 |
| mark_forbidden | 酒吧模式不可标记 / 目标非法 |
| relic_slots_full | 遗物栏已满 |
| locked | 冠军编辑器未解锁 |
| champion_size | 冠军牌组未满 36 张 |
| shop_full | 无可购买位 / 已售出 |
| forge_unavailable | 铸造不可用 |
| tutorial_action_required | 教程要求先完成指定动作 |
| game_over | 已结束，需 start 新周目 |
| no_state | 未 start |
| unknown_skill | 调酒技能 id 不存在 |
| ability_locked | 该杯酒尚未喝到解锁（buff 未点亮） |
| ability_used | 该杯酒本小局技能已用 |
| ability_failed | 技能执行条件不满足（如无合法目标） |
| no_hand | 目标方没有手牌 |
| no_up | 庄家没有明牌 |
| empty_deck | 牌靴与弃牌堆皆空 |
| no_choice | 技能需要玩家在面板中先选择目标 |
| no_card | 指定 uid/index 找不到对应牌 |

---

## 8. 随机与确定性

- 所有玩法随机走 src/rng.lua（默认 love.math.random），不得直接 math.random。
- g:start(mode, seed) 传入 seed 时调用 love.math.setRandomSeed（若可用）。注入 opts.rng 时以注入为准。
- 情报计算（shoe_info.lua）为纯函数、不消耗随机数。
- 酒吧模式 decideCheat 直接 return，不掷任何骰。
- 自然 Blackjack 按 GDD 返还 1.5 x bet（baseChips = bet x 1.5），不是经典 2.5。

---

## 9. 存档

- 默认后端 love.filesystem，目录 saves21/，identity blackjack-cheater。
- 文件：progress.lua（元进度 + 设置）、collection.lua（冠军牌组 36 张）。
- Game.new 自动尝试读取；读写失败静默降级，不抛错。
- 写盘时机：开局、通关、破产、淘汰、设置变更、冠军保存。不每帧写盘。

---

## 10. 测试注入示例

    package.path = 'D:/dsh/Products/BlackjackCheater/?.lua;' .. package.path
    local Game = require('src.game')
    local g = Game.new({ rng = function(a,b) ... end, filesystem = memfs })
    g:start('normal', 1)
    g:action('bet_set', 50)
    g:action('bet_confirm')
    g:flush()

---

## 11. 版本与兼容

- 本文件是 UI 层与核心层的唯一契约。UI 不得直接 require src/ 内部模块（blackjack.lua 等），只能通过 Game 门面。
- 例外：src/blackjack.lua 的纯函数 cardValue / handTotal 允许被 UI 只读调用用于展示。
- 任何字段新增向后兼容；重命名或删除属不兼容变更，必须先更新本文件。
