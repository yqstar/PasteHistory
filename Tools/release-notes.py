#!/usr/bin/env python3
"""Extract one version's notes from the same changelog shipped in the app."""
import pathlib
import re
import sys

version = sys.argv[1]
if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
    sys.exit("Expected MAJOR.MINOR.PATCH")
changelog = pathlib.Path(__file__).resolve().parents[1] / "CHANGELOG.md"
text = changelog.read_text(encoding="utf-8")
match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if match is None or not match[1].strip():
    sys.exit(f"Missing release notes for {version} in CHANGELOG.md")
print(f"## 更新日志 · {version}\n")
print(match[1].strip())
