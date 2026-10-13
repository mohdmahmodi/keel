#!/usr/bin/env python3
"""Writes docs/site/tweaks.json from the app's catalog (Keel --catalog-json).

Values that depend on the Mac that ran the export (memory size, browsers installed, home folder)
are replaced with neutral wording so the website shows the same list for everyone.

    swift build && scripts/site-data.py
"""
import json, os, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
binary = os.path.join(root, ".build", "debug", "Keel")
if not os.path.exists(binary):
    sys.exit("Build first: swift build")

raw = json.loads(subprocess.run([binary, "--catalog-json"], check=True, capture_output=True).stdout)
home = os.path.expanduser("~")

renames = [
    (r"^GPU memory for local AI: .*", "GPU memory for local AI, sized for your Mac"),
    (r"^Docker: cap the VM at .*", "Docker: cap the VM to fit your Mac"),
    (r"^Ollama: \d+K default context$", "Ollama: default context sized for your memory"),
    (r"^Google Chrome (.*)", r"Chrome, Brave, Chromium: \1"),
]

rows, seen = [], set()
for t in raw:
    if t["id"].startswith(("brave-", "chromium-")):
        continue  # merged into the Chrome row
    name = t["name"]
    for pattern, repl in renames:
        name = re.sub(pattern, repl, name)
    cmds = [c.replace(home, "~") for c in t["commands"]]
    cmds = [re.sub(r"wired_limit_mb=\d+", "wired_limit_mb=<sized for your Mac>", c) for c in cmds]
    if t["id"] in seen:
        continue
    seen.add(t["id"])
    rows.append({
        "id": t["id"], "name": name, "cat": t["category"], "summary": t["summary"].replace(home, "~"),
        "benefit": t["benefit"], "tradeoff": t["tradeoff"], "risk": t["risk"], "impact": t["impact"],
        "rec": t["recommended"], "gem": t["gem"], "admin": t["admin"], "manual": t["manual"],
        "once": t["oneShot"], "who": t["audience"], "cmds": cmds, "restarts": t.get("restarts"),
    })

out = os.path.join(root, "docs", "site", "tweaks.json")
with open(out, "w") as f:
    json.dump(rows, f, ensure_ascii=False, separators=(",", ":"))
leak = [r["id"] for r in rows if home in json.dumps(r)]
if leak:
    sys.exit(f"home folder still present in: {leak}")
print(f"{len(rows)} tweaks -> {os.path.relpath(out, root)} ({os.path.getsize(out) // 1024} KB)")
