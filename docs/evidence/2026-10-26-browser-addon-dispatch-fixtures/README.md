# Dispatch scenarios through the browser Add-on

Related to #25860 and its consolidated #33000 producer-coverage scope.
This layer is based on #46025 at c1d697580556fcb9374f48169fd5d0135805a2da.

Main baseline run [40233006646](https://github.com/jeong-sik/masc/actions/runs/40233006646)
at 8e85e45ecc8c853fead4734439cf1e67e57728f3 executed 118 cases:
109 PASS, 9 FAIL; another 15 were skipped. Parent run
[40232805823](https://github.com/jeong-sik/masc/actions/runs/40232805823)
executed 120: 111 PASS, the same nine named cases failed, and 15 were skipped.
The two additional output-alternative cases passed in that parent run.

Eight composition recovery/terminal cases and the broad output probe still
installed server-local Browser_lane callbacks. Current Keeper browser calls
resolve an attached native Runtime/MCP Add-on, so they failed before their
scripted adapter ran. This layer uses the existing Browser_addon_fixture to
attach an actual native worker and advertised browser_command transport.
It owns and confirms that worker's detach. No installed browser or profile
is opened or adopted, and no runtime configuration is changed.

The existing scripted adapter responses and all navigation/read/effect counters,
receipt/evidence break controls, recovery authority and terminal assertions are
retained. The broad output probe still evaluates the actual production WebDriver
JavaScript using its Node DOM fixture; its answers now cross the real native
Add-on boundary. Skipped guest probes remain skipped, not passing evidence.

Only the three relevant fixture setups attach the worker; other test cases
retain their previous setup. The test executable explicitly depends on the
native launcher and existing browser_addon_fixture library. Production code and
browser contracts are unchanged.

Source parsing and whitespace pass. Independent source reviews and corrected
selected execution are pending at creation. These are scripted-adapter and DOM
fixture controls, not live-browser, real provider, full regression, installed
runtime, fleet or deployment proof.

Initial corrected run [40233619435](https://github.com/jeong-sik/masc/actions/runs/40233619435)
at dde494fcb653a44055a3784b9d23fe95f9a07a91 compiled, then timed out at the
first native fixture after case79. No nine-case success was reached. Source
inspection found nested Eio_context.with_test_env calls: its global mutex is
non-reentrant, so the dispatch wrapper held it while the Add-on helper tried
to bind it again. Earlier SOURCE PASS missed this lifetime deadlock.

The native helper now owns the single test-context binding and full environment;
the dispatch wrapper keeps its existing Time_compat clock lifetime but delegates
context ownership for these three cases. Other cases keep their previous binding.
The helper restores the full environment with its existing scoped snapshot.
Corrected execution and fresh source review are pending.

The context correction at 5f3843d0e1f92ec2d5987418c9db94ccbd685d3e completed
[40235485707](https://github.com/jeong-sik/masc/actions/runs/40235485707):
120 executed, 112 PASS and eight composition cases FAIL; 15 separately skipped.
The broad native browser output probe passed. The deadlock is no longer present,
but this is not whole-suite success. Earlier SOURCE PASS did not identify two
additional stale test assumptions now exposed by execution.

The recovery cases now validate any durable marker/envelope using the existing
structured_tool_output_exn helper, then unwrap Tool_projection's actual failed
result envelope. Native browser failures supply metadata; the public failure
wire is consequently an object containing message (the serialized composition
diagnostic), masc.tool_disposition=failed and masc.payload (producer metadata).
The old callbacks supplied no metadata, so the diagnostic was inline at root.
The helper only accepts that failed envelope or a direct diagnostic, then
requires effect_disposition and reports the actual payload if it is missing.
No production projection, metadata, effect or terminal decision is changed.

The BrowserAct control sends supported reload rather than click, which belongs
to BrowserInteract and was refused during plan input validation. It still
requires exactly one actual navigation and failed second-node call and the
original terminal boundary; no effect, receipt or counter assertion is removed.

Run [40236254385](https://github.com/jeong-sik/masc/actions/runs/40236254385)
at ac44a02e916fee376a78b6f08abd7367d1f12b73 completed with 120 executed:
112 PASS, eight FAIL; 15 separately skipped. The reload counters now passed,
but the durable helper alone did not unwrap the ordinary failure metadata
envelope, so effect assertions still saw null. The previous artifact-only
explanation was incomplete; earlier SOURCE PASS also missed this layer.
Selected execution for the failure-envelope correction is pending.
