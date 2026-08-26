open Alcotest

module Decode = Masc.Tui_decode
module Context_state = Masc_tui_context_state

let keeper =
  Decode.
    { k_name = "keeper-main";
      k_trace_id = "trace-current";
      k_paused = false;
      k_current_task_id = None;
      k_total_turns = 0;
      k_total_tokens = 0;
      k_total_cost_usd = 0.0;
      k_last_turn_ts = "";
      k_compaction_count = 0;
      k_last_proactive_outcome = "never";
      k_created_at = "2026-08-21T00:00:00Z";
      k_updated_at = "2026-08-21T00:00:00Z";
    }

let observed_fields ~trace_id =
  [ "context_ratio", `Float 0.5
  ; "context_tokens", `Int 100
  ; "context_max", `Int 200
  ; "context_source", `String "turn_record"
  ; "context_metrics_unavailable", `Null
  ; ( "context"
    , `Assoc
        [ "source", `String "turn_record"
        ; "context_ratio", `Float 0.5
        ; "context_tokens", `Int 100
        ; "context_max", `Int 200
        ; "observed_at", `String "2026-08-21T12:00:00Z"
        ; "turn_ref", `String (trace_id ^ "#4")
        ; "absolute_turn", `Int 4
        ; "request_body_bytes", `Int 4096
        ; "metrics_unavailable", `Null
        ] )
  ]

let reading_exn keeper_name state =
  match Context_state.reading_for_keeper ~keeper_name state with
  | Some reading -> reading
  | None -> failf "missing context reading for %s" keeper_name

let test_resolve_binds_keeper_identity_and_current_trace () =
  let seen_name = ref None in
  let seen_trace = ref None in
  let state =
    Context_state.resolve_with keeper
      ~project:(fun ~keeper_name ~current_trace_id ->
        seen_name := Some keeper_name;
        seen_trace := Some current_trace_id;
        observed_fields ~trace_id:current_trace_id)
  in
  check (option string) "keeper name" (Some "keeper-main") !seen_name;
  check (option string) "current trace" (Some "trace-current") !seen_trace;
  let reading = reading_exn "keeper-main" state in
  check bool "observation loaded" true (Option.is_some reading.observation);
  check bool "successful load has no error" true (Option.is_none reading.error)

let test_snapshot_is_bound_to_one_keeper () =
  let state =
    Context_state.resolve_with keeper
      ~project:(fun ~keeper_name:_ ~current_trace_id ->
        observed_fields ~trace_id:current_trace_id)
  in
  check bool "Keeper A can read its snapshot" true
    (Option.is_some
       (Context_state.reading_for_keeper ~keeper_name:"keeper-main" state));
  check bool "Keeper B cannot read Keeper A's snapshot" true
    (Option.is_none
       (Context_state.reading_for_keeper ~keeper_name:"keeper-other" state))

let test_decode_error_is_exclusive () =
  let state =
    Context_state.resolve_with keeper
      ~project:(fun ~keeper_name:_ ~current_trace_id:_ ->
        observed_fields ~trace_id:"trace-prior")
  in
  let reading = reading_exn "keeper-main" state in
  check bool "failed decode clears observation" true
    (Option.is_none reading.observation);
  check bool "failed decode preserves error" true (Option.is_some reading.error);
  check bool "error snapshot cannot cross Keeper identity" true
    (Option.is_none
       (Context_state.reading_for_keeper ~keeper_name:"keeper-other" state))

let test_empty_selection_clears_loaded_state () =
  let load_count = ref 0 in
  let load _keeper =
    incr load_count;
    Context_state.resolve_with keeper
      ~project:(fun ~keeper_name:_ ~current_trace_id ->
        observed_fields ~trace_id:current_trace_id)
  in
  let loaded = Context_state.for_selection ~load (Some keeper) in
  check bool "nonempty selection loads context" true
    (Option.is_some
       (Context_state.reading_for_keeper ~keeper_name:"keeper-main" loaded));
  let cleared = Context_state.for_selection ~load None in
  check bool "empty selection clears the stamped reading" true
    (Option.is_none
       (Context_state.reading_for_keeper ~keeper_name:"keeper-main" cleared));
  check int "empty selection does not call loader" 1 !load_count

let () =
  run "tui_context_state"
    [ ( "selection"
      , [ test_case "binds current Keeper identity" `Quick
            test_resolve_binds_keeper_identity_and_current_trace
        ; test_case "snapshot cannot cross Keeper identity" `Quick
            test_snapshot_is_bound_to_one_keeper
        ; test_case "decode error is exclusive" `Quick
            test_decode_error_is_exclusive
        ; test_case "empty roster clears loaded context" `Quick
            test_empty_selection_clears_loaded_state
        ] )
    ]
