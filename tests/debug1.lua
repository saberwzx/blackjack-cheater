local Game = require('src.game')
local seed = 987654321
local function rng(a,b) seed=(seed*1103515245+12345)%2147483648; if a==nil then return seed/2147483648 end; return a+(seed%(b-a+1)) end
local files={}
local function memfs() return {read=function(p) return files[p] end, write=function(p,d) files[p]=d; return true end, getInfo=function(p) return files[p] and {type='file'} or nil end, mkdir=function() return true end, remove=function(p) files[p]=nil; return true end} end
local g = Game.new({rng=rng, filesystem=memfs()})
print('type(g.state) =', type(g.state))
print('g.state =', tostring(g.state))
local ok, err = g:start('normal', 1)
print('start ok=', tostring(ok), 'err=', tostring(err))
print('after start, rawget _g.state.state =', tostring(rawget(g,'_g').state.state))
print('g.state.state =', tostring(g.state.state))
print('g.mode =', tostring(g.mode))
