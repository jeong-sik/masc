# Redaction source spans

Redacted output alone cannot identify which provider chunk owned each output
byte. Replacing a secret changes its length, and literal `[REDACTED]` text is
ordinary authored content. The mapped APIs retain provenance at the actual
replacement passes so downstream ordered publication can use source positions.

`Secret_patterns.source_piece` has two variants:

- `Copied {source; text}` contains exactly the original bytes in the half-open
  interval `source.first_byte .. source.past_byte`.
- `Masked {source; replacement}` records an actual replacement over that source
  interval. Its output belongs to the first covered original byte; the remaining
  covered bytes produce no additional output.

The ordered exact-value, PEM, named-credential and structural-pattern policies
are unchanged. Each regular-expression match supplies its actual offsets. Named
credentials preserve the prefix capture as copied text. Later passes match the
current rendered text, then compose those offsets through the earlier pieces.
If a later match splits a previous replacement, overlapping source ownership is
coalesced into one replacement with the exact final rendered value. The code
does not infer positions by comparing original and rendered strings.

`Keeper_secret_redaction.redact_text_mapped` reports zero-based original input
positions. The streaming mapped APIs return `{pieces; consumed}`. `consumed` is
the absolute exclusive source watermark since that stream state was created.
Each release covers exactly the newly consumed prefix, never retracting earlier
pieces. Newline and carriage-return records, bounded unterminated records, and
final flush retain their existing policy. A bounded cut can consume beyond its
nominal stop when an exact secret crosses it; the watermark records the actual
cursor, not the redacted output length. Existing string APIs render these same
pieces, so callers cannot silently select a different masking policy.

Coordinates are bytes in the text passed to this redactor, not raw JSON/SSE wire
offsets. Pieces are allocated for copied runs and replacements, not individual
bytes. A copied run may span several original chunks, including a provider cut
inside a UTF-8 code point. A consumer assigning output to original chunk slots
must keep such a code point whole and assign it to its first-byte owner. A
replacement spanning several chunk slots is likewise emitted only at its first
covered source-byte owner. Actual renderer ordering and per-channel buffer
ownership are separate consumers and are not implemented by this API change.

The existing bounded structural-pattern overlap remains a policy limitation;
this change preserves that policy and does not claim support for unbounded
structural token lengths. Exact snapshotted secret lengths determine their own
overlap. The focused source-span fixtures cover original-byte coverage, ordered
replacement composition, longest-first exact values, preserved credential
prefixes, literal markers, split secrets, long exact matches and UTF-8 release
boundaries. No local build or test execution is claimed for this change.
