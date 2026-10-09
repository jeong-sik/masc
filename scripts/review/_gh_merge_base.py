"""Resolve a GitHub three-dot merge base without decoding file patches.

The compare endpoint embeds per-file ``patch`` text in the same JSON document
as ``merge_base_commit``. Patch text is not always valid JSON: a repository
file containing ``Printf.sprintf "\\u00%02X"`` (task-2220, PR #41696) has been
observed serialising with an odd backslash count, which breaks every
``--jq`` read of the whole response, including the merge-base lookup that
``review-diff.py`` and ``review-scope.py`` depend on.

``merge_base_commit`` precedes the ``files`` array in the response, so this
helper slices the raw bytes down to that one object and decodes only those
bytes. The ``files`` array, including every patch, is never interpreted. The
same input therefore keeps returning the same merge base whether or not the
patch region happens to be serialised correctly, and any other corruption is
refused with the cause instead of inventing a base.
"""

import json
import re
import subprocess

_MERGE_BASE_OBJECT = re.compile(rb'"merge_base_commit"\s*:\s*\{')
_SHA = re.compile(r"^[0-9a-f]{40}$")


def _slice_merge_base_object(raw: bytes) -> bytes:
    """Return the ``merge_base_commit`` object bytes from a compare response.

    Scans bytes with brace depth and JSON string state. A corrupted region
    inside the slice can only end one way here: the scan reaches the end of
    the buffer and the truncated object is refused.
    """
    match = _MERGE_BASE_OBJECT.search(raw)
    if match is None:
        raise ValueError("compare response has no merge_base_commit object")
    start = match.start()
    depth = 1
    in_string = False
    escaped = False
    i = match.end()
    while i < len(raw):
        byte = raw[i : i + 1]
        if in_string:
            if escaped:
                escaped = False
            elif byte == b"\\":
                escaped = True
            elif byte == b'"':
                in_string = False
        elif byte == b'"':
            in_string = True
        elif byte == b"{":
            depth += 1
        elif byte == b"}":
            depth -= 1
            if depth == 0:
                return raw[start : i + 1]
        i += 1
    raise ValueError("merge_base_commit object is truncated in the compare response")


def merge_base(gh: str, repo: str, base: str, head: str) -> str:
    """Return the merge base of ``base`` and ``head`` in ``owner/repo``.

    Refuses with the underlying cause when the comparison itself fails, and
    never returns a partial or guessed SHA.
    """
    for value in (base, head):
        if not isinstance(value, str) or _SHA.fullmatch(value) is None:
            raise ValueError("base and head must be complete commit IDs")
    if not isinstance(repo, str) or re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo
    ) is None:
        raise ValueError("invalid repository")
    result = subprocess.run(
        [gh, "api", f"repos/{repo}/compare/{base}...{head}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip().splitlines()
        cause = detail[-1] if detail else f"exit {result.returncode}"
        raise ValueError(f"GitHub comparison failed: {cause}")
    commit = json.loads(
        b"{" + _slice_merge_base_object(result.stdout) + b"}"
    )
    sha = commit.get("merge_base_commit", {}).get("sha")
    if not isinstance(sha, str) or _SHA.fullmatch(sha) is None:
        raise ValueError("GitHub did not return a complete merge base")
    return sha
