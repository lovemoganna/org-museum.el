"""Check real exported HTML for missing fragment targets and marked dead links.

Usage: python test/org-museum-export-links-test.py [article-export-directory]
Pass the configured org-museum-export-dir; legacy output trees may coexist.
"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import json
import sys


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids, self.links, self.marked = set(), [], []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])

    def handle_data(self, data):
        if "[BROKEN LINK:" in data:
            self.marked.append(data.strip())


def check(root):
    pages = {path: Page(path) for path in root.rglob("*.html")}
    issues = []
    for path, page in pages.items():
        for marker in page.marked:
            issues.append({"page": str(path.relative_to(root)), "broken": marker})
        for href in page.links:
            url = urlsplit(href)
            if url.scheme or url.netloc or not url.fragment:
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if target in pages and unquote(url.fragment) not in pages[target].ids:
                issues.append({"page": str(path.relative_to(root)), "href": href})
    if not pages:
        issues.append({"error": "No exported HTML pages found"})
    print(json.dumps(issues, ensure_ascii=False, indent=2))
    print(f"Checked {len(pages)} HTML pages; broken fragment links: {len(issues)}")
    return bool(issues)


if __name__ == "__main__":
    sys.exit(check(Path(sys.argv[1] if len(sys.argv) > 1 else "dist/pages").resolve()))
