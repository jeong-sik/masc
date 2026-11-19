open Alcotest

module Decode = Masc.Tui_decode
module Context_state = Masc_tui_context_state

let keeper =
  Decode.
    { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = "keeper-main"
  ; k_paused = false
  ; k_identity = Ok { k_trace_id = "trace-current"; k_created_at = "2026-08-21T00:00:00Z"; k_updated_at = "2026-08-21T00:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = Keeper_cost_coverage.empty; k_last_turn_at = None; k_last_proactive_outcome = None }
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

(* A TurnRecord of [load_keeper], as the server writes one. *)
let load_trace = "trace-1780648779957-00000"

let turn_record ~absolute_turn ~input_tokens : Turn_record.t =
  { request_observations = []
  ; execution_ids = []
  ; keeper = "beta"
  ; agent_name = "beta-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = load_trace
  ; absolute_turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id:load_trace ~absolute_turn
  ; blocks =
      [ { Turn_record.block = Prompt_block_id.Keeper_instructions
        ; bytes = 4
        ; digest = Agent_core_sha256.(to_hex (digest_string "aaaa"))
        }
      ]
  ; input_components = Some [ { component = Turn_record.Tool_schemas; bytes = 8192 } ]
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding.glm-5-turbo"
  ; selected_model = Some "glm-5-turbo"
  ; finish_reason = Some "completed"
  ; context_window = Some 131_072
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1234
  ; ttfrc_ms = None
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding.glm-5-turbo"; body_bytes = 4096 }
  ; model_input_window = None
  ; response_observed_model_input = None
  ; refused_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None; top_p = None; max_tokens = None; enable_thinking = Some true }
  ; usage =
      { input_tokens = Some input_tokens
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope = Runtime_usage_scope.Per_request
      ; input_provenance = Some Turn_input_provenance.Measured_request
      }
  ; turn_output_tokens = None
  ; ts = 1_781_200_000.5
  }

let load_keeper =
  { keeper with
    Decode.k_name = "beta"
  ; k_identity =
      Ok
        { Decode.k_trace_id = load_trace
        ; k_created_at = "2026-08-21T00:00:00Z"
        ; k_updated_at = "2026-08-21T00:00:00Z"
        }
  }

(* The TUI is not the process that writes the TurnRecords: the server is.
   This executable links what the TUI links and, like the TUI, never says it
   holds the writer lease. So every [load] reads the files, and a row that
   reached them after one load is what the next load shows. A TUI that kept
   the first row would show it for good (#53145). *)
let test_every_load_reads_what_the_server_wrote () =
  let base_path = Filename.temp_dir "tui-context-load-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let store = Masc.Keeper_types_support.keeper_turn_record_store config "beta" in
      let line ~absolute_turn ~input_tokens =
        Yojson.Safe.to_string (Turn_record.to_json (turn_record ~absolute_turn ~input_tokens)) ^ "\n"
      in
      let tokens () =
        match Context_state.load ~config load_keeper with
        | Ok (Decode.Context_observed { tokens; _ }) -> Some tokens
        | Ok (Decode.Context_unavailable _) -> None
        | Error detail -> fail detail
      in
      Dated_jsonl.append store (Turn_record.to_json (turn_record ~absolute_turn:1 ~input_tokens:18_000));
      check (option int) "the first load" (Some 18_000) (tokens ());
      let day_file =
        match Dated_jsonl.month_dir_paths_newest_first_result store with
        | Ok (month :: _) ->
          (match Dated_jsonl.day_file_paths_newest_first_result month with
           | Ok (day_file :: _) -> day_file
           | Ok [] | Error _ -> fail "the store has no day file")
        | Ok [] | Error _ -> fail "the store has no month directory"
      in
      Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 day_file
        (fun channel -> output_string channel (line ~absolute_turn:2 ~input_tokens:21_000));
      check (option int) "the next load shows the row the server wrote" (Some 21_000) (tokens ()))

let observation_exn keeper =
  match Context_state.resolve_with keeper
          ~project:(fun ~keeper_name:_ ~current_trace_id -> observed_fields ~trace_id:current_trace_id) with
  | Ok observation -> observation
  | Error detail -> fail detail

let start_exn state key =
  match Context_state.start state ~key with
  | Context_state.Started (state, request) -> state, request
  | Context_state.Already_loading -> fail "expected a new owner"

let test_projection_keeps_captured_identity () =
  let seen = ref None in
  let result = Context_state.resolve_with keeper
      ~project:(fun ~keeper_name ~current_trace_id ->
        seen := Some (keeper_name, current_trace_id);
        observed_fields ~trace_id:current_trace_id) in
  check (option (pair string string)) "exact source" (Some ("keeper-main", "trace-current")) !seen;
  check bool "matching observation" true (Result.is_ok result);
  check bool "foreign trace remains an error" true
    (Result.is_error (Context_state.resolve_with keeper
       ~project:(fun ~keeper_name:_ ~current_trace_id:_ -> observed_fields ~trace_id:"trace-prior")))

let test_selection_and_clear_retire_previous_completion () =
  let scope = ref () in
  let key = Context_state.key_for_keeper ~scope ~base_path:"/workspace/a" keeper in
  let other = Context_state.key_for_keeper ~scope ~base_path:"/workspace/a"
      { keeper with k_name = "keeper-other" } in
  let a, old_a = start_exn Context_state.empty key in
  let b, old_b = start_exn a other in
  let a, new_a = start_exn (Context_state.clear b) key in
  let late = Context_state.complete (Context_state.complete a old_b (Error "old B"))
      old_a (Ok (observation_exn keeper)) in
  check bool "A-B-A keeps its new owner after old results" true
    (Context_state.is_current late new_a);
  (match Context_state.view late ~key with
   | Masc_tui_fetched.Loading -> ()
   | _ -> fail "retired completion replaced the current read");
  let settled = Context_state.complete late new_a (Ok (observation_exn keeper)) in
  check bool "duplicate completion cannot become current" false
    (Context_state.is_current settled new_a)

let test_identity_scope_and_base_do_not_borrow_values () =
  let scope = ref () in
  let key = Context_state.key_for_keeper ~scope ~base_path:"/workspace/a" keeper in
  let state, request = start_exn Context_state.empty key in
  let state = Context_state.complete state request (Ok (observation_exn keeper)) in
  let new_trace = { keeper with k_identity =
      Result.map (fun (identity : Decode.keeper_identity) ->
        { identity with k_trace_id = "trace-next" }) keeper.k_identity } in
  List.iter (fun foreign -> match Context_state.view state ~key:foreign with
      | Masc_tui_fetched.Absent -> ()
      | _ -> fail "foreign source borrowed the previous observation")
    [ Context_state.key_for_keeper ~scope:(ref ()) ~base_path:"/workspace/a" keeper
    ; Context_state.key_for_keeper ~scope ~base_path:"/workspace/b" keeper
    ; Context_state.key_for_keeper ~scope ~base_path:"/workspace/a" new_trace ]

let test_refresh_retains_value_and_failure_and_suspension () =
  let key = Context_state.key_for_keeper ~scope:(ref ()) ~base_path:"/workspace/a" keeper in
  let initial, first = start_exn Context_state.empty key in
  let ready = Context_state.complete initial first (Ok (observation_exn keeper)) in
  let pending, refresh = start_exn ready key in
  (match Context_state.view pending ~key with
   | Masc_tui_fetched.Ready _ -> ()
   | _ -> fail "same-owner revalidation discarded the last value");
  let failed = Context_state.complete pending refresh (Error "store unavailable") in
  (match Context_state.view failed ~key with
   | Masc_tui_fetched.Stale (_, detail) -> check string "read failure retained" "store unavailable" detail
   | _ -> fail "failed refresh lost its previous value");
  let retry, request = start_exn failed key in
  let suspended = Context_state.suspend retry in
  check bool "suspension retires worker result" false
    (Context_state.is_current suspended request);
  match Context_state.view (Context_state.complete suspended request (Ok (observation_exn keeper))) ~key with
  | Masc_tui_fetched.Stale _ -> ()
  | _ -> fail "late result revived a suspended owner"

let () =
  run "tui_context_state"
    [ "ownership", [
        test_case "projection keeps captured trace" `Quick test_projection_keeps_captured_identity;
        test_case "every load reads what the server wrote" `Quick
          test_every_load_reads_what_the_server_wrote;
        test_case "selection and clear retire previous completions" `Quick
          test_selection_and_clear_retire_previous_completion;
        test_case "workspace and trace cannot borrow values" `Quick test_identity_scope_and_base_do_not_borrow_values;
        test_case "refresh preserves evidence while suspension retires ownership" `Quick
          test_refresh_retains_value_and_failure_and_suspension ] ]
