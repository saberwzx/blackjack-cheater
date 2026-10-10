"""Run the fused executable with a deadline and a durable engine log."""
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
args = sys.argv[1:] or ["--test"]
name = "packaged_test" if "--test" in args else "packaged_smoke"
with (ROOT / "artifacts" / (name + ".log")).open("w", encoding="utf-8") as output:
    try:
        result = subprocess.run([str(ROOT / "dist/BlackjackCheater-Windows/BlackjackCheater.exe"), *args], cwd=ROOT / "dist/BlackjackCheater-Windows", stdout=output, stderr=subprocess.STDOUT, timeout=120)
        code = result.returncode
    except subprocess.TimeoutExpired:
        output.write("\nTIMEOUT after 120 seconds\n")
        code = 124
print(name + ": exit " + str(code))
raise SystemExit(code)
