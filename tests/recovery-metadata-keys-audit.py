#!/usr/bin/env python3
"""Every recovery-metadata key that is READ must be one the writer EMITS.

A reader using a key the writer never produces does not fail: `sed -nE` simply
matches nothing and the value is silently empty. Measured: new code read
`CONTAINER_1_IMAGE_VERSION` while the writer emits
`CONTAINER_1_IMAGE_LABEL_VERSION`, so a version field would have been blank
forever and no test would have noticed -- the surrounding output was still
well-formed.

This compares the two sets directly. It is deliberately a whole-file audit
rather than a per-function one: a key is a contract between two places that are
nowhere near each other in the file.
"""
import re
import sys
from pathlib import Path

CLI = Path(__file__).resolve().parent.parent / "bin" / "domum-media"


def normalise(key: str) -> str:
    """CONTAINER_1_X, CONTAINER_${n}_X and CONTAINER_%s_X all describe one key."""
    return re.sub(r"CONTAINER_(?:\d+|\$\{n\}|%s)_", "CONTAINER_N_", key)


def main() -> int:
    text = CLI.read_text()
    # Strip comments: prose naming a key is not a use of it.
    code = "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("#")
    )

    written = {
        normalise(m)
        for m in re.findall(r"printf \"((?:CONTAINER_%s_)?[A-Z][A-Z0-9_]*)=", code)
    }
    # Readers use `sed -nE "s/^KEY='(.*)'$/\1/p"` or grep -F "KEY='...'".
    read = {
        normalise(m)
        for m in re.findall(r"\^((?:CONTAINER_(?:\d+|\$\{n\})_)?[A-Z][A-Z0-9_]*)='", code)
    }
    read |= {
        normalise(m)
        for m in re.findall(r"grep -qF \"((?:CONTAINER_\d+_)?[A-Z][A-Z0-9_]*)='", code)
    }

    if not written or not read:
        print(f"FAIL: audit found nothing to compare (written={len(written)} read={len(read)})")
        print("      the extraction patterns no longer match the code; fix this audit")
        return 1

    orphans = sorted(read - written)
    print(f"== recovery metadata keys: {len(written)} written, {len(read)} read")
    if orphans:
        print("FAIL: key(s) read but never written -- these are silently always empty:")
        for k in orphans:
            print(f"   !! {k}")
        print("      Either the writer should emit it, or the reader has a typo.")
        return 1
    # Not an error: plenty of keys are written for the operator to read, not for
    # code to consume. Reported so the asymmetry stays visible.
    unread = sorted(written - read)
    print(f"   {len(unread)} key(s) written but not read back by code (informational)")
    print("PASS: recovery metadata keys audit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
