#!/usr/bin/env python3
"""masc 저장소 이슈를 GraphQL 로 받아 JSONL 로 저장한다.

usage: fetch_issues.py open|closed OUT.jsonl
- open: 본문 포함
- closed: 본문 없이 번호·시각·닫힌 이유·라벨만
"""
import json
import subprocess
import sys

OWNER, NAME = "jeong-sik", "masc"

OPEN_FIELDS = """
  number title createdAt updatedAt
  author { login }
  labels(first: 20) { nodes { name } }
  comments { totalCount }
  body
"""
CLOSED_FIELDS = """
  number title createdAt closedAt stateReason
  labels(first: 20) { nodes { name } }
"""


def run(state: str, out_path: str) -> None:
    fields = OPEN_FIELDS if state == "open" else CLOSED_FIELDS
    states = "OPEN" if state == "open" else "CLOSED"
    query = (
        "query($cursor: String) { rateLimit { remaining cost } repository(owner: \"%s\", name: \"%s\") {"
        " issues(first: 100, after: $cursor, states: %s, orderBy: {field: CREATED_AT, direction: ASC}) {"
        " pageInfo { hasNextPage endCursor } nodes { %s } } } }"
    ) % (OWNER, NAME, states, fields)
    cursor = None
    total = 0
    with open(out_path, "w", encoding="utf-8") as out:
        while True:
            cmd = ["gh", "api", "graphql", "-f", "query=" + query]
            if cursor:
                cmd += ["-f", "cursor=" + cursor]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                print("gh failed:", res.stderr[:500], file=sys.stderr)
                sys.exit(1)
            data = json.loads(res.stdout)["data"]
            page = data["repository"]["issues"]
            for node in page["nodes"]:
                node["labels"] = [label["name"] for label in node["labels"]["nodes"]]
                if "author" in node:
                    node["author"] = (node["author"] or {}).get("login")
                if "comments" in node:
                    node["comments"] = node["comments"]["totalCount"]
                out.write(json.dumps(node, ensure_ascii=False) + "\n")
                total += 1
            if not page["pageInfo"]["hasNextPage"]:
                print("rate remaining", data["rateLimit"]["remaining"], file=sys.stderr)
                break
            cursor = page["pageInfo"]["endCursor"]
    print(state, total)


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
