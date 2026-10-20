"""No git conflict marker may be committed to a tracked text file.

Four `|||||||` lines reached `main` inside CLAUDE.md -- the file that holds this
project's operating rules -- and sat there through several merges and CI runs.

The cause: `merge.conflictStyle` is `zdiff3` here, so a conflict carries THREE
sections, not two:

    <<<<<<< HEAD
    ours
    ||||||| base            <- the one that was missed
    the common ancestor
    =======
    theirs
    >>>>>>> commit

The resolver used to land those merges handled `<<<<<<<`, `=======` and
`>>>>>>>`, kept "both sides", and silently treated the `|||||||` line and the
base text as ordinary content. Nothing noticed, because a stray line in a
Markdown file breaks no test and renders as plain text.

`=======` is deliberately NOT matched on its own: it is legitimate Markdown
setext-style heading underlining, so flagging it would fire on ordinary
documents. The other three forms have no legitimate use at the start of a line.
"""
import re
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent

MARKER = re.compile(r'^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)')
# Binary-ish things git tracks that would never hold a resolvable conflict.
SKIP_SUFFIX = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf',
               '.gz', '.xz', '.zst', '.tar', '.zip', '.age'}


def tracked_files():
    out = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z'],
                         capture_output=True, text=True, check=True)
    return [f for f in out.stdout.split('\0') if f]


def main():
    bad = []
    scanned = 0
    for rel in tracked_files():
        path = ROOT / rel
        if path.suffix.lower() in SKIP_SUFFIX or not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for i, line in enumerate(text.split('\n'), 1):
            if MARKER.match(line):
                bad.append((rel, i, line[:88]))

    print("== scanned %d tracked text file(s)" % scanned)
    if not scanned:
        print("FAIL: no files were scanned; this audit would pass vacuously")
        return 1
    for rel, i, line in bad:
        print("   !! %s:%d  %s" % (rel, i, line))
    if bad:
        print("\nFAIL: a git conflict marker is committed. With conflictStyle "
              "zdiff3 a conflict has THREE sections -- resolve the `|||||||` "
              "base section too, not just ours/theirs.")
        return 1
    print("   no conflict marker in any tracked text file")
    return 0


if __name__ == '__main__':
    sys.exit(main())
