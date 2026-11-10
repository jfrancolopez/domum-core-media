"""Reject infrastructure identifiers from tracked text files.

The audit intentionally reports only the finding category and location. It
never writes the matched address or account-like value to CI logs.
"""
import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
ACCOUNT = re.compile(r"(?<![A-Za-z0-9_])u\d{5,}(?!\d)")
PRODUCT_VERSION_FILE = "docs/RECOVERY-POINT-IDENTITY.md"


def tracked_files():
    result = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [name for name in result.stdout.split("\0") if name]


def ipv4_octets(value):
    """Return valid IPv4 octets, including leading-zero forms, or None."""
    try:
        octets = tuple(int(part) for part in value.split("."))
    except ValueError:
        return None
    if len(octets) != 4 or any(part > 255 for part in octets):
        return None
    return octets


def is_documented_product_version(rel, line, match):
    """Exclude the inline-labeled four-part product version, not arbitrary IPs."""
    if rel != PRODUCT_VERSION_FILE:
        return False
    before = line[:match.start()]
    after = line[match.end():]
    return (
        re.search(r"\bproduct version\s+`$", before, re.IGNORECASE) is not None
        and re.match(r"`\s*[—–]", after) is not None
    )


def private_address(octets):
    a, b, _c, _d = octets
    return (
        a == 10
        or (a == 172 and 16 <= b <= 31)
        or (a == 192 and b == 168)
    )


def finding_kind(rel, line, match):
    octets = ipv4_octets(match.group())
    if octets is not None:
        a, b, c, _d = octets
        if private_address(octets):
            # Existing 10.0.0.x documentation examples are intentionally allowed.
            if rel.startswith("docs/") and (a, b, c) == (10, 0, 0):
                return None
            # This exact documented Jellyfin product-version token looks like
            # RFC1918 when parsed as IPv4; it is not an address. Keep this
            # exception scoped to its file and inline "product version" label.
            if is_documented_product_version(rel, line, match):
                return None
            return "RFC1918 address"
        if a == 100 and 64 <= b <= 127:
            return "Tailscale CGNAT address"
    return None


def main():
    findings = []
    scanned = 0
    for rel in tracked_files():
        path = ROOT / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if "\0" in text:
            continue
        scanned += 1
        for line_number, line in enumerate(text.splitlines(), 1):
            for match in IPV4.finditer(line):
                kind = finding_kind(rel, line, match)
                if kind:
                    findings.append((kind, rel, line_number))
            for _match in ACCOUNT.finditer(line):
                findings.append(("backup account pattern", rel, line_number))

    print(f"== scanned {scanned} tracked text file(s)")
    if not scanned:
        print("FAIL: no text files were scanned; this audit would pass vacuously")
        return 1
    for kind, rel, line_number in findings:
        print(f"   !! {kind} [redacted] at {rel}:{line_number}")
    if findings:
        print("\nFAIL: remove or replace the infrastructure identifier; matched values are redacted.")
        return 1
    print("   no prohibited infrastructure identifiers found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
