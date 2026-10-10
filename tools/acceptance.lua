-- Independent specification checks. Run with tools/run_lua.py, then actual LOVE tests.
local BJ = require("src.blackjack")
local Deck = require("src.deck")
local pass, failures = 0, {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then pass=pass+1; print("PASS "..name) else failures[#failures+1]=name..": "..tostring(err); print("FAIL "..failures[#failures]) end
end
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function c(rank,value) return {rank=rank,suit="S",value=value} end
check("Multiple aces downgrade individually",function() eq(BJ.handTotal({c("A"),c("A"),c("9")}),21) end)
check("Explicit value takes priority over ace rank",function() eq(BJ.handTotal({c("A",2.5),c("5")}),7.5) end)
check("Explicit ace value also controls raw total",function() eq(BJ.handRawTotal({c("A",2.5),c("5")}),7.5) end)
check("Negative and decimal card totals",function() eq(BJ.handTotal({c("K"),c("n",-7),c("d",2.5)}),5.5) end)
check("Both bust loses to dealer",function() eq(BJ.compare(24,23,true,true),"dealer") end)
check("Equal normal points push",function() eq(BJ.compare(19,19,false,false),"push") end)
check("Only two cards form natural blackjack",function() eq(BJ.isBlackjack({c("A"),c("K")}),true); eq(BJ.isBlackjack({c("A"),c("5"),c("5")}),false) end)
check("Soft sixteen means an ace remains eleven",function() eq(BJ.isSoft({c("A"),c("5")}),true); eq(BJ.isSoft({c("A"),c("5"),c("10")}),false) end)
check("Deck cut preserves order and identities",function()
 local d=Deck.new({rng=function(a,b)return b end}); d:addCards({c("2"),c("3"),c("4"),c("5")}); local uid=d.drawPile[3].uid;d:cut(3);eq(d.drawPile[1].uid,uid);eq(d.drawPile[2].rank,"5");eq(d.drawPile[3].rank,"2");eq(d:auditTotal(),4)
end)
check("Discard refill preserves physical entities",function()
 local d=Deck.new({rng=function(a,b)return b end});d:addCards({c("2"),c("3")});local a=d:draw();local b=d:draw();d:toDiscard(a);d:toDiscard(b);local got=d:draw();assert(got==a or got==b);eq(d.shuffleCount,1);eq(#d.drawPile+#d.discardPile+1,2)
end)
check("UIDs never collide across deck instances",function()
 local a=Deck.new();local b=Deck.new();a:addCards({c("2")});b:addCards({c("2")});assert(a.drawPile[1].uid~=b.drawPile[1].uid)
end)
local Score = require("src.scoring")
check("Natural payout follows GDD gross 1.5x",function() eq(Score.baseFor("player",200,true),300) end)
check("Additive and multiplicative bonuses use distinct phases",function()
 local ctx=Score.newCtx({hand={}},{hand={}},{},{outcome="player",bet=200,cardChips=100,cardMultBonus=2,xMult=1.5})
 local amount=Score.finalize(ctx);eq(amount,2250)
end)
check("Push bonuses appear in net change",function()
 local ctx=Score.newCtx({hand={}},{hand={}},{},{outcome="push",bet=200,cardChips=100})
 local amount,result=Score.finalize(ctx);eq(amount,300);eq(result.netChange,100)
end)
check("Sixty-seven multiplier applies at final phase",function()
 local ctx=Score.newCtx({hand={}},{hand={}},{},{outcome="player",bet=100,is67=true})
 local amount=Score.finalize(ctx);eq(amount,13400)
end)
local Relics=require("src.relics")
check("Catalogue has all unique GDD relics and rarity counts",function()
 eq(#Relics.LIST,139);local seen,counts={},{}
 for _,r in ipairs(Relics.LIST) do assert(not seen[r.id],r.id);seen[r.id]=true;counts[r.rarity]=(counts[r.rarity] or 0)+1 end
 eq(counts.common,2);eq(counts.uncommon,29);eq(counts.rare,57);eq(counts.legendary,51)
end)
check("Removed bias relics remain excluded from random pool",function()
 for _,id in ipairs({"deck_weight_low","deck_weight_high","exclusive_supreme","seclusion"}) do assert(Relics.isPoolExcluded(Relics.byId(id)),id) end
end)
local Cocktails=require("src.cocktails")
check("All cocktail abilities are distinct and named",function()
 eq(#Cocktails.LIST,34);local seen={}
 for _,r in ipairs(Cocktails.LIST) do assert(not seen[r.id]);seen[r.id]=true;assert(r.ability and r.ability.special and #r.ability.desc>0) end
 eq(Cocktails.byId("mercury").ability.special,"redraw_hand")
end)
print(string.format("Independent acceptance: PASS=%d FAIL=%d",pass,#failures))
if #failures>0 then error(table.concat(failures,"\n")) end
