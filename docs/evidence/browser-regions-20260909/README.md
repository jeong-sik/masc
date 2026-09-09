# Observed-region reading

Real Firefox 155.0 fixture: 27 shared-script/protocol checks passed. The rendered message pane and channel sidebar have semantic labels. Reading their outline returns 966 UTF-8 bytes; reading the selected message subtree returns 1,877 bytes versus 3,431 for the whole visible scene. This is a fixture comparison, not a Slack performance result.

The selected subtree excludes sidebar content, retains usable link references, and rejects a replaced region. Normal-flow overflow clipping excludes a message outside the pane. A fixed popup outside an overflow-hidden parent remains observable and clickable. Positioned clipping is conservative: uncertain transformed containing blocks can yield extra candidates; this is not a paint-order/occlusion model.

proof.json records checks and screenshot/script digests; regions.json stores actual outline/scoped payloads and byte counts; driver.txt and fixture.png preserve runtime evidence. Run test/test_browser_scene.py using installed Firefox and geckodriver binaries. The probe directly executes shared scripts/native protocol, not the compiled OCaml server or TUI. Typed request acknowledgement and TUI navigation tests await CI.
