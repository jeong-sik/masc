# Frozen production candidate 215517f229

Source: `215517f229fd74c5300ee7fc4aae91f29da1db4c`, version 0.34.0.
This is a CI release candidate, not a published tag or a live deployment.
The evidence applies to that source only. Later main changes, including Keeper deletion
(#34304) and browser source context (#34305), are outside this frozen candidate.

- [Installed Kata run 34194081312](https://github.com/jeong-sik/masc/actions/runs/34194081312) passed with the Linux x64 artifact from [Release 34192837971](https://github.com/jeong-sik/masc/actions/runs/34192837971). The [receipt](kata/receipt.json) binds the binary SHA and canonical checkpoint to real Kata execution.
- [Raw guest proof](kata/tool-proof.json) and [recreated guest proof](kata/volume-recreated-proof.json) contain identical JSON bytes. [Model-facing proof](kata/tool-proof-model-projected.json) uses MASC's documented guest-to-host bookkeeping path projection; it is not substituted for raw storage evidence.
- [Native guest metadata](kata/kata-native-inspect.json), [managed volume](kata/work-volume.json) and [shim receipts](kata/shim-execution-receipts.json) preserve runtime, UID, network, mount and successful execution boundaries.
- [TUI receipt](tui-scene-receipt.json) and [PTY log](tui-browser-pty-fixed.log) cover the actual macOS ARM TUI's viewport, client selection, scene controls and observed click refresh against loopback HTTP fixtures. The earlier f929 binary failed the scene scenario as expected. Real Gecko shared-script evidence lives in the separate browser semantic scene directory.

The model is scripted. Long-running continuity and real-model quality are not measured.
The recreated file is this JSON fixture, not an arbitrary binary-file stress test.
Four-platform job outcomes are recorded in the parent acceptance matrix.

Receipt artifact paths are preserved relative to the `kata/` directory. The full canonical checkpoint remains in the linked CI artifact.

[Fresh init inventory](seed-inventory.json) records the compiled seed: 331 config files, 24 prompts, 161 tool definitions, 89 identity declarations, 53 themes and two MCP declarations, plus runtime/model overlay. It creates zero Keepers and one browser-lanes Skill package. The shared Keeper prompt and Skill bytes match the frozen source. Identity declarations do not authenticate those services.
