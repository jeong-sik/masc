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
