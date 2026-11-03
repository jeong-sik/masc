open Alcotest
open Masc

(* Codex reports the turn's newest occupancy two ways: a counted request, or
   a post-compaction estimate of the whole new history. The conversion into
   a runtime observation has to keep the two apart, because the durable turn
   record stores whatever provenance this hands it and a reader cannot
   recover the distinction from the bare numbers. (#47694) *)

let counted_request () =
  let usage : Runtime_codex_app_server.token_usage =
    { input_tokens = 4200
    ; cached_input_tokens = 3000
    ; cache_write_input_tokens = 512
    ; output_tokens = 180
    ; reasoning_output_tokens = 64
    ; total_tokens = 4380
    }
  in
  let context =
    Keeper_codex_runtime.request_context_of_last_usage
      (Runtime_codex_app_server.Request_usage usage)
  in
  check bool "a counted request is measured" true
    (context.Runtime_observation.provenance
     = Turn_input_provenance.Measured_request);
  check int "its input rides along" 4200 context.input_tokens;
  check bool "its cache split rides along" true
    (Option.is_some context.cache);
  check bool "its output rides along" true
    (context.output_tokens = Some 180)

let compaction_estimate () =
  let context =
    Keeper_codex_runtime.request_context_of_last_usage
      (Runtime_codex_app_server.Context_estimate
         { estimated_tokens = 45000 })
  in
  check bool "an estimate is an estimate" true
    (context.Runtime_observation.provenance
     = Turn_input_provenance.Context_estimate);
  check int "the estimated size rides along" 45000 context.input_tokens;
  check bool "no cache split is invented" true (Option.is_none context.cache);
  check bool "no output is invented" true (Option.is_none context.output_tokens)

let () =
  run "Codex request provenance"
    [ ( "conversion"
      , [ test_case "a counted request is measured" `Quick counted_request
        ; test_case "a compaction estimate stays an estimate" `Quick
            compaction_estimate
        ] )
    ]
