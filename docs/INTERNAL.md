# Blackjack Cheater 内部模块接口（core-engine v1）

> 面向 src/ 内部模块与内容子模块。UI 层不要读本文件。
> 与 docs/API.md 的公开契约区分：本文件是内部数据格式与事件上下文约定。

---

## 1. 通用约定

- Lua 5.1 / LuaJIT 语义。所有模块 return 一个表，不产生全局变量。
- ASCII 资源 id（如 mult_ring / ck_mercury / saber），均沿用 GDD 原始 ID、不加前缀；中文为 name/desc 文案。
- 模块内不得 require 未列模块；不得依赖 LÖVE（可选用 love.math，缺失时降级）。
- 数值口径：mult 加法、x_mult 乘法。

---

## 2. 事件上下文 ctx（引擎构造，传入遗物/调酒 effect）

ctx = {
  -- 身份
  engine   = <内部句柄>,      -- 引擎 / game_state 对象
  state    = <state 表>,      -- §API.md §2
  round    = 7,               -- 当前小局（1 基）
  stage    = 2,
  mode     = 'normal',
  -- 结算快照（on_score_calc 时有效）
  outcome  = 'win',           -- 'win'|'lose'|'push'|'blackjack'|'bust'
  bet      = 100,
  chips    = 2500,
  player   = <player 子表>,
  dealer   = <dealer 子表>,
  score    = { baseChips=200, chips=0, mult=0, x_mult=1.0, breakdown={} },
  -- 触发点
  event    = 'on_score_calc', -- 触发事件名
  -- 操作
  fx       = function(evt) ... end,   -- 推表现事件（形状见 API.md §6）
  log      = function(text) ... end,
  rng      = function(a,b) ... end,   -- 统一随机；无参返回 [0,1)
  -- 引擎 API（仅列允许调用的）
  api      = <api 表>,        -- §3
}

---

## 3. ctx.api（引擎提供的稳定操作）

全部返回 true/false 表示是否成功。

  -- 牌堆
  api.drawCard(target)            -- target='player'|'dealer'，从抽牌堆取一张
  api.drawSpecificCard(target, pred)  -- pred(card)->bool，从抽牌堆找第一张匹配并抽出
  api.peekDraw(n)                 -- 返回前 n 张（不改动）
  api.removeFromDraw(card)        -- 移出抽牌堆
  api.addToDraw(card, pos)        -- 加回抽牌堆（pos=nil 顶部）
  api.findInDraw(pred)            -- 返回 card 或 nil
  api.burnTop()                   -- 弃掉抽牌堆顶一张
  api.revealCard(card)            -- 标记 card.revealed=true
  api.rerollDeck()                -- 重洗
  -- 手牌
  api.discardPlayerCard(index)
  api.discardDealerCard(index)
  api.swapPlayerCard(index, zone, targetIndex)   -- zone='draw'|'dealer'|'discard'
  api.swapDealerCard(index, zone, targetIndex)
  api.addPlayerCard(cardSpec)     -- cardSpec={rank=,suit=,special=} 或 card
  api.addDealerCard(cardSpec)
  api.setPlayerTotal(n)           -- 仅特殊牌使用
  api.setDealerTotal(n)
  -- 数值
  api.addChips(n)
  api.addBet(n)
  api.refundBet()
  -- 流程/标记
  api.forcePlayerWin()
  api.forceDealerBust()
  api.skipRound()
  api.openShopEarly()
  api.markDealer(card, markId)
  api.gainRelic(id)
  api.gainMark(id)
  api.rerollShop(free)
  api.revealHole()
  api.suppressTell(turns)
  api.recordBreak(cardSpec)
  -- 情报
  api.isRevealed(card)

---

## 4. 遗物定义格式 src/relics.lua

R = {
  LIST = { def, ... },   -- 顺序=GDD 附录 A 顺序，应为 139 条
  byId = function(id) -> def|nil end,
  rarityPrice = function(rarity) -> 50|100|200|400 end,
  price = function(def, stage, opts) -> number end,
  isPoolExcluded = function(def) -> bool end,
}
return R

def = {
  id       = 'dealer_killer',       -- 直接使用 GDD 原始 ID（无前缀），全工程以此为键
  name     = '庄家克星',
  desc     = '庄家爆牌时筹码 +1000',
  spec     = 'on_score_calc | 永久 | 庄家爆牌时筹码 +1000',  -- GDD 原文摘要，审计用
  rarity   = 'rare',                -- common|uncommon|rare|legendary
  trigger  = 'on_score_calc',       -- 见 §4.1
  kind     = 'chips',               -- 见 §4.2，用于图标/配色
  fx       = function(ctx) if ctx.dealer.busted then ch(ctx, 1000) end end,
                                    -- 见 §4.3/§4.4：数值类直接回调，复杂类改用 special 名
  special  = nil,                   -- 复杂效果名；由 game_state 的处理器分发
  group    = 'score',               -- 分组，可选
  line     = 1360,                  -- GDD 附录 A 行号，便于回溯
}

### 4.1 trigger 取值

  passive            -- 常驻，不点亮
  on_score_calc      -- 结算算分
  on_bet             -- 下注阶段
  on_deal            -- 发牌后
  on_hit             -- 玩家要牌时
  on_stand           -- 玩家停牌时
  on_win / on_lose / on_push / on_round_end
  on_accuse / on_accused         -- 指认相关
  on_cheat_executed / on_cheat_detected
  on_shop / on_reroll
  active             -- 玩家回合点击生效
  pre                -- Pre 类

### 4.2 kind 取值

  chips / mult / x_mult / control / luck / mark / defense / economy / class / special

### 4.3 mods 格式

mods = { {stat=..., value=..., cond=...}, ... }

stat 取值：
  chips               -- 加法筹码
  mult                -- 加法倍率
  x_mult              -- 乘法倍率（相乘）
  chips_per_card      -- value x 玩家手牌张数
  chips_per_chipcard  -- value x 筹码牌点数
  chips_per_chipcard_sq -- value x 筹码牌点数^2
  mult_per_card       -- value x 手牌张数
  mult_per_chipcard   -- value x 筹码牌点数
  mult_per_ace / mult_per_seven
  x_mult_per_card     -- 每张手牌乘 (1+value)
  chips_per_bet       -- value x 下注
  mult_per_bet        -- value x 下注

cond（全部可选，AND）：
  outcome='win'|'lose'|'push'|'blackjack'|'nonblackjack'|'bust'
  hand='blackjack'|'67'|'pair'|'soft'|'hard'|'five'|'seven'|'rps'
  stage=n / stageMin / stageMax
  mode='normal'|'hard'|'bar'
  dealerBust=true / noBust=true / standing=true
  minRelics=n / maxRelics=n
  chipsBelow=n / chipsAbove=n / betBelow=n / betAbove=n
  roundMultiple=n
  playerClass='saber' / dealerClass='assassin'
  marksAtLeast=n
  always=true

### 4.4 special 处理器名（引擎已实现，可引用）

  peek_draw            -- 查看抽牌堆顶 n 张
  reveal_hole          -- 揭示庄家暗牌
  reveal_deck_top      -- 展示抽牌堆前 n 张
  burn_draw            -- 烧掉抽牌堆顶 n 张
  discard_player       -- 弃玩家手牌 1 张
  discard_dealer       -- 弃庄家手牌 1 张
  swap_player_draw     -- 玩家手牌与抽牌堆交换
  swap_dealer_draw     -- 庄家手牌与抽牌堆交换
  rod_swap             -- 钓具：换两张的顺位
  add_chip_card        -- 往抽牌堆插入筹码牌
  add_ace              -- 插入一张 A
  force_dealer_bust    -- 强制庄家爆
  force_player_win     -- 强制玩家胜
  blackjack_push       -- 自然 BJ 记平局
  skip_round           -- 跳过本小局
  open_shop_early      -- 提前开店
  free_reroll          -- 免费刷新
  refund_bet           -- 返还下注
  extra_bust_bet       -- 爆注额外
  suppress_tell        -- 抑制庄家痕迹
  suppress_distractor  -- 抑制干扰项
  suppress_ink         -- 抑制墨水标记揭示
  halve_cheat          -- 出千率减半
  cheat_force_bust     -- 作弊时强制庄家爆（作弊克星）
  gain_mark            -- 获得特种标记
  permanent_forge      -- 铸造永久
  counter_engine       -- 反作弊器
  extra_accuse         -- 指认额外奖励
  copy_relic           -- 复制一件遗物
  reveal_all           -- 揭示全牌堆
  set_dealer_stand     -- 改变庄家停牌阈值
  set_dealer_ai        -- 改变庄家 AI 档
  extra_bust_bet_odds  -- 提高爆注赔率
  mark_limit_up        -- 标记上限 +n
  class_shard          -- 残卷相关
  caster_relic         -- Caster 三选一
  call_relic           -- 直接获得指定遗物

若某种效果不在上表，把 special 填一个描述性 ASCII 名并把 approx=true；引擎会记录到 R.unsupported。

---

## 5. 调酒定义格式 src/cocktails.lua

C = { LIST = { ck, ... }, byId = function(id) -> ck|nil end }
return C

ck = {
  id='ck_mercury', name='莫斯科骡子', en='Moscow Mule',
  gddId='mercury',                   -- 附录 D 的原始条目 id
  glass='copper',                    -- 杯型，表现用
  base='vodka',                      -- 基酒
  ingredients={'伏特加'},            -- 原料（含首项基酒）
  color={r=0.85,g=0.6,b=0.2},        -- 液体颜色
  strength=2,                        -- 烈度 1-5
  gift=true,                         -- 是否可能作为赠酒
  group='base',                      -- base(12) | tarot(22)
  ability = {
    id='ab_mercury', name='重洗', desc='弃掉你全部手牌，再抽等量张新牌',
    target='自己手牌+牌堆',            -- 自由文本，供 UI 显示
    special='redraw_hand',           -- 由 bar_mode/game_state 分发；nil=仅数值
    interaction='instant',           -- instant|two_step|checklist|pick_champion
    duration='round',                -- round|turns(2)|permanent|next_round
  },
}

喝 1 口解锁 ability，持续 5 局（buffs[id]=5）。每小局限用 1 次。

---

## 6. 酒吧文案 src/bar_lines.lua

return {
  generic = { '...', ... },          -- 通用科普，洗牌袋
  byDrink = { ck_mercury = {'...'}, ... },
  endings = { date='...', keeper='...', friend='...', fail='...' },
  shuffleBag = function(list, rng) return shuffled_copy end,
}

---

## 7. 与公开 API 的关系

- 引擎（game_state.lua）读取 R.LIST / C.LIST 构造运行时实例（relics 数组 / bar.cups）。
- 运行时实例在定义字段前加下划线（_active 等），并同步无下划线别名（active 等）。
- 子模块不做存档、不改 state，只提供定义与 effect 函数。
