# Ego native input workflows

Measured on 2026-10-26 with installed Ego Lite 0.6.1.11, one continuing agent
Space (24), and an owned local HTTP fixture. No production page was used.

The production workflow JavaScript executed reload, focus, keyboard.type,
keyboard.press, keyboard.insertText and rich keyboard.paste. DOM observation
confirmed the Korean/emoji input, an actual HTML table, a trusted paste event
and a reload navigation entry. An input handler then opened an alert; the
workflow stopped before its later submit click and the fixture dialog was
answered explicitly. The same page continued through the existing navigation
and wait scenarios. A wrong starting URL refused before input and a failed wait
retained the preceding effect without running its later navigation.

- [Machine receipt](proof.json) binds requests/results to the workflow script SHA-256.
- [Rich input screenshot](native-rich-input.png) was visually inspected.
- `node --test test/test_browser_ego_workflow.cjs`: 11 cases passed.
- `bash scripts/check-browser-native-workflow-codec.sh`: 5 cases passed.
- The rich-input success receipt also decoded through that standalone OCaml codec.
- `git diff --check`: passed.

Reproduce with `node scripts/probe-browser-ego-workflow.mjs EGO_EXECUTABLE OUT
SPACE_ID`, using one space owned by the current test goal. The probe reuses p1;
it must not target an active Keeper's space. It leaves the space open for the
continuing goal. Finish that space only after the whole browser goal succeeds.

Scope: production workflow JavaScript on the installed Ego SDK and a standalone
codec/receipt component. This is not a full OCaml host type check, installed
MASC Add-on dispatch, autonomous Keeper, deployment or full-SDK-completion proof.
No local Dune build or CI run was performed for this slice.
