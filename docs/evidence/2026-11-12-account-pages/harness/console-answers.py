"""Asks two account servers for the routes of the console over HTTP and prints
what they answer, as JSON rows. The first server has a dashboard bundle that
holds the build of the console; the bundle of the second is an empty
directory. A path is sent as it is written here: nothing between this script
and the server reads "..".
usage: python3 console-answers.py WITH_BUNDLE_BASE WITHOUT_BUNDLE_BASE"""
import hashlib
import http.client
import json
import re
import sys
import urllib.parse

CONSOLE = "/accounts/console"
KEPT = ("content-type", "cache-control", "content-encoding", "content-security-policy", "referrer-policy", "etag", "vary")


def ask(base, path, headers=None):
    target = urllib.parse.urlsplit(base)
    connection = http.client.HTTPConnection(target.hostname, target.port, timeout=10)
    try:
        connection.request("GET", path, headers=headers or {})
        answer = connection.getresponse()
        body = answer.read()
        kept: dict[str, str] = {}
        for name in KEPT:
            value = answer.getheader(name)
            if value is not None:
                kept[name] = value
        if "content-security-policy" in kept:
            kept["content-security-policy"] = re.sub(r"nonce-[0-9a-f]+", "nonce-N", kept["content-security-policy"])
        return answer.status, kept, body
    finally:
        connection.close()


def row(server, base, what, path, headers=None):
    status, kept, body = ask(base, path, headers)
    return {
        "server": server,
        "what": what,
        "path": path,
        "sent": headers or {},
        "status": status,
        "headers": kept,
        "bytes": len(body),
        "sha256": hashlib.sha256(body).hexdigest()[:12],
    }, body


def main():
    with_bundle, without_bundle = sys.argv[1:3]
    rows = []
    page_row, page = row("with the console", with_bundle, "the page", CONSOLE)
    rows.append(page_row)
    files = sorted(set(re.findall(r'"(/accounts/console/assets/[^"]+)"', page.decode())))
    for path in files:
        rows.append(row("with the console", with_bundle, "a file of the build", path)[0])
        rows.append(
            row("with the console", with_bundle, "the same file, for a browser that takes zstd or gzip", path, {"Accept-Encoding": "zstd, gzip"})[0]
        )
    sheet_row, sheet = row("with the console", with_bundle, "the base sheet", CONSOLE + "/base.css")
    rows.append(sheet_row)
    tag = sheet_row["headers"].get("etag")
    if tag is not None:
        rows.append(row("with the console", with_bundle, "the base sheet, for a browser that holds it", CONSOLE + "/base.css", {"If-None-Match": tag})[0])
    # The home page carries the whole sheet in a style element; the base
    # sheet is its first part.
    home = ask(with_bundle, "/")[2].decode()
    inline = re.search(r"<style nonce=\"[0-9a-f]+\">(.*?)</style>", home, re.S)
    rows.append({
        "server": "with the console",
        "what": "the sheet of the home page starts with the base sheet, byte for byte",
        "path": "/",
        "holds": inline is not None and inline.group(1).startswith(sheet.decode()),
        "bytes": None if inline is None else len(inline.group(1).encode()),
    })
    for what, path in (
        ("the way up from the files of the build", CONSOLE + "/assets/../index.html"),
        ("two steps up, to the operator dashboard", CONSOLE + "/assets/../../index.html"),
        ("the same, percent-encoded", CONSOLE + "/assets/..%2f..%2findex.html"),
        ("no name", CONSOLE + "/assets/"),
        ("a name the build does not hold", CONSOLE + "/assets/missing.js"),
        ("the page of the operator dashboard", "/dashboard"),
        ("an address of the bundle itself", "/accounts/index.html"),
    ):
        rows.append(row("with the console", with_bundle, what, path)[0])
    rows.append(row("without a bundle", without_bundle, "the page", CONSOLE)[0])
    rows.append(row("without a bundle", without_bundle, "a file of the build", files[0] if files else CONSOLE + "/assets/missing.js")[0])
    rows.append(row("without a bundle", without_bundle, "the base sheet", CONSOLE + "/base.css")[0])
    rows.append(row("without a bundle", without_bundle, "the home page", "/")[0])
    rows.append(row("without a bundle", without_bundle, "the readiness probe", "/health/ready")[0])
    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")


main()
