-- src/tutorial.lua 14 步教程（GDD §19.3；原表 [10]/[11] 重复键 bug，此处修正为真正 14 步）
local T = {}
T.VERSION = 1
T.FORCED_MODE = 'basic'
T.START_CHIPS = 2500

-- 文案覆盖（GDD §19.3）：胜负规则、牌堆与牌组系统、遗物与点亮机制、手牌上限、
-- 商店与阶段、庄家出千与指认、进阶牌组（67 / RPS / 删除）、7 职阶总览。
T.PHASES = {
  { id = 'welcome', title = '欢迎来到 Blackjack Cheater', type = 'manual',
    text = '你是千门老千，目标是靠算牌、出千和情报，把三家赌场的钱赢光。\n按「继续」开始，教程不锁你的操作。' },
  { id = 'winloss', title = '胜负规则', type = 'manual',
    text = '比庄家更接近 21 点且不爆即赢；超过 21 点爆牌直接输；点数相同为平局退还下注。\n两张牌凑成 A + 10 点就是自然 21，赔 1.5 倍。' },
  { id = 'bet', title = '第一步：下注', type = 'requireAction', action = 'bet',
    actionHint = '请先完成一次下注（点击筹码或下注按钮）', requiresRelic = false,
    text = '每小局开始先下注。最低 $1，最高不超过你的筹码。\n下注会立刻从筹码里扣除。' },
  { id = 'play_round', title = '完成一局', type = 'requireAction', action = 'round_end',
    actionHint = '请打完这一小局（要牌或停牌直到结算）',
    text = '发牌后你可以「要牌」或「停牌」。点数尽量接近 21 但不要超过。' },
  { id = 'hand_limit', title = '手牌上限', type = 'manual',
    text = '一手牌最多 12 张。特殊牌（67 组合）会自动补满到 12 张——那是好事。' },
  { id = 'open_deck', title = '打开牌堆', type = 'requireAction', action = 'open_deck',
    actionHint = '请点击界面上的「牌堆」按钮查看顺序带',
    text = '牌堆界面能看到牌靴顺序、已翻开的牌和标记。情报从来不是免费的，但无知更贵。' },
  { id = 'deck_system', title = '牌堆与牌组', type = 'manual',
    text = '牌靴由 52 张固有牌和买来的特殊牌组组成，抽空后弃牌堆会洗回。\n特殊牌组有 12 种：小数、负数、倍率、67、RPS、删除、黑洞、牢笼、筹码、六面骰、二十面骰、冠军。' },
  { id = 'close_deck', title = '关闭牌堆', type = 'requireAction', action = 'close_deck',
    actionHint = '请点击「关闭」收起牌堆界面',
    text = '收起牌堆，回到牌桌。' },
  { id = 'relic_intro', title = '遗物与点亮', type = 'manual',
    text = '遗物会持续改变算分与规则。满足条件的遗物会「点亮」变色，说明它本局生效了。\n遗物栏最多 5 格，取舍就是构筑。' },
  { id = 'pick_relic', title = '选一个遗物', type = 'requireAction', action = 'pick_relic',
    actionHint = '请在遗物三选一里挑一个',
    text = '现在会弹出一个遗物三选一。挑一个加入你的遗物栏。' },
  { id = 'activate_relic', title = '激活一个遗物', type = 'requireAction', action = 'activate_relic',
    actionHint = '请激活一个主动/消耗型遗物',
    text = '部分遗物是主动或消耗型的（有次数），点击即可激活。用完次数就失效。' },
  { id = 'shop_stage', title = '商店与阶段', type = 'manual',
    text = '每 5 小局开一次商店。可以买遗物和牌组，也能用 $10,000 把消耗品「铸造」成永久。\n每个阶段有局数上限和筹码目标，达标就进入更难的下一个赌场。' },
  { id = 'cheat_accuse', title = '庄家出千与指认', type = 'manual',
    text = '阶段二起，庄家每小局都可能出千（暗牌换 BJ、抽牌必 10、低牌换掉、神抽、镜影）。\n你在玩家回合可以「指认出千」——猜对重罚庄家，猜错要赔 $50。痕迹会骗人，也可能是干扰项。' },
  { id = 'advanced', title = '进阶牌组与 7 职阶', type = 'manual',
    text = '67 组合（同时含 6 和 7）会填满手牌并强制获胜；RPS 双方各一张时只用石头剪刀布定胜负；删除牌组能把对手的牌删掉。\n7 个职阶各有绝活：Saber 斩牌、Lancer 三张、Archer 预览、Rider 跳过、Caster 换遗物、Assassin 隐身、Berserker 25 点。\n教程到此结束，祝你在三家赌场满载而归。' },
}

T.count = #T.PHASES

function T.new(opts)
  opts = opts or {}
  return setmetatable({
    steps = T.PHASES,
    index = 1,
    done = false,
    lastRejected = nil,
    onAction = opts.onAction,
  }, { __index = T })
end

function T:current()
  if self.done or self.index > #self.steps then return nil end
  return self.steps[self.index]
end

function T:isDone() return self.done end
function T:stepNumber() return math.min(self.index, #self.steps) end
function T:progress() return math.min(self.index - 1, #self.steps), #self.steps end

function T:advance(action)
  if self.done then return false, 'done' end
  local step = self.steps[self.index]
  if not step then self.done = true; return false, 'done' end
  if step.type == 'requireAction' then
    if action ~= step.action then
      self.lastRejected = { id = step.id, need = step.action, hint = step.actionHint }
      return false, 'require_action', step.actionHint
    end
  end
  self.lastRejected = nil
  self.index = self.index + 1
  if self.index > #self.steps then self.done = true end
  if self.onAction then pcall(self.onAction, step) end
  return true, 'advanced'
end

function T:notify(action)
  -- 玩家做出动作时调用：若当前步骤需要该动作则自动推进（不阻断正常游戏）
  local step = self:current()
  if step and step.type == 'requireAction' and step.action == action then
    return self:advance(action)
  end
  return false, 'ignored'
end

return T
