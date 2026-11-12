#!/usr/bin/env python3
"""열린 이슈마다 그 이슈를 언급한 PR(상태 포함)과 마지막 댓글 시각을 받는다.

usage: fetch_xrefs.py OUT.jsonl
"""
import json
import subprocess
import sys

QUERY = """
query($cursor: String) {
  rateLimit { remaining }
  repository(owner: "jeong-sik", name: "masc") {
    issues(first: 50, after: $cursor, states: OPEN, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        comments(last: 1) { nodes { createdAt author { login } } }
        timelineItems(first: 40, itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT]) {
          nodes {
            __typename
            ... on CrossReferencedEvent {
              willCloseTarget
              source { __typename ... on PullRequest { number state isDraft mergedAt title } ... on Issue { number state } }
            }
            ... on ConnectedEvent {
              subject { __typename ... on PullRequest { number state isDraft mergedAt title } }
            }
          }
        }
      }
    }
  }
}
"""


def main(out_path: str) -> None:
    cursor = None
    total = 0
    with open(out_path, "w", encoding="utf-8") as out:
        while True:
            cmd = ["gh", "api", "graphql", "-f", "query=" + QUERY]
            if cursor:
                cmd += ["-f", "cursor=" + cursor]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                print("gh failed:", res.stderr[:500], file=sys.stderr)
                sys.exit(1)
            data = json.loads(res.stdout)["data"]
            page = data["repository"]["issues"]
            for node in page["nodes"]:
                prs = {}
                issues = []
                for item in node["timelineItems"]["nodes"]:
                    src = item.get("source") or item.get("subject") or {}
                    if src.get("__typename") == "PullRequest":
                        entry = prs.setdefault(
                            src["number"],
                            {"number": src["number"], "state": src["state"], "draft": src["isDraft"], "mergedAt": src["mergedAt"], "title": src["title"], "closes": False, "connected": False},
                        )
                        if item["__typename"] == "ConnectedEvent":
                            entry["connected"] = True
                        if item.get("willCloseTarget"):
                            entry["closes"] = True
                    elif src.get("__typename") == "Issue":
                        issues.append({"number": src["number"], "state": src["state"]})
                last = node["comments"]["nodes"]
                out.write(
                    json.dumps(
                        {
                            "number": node["number"],
                            "prs": list(prs.values()),
                            "xissues": issues,
                            "last_comment_at": last[0]["createdAt"] if last else None,
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
                total += 1
            if not page["pageInfo"]["hasNextPage"]:
                print("rate remaining", data["rateLimit"]["remaining"], file=sys.stderr)
                break
            cursor = page["pageInfo"]["endCursor"]
    print("issues", total)


if __name__ == "__main__":
    main(sys.argv[1])
