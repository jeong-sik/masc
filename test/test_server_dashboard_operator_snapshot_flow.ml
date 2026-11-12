open Alcotest
open Masc

module Owner = Server_dashboard_operator_snapshot_observation
module Http = Server_dashboard_http_core_operator_snapshot_http
module Worker = Server_dashboard_http_core_snapshot_refresh

let init_fixture_runtime base_path =
  let path = Filename.concat base_path "runtime.toml" in
  Out_channel.with_open_bin path (fun output -> output_string output {|
version = 1
[runtime]
default = "test_provider.test_model"
[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true
[test_provider.test_model]
max-concurrent = 1
|});
  match Runtime.init_default ~config_path:path with
  | Ok () -> () | Error detail -> failf "fixture Runtime.init_default failed: %s" detail

let with_runtime f = Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_context = Eio_context.snapshot_state () in
  let previous_clock = Eio_context.get_clock_opt () in
  let previous_runtime = Runtime.For_testing.snapshot () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  let mock_clock = Eio_mock.Clock.make () in
  let clock = (mock_clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  Eio_mock.Clock.set_time mock_clock (Unix.gettimeofday ());
  Fun.protect ~finally:(fun () ->
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot = Operator_control.snapshot_read};
    Runtime.For_testing.restore previous_runtime;
    Eio_context.restore_state previous_context;
    (match previous_clock with Some clock -> Time_compat.set_clock clock | None -> Time_compat.clear_clock ());
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ()) (fun () ->
    init_fixture_runtime base_path;
    (* Test watchdog only; it does not define a product freshness interval. *)
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          Time_compat.set_clock clock;
          let state = Mcp_server.For_testing.create_state ~base_path in
          let scope = Mcp_server.workspace_scope state in
          ignore (Workspace.init scope.config ~agent_name:None);
          f ~env ~sw ~clock ~mock_clock ~state ~scope)))))

let read ~state ~sw ~clock suffix =
  Http.operator_snapshot_http_json ~state ~sw ~clock
    (Httpun.Request.create `GET ("/api/v1/operator" ^ suffix))

let sequence payload = Yojson.Safe.Util.(payload |> member "snapshot_compute_sequence" |> to_int)
let terminal_sequence payload = Yojson.Safe.Util.(payload |> member "snapshot_terminal_sequence" |> to_int)
(* A failed attempt advances terminal authority without inventing a computed
   observation. Frame admission follows that original terminal identity. *)
let ordering payload = Yojson.Safe.Util.(payload |> member "snapshot_generation" |> to_int), terminal_sequence payload
let newer payload previous =
  let generation, sequence = ordering payload and before_generation, before_sequence = ordering previous in
  generation > before_generation || (generation = before_generation && sequence > before_sequence)

let frames ~sw ~scope id =
  let frames = Eio.Stream.create 32 in
  Sse.subscribe_external ~id
    ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.Mcp_server.config.base_path)
    ~observer_instance_id:(Server_observer_scope.instance_id scope)
    ~callback:(fun event ->
      if Yojson.Safe.Util.member "type" event.Sse.ext_payload = `String "operator_snapshot" then
        Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)) ();
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
  frames

let rec frame_after frames previous accept =
  let payload = Eio.Stream.take frames in
  match Yojson.Safe.Util.member "snapshot_observation_state" payload with
  | `String ("initializing" | "invalidated" | "ready" | "error") ->
      if newer payload previous && accept payload then payload else frame_after frames previous accept
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
      fail "Snapshot frame has no closed observation state"

let ready payload = Yojson.Safe.Util.member "snapshot_observation_state" payload = `String "ready"
let total_confirmations payload = Yojson.Safe.Util.(payload |> member "pending_confirm_envelope"
  |> member "summary" |> member "total_count" |> to_int)

let write_confirmation config ~now =
  let expires_at = Masc_domain.iso8601_of_unix_seconds (now +. 60.0) in
  let entry : Operator_pending_confirm.pending_confirm = {
    confirm_token = "snapshot-flow-confirmation"; trace_id = "snapshot-flow-trace";
    actor = "other-operator"; action_type = "keeper_message"; target_type = "keeper";
    target_id = Some "declared-only"; payload = `Assoc []; delegated_tool = "masc_keeper_delegate";
    created_at = Masc_domain.iso8601_of_unix_seconds now; expires_at = Some expires_at} in
  (match Operator_pending_confirm.write_pending_confirms config [entry] with
   | Ok () -> () | Error detail -> fail detail);
  match Masc_domain.parse_iso8601_opt expires_at with
  | Some at -> at | None -> fail "invalid fixture expiry"

let test_actual_initial_source_change_and_semantic_deadline () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let cold = read ~state ~sw ~clock "" in
    check string "cold default HTTP is a completed observation" "ready"
      Yojson.Safe.Util.(cold |> member "snapshot_observation_state" |> to_string);
    let expires = write_confirmation scope.config ~now:(Eio.Time.now clock) in
    let frames = frames ~sw ~scope "actual-snapshot-deadline" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    let initial = frame_after frames cold (fun payload -> ready payload && total_confirmations payload = 1) in
    check string "canonical source frame has its captured workspace instance"
      (Server_observer_scope.instance_id scope)
      Yojson.Safe.Util.(initial |> member "observer_instance_id" |> to_string);
    check (float 0.0) "canonical deadline is the original hidden confirmation expiry" expires
      Yojson.Safe.Util.(initial |> member "snapshot_fresh_until_unix" |> to_number);
    check bool "no healthy refresh interval is advertised" true
      Yojson.Safe.Util.(initial |> member "retention" |> member "background_refresh_interval_s" = `Null);
    let before_count = Yojson.Safe.Util.(initial |> member "workspace" |> member "agent_count" |> to_int) in
    ignore (Workspace.bind_session scope.config ~agent_name:"actual-snapshot-source-agent" ~capabilities:[] ());
    let changed = frame_after frames initial (fun payload -> ready payload
      && Yojson.Safe.Util.(payload |> member "workspace" |> member "agent_count" |> to_int) = before_count + 1) in
    check (float 0.0) "an original record write preserves the same policy deadline" expires
      Yojson.Safe.Util.(changed |> member "snapshot_fresh_until_unix" |> to_number);
    (* No later input/GET is sent: the same-read semantic deadline owns this read. *)
    Eio_mock.Clock.set_time mock_clock expires;
    let expired = frame_after frames changed (fun payload -> ready payload && total_confirmations payload = 0) in
    check bool "expiry completion clears its own timed debt" true
      Yojson.Safe.Util.(expired |> member "snapshot_fresh_until_unix" = `Null);
    check (list string) "the actual store has removed the expired entry" []
      (List.map (fun (entry : Operator_pending_confirm.pending_confirm) -> entry.confirm_token)
        (Operator_pending_confirm.raw_pending_confirms scope.config));
    Eio.Fiber.yield ();
    check bool "successful quiet state has no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_actual_partial_retry_after_quiet_file_repair () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    ignore (Workspace.bind_session scope.config ~agent_name:"readable-snapshot-agent" ~capabilities:[] ());
    let broken = Keeper_types_profile.keeper_meta_path scope.config "unread-snapshot-metadata" in
    (match Fs_compat.save_file_atomic broken "{" with Ok () -> () | Error detail -> fail detail);
    let owner = Owner.owner_for_scope ~state scope in
    let canonical_before_private = Yojson.Safe.to_string (Owner.publication_json (Owner.publication owner)) in
    let private_read = read ~state ~sw ~clock "?view=summary&include_messages=0" in
    check bool "private read preserves the actual typed partial outcome" true
      Yojson.Safe.Util.(private_read |> member "projection_diagnostics" |> member "read_completeness" = `String "partial");
    check bool "private response never borrows canonical ordering" true
      Yojson.Safe.Util.(private_read |> member "snapshot_epoch" = `Null);
    check bool "private query preserves its actual include-messages flag" true
      Yojson.Safe.Util.(private_read |> member "query" |> member "include_messages" = `Bool false);
    check bool "private query is never labeled default" true
      Yojson.Safe.Util.(private_read |> member "query" |> member "default_summary_request" = `Bool false);
    check string "private response attests its captured request scope"
      (Server_observer_scope.instance_id scope)
      Yojson.Safe.Util.(private_read |> member "observer_instance_id" |> to_string);
    check string "private partial rows do not replace default canonical state" canonical_before_private
      (Yojson.Safe.to_string (Owner.publication_json (Owner.publication owner)));
    let now = Eio.Time.now clock in
    let cold = read ~state ~sw ~clock "" in
    check string "cold default partial body is a canonical error" "error"
      Yojson.Safe.Util.(cold |> member "snapshot_observation_state" |> to_string);
    check int "partial response retains its independently readable workspace rows" 1
      Yojson.Safe.Util.(cold |> member "workspace" |> member "agent_count" |> to_int);
    check int "repeated partial GET cannot bypass failure backoff" (sequence cold)
      (sequence (read ~state ~sw ~clock ""));
    let frames = frames ~sw ~scope "actual-snapshot-partial-retry" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    let partial = frame_after frames cold (fun payload ->
      Yojson.Safe.Util.member "snapshot_observation_state" payload = `String "error") in
    check bool "source partial frame retains the same unread metadata" true
      Yojson.Safe.Util.(partial |> member "keepers" |> member Keeper_snapshot_unread.section_field |> to_list
        |> List.exists (fun row -> row |> member "name" = `String "unread-snapshot-metadata"));
    (* No canonical writer, input event, GET or filesystem observer repairs
       this read. Only the existing failure retry may consume the raw fix. *)
    Sys.remove broken;
    let rec advance_when_registered () =
      Eio.Fiber.yield ();
      if not (Eio_mock.Clock.try_advance mock_clock) then advance_when_registered () in
    advance_when_registered ();
    let recovered = frame_after frames partial ready in
    check (float 0.0) "repair is read at the existing failure-only interval"
      (now +. Server_dashboard_http_core_operator.operator_refresh_interval_s) (Eio.Time.now clock);
    check bool "recovery carries the producer's complete read outcome" true
      Yojson.Safe.Util.(recovered |> member "projection_diagnostics" |> member "read_completeness" = `String "complete");
    Eio.Fiber.yield ();
    check bool "successful repair leaves no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_actual_completed_read_survives_continuous_original_inputs () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let held, signal_held = Eio.Promise.create () in
    let release, release_held = Eio.Promise.create () in
    let calls = Atomic.make 0 in
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot =
      (fun ?read_policy ?actor ?view ?include_messages ?include_keepers
          ?include_summary_fields ?lightweight_summary ctx ->
        let call = Atomic.fetch_and_add calls 1 + 1 in
        let result = Operator_control.snapshot_read ?read_policy ?actor ?view ?include_messages
            ?include_keepers ?include_summary_fields ?lightweight_summary ctx in
        if call = 1 then (Eio.Promise.resolve signal_held (); Eio.Promise.await release);
        result)};
    let owner = Owner.owner_for_scope ~state scope in
    let completions = Eio.Stream.create 8 in
    let unsubscribe = Owner.subscribe_completed owner (function
      | Owner.Installed Source_read ->
          Eio.Stream.add completions (Owner.publication_json (Owner.publication owner))
      | Installed Default_request | Failed _ | Source_changed | Invalidated -> ()) in
    Eio.Switch.on_release sw unsubscribe;
    let frames = frames ~sw ~scope "actual-snapshot-trailing-read" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    Eio.Promise.await held;
    List.iter (fun name -> ignore (Workspace.bind_session scope.config ~agent_name:name ~capabilities:[] ()))
      ["actual-source-one"; "actual-source-two"; "actual-source-three"];
    Eio.Promise.resolve release_held ();
    let first = Eio.Stream.take completions in
    let trailing = Eio.Stream.take completions in
    check int "first completed actual observation is retained despite the inputs" 0
      Yojson.Safe.Util.(first |> member "workspace" |> member "agent_count" |> to_int);
    check int "one trailing read observes all original record writes" 3
      Yojson.Safe.Util.(trailing |> member "workspace" |> member "agent_count" |> to_int);
    check int "the bounded input mailbox leaves exactly one trailing Current read" 2 (Atomic.get calls);
    let published = frame_after frames first (fun payload -> ready payload
      && Yojson.Safe.Util.(payload |> member "workspace" |> member "agent_count" |> to_int) = 3) in
    check int "canonical output follows the completed trailing observation" (sequence trailing) (sequence published);
    Eio.Fiber.yield ();
    check bool "progress leaves no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_actual_default_request_wins_held_source_and_is_published () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let held, signal_held = Eio.Promise.create () in
    let release, release_held = Eio.Promise.create () in
    let calls = Atomic.make 0 in
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot =
      (fun ?read_policy ?actor ?view ?include_messages ?include_keepers
          ?include_summary_fields ?lightweight_summary ctx ->
        let call = Atomic.fetch_and_add calls 1 + 1 in
        let result = Operator_control.snapshot_read ?read_policy ?actor ?view ?include_messages
            ?include_keepers ?include_summary_fields ?lightweight_summary ctx in
        if call = 1 then (Eio.Promise.resolve signal_held (); Eio.Promise.await release);
        result)};
    let owner = Owner.owner_for_scope ~state scope in
    let completed_source = Eio.Stream.create 4 in
    let unsubscribe = Owner.subscribe_completed owner (function
      | Owner.Installed Source_read ->
          Eio.Stream.add completed_source (Owner.publication_json (Owner.publication owner))
      | Installed Default_request | Failed _ | Source_changed | Invalidated -> ()) in
    Eio.Switch.on_release sw unsubscribe;
    let frames = frames ~sw ~scope "actual-snapshot-request-handoff" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    Eio.Promise.await held;
    let response = read ~state ~sw ~clock "" in
    check string "the actual default HTTP completes while the older source is held" "ready"
      Yojson.Safe.Util.(response |> member "snapshot_observation_state" |> to_string);
    check int "HTTP performed its own actual Current read" 2 (Atomic.get calls);
    check string "HTTP and deferred publisher share one immutable canonical body"
      (Yojson.Safe.to_string response)
      (Yojson.Safe.to_string (Owner.publication_json (Owner.publication owner)));
    let rec same_frame () =
      let payload = Eio.Stream.take frames in
      if sequence payload = sequence response && ready payload then payload else same_frame () in
    check string "request completion itself reaches the scoped SSE consumer"
      (Yojson.Safe.to_string response) (Yojson.Safe.to_string (same_frame ()));
    Eio.Promise.resolve release_held ();
    let trailing = Eio.Stream.take completed_source in
    check bool "the held older source cannot replace the completed request" true
      (sequence trailing > sequence response);
    check int "one read remains owed after the request's completion" 3 (Atomic.get calls);
    check (option string) "rejected old completion does not synthesize a cache failure" None
      (Owner.cache_snapshot owner).last_error;
    Eio.Fiber.yield ();
    check bool "settled request handoff leaves no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

(* Production workers space change-driven reads by their declared interval.
   A second change inside that spacing is read when the worker's clock passes
   it; the first try waits for the worker to take the change. *)
let pass_change_read_spacing ~env clock =
  let rec go tries =
    Eio.Fiber.yield ();
    if not (Eio_mock.Clock.try_advance clock) then
      if tries = 0 then fail "a change inside the spacing left no owed read"
      else (
        Eio.Time.sleep (Eio.Stdenv.clock env) 0.005;
        go (tries - 1))
  in
  go 400
;;

let test_actual_board_attention_commit_updates_quarantine_without_get () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let module Candidate = Keeper_board_attention_candidate in
    let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc [
        "name", `String "snapshot-ledger-keeper"; "trace_id", `String "snapshot-ledger-trace";
        "total_turns", `Int 1; "activation_mode", `String "autonomous"]) with
      | Ok meta -> {meta with paused = true} | Error detail -> fail detail in
    (match Keeper_meta_store.replace_snapshot scope.config meta with
     | Ok () -> () | Error detail -> fail detail);
    let signal : Board_dispatch.board_signal = {
      kind = Board_dispatch.Board_post_created; post_id = "snapshot-ledger-post";
      author = "snapshot-ledger-author"; title = "Snapshot source fixture";
      content = "Durable source only"; hearth = None; updated_at = Some 42.0} in
    let candidate : Candidate.candidate = {
      candidate_id = Candidate.candidate_id_of_signal ~keeper_name:meta.name signal;
      keeper_name = meta.name; signal; audience = Board.Discoverable;
      keeper_context = `Assoc ["lane_keeper_name", `String meta.name;
        "board_interests", `List [`String "runtime"]];
      recorded_at = 1.0; status = Pending {last_delivery_failure = None}} in
    (match Candidate.record ~base_path:scope.config.base_path candidate with
     | Recorded _ -> () | Duplicate _ -> fail "isolated ledger already had the candidate"
     | Record_error detail -> fail detail);
    let cold = read ~state ~sw ~clock "" in
    let frames = frames ~sw ~scope "actual-snapshot-ledger-input" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    let initial = frame_after frames cold ready in
    let inventory payload = Yojson.Safe.Util.(payload |> member "board_attention_quarantines") in
    check int "initial source read has no quarantine" 0
      Yojson.Safe.Util.(inventory initial |> member "count" |> to_int);
    let foreign_base = Filename.concat scope.config.base_path "foreign-attention-owner" in
    (match Candidate.record ~base_path:foreign_base candidate with
     | Recorded _ -> () | Duplicate _ -> fail "isolated foreign ledger had the candidate"
     | Record_error detail -> fail detail);
    let owner = Owner.owner_for_scope ~state scope in
    check bool "foreign ledger attempts do not owe this workspace a read" true
      (Owner.publication_is_current owner (Owner.publication owner));
    let quarantined = match Candidate.quarantine ~base_path:scope.config.base_path ~candidate
        ~partition_id:"snapshot-ledger-partition"
        ~partition_generation:Keeper_board_attention_partition_generation.initial
        ~failure_category:Unexpected_worker_failure ~attempt_provenance:None ~quarantined_at:3.0 with
      | Ok candidate -> candidate | Error detail -> fail detail in
    let quarantine_id = match quarantined.status with
      | Quarantine state -> state.quarantine.quarantine_id
      | Pending _ | Judged _ | Consumed _ -> fail "actual quarantine commit lost its state" in
    (* No Board broadcast, phase transition, later input, GET or clock advance:
       the exact Candidate mutation must alone wake the actual source reader. *)
    let changed = frame_after frames initial (fun payload -> ready payload
      && Yojson.Safe.Util.(inventory payload |> member "count" |> to_int) = 1) in
    check string "canonical source carries the committed quarantine incarnation" quarantine_id
      Yojson.Safe.Util.(inventory changed |> member "items" |> to_list |> List.hd
        |> member "quarantine_id" |> to_string);
    (match Candidate.purge ~base_path:scope.config.base_path ~keeper_name:meta.name with
     | Ok () -> () | Error detail -> fail detail);
    pass_change_read_spacing ~env mock_clock;
    let removed = frame_after frames changed (fun payload -> ready payload
      && Yojson.Safe.Util.(inventory payload |> member "count" |> to_int) = 0) in
    check bool "actual purge also preserves complete read authority" true
      Yojson.Safe.Util.(removed |> member "projection_diagnostics" |> member "read_completeness" = `String "complete");
    Eio.Fiber.yield ();
    check bool "settled ledgers leave no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_actual_no_result_failure_does_not_repeat_cold_reads () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let calls = Atomic.make 0 in
    Dashboard_projection_cache.register_operator_snapshot_json {snapshot =
      (fun ?read_policy ?actor ?view ?include_messages ?include_keepers
          ?include_summary_fields ?lightweight_summary ctx ->
        ignore (Atomic.fetch_and_add calls 1);
        Operator_control.snapshot_read ?read_policy ?actor ?view ?include_messages
          ?include_keepers ?include_summary_fields ?lightweight_summary ctx)};
    let path = Operator_pending_confirm.pending_confirms_path scope.config in
    Fs_compat.mkdir_p (Filename.dirname path);
    (match Fs_compat.save_file_atomic path "{" with Ok () -> () | Error detail -> fail detail);
    let cold = read ~state ~sw ~clock "" in
    let owner = Owner.owner_for_scope ~state scope in
    check bool "a thrown actual read has no retained body" false (Owner.has_observation owner);
    check string "first failure is a canonical terminal error" "error"
      Yojson.Safe.Util.(cold |> member "snapshot_observation_state" |> to_string);
    List.iter (fun () -> check (pair int int) "failed cold GET retains the terminal identity" (ordering cold)
      (ordering (read ~state ~sw ~clock ""))) [(); (); ()];
    check int "repeated GET cannot reissue the failed Current read" 1 (Atomic.get calls);
    let frames = frames ~sw ~scope "actual-snapshot-no-result-retry" in
    Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
    let failed = frame_after frames cold (fun payload ->
      Yojson.Safe.Util.member "snapshot_observation_state" payload = `String "error") in
    check bool "the failed source attempt advances its real terminal identity" true
      (terminal_sequence failed > terminal_sequence cold);
    check int "a failed source attempt does not fabricate a computed observation"
      (sequence cold) (sequence failed);
    check int "the source worker owns its one initial recovery read" 2 (Atomic.get calls);
    let failed_sequence = sequence failed in
    ignore (read ~state ~sw ~clock "");
    check int "GET during source failure backoff remains quiet" 2 (Atomic.get calls);
    (* Raw repair supplies no pending-confirm invalidation or new HTTP read. *)
    (match Fs_compat.save_file_atomic path "[]" with Ok () -> () | Error detail -> fail detail);
    let rec advance_when_registered () =
      Eio.Fiber.yield ();
      if not (Eio_mock.Clock.try_advance mock_clock) then advance_when_registered () in
    advance_when_registered ();
    let recovered = frame_after frames failed ready in
    check bool "failure-only retry advances the same canonical owner" true (sequence recovered > failed_sequence);
    check int "one existing failure retry consumes the quiet repair" 3 (Atomic.get calls);
    Eio.Fiber.yield ();
    check bool "complete recovery leaves no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_actual_context_tail_failure_retries_after_quiet_raw_repair () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let trace_id = "trace-1780648779957-00000" in
    let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc [
        "name", `String "snapshot-context-keeper"; "trace_id", `String trace_id;
        "total_turns", `Int 1; "activation_mode", `String "autonomous"]) with
      | Ok meta -> {meta with paused = false} | Error detail -> fail detail in
    (match Keeper_meta_store.replace_snapshot scope.config meta with
     | Ok () -> () | Error detail -> fail detail);
    let record : Turn_record.t = {
      request_observations = []; execution_ids = []; keeper = meta.name;
      agent_name = meta.name; turn_kind = Direct; trace_id; absolute_turn = 1;
      turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      blocks = [];
      input_components = None; tool_surface_ref = None; runtime_profile = "fixture";
      selected_model = None; finish_reason = Some "completed";
      context_window = Some 131_072; provider_context_window = None;
      price_input_per_million = None; price_output_per_million = None;
      request_latency_ms = None; ttfrc_ms = None; request_wire_observation = None;
      model_input_window = None; response_observed_model_input = None; refused_model_input = None;
      raw_trace_run_ref = None;
      sampling = {temperature = None; top_p = None; max_tokens = None; enable_thinking = None};
      usage = {input_tokens = Some 18_000; output_tokens = Some 412;
        cache_creation_input_tokens = None; cache_read_input_tokens = None;
        scope = Runtime_usage_scope.Per_request; input_provenance = None};
      turn_output_tokens = None; ts = Eio.Time.now clock} in
    let store = Keeper_types_support.keeper_turn_record_store scope.config meta.name in
    Dated_jsonl.append store (Turn_record.to_json record);
    Dated_jsonl.close store;
    let base_dir = Dated_jsonl.base_dir store in
    let held_dir = base_dir ^ ".fixture-held" in
    Sys.rename base_dir held_dir;
    let restored = ref false in
    let restore () =
      if not !restored then (
        if Sys.file_exists base_dir then Sys.remove base_dir;
        Sys.rename held_dir base_dir;
        restored := true) in
    Fun.protect ~finally:restore (fun () ->
      let channel = open_out_bin base_dir in
      output_string channel "not a directory";
      close_out channel;
      check bool "the isolated Keeper has no running registry phase" true
        (Keeper_registry.get_phase ~base_path:scope.config.base_path meta.name = None);
      let trust = Keeper_runtime_trust_snapshot.summary_observation ~config:scope.config ~meta in
      check bool "Trust does not already classify this distinct context-tail failure" true
        (trust.completeness = Dashboard_projection_read.Complete);
      let keeper_row payload =
        match Yojson.Safe.Util.(payload |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row -> Yojson.Safe.Util.member "name" row = `String meta.name) with
        | Some row -> row | None -> fail "actual Snapshot omitted the context Keeper" in
      let cold = read ~state ~sw ~clock "" in
      check string "the actual tail failure settles as a canonical error" "error"
        Yojson.Safe.Util.(cold |> member "snapshot_observation_state" |> to_string);
      check bool "the same actual read retains Partial" true
        Yojson.Safe.Util.(cold |> member "projection_diagnostics" |> member "read_completeness" = `String "partial");
      check bool "the stopped unpaused row has no semantic wake deadline" true
        Yojson.Safe.Util.(cold |> member "snapshot_fresh_until_unix" = `Null);
      check bool "the context-reading branch is unpaused" true
        Yojson.Safe.Util.(keeper_row cold |> member "paused" = `Bool false);
      check bool "the actual context diagnostic retains its typed read failure" true
        Yojson.Safe.Util.(keeper_row cold |> member "context_metrics_unavailable"
          |> member "reason" = `String "turn_record_read_failed");
      let now = Eio.Time.now clock in
      let frames = frames ~sw ~scope "actual-snapshot-context-tail-retry" in
      Worker.start_operator_snapshot_refresh_loop ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
      let failed = frame_after frames cold (fun payload ->
        Yojson.Safe.Util.member "snapshot_observation_state" payload = `String "error") in
      (* No metadata append, input, later GET, or elapsed healthy refresh
         consumes this raw restoration. Only the existing failure debt can. *)
      restore ();
      let rec advance_when_registered () =
        Eio.Fiber.yield ();
        if not (Eio_mock.Clock.try_advance mock_clock) then advance_when_registered () in
      advance_when_registered ();
      let recovered = frame_after frames failed ready in
      check (float 0.0) "context recovery uses the existing failure-only interval"
        (now +. Server_dashboard_http_core_operator.operator_refresh_interval_s) (Eio.Time.now clock);
      check bool "the repaired actual read is complete" true
        Yojson.Safe.Util.(recovered |> member "projection_diagnostics" |> member "read_completeness" = `String "complete");
      check int "the original same-trace measurement reaches canonical output" 18_000
        Yojson.Safe.Util.(keeper_row recovered |> member "context_tokens" |> to_int);
      check bool "the typed unavailable diagnostic clears" true
        Yojson.Safe.Util.(keeper_row recovered |> member "context_metrics_unavailable" = `Null);
      Eio.Fiber.yield ();
      check bool "successful context repair leaves no healthy timer" false (Eio_mock.Clock.try_advance mock_clock)))

let () = Alcotest.run "operator_snapshot_feature_flow" ["production", [
  test_case "cold HTTP and original input reach exact semantic expiry" `Quick
    test_actual_initial_source_change_and_semantic_deadline;
  test_case "actual partial read repairs through failure-only retry" `Quick
    test_actual_partial_retry_after_quiet_file_repair;
  test_case "completed Current and one trailing read survive original inputs" `Quick
    test_actual_completed_read_survives_continuous_original_inputs;
  test_case "actual default request owns completion while source is held" `Quick
    test_actual_default_request_wins_held_source_and_is_published;
  test_case "actual Board attention commit reaches scoped quarantine output" `Quick
    test_actual_board_attention_commit_updates_quarantine_without_get;
  test_case "actual no-result failure remains owed only to failure retry" `Quick
    test_actual_no_result_failure_does_not_repeat_cold_reads;
  test_case "actual context-tail failure repairs through failure-only retry" `Quick
    test_actual_context_tail_failure_retries_after_quiet_raw_repair]]
