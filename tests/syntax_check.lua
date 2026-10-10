-- tests/syntax_check.lua : 逐个 require 所有核心模块，捕获语法/加载错误
local mods = {
  'src.util','src.rng','src.blackjack','src.deck','src.deck_types','src.classes','src.marks',
  'src.relics','src.cocktails','src.bar_lines','src.scoring','src.event_manager','src.shoe_info',
  'src.persist','src.champion','src.tutorial','src.bar_mode','src.game_state','src.game',
}
local fail = 0
for _, m in ipairs(mods) do
  local ok, err = pcall(require, m)
  if ok then print('OK   ' .. m)
  else print('FAIL ' .. m .. ' :: ' .. tostring(err)); fail = fail + 1 end
end
print('load failures = ' .. fail)
os.exit(fail == 0 and 0 or 1)
