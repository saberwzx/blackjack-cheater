-- src/classes.lua 7 玩家职阶 + 7 残卷 + 7 庄家职阶
local Classes = {}

Classes.ORDER = { 'saber', 'lancer', 'archer', 'rider', 'caster', 'assassin', 'berserker' }

Classes.ALL = {
  saber = { id = 'saber', name = 'Saber 剑', letter = 'S', color = 'red', kind = 'trigger',
    desc = '结算前斩断庄家点数最小的一张牌，重装机手牌后重新比点。' },
  lancer = { id = 'lancer', name = 'Lancer 枪', letter = 'L', color = 'blue', kind = 'deal',
    desc = '初始发三张（第三张保证不爆），仍可继续要牌。' },
  archer = { id = 'archer', name = 'Archer 弓', letter = 'A', color = 'orange', kind = 'preview',
    desc = '下注时就能看到自己的第一张牌。' },
  rider = { id = 'rider', name = 'Rider 骑', letter = 'R', color = 'green', kind = 'active', uses = 3,
    desc = '可跳过本局 3 次，下注全额归还。' },
  caster = { id = 'caster', name = 'Caster 术', letter = 'C', color = 'purple', kind = 'modal',
    desc = '每连胜 3 次，可从 3 个随机遗物中挑 1 个替换已有 1 个。' },
  assassin = { id = 'assassin', name = 'Assassin 杀', letter = 'X', color = 'gray', kind = 'shadow',
    desc = '庄家看不到你的牌，依赖读手牌的千招 A/E 直接放弃。' },
  berserker = { id = 'berserker', name = 'Berserker 狂', letter = 'B', color = 'darkred', kind = 'rewrite',
    desc = '25 点以内不爆；未爆且比庄家大直接判胜（67 组合优先）。' },
}

function Classes.get(id)
  if not id then return nil end
  local d = Classes.ALL[id]
  if not d then return nil end
  return d
end

function Classes.getRuntime(id)
  local d = Classes.ALL[id]
  if not d then return nil end
  local o = {}
  for k, v in pairs(d) do o[k] = v end
  o.usesLeft = d.uses or 0
  o.used = false
  o._consumed = false
  return o
end

function Classes.random(rng)
  local i = 1
  if rng then i = math.floor(rng(1, #Classes.ORDER)) end
  if i < 1 then i = 1 elseif i > #Classes.ORDER then i = #Classes.ORDER end
  return Classes.ORDER[i]
end

function Classes.randomAnother(excludeId, rng)
  local pool = {}
  for i = 1, #Classes.ORDER do
    if Classes.ORDER[i] ~= excludeId then pool[#pool + 1] = Classes.ORDER[i] end
  end
  if #pool == 0 then return nil end
  local i = 1
  if rng then i = math.floor(rng(1, #pool)) end
  if i < 1 then i = 1 elseif i > #pool then i = #pool end
  return pool[i]
end

-- 残卷：商店专属 3 次
Classes.SHARDS = {
  class_rider_shard = { id = 'class_rider_shard', class = 'rider', mode = 'active', name = '骑之残卷', desc = '本小局按 R 可跳过一次（下注归还）。' },
  class_archer_shard = { id = 'class_archer_shard', class = 'archer', mode = 'active', name = '弓之残卷', desc = '本小局发牌时预览你的第一张牌。' },
  class_lancer_shard = { id = 'class_lancer_shard', class = 'lancer', mode = 'active', name = '枪之残卷', desc = '本小局开局发三张（第三张保证不爆 21）。' },
  class_assassin_shard = { id = 'class_assassin_shard', class = 'assassin', mode = 'active', name = '杀之残卷', desc = '本小局庄家看不到你的牌。' },
  class_caster_shard = { id = 'class_caster_shard', class = 'caster', mode = 'passive', name = '术之残卷', desc = '连胜 3 局时从 3 个候选挑 1 个替换本遗物自身。' },
  class_saber_shard = { id = 'class_saber_shard', class = 'saber', mode = 'trigger', name = '剑之残卷', desc = '本小局结算时斩掉庄家点数最小的一张牌。' },
  class_berserker_shard = { id = 'class_berserker_shard', class = 'berserker', mode = 'trigger', name = '狂之残卷', desc = '本小局 25 点内不爆；未比庄家小直接判胜。' },
}

-- 困难模式庄家职阶
Classes.DEALER = {
  saber = { id = 'saber', name = 'Saber', desc = '结算时斩掉玩家点数最小的一张牌后重新比点。' },
  lancer = { id = 'lancer', name = 'Lancer', desc = '开局发三张（保证 <=21），22~25 不算爆。' },
  archer = { id = 'archer', name = 'Archer', desc = '阶段 1 就能看到玩家点数，并预览你的第一张牌。' },
  rider = { id = 'rider', name = 'Rider', desc = '3 次跳过机会，每次下注后 50% 概率发动。' },
  caster = { id = 'caster', name = 'Caster', desc = '每 3 连胜获得 1 件遗物；每件让玩家 -1 点、庄家 +floor(n/2)。' },
  assassin = { id = 'assassin', name = 'Assassin', desc = '阶段 3 退化为阶段 2 激进 AI。' },
  berserker = { id = 'berserker', name = 'Berserker', desc = '22~25 不算爆；只要不比玩家小就强制判庄家赢。' },
}

function Classes.dealerRuntime(id)
  local d = Classes.DEALER[id]
  if not d then return nil end
  local o = {}
  for k, v in pairs(d) do o[k] = v end
  o.usesLeft = 3
  o.streak = 0
  o.relics = {}
  return o
end

function Classes.isShard(id)
  return Classes.SHARDS[id] ~= nil
end

return Classes
