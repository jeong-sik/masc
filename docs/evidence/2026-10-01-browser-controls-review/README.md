# Browser control review fixture

The isolated Firefox 151.0 run passed 53 assertions from the form-semantics section of `test/test_browser_scene.py`. It executes the actual Scene, interaction and elements scripts; it does not run the full WebDriver suite, compiled OCaml server, installed extension or production Keeper.

The fixture covers declared label clicks, role-specific checked states, browser-rendered whitespace/text transformations, hidden and clipped content, native labels, delegated descendants and stale association references. `proof.json`, `scene.json`, `form-controls.json`, the screenshot and `run.log` record this run. The read-only scene check also confirmed that observation preserved DOM/CSS.

`run.py` is the exact temporary runner used in this capture; its absolute checkout/browser/output paths identify this host and must be adjusted for reproduction on another host. It extracts the existing test section instead of replacing its assertions. Initial launch restrictions and temporary harness errors were corrected before the recorded successful run. The source baseline was 2e5dd424a65a564b3fb425ceb462cdef7f251b8f plus the review response. `source-sha256.json` pins the exact product and scenario bytes.
