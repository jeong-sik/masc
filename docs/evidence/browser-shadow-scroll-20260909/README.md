# Open shadow root scroll target

PR #34726 review reproduction and fix: document-level hit testing returns the
outer shadow host. The shared live interaction script now descends through
accessible shadow-root hit tests before walking scroll ancestors.

Actual Firefox probe: two nested open shadow roots contain an overflow pane.
The internal pane moved 120 pixels while the document remained at zero. All
20 shared-script/Gecko checks passed. Node extension dispatch tests also cover
nested roots. Closed shadow roots remain opaque. This is not a live Slack or
compiled-server acceptance claim.
