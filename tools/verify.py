"""Run independent Lua rule suites; write auditable logs under artifacts/."""
from pathlib import Path
import json
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = [
    "tests/run.lua", "tools/acceptance.lua", "tools/flow_acceptance.lua",
    "tools/probability_acceptance.lua", "tools/bar_acceptance.lua",
    "tools/meta_acceptance.lua", "tools/class_acceptance.lua",
    "tools/relic_acceptance.lua", "tools/scoring_acceptance.lua", "tools/stress_acceptance.lua",
]

def main():
    out = ROOT / "artifacts"
    out.mkdir(exist_ok=True)
    results = []
    commands = [("syntax", [sys.executable, str(ROOT / "tools/check_lua.py")])]
    commands.extend((Path(s).stem, [sys.executable, str(ROOT / "tools/run_lua.py"), str(ROOT / s)]) for s in SUITES)
    for name, command in commands:
        try:
            p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, env=dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8"))
            text, code = p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired as exc:
            text, code = "Timed out after 180 seconds: " + str(exc), 124
        (out / ("verify_" + name + ".log")).write_text(text, encoding="utf-8")
        results.append({"suite": name, "exit_code": code, "log": "verify_" + name + ".log"})
        print(name + ": " + ("PASS" if code == 0 else "FAIL"), flush=True)
        if code: print(text[-4000:], flush=True)
    report = {"scope": "LuaJIT rule tests with explicit LOVE stubs; graphics/audio verified separately in LOVE", "results": results, "ok": all(r["exit_code"] == 0 for r in results)}
    (out / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if report["ok"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
