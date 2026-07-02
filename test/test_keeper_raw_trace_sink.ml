(** Regression guards for the keeper OAS raw-trace wiring.

    [Keeper_turn_driver.run_named] has always accepted [?raw_trace] and
    forwarded it into the OAS agent builder, but the sole keeper dispatch
    site ([call_run_named] in keeper_agent_run.ml) never supplied it: OAS
    started no raw-trace run for keeper turns, so
    [run_result.trace_ref]/[run_validation] stayed permanently [None] in
    the unified-metrics decision/snapshot rows and the keeper_turn.ml
    progress-evidence disjunct. Guards here: sink path SSOT + session
    identity, seq resume across per-turn sink re-creation, and a
    dispatch-site source guard (pattern:
    test_keeper_summarizer.test_keeper_dispatch_passes_keeper_summarizer). *)

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

(* One JSONL per keeper under the keepers runtime dir — the sink location
   is derived from the same SSOT as the metrics/receipt stores. *)
let test_raw_trace_path_layout () =
  with_workspace @@ fun config ->
  let expected =
    Filename.concat
      (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
      "raw-trace.jsonl"
  in
  Alcotest.(check string) "keeper raw-trace path layout" expected
    (Keeper_types_support.keeper_raw_trace_path config keeper_name)

(* The sink constructed for dispatch must write to the SSOT path and carry
   the keeper trace id as its session identity. *)
let test_sink_path_and_session_identity () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let sink =
    ok_or_fail "keeper_raw_trace_sink"
      (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
  in
  Alcotest.(check string) "sink file path = SSOT path"
    (Keeper_types_support.keeper_raw_trace_path config meta.name)
    (Agent_sdk.Raw_trace.file_path sink);
  Alcotest.(check (option string)) "sink session id = keeper trace id"
    (Some (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
    (Agent_sdk.Raw_trace.session_id sink)

(* The sink is re-created once per keeper turn on the same path;
   Raw_trace.create must resume the seq counter from the existing file so
   turn N+1 appends after turn N instead of clobbering it. *)
let test_sink_recreation_resumes_seq () =
  with_workspace @@ fun config ->
  let meta = make_test_meta () in
  let run_once ~turn =
    let sink =
      ok_or_fail "keeper_raw_trace_sink"
        (Keeper_agent_run.For_testing.keeper_raw_trace_sink ~config ~meta)
    in
    let active =
      ok_or_fail "start_run"
        (Agent_sdk.Raw_trace.start_run sink ~agent_name:meta.name
           ~prompt:(Printf.sprintf "turn-%d" turn) ())
    in
    ok_or_fail "finish_run"
      (Agent_sdk.Raw_trace.finish_run active
         ~final_text:(Some (Printf.sprintf "done-%d" turn))
         ~stop_reason:(Some "end_turn") ~error:None)
  in
  let ref1 = run_once ~turn:1 in
  let ref2 = run_once ~turn:2 in
  Alcotest.(check bool) "second turn's run appends after the first" true
    (ref2.Agent_sdk.Raw_trace.start_seq > ref1.Agent_sdk.Raw_trace.end_seq);
  let records =
    ok_or_fail "read_all"
      (Agent_sdk.Raw_trace.read_all
         ~path:(Keeper_types_support.keeper_raw_trace_path config meta.name)
         ())
  in
  let run_started_count =
    List.length
      (List.filter
         (fun (r : Agent_sdk.Raw_trace.record) ->
           match r.record_type with
           | Agent_sdk.Raw_trace.Run_started -> true
           | _ -> false)
         records)
  in
  Alcotest.(check int) "both turns recorded as runs" 2 run_started_count

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
   ~raw_trace must be passed. This is the regression that motivated the fix:
   the parameter existed end-to-end but the dispatch never supplied it. *)
let test_keeper_dispatch_passes_raw_trace () =
  let root = repo_root () in
  let rel_path = "lib/keeper/keeper_agent_run.ml" in
  let source = read_file (Filename.concat root rel_path) in
  let marker = "Keeper_turn_driver.run_named" in
  let required_anchor = "~goal:user_message" in
  let required = "~raw_trace" in
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
       "%s: keeper dispatch must pass ~raw_trace into \
        Keeper_turn_driver.run_named"
       rel_path)
    true (search 0)

let () =
  Alcotest.run "keeper_raw_trace_sink"
    [
      ( "keeper raw-trace sink",
        [
          Alcotest.test_case "SSOT path layout" `Quick
            test_raw_trace_path_layout;
          Alcotest.test_case "sink path + session identity" `Quick
            test_sink_path_and_session_identity;
          Alcotest.test_case "per-turn re-creation resumes seq" `Quick
            test_sink_recreation_resumes_seq;
          Alcotest.test_case "dispatch passes ~raw_trace" `Quick
            test_keeper_dispatch_passes_raw_trace;
        ] );
    ]
