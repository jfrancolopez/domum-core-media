#!/usr/bin/env python3
"""Operator wrappers must assert on contracts, not on internals or prose.

Three wrappers have now aborted correct production states, each by asserting on
something that was never a contract:

  1. a stale topology invariant ("no subvolumes exist") -- true before the first
     migration, permanently false after it;
  2. a grep for the prose line `recovery point  : verified` -- the wording
     changed when the summary was split into four claims;
  3. a grep for `make_pre_upgrade_point()` in the installed binary -- a private
     function from a refactor that was attempted and reverted, so it had never
     existed in any merged revision.

All three escaped review because operator scripts lived outside the repository
and therefore outside CI. They are in `operator/` now, and this audit fails if:

  * a private function name defined in bin/domum-media is grepped for;
  * a `domum-media` invocation is piped into grep/sed/awk to extract a fact,
    unless it is the `--json` structured interface;
  * a capability token is required that the CLI does not advertise.

What a wrapper MAY assert on: exit status, files, docker/btrfs/systemd output,
checksums, and `capabilities --has`.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "domum-media"
OPERATOR_DIR = ROOT / "operator"


def cli_functions():
    return set(re.findall(r"^([a-z_][a-z0-9_]*)\(\) \{", CLI.read_text(), re.M))


def cli_capabilities():
    src = CLI.read_text()
    m = re.search(r"domum_capability_specs\(\) \{\n  cat <<'EOF'\n(.*?)EOF", src, re.S)
    if not m:
        return set()
    return {l.split("|")[0] for l in m.group(1).strip().split("\n") if "|" in l}


def code_lines(text):
    for i, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        yield i, line


def main():
    if not OPERATOR_DIR.is_dir():
        print("FAIL: operator/ does not exist. Operator wrappers belong in the "
              "repository, which is the whole point of this audit.")
        return 1
    scripts = sorted(OPERATOR_DIR.glob("*.sh"))
    if not scripts:
        print("FAIL: no operator scripts found; this audit would pass vacuously")
        return 1

    funcs = cli_functions()
    caps = cli_capabilities()
    if not funcs or not caps:
        print("FAIL: could not read the CLI's functions or capability table; "
              "this audit cannot do its job")
        return 1

    problems = []
    for script in scripts:
        text = script.read_text()
        rel = script.relative_to(ROOT)
        for lineno, line in code_lines(text):
            # 1a. grepping the CLI's SOURCE, whatever the pattern.
            #
            # This is the rule that catches the historical defect's actual
            # shape. It looped over function names in a variable:
            #
            #   for fn in service_upgrade ... make_pre_upgrade_point ...; do
            #     grep -q "^$fn()" /usr/local/bin/domum-media || abort ...
            #
            # so no literal function name appears on the grep line and a
            # name-based rule misses it entirely. The binary's TEXT is not a
            # contract at all -- only its behaviour is.
            if "grep" in line and re.search(
                    r"(?:/usr/local/bin/domum-media|bin/domum-media|\$\{?CLI\}?)"
                    r"\s*\\?\s*$", line):
                problems.append((rel, lineno,
                    "greps the CLI's SOURCE. Its text is not a contract; ask it "
                    "what it supports with `capabilities --has <token>`.", line))

            # 1b. a private function name used as an assertion target
            for name in re.findall(r"[\"']\^?([a-z_][a-z0-9_]{2,})\(\)", line):
                if name in funcs:
                    problems.append((rel, lineno,
                        f"greps for the private function {name}(). Ask the CLI "
                        f"what it SUPPORTS: `capabilities --has <token>`.", line))
            # a bare mention of a private function inside a grep argument
            if "grep" in line:
                for name in re.findall(r"\b([a-z_][a-z0-9_]{2,})\b", line):
                    if name in funcs and name not in ("grep",):
                        problems.append((rel, lineno,
                            f"greps for the private function name {name}. A "
                            f"refactor must not break an operator wrapper.", line))

            # 2. parsing a domum-media invocation's prose
            if re.search(r"\$?\{?CLI\}?|domum-media", line) and re.search(r"\|\s*(grep|sed|awk)", line):
                if "--json" not in line and "capabilities" not in line:
                    problems.append((rel, lineno,
                        "pipes a domum-media invocation into grep/sed/awk. Its "
                        "prose is not a contract -- use --json, a purpose-built "
                        "subcommand, or exit status.", line))

            # 3. a capability token the CLI does not advertise
            m = re.search(r"capabilities --has\s+(\S+)", line)
            if m and not m.group(1).startswith(("$", '"', "'")):
                if m.group(1) not in caps:
                    problems.append((rel, lineno,
                        f"requires capability '{m.group(1)}', which the CLI does "
                        f"not advertise.", line))

        # Capability tokens listed in a NEEDED_CAPS-style block must all exist.
        for m in re.finditer(r"NEEDED_CAPS=\"([^\"]*)\"", text, re.S):
            for tok in m.group(1).split():
                if tok not in caps:
                    problems.append((rel, 0,
                        f"requires capability '{tok}', which the CLI does not "
                        f"advertise. Either add it to domum_capability_specs or "
                        f"stop requiring it.", tok))

    print(f"== {len(scripts)} operator script(s), {len(funcs)} CLI functions, "
          f"{len(caps)} capabilities")
    if problems:
        print("\nFAIL: operator wrapper assertion violations:")
        for rel, lineno, msg, src in problems:
            where = f"{rel}:{lineno}" if lineno else f"{rel}"
            print(f"   !! {where}  {msg}")
            print(f"      {src.strip()[:96]}")
        return 1
    for s in scripts:
        print(f"  ok  {s.relative_to(ROOT)}")
    print("\nPASS: operator wrapper audit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
