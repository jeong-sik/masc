# Desktop Settings navigation

At a 1020 × 946 viewport with the existing source-mismatch banner visible,
Settings ended below the viewport (y=997.5). A normal browser click failed:
`ElementResolutionError: element is not visible in the viewport`.
The rail had 906 px of content within an approximately 843 px body and no
scrolling overflow. [Before](before.png).

A temporary stylesheet in that same page applied the desktop rules in this PR:
`min-height: 0; overflow-y: auto` on the rail and `flex-shrink: 0` on its brand
and direct menu buttons. The rail fit the body (842.5 px) and a normal Settings
click succeeded. The Settings button was still 46 × 46 px and inside the
viewport. [Candidate after](candidate-after.png).

[Recorded measurements](candidate-measurements.json) additionally show Settings
reachable at 1020 × 600 (button bottom 588) and the phone bottom bar at
390 × 844 (five buttons, each 56 px tall; desktop media query inactive).
No viewport-specific styles, DOM buttons or route callbacks were changed.
The viewport override was cleared after observation.

These are browser CSS candidate measurements on installed dashboard
`25faf14776f1115e962a4c4873e668af386211ad` with server
`25ba22387ffe0d71be8e0f8e58cb66b4bfa5237a`. The relevant rail declarations were
also read on main `54f0db185977a5c73d6f1bb96ef5825c3edb81bb`.
They do not establish a build or installation of this PR. The visible source
mismatch warning and one dashboard error remain recorded. No Preset restoration,
operator save modification or runtime restart was performed.
