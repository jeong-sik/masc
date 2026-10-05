# Native Memory UI focused integration evidence

Tested leaf `8f6c39c455c4075e242e2b79139e398315b847ee` includes pinned main `87123f7df94a27ded447b5b05d01c2f5178de029` and the preserved Native Stack scopes. Focused TUI and three native test executable builds passed. Actual small suites passed: Memory explorer 9, Memory renderer 54, decoder 351 (414 native cases total).

The dedicated actual-terminal Memory fact detail fixture passed one flow against that newly built TUI: full claim, j scrolling, wheel scrolling, G tail navigation, and Esc restoring the list and side pane. This is one flow, not the full keyboard suite. checks.json pins commands, binary/source hashes and byte-for-byte raw logs. No source edits occurred during execution. This evidence-only commit does not change the tested source closure.

No full build, full suite, provider/model execution, hosted CI, deployment or release qualification is claimed.
