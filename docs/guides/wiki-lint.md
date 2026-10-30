# Wiki lint (`masc_wiki_lint`)

## What it is

`masc_wiki_lint` reads every page of the wiki and reports what is wrong with
it. It is read-only: it writes no page, no `index.md`, no `log.md`, takes no
lock and calls no model. The design is
[`docs/rfc/RFC-wiki-lint-and-page-contracts.md`](../rfc/RFC-wiki-lint-and-page-contracts.md).

## Findings

| `kind` | Meaning |
| --- | --- |
| `broken_link` | A `[text](page.md)` link to a page that does not exist. |
| `unsupported_link` | A link shape the check does not follow: an anchor, a relative path, a `[[wikilink]]`. Reported, not judged. |
| `orphan` | No other page links to it. A link from the page to itself and a line in `index.md` do not count; `index.md` and `log.md` are not pages. |
| `orphan_unconfirmed` | No readable page links to it, but some page whose header does not read could. |
| `missing_sources` | No `## Sources` section with a `repo:`, `board:`, `artifact:` or `url:` line. |
| `hearsay_only` | Its sources are only `said:` lines. |
| `unreadable_page` | Its header does not read, or the file exists but cannot be opened; `reason` says why. |
| `revision_log_gap` | `log.md` records an `r<N>` this page never reached. `log_revision` is the highest `N` the log records for the page and `page_revision` is the revision the file carries. The other direction is not a finding: a read takes no lock, so it can see the page of a write in flight before that write's log line. |
| `revision_log_hole` | The log skips an `r<N>` below the highest one it records for this page; `missing` is the skipped `N`. A page's lines are `r1`, `r2`, … with no skips, so the missing value is a line that reached the page and never reached the log — what an `append_log` that failed leaves. A write in flight only leaves the top of the column empty, never a hole. Two cases are refused rather than guessed: no hole is reported at all when the log has any dropped line (`log_unknown_action` or `log_unreadable_line` above zero), because such a line may carry a revision where it cannot be read; and the column is taken to start at the lowest revision the log records for the page, so a page with no `create` line is not reported forever. |

Links inside code fences, code spans and images are not counted.

## How to turn it on

It is registered with the other wiki tools and is deferred: ask for it by name,
`masc_wiki_lint`. There is no configuration switch.

When it is not there: a Keeper whose tool set does not include the wiki tools
does not see it, and a server older than the release that added it answers with
an unknown-tool error. A wiki root that does not exist yet returns zero pages, not an
error.

## Example

```json
{"name": "masc_wiki_lint", "arguments": {}}
```

```json
{"name": "masc_wiki_lint", "arguments": {"kind": "broken_link", "limit": 20}}
```

```json
{"name": "masc_wiki_lint", "arguments": {"page": "rfc-map"}}
```

Arguments: `page` (page name, without `.md`), `kind` (one of the table above),
`limit` (default 50, at most 200; a larger value is treated as 200, not refused),
`cursor` (the `next_cursor` of the previous response; pass the same `kind` and
`page` with it, see below).

The response is JSON text: `schema` (`masc.wiki_lint.v1`), `pages_total`,
`pages_unreadable`, `counts` per kind, `matched`, `findings`, `truncated` and
`next_cursor`. `counts` is over every finding, before `kind` and `page` narrow
it; `matched` is how many are left after they do; `findings` is one page of
those, about 12 KB at most. Pass `next_cursor` back as `cursor` to read the
rest.

It also reads `log.md`, the same file `masc_wiki_create` and `masc_wiki_update`
append to, and reports two counts of its own: `log_unknown_action` for lines
whose action word it does not know and `log_unreadable_line` for lines it cannot
read at all. Both are zero for a log no other tool has written. A line the
parser cannot read is counted rather than raised, so "the log is fine" and "the
log could not be read" stay different answers. A wiki with no `log.md` yet
reports zero, not an error; a `log.md` that exists but cannot be read makes the
call fail instead of reporting zero. A last line the writer had not finished —
the file does not end in a newline — is not a line and is not counted; note
that if the writer then appends to that unfinished piece, the join becomes one
line the parser cannot read, so `log_unreadable_line` can stay at 1 or more
until the line is fixed.

A dropped line above zero switches the `revision_log_hole` check off, because
such a line may have carried a revision the parser cannot read. The response
says so in `revision_log_hole_suppressed` (`true` whenever either count is
above zero), so an empty `revision_log_hole` list is never read as "no holes".
`log.md` is append-only, so once a dropped line is in it the check stays off for
the life of that wiki; fix the line in `log.md` by hand to switch it back on.

The tool reads `log.md` before it reads the pages, which is the order the
writers work in (the page lands first, the log line second). A write that
completes in between therefore shows as a page at or ahead of the log, never as
a `revision_log_gap`.

Refused arguments: an unknown `kind`, a `limit` below 1, a value of the wrong
type (`{"limit": "20"}`, `{"kind": 5}`), a `cursor` this tool did not issue, a
`page` that is not a valid page name.

## While the wiki is being written

A call reads the wiki once and is not a snapshot across calls. A `cursor`
carries a fingerprint of the filtered findings it was issued for; if that list
changed, the call is refused with "call again without cursor" instead of
skipping or repeating findings. The list changes when the wiki changed and also
when `kind` or `page` differ from the call that issued the cursor, so a cursor
from a different filter is refused the same way (and with the same wording). A result read while someone is writing can
show a `broken_link` that is gone on the next run; run it once more to confirm.
A page file that exists but cannot be opened is reported as `unreadable_page`,
not left out.

## Turning it off

There is nothing to turn off: nothing runs unless it is called, and there is
no configuration switch.

## Status

Stable. The nine finding kinds in the table above and the response fields are
stable. A later step of the RFC may still add a kind, so read the table above
for the current set.
