# Browser region review validation

PR #34729 follow-up: scene clicks retain the selected region reference through the follow-up request and acknowledgment. A replaced region/document fails visibly; the client does not silently widen the read.

The real Firefox shared-script probe passed 37 checks, including a same-document link followed by a scoped read and eight native/ARIA landmark selections. `proof.json` records the executed checks and browser capabilities; `driver.txt` records the driver run; `fixture.png` captures the final synthetic popup fixture. These artifacts do not prove the newly changed TUI binary, which requires CI compilation and runtime validation.

Validation: OCaml parser-only checks for changed implementations; `node test/test_browser_scene_resource.cjs`; `python3 test/test_browser_scene.py` with existing Gecko binaries. No local build was performed.
