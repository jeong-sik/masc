# Read text without DOM labels in every row

The shared-page experiment renders authors, timestamps and paragraphs as
`[6 strong]`, `[7 time]`, `[8 p]`. These labels repeat structural detail before
the content the user wants to read. The browser already supplies a typed Text
node; no site rule or guessed selector is needed to render it as text.

Text nodes display their original sanitized content. The selected text keeps its
observed `[>N]` marker, matching the selected-element header and n/p navigation.
Controls, regions and images retain their existing labels and indices so click,
read-region and screenshot actions stay visible. No nodes are removed or reordered,
and `y` still copies the original document/node/source context.

The layout cache includes the selected index, so moving selection can re-wrap a
paragraph as its marker appears. Existing selection reveal and scroll behavior
remain in use. Unicode and repeated-node identity tests exercise the changed
projection, and native keyboard/scroll tests validate its interactive surface.

This is a reading presentation change. It does not solve intermediate pages
missed by cadence during a rapid agent sweep; the measured retained-observation
follow-up remains in the composition evidence.
