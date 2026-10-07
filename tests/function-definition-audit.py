#!/usr/bin/env python3
"""Every project function CALLED must be DEFINED somewhere in its scope.

`bash -n` cannot catch this. A function call is an ordinary command, resolved at
run time, so a missing definition is a syntax-clean script that dies with
"command not found" the moment that branch executes. shellcheck does not report
it either, and a function no test invokes is never exercised.

Measured: `service_upgrade` called `assert_pre_upgrade_possible`, a helper from a
refactor that was attempted, broke, and was reverted -- leaving the call behind.
`bash -n` passed, shellcheck passed, 41 suites passed, CI was green, and the code
reached production. `domum-media updates apply --service plex` would have died on
its first run, inside an upgrade, after stopping the container.

SCOPES
  bin/domum-media-report is not a program: its own header says it is sourced by
  domum-media so it can reuse the canonical config and service inventory
  functions. It therefore shares one namespace with domum-media -- it calls
  load_cfg/service_data_path from there, and domum-media calls report_cmd from
  it. Auditing either alone reports the other half as undefined. The two
  standalone entrypoints get their own scopes.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Each scope is one runtime namespace: every file in it is loaded together.
SCOPES = [
    ("domum-media + sourced report fragment",
     ["bin/domum-media", "bin/domum-media-report"]),
    ("domum-media-backup", ["bin/domum-media-backup"]),
    ("install.sh", ["install.sh"]),
]

DEF = re.compile(r"^\s*([a-z_][a-z0-9_]*)\s*\(\)\s*\{")

# Command position, conservatively. `(` and `{` are deliberately NOT treated as
# delimiters: `(( v_epoch < v_ok_epoch ))` is arithmetic and `${#auto_units[@]}`
# is an array length -- both look like calls after a naive split, and both were
# false positives when this audit was first written.
CALL_PATTERNS = [
    re.compile(r"^\s*([a-z_][a-z0-9_]{2,})(?=\s|$)"),
    re.compile(r"(?:;|\|\||&&|\||&)\s*([a-z_][a-z0-9_]{2,})(?=\s|;|$)"),
    re.compile(r"\b(?:then|do|else|elif|if|while|until)\s+([a-z_][a-z0-9_]{2,})(?=\s|;|$)"),
    # command substitution -- $(func ...), but never $(( arithmetic ))
    re.compile(r"\$\((?!\()\s*([a-z_][a-z0-9_]{2,})(?=\s|\)|$)"),
]

SHELL_WORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "function", "select", "time", "in", "return", "break",
    "continue", "local", "declare", "typeset", "readonly", "export", "unset",
    "shift", "set", "eval", "exec", "exit", "trap", "wait", "read", "echo",
    "printf", "cd", "pwd", "test", "source", "alias", "command", "builtin",
    "let", "mapfile", "readarray", "shopt", "getopts", "hash", "type", "umask",
    "jobs", "kill", "true", "false", "caller", "enable", "logout", "bind",
    "compgen", "complete", "disown", "fg", "bg", "suspend", "ulimit", "times",
}


def externals():
    found = set()
    for d in os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin").split(":"):
        p = Path(d)
        if not p.is_dir():
            continue
        try:
            found.update(f.name for f in p.iterdir())
        except OSError:
            continue
    return found


def masked_lines(text):
    """Yield (lineno, masked_line, raw_line) with non-code spans blanked out.

    This has to be a real lexer, not a set of special cases. The three false
    positives this replaced were all embedded languages or continuations:

      awk -v service=... '/^services:/ { in_services = 1 ... }'
      jq -r '{ tag_name, html_url, published_at }'
      compose_cmd up -d --force-recreate \\
        immich_postgres immich_redis immich_machine_learning immich_server

    The awk and jq bodies are single-quoted data; the service names are
    arguments on a continuation line. None is a command position.

    Single-quoted and double-quoted spans are blanked, EXCEPT that a `$( ... )`
    inside a double-quoted span returns to code state -- `x="$(func)"` is one of
    the most common real call sites in this codebase and must stay visible.
    Heredoc bodies are blanked entirely.
    """
    stack = ["code"]
    heredoc_term = None
    prev_continued = False
    hd = re.compile(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?")

    for lineno, line in enumerate(text.split("\n"), 1):
        if heredoc_term is not None:
            if line.strip() == heredoc_term:
                heredoc_term = None
            continue

        out, i, n = [], 0, len(line)
        while i < n:
            st = stack[-1]
            c = line[i]
            if st == "squote":
                if c == "'":
                    stack.pop()
                out.append(" ")
                i += 1
            elif st == "dquote":
                if c == "\\":
                    out.append("  ")
                    i += 2
                    continue
                if c == '"':
                    stack.pop()
                    out.append(" ")
                    i += 1
                    continue
                if line.startswith("$(", i) and not line.startswith("$((", i):
                    stack.append("code")
                    out.append("$(")
                    i += 2
                    continue
                out.append(" ")
                i += 1
            else:  # code
                if c == "\\":
                    out.append("  ")
                    i += 2
                    continue
                if c == "#" and (i == 0 or line[i - 1] in " \t;|&"):
                    break  # comment runs to end of line
                if c == "'":
                    stack.append("squote")
                    out.append(" ")
                    i += 1
                    continue
                if c == '"':
                    stack.append("dquote")
                    out.append(" ")
                    i += 1
                    continue
                if line.startswith("$(", i) and not line.startswith("$((", i):
                    stack.append("code")
                    out.append("$(")
                    i += 2
                    continue
                if c == ")" and len(stack) > 1:
                    stack.pop()
                    out.append(")")
                    i += 1
                    continue
                out.append(c)
                i += 1

        masked = "".join(out)

        # A heredoc opener puts the following lines out of scope entirely.
        # This must read the RAW line: the lexer blanks the quotes in <<'EOF',
        # so the terminator is no longer visible in the masked form.
        if "<<" in line:
            m = hd.search(line)
            if m:
                heredoc_term = m.group(1)

        # Arithmetic is not command position: (( now_m >= start_m && now_m ... ))
        masked = re.sub(r"\(\(.*?\)\)", "  ", masked)

        continued = line.rstrip().endswith("\\")
        if prev_continued:
            # Arguments on a continuation line, not a command.
            prev_continued = continued
            continue
        prev_continued = continued

        yield lineno, masked, line


def main():
    ext = externals()
    problems, total_defs, total_calls = [], 0, 0

    for label, rels in SCOPES:
        paths = [ROOT / r for r in rels if (ROOT / r).is_file()]
        if not paths:
            continue
        defined, calls = set(), []
        for path in paths:
            raw = path.read_text()
            for line in raw.split("\n"):
                m = DEF.match(line)
                if m:
                    defined.add(m.group(1))
            for lineno, masked, raw_line in masked_lines(raw):
                for pat in CALL_PATTERNS:
                    for m in pat.finditer(masked):
                        word = m.group(1)
                        rest = masked[m.end(1):]
                        # `name=value` / `name = value` is an assignment,
                        # `name(` is a definition
                        if rest[:1] in ("=", "(") or rest.lstrip()[:1] == "=":
                            continue
                        calls.append((path, lineno, word, raw_line.strip()))
        if not defined:
            print(f"FAIL: no definitions found in {label}; the audit's DEF "
                  f"pattern no longer matches the source")
            return 1
        total_defs += len(defined)
        names = {c[2] for c in calls}
        total_calls += len(names)
        print(f"== {label}: {len(defined)} defined, {len(names)} distinct "
              f"call-shaped words")
        seen = set()
        for path, lineno, word, src in calls:
            if word in defined or word in SHELL_WORDS or word in ext:
                continue
            if "_" not in word or word in seen:
                continue
            seen.add(word)
            problems.append((path.relative_to(ROOT), lineno, word, src))

    if not total_calls:
        print("FAIL: the audit matched no call-shaped words at all; its "
              "patterns are broken")
        return 1

    if problems:
        print("\nFAIL: called but never defined -- these die at run time:")
        for rel, lineno, word, src in problems:
            print(f"   !! {rel}:{lineno}  {word}")
            print(f"      {src[:100]}")
        print("\n      bash -n cannot catch this. Define it, or remove the call.")
        return 1
    print(f"\nPASS: function definition audit ({total_defs} definitions, "
          f"{total_calls} call sites resolved)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
