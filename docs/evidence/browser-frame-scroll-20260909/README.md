# Accessible frame scroll targeting

PR #34726 review: the shared live scroll script now descends through accessible
frame documents and open shadow roots, translating the point into each frame.
Fallback scrolling stays in the innermost document. Opaque frames and transformed
frame geometry reject before scrolling rather than scrolling the outer page.

The real Firefox probe passed 24 checks, including nested frames inside an open
shadow root, inner document fallback, rotated-frame rejection and opaque-frame
rejection. The frame fixture covers borders; padding compensation is implemented
but not separately measured here. These are script/Gecko checks, not deployed
TUI or real Slack acceptance evidence.
