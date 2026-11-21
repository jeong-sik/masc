(* The forecast runs the turn's own composition forward. These cases pin
   the arithmetic on a synthetic history with no Librarian point, so the
   numbers are checkable by hand: a seeded front carries everything from
   it, a front whose atom is gone or opens with another message is dropped,
   and without a front the range starts at the turn start. The assembly
   cases pin the order the request carries its parts. *)

open Masc

let message role text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Agent_core.Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

(* One user/assistant exchange per index, each side [n] bytes of text. *)
let history ~exchanges ~text_bytes =
  List.concat_map
    (fun index ->
      let text = String.make text_bytes (Char.chr (Char.code 'a' + (index mod 26))) in
      [ message Agent_core.Types.User text; message Agent_core.Types.Assistant text ])
    (List.init exchanges Fun.id)

(* A front measured on [messages]: its index and the message that opens it. *)
let seed ~messages first_atom : Keeper_carried_front.seed =
  match Runtime_model_input_tail_window.atom_opening_digest messages first_atom with
  | Some front_digest -> { first_atom; front = Model_input_front.At_atom front_digest; source = Keeper_carried_front.Ledger }
  | None -> Alcotest.fail "the seed's own history has the atom"

(* RFC librarian-lifecycle §4.10: the Librarian_stalled gap, from the files a
   server that just started holds -- the keeper's meta, checkpoint, turn
   log, Librarian position and turn records -- through the driver's
   own choice of where the next request starts. *)
let test_the_librarian_gap_is_read_from_small_files () =
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
  let config = Workspace.default_config base_path in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "librarian-gap" ])
    with
    | Ok meta -> meta
    | Error detail -> Alcotest.fail detail
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  let keeper_name = meta.name in
  let gap () =
    match Keeper_next_request_forecast.librarian_gap ~config ~keeper_name with
    | Ok gap ->
      Option.map
        (fun (g : Keeper_carried_front.librarian_gap) -> g.gap_start_atom, g.gap_end_atom)
        gap
    | Error unmeasured ->
      Alcotest.fail (Keeper_next_request_forecast.librarian_gap_unmeasured_detail unmeasured)
  in
  Alcotest.(check (option (pair int int))) "no files, no gap" None (gap ());
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let persisted = history ~exchanges:5 ~text_bytes:100 in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
  let _, total_atoms = Runtime_model_input_tail_window.annotate persisted in
  let accepted_at ~turn first_atom =
    let window : Turn_record.model_input_window =
      { transmitted_atoms = total_atoms - first_atom
      ; total_atoms
      ; measurement = Turn_record.Wire_shape
      ; model_input_front = (seed ~messages:persisted first_atom).front
      }
    in
    Keeper_turn_record_writer.write ~request_observations:[]
      ~config ~keeper_name ~agent_name:keeper_name ~turn_kind:Turn_record.Direct
      ~trace_id ~absolute_turn:turn ~runtime_profile:"librarian-gap"
      ~selected_model:None ~finish_reason:None ~context_window:None
      ~price_input_per_million:None ~price_output_per_million:None
      ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
      ~model_input_window:(Some window)
      ~response_observed_model_input:(Some { Turn_record.runtime_profile = "librarian-gap"; window })
      ~refused_model_input:None
      ~raw_trace_run_ref:None
      ~sampling:{ temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
      ~usage:
        { input_tokens = None
        ; output_tokens = None
        ; cache_creation_input_tokens = None
        ; cache_read_input_tokens = None
        ; scope = Runtime_usage_scope.Usage_scope_unavailable
        ; input_provenance = None
        }
      ~turn_output_tokens:None
      ~execution_ids:[] ~blocks:[] ~input_components:None ~tool_surface_ref:None ()
  in
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest persisted in
  let read_to end_atom =
    let last_atom_digest = Option.get (digest_at (end_atom - 1)) in
    match
      Keeper_librarian_progress.write ~keepers_dir ~keeper_id:keeper_name
        { Keeper_librarian_progress.position = { trace_id; end_atom; last_atom_digest }
        ; boundary_lines_seen = 1
        }
    with
    | Ok () -> ()
    | Error error -> Alcotest.fail (Keeper_librarian_progress.write_error_to_string error)
  in
  read_to 2;
  accepted_at ~turn:1 2;
  Alcotest.(check (option (pair int int))) "a request from the Librarian point is no gap" None
    (gap ());
  accepted_at ~turn:2 8;
  Alcotest.(check (option (pair int int))) "an accepted start past the point is the gap"
    (Some (2, 8)) (gap ());
  (* A position on another trace says nothing about this one. *)
  (match
     Keeper_librarian_progress.write ~keepers_dir ~keeper_id:keeper_name
       { Keeper_librarian_progress.position =
           { trace_id = "another-trace"; end_atom = 2; last_atom_digest = "d" }
       ; boundary_lines_seen = 1
       }
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Keeper_librarian_progress.write_error_to_string error));
  Alcotest.(check (option (pair int int))) "a position on another trace is no coverage" None
    (gap ());
  read_to 8;
  Alcotest.(check (option (pair int int))) "the Librarian at the accepted start closes it" None
    (gap ());
  read_to 9;
  Alcotest.(check (option (pair int int))) "and past it" None (gap ());
  (* Each file the gap is read from that does not read is its own answer:
     not "no gap", which would hide the alarm exactly when a read broke, and
     not "not covered", which would claim atoms are missing that may not
     be. The Librarian stands at 2 and the request was accepted at 8, so a
     clean read would be the gap (2, 8). *)
  read_to 2;
  Alcotest.(check (option (pair int int))) "the gap the failures below stand in front of"
    (Some (2, 8)) (gap ());
  let cause () =
    match Keeper_next_request_forecast.librarian_gap ~config ~keeper_name with
    | Ok None -> "no gap"
    | Ok (Some _) -> "gap"
    | Error unmeasured -> Keeper_next_request_forecast.librarian_gap_unmeasured_cause unmeasured
  in
  let write_raw path text =
    Fs_compat.mkdir_p (Filename.dirname path);
    let output = open_out path in
    Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () -> output_string output text)
  in
  let progress_path =
    Keeper_librarian_progress.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name
  in
  write_raw progress_path "{not-json";
  Alcotest.(check string) "an unreadable read position is not counted as uncovered"
    "read_position_unreadable" (cause ());
  read_to 2;
  let snapshot_path = Keeper_librarian_continuity.path ~config ~keeper_name in
  write_raw snapshot_path "{not-json";
  Alcotest.(check string) "an unreadable snapshot is not counted as uncovered"
    "snapshot_unreadable" (cause ());
  Sys.remove snapshot_path;
  Alcotest.(check (option (pair int int))) "the snapshot gone, the gap is back" (Some (2, 8))
    (gap ());
  (* A newer row that does not decode may be the newest accepted start, so
     the one found under it is not taken as the answer. *)
  Dated_jsonl.append store (`Assoc [ "trace_id", `String trace_id; "absolute_turn", `Int 3 ]);
  Alcotest.(check string) "an undecodable turn record is not no gap" "turn_records_unreadable"
    (cause ());
  accepted_at ~turn:4 8;
  Alcotest.(check (option (pair int int))) "a newer record that decodes answers again"
    (Some (2, 8)) (gap ());
  (* The history generation is read from the turn log (RFC
     librarian-call-only-proposes §11.2). *)
  write_raw
    (Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name)
    "{not-json\n";
  Alcotest.(check string) "a turn log that does not read is not no gap" "turn_boundary_refused"
    (cause ());
  (* A meta file this binary does not decode is not "no Keeper, no gap":
     [read_meta] folds it into [Ok None], so the gap reads presence. *)
  write_raw
    (Keeper_types_profile.keeper_meta_path config keeper_name)
    "{\"name\":\"librarian-gap\"}";
  Alcotest.(check string) "an undecodable meta is not no gap" "meta_unreadable" (cause ())

let test_observed_boundary_forecast ?(max_context_tokens = 4096)
      ?(max_output_tokens = 128) ?max_tokens
      ?(expected_origin = Keeper_carried_front.Carried Keeper_carried_front.Ledger)
      ~samples ~expected_front () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let module Ledger = Keeper_model_input_ledger in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  let base_path = Filename.temp_file "forecast-boundary-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
  in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (Llm_provider.Catalog_snapshot.publish catalog_snapshot);
    Ledger.Table.For_testing.reset ();
    remove base_path);
  let unwrap = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let write path contents =
    Out_channel.with_open_bin path (fun out -> output_string out contents)
  in
  let keeper_name = "forecast-boundary" and runtime_id = "fixture.sample" in
  let config = Workspace.default_config base_path in
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path
    (Printf.sprintf
       "[[models]]\nmodel_id = \"forecast-model\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = %d\nmax_output_tokens = %d\nsupports_tools = true\n"
       max_context_tokens
       max_output_tokens);
  Llm_provider.Model_catalog.load_file catalog_path |> unwrap
  |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:(None)));
  let max_tokens_line =
    match max_tokens with
    | Some n -> Printf.sprintf "max-tokens = %d\n" n
    | None -> ""
  in
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path
    (Printf.sprintf
       "[runtime]\ndefault = \"fixture.sample\"\n[providers.fixture]\nprotocol = \"openai-compatible-http\"\nendpoint = \"http://127.0.0.1:1/v1\"\n[models.sample]\napi-name = \"forecast-model\"\nmax-context = %d\n[fixture.sample]\n%s"
       max_context_tokens
       max_tokens_line);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> Alcotest.fail "fixture runtime must materialize"
   | Error error -> Alcotest.fail (Runtime.strict_init_error_to_string error));
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name ]) |> unwrap in
  Keeper_meta_store.replace_snapshot config meta |> unwrap;
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let messages = history ~exchanges:6 ~text_bytes:100 in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version; session_id = trace_id
    ; agent_name = keeper_name; model = "forecast-model"; system_prompt = None
    ; messages; usage = Agent_core.Types.empty_usage; turn_count = 1; created_at = 1000.
    ; tools = []; tool_choice = None; disable_parallel_tool_use = false
    ; temperature = None; top_p = None; top_k = None; min_p = None
    ; reasoning_effort = None; enable_thinking = None; preserve_thinking = None
    ; response_format = Agent_core.Types.Off; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync (); pending_input = None; working_context = None }
  in
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  ignore (Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    ~session_dir ~history_retained:0 checkpoint |> unwrap);
  (* A completed turn has a real boundary as well as a checkpoint. This
     exercises the forecast path that must preserve the observed front. *)
  let position = Keeper_turn_boundaries.position_of_messages messages |> unwrap in
  let boundary : Keeper_turn_boundaries.record =
    { recorded_at = 1000.
    ; event = Turn_ended
        { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
        ; task_context = Keeper_turn_task_context.No_task
        ; history_at_start = Fresh_history
        ; position
        }
    }
  in
  Keeper_turn_boundaries.append
    ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name boundary
  |> Result.map_error Keeper_turn_boundaries.append_error_to_string |> unwrap;
  (* The forecast reads the turn start from the turn log; the Librarian
     still reads the boundary line above. *)
  Masc_test_deps.start_turn_log ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name
    ~trace_id ~closed_messages:(List.length messages);
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest messages in
  List.iter (fun (atom_count, turn_context, input_tokens) ->
    let ends = match digest_at 0, digest_at (atom_count - 1) with
      | Some front_digest, Some end_digest when atom_count > 0 ->
        Ledger.Carried_atoms { front_digest; end_digest }
      | _ -> Ledger.No_atom_carried
    in
    let request : Ledger.request =
      { prefix_digest = "same-fixture-prefix"; first_atom = 0; atom_count; ends
      ; tail_bytes = 0; turn_context; demote_before = 0
      ; working_state = None }
    in
    let usage = Option.map (fun input_tokens ->
      { Ledger.input_tokens; cache_read_input_tokens = 0 }) input_tokens in
    ignore (Ledger.Table.observe ~keeper_name ~runtime_id ~session_id:trace_id
      ~digest_at ~request ~usage)) samples;
  let lookup () = match Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id:trace_id with
    | Some ledger -> ledger
    | None -> Alcotest.fail "observed ledger missing"
  in
  let observed = lookup () in
  let forecast = Keeper_next_request_forecast.forecast ~config ~keeper_name |> unwrap in
  Alcotest.(check bool) "forecast preserves the complete observed Table value" true
    (lookup () = observed);
  match forecast.candidates with
  | [ { carried = Some carried; _ } ] ->
    let expected_counted =
      if expected_front = 0 then observed.total_tokens else None
    in
    Alcotest.(check (option int)) "counted_tokens follows whether range stayed on ledger front"
      expected_counted carried.counted_tokens;
    Alcotest.(check int) "forecast opens on the expected front" expected_front
      carried.first_atom;
    Alcotest.(check bool) "and carries the expected origin" true
      (carried.origin = expected_origin);
    Alcotest.(check int) "range includes the new wake atom" (13 - expected_front)
      carried.kept_atoms
  | _ -> Alcotest.fail "expected one applicable forecast candidate"

let () =
  Alcotest.run "keeper_next_request_forecast_turn_boundaries_and_progress"
    [ ( "boundary"
      , (* An initial prefix-only observation then three four-atom blocks,
           each counted at 400 tokens, gives total 1300. Forecasting preserves
           the complete observed ledger and its front at atom 0. *)
        let samples = [ 0, false, Some 100; 4, false, Some 500; 8, false, Some 900; 12, false, Some 1300 ] in
        let peak_53504_samples =
          [ 2, true, Some 150_000
          ; 4, false, Some 180_000
          ; 8, true, Some 185_000
          ; 12, false, Some 226_390
          ]
        in
        [ Alcotest.test_case "the forecast preserves the observed front" `Quick
            (test_observed_boundary_forecast ~samples ~expected_front:0)
        ; Alcotest.test_case
            "#53504: output reservation lowers input limit and moves forecast past 272_000"
            `Quick
            (test_observed_boundary_forecast
               ~max_context_tokens:400_000
               ~max_output_tokens:128_000
               ~max_tokens:128_000
               ~expected_origin:
                 (Keeper_carried_front.Carried Keeper_carried_front.Turn_start_at_max_context)
               ~samples:peak_53504_samples
               ~expected_front:12)
        ; Alcotest.test_case
            "#53504: omitting optional max_tokens keeps full 400_000 window"
            `Quick
            (test_observed_boundary_forecast
               ~max_context_tokens:400_000
               ~max_output_tokens:128_000
               ~samples:peak_53504_samples
               ~expected_front:0)
        ] )
    ; ( "store"
      , [ Alcotest.test_case "the Librarian gap is read from small files" `Quick
            test_the_librarian_gap_is_read_from_small_files
        ] )
    ]
