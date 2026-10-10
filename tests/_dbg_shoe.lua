local Game=require('src.game'); local Deck=require('src.deck'); local DT=require('src.deck_types')
local function c(r,v,x) local o={rank=r,suit='S',kind='basic',is_basic=true,value=v}; if x then for k,val in pairs(x) do o[k]=val end end; return DT.mk(o) end
local g=Game.new({rng=function(a,b) if a==nil then return 0.5 end return a end, filesystem={read=function()end,write=function() return true end,getInfo=function()end,mkdir=function() return true end,remove=function() return true end}})
local ok,ids=pcall(function() return g._g:specialHandlerIds() end)
print('specialHandlerIds ok=',ok,'type=',type(ids),'n=',type(ids)=='table' and #ids or -1)
local s=g.state; s.deck=Deck.new()
local cards={} for i=1,60 do cards[i]=c('5',5) end
s.deck:addCards(cards)
s.player.hand={c('10',10),c('7',7)}; s.player.total=17
s.dealer.hand={c('10',10),c('6',6)}; s.dealer.difficulty=1
s.shoeOpen=true
g._g:refreshShoe()
print('nextBustOdds',s.shoe.nextBustOdds, s.shoe.nextBustOddsInfo and s.shoe.nextBustOddsInfo.reason)
print('dealerBustOdds',s.shoe.dealerBustOdds, s.shoe.dealerBustOddsInfo and s.shoe.dealerBustOddsInfo.reason)
print('coverageGap',s.shoe.coverageGap, 'known',s.shoe.known and #s.shoe.known)
local SI=require('src.shoe_info')
local p,meta=SI.dealerBustOdds({s.dealer.hand[2]},1,{cards=s.shoe.known,playerTotal=17,holeUnknown=true,holeCard=s.dealer.hand[1]})
print('direct',p,meta and meta.reason, meta and meta.nodes)
