; The Stagehand lane in a real Chromium, run by scripts/probe-stagehand.py in
; the Browser Host Proof workflow (RFC-browser-lane-stagehand §6.2).
(executable
 (name stagehand_browser_probe)
 (modules stagehand_browser_probe)
 (libraries masc masc.server masc.browser_lane masc.time_compat masc.tool_types eio eio_main yojson base64 unix))
