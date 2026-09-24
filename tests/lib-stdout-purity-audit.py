"""Scan for functions whose captured stdout would be contaminated by a log line.

A shell function that returns a value does so on stdout. A progress line written
there becomes part of that value for every `x="$(fn ...)"` caller.
"""
import re, pathlib, sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
found_any = False

for f in ["bin/domum-media", "bin/domum-media-backup", "bin/domum-media-report"]:
    src = (ROOT / f).read_text()
    lines = src.split("\n")
    # map: function name -> (start,end) line indices
    funcs, stack = {}, None
    for i, ln in enumerate(lines):
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{', ln)
        if m:
            stack = (m.group(1), i)
        elif ln == "}" and stack:
            funcs[stack[0]] = (stack[1], i)
            stack = None

    # which functions are captured with $( ... ) somewhere?
    captured = set()
    for name in funcs:
        if re.search(r'\$\(\s*' + re.escape(name) + r'[\s)]', src):
            captured.add(name)

    bad = []
    for name in sorted(captured):
        a, b = funcs[name]
        for i in range(a, b + 1):
            ln = lines[i]
            st = ln.strip()
            if st.startswith("#"):
                continue
            # a bare echo/printf of a human-readable log line, not redirected
            if re.match(r'^(echo|printf)\b', st) and ">&2" not in ln:
                if "[domum-media]" in ln or "WARN" in ln or "ERROR" in ln or "Snapshot" in ln:
                    bad.append((name, i + 1, st[:96]))
            # External commands that chatter on stdout are the same defect
            # arriving from outside. `btrfs subvolume snapshot` prints
            # "Create readonly snapshot of ..." -- the stubbed btrfs in the unit
            # tests printed nothing and hid this until the real tool ran.
            #
            # Only `btrfs` is checked. Its stdout is never a return value in this
            # codebase, whereas `docker`'s legitimately is (htpasswd_hash returns
            # the hash a container printed), so flagging docker would be noise.
            m2 = re.match(r'^(?:if\s+)?!?\s*btrfs\s+\S', st)
            if m2 and ">&2" not in ln and ">/dev/null" not in ln:
                bad.append((name, i + 1, "unredirected btrfs: " + st[:80]))
    print(f"== {f}: {len(funcs)} functions, {len(captured)} captured with $()")
    for name, lineno, text in bad:
        print(f"   !! {name}  line {lineno}: {text}")
    if bad:
        found_any = True
    else:
        print("   no captured function logs a human-readable line to stdout")

sys.exit(1 if found_any else 0)
