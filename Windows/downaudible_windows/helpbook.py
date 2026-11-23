"""Render the offline Windows manual."""

import re
import shutil
from html import escape
from pathlib import Path

import markdown


def build_help(source: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    images = source / "images"
    if images.is_dir():
        shutil.copytree(images, destination / "images", dirs_exist_ok=True)
    shutil.copyfile(source / "help.css", destination / "help.css")
    for path in sorted(source.glob("*.md")):
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"(\]\([A-Za-z0-9-]+)\.md(?=[)#])", r"\1.html", text)
        title = text.splitlines()[0].removeprefix("# ").strip()
        body = markdown.markdown(text, extensions=["tables", "toc", "fenced_code"])
        navigation = "" if path.stem == "README" else '<nav><a href="README.html">Manual contents</a></nav>'
        document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} · DownAudible Help</title><link rel="stylesheet" href="help.css"></head>
<body><a class="skip" href="#main">Skip to content</a>{navigation}<main id="main">{body}</main></body></html>
"""
        (destination / path.with_suffix(".html").name).write_text(document, encoding="utf-8")
    return destination / "README.html"
