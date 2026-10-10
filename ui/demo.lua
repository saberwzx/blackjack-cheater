-- ui/demo.lua : EXPLICIT art harness only (--ui-demo). Never used by a normal run or --smoke.
-- Builds a synthetic core state table + fake g so screens can be verified without src/.
local Demo = {}

local uid = 1000
local function card(rank, suit, value, extra)
  uid = uid + 1
  local c = { rank = rank, suit = suit, value = value or tonumber(rank), uid = uid, _uid = uid }
  if extra then for k, v in pairs(extra) do c[k] = v end end
  return c
end

local SUITS = { "S", "H", "D", "C" }
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

local function stdHand(n, seedv)
  local out = {}
  for i = 1, n do
    local r = RANKS[((seedv + i * 5) % 13) + 1]
    local s = SUITS[((seedv + i * 3) % 4) + 1]
    local v = (r == "A") and 11 or (r == "J" or r == "Q" or r == "K") and 10 or tonumber(r)
    out[#out + 1] = card(r, s, v)
  end
  return out
end

local RELICS = {
  { id = "mult_ring", name = "倍率戒指", desc = "每局结算时倍率 +1。点亮后本小局生效。", rarity = "uncommon", price = 1200, icon = 1, _active = true, triggers = { "on_score_calc" } },
  { id = "ink_lord", name = "墨水大盗", desc = "墨水标记费用减半，剩余 3 次。", rarity = "rare", price = 2400, icon = 8, _consumable = true, _usesLeft = 3, triggers = { "on_mark" } },
  { id = "late_surrender", name = "后期投降", desc = "点数小于 18 时可以投降，返还一半注金。", rarity = "common", price = 800, icon = 9, _auto = true, triggers = { "on_surrender" } },
  { id = "ironproof", name = "铁证如山", desc = "指认成功时改为 +5 倍注。", rarity = "legendary", price = 4800, icon = 7, _preGame = true, triggers = { "on_accuse" } },
  { id = "peek3", name = "透视眼镜", desc = "情报可见深度 +3。", rarity = "rare", price = 3000, icon = 5, _consumable = true, _usesLeft = 2, triggers = { "on_peek" } },
}

local CLASSES = {
  { id = "saber", name = "Saber 剑", letter = "S", desc = "结算前斩掉庄家最小的一张牌。", color = { 0.85, 0.18, 0.20 } },
  { id = "lancer", name = "Lancer 枪", letter = "L", desc = "开局多发一张牌。", color = { 0.30, 0.56, 0.95 } },
  { id = "archer", name = "Archer 弓", letter = "A", desc = "下注阶段预览牌靴第一张。", color = { 0.96, 0.60, 0.20 } },
  { id = "rider", name = "Rider 骑", letter = "R", desc = "每 3 胜获得一次免费跳局。", color = { 0.30, 0.78, 0.42 } },
  { id = "caster", name = "Caster 术", letter = "C", desc = "每 3 连胜可从 3 件遗物中替换 1 件。", color = { 0.62, 0.38, 0.92 } },
  { id = "assassin", name = "Assassin 杀", letter = "X", desc = "庄家看不见你的牌，并封锁暗牌换牌与镜影。", color = { 0.58, 0.56, 0.58 } },
  { id = "berserker", name = "Berserker 狂", letter = "B", desc = "25 点以内不爆牌，只要不爆且高于庄家即获胜。", color = { 0.62, 0.10, 0.14 } },
}

local function baseState()
  local st = {
    state = "title", mode = "normal", seed = 20261001, stage = 2, stageName = "老练赌场",
    stageTarget = 20000, stageRounds = 15, roundsInStage = 4, round = 19,
    chips = 18350, bet = 200, streak = 2,
    bustBet = { on = true, amount = 100, odds = 3.6, hit = false, locked = true },
    player = { hand = {}, total = 0, rawTotal = 0, busted = false, stood = false, blackjack = false,
      is67 = false, isRps = false, surrendered = false, doubled = false, cageBlocked = false },
    dealer = { hand = {}, total = 0, rawTotal = 0, busted = false, holeRevealed = false, difficulty = 2, standOn = 18 },
    deck = { drawPile = {}, discardPile = {}, removed = {}, shuffleCount = 2, removedDecks = 0, syntheticCount = 0 },
    relics = RELICS, relicSlotMax = 5,
    specialMarks = { held = { id = "mark_bomb", name = "爆炸红标记", usesLeft = 2, color = "red" } },
    playerClass = CLASSES[5],
    dealerClass = { id = "cheat", name = "老千庄家", letter = "D", desc = "老练赌场的庄家，出千概率 20%。" },
    shop = nil, relicSelect = nil, classOffer = nil,
    message = "", messageTone = "info", result = nil,
    shoe = {
      order = {}, composition = {}, nextBustOdds = 0.42, dealerBustOdds = 0.28,
      discard = {}, revealSlots = { [1] = true, [2] = true }, coverageGap = "", offset = 0,
    },
    streak = 2, fx = {}, log = {},
    progress = { hardCleared = true, hardClearCount = 2, maxStage = 3, maxChips = 91000, totalRuns = 7, bestRoundsBasic = 47, bestRoundsHard = 33 },
    settings = { autoEndOnBroke = true, volume = 0.6, resolution = 2, fullscreen = false },
    tutorial = nil, bar = nil, flags = {},
  }
  st.player.hand = stdHand(3, 3)
  st.player.total, st.player.rawTotal = 21, 21
  st.dealer.hand = stdHand(2, 11)
  st.dealer.total, st.dealer.rawTotal = 17, 17
  st.dealer.hand[1]._hole = true
  st.deck.drawPile = stdHand(8, 21)
  st.deck.discardPile = stdHand(4, 31)
  st.shoe.order = {}
  for i = 1, 14 do
    local c = card(RANKS[((i * 7) % 13) + 1], SUITS[(i % 4) + 1], nil)
    c.value = tonumber(c.rank) or 10
    st.shoe.order[i] = { card = c, revealed = (i <= 3) }
  end
  st.shoe.composition = {
    { label = "A", count = 4 }, { label = "2", count = 5 }, { label = "3", count = 3 }, { label = "4", count = 6 },
    { label = "5", count = 7 }, { label = "6", count = 5 }, { label = "7", count = 4 }, { label = "8", count = 6 },
    { label = "9", count = 5 }, { label = "10", count = 12 }, unknown = 1,
  }
  st.shoe.discard = stdHand(6, 41)
  st.classChoices = CLASSES
  st.shop = {
    open = true,
    shelves = {
      { kind = "relic", item = { relic = RELICS[1], price = 1800, basePrice = 1200 }, price = 1800, basePrice = 1200, sold = false },
      { kind = "relic", item = { relic = RELICS[2], price = 2400, basePrice = 2400 }, price = 2400, basePrice = 2400, sold = false },
      { kind = "relic", item = { relic = RELICS[4], price = 7200, basePrice = 4800 }, price = 7200, basePrice = 4800, sold = false },
      { kind = "relic", item = { relic = RELICS[5], price = 3000, basePrice = 3000 }, price = 3000, basePrice = 3000, sold = true },
      { kind = "deck", item = { type = "decimal", size = "small", name = "小数牌组（小）", price = 900 }, price = 900, sold = false },
    },
    relics = {},
    deckItem = { type = "decimal", size = "small", name = "小数牌组（小）", price = 900, sold = false },
    allDecks = false, discount = { slot = 2, factor = 0.5 }, rerollCost = 400,
    forgeOffer = { available = true, price = 10000, candidates = { RELICS[1], RELICS[4] } },
    forgeUsed = false, returnState = "player",
  }
  st.shop.relics = { st.shop.shelves[1].item, st.shop.shelves[2].item, st.shop.shelves[3].item, st.shop.shelves[4].item }
  st.relicSelect = { candidates = { RELICS[2], RELICS[3], RELICS[5] } }
  st.result = {
    outcome = "player", bet = 200, baseChips = 400, additiveChips = 300, mult = 4, xMult = 2.0,
    winnings = 3200, netChange = 3000, chips = 21350,
    breakdown = { { label = "基础胜出", kind = "base", value = 400 }, { label = "倍率戒指", kind = "mult", value = 1 },
      { label = "幸运星", kind = "mult", value = 2 }, { label = "双倍狂热", kind = "x_mult", value = 2 } },
    bustBet = { on = true, amount = 100, odds = 3.6, hit = true, payout = 460 },
    accuse = { attempted = true, correct = true, bonus = 600 },
    marks = { discovered = 1, penalty = 0 }, forcedStage = false, events = { "on_win", "on_score_calc" },
  }
  return st
end

-- champion pool for the editor scene
local function championView()
  local pool, groups = {}, { "standard", "decimal", "negative", "multiplier", "s67", "rps", "blackhole", "cage", "chip", "dice6", "dice20" }
  local n = 0
  for gi, grp in ipairs(groups) do
    local count = (grp == "standard" or grp == "blackhole" or grp == "cage" or grp == "chip") and 13 or 6
    for i = 1, count do
      n = n + 1
      local r = RANKS[(i % 13) + 1]
      local s = SUITS[(i % 4) + 1]
      pool[n] = { id = n, label = tostring(n), group = grp, kind = grp, rank = r, suit = s,
        value = tonumber(r) or 10, name = grp .. " #" .. i }
    end
  end
  local selected = {}
  for i = 1, 24 do selected[i] = i end
  return { pool = pool, selected = selected, max = 36, unlocked = true, filter = "standard", scroll = 0 }
end

function Demo.new(scene)
  local st = baseState()
  local view = { champion = championView() }

  local g = { state = st }

  local function fx(kind, extra)
    local e = { kind = kind }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    st.fx[#st.fx + 1] = e
  end

  function g:start(mode, seed)
    st.mode = mode or "normal"
    if mode == "bar" then st.state = "bar_brief"; st.bar = Demo.makeBar()
    else st.state = "relic_select" end
    return true
  end
  function g:update(dt) end
  function g:flush() return 0 end
  function g:can(name) return true end
  function g:getView() return view end
  function g:drainFx()
    local l = st.fx
    st.fx = {}
    return l
  end
  function g:drainLog() return {} end

  local A = {}
  A.select_mode = function(a)
    st.mode = a or "normal"
    if st.mode == "bar" then st.state = "bar_brief"; st.bar = Demo.makeBar()
    else st.state = "relic_select" end
  end
  A.pick_relic = function() st.state = "bet"; st.relicSelect = nil end
  A.bet_set = function(n) st.bet = math.max(0, math.floor(n or 0)) end
  A.bet_adjust = function(d) st.bet = math.max(0, st.bet + (d or 0)) end
  A.bet_preset = function(i) st.bet = ({ 50, 100, 200, 500, 1000 })[i] or st.bet end
  A.bet_confirm = function() st.state = "player"; st.bustBet.locked = true end
  A.toggle_bust_bet = function() st.bustBet.on = not st.bustBet.on end
  A.hit = function() end
  A.stand = function() st.state = "result" end
  A.continue = function()
    if st.state == "result" then st.state = "shop"
    elseif st.state == "shop" then st.state = "bet"; st.result = nil
    elseif st.state == "stageClear" then st.state = "bet"
    elseif st.state == "victory" or st.state == "forceExit" then st.state = "title"
    elseif st.state == "bar_ending" then st.state = "title"
    elseif st.state == "classSelect" then st.state = "bet"
    else st.state = "bet" end
  end
  A.open_shoe = function() st.state = "shoeInfo" end
  A.close_shoe = function() st.state = "player" end
  A.open_deck = function() st.state = "deckOverview" end
  A.close_deck = function() st.state = "player" end
  A.open_deck_editor = function() st.state = "deckEditor" end
  A.close_deck_editor = function() st.state = "title" end
  A.choose_class = function() st.state = "bet" end
  A.take_class_offer = function() st.classOffer = nil; st.state = "bet" end
  A.skip_class_offer = function() st.classOffer = nil; st.state = "bet" end
  A.leave_shop = function() st.state = "bet"; st.result = nil end
  A.buy_relic = function() end
  A.buy_deck = function() end
  A.reroll = function() st.shop.rerollCost = st.shop.rerollCost * 2 end
  A.open_forge = function() end
  A.confirm_forge = function() end
  A.cancel_forge = function() end
  A.forge_select = function() end
  A.mark_card = function() end
  A.rod_pick = function() end
  A.rod_confirm = function() end
  A.accuse = function()
    st.result = st.result or {}
    fx("sfx", { name = "accuse_ok" })
    fx("shake", { amount = 10 })
  end
  A.surrender = function() end
  A.skip_round = function() end
  A.shoe_tab = function(t) st.shoeTab = t end
  A.shoe_scroll = function(d) st.shoe.scroll = (st.shoe.scroll or 0) + d end
  A.deck_scroll = function(d) st.deckScroll = (st.deckScroll or 0) + d end
  A.bar_begin = function() st.state = "bar_table" end
  A.bar_gift_pick = function() st.state = "bar_table" end
  A.bar_drink = function() end
  A.bar_ability = function() end
  A.start_tutorial = function()
    st.tutorial = { active = true, step = 1, total = 14,
      phase = { index = 1, title = "21 点的胜负", text = "手牌点数尽量接近 21 点但不要超过。超过 21 点立即爆牌落败。点击「继续」开始。", requireAction = nil, actionHint = "" } }
  end
  A.tutorial_advance = function()
    if not st.tutorial then return false, "no_state" end
    st.tutorial.step = math.min(st.tutorial.total, st.tutorial.step + 1)
    st.tutorial.phase = { index = st.tutorial.step, title = "步骤 " .. st.tutorial.step, text = "这是教程第 " .. st.tutorial.step .. " 步的说明文字。", requireAction = nil, actionHint = "" }
    return true
  end
  A.set_setting = function(a)
    if type(a) == "table" then st.settings[a.key] = a.value end
  end
  A.toggle_setting = function(k) st.settings[k] = not st.settings[k] end
  A.reset_progress = function() end
  A.close_top = function() st.state = st.prevState or "player" end
  A.dismiss = function() end
  A.champion_toggle = function() end
  A.champion_clear = function() view.champion.selected = {} end
  A.champion_filter = function() end
  A.champion_save = function() return true end

  function g:action(name, arg)
    if not name then return false, "unknown_action" end
    local fn = A[name]
    if not fn then return true end
    local ok, err = pcall(fn, arg)
    if not ok then st.message = tostring(err); return false, "demo_error" end
    return true
  end

  -- scene pre-roll
  view.champion = championView()
  if scene == "relic" then st.state = "relic_select"
  elseif scene == "mode" then st.state = "modeSelect"
  elseif scene == "bet" then st.state = "bet"
  elseif scene == "table" then st.state = "player"
  elseif scene == "result" then st.state = "result"
  elseif scene == "shop" then st.state = "shop"
  elseif scene == "shoe" then st.state = "shoeInfo"
  elseif scene == "deck" then st.state = "deckOverview"
  elseif scene == "class" then st.state = "classSelect"
  elseif scene == "offer" then st.state = "classOffer"
  elseif scene == "editor" then st.state = "deckEditor"
  elseif scene == "bar" then st.state = "bar_table"; st.bar = Demo.makeBar()
  elseif scene == "barbrief" then st.state = "bar_brief"; st.bar = Demo.makeBar()
  elseif scene == "stageclear" then st.state = "stageClear"
  elseif scene == "victory" then st.state = "victory"; st.stage = 3; st.chips = 2450000
  elseif scene == "forceexit" then st.state = "forceExit"
  elseif scene == "settings" then st.state = "player"
  elseif scene == "tutorial" then st.state = "player"
    st.tutorial = { active = true, step = 3, total = 14,
      phase = { index = 3, title = "点亮遗物", text = "点击右侧遗物栏中的遗物即可点亮，本小局它会持续生效。", requireAction = "activate_relic", actionHint = "请先点亮一件遗物" } }
  elseif scene == "title" then st.state = "title"
  end
  if scene == "table" or scene == "result" then
    fx("tell", { tellKind = "A", slot = "hole", uid = st.dealer.hand[1].uid, card = st.dealer.hand[1] })
  end
  return g
end

function Demo.makeBar()
  local ids = { "mercury", "venus", "earth", "mars", "jupiter", "saturn" }
  local names = { "莫斯科骡子", "大都会", "古典鸡尾酒", "血腥玛丽", "迈泰", "新加坡司令" }
  local colors = { { 0.85, 0.55, 0.20 }, { 0.88, 0.20, 0.30 }, { 0.80, 0.36, 0.12 }, { 0.72, 0.10, 0.12 }, { 0.95, 0.78, 0.30 }, { 0.92, 0.42, 0.48 } }
  local cups = {}
  for i = 1, 6 do cups[i] = { id = ids[i], name = names[i], mouth = (i % 5), color = colors[i] } end
  return {
    round = 27, totalRounds = 100, cups = cups,
    buffs = { mercury = 4, venus = 2 }, prob = 0.14,
    giftOptions = { { id = "tarot_star", name = "星星", desc = "下一张牌必定为 A。" }, { id = "tarot_moon", name = "月亮", desc = "本局暗牌可见。" }, { id = "tarot_sun", name = "太阳", desc = "本局结算翻倍。" } },
    pendingDrink = nil, hangover = true, hangoverColor = { 0.62, 0.34, 0.40 },
    abilitiesUsed = {}, lastLine = "酒保说：今晚的客人来自银河的另一端。", ending = nil, wins = 12, losses = 9,
  }
end

Demo.CLASSES = CLASSES
Demo.RELICS = RELICS
return Demo
