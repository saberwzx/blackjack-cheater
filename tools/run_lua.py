"""Execute a developer Lua script using bundled LuaJIT; LOVE API is explicitly stubbed."""
from pathlib import Path
import ctypes
import os
import sys
ROOT = Path(__file__).resolve().parents[1]
runtime = ROOT / "runtime/love-11.5-win64"
# LuaJIT's ANSI file API cannot open paths outside the system code page, so
# run with cwd at the project root and hand LuaJIT relative ASCII paths.
os.chdir(ROOT)
dll_dir = os.add_dll_directory(str(runtime))
lua = ctypes.CDLL(str(runtime / "lua51.dll"))
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.luaL_loadstring.restype = ctypes.c_int
lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
lua.lua_pcall.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]
state = lua.luaL_newstate()
lua.luaL_openlibs(state)
script = Path(os.path.relpath(sys.argv[1], ROOT))
source = "package.path = [[./?.lua;]] .. package.path\n"
source += "love = {math={random=math.random, setRandomSeed=math.randomseed}, timer={getTime=os.clock}}\n"
source += "arg = {}\n"
source += "dofile([[%s]])\n" % script.as_posix()
status = lua.luaL_loadstring(state, source.encode("utf-8"))
if status == 0:
    status = lua.lua_pcall(state, 0, -1, 0)
if status:
    print(lua.lua_tolstring(state, -1, None).decode("utf-8", errors="replace"), file=sys.stderr)
lua.lua_close(state)
sys.exit(1 if status else 0)
