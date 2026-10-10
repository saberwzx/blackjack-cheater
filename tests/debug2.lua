local Game = require('src.game')
local BJ = require('src.blackjack')
local seed=987654321
local function rng(a,b) seed=(seed*1103515245+12345)%2147483648; if a==nil then return seed/2147483648 end; return a+(seed%(b-a+1)) end
local files={}
local function memfs() return {read=function(p) return files[p] end, write=function(p,d) files[p]=d; return true end, getInfo=function(p) return files[p] and {type='file'} or nil end, mkdir=function() return true end, remove=function(p) files[p]=nil; return true end} end
local g=Game.new({rng=rng,filesystem=memfs()})
g:start('normal',1); g:flush()
local last=nil
for step=1,400 do
  local st=g.state
  local s=st.state
  if s~=last then
    print(string.format('step%3d %-14s round=%d ris=%d/%d chips=%d bet=%d after=%s target=%d', step, s, st.round, st.roundsInStage, st.stageRounds, st.chips, st.bet, tostring(st.afterResult), st.stageTarget))
    last=s
  end
  if s=='relic_select' then g:action('pick_relic',1)
  elseif s=='bet' then g:action('bet_set',200); g:action('bet_confirm')
  elseif s=='player' then
    local p=st.player
    if BJ.handTotal(p.hand)<17 then g:action('hit') else g:action('stand') end
  elseif s=='dealer' or s=='result_pending' then g:update(0.5)
  elseif s=='result' then g:action('continue')
  elseif s=='stageClear' then g:action('continue')
  elseif s=='shop' then g:action('leave_shop')
  elseif s=='classSelect' then local c=st.classOffer.candidates; g:action('choose_class',c[1].id)
  elseif s=='classOffer' then g:action('take_class_offer',1)
  else print('STOP at',s); break end
  g:flush()
end
