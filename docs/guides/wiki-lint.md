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

Stable. The seven finding kinds in the table above and the response fields are
stable. A later step of the RFC may still add a kind — `revision_log_gap` is
planned — so read the table above for the current set.
