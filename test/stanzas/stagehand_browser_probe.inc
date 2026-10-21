; Actual native browser Add-on and shared Exact Output in a real Chromium,
; run by scripts/probe-stagehand.py in the Stagehand Browser Proof workflow.
(executable
 (name stagehand_browser_probe)
 (modules stagehand_browser_probe)
 (libraries masc.skill_snapshot masc.skill_snapshot_service masc.browser_configuration masc masc.server masc.browser_lane masc.time_compat masc.tool_types eio eio_main yojson base64 unix eio.unix
  exact_output_fixture cohttp masc.agent_core masc.masc_eio_context masc.fs_compat masc.config masc.runtime
  masc.lane_addon_call_context masc.skill_snapshot masc.skill_snapshot_service masc.skill_reference mirage-crypto-rng.unix))
