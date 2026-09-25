"""Scan for functions whose captured stdout can be contaminated.

A shell function that returns a value does so on stdout. Anything else written
there -- by the function itself, by an external command it runs, or by another
function it calls -- silently becomes part of that value for every
`x="$(fn ...)"` caller.

This has shipped three times in this repository:

  * `create_service_snapshot` logged a progress line to stdout;
  * `btrfs subvolume snapshot` printed "Create readonly snapshot of ..." there;
  * `record_rollback_entry`, which returns an id on stdout, was called from
    inside `create_service_snapshot` -- correct only because of a `>/dev/null`
    that nothing enforced.

The third is why this audit models the call graph one level deep.
"""
import re
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
FILES = ["bin/domum-media", "bin/domum-media-backup", "bin/domum-media-report"]

# `docker run` in htpasswd_hash legitimately returns the hash a container
# printed, so external-command chatter is only checked for btrfs, whose stdout
# is never a return value here.
CHATTY = re.compile(r"^(?:if\s+)?!?\s*btrfs\s+\S")
LOGLIKE = re.compile(r"\[domum-media\]|WARN|ERROR|Snapshot")


def functions(lines):
    """name -> (start, end) line indexes, for top-level `name() {` blocks."""
    out, open_at, name = {}, None, None
    for i, ln in enumerate(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", ln)
        if m:
            name, open_at = m.group(1), i
        elif ln == "}" and open_at is not None:
            out[name] = (open_at, i)
            open_at, name = None, None
    return out


def returns_on_stdout(lines, span):
    """True if the function's last effective statement prints a value."""
    for ln in reversed(lines[span[0]:span[1]]):
        st = ln.strip()
        if not st or st.startswith("#") or st in ("fi", "done", "esac", "}"):
            continue
        if st.startswith("return"):
            continue
        return bool(re.match(r"^(printf|echo)\b", st)) and ">&2" not in ln
    return False


def captured_names(src, names):
    """Functions whose output is consumed as a value: $( ) or < <( ).

    Pipelines are deliberately NOT counted. Matching `name ... |` pulled in every
    logging function that happens to appear before a pipe anywhere in the file,
    and an audit that cries wolf is one somebody switches off -- the same alert
    fatigue this codebase fixes elsewhere.
    """
    found = set()
    for n in names:
        e = re.escape(n)
        if (re.search(r"\$\(\s*" + e + r"[\s)]", src)
                or re.search(r"<\s*\(\s*" + e + r"[\s)]", src)):
            found.add(n)
    return found


def last_effective_line(lines, span):
    """Index of the function's last statement, skipping blanks/comments/enders."""
    for i in range(span[1] - 1, span[0], -1):
        st = lines[i].strip()
        if not st or st.startswith("#") or st in ("fi", "done", "esac"):
            continue
        return i
    return -1


bad_total = 0
for f in FILES:
    src = (ROOT / f).read_text()
    lines = src.split("\n")
    funcs = functions(lines)
    captured = captured_names(src, funcs)
    value_returning = {n for n, sp in funcs.items() if returns_on_stdout(lines, sp)}

    bad = []
    for name in sorted(captured):
        a, b = funcs[name]
        last_line = last_effective_line(lines, (a, b))
        for i in range(a, b + 1):
            ln = lines[i]
            st = ln.strip()
            if st.startswith("#"):
                continue
            redirected = ">&2" in ln or ">/dev/null" in ln
            # (1) the function logging to its own stdout
            if re.match(r"^(printf|echo)\b", st) and not redirected and LOGLIKE.search(ln):
                bad.append((name, i + 1, st[:92]))
            # (2) an external command chattering on stdout
            if CHATTY.match(st) and not redirected:
                bad.append((name, i + 1, "unredirected btrfs: " + st[:76]))
            # (3) calling another value-returning function for its SIDE EFFECTS
            # while leaking its stdout.
            #
            # A call on the function's LAST line is delegating the return value --
            # `read_secret_file_value` ending in `trim_spaces "$value"` is correct,
            # and flagging it would be noise. Anywhere else the stdout is not
            # wanted and has to be redirected. That is exactly the shape of the
            # record_rollback_entry case: a mid-function call whose only guard was
            # a `>/dev/null` nothing enforced.
            if i != last_line and not redirected:
                for callee in value_returning:
                    if callee == name:
                        continue
                    if re.match(r"^(?:if\s+|!\s*)?" + re.escape(callee) + r"(\s|$)", st):
                        bad.append((name, i + 1,
                                    "calls %s mid-function, leaking its stdout into this return value: %s"
                                    % (callee, st[:60])))

    print("== %s: %d functions, %d captured with $(), %d return a value on stdout"
          % (f, len(funcs), len(captured), len(value_returning)))
    for name, lineno, text in bad:
        print("   !! %s  line %d: %s" % (name, lineno, text))
    bad_total += len(bad)
    if not bad:
        print("   no captured function can be contaminated")

sys.exit(1 if bad_total else 0)
