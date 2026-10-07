#!/usr/bin/env python3
"""Every advertised capability must be reachable from the command line.

A capability token is a promise to operator scripts. If the token can be
advertised without the behaviour being dispatchable, the contract is worth less
than the private-function greps it replaced -- a script would get a confident
"supported" and then a usage error.

`capabilities_cmd` checks the implementation with `declare -F` at run time, which
is the half that matters on the operator's host: a token disappears if its
implementation does. This audit covers the half that check cannot see -- that the
advertised argv path is actually ROUTED to that implementation by the real
dispatcher.

It walks `main()`'s case statement, then each subcommand dispatcher in turn, and
follows calls transitively (bounded) from the branch that handles the path. A
capability whose dispatcher line is deleted stops being reachable and fails here.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "domum-media"
MAX_DEPTH = 4


def read():
    return CLI.read_text()


def func_body(src, name):
    """The text of a top-level function definition, brace-matched."""
    m = re.search(rf"^{re.escape(name)}\(\) \{{", src, re.M)
    if not m:
        return None
    i = m.end() - 1
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    return None


def strip_comments(text):
    """Remove comment lines and trailing comments.

    Without this the audit is fooled by prose. The `apply` branch of updates_cmd
    carries a comment explaining what `service_upgrade` does, so deleting the
    actual CALL left the name still present in the branch text and the
    capability still looked dispatchable. A comment is documentation, not wiring.
    """
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        # a ` #` outside quotes starts a trailing comment; good enough here
        i = line.find(" #")
        out.append(line[:i] if i != -1 else line)
    return "\n".join(out)


def defined_functions(src):
    return set(re.findall(r"^([a-z_][a-z0-9_]*)\(\) \{", src, re.M))


def toplevel_routes(src):
    """token -> function, from main()'s case statement."""
    body = func_body(src, "main")
    if body is None:
        return {}
    routes = {}
    # `token)  shift; func "$@" ;;` and multi-line branches alike: take the
    # first function call inside the branch.
    for m in re.finditer(r"^\s{4}([a-z][a-z0-9|_-]*)\)\s*$|^\s{4}([a-z][a-z0-9|_-]*)\)(.*)$",
                         body, re.M):
        toks = m.group(1) or m.group(2)
        rest = m.group(3) or ""
        start = m.end()
        # branch text runs to the next `;;`
        end = body.find(";;", start)
        branch = rest + (body[start:end] if end != -1 else "")
        for tok in toks.split("|"):
            routes[tok] = branch
    return routes


def branch_end(body, start):
    """Index of the `;;` closing a branch that begins at `start`.

    Must track nested case/esac: the `topology)` branch contains an inner case
    whose first `;;` is not the end of the outer branch. Taking the first `;;`
    silently truncated the branch and hid `--verify)` entirely.
    """
    depth, i = 0, start
    while i < len(body):
        if re.match(r"\bcase\b", body[i:]):
            depth += 1
            i += 4
            continue
        if re.match(r"\besac\b", body[i:]):
            depth -= 1
            i += 4
            continue
        if body.startswith(";;", i) and depth == 0:
            return i
        i += 1
    return len(body)


def case_branch(body, word):
    """The text of the case branch handling `word`, or None."""
    for m in re.finditer(r"^\s*([a-z0-9|_\"${}:-]+)\)", body, re.M):
        pats = m.group(1).replace('"', "")
        if word not in pats.split("|"):
            continue
        start = m.end()
        return body[start:branch_end(body, start)]
    return None


def reachable_text(src, seed, defined, depth=MAX_DEPTH):
    """Union of `seed` and the bodies of functions it transitively calls."""
    seed = strip_comments(seed)
    seen, texts, frontier = set(), [seed], [(seed, depth)]
    while frontier:
        text, d = frontier.pop()
        if d <= 0:
            continue
        for name in re.findall(r"\b([a-z_][a-z0-9_]{2,})\b", text):
            if name not in defined or name in seen:
                continue
            seen.add(name)
            b = func_body(src, name)
            if b:
                b = strip_comments(b)
                texts.append(b)
                frontier.append((b, d - 1))
    return "\n".join(texts), seen


def main():
    src = read()
    defined = defined_functions(src)
    spec_body = func_body(src, "domum_capability_specs")
    if not spec_body:
        print("FAIL: domum_capability_specs() is not defined")
        return 1

    rows = []
    for line in spec_body.split("\n"):
        line = line.strip()
        if line.count("|") == 2 and not line.startswith("#"):
            rows.append(line.split("|"))
    if not rows:
        print("FAIL: the capability table is empty, or its format changed and this "
              "audit can no longer read it")
        return 1

    routes = toplevel_routes(src)
    if not routes:
        print("FAIL: could not read main()'s case statement; this audit is blind")
        return 1

    problems, tokens = [], set()
    for token, argv, impl in rows:
        argv_words = argv.split()
        if token in tokens:
            problems.append(f"{token}: advertised twice")
            continue
        tokens.add(token)

        if impl not in defined:
            problems.append(f"{token}: implementation {impl}() is not defined")
            continue

        head = argv_words[0]
        if head not in routes:
            problems.append(f"{token}: main() does not route '{head}'")
            continue

        body = routes[head]
        # Flags are often consumed by an option loop in an ancestor dispatcher
        # rather than inside the final branch -- `cleanup_cmd` parses --json
        # before it ever reaches `images)`. So flag handling is verified against
        # every body on the path, not just the last one.
        path_bodies = [body]
        # Descend through subcommand words; collect flags to verify on the way.
        flags = [w for w in argv_words[1:] if w.startswith("--")]
        ok = True
        for word in argv_words[1:]:
            if word.startswith("--"):
                continue
            # The branch may delegate to a dispatcher function.
            called = [n for n in re.findall(r"\b([a-z_][a-z0-9_]*)\b",
                                             strip_comments(body))
                      if n in defined]
            nxt = None
            for name in called:
                b = func_body(src, name)
                if b and case_branch(b, word) is not None:
                    path_bodies.append(b)
                    nxt = case_branch(b, word)
                    break
            if nxt is None:
                nxt = case_branch(body, word)
            if nxt is None:
                problems.append(f"{token}: no dispatcher branch handles '{word}' "
                                f"in the '{head}' path")
                ok = False
                break
            body = nxt
            path_bodies.append(body)
        if not ok:
            continue

        text, _ = reachable_text(src, body, defined)
        flag_text = text + "\n" + strip_comments("\n".join(path_bodies))
        if not re.search(rf"\b{re.escape(impl)}\b", text) \
           and not re.search(rf"\b{re.escape(impl)}\b", strip_comments(body)):
            problems.append(f"{token}: '{argv}' does not reach {impl}() -- the "
                            f"capability is advertised but not dispatchable")
            continue
        for flag in flags:
            if flag not in flag_text:
                problems.append(f"{token}: '{argv}' reaches {impl}() but nothing "
                                f"on that path handles {flag}")

    print(f"== {len(rows)} capabilities declared, {len(routes)} top-level routes")
    if problems:
        print("\nFAIL: capability contract violations:")
        for p in problems:
            print(f"   !! {p}")
        return 1
    for token, argv, impl in rows:
        print(f"  ok  {token:34s} {argv:42s} -> {impl}()")
    print("\nPASS: capabilities contract audit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
