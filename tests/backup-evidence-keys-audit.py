#!/usr/bin/env python3
"""Every key read from the backup EVIDENCE files must be one a writer emits.

A reader sourcing a key the writer never emits does not fail: the variable is
simply unset, `${KEY:-}` is empty, and the output is still well-formed. That
exact defect shipped once already -- new code read `..._IMAGE_VERSION` while
the writer emitted `..._IMAGE_LABEL_VERSION` -- and
`tests/recovery-metadata-keys-audit.py` now guards it WITHIN `bin/domum-media`.

This guards the harder case: the `<target>-run.env`, `<target>-check.env` and
`<target>-retention.env` evidence is written in `bin/domum-media-backup` and
read in `bin/domum-media` and `bin/domum-media-report`. A contract whose two
ends are in different files has nothing to make a mismatch visible, and these
records are what let the report tell "the last scheduled run failed and nothing
has verified the repository since" from "it failed and has since been
verified".

Both ends are mechanically extractable, which is why this is a real audit and
not a heuristic:

  writer   printf 'KEY=...' inside the recording function
  reader   unset KEY1 KEY2 ... immediately before `. "$file"`, which readers
           do anyway so a stale inherited value cannot be mistaken for a read
           one

READERS classifies each reader function by the evidence kind it sources. The
table cannot silently go stale: reader sites are DISCOVERED from the file-path
expression, and a discovered function the table does not classify is a
failure, not a skip.

Exit 0 clean, 1 a mismatch, an unclassified reader, or a scan that found
nothing to check.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

WRITERS = {
    # evidence kind -> the function in bin/domum-media-backup that writes it
    "run": "record_backup_target_run",
    "op": "record_restic_operation",
}

READERS = {
    # reader function -> the evidence kind it sources
    "restic_op_last_success": "op",
    "backup_run_last_success": "run",
    "report_backup_target_state": "run",
    # Found by this audit's own discovery on its FIRST run, having been missed
    # when the table was written by hand. That is what "fail on an
    # unclassified reader" is for.
    "dr_last_success_run": "run",
}

# How a reader names the file it sources. Discovery is on these, so a new
# reader is found whether or not anyone remembers to list it above.
PATH_MARKERS = (
    "-run.env",
    "-$2.env",
    "restic_op_evidence_file",
)

READER_FILES = ("bin/domum-media", "bin/domum-media-report", "bin/domum-media-backup")
WRITER_FILE = "bin/domum-media-backup"


def strip_comments(text):
    """Prose naming a key is not a use of it -- the mistake four audits in this
    repository have each made once."""
    return "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("#")
    )


def functions(text):
    """-> [(name, start_line, end_line)] for top-level `name() {` blocks."""
    lines = text.split("\n")
    out = []
    current = None
    for i, line in enumerate(lines):
        m = re.match(r"^([a-z_][a-z0-9_]*)\(\) \{", line)
        if m:
            if current:
                out.append((current[0], current[1], i - 1))
            current = (m.group(1), i)
        elif line == "}" and current:
            out.append((current[0], current[1], i))
            current = None
    if current:
        out.append((current[0], current[1], len(lines) - 1))
    return out


def written_keys(text, func):
    for name, start, end in functions(text):
        if name != func:
            continue
        body = "\n".join(text.split("\n")[start:end + 1])
        return set(re.findall(r"printf '([A-Z][A-Z0-9_]*)=", body))
    return None


def main():
    writer_text = strip_comments((ROOT / WRITER_FILE).read_text())
    written = {}
    for kind, func in WRITERS.items():
        keys = written_keys(writer_text, func)
        if not keys:
            print("!! the writer %s() was not found in %s, or emits no key"
                  % (func, WRITER_FILE))
            return 1
        written[kind] = keys
        print("   %-4s written by %s(): %s" % (kind, func, " ".join(sorted(keys))))

    problems = []
    checked = 0
    for rel in READER_FILES:
        path = ROOT / rel
        if not path.exists():
            problems.append("%s does not exist" % rel)
            continue
        text = strip_comments(path.read_text())
        lines = text.split("\n")
        for name, start, end in functions(text):
            body_lines = lines[start:end + 1]
            body = "\n".join(body_lines)
            if not any(marker in body for marker in PATH_MARKERS):
                continue
            # A writer is not a reader of itself.
            if name in WRITERS.values():
                continue
            unsets = re.findall(r"^\s*unset ([A-Z][A-Z0-9_ ]*)$", body, re.M)
            if not unsets:
                continue
            kind = READERS.get(name)
            if kind is None:
                problems.append(
                    "%s:%s() sources backup evidence and is not classified; add it "
                    "to READERS so its keys are checked" % (rel, name))
                continue
            keys = set()
            for u in unsets:
                keys |= set(u.split())
            missing = sorted(keys - written[kind])
            checked += 1
            status = "ok" if not missing else "MISMATCH"
            print("   %-8s %s:%s() [%s] reads %s"
                  % (status, rel, name, kind, " ".join(sorted(keys))))
            if missing:
                problems.append(
                    "%s:%s() reads %s from the '%s' evidence, which %s() never "
                    "emits -- the value would be silently empty"
                    % (rel, name, " ".join(missing), kind, WRITERS[kind]))

    for p in problems:
        print("!! %s" % p)
    print("   %d reader(s) checked against %d writer(s)" % (checked, len(written)))
    if checked < len(READERS):
        print("!! only %d of the %d declared reader(s) were discovered; the "
              "discovery markers are stale" % (checked, len(READERS)))
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
