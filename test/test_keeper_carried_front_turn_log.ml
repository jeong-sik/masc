(** Tests for {!Keeper_carried_front.read_seed}'s generation boundary, read
    from the Keeper's turn log (RFC librarian-call-only-proposes §11.2). The
    first, third and fourth cases are the old turn-index cases rewritten on
    the turn log: the same history leaves the seed at the same atom. The
    second is the rule the old index had no line for. *)

module Front = Masc.Keeper_carried_front
module Log = Masc.Keeper_turn_log
module Store = Masc.Keeper_turn_log_store

open Alcotest

let trace_id = "trace-1"
let keeper_name = "alpha"

let recorded_digest atom =
  Agent_core_sha256.digest_string (Printf.sprintf "front-%d" atom)
  |> Agent_core_sha256.to_hex
;;

(* A direct turn's record. [window] is (transmitted, total) atoms; a response
   observed on it makes the record a seed starting at [total - transmitted]. *)
let record ?(response_observed = true) ~turn window : Turn_record.t =
  let model_input_window measurement (transmitted_atoms, total_atoms) =
    { Turn_record.transmitted_atoms
    ; total_atoms
    ; measurement
    ; model_input_front = Model_input_front.At_atom (recorded_digest (total_atoms - transmitted_atoms))
    }
  in
  { request_observations = []
  ; execution_ids = []
  ; keeper = keeper_name
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id
  ; absolute_turn = turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
  ; blocks = []
  ; input_components = None
  ; tool_surface_ref = None
  ; runtime_profile = "glm"
  ; selected_model = None
  ; finish_reason = (if response_observed then Some "completed" else None)
  ; context_window = None
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation = None
  ; model_input_window = Option.map (model_input_window Turn_record.Wire_shape) window
  ; response_observed_model_input =
      (match response_observed, window with
       | true, Some window ->
         Some
           { runtime_profile = "glm"
           ; window = model_input_window Turn_record.Wire_shape window
           }
       | true, None | false, (Some _ | None) -> None)
  ; refused_model_input = None
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
  let store = Masc.Keeper_types_support.keeper_turn_record_store config keeper_name in
  Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
  f config store
;;

let store_record store record = Dated_jsonl.append store (Turn_record.to_json record)

let log_path config =
  Store.path_for_keepers_dir
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name
;;

let mark closed_messages = Masc_test_deps.turn_log_mark ~trace_id ~closed_messages

(* [lines] in one append at the end of the turn log; the offset the last of
   them starts at. *)
let append config lines =
  let path = log_path config in
  let at_end =
    match Store.read_tail path with
    | Ok Store.Nothing_written -> 0
    | Ok (Store.Written { rows_end; point = _; open_turn = _; last = _ }) -> rows_end
    | Error error -> fail (Store.read_error_to_string error)
  in
  match lines with
  | [] -> fail "append: no line"
  | first :: rest ->
    (match Store.append ~path ~at_end (first, rest) with
     | Ok appended -> appended.Store.last_at
     | Error (_ : Store.append_error) -> fail "append: the turn log refused the lines")
;;

let started () = Log.Log_started { id = Log.Log_id.fresh (); at = 1.0; mark = mark 0 }

let opened ~turn ~before =
  Log.Opened
    { at = float_of_int turn
    ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
    ; runtime = "fixture"
    ; task = Log.No_task
    ; stimuli = []
    ; baseline = mark before
    }
;;

let closed ~opened_at ~after =
  Log.Closed
    { turn = opened_at
    ; at = 2.0
    ; outcome = Log.Completed
    ; after = mark after
    ; unattributed = []
    ; own = []
    }
;;

let reset cause ~before ~after =
  Log.Reset { at = 3.0; cause; before = mark before; after = mark after; closed_before = [] }
;;

let completed_turn config ~turn ~before ~after =
  let opened_at = append config [ opened ~turn ~before ] in
  let (_ : int) = append config [ closed ~opened_at ~after ] in
  ()
;;

let seed_atom config =
  (Front.read_seed ~config ~keeper_name ~trace_id ~runtime_id:"glm").Front.seed
  |> Option.map (fun (seed : Front.seed) -> seed.first_atom)
;;

(* Each read after an append resumes the kept scan where it stopped. *)
let test_a_clear_fences_the_responses_before_it () =
  with_turn_record_store @@ fun config store ->
  store_record store (record ~turn:1 (Some (30, 100)));
  let (_ : int) = append config [ started () ] in
  completed_turn config ~turn:1 ~before:0 ~after:2;
  check (option int) "the response before any reset is the seed" (Some 70) (seed_atom config);
  check (option int) "an unchanged log answers the same" (Some 70) (seed_atom config);
  let (_ : int) = append config [ reset (Log.Announced Log.Recovered) ~before:2 ~after:2 ] in
  check (option int) "a recovering purge keeps the history it names" (Some 70)
    (seed_atom config);
  let (_ : int) = append config [ reset (Log.Announced Log.Cleared) ~before:2 ~after:0 ] in
  store_record store (record ~response_observed:false ~turn:2 None);
  check (option int) "a clear appended after the reads fences the old response" None
    (seed_atom config)
;;

(* The reset comes between the turn's [Opened] and its [Closed], so the
   floor is the turn before it, and the turn's own response is above it. *)
let test_the_turn_that_cleared_its_history_is_above_the_floor () =
  with_turn_record_store @@ fun config store ->
  store_record store (record ~turn:1 (Some (30, 100)));
  store_record store (record ~turn:2 (Some (2, 12)));
  let (_ : int) = append config [ started () ] in
  completed_turn config ~turn:1 ~before:0 ~after:2;
  let opened_at = append config [ opened ~turn:2 ~before:2 ] in
  let (_ : int) = append config [ reset (Log.Announced Log.Cleared) ~before:2 ~after:0 ] in
  let (_ : int) = append config [ closed ~opened_at ~after:0 ] in
  check (option int) "the clearing turn's response is the seed" (Some 10) (seed_atom config)
;;

(* A head replaced without a clear: the writer puts the reset in front of the
   next [Opened], in the same append. *)
let test_an_unannounced_reset_fences_the_old_generation () =
  with_turn_record_store @@ fun config store ->
  store_record store (record ~turn:1 (Some (30, 100)));
  let (_ : int) = append config [ started () ] in
  completed_turn config ~turn:1 ~before:0 ~after:2;
  let opened_at =
    append config [ reset Log.Unannounced ~before:2 ~after:0; opened ~turn:2 ~before:0 ]
  in
  let (_ : int) = append config [ closed ~opened_at ~after:0 ] in
  store_record store (record ~response_observed:false ~turn:2 None);
  check (option int) "the response on the replaced head is not a seed" None (seed_atom config)
;;

let test_turn_log_errors_are_not_turn_record_errors () =
  with_turn_record_store @@ fun config store ->
  store_record store (record ~turn:1 (Some (30, 100)));
  let path = log_path config in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun output -> output_string output "{not-json\n");
  let read = Front.read_seed ~config ~keeper_name ~trace_id ~runtime_id:"glm" in
  check bool "an unread boundary admits no seed" true (Option.is_none read.Front.seed);
  check bool "no TurnRecord was counted unreadable" true (Option.is_none read.Front.unreadable);
  check bool "the turn log failure has its own channel" true
    (Option.is_some read.Front.boundary_error)
;;

let () =
  run
    "keeper_carried_front_turn_log"
    [ ( "read_seed"
      , [ test_case "a clear fences the responses before it" `Quick
            test_a_clear_fences_the_responses_before_it
        ; test_case "the turn that cleared its history is above the floor" `Quick
            test_the_turn_that_cleared_its_history_is_above_the_floor
        ; test_case "an unannounced reset fences the old generation" `Quick
            test_an_unannounced_reset_fences_the_old_generation
        ; test_case "turn log errors are not TurnRecord errors" `Quick
            test_turn_log_errors_are_not_turn_record_errors
        ] )
    ]
;;
