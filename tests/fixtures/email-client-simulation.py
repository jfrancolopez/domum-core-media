#!/usr/bin/env python3
"""Simulate what each mail client does to the report HTML.

A CSS grep is not evidence of rendering. This applies the documented
transformation of each client and requires the report to survive it:

  Gmail       removes <head> and <style> entirely
  Apple Mail  honours both, plus color-scheme
  Outlook     Word engine: no flex/grid/position, table layout only
  text-only   all markup removed

Argv: the rendered HTML file. Exits non-zero with the reason on failure.
"""
import html as htmlmod
import re
import sys
from html.parser import HTMLParser


class Balance(HTMLParser):
    VOID = {"meta", "br", "img", "link", "hr", "input"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.bad = []

    def handle_starttag(self, tag, attrs):
        if tag not in self.VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack[-1] != tag:
            self.bad.append(tag)
        else:
            self.stack.pop()


def wellformed(html):
    p = Balance()
    p.feed(html)
    return not p.bad and not p.stack


def bodytext(html):
    html = re.sub(r"<style>.*?</style>", "", html, flags=re.S)
    html = re.sub(r"<head>.*?</head>", "", html, flags=re.S)
    stripped = re.sub(r"<[^>]+>", " ", html)
    return re.sub(r"\s+", " ", htmlmod.unescape(stripped)).strip()


def main(path):
    src = open(path, encoding="utf-8").read()
    fails = []

    if not wellformed(src):
        fails.append("the HTML is not well-formed")

    # --- Gmail: strips <head> and <style>. -------------------------------
    gmail = re.sub(r"<head>.*?</head>", "", src, flags=re.S)
    gmail = re.sub(r"<style>.*?</style>", "", gmail, flags=re.S)
    if not wellformed(gmail):
        fails.append("stripping <head>/<style> leaves malformed HTML")
    if bodytext(gmail) != bodytext(src):
        fails.append("Gmail stripping changes the report TEXT, not just its styling")
    if "keyframes" in gmail:
        fails.append("the style block was not actually stripped; the test proves nothing")
    for colour in ("#141a15", "#42e07d"):
        if colour not in gmail:
            fails.append("inline colour %s lost when <style> is stripped" % colour)
    if 'bgcolor="#141a15"' not in gmail:
        fails.append("no bgcolor= attribute fallback for the dark background")

    # --- Apple Mail: honours the style block and the colour-scheme hints --
    for need in ('content="dark"', "color-scheme:dark", "animation:dcb"):
        if need not in src:
            fails.append("Apple Mail hint missing: %s" % need)

    # --- Outlook: Word engine. -------------------------------------------
    if src.count("<table") < 2:
        fails.append("not a table layout; Outlook would not place the column")
    if re.search(r"display:\s*(flex|grid)|position:\s*(absolute|fixed)", src):
        fails.append("uses CSS the Word engine drops")
    if "background-image" in src:
        fails.append("a background image would not render")

    # --- text-only: the findings must survive total markup loss. ---------
    text = bodytext(src)
    for must in ("CRITICAL", "IMMICH & DISASTER RECOVERY"):
        if must not in text:
            fails.append("lost when markup is removed: %s" % must)

    if fails:
        for f in fails:
            print("  FAIL: %s" % f, file=sys.stderr)
        return 1
    print("  gmail: text identical, only the cursor animation lost")
    print("  apple mail: style block and colour-scheme hints intact")
    print("  outlook: table layout, no dropped CSS, no background image")
    print("  text-only: the findings survive total markup loss")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
