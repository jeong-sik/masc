# Fusion Judge nonblank conclusions

The actual baseline decoder accepted an empty or whitespace-only `answer` synthesis. The repaired decoder rejects those conclusions, while `insufficient` may retain an empty `resolved_answer` without inventing an answer. `answer`, `recommend.action`, `recommend.rationale`, and resolved conclusions for those two variants use the same nonblank codec for decoding and output-schema generation.

`baseline-decoder.txt` and `candidate-decoder.txt` are outputs from separate OCaml 5.5.1 native processes running `decoder-probe.ml`. The production decoder implementation/interface were compiled in temporary directories and linked with the cached `Fusion_types` object. The cached type sources match the recorded base. `output-schema.json` is exported by the candidate decoder. The exact source and binary hashes are in `manifest.json`.

`judge-parser-tests.txt` records 11 passing parser tests. Their function bodies were extracted unchanged from the candidate `test/fusion_core/test_fusion.ml`, from `let jdecision` through the next topology section, and linked with the repaired decoder using a focused Alcotest runner. This is not execution of the complete Fusion core suite.

The production Judge's official-client and Agent_core paths both decode through `Fusion_judge_parse.of_string`; parser errors pass through `Fusion_judge.attach_usage` and then `Fusion_seat.walk` tries the next candidate. Only a successful synthesis reaches the sink's success/queue path. This control flow was source-reviewed, not executed by the decoder probe.

`test_fusion_official_client_panel` now has a Muse provider fixture whose first model returns blank structured JSON and second returns a supported answer. It checks the selected candidate, the first Parse_error receipt, and usage from both calls. That full provider fixture remains unrun, as do server startup and sink/queue delivery. No local Dune or full product build was performed.
