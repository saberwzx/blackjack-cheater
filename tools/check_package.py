"""Verify release hashes, bundled source freshness, and absence of private saves."""
from pathlib import Path
import hashlib
import json
import zipfile
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "dist/manifest.json").read_text(encoding="utf-8"))
for name, entry in manifest["files"].items():
    data = (ROOT / "dist" / name).read_bytes()
    assert len(data) == entry["bytes"], name
    assert hashlib.sha256(data).hexdigest() == entry["sha256"], name
with zipfile.ZipFile(ROOT / "dist/BlackjackCheater.love") as game:
    assert game.testzip() is None
    for name in game.namelist():
        assert game.read(name) == (ROOT / name).read_bytes(), "Stale bundled source: " + name
with zipfile.ZipFile(ROOT / "dist/BlackjackCheater-Windows.zip") as package:
    assert package.testzip() is None
    names = package.namelist()
    assert not any(name.endswith(("progress.lua", "collection.lua")) for name in names)
    for name in names:
        relative = name.removeprefix("BlackjackCheater/")
        assert package.read(name) == (ROOT / "dist/BlackjackCheater-Windows" / relative).read_bytes(), name
    for name in ("BlackjackCheater.exe", "love.dll", "lua51.dll", "license.txt", "FONT-LICENSE.txt", "saves21/.keep", "artifacts/.keep"):
        assert "BlackjackCheater/" + name in names, name
print("PACKAGE PASS: hashes, CRCs, current source, runtime, licenses, no player saves")
