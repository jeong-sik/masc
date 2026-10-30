# Purposeful Keeper prompt runtime application

The existing Keeper override was preserved and extended with the reviewed
purposeful-work section from merged PR #34908. The authenticated set request
returned HTTP 200; an independent GET returned exactly the requested value.
The persisted override also matches, and the live dashboard Keeper editor was
opened and its complete textarea value compared exactly against requested.txt.
See receipt.json, persistence-and-turn-observation.json, browser.json and
effective-prompt.png. Authentication secrets are not included.

Effective SHA-256: 9360fb87bcc5fd03c881126156e734b4d0d3674e2734e1ebf3ccb7411a0a6ea8.

The first browser attempt selected Librarian, not Keeper, and was rejected by
the exact-value assertion. The successful observation explicitly selects Keeper.
The screenshot captures its editor after scrolling within the original text.

This proves registry application, persistence and display only. The observed
turn-record string fields did not contain the complete inserted section; this
does not establish its absence from provider input, which may be stored by
reference. The subsequent snapshot-to-record comparison below supplies input evidence;
autonomous behavior remains unverified. No Keeper was restarted or force-woken
for this observation.

A later observation (`admitted-prompt.json`) joins the saved code-reviewer
agent-core system prompt to the turn-record keeper_instructions block by exact
SHA-256 and byte count. That saved system prompt contains the entire inserted
section. This establishes its presence in the measured agent input for that
record, beyond registry display. It does not prove the Keeper followed the
instructions or completed any autonomy/Fusion/delegation scenario. Full private
conversation snapshots are not copied into this public evidence directory.
