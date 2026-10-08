-- ============================================================
-- Relics — 遗物定义系统 V3
-- 规则: 诅咒全删 / 纯少量筹码全删 / 倍率遗物涨价×2+升稀有度
-- 新增: 反作弊扩展组 + 下注倍率组
-- ============================================================

local Relics = {}

Relics.RARITY = {
    common    = {0.7, 0.7, 0.7},
    uncommon  = {0.3, 0.8, 0.3},
    rare      = {0.3, 0.5, 1.0},
    legendary = {1.0, 0.7, 0.2},
    cursed    = {0.9, 0.2, 0.2},
}

Relics.PRICES = {
    common    = 50,
    uncommon  = 100,
    rare      = 200,
    legendary = 400,
    cursed    = 150,  -- 保留结构但不再有 cursed 遗物
}

-- ============================================================
-- 遗物定义表
-- ============================================================

Relics.LIBRARY = {
    -- ========================================
    -- 基础倍率类（全部涨价+升稀有度）
    -- ========================================
    { id = "mult_ring",      name = "倍率戒指", desc = "激活后：每局倍率 +1", rarity = "uncommon",      triggers = {"on_score_calc"}, effect = function(ctx) return { mult = 1 } end },
    { id = "gold_charm",     name = "黄金幸运符", desc = "激活后：每局倍率 +2", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx) return { mult = 2 } end },
    { id = "divine_blessing",name = "神之保佑", desc = "激活后：最终 ×1.2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) return { x_mult = 1.2 } end },

    -- ========================================
    -- 玩家点数 → 倍率（全部涨价+升稀有度）
    -- ========================================
    { id = "ink_thief",      name = "墨水大盗", desc = "持有：墨水标记费用减半（25/100/500，按阶段）。共 3 次（每次减费标记消耗 1 次，可铸造永久）。", rarity = "rare",      auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "perfect_21",     name = "完美 21", desc = "激活后：恰好 21 点（非自然）时 最终 ×2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.player_total == 21 and not ctx.is_blackjack then return { x_mult = 2 } end end },
    { id = "twentyone_supreme", name = "21 至尊", desc = "激活后：恰好 21 点直接判该阶段胜利，\n奖励等同于该阶段目标的筹码并立刻转阶段。（仅生效 1 次）", rarity = "legendary",      _consumable = true, _usesLeft = 1,
      triggers = {"on_score_calc"},
      effect = function(ctx)
          if ctx.player_total == 21 and not ctx.force_win then
              ctx.force_win = true
              ctx.twentyone_supreme_hit = true
          end
      end },
    -- ========================================
    -- 传奇新遗物：黑洞 + 卡包
    -- ========================================
    { id = "black_hole", name = "黑洞",
      desc = "激活后：本小局你下一次要牌时，吸收位于第一位置的牌（每小局一次）。\n（激活状态每小局重置，需要重新点亮）",
      rarity = "legendary",      triggers = { "on_hit" },
      effect = function(ctx) ctx.blackhole_absorb = true end },
    { id = "card_pack", name = "卡包",
      desc = "激活后：如果卡包没存牌（默认），你下一次要牌会存进卡包。\n如果卡包已存牌，你下一次要牌会取出卡包里存的那张。\n（存牌内容会在状态栏显示）",
      rarity = "legendary",      triggers = { "on_hit" },
      effect = function(ctx) ctx.game._cardPackActive = true end },

    -- ========================================
    -- 牌堆操控遗物：移动网络 / 独享至尊 / 闭关
    -- ========================================
    { id = "mobile_network", name = "移动网络",
      desc = "激活后：立刻在要牌阶段打开一次商店。\n商店规则与回合结束时的商店完全一致。\n**仅一次，用后消失。**",
      rarity = "rare",      _consumable = true, _usesLeft = 1,
      -- 无 triggers：不注册任何事件，点亮即开店（由 GameState.toggleRelicActive 派发）
    },
    { id = "exclusive_supreme", name = "独享至尊",
      desc = "本小局只有你能抽到特殊牌组的牌，庄家只能抽到固有牌堆的牌。",
      rarity = "legendary",      auto_active = true, triggers = { "on_round_start" },
      effect = function(ctx)
          local g = ctx.game
          g._drawRestrict = g._drawRestrict or {}
          g._drawRestrict.dealer = true
      end },
    { id = "seclusion", name = "闭关",
      desc = "本小局只有庄家能抽到特殊牌组的牌，你只能抽到固有牌堆的牌。",
      rarity = "common",      auto_active = true, triggers = { "on_round_start" },
      effect = function(ctx)
          local g = ctx.game
          g._drawRestrict = g._drawRestrict or {}
          g._drawRestrict.player = true
      end },

    -- ========================================
    -- 自然 Blackjack 专属
    -- ========================================
    { id = "blackjack_master", name = "Blackjack 大师", desc = "激活后：自然 21 时 最终 ×5", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.is_blackjack then return { x_mult = 5 } end end },
    { id = "bj_insurance",   name = "Blackjack 保险", desc = "激活后：自然 21 不会被庄家反超", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.is_blackjack then ctx.force_win = true end end },

    -- ========================================
    -- A 牌相关（倍率类涨价+升稀有度）
    -- ========================================
    { id = "ace_blessing",   name = "A 之祝福", desc = "激活后：手牌每张 A 倍率 +1", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          local ac = 0; for _, c in ipairs(ctx.player_hand or {}) do if c.rank == 'A' then ac = ac + 1 end end
          if ac > 0 then return { mult = ac } end end },
    { id = "ace_guarantee",  name = "A 之保证", desc = "发牌第一张总是 A", rarity = "legendary",      triggers = {"on_deal"}, effect = function(ctx) ctx.force_first_card = { rank = 'A', suit = '♠', faceUp = true } end },
    { id = "ace_magnet",     name = "A 磁铁", desc = "激活后：每次要牌有 12% 概率直接给你一张 A", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          if love.math.random() < 0.12 then
              ctx.force_draw_card = { rank = 'A', suit = '♠', faceUp = true }
          end end },
    { id = "ace_revolution", name = "A 之革命", desc = "激活后：你的 A 永远算 11 点（不会降级成 1，更容易爆）", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.force_win then return end   -- 67 组合技优先，不覆盖
          local Blackjack = require("src.blackjack")
          local raw = Blackjack.calculateHandRaw(ctx.player_hand)   -- 不降级 A 的原始点数
          if raw == ctx.player_total then return end
          ctx.player_total = raw
          ctx.player_bust  = raw > 21
          if ctx.player_bust then ctx.result = "dealer"
          elseif ctx.dealer_bust then ctx.result = "player"
          elseif raw > ctx.dealer_total then ctx.result = "player"
          elseif ctx.dealer_total > raw then ctx.result = "dealer"
          else ctx.result = "push" end
      end },

    -- ========================================
    -- 10 点牌相关
    -- ========================================
    { id = "ten_guarantee",  name = "10 点保证", desc = "发牌第二张总是 10/J/Q/K", rarity = "rare",      triggers = {"on_deal"}, effect = function(ctx) local faces = {10,'J','Q','K'}; ctx.force_second_card = { rank = faces[love.math.random(4)], suit = '♥', faceUp = true } end },
    { id = "ten_magnet",     name = "10 点磁铁", desc = "激活后：每次要牌有 38% 概率直接给你一张 10 点牌（10/J/Q/K）", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          local r = love.math.random()
          if r < 0.38 then
              local faces = {10, 10, 10, 10, 'J', 'Q', 'K'}; ctx.force_draw_card = { rank = faces[love.math.random(#faces)], suit = '♦', faceUp = true }
          end end },
    { id = "ten_spotlight",  name = "10 点聚光灯", desc = "激活后：手牌有 10/J/Q/K 时 倍率 +1", rarity = "uncommon",      triggers = {"on_score_calc"}, effect = function(ctx)
          local has = false
          for _, c in ipairs(ctx.player_hand or {}) do
              if c.rank == 10 or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then has = true break end
          end
          if has then return { mult = 1 } end end },

    -- ========================================
    -- 牌型（倍率类涨价+升稀有度）
    -- ========================================
    { id = "pair_boost",     name = "对拍加成", desc = "激活后：手牌有对子时 倍率 +3", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.has_pair then return { mult = 3 } end end },
    { id = "pair_royalty",   name = "对子皇家", desc = "激活后：手牌有两张点数相同的 J/Q/K 时 倍率 +8", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          local hand = ctx.player_hand or {}
          for i = 1, #hand do
              for j = i+1, #hand do
                  if hand[i].rank == hand[j].rank and
                    (hand[i].rank == 'J' or hand[i].rank == 'Q' or hand[i].rank == 'K') then
                      return { mult = 8 }
                  end
              end
          end end },
    { id = "flush_master",   name = "同花大师", desc = "激活后：手牌 4+ 张同花色 最终 ×2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.flush_count and ctx.flush_count >= 4 then return { x_mult = 2 } end end },

    -- ========================================
    -- 庄家相关（倍率类涨价+升稀有度）
    -- ========================================
    { id = "dealer_killer",  name = "庄家克星", desc = "激活后：庄家爆牌 筹码 +1000", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.dealer_bust then return { chips = 1000 } end end },
    { id = "coward_curse",   name = "胆小鬼诅咒", desc = "激活后：庄家点数 17 时 倍率 +2", rarity = "uncommon",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.dealer_total == 17 then return { mult = 2 } end end },
    { id = "steal_money",    name = "偷金之手", desc = "激活后：庄家爆牌 最终 ×1.2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.dealer_bust then return { x_mult = 1.2 } end end },
    { id = "dealer_fatigue", name = "庄家疲劳", desc = "庄家点数 ≥ 17 时停止（经典是软 17 继续）", rarity = "rare",      auto_active = true, triggers = {"on_dealer_turn"}, effect = function(ctx) ctx.force_dealer_stand_on_soft_17 = true end },
    { id = "dealer_magnet",  name = "庄家磁铁", desc = "激活后：庄家要牌时有 55% 概率摸到 2~6 的爆牌牌", rarity = "legendary",      triggers = {"on_dealer_hit"}, effect = function(ctx)
          local r = love.math.random()
          if r < 0.55 then
              local lowCards = {2,3,4,5,6}; ctx.force_dealer_draw = lowCards[love.math.random(5)]
          end end },

    -- ========================================
    -- Hit 安全 / 爆牌防护（全是 in-game 触发，玩家可选时机 → 去掉 auto_active）
    -- ========================================
    { id = "first_hit_safe", name = "第一次 Hit 安全", desc = "激活后：本小局你的第一次要牌不会爆牌（剩余 3 次）", rarity = "rare",      _consumable = true, _usesLeft = 3,
      triggers = {"on_hit"}, effect = function(ctx) if ctx.is_first_hit then ctx.safe_hit = true end end },
    { id = "bust_shield",    name = "爆牌护盾", desc = "激活后：本小局你爆牌时改判为平局（退还下注，剩余 3 次）", rarity = "legendary",      _consumable = true, _usesLeft = 3,
      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.player_bust and not ctx._bust_shielded then
          ctx._bust_shielded = true
          ctx.player_bust = false
          ctx.result = "push"
          return true   -- 消耗判定靠返回值：改的是 player_bust/result，ctx 检测认不出（修复不扣次 bug）
      end end },
    { id = "soft_22_safe",   name = "软爆护盾", desc = "激活后：你的 22 点不算爆，按正常规则与庄家比大小（剩余 3 次）", rarity = "rare",      _consumable = true, _usesLeft = 3,
      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.player_total == 22 then ctx.become_bust = false end end },
    { id = "soft_bust_shield", name = "软爆护盾 v2", desc = "激活后：你的 22 点直接判赢（剩余 3 次）", rarity = "legendary",      _consumable = true, _usesLeft = 3,
      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.player_total == 22 then ctx.force_win = true end end },

    -- ========================================
    -- 规则扭曲（倍率类涨价+升稀有度）
    -- ========================================
    { id = "push_king",      name = "平局之王", desc = "激活后：平局时 倍率 +2 且 筹码 +300", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.result == "push" then return { chips = 300, mult = 2 } end end },
    { id = "push_as_win",    name = "平局即胜", desc = "激活后：平局判为玩家赢", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.result == "push" then ctx.result = "player" end end },
    { id = "dealer_22_push", name = "庄家 22 平局", desc = "庄家恰好 22 点算平局", rarity = "rare",      auto_active = true, triggers = {"on_score_calc"}, effect = function(ctx) if ctx.dealer_total == 22 and ctx.player_total <= 21 then ctx.result = "push" end end },
    { id = "insurance_master",name = "保险大师", desc = "输了庄家明 A 时只输一半", rarity = "rare",      auto_active = true, triggers = {"on_score_calc"}, effect = function(ctx) if ctx.dealer_first_face == 'A' and ctx.result == "dealer" then ctx.half_loss = true end end },

    -- ========================================
    -- 下注/筹码倍率类
    -- ========================================
    { id = "bet_syndicate",  name = "下注集团", desc = "每局下注自动翻倍", rarity = "rare",      triggers = {"on_bet"}, effect = function(ctx)
          local g = ctx.game
          if g and g.player and g.player.bet and g.player.chips >= g.player.bet then
              g.player.chips = g.player.chips + g.player.bet
              g.player.bet = g.player.bet * 2
              g.player.chips = g.player.chips - g.player.bet
          end end },
    { id = "chip_magnet",    name = "筹码磁铁", desc = "激活后：赢时最终 ×1.3", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.result == "player" then return { x_mult = 1.3 } end end },
    { id = "bet_minimizer",  name = "最小下注者", desc = "强制下注 $50（每局都安全）", rarity = "uncommon",      triggers = {"on_bet"}, effect = function(ctx)
          local g = ctx.game
          if g and g.player and g.player.bet and g.player.bet > 50 then
              g.player.chips = g.player.chips + g.player.bet - 50
              g.player.bet = 50
          end end },

    -- ========================================
    -- 连胜/阶段
    -- ========================================
    { id = "streak_master",  name = "连胜之王", desc = "激活后：连胜 ≥ 3 时 最终 ×3", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.streak and ctx.streak >= 3 then return { x_mult = 3 } end end },
    { id = "streak_hammer",  name = "连胜铁锤", desc = "激活后：连胜 ≥ 2 时 倍率 +（当前连胜数）", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if ctx.streak and ctx.streak >= 2 then return { mult = ctx.streak } end end },
    { id = "stage_survivor", name = "阶段幸存者", desc = "阶段完成时额外奖励 $2000", rarity = "rare",      triggers = {"on_stage_clear"}, effect = function(ctx) ctx.game.player.chips = ctx.game.player.chips + 2000 end },
    { id = "debt_collector", name = "债务收藏家", desc = "每阶段开始时借你 $5000 筹码，但你输掉一局时会先扣掉这笔债", rarity = "uncommon",      triggers = {"on_stage_start"}, effect = function(ctx)
          ctx.game.player.chips = ctx.game.player.chips + 5000
          ctx.game.debt = (ctx.game.debt or 0) + 5000 end },

    -- ========================================
    -- 特殊/游戏改变者
    -- ========================================
    -- 后期投降：不是 on_score_calc 效果，而是"玩家回合的可选动作"
    -- 激活后：玩家手牌小于 18 点时可按 [U] 投降，退回一半下注（实现见 GameState.surrenderPlayer）
    { id = "late_surrender", name = "后期投降", desc = "激活后：你点数小于 18 时可按 [U] 投降，退回一半下注", rarity = "rare" },
    { id = "clockwork_dragon",name = "发条龙", desc = "激活后：手牌同时有 A 与 10 点牌（10/J/Q/K）且非自然 21 时 最终 ×10", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          local hasA, has10 = false, false
          for _, c in ipairs(ctx.player_hand or {}) do
              if c.rank == 'A' then hasA = true end
              if c.rank == 10 or c.rank == 'J' or c.rank == 'Q' or c.rank == 'K' then has10 = true end
          end
          if hasA and has10 and not ctx.is_blackjack then return { x_mult = 10 } end end },

    -- ========================================
    -- 阶段感知 / 后期加强
    -- ========================================
    { id = "stage_champion", name = "阶段冠军", desc = "激活后：阶段 3 时，最终 ×1.5", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) if (ctx.game and ctx.game.stage or 1) >= 3 then return { x_mult = 1.5 } end end },
    { id = "anti_cheat",     name = "反侦察器", desc = "激活后：阶段 3 时，庄家不会看你的牌", rarity = "legendary",      triggers = {"on_dealer_turn"}, effect = function(ctx)
          if (ctx.game and ctx.game.stage or 1) >= 3 then ctx.blind_dealer = true end end },
    { id = "dealer_blind",   name = "庄家致盲", desc = "庄家看不到你的第二张牌（经典难度）", rarity = "rare",      auto_active = true, triggers = {"on_dealer_turn"}, effect = function(ctx) ctx.force_dealer_difficulty = 1 end },
    { id = "all_in_master",  name = "全押大师", desc = "激活后：全押（下注 = 全部筹码）且赢时 最终 ×3", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.game and ctx.game.player and ctx.bet and ctx.result == "player" then
              local total = ctx.game.player.chips + ctx.bet   -- 下注前筹码
              if total > 0 and ctx.bet >= total then
                  return { x_mult = 3 }
              end
          end end },

    -- ========================================
    -- 特殊 21 点牌型扩展
    -- ========================================
    { id = "double_seven",   name = "双七", desc = "激活后：手牌有 2 张 7 时 倍率 +15", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          local cnt = 0
          for _, c in ipairs(ctx.player_hand or {}) do if c.rank == 7 then cnt = cnt + 1 end end
          if cnt >= 2 then return { mult = 15 } end end },
    { id = "rainbow_21",     name = "彩虹 21", desc = "激活后：恰好 21 点且四种花色齐全时 最终 ×2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.player_total ~= 21 then return end
          local suits = {}
          for _, c in ipairs(ctx.player_hand or {}) do suits[c.suit] = true end
          local count = 0
          for _ in pairs(suits) do count = count + 1 end
          if count >= 4 then return { x_mult = 2 } end end },

    -- ========================================
    -- 强力基础倍率（涨价+升稀有度）
    -- ========================================
    { id = "super_mult",     name = "超级倍率", desc = "激活后：每局倍率 +3", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx) return { mult = 3 } end },

    -- ========================================
    -- 牌堆干预
    -- ========================================
    { id = "deck_weight_low",name = "低牌加重", desc = "发牌时你的前两张优先抽 2-6（更容易拿到低牌）", rarity = "uncommon",      triggers = {"on_deal"}, effect = function(ctx) ctx.weight_low = true end },
    { id = "deck_weight_high",name = "高牌加重", desc = "发牌时你的前两张优先抽 10/J/Q/K/A（更容易拿到高牌）", rarity = "uncommon",      triggers = {"on_deal"}, effect = function(ctx) ctx.weight_high = true end },
    { id = "second_ace",     name = "第二张 A", desc = "发牌后，第二张有 40% 概率变成 A", rarity = "rare",      triggers = {"on_deal_after"}, effect = function(ctx)
          local g = ctx.game
          if g and g.player and g.player.hand and #g.player.hand >= 2 and love.math.random() < 0.4 then
              g.player.hand[2] = { rank = 'A', suit = '♣', faceUp = true }
          end end },
    { id = "no_face_dealer", name = "庄家无面", desc = "激活后：庄家摸到 J/Q/K 时自动换成 10", rarity = "legendary",      triggers = {"on_dealer_hit"}, effect = function(ctx)
          local lastDealer = ctx.game and ctx.game.dealer and ctx.game.dealer.hand
          if lastDealer and #lastDealer > 0 then
              local last = lastDealer[#lastDealer]
              if last and (last.rank == 'J' or last.rank == 'Q' or last.rank == 'K') then
                  last.rank = 10
              end
          end end },

    -- ========================================
    -- 更容易接近 21（非倍率类保留原价）
    -- ========================================
    { id = "always_10_on_third", name = "第三张必10", desc = "激活后：你的第三张牌总是 10", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          local hand = ctx.game and ctx.game.player and ctx.game.player.hand
          if hand and #hand == 2 then
              ctx.force_draw_card = { rank = 10, suit = '♣', faceUp = true }
          end end },
    { id = "auto_surrender_16", name = "16自动停牌", desc = "激活后：你点数 ≥ 16 时，要牌会自动改为停牌（不再抽牌）", rarity = "uncommon",      triggers = {"on_hit"}, effect = function(ctx)
          local g = ctx.game; if not g or not g.player then return end
          local h = g.player.hand
          if h and #h >= 2 then
              local Blackjack = require("src.blackjack")
              local total = Blackjack.calculateHand(h)
              if total >= 16 then ctx.stop_auto = true end
          end end },
    { id = "peek_and_chase", name = "牌堆追踪", desc = "激活后：每次要牌有 30% 概率直接给你一张 10", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          if love.math.random() < 0.3 then
              ctx.force_draw_card = { rank = 10, suit = '♠', faceUp = true }
          end end },
    { id = "soft_hand_magnet", name = "软手磁铁", desc = "激活后：每次要牌有 25% 概率给你一张 A", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          if love.math.random() < 0.25 then
              ctx.force_draw_card = { rank = 'A', suit = '♥', faceUp = true }
          end end },
    { id = "hit_to_20", name = "凑20为止", desc = "激活后：你点数 < 20 且手牌 ≤ 3 张时，要牌自动给你一张凑到 20 的牌", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          local g = ctx.game; if not g or not g.player then return end
          local h = g.player.hand; if not h or #h < 2 then return end
          local Blackjack = require("src.blackjack")
          local t = Blackjack.calculateHand(h)
          if t < 20 and #h <= 3 then
              local need = 20 - t
              if need == 1 then need = 'A'
              elseif need > 11 then need = 10 end
              ctx.force_draw_card = { rank = need, suit = '♦', faceUp = true }
          end end },
    { id = "last_card_save", name = "最后一张救命", desc = "激活后：你要牌会爆时，自动改成给你一张不超过 21 的安全牌（剩余 3 次）", rarity = "legendary",      _consumable = true, _usesLeft = 3,
      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          local g = ctx.game; if not g then return end
          local h = g.player and g.player.hand
          if not h or #h < 2 then return end
          local Blackjack = require("src.blackjack")
          local current = Blackjack.calculateHand(h)
          -- 描述以"抽牌会爆时"为准：先看牌堆顶，会爆才干预
          local top = g.deck and g.deck:peek(1)
          local topCard = top and top[1]
          if not topCard then return end
          if current + Blackjack.cardValue(topCard) <= 21 then return end
          local need = 21 - current
          if need <= 0 then return end        -- 已经 21（无安全牌可给）→ 不干预、不扣次
          local give = need
          if need == 1 then give = 'A'
          elseif need >= 10 then give = 10 end
          ctx.force_draw_card = { rank = give, suit = '♣', faceUp = true }
          ctx._give_card_triggered = true
      end },
    { id = "pair_to_21", name = "对子凑21", desc = "激活后：手牌有对子时，要牌自动给你一张尽量凑到 21 的牌（点数太低时只加 10）", rarity = "rare",      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          local h = ctx.game and ctx.game.player and ctx.game.player.hand
          if not h or #h < 2 then return end
          local hasPair = false
          for i = 1, #h do for j = i+1, #h do if h[i].rank == h[j].rank then hasPair = true break end end end
          if hasPair then
              local Blackjack = require("src.blackjack")
              local t = Blackjack.calculateHand(h)
              if t < 21 then
                  local need = 21 - t
                  if need == 1 then need = 'A'
                  elseif need > 11 then need = 10 end
                  ctx.force_draw_card = { rank = need, suit = '♣', faceUp = true }
              end
          end end },
    { id = "eight_ball", name = "八球幸运", desc = "激活后：手牌有 8 时，下次要牌必给 10", rarity = "uncommon",      triggers = {"on_hit"}, effect = function(ctx)
          if ctx.force_draw_card then return end
          local h = ctx.game and ctx.game.player and ctx.game.player.hand
          if h then for _, c in ipairs(h) do if c.rank == 8 then
              ctx.force_draw_card = { rank = 10, suit = '♠', faceUp = true }; break end end end end },
    { id = "low_buff", name = "低牌buff", desc = "激活后：手牌有 3/4/5 时 倍率 +2", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          local h = ctx.player_hand or {}
          local has = false
          for _, c in ipairs(h) do local v = tonumber(c.rank) if v and v >= 3 and v <= 5 then has = true break end end
          if has then return { mult = 2 } end end },
    { id = "jackpot_two", name = "JQK配对", desc = "发牌后，如果第一张是 J/Q/K，第二张也给你 J/Q/K", rarity = "rare",      triggers = {"on_deal_after"}, effect = function(ctx)
          local g = ctx.game; if not g or not g.player then return end
          local hand = g.player.hand
          local first = hand and hand[1]
          if first and (first.rank == 'J' or first.rank == 'Q' or first.rank == 'K') then
              if hand[2] then
                  local faces = {'J', 'Q', 'K'}
                  hand[2] = { rank = faces[love.math.random(3)], suit = '♥', faceUp = true }
              end
          end end },

    -- ========================================
    -- 出千配合系（替换原「凑具体数给奖励」组 —— 特定点数触发效果太隐晦）
    -- 套路：墨水大盗（减费）→ 千门人脉（扩容）→ 老千世家（发现保险）→
    --     对冲基金（爆注对冲）→ 铁证如山（指认加倍）→ 过目不忘（窥视+1）
    -- 除千门人脉（常驻被动无消耗点）外，其余均限 3 次（可铸造永久化）
    -- ========================================
    { id = "cheat_consort", name = "千门人脉", desc = "持有：墨水标记上限 +2（5 → 7 张）。台子里总有人肯替你兜东西。", rarity = "legendary",      auto_active = true },
    { id = "sharp_family", name = "老千世家", desc = "持有：墨水牌被发现时罚金减半，且 50% 概率保住标记。共 3 次（每次庇护消耗 1 次，可铸造永久）。", rarity = "rare",      auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "hedge_fund", name = "对冲基金", desc = "持有：爆注未中返还一半注；命中时彩金再 ×1.25。共 3 次（每次爆注结算消耗 1 次，可铸造永久）。", rarity = "legendary",      auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "iron_evidence", name = "铁证如山", desc = "持有：指认成功奖金从 3 倍下注提升至 5 倍下注。共 3 次（每次指认命中消耗 1 次，可铸造永久）。", rarity = "rare",      auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "ace_and_ten_exact", name = "精准12", desc = "激活后：点数恰好 12（A 算 1）时 倍率 +20", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.player_total == 12 and not ctx.is_blackjack then return { mult = 20 } end end },
    { id = "fives_15", name = "三个5", desc = "激活后：手牌有 3 张或更多 5 时 倍率 +30", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          local cnt = 0
          for _, c in ipairs(ctx.player_hand or {}) do if c.rank == 5 then cnt = cnt + 1 end end
          if cnt >= 3 then return { mult = 30 } end end },
    { id = "mind_memory", name = "过目不忘", desc = "持有：点亮窥牌遗物时窥视深度额外 +1；算牌师的每局自动窥视也 +1。共 3 局（每小局消耗 1 次，可铸造永久）。", rarity = "legendary",      auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "dealer_mirror_17", name = "庄家跟牌", desc = "激活后：你的点数等于庄家明牌点数时 倍率 +3", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.dealer_first_face then
              local dft = ctx.dealer_first_face
              if dft == 'A' then dft = 11
              elseif dft == 'J' or dft == 'Q' or dft == 'K' then dft = 10
              else dft = tonumber(dft) or 0
              end
              if ctx.player_total == dft then return { mult = 3 } end
          end end },

    -- ========================================
    -- 反作弊（5 基础 + 3 扩展 — 全部涨价）
    -- ========================================
    -- 作弊之眼：旧效果「把 visualTell 置真」在新规则下已是全局默认行为（痕迹本就必现），
    -- 故并入「作弊探测器」语义 —— 阶段 2+ 抑制干扰项，看到的痕迹一定为真
    { id = "cheat_eye", name = "作弊之眼", desc = "阶段2+时，干扰项不再出现（看到的痕迹一定为真）", rarity = "rare",      triggers = {"on_deal"}, effect = function(ctx)
          local g = ctx.game
          if g and g.stage and g.stage >= 2 then
              g._probeActive = true
          end end },
    { id = "cheat_buster_1", name = "作弊克星", desc = "庄家作弊时，强制庄家爆牌", rarity = "legendary",      auto_active = true, triggers = {"on_dealer_turn"}, effect = function(ctx)
          local g = ctx.game; if not g or not g.cheatState or not g.cheatState.isCheating then return end
          ctx.force_dealer_cheat_bust = true end },
    { id = "cheat_reverse", name = "反作弊器", desc = "指认猜对时，额外获得 3 倍下注的筹码", rarity = "legendary",      auto_active = true, triggers = {"on_accuse"}, effect = function(ctx)
          if ctx.was_cheating then
              local g = ctx.game
              if g and g.player then
                  local add = g.player.bet * 3
                  g.player.chips = g.player.chips + add
                  if love and love.graphics then
                      local w, h = love.graphics.getWidth(), love.graphics.getHeight()
                      table.insert(g.scorePopups, {
                          text = "反作弊翻倍! +$" .. add,
                          x = w / 2, y = h / 2 - 150,
                          t = 0, life = 2.5,
                          color = {1, 1, 0.2}, scale = 1.8
                      })
                  end
              end
          end end },
    -- 新增反作弊扩展
    -- 作弊探测器（重定义）：旧效果「阶段2+时把 visualTell 置真」在新规则下已是全局默认，
    -- 故改为「抑制干扰项」——阶段 2+ 你看到的痕迹一定为真，但不会告诉你庄家是否作弊
    { id = "cheat_probe", name = "作弊探测器", desc = "阶段2+时，干扰项不再出现（看到的痕迹一定为真）", rarity = "uncommon",      triggers = {"on_deal"}, effect = function(ctx)
          local g = ctx.game
          if g and g.stage and g.stage >= 2 then
              g._probeActive = true
          end end },
    { id = "cheat_sniffer", name = "识破大师", desc = "激活后：指认猜对时，额外获得 5 倍下注的筹码", rarity = "legendary",      triggers = {"on_accuse"}, effect = function(ctx)
          if ctx.was_cheating then
              local g = ctx.game
              if g and g.player then
                  local add = g.player.bet * 5
                  g.player.chips = g.player.chips + add
                  if love and love.graphics then
                      local w, h = love.graphics.getWidth(), love.graphics.getHeight()
                      table.insert(g.scorePopups, {
                          text = "识破大师! +$" .. add,
                          x = w / 2, y = h / 2 - 150,
                          t = 0, life = 2.5,
                          color = {0.3, 1, 0.3}, scale = 2
                      })
                  end
              end
          end end },
    { id = "cheat_trap", name = "反作弊陷阱", desc = "激活后：指认猜对后，下一局自动替你停牌（不保证赢）", rarity = "rare",      triggers = {"on_accuse"}, effect = function(ctx)
          if ctx.was_cheating then
              local g = ctx.game
              if g then g.autoStandNextRound = true end
          end end },
    { id = "cheat_fear", name = "庄家恐惧症", desc = "阶段 3 的庄家作弊概率减半（45% → 22%）", rarity = "legendary",      triggers = {"on_game_start", "on_stage_start"}, effect = function(ctx)
          local g = ctx.game
          if g and g.cheatChance and g.cheatChance[3] then
              local base = (g.cheatChanceBase and g.cheatChanceBase[3]) or 0.45
              g.cheatChance[3] = base * 0.5   -- 幂等：只减半一次，不随阶段/周目累积
          end end },
    { id = "scales_of_justice", name = "公平之秤", desc = "激活后：指认猜对时，额外获得 2 倍下注的筹码", rarity = "legendary",      triggers = {"on_accuse"}, effect = function(ctx)
          if ctx.was_cheating then
              local g = ctx.game
              if g and g.player then
                  local add = g.player.bet * 2
                  g.player.chips = g.player.chips + add
              end
          end end },

    -- ========================================
    -- 下注倍率组（根据下注多少调整倍率）
    -- ========================================
    { id = "conservative_bet", name = "保守策略", desc = "激活后：下注 ≤ $100 且赢时 倍率 +3", rarity = "uncommon",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.bet and ctx.bet <= 100 and ctx.result == "player" then return { mult = 3 } end end },
    { id = "balanced_bet", name = "平衡策略", desc = "激活后：下注 $200 ~ $500 且赢时 倍率 +5", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.bet and ctx.bet >= 200 and ctx.bet <= 500 and ctx.result == "player" then return { mult = 5 } end end },
    { id = "aggressive_bet", name = "豪赌策略", desc = "激活后：下注 ≥ $500 且赢时 最终 ×1.5", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.bet and ctx.bet >= 500 and ctx.result == "player" then return { x_mult = 1.5 } end end },
    { id = "all_in_fanatic", name = "全押狂魔", desc = "激活后：下注 ≥ 80% 筹码且赢时 最终 ×2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.game and ctx.game.player and ctx.bet and ctx.result == "player" then
              local total = ctx.game.player.chips + ctx.bet
              if total > 0 and ctx.bet / total >= 0.8 then
                  return { x_mult = 2 }
              end
          end end },
    { id = "small_bet_master", name = "小额大师", desc = "激活后：下注刚好 $50 且赢时 倍率 +4 且 筹码 +1000", rarity = "rare",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.bet == 50 and ctx.result == "player" then return { mult = 4, chips = 1000 } end end },
    { id = "bet_sniper", name = "下注狙击手", desc = "激活后：下注 ≥ 筹码一半且赢时 最终 ×2", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.game and ctx.game.player and ctx.bet and ctx.result == "player" then
              local total = ctx.game.player.chips + ctx.bet
              if total > 0 and ctx.bet / total >= 0.5 then
                  return { x_mult = 2 }
              end
          end end },

    -- ========================================
    -- 赊账下注组（可以下注超过现有筹码，但输了直接负数 → 游戏结束）
    -- ========================================
    { id = "credit_line", name = "信用额度", desc = "允许下注超出筹码！上限 = 筹码的 3 倍。输了变负立即退出！", rarity = "legendary",      triggers = {"on_bet"}, effect = function(ctx) end },  -- placeBet 里直接检测 id
    { id = "all_in_fanatic_rel", name = "赌徒信条", desc = "允许下注超出筹码！上限 = 筹码的 4 倍。输了变负立即退出！", rarity = "legendary",      triggers = {"on_bet"}, effect = function(ctx) end },
    { id = "high_roller", name = "豪客特权", desc = "允许下注超出筹码！额外 +$5000 赊账额度。输了变负立即退出！", rarity = "legendary",      triggers = {"on_bet"}, effect = function(ctx) end },
    { id = "debt_collector_pro", name = "债主代理人", desc = "激活后：下注超出自己筹码且赢时 最终 ×1.5", rarity = "legendary",      triggers = {"on_score_calc"}, effect = function(ctx)
          if ctx.game and ctx.game.player and ctx.bet and ctx.result == "player" then
              local ownChips = ctx.game.player.chips + ctx.bet  -- 下注前筹码
              if ctx.bet > ownChips then
                  -- 赢了，但下注时用了赊账
                  return { x_mult = 1.5 }
              end
          end end },

    -- ========================================
    -- 牌靴情报组（BlackJacky「赌信息」玩法 v1）
    --  窥视类：点亮即看穿接下来 N 张；焚牌类：把不确定性烧进弃牌堆
    --  点亮即生效的遗物无 triggers，由 GameState.toggleRelicActive 派发
    -- ========================================
    { id = "peek_1", name = "窥牌 · 壹", desc = "点亮后：本轮牌靴情报里亮明接下来 1 张牌。（每小局重新点亮，可用 3 次）", rarity = "uncommon",      _consumable = true, _usesLeft = 3 },
    { id = "peek_2", name = "窥牌 · 贰", desc = "点亮后：本轮牌靴情报里亮明接下来 2 张牌。（每小局重新点亮，可用 3 次）", rarity = "rare",      _consumable = true, _usesLeft = 3 },
    { id = "peek_3", name = "天眼通", desc = "点亮后：本轮牌靴情报里亮明接下来 3 张牌。（每小局重新点亮，可用 3 次）", rarity = "legendary",      _consumable = true, _usesLeft = 3 },
    { id = "peek_auto", name = "算牌师", desc = "自动：每小局开始时自动亮明接下来 1 张牌。可用 3 次。", rarity = "rare",      auto_active = true, _consumable = true, _usesLeft = 3, triggers = { "on_round_start" },
      effect = function(ctx)
          local g = ctx.game
          g._shoePeek = math.max(g._shoePeek or 0, 1)
      end },
    { id = "burn_1", name = "焚牌术", desc = "点亮即把牌靴顶 1 张烧进弃牌堆（不亮明，直接烧掉——减少不确定性也是情报）。可用 3 次。", rarity = "uncommon",      _consumable = true, _usesLeft = 3 },
    { id = "burn_3", name = "炼狱焚堆", desc = "点亮即把牌靴顶 3 张烧进弃牌堆（不亮明，直接烧掉）。可用 2 次。", rarity = "rare",      _consumable = true, _usesLeft = 2 },
    { id = "far_sight", name = "千里眼", desc = "点亮后：本轮牌靴情报里亮明接下来 5 张牌。（每小局重新点亮，可用 3 次）", rarity = "legendary",      _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 特殊标记组（商店售卖 · 白底色点图标 · 各 3 次 · 每回合限 1 次）
    -- 购买后不占遗物栏 5 格：存入 state.specialMarks，遗物栏下方有专属展示区。
    -- 一次只能持有一枚特种标记：新获得的直接替换旧持有的（含重复购买同一款）。
    -- 特种标记仅限本周目内有效，新开游戏时清空。
    -- 持有期间标记动作被替换为对应特殊标记；次数用尽自动回到普通墨水标记。
    -- 特殊标记不会被庄家发现（发现判定只针对墨水标记）。
    -- ========================================
    { id = "mark_vanish", name = "消失标记", desc = "持有期间：标记动作改为「消失标记」（灰点）——这张牌被你要到时如同不存在般消失，你转而摸下一张。共 3 次，每回合限 1 次。", rarity = "rare", price = 1000,
      markDot = { 0.75, 0.75, 0.80 }, _consumable = true, _usesLeft = 3 },
    { id = "mark_flame", name = "火焰标记", desc = "持有期间：标记动作改为「火焰标记」（金点）——庄家无法要这张牌；庄家的下一张若是火焰牌只能停牌。共 3 次，每回合限 1 次。", rarity = "rare", price = 1500,
      markDot = { 1, 0.85, 0 }, _consumable = true, _usesLeft = 3 },
    { id = "mark_bounty", name = "赏金标记", desc = "持有期间：标记动作改为「赏金标记」（绿点）——庄家要这张牌时你立刻获得 $500 赏金。共 3 次，每回合限 1 次。", rarity = "rare", price = 2000,
      markDot = { 0.2, 0.9, 0.3 }, _consumable = true, _usesLeft = 3 },
    { id = "mark_void", name = "虚空标记", desc = "持有期间：标记动作改为「虚空标记」（紫点）——标记的瞬间立刻吸收它前面那张牌及其词条（继承倍率与特性，黑洞效果；前面没牌则不消耗次数）。共 3 次，每回合限 1 次。", rarity = "rare", price = 2500,
      markDot = { 0.6, 0.3, 0.95 }, _consumable = true, _usesLeft = 3 },
    { id = "mark_bomb", name = "爆炸标记", desc = "持有期间：标记动作改为「爆炸标记」（红点）——这张牌被任何人摸到时，炸掉其后 2 张牌（移入弃牌堆）。共 3 次，每回合限 1 次。", rarity = "rare", price = 3000,
      markDot = { 0.95, 0.15, 0.15 }, _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 钓具组（点亮使用 · 改变已标记牌在牌库中的位置 · 每回合限 1 次 · 各 3 次）
    -- 点选型（rod = standard/deep/trawl/swap）：点亮后打开情报界面，在顺序带点已标记的牌为目标
    -- 即发型（rod = golden/rogue/lost）：点亮立即生效
    -- 可被铸造永久化（_consumable）
    -- ========================================
    { id = "rod_standard", name = "标准钓具", desc = "点亮后打开情报界面：选择一张已标记的牌，把它钓到牌库第一张。每回合限 1 次，可用 3 次。", rarity = "rare", price = 1500,      rod = "standard", _consumable = true, _usesLeft = 3 },
    { id = "rod_deep", name = "深海钓具", desc = "点亮后打开情报界面：选择一张已标记的牌，把它沉到牌库最底。每回合限 1 次，可用 3 次。", rarity = "uncommon", price = 600,      rod = "deep", _consumable = true, _usesLeft = 3 },
    { id = "rod_trawl", name = "拖钓钓具", desc = "点亮后打开情报界面：选择一张已标记的牌，向牌顶方向拖 3 张（已近顶则到顶）。每回合限 1 次，可用 3 次。", rarity = "uncommon", price = 800,      rod = "trawl", _consumable = true, _usesLeft = 3 },
    { id = "rod_swap", name = "换位钓具", desc = "点亮后打开情报界面：依次点击两张已标记的牌，交换它们在牌库中的位置。每回合限 1 次，可用 3 次。", rarity = "rare", price = 1200,      rod = "swap", _consumable = true, _usesLeft = 3 },
    { id = "rod_golden", name = "黄金钓具", desc = "点亮即发动：把牌库中所有已标记的牌按标记顺序钓到顶层依次排列。每回合限 1 次，可用 3 次。", rarity = "legendary", price = 3500,      rod = "golden", _consumable = true, _usesLeft = 3 },
    { id = "rod_rogue", name = "失控钓具", desc = "点亮即发动：所有已标记的牌（含玩家/庄家手上与弃牌堆中的）被随机抛回牌库各处。每回合限 1 次，可用 3 次。", rarity = "rare", price = 1000,      rod = "rogue", _consumable = true, _usesLeft = 3 },
    { id = "rod_lost", name = "遗弃钓具", desc = "点亮即发动：把弃牌堆所有已标记的牌钓回牌库顶层（越晚弃的越靠顶）。每回合限 1 次，可用 3 次。", rarity = "rare", price = 1800,      rod = "lost", _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 揭示组（点亮即亮明特定位置 · 本小局有效 · 各 3 次）
    -- 位置超出顺序带首屏时用滚轮/方向键后拉查看
    -- ========================================
    { id = "reveal_12", name = "揭示 · 一二", desc = "点亮后打开情报界面：本回合亮明牌库第 1、2 张。可用 3 次。", rarity = "uncommon", price = 500,      reveal = { { 1, 2 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_34", name = "揭示 · 三四", desc = "点亮后打开情报界面：本回合亮明牌库第 3、4 张。可用 3 次。", rarity = "uncommon", price = 500,      reveal = { { 3, 4 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_56", name = "揭示 · 五六", desc = "点亮后打开情报界面：本回合亮明牌库第 5、6 张。可用 3 次。", rarity = "uncommon", price = 700,      reveal = { { 5, 6 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_78", name = "揭示 · 七八", desc = "点亮后打开情报界面：本回合亮明牌库第 7、8 张。可用 3 次。", rarity = "uncommon", price = 700,      reveal = { { 7, 8 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_123", name = "揭示 · 一二三", desc = "点亮后打开情报界面：本回合亮明牌库第 1 至 3 张。可用 3 次。", rarity = "rare", price = 900,      reveal = { { 1, 3 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_345", name = "揭示 · 三四五", desc = "点亮后打开情报界面：本回合亮明牌库第 3 至 5 张。可用 3 次。", rarity = "rare", price = 900,      reveal = { { 3, 5 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_456", name = "揭示 · 四五六", desc = "点亮后打开情报界面：本回合亮明牌库第 4 至 6 张。可用 3 次。", rarity = "rare", price = 1000,      reveal = { { 4, 6 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_10_20", name = "揭示 · 十到二十", desc = "点亮后打开情报界面：本回合亮明牌库第 10 至 20 张（滚轮后拉查看）。可用 3 次。", rarity = "legendary", price = 1800,      reveal = { { 10, 20 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_20_30", name = "揭示 · 二十到三十", desc = "点亮后打开情报界面：本回合亮明牌库第 20 至 30 张（滚轮后拉查看）。可用 3 次。", rarity = "legendary", price = 1500,      reveal = { { 20, 30 } }, _consumable = true, _usesLeft = 3 },
    { id = "reveal_15", name = "揭示 · 前五张", desc = "点亮后打开情报界面：本回合亮明牌库第 1 至 5 张。可用 3 次。", rarity = "legendary", price = 2500,      reveal = { { 1, 5 } }, _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 弃牌堆组（围绕弃牌堆的主动道具 · 各 3 次）
    -- ========================================
    { id = "discard_salvager", name = "打捞", desc = "激活后打开情报界面（弃牌堆页签）：点击弃牌堆的一张牌，下次要牌改为把这张牌打出（照常结算与触发标记）。可用 3 次。", rarity = "rare", price = 1800,      discardTool = "salvage", _consumable = true, _usesLeft = 3 },
    { id = "discard_backflow", name = "回流", desc = "点亮即发动：把弃牌堆最近弃掉的 3 张按原顺序放回牌库顶。可用 3 次。", rarity = "uncommon", price = 900,      discardTool = "backflow", _consumable = true, _usesLeft = 3 },
    { id = "discard_rinse", name = "淘洗", desc = "点亮即发动：把整个弃牌堆洗回牌库，并随机切牌一次。弃牌堆为空时不消耗次数。可用 3 次。", rarity = "common", price = 500,      discardTool = "rinse", _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 显影墨水（标记配合 · 持有期生效 · 3 次）
    --   持有期间：在情报面板标记牌库里的牌时，这张牌立刻亮明（本就公开的牌不消耗次数）。
    --   扣次点：tryMarkCard 的 revealMarkedCard。
    -- ========================================
    { id = "reveal_ink", name = "显影墨水", desc = "持有：在情报中标记的同时，立刻亮明被标记的那张牌（本就公开的牌不消耗）。共 3 次。", rarity = "rare", price = 800,
      markFlip = true, auto_active = true, _consumable = true, _usesLeft = 3 },

    -- ========================================
    -- 职阶残卷组（七职阶的弱化仿制品 · 商店售卖 · 各 3 次 · 仅本小局生效）
    --   点亮型（下注前/玩家回合点亮，点亮即扣次）：枪（发三张）/ 弓（首张预览）/
    --   杀（庄家失明）/ 骑（本局跳过一次）——实现读 relic.active（dealInitial / skipRound）
    --   触发型（点亮后结算时生效，真实生效才扣次）：剑（斩庄家最小牌，走 endRound
    --   斩击动画路径）/ 狂（25 点宽容+胜判定，on_score_calc force_win）
    --   被动型：术（连胜 3 局 → 三选一替换本遗物自身，_doScoring 触发 openShardOffer）
    --   classShard 标记：点亮即扣次 + 开局三选一排除（shopOnly 语义）
    -- ========================================
    { id = "class_rider_shard", name = "骑之残卷", desc = "点亮后：本小局按 [R] 可跳过一次（下注归还）。点亮即消耗 1 次。共 3 次。", rarity = "uncommon", price = 600,
      classShard = true, _consumable = true, _usesLeft = 3 },
    { id = "class_archer_shard", name = "弓之残卷", desc = "点亮后（下注前点）：本小局发牌时预览你的第一张牌。点亮即消耗 1 次。共 3 次。", rarity = "uncommon", price = 800,
      classShard = true, _consumable = true, _usesLeft = 3 },
    { id = "class_lancer_shard", name = "枪之残卷", desc = "点亮后（下注前点）：本小局开局发三张（第三张保证不爆 21）。点亮即消耗 1 次。共 3 次。", rarity = "rare", price = 1200,
      classShard = true, _consumable = true, _usesLeft = 3 },
    { id = "class_assassin_shard", name = "杀之残卷", desc = "点亮后：本小局庄家看不到你的牌（看牌类出千直接放弃）。点亮即消耗 1 次。共 3 次。", rarity = "rare", price = 1500,
      classShard = true, _consumable = true, _usesLeft = 3 },
    { id = "class_caster_shard", name = "术之残卷", desc = "持有：连胜 3 局时，从 3 个候选里挑 1 个替换本遗物自身（也可以不换）。每次开启替换消耗 1 次。共 3 次。", rarity = "rare", price = 1800,
      classShard = true, auto_active = true, _consumable = true, _usesLeft = 3 },
    { id = "class_saber_shard", name = "剑之残卷", desc = "点亮后：本小局结算时斩掉庄家点数最小的一张牌（与剑阶不叠加）。真实生效才扣次。共 3 次。", rarity = "legendary", price = 2500,
      classShard = true, _consumable = true, _usesLeft = 3 },
    { id = "class_berserker_shard", name = "狂之残卷", desc = "点亮后：本小局 25 点内不爆牌；未爆且比庄家大直接判胜（与狂阶不叠加）。真实生效才扣次。共 3 次。", rarity = "legendary", price = 2500,
      classShard = true, _consumable = true, _usesLeft = 3,
      triggers = {"on_score_calc"},
      effect = function(ctx)
          if ctx.force_win then return end            -- 67 组合技 / 剑斩等优先
          local pTotal = ctx.player_total
          if pTotal <= 25 and pTotal > 21 then
              ctx.player_bust = false
              if pTotal > ctx.dealer_total then
                  ctx.force_win = true                 -- Phase 2 会按 force_win 重算 baseChips
              end
              return { x_mult = 1 }                    -- 无数值效果；仅作为「已生效」扣次信号
          end
          -- pTotal <= 21 或 > 25：无从庇护 → 不扣次
      end },
}

-- ============================================================
-- POWER_MULT: 倍率遗物 ×2 (用户要求价格翻倍)
-- ============================================================
Relics.POWER_MULT = {
    -- 基础倍率类
    mult_ring = 2.0,
    gold_charm = 2.0,
    divine_blessing = 2.0,
    -- 点数倍率
    perfect_21 = 2.0,
    twentyone_supreme = 2.0,
    blackjack_master = 2.0,
    ace_blessing = 2.0,
    ace_revolution = 2.0,
    -- 牌型倍率
    pair_boost = 2.0,
    flush_master = 2.0,
    -- 庄家相关倍率
    coward_curse = 2.0,
    steal_money = 2.0,
    -- 规则扭曲倍率
    push_king = 2.0,
    push_as_win = 2.0,
    -- 下注倍率
    chip_magnet = 2.0,
    -- 连胜倍率
    streak_master = 2.0,
    streak_hammer = 2.0,
    -- 特殊
    clockwork_dragon = 2.0,
    stage_champion = 2.0,
    rainbow_21 = 2.0,
    super_mult = 2.0,
    all_in_master = 2.0,
    -- 接近21里的倍率
    low_buff = 2.0,
    -- 具体数奖励倍率
    dealer_mirror_17 = 2.0,
    -- 反作弊倍率
    cheat_buster_1 = 2.0,
    cheat_reverse = 2.0,
    cheat_sniffer = 2.0,
    scales_of_justice = 2.0,
    -- 下注倍率组
    conservative_bet = 2.0,
    balanced_bet = 2.0,
    aggressive_bet = 2.0,
    all_in_fanatic = 2.0,
    small_bet_master = 2.0,
    bet_sniper = 2.0,
    -- 赊账相关
    debt_collector_pro = 2.0,  -- 有倍率

    -- 非倍率的强遗物也稍微涨价
    bet_syndicate = 1.3,
    double_seven = 1.3,
    ten_guarantee = 1.3,
    soft_hand_magnet = 1.3,
    hit_to_20 = 1.3,
    pair_to_21 = 1.3,
    last_card_save = 1.3,
    fives_15 = 1.3,
}

-- ========================================
-- 给牌遗物 2-8（7 个，每次 hit 触发，2 次消耗）
-- 点数越小越贵：给8=$100 → 给7=$150 → ... → 给2=$400 (每档 +$50)
-- ========================================
local SUITS = {"♠", "♥", "♦", "♣"}
local _give_ranks = {2, 3, 4, 5, 6, 7, 8}
for idx = 1, #_give_ranks do
    local rank = _give_ranks[idx]   -- Lua 5.1 闭包：每次迭代绑一个局部
    local rankName = tostring(rank)
    local basePrice = 100 + (8 - rank) * 50   -- 8→100, 7→150, 6→200, ..., 2→400
    Relics.LIBRARY[#Relics.LIBRARY + 1] = {
        id = "give_card_" .. rank,
        name = "给牌 · " .. rankName,
        desc = "激活后：下次要牌时强制给 " .. rankName .. " 点（花色随机）。可用 2 次。",
        rarity = "uncommon",
        price = basePrice,   -- 覆盖 rarity 默认定价（给牌点数越小越贵）
        _consumable = true, _usesLeft = 2,
        triggers = {"on_hit"},
        effect = function(ctx)
            if ctx.force_draw_card then return end  -- 已有更高优先级的
            ctx.force_draw_card = {
                rank = rank,
                suit = SUITS[love.math.random(4)],
                faceUp = true,
                value = rank,
                isSpecial = false,
                kind = "normal",
            }
            ctx._give_card_triggered = true
        end,
    }
end

-- 自动注入 price 字段（只补 price==nil 的，已有硬设 price 的不覆盖）
for _, r in ipairs(Relics.LIBRARY) do
    if r.price == nil then
        local base = Relics.PRICES[r.rarity] or 100
        local mult = Relics.POWER_MULT[r.id] or 1.0
        r.price = math.floor(base * mult)
    end
end

-- 永久类遗物（无 _consumable）统一涨价 $1000（2026-09-30 调整：永久保值、消耗品限量）
-- 必须放在默认价注入之后：连同 rarity 默认价一起上浮
for _, r in ipairs(Relics.LIBRARY) do
    if not r._consumable and r.price then
        r.price = r.price + 1000
    end
end

-- Pre-game 事件：在玩家有手牌之前就触发的（不受激活限制）
Relics.PRE_GAME_EVENTS = {
    on_game_start = true,
    on_stage_start = true,
    on_stage_clear = true,
    on_round_start = true,
    on_deal = true,       -- 发牌前/中触发（发牌后玩家才能点）
    on_deal_after = true, -- 玩家开局两张牌发完之后触发
    on_bet = true,        -- 下注阶段触发
}

function Relics.isPreGame(relic)
    if not relic or not relic.triggers then return false end
    for _, ev in ipairs(relic.triggers) do
        if not Relics.PRE_GAME_EVENTS[ev] then
            return false  -- 只要有一个触发是 in-game，就需要激活
        end
    end
    return true
end

-- 阶段动态定价
function Relics.getStagePrice(relic, stage)
    stage = stage or 1
    local stageMult = 1 + (stage - 1) * 0.5   -- stage1=1.0x, stage2=1.5x, stage3=2.0x
    return math.floor(relic.price * stageMult)
end

-- ========================================
-- 赊账下注组的单一口径：creditLimit 是「筹码之外可赊的额外额度」，
-- 总下注上限 = 筹码 + creditLimit（对应 credit_line / all_in_fanatic_rel 的
-- desc「上限 = 筹码的 N 倍」，N = 1 + 额度倍数）。placeBet / drawBetSlider /
-- 下注滑条拖拽三处都必须走 getCreditInfo，勿再各自复制遗物循环。
-- ========================================
function Relics.getCreditInfo(state)
    local chips = (state.player and state.player.chips) or 0
    local hasCredit, creditLimit = false, 0
    for _, r in ipairs(state.relics or {}) do
        if r.id == "credit_line" then
            hasCredit = true
            creditLimit = math.max(creditLimit, chips * 2)
        elseif r.id == "all_in_fanatic_rel" then  -- 全押狂魔赊账版
            hasCredit = true
            creditLimit = math.max(creditLimit, chips * 3)
        elseif r.id == "high_roller" then  -- 豪客
            hasCredit = true
            creditLimit = math.max(creditLimit, 5000)
        end
    end
    return hasCredit, creditLimit
end

function Relics.getById(id)
    for _, r in ipairs(Relics.LIBRARY) do if r.id == id then return r end end
    return nil
end

function Relics.filterByRarity(rarity)
    local out = {}
    for _, r in ipairs(Relics.LIBRARY) do if r.rarity == rarity then table.insert(out, r) end end
    return out
end

-- ========================================
-- 情报黑名单：暗处偏置遗物不再进商店/三选一池。
-- 「赌信息」玩法的地基是抽牌序列诚实 —— 有效偏置必须以显性千术回归。
-- 这些定义保留在 LIBRARY（兼容旧存档/图鉴），但不再刷新出来。
-- ========================================
Relics.POOL_EXCLUDED = {
    deck_weight_low = true,
    deck_weight_high = true,
    exclusive_supreme = true,
    seclusion = true,
}

function Relics.drawRandom(n, weights, excludeIds)
    n = n or 3
    weights = weights or { common = 50, uncommon = 30, rare = 15, legendary = 4, cursed = 1 }
    excludeIds = excludeIds or {}

    local pool = {}
    for _, r in ipairs(Relics.LIBRARY) do
        if not excludeIds[r.id] and not Relics.POOL_EXCLUDED[r.id] then
            local w = weights[r.rarity] or 10
            for i = 1, w do table.insert(pool, r) end
        end
    end

    local results = {}
    local used = {}
    local safety = 0
    while #results < n and safety < n * 10 do
        if #pool == 0 then break end
        safety = safety + 1
        local pick = pool[love.math.random(#pool)]
        if not used[pick.id] then
            used[pick.id] = true
            -- 返回浅拷贝，避免 .sold 等瞬时 flag 污染全局 LIBRARY
            local copy = {}
            for k, v in pairs(pick) do copy[k] = v end
            table.insert(results, copy)
            for i = #pool, 1, -1 do
                if pool[i].id == pick.id then table.remove(pool, i) end
            end
        end
    end
    return results
end

function Relics.generateShopOfferings(playerRelics)
    -- 只排除**永久持有**且未过期的（consumable 用完或过期后可再刷同款）
    local excludeIds = {}
    for _, r in ipairs(playerRelics) do
        if not r._consumable and not r._expired then
            excludeIds[r.id] = true
        end
    end
    -- 商店总共 5 栏 → 遗物 4 + 牌组 1
    return Relics.drawRandom(4, { common = 45, uncommon = 30, rare = 18, legendary = 7 }, excludeIds)
end

function Relics.getRarityColor(rarity)
    return Relics.RARITY[rarity] or {1, 1, 1}
end

return Relics
