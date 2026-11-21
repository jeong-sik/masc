(** Tests for {!Keeper_carried_front} (RFC keeper-context-window-in-tokens
    §10.4): where the carried range starts when no ledger holds the pair. *)

module Front = Masc.Keeper_carried_front

open Alcotest

let recorded_digest atom =
  Agent_core_sha256.digest_string (Printf.sprintf "front-%d" atom)
  |> Agent_core_sha256.to_hex

let record
      ?(runtime = "glm")
      ?(wire_runtime = None)
      ?(finish = Some "completed")
      ?(response_observed = true)
      ?response_runtime
      ?(refused = false)
      ?(trace = "trace-1")
      ~turn
      window
  : Turn_record.t
  =
  { request_observations = [];  execution_ids = []
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
  ; blocks = []
  ; input_components = None
  ; tool_surface_ref = None
  ; runtime_profile = runtime
  ; selected_model = None
  ; finish_reason = finish
  ; context_window = None
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation =
      Option.map
        (fun runtime_profile -> { Turn_record.runtime_profile; body_bytes = 1 })
        wire_runtime
  ; model_input_window =
      Option.map
        (fun (transmitted_atoms, total_atoms) ->
           { Turn_record.transmitted_atoms
           ; total_atoms
           ; measurement = Turn_record.Wire_shape
           ; model_input_front = Model_input_front.At_atom (recorded_digest (total_atoms - transmitted_atoms))
           })
        window
  ; response_observed_model_input =
      (match response_observed, window with
       | true, Some (transmitted_atoms, total_atoms) ->
         Some
           { runtime_profile = Option.value response_runtime ~default:runtime
           ; window =
               { Turn_record.transmitted_atoms
               ; total_atoms
               ; measurement = Turn_record.Wire_shape
               ; model_input_front =
                   Model_input_front.At_atom (recorded_digest (total_atoms - transmitted_atoms))
               }
           }
       | true, None | false, _ -> None)
  ; refused_model_input =
      (match refused, window with
       | true, Some (transmitted_atoms, total_atoms) ->
         Some
           { runtime_profile = runtime
           ; window =
               { Turn_record.transmitted_atoms
               ; total_atoms
               ; measurement = Turn_record.Durable_shape
               ; model_input_front =
                   Model_input_front.At_atom (recorded_digest (total_atoms - transmitted_atoms))
               }
           ; refusal = Turn_record.Model_error_not_retryable
           }
       | true, None | false, _ -> None)
  ; raw_trace_run_ref = None
  ; sampling = { temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
  ; usage =
      { input_tokens = None
      ; output_tokens = None
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope = Runtime_usage_scope.Per_request
      ; input_provenance = None
      }
  ; turn_output_tokens = None
  ; ts = 0.
  }
;;

let with_turn_record_store f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let previous_fs = Fs_compat.get_fs_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.on_release sw (fun () ->
    match previous_fs with
    | Some fs -> Fs_compat.set_fs fs
    | None -> Fs_compat.clear_fs ());
  let base_path = Masc_test_deps.setup_test_workspace () in
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace base_path);
  let config = Masc.Workspace.default_config base_path in
  let store = Masc.Keeper_types_support.keeper_turn_record_store config "alpha" in
  Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
  f config store
;;

let test_read_seed_stops_at_history_restart () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 1.
    ; event =
        Masc.Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
          ; history_at_start = Masc.Keeper_turn_boundaries.Continued_history
          ; position = Masc.Keeper_turn_boundaries.Stale_noop
          }
    }
  |> Result.get_ok;
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 2.
    ; event = Masc.Keeper_turn_boundaries.History_restarted { trace_id = "trace-1" }
    }
  |> Result.get_ok;
  Dated_jsonl.append store
    (Turn_record.to_json
       (record ~turn:2 ~finish:None ~response_observed:false None));
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "the pre-clear response is not a seed" true (Option.is_none read.Front.seed)
;;

(* The floor is kept with the boundary store's identity, so a read after an
   append sees the boundary the append wrote, and a read with no append in
   between answers the same. *)
let test_read_seed_sees_a_boundary_appended_after_a_read () =
  with_turn_record_store @@ fun config store ->
  let keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  Masc.Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:"alpha"
    { recorded_at = 1.
    ; event =
        Masc.Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
          ; history_at_start = Masc.Keeper_turn_boundaries.Continued_history
          ; position = Masc.Keeper_turn_boundaries.Stale_noop
          }
    }
  |> Result.get_ok;
  let seeded () =
    Option.is_some (Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1").Front.seed in
  check bool "the response before any restart is a seed" true (seeded ());
  check bool "an unchanged store answers the same" true (seeded ());
  Masc.Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:"alpha"
    { recorded_at = 2.
    ; event = Masc.Keeper_turn_boundaries.History_restarted { trace_id = "trace-1" }
    }
  |> Result.get_ok;
  Dated_jsonl.append store
    (Turn_record.to_json
       (record ~turn:2 ~finish:None ~response_observed:false None));
  check bool "a restart appended after the read fences the old response" false (seeded ())
;;

(* The marker a fresh turn owed failed to be written and only its empty end
   line records the restart. The line still has to fence the old generation:
   without it the seed scan walks back into the pre-restart responses and
   reintroduces a carried range of a history that is gone. *)
let test_read_seed_stops_at_a_fresh_history_end_line () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 1.
    ; event =
        Masc.Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
          ; history_at_start = Masc.Keeper_turn_boundaries.Continued_history
          ; position = Masc.Keeper_turn_boundaries.Stale_noop
          }
    }
  |> Result.get_ok;
  Masc.Keeper_turn_boundaries.append
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:"alpha"
    { recorded_at = 2.
    ; event =
        Masc.Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:2
          ; history_at_start = Masc.Keeper_turn_boundaries.Fresh_history
          ; position = Masc.Keeper_turn_boundaries.No_atom_history
          }
    }
  |> Result.get_ok;
  Dated_jsonl.append store
    (Turn_record.to_json
       (record ~turn:2 ~finish:None ~response_observed:false None));
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "the pre-restart response is not a seed without a restart marker" true
    (Option.is_none read.Front.seed)
;;

let test_read_seed_keeps_boundary_errors_out_of_the_record_count () =
  with_turn_record_store @@ fun config store ->
  Dated_jsonl.append store
    (Turn_record.to_json (record ~turn:1 (Some (30, 100))));
  let path =
    Masc.Keeper_turn_boundaries.path_for_keepers_dir
      ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
      ~keeper_id:"alpha"
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let output = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output "{not-json\n");
  let read = Front.read_seed ~config ~keeper_name:"alpha" ~trace_id:"trace-1" in
  check bool "an unknown boundary admits no seed" true (Option.is_none read.Front.seed);
  check bool "no TurnRecord was counted unreadable" true
    (Option.is_none read.Front.unreadable);
  check bool "the boundary failure has its own channel" true
    (Option.is_some read.Front.boundary_error)
;;

let () =
  run
    "keeper_carried_front_turn_boundaries"
    [ ( "of_records"
      , [ test_case "history restart fences older responses" `Quick
            test_read_seed_stops_at_history_restart
        ; test_case "read seed sees a boundary appended after a read" `Quick
            test_read_seed_sees_a_boundary_appended_after_a_read
        ; test_case "a fresh-history end line fences older responses" `Quick
            test_read_seed_stops_at_a_fresh_history_end_line
        ; test_case "boundary errors are not TurnRecord errors" `Quick
            test_read_seed_keeps_boundary_errors_out_of_the_record_count
        ] )
    ]
;;
