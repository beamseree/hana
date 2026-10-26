"""Compare a pinned public Calculation evaluator with independent range references."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("revision")
parser.add_argument("--repo", default=".")
args = parser.parse_args()
revision = subprocess.check_output(["git", "rev-parse", args.revision], cwd=args.repo, text=True).strip()
source = subprocess.check_output(["git", "show", f"{revision}:Sources/Hana/Calculation.swift"], cwd=args.repo, text=True)
cases_path = Path(__file__).with_name("exact-range-oracle-cases.json")
cases = json.loads(cases_path.read_text())
driver = r'''
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
let locale = Locale(identifier: "en_US")
var results: [[String: Any]] = []
for item in cases {
    let expression = item["expression"] as! String
    let answer = Calculation.answer(for: expression, locale: locale)
    results.append(["expression": expression, "state": answer.map { String(describing: $0.state) } ?? "nil",
                    "copy": answer?.copyableText ?? "nil"])
}
let output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
print(String(decoding: output, as: UTF8.self))
'''
with tempfile.TemporaryDirectory(prefix="hana-range-oracle-") as folder:
    probe = Path(folder) / "probe.swift"
    probe.write_text(source + "\n" + driver)
    process = subprocess.run(["swift", str(probe), str(cases_path)], text=True, capture_output=True, check=True)
results = json.loads(process.stdout)
mismatches = [dict(expected=expected, actual=actual) for expected, actual in zip(cases, results)
              if expected["state"] != actual["state"]
              or (expected["state"] == "value" and expected["nonzero"] and actual["copy"] in ("0", "-0"))]
report = dict(source=revision, reference="Python Decimal precision 600, seed 141", cases=len(cases),
              results=len(results), mismatches=mismatches, compiler_stderr=process.stderr)
path = Path(__file__).with_name("exact-range-oracle-result.json")
path.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(dict(source=revision, cases=len(cases), mismatches=len(mismatches), report=str(path))))
raise SystemExit(bool(mismatches) or len(results) != len(cases))
