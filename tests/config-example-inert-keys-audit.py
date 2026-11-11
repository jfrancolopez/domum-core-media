#!/usr/bin/env python3
"""A config key that is REFERENCED but whose value nothing reads is still inert.

This is the second class of the defect the dead-key audit covers, and the
dead-key audit cannot see it: the key appears in the code, so "is it referenced"
answers yes. What makes it inert is that every occurrence is PLUMBING -- its own
export, its load_cfg default, or a `configure`/`config_set` line that WRITES it --
with nothing that reads the value to decide anything.

It is the worse half of the family, because `configure` PROMPTS for some of these.
Being asked a question asserts that the answer matters. Measured 2026-11-10:

  DOMUM_TS_IP                     exported + prompted. No dynamic route
                                  referenced it and no document mentioned it,
                                  though its own comment claimed both. Removed.
  IMMICH_HOST                     exported + prompted, while the Immich route
                                  hardcodes Host(`photos.${DOMUM_DOMAIN}`).
  IMMICH_BUNDLE_ROLLBACK_ENABLED  exported + prompted; rollback follows
                                  AUTO_ROLLBACK_ENABLED, prompted for on the
                                  line immediately before.

CONTINUATIONS ARE JOINED, and that is not optional. A `config_set` whose prompt
default sits on the next physical line puts `${KEY:-...}` on a line with no
`config_set` on it, so a line-at-a-time scan reads it as a genuine read and
reports ZERO inert keys -- measured, this audit found 0 before joining and 3
after. That is the blind spot `tests/pipefail-grep-audit.py` already records.

A key may be exempted with `# inert-audit: <reason>` ON ITS OWN LINE in the
example -- not the line before, which drifts away from what it vouches for.
Every exemption is PRINTED, because an allowance nobody can see is how a real
defect gets a marker stuck on it. An exemption for a key that is NOT inert is
itself reported, so a marker cannot outlive the defect it describes.
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
# Helpers that WRITE a key rather than read it. A helper missing from this list
# causes a FALSE NEGATIVE (the key reads as live), never a false alarm, so the
# list going stale is the safe direction.
SETTERS = (
    "config_set",
    "configure_text_value",
    "configure_service_toggle",
    "configure_image_behavior",
    "configure_secret_file_prompt",
    "configure_generated_secret_prompt",
    "configure_multiline_secret_prompt",
)


def join_continuations(body, strip_comments):
    lines, buf = [], ""
    for line in body.split("\n"):
        code = line.split("#", 1)[0] if strip_comments else line
        if code.rstrip().endswith("\\"):
            buf += code.rstrip()[:-1] + " "
            continue
        lines.append(buf + code)
        buf = ""
    if buf:
        lines.append(buf)
    return lines


def example_keys_and_markers(path):
    keys, exempt = [], {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"\s*([A-Z][A-Z0-9_]*)=", line)
            if not m:
                continue
            key = m.group(1)
            keys.append(key)
            mk = re.search(r"#\s*inert-audit:\s*(.+?)\s*$", line)
            if mk:
                exempt[key] = mk.group(1)
    return sorted(set(keys)), exempt


def consumers():
    out = []
    for pattern in CONSUMERS:
        for path in glob.glob(pattern, recursive=True):
            if os.path.isfile(path):
                yml = path.endswith((".yml", ".yaml"))
                with open(path, encoding="utf-8", errors="replace") as fh:
                    out.append((path, join_continuations(fh.read(), not yml)))
    return out


def plumbing(line, key):
    if re.search(r"(^|\s)export\s+" + key + r"=", line):
        return True
    if re.match(r"\s*" + key + r"=", line):
        return True
    return any(re.search(s + r'\s+"?' + key + r"\b", line) for s in SETTERS)


def main():
    if not os.path.isfile(EXAMPLE):
        print("FAIL: %s is missing" % EXAMPLE)
        return 1

    keys, exempt = example_keys_and_markers(EXAMPLE)
    files = consumers()
    if not keys:
        print("FAIL: no keys parsed from %s -- the parser or the file is broken" % EXAMPLE)
        return 1
    if len(files) < 10:
        print("FAIL: only %d consumer file(s) found -- the target globs are stale" % len(files))
        return 1

    inert, seen = [], 0
    for key in keys:
        occ = [l for _, lines in files for l in lines if re.search(r"\b" + key + r"\b", l)]
        if not occ:
            continue  # the dead-key audit owns this case
        seen += 1
        if not [l for l in occ if not plumbing(l, key)]:
            inert.append(key)

    print("== %d of %d example key(s) are referenced by a consumer" % (seen, len(keys)))
    for key, reason in sorted(exempt.items()):
        state = "inert" if key in inert else "NOT inert any more"
        print("   exempt: %-32s [%s] %s" % (key, state, reason))

    stale = sorted(k for k in exempt if k not in inert)
    unexplained = sorted(k for k in inert if k not in exempt)

    if stale:
        print()
        print("FAIL: %d exemption(s) describe a key that is no longer inert:" % len(stale))
        for key in stale:
            print("   %s -- remove the marker" % key)
        return 1

    if unexplained:
        print()
        print("FAIL: %d key(s) are referenced but nothing reads the value:" % len(unexplained))
        for key in unexplained:
            print("   %s" % key)
        print()
        print("   Every occurrence is its own export, its load_cfg default, or a")
        print("   configure/config_set that WRITES it. Wire it to the behaviour it")
        print("   names, remove it, or mark it `# inert-audit: <reason>` on its own line.")
        return 1

    print("   every referenced key's value is read somewhere")
    return 0


if __name__ == "__main__":
    sys.exit(main())
