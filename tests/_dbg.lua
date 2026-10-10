local Game=require('src.game')
local BJ=require('src.blackjack')
local seed0=987654321
local function mk() local seed=seed0; return function(a,b) seed=(seed*1103515245+12345)%2147483648; if a==nil then return seed/2147483648 end return a+(seed%(b-a+1)) end,function(s) seed=s end end
local files={}
local function memfs() return {read=function(p)return files[p]end,write=function(p,d)files[p]=d;return true end,getInfo=function(p)if files[p]then return{type='file'}end end,mkdir=function()return true end,remove=function(p)files[p]=nil;return true end} end
local function drive(mode)
 local rng,setseed=mk(); local g=Game.new({rng=rng,filesystem=memfs()})
 g:start(mode,20261001);g:flush()
 local steps=0; local fails=0
 while steps<5000 do
  steps=steps+1
  local s=g.state.state
  if s=='relic_select' then g:action('pick_relic',1)
  elseif s=='classSelect' then local c=g.state.classOffer and g.state.classOffer.candidates; g:action('choose_class',c and c[1] and c[1].id or 'saber')
  elseif s=='classOffer' then g:action('take_class_offer',1)
  elseif s=='bet' then g:action('bet_set',200);g:action('bet_confirm')
  elseif s=='player' then
    local p=g.state.player; local n=0
    while g.state.state=='player' and n<40 do
      n=n+1
      local ok,tt=pcall(BJ.handTotal,p.hand); tt=ok and tt or 0
      local name=(tt<15 and n<8) and 'hit' or 'stand'
      local rok,err=g:action(name)
      if not rok and name=='hit' then
        fails=fails+1
        if fails<=3 then print(string.format('[%s] hit fail total=%s busted=%s stood=%s cage=%s bj=%s is67=%s n=%d flags=%s',mode,tostring(tt),tostring(p.busted),tostring(p.stood),tostring(p.cageBlocked),tostring(p.blackjack),tostring(p.is67),#p.hand,tostring(g.state.flags and (g.state.flags.autoStandNext or g.state.flags.accusedThisRound)))) end
      end
      g:flush()
    end
  elseif s=='bar_gift' then g:action('bar_gift_pick',1)
  elseif s=='bar_brief' then g:action('bar_begin')
  elseif s=='result' then g:action('continue')
  elseif s=='shop' then g:action('leave_shop')
  elseif s=='stageClear' then g:action('continue')
  elseif s=='victory' or s=='forceExit' or s=='bar_ending' or s=='title' then break
  else print('unhandled',s);break end
  g:flush()
 end
 print(mode,'fails',fails,'steps',steps,'end',g.state.state)
end
drive('normal');drive('hard');drive('bar')
