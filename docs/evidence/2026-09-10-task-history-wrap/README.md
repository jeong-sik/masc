# Actual Task detail mobile wrapping

The final CI preview renders the existing real Keeper decision without horizontal overflow at a 390px viewport. The Task dialog measures **343px client width and 343px scroll width**, with no overflowing descendants and no browser page errors. The full SHA wraps onto subsequent lines; desktop and mobile captures were inspected directly.

| Preview source | Dialog client / scroll width | Result |
| --- | --- | --- |
| `81066b198c7e04f9bef03d5f2af8882113fffb30` | 343 / 503px | Original long-SHA clipping, preserved in [PR #34997](https://github.com/jeong-sik/masc/pull/34997) |
| `a97191a186cdec5dece037510799a8f8fa03da64` | 343 / 430px | Note-only wrapping incomplete; `intermediate-mobile.png` and receipt retained |
| `4c33e7ceb83660d5dca98f8c9e17e0eb8002e7f0` | 343 / 343px | Full Task detail wrapping passes |

The intermediate DOM receipt identifies the remaining overflowing duplicated event note, Handoff verification reference, and event header. The final implementation inherits `overflow-wrap:anywhere` within the Task detail body and lets event headers wrap. It preserves the text and does not hide overflow or alter global Markdown styling.

Final preview CI [34421618393](https://github.com/jeong-sik/masc/actions/runs/34421618393) supplied artifact `10131127961`. Intermediate CI [34421176690](https://github.com/jeong-sik/masc/actions/runs/34421176690) supplied artifact `10130961993`. Every downloaded preview file was checked against its exact source provenance manifest. The backend remained the actual isolated `81066` binary at port 18948: no model rerun or API fixture substitution was required for this UI repair.

Both runs independently read the same Task history and Fusion detail, and the browser rendered decision `08e78fb51a43b06ccaad6ccf13fccd7c57e75519ccacbe904f6244bc0648f06e`, run `kmsg-cd179ef2b1978a75c96df4c82478c260`, Task `task-001`. The harness is `scripts/verify-fusion-decision-live-preview.mjs` from PR #34997; `verification-plan.json` binds its exact bytes and the separate preview/backend commits. The final fit assertion was checked against the recorded dimensions: `scrollWidth <= clientWidth + 1`.

The evaluation Task remains incomplete; its actual verifier rejection remains visible. This proves the rendering repair, not Task/Goal completion, spontaneous structured recording, or production deployment. The missing-assets banner is retained because the isolated backend has no installed Dashboard bundle; the browser loads independently verified CI preview assets. Browser writes, WebSockets, and off-origin requests were blocked. Health observations are reduced to build, paths, and asset provenance; private credentials and raw thinking are excluded.

`sha256.json` binds the saved files, including the intermediate failure. No local build was performed.
