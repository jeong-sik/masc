# Native Firefox screenshot evidence

The repository's `scripts/probe-firefox-controls.py` evaluated production OCaml
Driver source against isolated stock Firefox/geckodriver. The scenario now
captures through `Page_screenshot`, with the explicit first-tab ID after visiting
another tab. All 13 assertions passed; [log](probe.log), [source hashes](sources.json)
and [PNG](screenshot.png) are attached. This is source-interpreter/native-browser
measurement, not a compiled MASC runtime or model call.

The separate CI test in `test_keeper_vision_tool` invokes BrowserRead screenshot,
persists its PNG in the Keeper Vision store, then loads it through keeper_analyze_image
with an injected provider. It asserts that exact image bytes reach the provider
and that encoded pixels do not appear in the BrowserRead text result. The live
extension capture/size/navigation behavior has Node tests; native-host frame
forwarding is verified by its CI pipe/HTTP harness.
