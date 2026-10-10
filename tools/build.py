"""Build reproducible .love and portable Windows packages (Python stdlib only)."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "dist"
RUNTIME = ROOT / "runtime" / "love-11.5-win64"

def archive(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for file, name in sorted(entries, key=lambda e: e[1]):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, file.read_bytes())
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None, "Archive CRC failure"

def main():
    required = [ROOT / "main.lua", ROOT / "conf.lua", RUNTIME / "love.exe", ROOT / "assets/fonts/cjk-regular.otf"]
    for p in required:
        if not p.is_file():
            raise SystemExit("Missing required input: " + str(p))
    OUT.mkdir(exist_ok=True)
    entries = [(ROOT / n, n) for n in ("main.lua", "conf.lua", "portable_fs.lua")]
    (OUT / "saves21").mkdir(exist_ok=True)
    for folder in ("src", "ui", "assets", "tests"):
        entries.extend((p, p.relative_to(ROOT).as_posix()) for p in (ROOT / folder).rglob("*") if p.is_file() and not p.name.startswith(".") and p.name not in {"cjk.ttf", "debug1.lua", "debug2.lua"})
    love = OUT / "BlackjackCheater.love"
    archive(love, entries)
    portable = OUT / "BlackjackCheater-Windows"
    portable.mkdir(exist_ok=True)
    (portable / "saves21").mkdir(exist_ok=True)
    (portable / "artifacts").mkdir(exist_ok=True)
    (portable / "artifacts/.keep").write_text("", encoding="utf-8")
    shutil.copy2(ROOT / "saves21/.keep", portable / "saves21/.keep")
    for p in RUNTIME.iterdir():
        if p.suffix.lower() == ".dll" or p.name == "license.txt":
            shutil.copy2(p, portable / p.name)
    exe = portable / "BlackjackCheater.exe"
    with exe.open("wb") as dest:
        dest.write((RUNTIME / "love.exe").read_bytes())
        dest.write(love.read_bytes())
    for name in ("README.md", "LICENSES.md"):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, portable / name)
    for name in ("IMPLEMENTATION.md", "SPEC-DECISIONS.md", "core-gaps.md", "relic-audit.md", "class-implementation.md", "bar-implementation.md", "meta-implementation.md", "stress-results.md"):
        if (ROOT / "docs" / name).exists():
            (portable / "docs").mkdir(exist_ok=True)
            shutil.copy2(ROOT / "docs" / name, portable / "docs" / name)
    shutil.copy2(ROOT / "assets/fonts/OFL.txt", portable / "FONT-LICENSE.txt")
    package = OUT / "BlackjackCheater-Windows.zip"
    archive(package, [(p, "BlackjackCheater/" + p.relative_to(portable).as_posix()) for p in portable.rglob("*") if p.is_file() and (not ({"saves21", "artifacts"} & set(p.relative_to(portable).parts)) or p.name == ".keep")])
    manifest = {"files": {name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for name, p in [("BlackjackCheater.love", love), ("BlackjackCheater-Windows.zip", package), ("BlackjackCheater-Windows/BlackjackCheater.exe", exe)]}, "love_entries": len(entries)}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))

if __name__ == "__main__":
    main()
