"""Parse every Lua source with the bundled LuaJIT (no third-party Python packages)."""
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
lua.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.luaL_loadfile.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
lua.lua_close.argtypes = [ctypes.c_void_p]
state = lua.luaL_newstate()
files = list(ROOT.glob("*.lua"))
for directory in ("src", "ui", "tests"):
    files += list((ROOT / directory).rglob("*.lua"))
errors = []
for file in sorted(files):
    result = lua.luaL_loadfile(state, os.fsencode(file.relative_to(ROOT).as_posix()))
    if result:
        message = lua.lua_tolstring(state, -1, None).decode("utf-8", errors="replace")
        errors.append(message)
        print("FAIL", message)
    lua.lua_settop(state, 0)
lua.lua_close(state)
print("LuaJIT syntax: %d files, %d errors" % (len(files), len(errors)))
sys.exit(1 if errors or not files else 0)
