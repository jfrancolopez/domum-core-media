#!/usr/bin/env python3
"""Every key in config/domum-media.conf.example must be consumed by something.

A dead key in the example is the defect family this project keeps correcting: a
surface that implies control it does not have. Measured 2026-11-10,
IMMICH_UPDATE_MODE and IMMICH_UPDATE_CHANNEL sat in a documented
"Update policy - Class C" section beside three keys that ARE read, with zero
references anywhere in the repository. Setting IMMICH_UPDATE_MODE=direct
therefore read as switching the update policy for the service this server exists
for, and did nothing -- and nothing would have told the operator.

WHY THE CORPUS IS CONSUMERS ONLY. It is bin/, install.sh, compose/, systemd/ and
operator/ -- the places that actually read configuration. tests/ is deliberately
excluded for two reasons, and the first is a trap this project has hit five
times: a test (or this audit's own docstring) that NAMES a key would make the key
read as live, so including tests/ would make the check unable to fail. The second
is that a key consumed only by a test is dead for production purposes anyway.

WHY IT DOES NOT CRY WOLF. Thirty of the example's keys are never written
literally in the code: the per-target backup settings are built as
BACKUP_TARGET_$(uppercase_token "$target")_${field}. That prefix is DERIVED from
the code rather than hardcoded here, so a new dynamic family is recognised
automatically and this audit does not need editing when one appears. Every
recognised family is PRINTED with the keys it covers, because an allowance
nobody can see is how a real defect gets a marker stuck on it.
"""

import glob
import os
import re
import sys

EXAMPLE = "config/domum-media.conf.example"
CONSUMERS = (
    "bin/*",
    "install.sh",
    "compose/**/*.yml",
    "compose/**/*.yaml",
    "systemd/*",
    "operator/*.sh",
    "operator/rehearsals/*.sh",
)


def example_keys(path):
    """Keys the example ASSIGNS, ignoring commented-out lines."""
    keys = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            code = line.split("#", 1)[0]
            m = re.match(r"\s*([A-Z][A-Z0-9_]*)=", code)
            if m:
                keys.append(m.group(1))
    return sorted(set(keys))


def consumer_corpus():
    files = []
    for pattern in CONSUMERS:
        for path in glob.glob(pattern, recursive=True):
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    files.append((path, fh.read()))
    return files


def main():
    if not os.path.isfile(EXAMPLE):
        print("FAIL: %s is missing" % EXAMPLE)
        return 1

    keys = example_keys(EXAMPLE)
    corpus = consumer_corpus()

    # Vacuity guards: a broken glob or an unreadable example must FAIL rather
    # than report a clean sweep over nothing.
    if not keys:
        print("FAIL: no keys parsed from %s -- the parser or the file is broken" % EXAMPLE)
        return 1
    if len(corpus) < 10:
        print("FAIL: only %d consumer file(s) found -- the target globs are stale" % len(corpus))
        return 1

    text = "\n".join(body for _, body in corpus)
    referenced = set(re.findall(r"[A-Z][A-Z0-9_]*", text))
    dynamic = sorted(set(re.findall(r'"([A-Z][A-Z0-9_]*)_\$[\({]', text)))

    unreferenced = [k for k in keys if k not in referenced]
    dead, by_family = [], {}
    for key in unreferenced:
        family = next((p for p in dynamic if key.startswith(p + "_")), None)
        if family is None:
            dead.append(key)
        else:
            by_family.setdefault(family, []).append(key)

    print("== scanned %d key(s) in %s against %d consumer file(s)"
          % (len(keys), EXAMPLE, len(corpus)))
    print("   dynamic families derived from the code: %s"
          % (", ".join(dynamic) if dynamic else "none"))
    for family, covered in sorted(by_family.items()):
        print("   %s_* built dynamically, covers %d key(s): %s"
              % (family, len(covered), ", ".join(covered)))

    if dead:
        print()
        print("FAIL: %d key(s) in %s are read by nothing:" % (len(dead), EXAMPLE))
        for key in dead:
            print("   %s" % key)
        print()
        print("   Either wire it to the behaviour it names, or remove it and say why.")
        print("   A key the operator can set that does nothing is a surface implying")
        print("   control it does not have.")
        return 1

    print("   every key is consumed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
