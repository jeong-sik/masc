(** Regression guards for the keeper OAS raw-trace wiring.

    [Keeper_turn_driver.run_named] has always accepted [?raw_trace] and
    forwarded it into the OAS agent builder, but the sole keeper dispatch
    site ([call_run_named] in keeper_agent_run.ml) never supplied it: OAS
    started no raw-trace run for keeper turns, so
    [run_result.trace_ref]/[run_validation] stayed permanently [None] in
    the unified-metrics decision/snapshot rows and the keeper_turn.ml
    progress-evidence disjunct.

    Trace-store safety guards (review on PR #22984):
    - P1a: sink creation must never scan previous turns' data, so a
      corrupt/oversized historical trace cannot block dispatch; if
      creation still fails, the turn dispatches untraced with a typed
      degrade record ([Sink_degraded] -> warn log + counter), never a
      pre-dispatch error.
    - P1b: the store is bounded — one fresh JSONL per turn under
      [.masc/keepers/<name>/raw-traces/], deterministically pruned to
      [Keeper_types_support.raw_trace_retained_turn_files].
    - Consumer level: a traced turn yields non-[None]
      [run_result.trace_ref]/[run_validation] via exactly the projection
      [Runtime_agent.run] performs. *)

open Masc

let keeper_name = "keeper-raw-trace"

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_raw_trace_sink_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Sys.remove path
  in
  try rm dir with _ -> ()

let make_test_meta () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [
           ("name", `String keeper_name);
           ("agent_name", `String (keeper_name ^ "-agent"));
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () -> f (Workspace.default_config dir))

let ok_or_fail label = function
  | Ok v -> v
  | Error err ->
      Alcotest.fail
        (Printf.sprintf "%s: %s" label (Agent_sdk.Error.to_string err))

let sink_or_fail label = function
  | Keeper_agent_run.Sink_ready sink -> sink
  | Keeper_agent_run.Sink_degraded err ->
      Alcotest.fail
        (Printf.sprintf "%s: degraded: %s" label
           (Agent_sdk.Error.to_string err))

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let jsonl_files dir =
  (try Sys.readdir dir with Sys_error _ -> [||])
  |> Array.to_list
  |> List.filter (fun entry -> Filename.check_suffix entry ".jsonl")

(* Drive one turn's records through the sink with the OAS run API — the
   same append sequence [Agent_sdk.Agent.run] performs when the agent is
   built with the sink. *)
let materialize_turn ~(meta : Keeper_meta_contract.keeper_meta) ~turn sink =
  let active =
    ok_or_fail "start_run"
      (Agent_sdk.Raw_trace.start_run sink ~agent_name:meta.name
         ~prompt:(Printf.sprintf "turn-%d" turn) ())
  in
  ok_or_fail "finish_run"
    (Agent_sdk.Raw_trace.finish_run active
       ~final_text:(Some (Printf.sprintf "done-%d" turn))
       ~stop_reason:(Some "end_turn") ~error:None)

(* Per-turn store lives under the keepers runtime dir — the SSOT shared
   with the metrics/receipt stores — and every call hands out a fresh
   file so [Raw_trace.create] never reads previous turns. *)
let test_raw_trace_path_layout () =
  with_workspace @@ fun config ->
  let expected_dir =
    Filename.concat
      (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
      "raw-traces"
  in
  Alcotest.(check string) "keeper raw-trace dir layout" expected_dir
    (Keeper_types_support.keeper_raw_trace_dir config keeper_name);
  let path1 =
    Keeper_types_support.keeper_raw_trace_turn_path config keeper_name
  in
  let path2 =
    Keeper_types_support.keeper_raw_trace_turn_path config keeper_name
  in
  Alcotest.(check string) "turn path lives in the raw-trace dir" expected_dir
    (Filename.dirname path1);
  Alcotest.(check bool) "turn path is a .jsonl file" true
    (Filename.check_suffix path1 ".jsonl");
  Alcotest.(check bool) "successive turn paths are distinct" true
    (not (String.equal path1 path2))

(* The sink constructed for dispatch must write to a fresh per-turn file
   in the SSOT dir and carry the keeper trace id as its session identity. *)
let test_sink_path_and_session_identity () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let sink =
    sink_or_fail "keeper_raw_trace_sink"
      (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
  in
  Alcotest.(check string) "sink file lives in the SSOT raw-trace dir"
    (Keeper_types_support.keeper_raw_trace_dir config meta.name)
    (Filename.dirname (Agent_sdk.Raw_trace.file_path sink));
  Alcotest.(check (option string)) "sink session id = keeper trace id"
    (Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
    (Agent_sdk.Raw_trace.session_id sink);
  let sink2 =
    sink_or_fail "keeper_raw_trace_sink (second turn)"
      (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
  in
  Alcotest.(check bool) "second turn gets a fresh file" true
    (not
       (String.equal
          (Agent_sdk.Raw_trace.file_path sink)
          (Agent_sdk.Raw_trace.file_path sink2)))

let test_sink_creates_keeper_runtime_dir () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let keeper_dir =
    Filename.concat (Workspace.keepers_runtime_dir config) meta.name
  in
  Alcotest.(check bool) "keeper dir starts absent" false
    (Sys.file_exists keeper_dir);
  ignore
    (sink_or_fail "keeper_raw_trace_sink"
       (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta));
  Alcotest.(check bool) "keeper dir created" true
    (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir);
  let raw_trace_dir =
    Keeper_types_support.keeper_raw_trace_dir config meta.name
  in
  Alcotest.(check bool) "raw-trace store dir created" true
    (Sys.file_exists raw_trace_dir && Sys.is_directory raw_trace_dir)

(* Each turn is its own file: turn N+1 never appends to (or scans) turn
   N's file, so per-turn sink creation cost is independent of lifetime
   trace volume. *)
let test_per_turn_files_isolate_turns () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let run_once ~turn =
    let sink =
      sink_or_fail "keeper_raw_trace_sink"
        (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
    in
    let (_ref : Agent_sdk.Raw_trace.run_ref) =
      materialize_turn ~meta ~turn sink
    in
    Agent_sdk.Raw_trace.file_path sink
  in
  let path1 = run_once ~turn:1 in
  let path2 = run_once ~turn:2 in
  Alcotest.(check bool) "turn files are distinct" true
    (not (String.equal path1 path2));
  let records_of path =
    ok_or_fail "read_all" (Agent_sdk.Raw_trace.read_all ~path ())
  in
  let count_started records =
    List.length
      (List.filter
         (fun (r : Agent_sdk.Raw_trace.record) ->
           match r.record_type with
           | Agent_sdk.Raw_trace.Run_started -> true
           | _ -> false)
         records)
  in
  Alcotest.(check int) "first turn's file holds exactly its own run" 1
    (count_started (records_of path1));
  Alcotest.(check int) "second turn's file holds exactly its own run" 1
    (count_started (records_of path2))

(* P1a core: corrupt (or arbitrarily large) historical trace data must
   not fail sink creation — the fresh per-turn file means OAS
   [create -> scan_next_seq -> read_all] never touches it. Covers both a
   corrupt previous per-turn file and a corrupt legacy single-file
   [raw-trace.jsonl] from the pre-review layout of this branch. *)
let test_corrupt_history_does_not_block_sink () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let raw_trace_dir =
    Keeper_types_support.keeper_raw_trace_dir config meta.name
  in
  Fs_compat.mkdir_p raw_trace_dir;
  let corrupt_turn_file =
    Filename.concat raw_trace_dir "turn-0000000000000-0000-000000.jsonl"
  in
  write_file corrupt_turn_file "{\"seq\": not-valid-json\ngarbage line\n";
  let corrupt_legacy_file =
    Filename.concat (Filename.dirname raw_trace_dir) "raw-trace.jsonl"
  in
  write_file corrupt_legacy_file "also not json\n";
  let sink =
    sink_or_fail "sink creation with corrupt history present"
      (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
  in
  Alcotest.(check bool) "fresh file, not the corrupt one" true
    (not
       (String.equal (Agent_sdk.Raw_trace.file_path sink) corrupt_turn_file));
  (* The new turn still traces normally. *)
  let (_ref : Agent_sdk.Raw_trace.run_ref) =
    materialize_turn ~meta ~turn:1 sink
  in
  (* And the dispatch adapter hands the sink to the turn (no degrade). *)
  Alcotest.(check bool) "dispatch receives a sink despite corrupt history"
    true
    (Option.is_some
       (Keeper_agent_run.For_testing.raw_trace_for_dispatch ~config ~meta))

(* P1a isolation: when the trace store is genuinely unavailable, the
   sink degrades ([Sink_degraded]) and dispatch proceeds untraced
   ([None]) with the typed counter emitted — the turn never fails
   pre-dispatch on observability state. *)
let test_degraded_sink_dispatches_untraced () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let keeper_dir =
    Filename.concat (Workspace.keepers_runtime_dir config) meta.name
  in
  Fs_compat.mkdir_p keeper_dir;
  let metric_name = Keeper_metrics.(to_string RawTraceSinkDegraded) in
  let degrade_count () =
    Masc.Otel_metric_store.metric_value_or_zero metric_name
      ~labels:[ ("keeper", meta.name) ]
      ()
  in
  Fun.protect
    ~finally:(fun () -> try Unix.chmod keeper_dir 0o755 with _ -> ())
    (fun () ->
      Unix.chmod keeper_dir 0o555;
      (match
         Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta
       with
      | Keeper_agent_run.Sink_degraded _ -> ()
      | Keeper_agent_run.Sink_ready _ ->
          Alcotest.fail
            "unwritable keeper dir must yield Sink_degraded, not a sink");
      let before = degrade_count () in
      Alcotest.(check bool)
        "degraded store dispatches the turn untraced (None, no error)" true
        (Option.is_none
           (Keeper_agent_run.For_testing.raw_trace_for_dispatch ~config ~meta));
      Alcotest.(check (float 0.0001))
        "degrade emits the typed RawTraceSinkDegraded counter"
        (before +. 1.0) (degrade_count ()))

(* P1b: deterministic retention — oldest-by-name (= oldest-by-time via
   the zero-padded timestamp prefix) files beyond the named bound are
   removed; non-.jsonl entries are not candidates; pruning is idempotent. *)
let test_prune_removes_oldest_beyond_retention () =
  with_workspace @@ fun config ->
  let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
  Fs_compat.mkdir_p dir;
  let n_extra = 7 in
  let total = Keeper_types_support.raw_trace_retained_turn_files + n_extra in
  let name_of i = Printf.sprintf "turn-%013d-0000-%06d.jsonl" i i in
  for i = 0 to total - 1 do
    write_file (Filename.concat dir (name_of i)) "{}\n"
  done;
  write_file (Filename.concat dir "not-a-trace.tmp") "keep\n";
  Alcotest.(check int) "prune removes exactly the excess" n_extra
    (Keeper_types_support.prune_keeper_raw_trace_turn_files config keeper_name);
  for i = 0 to n_extra - 1 do
    Alcotest.(check bool)
      (Printf.sprintf "oldest file %d removed" i)
      false
      (Sys.file_exists (Filename.concat dir (name_of i)))
  done;
  Alcotest.(check bool) "retention boundary file survives" true
    (Sys.file_exists (Filename.concat dir (name_of n_extra)));
  Alcotest.(check bool) "newest file survives" true
    (Sys.file_exists (Filename.concat dir (name_of (total - 1))));
  Alcotest.(check bool) "non-jsonl entries are not retention candidates" true
    (Sys.file_exists (Filename.concat dir "not-a-trace.tmp"));
  Alcotest.(check int) "second prune is a no-op" 0
    (Keeper_types_support.prune_keeper_raw_trace_turn_files config keeper_name)

(* P1b end-to-end: creating sinks turn after turn keeps the store at the
   documented steady-state bound (retained + the freshly materialized
   turn file), with the oldest turn files the ones pruned. *)
let test_sink_creation_enforces_retention_bound () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let retained = Keeper_types_support.raw_trace_retained_turn_files in
  let turns = retained + 3 in
  let first_path = ref "" in
  let last_path = ref "" in
  for turn = 1 to turns do
    let sink =
      sink_or_fail "keeper_raw_trace_sink"
        (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
    in
    let (_ref : Agent_sdk.Raw_trace.run_ref) =
      materialize_turn ~meta ~turn sink
    in
    let path = Agent_sdk.Raw_trace.file_path sink in
    if turn = 1 then first_path := path;
    last_path := path
  done;
  let dir = Keeper_types_support.keeper_raw_trace_dir config meta.name in
  Alcotest.(check int) "store is bounded at retained + 1 files"
    (retained + 1)
    (List.length (jsonl_files dir));
  Alcotest.(check bool) "oldest turn file was pruned" false
    (Sys.file_exists !first_path);
  Alcotest.(check bool) "newest turn file was retained" true
    (Sys.file_exists !last_path)

let response ?(content = []) ?(stop_reason = Agent_sdk.Types.EndTurn) () =
  {
    Agent_sdk.Types.id = "resp-test";
    model = "model-test";
    stop_reason;
    content;
    usage = None;
    telemetry = None;
  }

(* Consumer-level regression: a turn whose sink reached the OAS run
   produces non-[None] result-level [trace_ref]/[run_validation]. The
   projection below is exactly what [Runtime_agent.run] performs after
   [Agent.run]: [trace_ref = Agent.last_raw_trace_run agent] (whose body
   is [Raw_trace.last_run sink]) and
   [run_validation = Raw_trace_query.validate_run trace_ref]. *)
let test_traced_turn_yields_result_level_fields () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let sink =
    sink_or_fail "keeper_raw_trace_sink"
      (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
  in
  let (_ref : Agent_sdk.Raw_trace.run_ref) =
    materialize_turn ~meta ~turn:1 sink
  in
  let trace_ref = Agent_sdk.Raw_trace.last_run sink in
  let run_validation =
    match trace_ref with
    | Some ref_ ->
        Some
          (ok_or_fail "validate_run"
             (Agent_sdk.Raw_trace_query.validate_run ref_))
    | None -> None
  in
  let result : Runtime_agent.run_result =
    {
      response = response ();
      checkpoint = None;
      session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id;
      turns = 1;
      trace_ref;
      run_validation;
      runtime_observation = None;
      stop_reason = Runtime_agent.Completed;
    }
  in
  (match result.trace_ref with
  | None ->
      Alcotest.fail "run_result.trace_ref must be Some for a traced turn"
  | Some r ->
      Alcotest.(check string) "trace_ref points at the per-turn sink file"
        (Agent_sdk.Raw_trace.file_path sink)
        r.Agent_sdk.Raw_trace.path);
  match result.run_validation with
  | None ->
      Alcotest.fail "run_result.run_validation must be Some for a traced turn"
  | Some v ->
      Alcotest.(check bool) "minimal traced run validates ok" true
        v.Agent_sdk.Raw_trace.ok

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let repo_root () =
  let marker path = Filename.concat path "lib/keeper/keeper_agent_run.ml" in
  let has_marker path = Sys.file_exists (marker path) in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_marker root -> root
  | _ ->
      let rec ascend path =
        if has_marker path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then path else ascend parent
      in
      ascend (Sys.getcwd ())

(* Dispatch-site wiring guard: within the run_named call block (anchored by
   ~goal:user_message, which doc-comment mentions of run_named never carry),
   ?raw_trace must be passed. This is the regression that motivated the fix:
   the parameter existed end-to-end but the dispatch never supplied it.
   The companion check pins the option to the degrade adapter so a future
   edit cannot silently reintroduce a hard (turn-failing) dependency. *)
let test_keeper_dispatch_passes_raw_trace () =
  let root = repo_root () in
  let rel_path = "lib/keeper/keeper_agent_run.ml" in
  let source = read_file (Filename.concat root rel_path) in
  let marker = "Keeper_turn_driver.run_named" in
  let required_anchor = "~goal:user_message" in
  let required = "?raw_trace" in
  let rec search pos =
    match Astring.String.find_sub ~start:pos ~sub:marker source with
    | None -> false
    | Some idx ->
        let len = min 3000 (String.length source - idx) in
        let dispatch_block = String.sub source idx len in
        (Astring.String.is_infix ~affix:required_anchor dispatch_block
         && Astring.String.is_infix ~affix:required dispatch_block)
        || search (idx + String.length marker)
  in
  Alcotest.(check bool)
    (Printf.sprintf
       "%s: keeper dispatch must pass ?raw_trace into \
        Keeper_turn_driver.run_named"
       rel_path)
    true (search 0);
  Alcotest.(check bool)
    (Printf.sprintf
       "%s: the dispatched sink must come from the degrading adapter \
        (raw_trace_for_dispatch), not a turn-failing require"
       rel_path)
    true
    (Astring.String.is_infix ~affix:"?raw_trace:(raw_trace_for_dispatch"
       source)

let () =
  Alcotest.run "keeper_raw_trace_sink"
    [
      ( "keeper raw-trace sink",
        [
          Alcotest.test_case "SSOT path layout + freshness" `Quick
            test_raw_trace_path_layout;
          Alcotest.test_case "sink path + session identity" `Quick
            test_sink_path_and_session_identity;
          Alcotest.test_case "sink creates keeper runtime dir" `Quick
            test_sink_creates_keeper_runtime_dir;
          Alcotest.test_case "per-turn files isolate turns" `Quick
            test_per_turn_files_isolate_turns;
          Alcotest.test_case "corrupt history does not block sink" `Quick
            test_corrupt_history_does_not_block_sink;
          Alcotest.test_case "degraded sink dispatches untraced" `Quick
            test_degraded_sink_dispatches_untraced;
          Alcotest.test_case "retention prunes oldest beyond bound" `Quick
            test_prune_removes_oldest_beyond_retention;
          Alcotest.test_case "sink creation enforces retention bound" `Quick
            test_sink_creation_enforces_retention_bound;
          Alcotest.test_case "traced turn yields result-level fields" `Quick
            test_traced_turn_yields_result_level_fields;
          Alcotest.test_case "dispatch passes ?raw_trace" `Quick
            test_keeper_dispatch_passes_raw_trace;
        ] );
    ]
