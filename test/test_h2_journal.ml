(** Real prepared async runs exercise the executor's journal integration.
    Dispatch never performs its own journal lookup or result reconstruction. *)
open Alcotest
module Journal = Masc.Keeper_tool_execution_journal
module Plan = Masc.Keeper_tool_plan
module Request = Masc.Keeper_tool_plan_request
module Executor = Masc.Keeper_tool_plan_executor
module Descriptor = Masc.Keeper_tool_descriptor
module Draft = Masc.Keeper_composition_draft
module Async = Masc.Keeper_msg_async
module Wake = Masc.Keeper_composition_completion_wake
module Outbox = Masc.Keeper_composition_completion_outbox
module Profile = Masc.Keeper_types_profile
module Workspace = Masc.Workspace
module Snapshot = Skill_catalog_snapshot

let keeper = "journal-fixture"
let composition_tool = Draft.run_tool_name
let require label = function Ok value -> value | Error _ -> fail label
let journal_value label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label (Journal.error_to_string error)
let check_json label expected actual =
  check bool label true (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort actual))
let node_id value = Plan.Node_id.make value |> require "node identity"
let node_name (node : Plan.node) = Plan.Node_id.to_string node.id
let node_result name rows =
  List.find (fun (row : Executor.node_result) -> Plan.Node_id.to_string row.node_id = name) rows
let settled = function Ok rows -> rows | Error failure -> failure.Executor.settled
let write path bytes =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel bytes)
let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let surface base_path =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let config = Skill_source_config.parse_text
      "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n"
      |> require "skill source configuration" in
  let scans = List.map (fun source_config ->
      let source = Skill_source_config.resolve ~base_path ~user_home:None source_config in
      let resolved_path = match source.Skill_source_config.resolution with
        | Resolved path -> path
        | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> fail "source resolution" in
      { Snapshot.source; observation = Snapshot.Source_ready { resolved_path; candidates = 0 }
      ; candidates = [] }) config.sources in
  let snapshot = Snapshot.configured ~config scans |> require "frozen empty skills" in
  let global_skill_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot snapshot in
  check int "empty frozen catalog is valid" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create ~tool_deny:[] ~sandbox_profile:Profile.Docker
    ~skill_names:None ~global_skill_catalog
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot) ~task_skills:[]

let with_workspace f =
  let base_path = Filename.temp_file "masc-journal-feature-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let agents_dir = Filename.concat base_path ".agents" in
    Unix.mkdir agents_dir 0o700;
    Unix.mkdir (Filename.concat agents_dir "skills") 0o700;
    let meta = Masc_test_deps.meta_of_json_fixture
        (`Assoc ["name", `String keeper; "activation_mode", `String "manual"])
        |> require "keeper metadata" in
    ignore (Masc.Keeper_meta_store.replace_snapshot config meta |> require "keeper persistence");
    ignore (Masc.Keeper_registry.register_offline ~base_path keeper meta);
    Eio.Switch.run (fun sw -> f env sw base_path))

let descriptor name = Descriptor.all_descriptors ()
  |> List.find (fun descriptor -> List.mem name (Descriptor.keeper_model_names descriptor))
let make_plan ?(changed_input = false) () =
  let producer = node_id "producer" and sibling = node_id "sibling" in
  let consumer_input = if changed_input then Plan.Json_template.literal (`Assoc ["query", `String "changed"])
    else Plan.Json_template.object_
      ["query", Plan.Json_template.output ~node_id:producer
        ~pointer:(Plan.Json_pointer.of_string "/profile" |> require "output pointer")]
      |> require "dependent input" in
  Plan.create ~descriptors:(List.map descriptor ["keeper_lane_status"; "masc_board_stats"; "masc_board_search"])
    ~branch_failure_policy:Plan.Continue_independent
    [Plan.node ~id:producer ~tool_name:"keeper_lane_status" ~input:(Plan.Json_template.literal (`Assoc [])) ();
     Plan.node ~id:sibling ~tool_name:"masc_board_stats" ~input:(Plan.Json_template.literal (`Assoc [])) ();
     Plan.node ~id:(node_id "consumer") ~tool_name:"masc_board_search" ~after:[producer; sibling]
       ~input:consumer_input ()] |> require "valid canonical plan"

type prepared = { draft : Draft.t; journal : Journal.t; source : Journal.source }
let prepare ?observation ?plan base_path =
  let capability_surface = surface base_path in
  let plan = Option.value plan ~default:(make_plan ()) in
  let draft = Draft.prepare ~base_path ~capability_surface ~keeper_name:keeper
      ~execution:Masc.Keeper_tool_composition_catalog.Async
      (Request.to_yojson plan |> require "canonical recipe") |> require "real draft preparation" in
  let composition_run_id = Plan.Composition_run_id.fresh () in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"original-parent"
      ~turn:42 ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Serial }
      ~completion:Continue_after_success in
  let run_reference = Draft.record_invocation ~base_path ~composition_run_id ~invocation draft
      |> require "real invocation artifact" in
  let source : Journal.source =
    { keeper_name = keeper; composition_run_id; draft_reference = Draft.reference draft; run_reference
    ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation
    ; source_turn = Agent_core.Tool_contract.Invocation.turn invocation
    ; source_task_id = Some "original-source-task"; producer=Journal.Prepared } in
  {draft; source; journal = Journal.prepare ?observation ~base_path source |> journal_value "prepare journal"}
let context (source : Journal.source) =
  ["composition_tool", `String composition_tool;
   "composition_run_id", `String (Plan.Composition_run_id.to_string source.composition_run_id);
   "draft_reference", Tool_output.normalized_artifact_ref_to_json source.draft_reference;
   "run_artifact", Tool_output.normalized_artifact_ref_to_json source.run_reference;
   "parent_tool_use_id", `String source.parent_tool_use_id;
   "source_turn", `Int source.source_turn]
  @ (match source.source_task_id with None -> [] | Some task -> ["source_task_id", `String task])

type submission =
  { request : Async.submit_outcome; worker : Journal.worker
  ; terminal : Async.worker_settlement Eio.Promise.t
  ; execution : (Executor.node_result list, Executor.failure) result option ref }
let submit ?request_context ?(caller = keeper) ?(target = keeper)
    ?(on_acceptance_probe = fun _ -> ())
    ?(before_execute = fun _ -> ()) ?plan ?observe ?launch_invocation_of ?admit_node base_path sw prepared dispatch =
  let bound = ref None and admission_error = ref None and execution = ref None in
  let terminal, resolver = Eio.Promise.create () in
  let request_context = Option.value request_context ~default:(context prepared.source) in
  let outcome = Async.submit_with_request_id ~request_context ~background_sw:sw ~base_path
      ~caller ~keeper_name:target
      ~on_accepted:(fun request_id ->
        on_acceptance_probe request_id;
        match Journal.bind_request prepared.journal ~request_id with
        | Error error -> admission_error := Some error; Error (Journal.error_to_string error)
        | Ok worker -> bound := Some worker;
          Outbox.prepare ~base_path ~keeper_name:target ~request_id ~composition_tool
          |> Result.map_error Outbox.error_to_string)
      ~on_worker_settled:(fun settlement ->
        Wake.on_worker_settled ~base_path ~composition_tool settlement;
        Eio.Promise.resolve resolver settlement)
      ~f:(fun ~request_id:_ _worker_sw ->
        let worker = match !bound with Some worker -> worker | None -> fail "unbound worker dispatched" in
        before_execute worker;
        let result = Executor.execute ~plan:(Option.value plan ~default:(Draft.plan prepared.draft))
            ~run_id:(Plan.Run_id.fresh ()) ~journal:worker ~dispatch ?launch_invocation_of ?admit_node ?observe_node_result:observe () in
        execution := Some result;
        let data = `Assoc ["composition_run_id", `String (Plan.Composition_run_id.to_string prepared.source.composition_run_id)] in
        match result with
        | Ok _ -> Profile.tool_result_ok_data ~tool_name:composition_tool data
        | Error failure -> Profile.tool_result_error_data ~tool_name:composition_tool
            ~class_:Tool_result.Policy_rejection ~effect_disposition:failure.effect_disposition data) () in
  match outcome with
  | Error error -> Error (error, !admission_error)
  | Ok request ->
    (match request.acceptance with Durably_accepted -> () | Reconciliation_required _ -> fail "ambiguous submission");
    let worker = match !bound with Some worker -> worker | None -> fail "accepted without worker" in
    Ok {request; worker; terminal; execution}
let accepted = function
  | Ok submission -> submission
  | Error (error, journal_error) -> failf "async acceptance: %s / %s"
      (Async.submit_error_to_json error |> Yojson.Safe.to_string)
      (Option.fold ~none:"no journal error" ~some:Journal.error_to_string journal_error)
let await base_path submission =
  (match Eio.Promise.await submission.terminal with
   | Async.Status_settlement { durability = Durable; _ } -> ()
   | Status_settlement {durability = Volatile_persistence_failure; _}
   | Settlement_projection_error _ -> fail "terminal is not canonical durable truth");
  Async.load_canonical_durable_terminal ~base_path ~caller:keeper submission.request.request_id
  |> require "canonical terminal request" |> Async.durable_terminal_entry
let executed submission = match !(submission.execution) with Some result -> result | None -> fail "executor did not return"

let retained_media =
  let open Llm_provider.Types in
  let image = Image {media_type = "image/png"; source_type = Base64;
    data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6uoAAAAASUVORK5CYII="} in
  [image;
   Document {media_type = "application/pdf"; source_type = Base64; data = Base64.encode_string "%PDF-1.4\n%%EOF\n"};
   Audio {media_type = "audio/wav"; source_type = Base64; data = Base64.encode_string "RIFF\004\000\000\000WAVE"};
   ToolResult {tool_use_id = "nested-result"; content = "outer fallback"; outcome = Tool_succeeded;
     json = Some (`Assoc ["sidecar", `List [`Int 7; `Bool true]]);
     content_blocks = Some [image; ToolResult {tool_use_id = "inner-result"; content = "inner fallback";
       outcome = Tool_succeeded; json = Some (`Assoc ["inner", `String "exact-json"]);
       content_blocks = Some [Text "nested text"]}]}]

let success base_path (node : Plan.node) profile =
  let data = match node_name node with
    | "producer" -> `Assoc ["profile", `String profile; "lane", `Null; "endpoint", `Null;
        "probe", `Null; "last_dispatch", `Null; "operator_action", `Null]
    | "sibling" -> `Assoc ["post_count", `Int 0; "comment_count", `Int 0;
        "expired_pending", `Int 0; "last_sweep", `Float 0.; "backend", `String "fixture"]
    | "consumer" -> `String "retrieved-original-profile"
    | name -> failf "unexpected node %s" name in
  let artifact = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
      ~bytes:("retained:" ^ node_name node) ~mime:"text/plain" in
  let content_blocks = if node_name node = "producer" then Some retained_media else None in
  Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ()) ~data ?content_blocks
    ~metadata:(`Assoc ["producer", `String "original-dispatch"]) ()
  |> Tool_result.with_retained_artifacts [artifact]
let failing phase (node : Plan.node) =
  Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Dependency_unavailable
    ~start_time:(Tool_timing.start ()) ~effect_disposition:phase "producer failure"
  |> Executor.dispatch_result ~failure_effect_disposition:phase
let initial_dispatch base_path phase ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
  if node_name node = "consumer" then failing phase node
  else Executor.dispatch_result (success base_path node "original-profile")
let resume_dispatch base_path calls ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input () =
  calls := node_name node :: !calls;
  if node_name node = "consumer" then check_json "saved producer drives dependent input"
      (`Assoc ["query", `String "original-profile"]) input;
  Executor.dispatch_result (success base_path node "changed-profile")
let durable_result (row : Executor.node_result) =
  let content_blocks = match row.result with
    | Tool_result.Completed output | Deferred output -> output.content_blocks
    | Failed _ -> None in
  `Assoc ["execution_id", Ids.Execution_id.to_yojson row.execution_id;
    "tool_use_id", `String row.tool_use_id; "result", Tool_result.to_json row.result;
    "retained_artifacts", `List (List.map Tool_output.normalized_artifact_ref_to_json (Tool_result.retained_artifacts row.result));
    "content_blocks", (match content_blocks with
      | None -> `Null
      | Some content ->
        let message : Agent_core.Types.message =
          {role = Tool; content; name = None; tool_call_id = None; metadata = []} in
        Agent_core.Checkpoint.message_to_json message);
    "result_bytes", `Int row.result_bytes;
    "truncated_to", (match row.truncated_to with None -> `Null | Some limit -> `Int limit)]
let check_retained expected rows =
  List.iter (fun name ->
    let row = node_result name rows in
    check bool (name ^ " reused its occurrence") true (row.execution_origin = Executor.Retained_completion);
    (match row.result with
     | Tool_result.Completed output -> check bool (name ^ " exact typed media and nested JSON sidecars") true
         (output.content_blocks = if name = "producer" then Some retained_media else None)
     | Deferred _ | Failed _ -> fail "retained result is not completed");
    check_json (name ^ " complete payload persisted") (Yojson.Safe.Util.member name expected) (durable_result row))
    ["producer"; "sibling"]
let completion base_path request_id =
  let queue = Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:keeper |> require "durable wake queue" in
  let completions = Keeper_event_queue.to_list queue |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Composition_completed value when value.cc_request_id = request_id -> Some value
      | _ -> None) in
  match completions with [value] -> value | _ -> fail "missing or duplicate completion wake"
let check_completion base_path prepared submission =
  let projected = Masc.Keeper_composition_completion_result.read ~base_path ~keeper_name:keeper
      (completion base_path submission.request.request_id)
      |> Masc.Keeper_composition_completion_result.to_json in
  check_json "wake resolves canonical result" (`Bool true) (Yojson.Safe.Util.member "result_available" projected);
  let source = Yojson.Safe.Util.member "source" projected in
  List.iter (fun (key, expected) -> if key <> "composition_tool" then
    check_json ("wake retains " ^ key) expected (Yojson.Safe.Util.member key source)) (context prepared.source)
let reconstruct base_path run_id =
  let composition_run_id = Plan.Composition_run_id.of_string run_id |> require "run UUID" in
  let journal = Journal.load ~base_path ~keeper_name:keeper ~composition_run_id |> journal_value "restart load" in
  let source = Journal.source journal in
  let draft = Draft.load ~base_path ~capability_surface:(surface base_path) ~keeper_name:keeper
      ~sha256:source.draft_reference.sha256 |> require "restart draft load" in
  {draft; source; journal}

let child_resume base_path run_id =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let prepared = reconstruct base_path run_id in
  let calls = ref [] and observed = ref [] in
  let submission = submit ~observe:(fun row -> observed := Plan.Node_id.to_string row.Executor.node_id :: !observed; Ok ())
      base_path sw prepared (resume_dispatch base_path calls) |> accepted in
  ignore (await base_path submission);
  let rows = executed submission |> require "resumed executor completes" in
  check_retained (Yojson.Safe.from_file (Filename.concat base_path "expected.json")) rows;
  check (list string) "only unfinished consumer dispatches" ["consumer"] !calls;
  check (list string) "retained completions do not repeat observations" ["consumer"] !observed;
  check_completion base_path prepared submission;
  write (Filename.concat base_path "child-request") submission.request.request_id
let run_child env mode base_path prepared =
  Eio.Process.run (Eio.Stdenv.process_mgr env)
    [Sys.executable_name; mode; base_path; Plan.Composition_run_id.to_string prepared.source.composition_run_id]
let test_restart_reuses_completed () = with_workspace (fun env sw base_path ->
  let prepared = prepare base_path in
  let first = submit base_path sw prepared (initial_dispatch base_path Tool_result.Proven_pre_effect) |> accepted in
  (match (await base_path first).status with Done {ok = false; _} -> () | _ -> fail "first request must fail pre-effect");
  let rows = settled (executed first) in
  check int "independent completed branch retained" 3 (List.length rows);
  write (Filename.concat base_path "expected.json")
    (Yojson.Safe.to_string (`Assoc (List.map (fun name -> name, durable_result (node_result name rows)) ["producer"; "sibling"])));
  check_completion base_path prepared first;
  run_child env "--resume-child" base_path prepared;
  let child_request = read (Filename.concat base_path "child-request") in
  check bool "new owned transport retains original run" true (child_request <> first.request.request_id);
  ignore (Async.load_canonical_durable_terminal ~base_path ~caller:keeper child_request |> require "child terminal proof"))

let expect_admission_error expected = function
  | Error (Async.Acceptance_persistence_failed _, Some error) when expected error -> ()
  | Error (error, journal_error) -> failf "wrong admission rejection %s / %s"
      (Async.submit_error_to_json error |> Yojson.Safe.to_string)
      (Option.fold ~none:"none" ~some:Journal.error_to_string journal_error)
  | Ok _ -> fail "invalid resume accepted"
let no_dispatch calls ?launch_replay:_ ~tool_use_id:_ ~node:_ ~descriptor:_ ~schedule:_ ~input:_ () =
  incr calls; fail "unsafe dispatch"
let test_source_and_plan_identity () = with_workspace (fun _env sw base_path ->
  let prepared = prepare base_path in
  let calls = ref 0 in
  submit ~caller:"other-owner" base_path sw prepared (no_dispatch calls)
  |> expect_admission_error (function Journal.Queued_request_rejected _ -> true | _ -> false);
  submit ~request_context:(context {prepared.source with source_task_id = Some "different-task"})
      base_path sw prepared (no_dispatch calls)
  |> expect_admission_error (function Journal.Queued_request_rejected _ -> true | _ -> false);
  let other = prepare ~plan:(make_plan ~changed_input:true ()) base_path in
  (match Journal.prepare ~base_path {prepared.source with draft_reference = other.source.draft_reference;
      run_reference = other.source.run_reference} with
   | Error (Journal.Source_conflict | Draft_unavailable _) -> ()
   | Error error -> fail (Journal.error_to_string error) | Ok _ -> fail "different source rebound");
  let changed = submit ~plan:(make_plan ~changed_input:true ()) base_path sw prepared (no_dispatch calls) |> accepted in
  ignore (await base_path changed);
  (match executed changed with
   | Error {cause = Executor.Run_journal_rejected Journal.Plan_identity_conflict; settled = []; _} -> ()
   | _ -> fail "changed plan did not refuse before dispatch");
  ignore (Journal.begin_attempt changed.worker ~node_id:(node_id "consumer") ~tool_name:"masc_board_search"
      ~input:(`Assoc ["query", `String "original-profile"]) ~execution_id:(Ids.Execution_id.generate ())
      ~tool_use_id:"original-consumer" ~readonly:true () |> journal_value "record input identity");
  (match Journal.lookup changed.worker ~node_id:(node_id "consumer") ~tool_name:"masc_board_search"
      ~input:(`Assoc ["query", `String "different"]) with
   | Error (Journal.Node_identity_conflict _) -> () | _ -> fail "changed node input accepted");
  check int "identity failures perform no dispatch" 0 !calls)

let rec regular_files directory =
  Sys.readdir directory |> Array.to_list |> List.concat_map (fun name ->
    let path = Filename.concat directory name in match (Unix.lstat path).st_kind with
    | Unix.S_DIR -> regular_files path | Unix.S_REG -> [path] | _ -> [])
let journal_path base_path composition_run_id =
  let directory = Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests") "execution_journals" in
  let filename = Plan.Composition_run_id.to_string composition_run_id ^ ".jsonl" in
  match List.filter (fun path -> Filename.basename path = filename) (regular_files directory) with
  | [path] -> path | _ -> fail "one actual run journal file"

let test_source_observation_is_frozen_at_creation () = with_workspace (fun _env _sw base_path ->
  let first : Journal.source_observation = {trace_id=Some (Keeper_id.Trace_id.of_string "original-trace" |> require "original trace");
    session_id=Some "original-session";keeper_turn_id=Some 17;
    answer_source_ids=["original-answer-input"]} in
  let later : Journal.source_observation = {trace_id=Some (Keeper_id.Trace_id.of_string "later-trace" |> require "later trace");
    session_id=Some "later-session";keeper_turn_id=Some 29;
    answer_source_ids=["later-answer-input"]} in
  let prepared = prepare ~observation:first base_path in
  let path = journal_path base_path prepared.source.composition_run_id in
  let original_bytes = read path in
  let replay = Journal.prepare ~observation:later ~base_path prepared.source
      |> journal_value "reopen original producer source" in
  let fresh = Journal.load ~base_path ~keeper_name:keeper
      ~composition_run_id:prepared.source.composition_run_id |> journal_value "fresh source load" in
  List.iter (fun journal ->
    check bool "every reader retains the first original observation" true
      (Journal.source_observation journal=Some first);
    check bool "observations do not replace execution source authority" true
      (Journal.same_source prepared.source (Journal.source journal))) [prepared.journal;replay;fresh];
  check string "replay does not rewrite the original source prefix" original_bytes (read path);
  let unknown = prepare base_path in
  let path = journal_path base_path unknown.source.composition_run_id in
  let unknown_bytes = read path in
  let reopened = Journal.prepare ~observation:later ~base_path unknown.source
      |> journal_value "reopen source without an observation" in
  check bool "an uncaptured original cannot borrow a later answer" true
    (Journal.source_observation reopened=None);
  check string "unknown observation stays unknown without mutating the source" unknown_bytes (read path))
let test_unavailable_evidence () =
  List.iter (fun damage -> with_workspace (fun _env sw base_path ->
    let prepared = prepare base_path in
    let entered, entered_resolver = Eio.Promise.create () and release, release_resolver = Eio.Promise.create () in
    let calls = ref 0 in
    let submission = submit ~before_execute:(fun _ -> Eio.Promise.resolve entered_resolver (); Eio.Promise.await release)
        base_path sw prepared (no_dispatch calls) |> accepted in
    Eio.Promise.await entered;
    let path = journal_path base_path prepared.source.composition_run_id in
    let original = read path in
    let restore = match damage with
      | `Corrupt -> write path "{invalid-json\n"; (fun () -> write path original)
      | `Unreadable -> Unix.unlink path; Unix.mkdir path 0o700; (fun () -> Unix.rmdir path; write path original)
      | `Missing -> Unix.unlink path; (fun () -> write path original) in
    Fun.protect ~finally:restore (fun () ->
      Eio.Promise.resolve release_resolver ();
      ignore (await base_path submission);
      (match executed submission with
       | Error {cause = Executor.Run_journal_rejected _; settled = []; _} -> ()
       | _ -> fail "unavailable journal did not stop before dispatch");
      (match Journal.load ~base_path ~keeper_name:keeper ~composition_run_id:prepared.source.composition_run_id with
       | Error _ -> () | Ok _ -> fail "damaged journal loaded");
      check int "no dispatch on unavailable evidence" 0 !calls))) [`Corrupt; `Unreadable; `Missing];
  with_workspace (fun _env sw base_path ->
    let prepared = prepare base_path in
    let first = submit base_path sw prepared (initial_dispatch base_path Tool_result.Proven_pre_effect) |> accepted in
    ignore (await base_path first);
    let reference = prepared.source.run_reference in
    let path = Filename.concat (Filename.concat (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path))
        (String.sub reference.sha256 0 2)) reference.sha256 in
    let original = read path in
    Fun.protect ~finally:(fun () -> write path original) (fun () ->
      write path "corrupt original run artifact";
      let calls = ref 0 in
      submit base_path sw prepared (no_dispatch calls)
      |> expect_admission_error (function Journal.Draft_unavailable _ -> true | _ -> false);
      check int "corrupt run artifact refuses before worker" 0 !calls))

let child_refuse_active base_path run_id =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let prepared = reconstruct base_path run_id and calls = ref 0 in
  submit base_path sw prepared (no_dispatch calls)
  |> expect_admission_error (function Journal.Prior_owner_not_terminal _ -> true | _ -> false);
  check int "another process cannot infer active ownership lost" 0 !calls
let test_owned_transport_and_race () = with_workspace (fun env sw base_path ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let prepared = prepare base_path in
  let entered, enter = Eio.Promise.create () and release, release_owner = Eio.Promise.create () in
  let first = submit ~before_execute:(fun _ -> Eio.Promise.resolve enter (); Eio.Promise.await release)
      base_path sw prepared (initial_dispatch base_path Tool_result.Proven_pre_effect) |> accepted in
  Eio.Promise.await entered;
  let discovery = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "pre-dispatch discovery" in
  check int "run is discoverable before its first node effect" 1 discovery.inspected;
  check int "active owner does not grant another worker" 0 (List.length discovery.ready);
  check int "active owner remains pending" 1 discovery.waiting;
  check int "active original authority is readable" 0 (List.length discovery.failures);
  let refused_calls = ref 0 in
  submit base_path sw prepared (no_dispatch refused_calls)
  |> expect_admission_error (function Journal.Prior_owner_not_terminal _ -> true | _ -> false);
  run_child env "--refuse-active-child" base_path prepared;
  Eio.Promise.resolve release_owner ();
  ignore (await base_path first);
  let attempt = Journal.begin_attempt first.worker ~node_id:(node_id "consumer") ~tool_name:"masc_board_search"
      ~input:(`Assoc ["query", `String "original-profile"]) ~execution_id:(Ids.Execution_id.generate ())
      ~tool_use_id:"pre-resume-occurrence" ~readonly:true () |> journal_value "original attempt" in
  let resume_release, resume_resolver = Eio.Promise.create () in
  let calls = ref [] in
  let contender () = submit ~before_execute:(fun _ -> Eio.Promise.await resume_release)
      base_path sw prepared (resume_dispatch base_path calls) in
  let left = ref None and right = ref None in
  Eio.Fiber.both (fun () -> left := Some (contender ())) (fun () -> right := Some (contender ()));
  let outcomes = List.map (function Some value -> value | None -> fail "missing contender") [!left; !right] in
  let winners = List.filter_map (function Ok value -> Some value | Error _ -> None) outcomes in
  check int "one resume owns original run" 1 (List.length winners);
  List.iter (function
    | Ok _ -> ()
    | outcome -> expect_admission_error (function
        Journal.Prior_owner_not_terminal _ | Ownership_changed -> true | _ -> false) outcome) outcomes;
  (match Journal.lookup first.worker ~node_id:(node_id "producer") ~tool_name:"keeper_lane_status" ~input:(`Assoc []) with
   | Error Journal.Ownership_changed -> () | _ -> fail "stale worker reused results");
  let consumer = List.find (fun node -> node_name node = "consumer") (Plan.nodes (Draft.plan prepared.draft)) in
  (match Journal.settle_attempt attempt ~result:(success base_path consumer "stale")
      ~result_bytes:0 ~truncated_to:None with
   | Error Journal.Ownership_changed -> () | _ -> fail "stale attempt settled after ownership changed");
  Eio.Promise.resolve resume_resolver ();
  let winner = List.hd winners in
  ignore (await base_path winner);
  ignore (executed winner |> require "owned resume completes");
  check (list string) "only unfinished node dispatched once" ["consumer"] !calls;
  check_completion base_path prepared winner)

let test_unproven_outcomes_refuse_replay () =
  List.iter (fun outcome -> with_workspace (fun _env sw base_path ->
    let prepared = prepare base_path in
    let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
      if node_name node <> "consumer" then Executor.dispatch_result (success base_path node "original-profile")
      else match outcome with
        | `Failure phase -> failing phase node
        | `Deferred phase -> Executor.dispatch_result ?failure_effect_disposition:phase
            (Tool_result.make_deferred ~tool_name:node.tool_name
            ~start_time:(Tool_timing.start ()) ~data:(`String "accepted but unfinished") ()) in
    let first = submit base_path sw prepared dispatch |> accepted in
    ignore (await base_path first);
    let calls = ref 0 in
    let second = submit base_path sw prepared (no_dispatch calls) |> accepted in
    ignore (await base_path second);
    (match executed second with
     | Error {cause = Executor.Tool_did_not_complete row; _} ->
       check bool "unproven leaf dispatch refused" true (row.execution_origin = Executor.Dispatch_refused)
     | _ -> fail "unknown, post-effect or deferred outcome replayed");
    check int "unsafe result does not authorize dispatch" 0 !calls;
    let expected = `Assoc (List.map (fun name -> name, durable_result (node_result name (settled (executed first))))
        ["producer"; "sibling"]) in
    check_retained expected (settled (executed second));
    check_completion base_path prepared second))
    [`Failure Tool_result.Effect_outcome_unknown; `Failure Proven_post_effect;
     `Deferred None; `Deferred (Some Tool_result.Proven_pre_effect)]

let test_foreign_job_wait_receipt_is_rejected () = with_workspace (fun _env sw base_path ->
  let prepared = prepare base_path in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    if node_name node <> "consumer" then Executor.dispatch_result (success base_path node "original-profile")
    else Executor.dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
      ~deferred_kind:(Masc.Keeper_tool_execution.Owned_job_result_wait
        (Masc.Keeper_owned_job_store.Job_id.fresh ()))
      (Tool_result.make_deferred ~tool_name:node.tool_name
        ~start_time:(Tool_timing.start ()) ~data:(`String "not an owned result leaf") ()) in
  let first = submit base_path sw prepared dispatch |> accepted in
  ignore (await base_path first);
  (match executed first with
   | Error {cause=Executor.Node_observation_failed _;_} -> ()
   | _ -> fail "foreign producer receipt was accepted by the run journal");
  (match Journal.lookup first.worker ~node_id:(node_id "consumer") ~tool_name:"masc_board_search"
      ~input:(`Assoc ["query", `String "original-profile"]) with
   | Error (Journal.Replay_not_proven _) -> ()
   | Error _ | Ok _ -> fail "foreign receipt authorized job result rechecking"))
let test_cancelled_readonly_attempt () = with_workspace (fun _env sw base_path ->
  let prepared = prepare base_path in
  let entered, enter = Eio.Promise.create () and never, _ = Eio.Promise.create () in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    if node_name node = "consumer" then (Eio.Promise.resolve enter (); Eio.Promise.await never);
    Executor.dispatch_result (success base_path node "original-profile") in
  let first = submit base_path sw prepared dispatch |> accepted in
  Eio.Promise.await entered;
  (match Async.cancel ~base_path ~caller:keeper first.request.request_id with
   | Cancellation_requested Durably_committed -> () | _ -> fail "owned cancellation not durable");
  (match (await base_path first).status with Cancelled _ -> () | _ -> fail "cancelled worker has no canonical terminal");
  check_completion base_path prepared first;
  let calls = ref [] in
  let second = submit base_path sw prepared (resume_dispatch base_path calls) |> accepted in
  ignore (await base_path second);
  let rows = executed second |> require "statically readonly interrupted attempt resumes" in
  List.iter (fun name -> check bool "cancel did not replay settled work" true
      ((node_result name rows).execution_origin = Executor.Retained_completion)) ["producer"; "sibling"];
  check (list string) "only declared readonly unfinished work retries" ["consumer"] !calls;
  check_completion base_path prepared second)

let decode_reference json = match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Not_normalized_artifact_ref -> fail "missing canonical artifact reference"
  | Invalid_normalized_artifact_ref {detail} -> fail detail
let document base_path (reference : Tool_output.artifact_ref) =
  let bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256
      |> require "fetch actual producer artifact" in
  match bytes with
  | None -> fail "producer artifact absent"
  | Some bytes -> match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string bytes) with
    | Decoded_artifact_manifest {structured_content; _} -> structured_content
    | Invalid_artifact_manifest {detail} -> fail detail
    | Not_artifact_manifest -> fail "producer artifact not a canonical manifest"
let public_content base_path content = match Tool_output.decode_from_agent_core content with
  | Tool_output.Decoded reference -> document base_path reference
  | Invalid_marker {detail} -> fail detail
  | Not_marker -> Yojson.Safe.from_string content |> Yojson.Safe.Util.member "structured_content"
let rec await_public_terminal base_path request_id =
  match Async.load_canonical_durable_terminal ~base_path ~caller:keeper request_id with
  | Ok proof -> Async.durable_terminal_entry proof
  | Error (Canonical_terminal_absent | Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) ->
    (* Schedule the owned worker, without inventing a deadline or retry count. *)
    Eio.Fiber.yield (); await_public_terminal base_path request_id
  | Error error -> fail (Async.canonical_terminal_error_to_string error)
let rec await_public_completion base_path request_id =
  let queue = Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:keeper |> require "public completion queue" in
  match List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Composition_completed value when value.cc_request_id = request_id -> Some value
      | _ -> None) (Keeper_event_queue.to_list queue) with
  | Some value -> value
  | None -> Eio.Fiber.yield (); await_public_completion base_path request_id

let test_resumed_ask_uses_only_original_source_evidence () =
  let original_trace = Keeper_id.Trace_id.of_string "original-ask-source" |> require "source trace" in
  let observation trace_id keeper_turn_id : Journal.source_observation =
    {trace_id;keeper_turn_id;session_id=Some "original-session";answer_source_ids=[]} in
  List.iter (fun (original_observation,expected) -> with_workspace (fun env sw base_path ->
    let module Tools = Masc.Keeper_tool_composition_surface in
    let module Call_log = Masc.Keeper_tool_call_log in
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
    let config = Workspace.default_config base_path in
    let meta = Masc_test_deps.meta_of_json_fixture
        (`Assoc ["name",`String keeper;"activation_mode",`String "manual";
          "trace_id",`String "current-unrelated-trace"]) |> require "current metadata" in
    let plan = Plan.create ~descriptors:[descriptor "masc_ask"]
        [Plan.node ~id:(node_id "original-question") ~tool_name:"masc_ask"
          ~input:(Plan.Json_template.literal (`Assoc ["task_id",`String "decision-task";
            "questions",`List [`Assoc ["header",`String "Next";"prompt",`String "Which original action?";
              "mode",`String "single";"free_text",`Bool true]]])) ()]
        |> require "original Ask plan" in
    (* The original invocation and journal exist before the later run. No
       external effect or terminal result is fabricated for the Ask node. *)
    let prepared = prepare ?observation:original_observation ~plan base_path in
    let cell = Call_log.create_turn_ctx_cell () in
    Call_log.set_turn_context ~cell ~agent_name:keeper ~task_id:"later-task"
      ~trace_id:"current-unrelated-trace" ~turn:777 ~keeper_turn_id:900 ();
    let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
      {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
    let tools = Tools.make_tools ~capability_surface:(surface base_path) ~config ~meta ~publication_recovery
        ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"resumed Ask source fixture")
        ~turn_ctx_cell:cell ~clock:(Eio.Stdenv.clock env) () in
    let tool = List.find_map (fun (tool,_,_) ->
        if tool.Agent_core.Tool.schema.name=Draft.run_tool_name then Some tool else None) tools
        |> Option.get in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"later-resume" ~turn:777
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
        ~completion:Continue_after_success in
    let output = Agent_core.Tool.execute ~invocation tool
        (`Assoc ["sha256",`String (Draft.reference prepared.draft).sha256;
          "resume_run_id",`String (Plan.Composition_run_id.to_string prepared.source.composition_run_id)])
        |> function Ok output -> output | Error error -> fail error.Agent_core.Types.message in
    let accepted = public_content base_path output.content in
    let request_id = Yojson.Safe.Util.(accepted |> member "request_id" |> to_string) in
    let entry = await_public_terminal base_path request_id in
    (match entry.Async.status with
     | Done {ok=true;_} -> ()
     | _ -> fail "resumed Ask should run even with unobserved source");
    ignore (await_public_completion base_path request_id);
    match Masc.Keeper_ask_store.open_asks ~base_path ~keeper_name:keeper with
    | [ask] ->
        check (option string) "resumed Ask never borrows current trace or turn" expected
          (Option.map Ids.Turn_ref.to_string ask.source_turn_ref);
        check (option string) "explicit related Task stays independent of source ownership"
          (Some "decision-task") ask.task_id
    | _ -> fail "one real resumed Ask should be recorded"))
    [Some (observation (Some original_trace) (Some 17)),Some "original-ask-source#17";
     Some (observation (Some original_trace) None),None;
     Some (observation None (Some 17)),None;
     None,None]

let test_public_run_resume_keeps_original_task () = with_workspace (fun env sw base_path ->
  let module Tools = Masc.Keeper_tool_composition_surface in
  let module Call_log = Masc.Keeper_tool_call_log in
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  Call_log.init ~base_path ();
  let config = Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String keeper; "activation_mode", `String "manual";
      "trace_id", `String "original-trace"])
      |> require "public keeper metadata" in
  let current_meta = ref meta in
  let ctx_snapshot = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"public continuation fixture" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider; keeper_name = keeper} in
  let cell = Call_log.create_turn_ctx_cell () in
  let original_answer = Masc.Keeper_ask.answer_source_id ~ask_id:"original-question" ~answered_at:100.
      |> Option.get in
  let later_answer = Masc.Keeper_ask.answer_source_id ~ask_id:"later-question" ~answered_at:200.
      |> Option.get in
  Call_log.set_turn_context ~cell ~agent_name:keeper ~turn:42 ~keeper_turn_id:1 ~task_id:"task-A"
    ~trace_id:"original-trace" ~session_id:"original-session" ~answer_source_ids:[original_answer] ();
  let tools () = Tools.make_tools ~capability_surface:(surface base_path) ~config ~meta:!current_meta ~publication_recovery
      ~ctx_snapshot ~turn_ctx_cell:cell ~clock:(Eio.Stdenv.clock env) () in
  let invoke ~turn ~id name input =
    let tool = List.find_map (fun (tool, _, _) ->
        if tool.Agent_core.Tool.schema.name = name then Some tool else None) (tools ())
        |> function Some tool -> tool | None -> fail ("public control absent: " ^ name) in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn
        ~schedule:{planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Serial}
        ~completion:Continue_after_success in
    let output = Agent_core.Tool.execute ~invocation tool input
      |> function Ok output -> output | Error error -> fail error.Agent_core.Types.message in
    public_content base_path output.content in
  let lane = Plan.node ~id:(node_id "lane") ~tool_name:"keeper_lane_status"
      ~input:(Plan.Json_template.literal (`Assoc [])) () in
  let plan = Plan.create ~descriptors:[descriptor "keeper_lane_status"]
      ~exports:[Plan.export ~name:"profile" ~node_id:lane.id
        ~pointer:(Plan.Json_pointer.of_string "/profile" |> require "public export pointer")]
      [lane] |> require "public lane plan" in
  let request = Request.to_yojson plan |> require "public canonical recipe" in
  let preview = invoke ~turn:42 ~id:"prepare-public" Draft.prepare_tool_name
      (match request with `Assoc fields -> `Assoc (("execution", `String "async") :: fields) | _ -> fail "recipe object") in
  let open Yojson.Safe.Util in
  let draft_reference = preview |> member "draft" |> decode_reference in
  let first = invoke ~turn:42 ~id:"public-original-run" Draft.run_tool_name
      (`Assoc ["sha256", `String draft_reference.sha256]) in
  let original_run = first |> member "composition_run_id" |> to_string in
  let original_artifact = first |> member "run_artifact" |> decode_reference in
  let first_request = first |> member "request_id" |> to_string in
  let first_entry = await_public_terminal base_path first_request in
  ignore (await_public_completion base_path first_request);
  let first_data = match first_entry.status with Done {ok = true; data = Some data; _} -> data | _ -> fail "public initial run failed" in
  let first_execution = first_data |> member "execution_artifact" |> decode_reference |> document base_path in
  let original_leaf = match first_execution |> member "nodes" |> to_list with [row] -> row | _ -> fail "one public leaf" in
  current_meta := {meta with runtime={meta.runtime with
    trace_id=Keeper_id.Trace_id.of_string "later-trace" |> require "later current trace"}};
  Call_log.set_turn_context ~cell ~agent_name:keeper ~turn:43 ~keeper_turn_id:2 ~task_id:"task-B"
    ~trace_id:"later-trace" ~session_id:"later-session" ~answer_source_ids:[later_answer] ();
  let resumed = invoke ~turn:43 ~id:"public-resume-in-task-B" Draft.run_tool_name
      (`Assoc ["sha256", `String draft_reference.sha256; "resume_run_id", `String original_run]) in
  check string "public resume keeps original run UUID" original_run (resumed |> member "composition_run_id" |> to_string);
  check_json "public resume keeps original invocation artifact"
    (Tool_output.normalized_artifact_ref_to_json original_artifact) (resumed |> member "run_artifact");
  let resumed_request = resumed |> member "request_id" |> to_string in
  check bool "resume uses a new owned transport" true (resumed_request <> first_request);
  let resumed_entry = await_public_terminal base_path resumed_request in
  let completion = await_public_completion base_path resumed_request in
  let expected_source = match first_entry.request_context with Some fields -> fields | None -> fail "first context absent" in
  let resumed_source = match resumed_entry.request_context with Some fields -> fields | None -> fail "resume context absent" in
  check_json "original source survives current task B" (`Assoc expected_source) (`Assoc resumed_source);
  check_json "source task remains A" (`String "task-A") (List.assoc "source_task_id" resumed_source);
  let resumed_data = match resumed_entry.status with Done {ok = true; data = Some data; _} -> data | _ -> fail "public resume failed" in
  let resumed_execution = resumed_data |> member "execution_artifact" |> decode_reference |> document base_path in
  let retained_leaf = match resumed_execution |> member "nodes" |> to_list with [row] -> row | _ -> fail "one retained public leaf" in
  List.iter (fun field -> check_json ("public retained " ^ field) (member field original_leaf) (member field retained_leaf))
    ["execution_id"; "tool_use_id"; "result"];
  check_json "public leaf reused original completion" (`String "retained_completion") (member "execution_origin" retained_leaf);
  Call_log.flush_now ();
  let rows = Call_log.read_recent ~keeper_name:keeper () |> require "canonical public observations" in
  let leaves = List.filter (fun row -> member "tool" row = `String "keeper_lane_status") rows in
  check int "public resume does not dispatch or observe a fresh leaf" 1 (List.length leaves);
  List.iter (fun row ->
    check bool "the real original leaf carries a physical invocation identity" true
      (match member "physical_execution_id" row with `String id -> id<>"" | _ -> false);
    check_json "the original leaf keeps the original answer input" (`List [`String original_answer])
      (member "answer_source_ids" row);
    check_json "the original leaf keeps its trace" (`String "original-trace") (member "trace_id" row);
    check_json "the original leaf keeps its physical Keeper turn" (`Int 1) (member "keeper_turn_id" row)) leaves;
  let inline_preview = invoke ~turn:43 ~id:"prepare-inline-observation" Draft.prepare_tool_name
      (match request with `Assoc fields -> `Assoc (("execution", `String "inline")::fields)
       | _ -> fail "inline recipe object") in
  let inline_reference = inline_preview |> member "draft" |> decode_reference in
  let inline = invoke ~turn:43 ~id:"inline-observation" Draft.run_tool_name
      (`Assoc ["sha256",`String inline_reference.sha256]) in
  let inline_run = member "composition_run_id" inline in
  Call_log.flush_now ();
  let inline_rows = Call_log.read_recent ~keeper_name:keeper () |> require "inline result observations"
      |> List.filter (fun row -> member "tool" row=`String "keeper_lane_status"
          && member "composition_run_id" row=inline_run) in
  check int "inline recipe retains one physical leaf observation" 1 (List.length inline_rows);
  List.iter (fun row -> check_json "inline leaf uses its own current answer input"
      (`List [`String later_answer]) (member "answer_source_ids" row)) inline_rows;
  let projected = Masc.Keeper_composition_completion_result.read ~base_path ~keeper_name:keeper completion
      |> Masc.Keeper_composition_completion_result.to_json in
  check_json "public wake carries task A" (`String "task-A") (projected |> member "source" |> member "source_task_id"))

let first_loss_plan ~readonly =
  let sibling = node_id "completed-sibling" in
  let tool_name, input = if readonly then "keeper_lane_status", `Assoc []
    else "keeper_job_start", `Assoc ["argv", `List [`String "true"]] in
  let descriptors = if readonly then [descriptor tool_name]
    else [descriptor "keeper_lane_status"; descriptor tool_name] in
  Plan.create ~descriptors
    [Plan.node ~id:sibling ~tool_name:"keeper_lane_status"
       ~input:(Plan.Json_template.literal (`Assoc [])) ();
     Plan.node ~id:(node_id "interrupted") ~tool_name ~after:[sibling]
       ~input:(Plan.Json_template.literal input) ()]
  |> require "first-loss canonical plan"

let first_loss_success_result (node : Plan.node) =
  Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
    ~data:(`Assoc ["profile", `String "original-profile"; "lane", `Null; "endpoint", `Null;
      "probe", `Null; "last_dispatch", `Null; "operator_action", `Null]) ()

let first_loss_success node = first_loss_success_result node
  |> Executor.dispatch_result

let child_first_loss base_path run_id mode =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let prepared = reconstruct base_path run_id in
  let snapshot () = write (Filename.concat base_path "first-loss-journal")
      (read (journal_path base_path prepared.source.composition_run_id)) in
  let record_effect () =
    let channel = open_out_gen [Open_wronly; Open_creat; Open_append; Open_binary] 0o600
        (Filename.concat base_path "first-loss-effect") in
    Fun.protect ~finally:(fun () -> close_out channel)
      (fun () -> output_string channel "one dispatch entry\n") in
  let retain_unproven_producer worker =
    if mode <> "readonly" then (
      (* Author unproven producer evidence through the canonical journal API.
         The modern Executor correctly refuses an identity-less owned launch
         before Attempting; it must not be claimed as this evidence's author.
         Real async acceptance still owns this worker, source and marker. *)
      let plan = Draft.plan prepared.draft in
      Journal.validate_plan worker ~plan |> journal_value "unproven producer plan";
      let run_id = Plan.Run_id.fresh () in
      let begin_node name ~readonly =
        let node = List.find (fun node -> node_name node = name) (Plan.nodes plan) in
        let input = Plan.resolve_input plan ~run_id ~node_id:node.id ~lookup:(fun _ -> None)
            |> require "original literal producer input" in
        let attempt = Journal.begin_attempt worker ~node_id:node.id ~tool_name:node.tool_name
            ~input ~execution_id:(Ids.Execution_id.generate ())
            ~tool_use_id:("original-first-loss-" ^ name) ~readonly ()
            |> journal_value "original producer attempt" in
        node, input, attempt in
      let settle ?failure_effect_disposition attempt result =
        Journal.settle_attempt ?failure_effect_disposition attempt ~result
          ~result_bytes:(String.length (Tool_result.message result)) ~truncated_to:None
        |> journal_value "original producer settlement" in
      let sibling, _, sibling_attempt = begin_node "completed-sibling" ~readonly:true in
      settle sibling_attempt (first_loss_success_result sibling);
      let node, input, attempt = begin_node "interrupted" ~readonly:false in
      record_effect ();
      (match mode with
       | "attempting" -> ()
       | "unknown" | "post_effect" ->
         let phase = if mode = "unknown" then Tool_result.Effect_outcome_unknown
           else Tool_result.Proven_post_effect in
         settle ~failure_effect_disposition:phase attempt
           (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Dependency_unavailable
             ~start_time:(Tool_timing.start ()) ~effect_disposition:phase "producer failure")
       | "deferred" -> settle attempt
           (Tool_result.make_deferred ~tool_name:node.tool_name ~start_time:(Tool_timing.start ()) ())
       | _ -> fail "invalid unproven producer mode");
      (match Journal.lookup worker ~node_id:node.id ~tool_name:node.tool_name ~input with
       | Error (Journal.Replay_not_proven id) ->
         check string "stored original producer is genuinely unproven" "interrupted" (Plan.Node_id.to_string id)
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "producer fixture did not persist the unproven occurrence");
      snapshot ();
      Unix._exit 0) in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    if node_name node = "interrupted" then (
      (* The readonly control still crosses the real Executor's Attempting
         boundary and callback. Loss does not invent a prior result wait. *)
      check string "only the readonly control uses modern dispatch" "readonly" mode;
      record_effect ();
      snapshot ();
      Unix._exit 0)
    else first_loss_success node in
  let submission = submit ~before_execute:retain_unproven_producer
      ~on_acceptance_probe:(fun request_id -> write (Filename.concat base_path "first-loss-request") request_id)
      base_path sw prepared dispatch |> accepted in
  ignore (await base_path submission);
  fail "first-loss worker unexpectedly completed"

let test_first_loss_retains_unproven_effects mode () =
  with_workspace (fun env sw base_path ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
    let readonly = mode = "readonly" in
    let prepared = prepare ~plan:(first_loss_plan ~readonly) base_path in
    Eio.Process.run (Eio.Stdenv.process_mgr env)
      [Sys.executable_name; "--lose-before-first-wait"; base_path;
       Plan.Composition_run_id.to_string prepared.source.composition_run_id; mode];
    let request_id = read (Filename.concat base_path "first-loss-request") in
    let original = read (Filename.concat base_path "first-loss-journal") in
    check string "original producer actually entered before loss" "one dispatch entry\n"
      (read (Filename.concat base_path "first-loss-effect"));
    let path = journal_path base_path prepared.source.composition_run_id in
    let recovered = Async.recover_lost_disk_records ~base_path () in
    check int "exclusive recovery publishes one real Lost owner" 1 recovered.lost;
    let terminal = Async.load_canonical_durable_terminal ~base_path ~caller:keeper request_id
        |> require "canonical first-loss proof" |> Async.durable_terminal_entry in
    (match terminal.status with Lost _ -> () | _ -> fail "first owner did not become Lost");
    check_json "Lost owner retains original Task" (`String "original-source-task")
      (match terminal.request_context with Some fields -> List.assoc "source_task_id" fields
       | None -> fail "original source absent");
    let marker_directory = Filename.concat (Filename.concat
        (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests") "prepared_continuations" in
    let marker_path = Filename.concat marker_directory
        (Digestif.SHA256.(digest_string request_id |> to_hex) ^ ".json") in
    let marker_bytes = read marker_path in
    let reject = function
      | Error (Journal.Replay_not_proven id) -> check string "exact unresolved node" "interrupted" (Plan.Node_id.to_string id)
      | Error error -> fail (Journal.error_to_string error)
      | Ok _ -> fail "unproven first-loss effects became a fresh resume" in
    if readonly then (
      (match Journal.waiting_continuation prepared.journal with
       | Ok None -> () | Ok (Some _) | Error _ -> fail "readonly manual resume was broadened into a wait or refused");
      let calls = ref [] in
      let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
        calls := node_name node :: !calls; first_loss_success node in
      let resumed = submit base_path sw prepared dispatch |> accepted in
      ignore (await base_path resumed);
      let rows = executed resumed |> require "readonly first-loss resume" in
      check (list string) "only readonly unfinished node dispatched" ["interrupted"] !calls;
      check bool "completed sibling retained" true
        ((node_result "completed-sibling" rows).execution_origin = Executor.Retained_completion))
    else (
      let pending () = Journal.pending_continuations
          ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path
        |> journal_value "first-loss maintenance discovery" in
      List.iter (fun _ ->
        let report = pending () in
        Printf.printf "first_loss_discovery=%s\n%!" (Yojson.Safe.to_string (`Assoc
          ["mode",`String mode;"inspected",`Int report.inspected;"retired",`Int report.retired;
           "ready",`Int (List.length report.ready);"failures",`Int (List.length report.failures)]));
        check int "unresolved first owner remains indexed" 1 report.inspected;
        check int "unresolved owner is not retired" 0 report.retired;
        check int "unknown effects do not schedule a worker" 0 (List.length report.ready);
        (match report.failures with [_,error] -> reject (Error error)
         | _ -> fail "unresolved first owner is not reported");
        check string "pending marker bytes retained" marker_bytes (read marker_path)) [(); ()];
      let terminal_path = Async.For_testing.terminal_record_path ~base_path ~request_id
          |> Option.get in
      let terminal_files () = Sys.readdir (Filename.dirname terminal_path) |> Array.to_list |> List.sort String.compare in
      let before = terminal_files () in
      let config = Workspace.default_config base_path in
      let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String keeper; "activation_mode", `String "manual"])
          |> require "public loss Keeper metadata" in
      let cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
      Masc.Keeper_tool_call_log.set_turn_context ~cell ~agent_name:keeper ~turn:43 ~keeper_turn_id:2 ~task_id:"replacement-task" ();
      let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
        {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
      let tools = Masc.Keeper_tool_composition_surface.make_tools ~capability_surface:(surface base_path)
          ~config ~meta ~publication_recovery ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
          ~turn_ctx_cell:cell ~clock:(Eio.Stdenv.clock env) () in
      let tool = List.find_map (fun (tool,_,_) ->
        if tool.Agent_core.Tool.schema.name = Draft.run_tool_name then Some tool else None) tools |> Option.get in
      let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"first-loss-manual-resume" ~turn:43
          ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
          ~completion:Continue_after_success in
      (match Agent_core.Tool.execute ~invocation tool (`Assoc ["sha256", `String (Draft.reference prepared.draft).sha256;
          "resume_run_id", `String (Plan.Composition_run_id.to_string prepared.source.composition_run_id)]) with
       | Error _ -> () | Ok _ -> fail "public SDK accepted an unproven first-loss resume");
      check (list string) "public refusal creates no terminal request" before (terminal_files ());
      let active = Async.read_durable_active_inventory ~base_path |> require "public refusal active inventory" in
      check int "public refusal creates no active request" 0 (List.length active.entries);
      reject (Journal.waiting_continuation prepared.journal);
      check string "manual refusal preserves pending marker" marker_bytes (read marker_path);
      check string "discovery and manual refusal preserve original occurrences" original (read path);
      let module Command = Operator_composition_resolution_command in
      let target = ["keeper_name",`String keeper;"request_id",`String request_id;
        "composition_run_id",`String (Plan.Composition_run_id.to_string prepared.source.composition_run_id)] in
      let command name fields = Command.parse_tool_command (`Assoc (("command",`String name)::target @ fields))
        |> require "explicit operator command" in
      let run ?(actor="operator-fixture") ~now command =
        Command.execute ~base_path ~actor ~now command in
      let observation = run ~now:100. (command "observe" []) |> journal_value "observe unresolved original owner"
        |> Command.outcome_to_json in
      let version = observation |> Yojson.Safe.Util.member "expected_version" |> Yojson.Safe.Util.to_string in
      let decision = if mode = "unknown" then "reject" else "cancel" in
      let resolve = command decision ["expected_version",`String version;"reason",`String "stop this exact original continuation"] in
      (* Preserve a real original marker inode while substituting same bytes at
         its public path. A stale operator observation cannot revoke replacement
         authority or consume its marker. No child command is called here. *)
      let parked = Filename.concat base_path "original-marker-for-resolution" in
      Unix.rename marker_path parked;
      Fun.protect ~finally:(fun () ->
        if Sys.file_exists marker_path then Unix.unlink marker_path;
        Unix.rename parked marker_path) (fun () ->
        write marker_path marker_bytes; Unix.chmod marker_path 0o600;
        (match run ~now:101. resolve with
         | Error Journal.Ownership_changed -> ()
         | Error error -> fail (Journal.error_to_string error)
         | Ok _ -> fail "stale marker observation committed a resolution");
        check string "stale resolution preserves the original node journal" original (read path);
        check string "stale resolution retains the replacement marker" marker_bytes (read marker_path));
      let resolved = run ~now:102. resolve |> journal_value "explicit original resolution"
        |> Command.outcome_to_json in
      let module Detail = Masc.Tui_decode_async_request in
      let target : Detail.target={submitted_by=keeper;request_id;keeper_name=keeper} in
      let projected = Server_async_request_observability.project_request ~base_path ~submitted_by:keeper ~request_id in
      (match Detail.decode ~target projected with
       | Ok (Detail.Observed {phase=Detail.Lost;logical=Detail.Confirmed (Detail.Original_run run);_}) ->
         check (option string) "typed TUI observation keeps original Task" (Some "original-source-task") run.source_task_id;
         (match run.resolution with
          | Some resolution -> check bool "typed TUI logical decision is the original operator decision" true
              (resolution.decision=(if mode="unknown" then Detail.Rejected else Detail.Cancelled_continuation))
          | None -> fail "logical operator resolution disappeared in the TUI protocol")
       | Ok _ -> fail "physical Lost and logical resolution were conflated"
       | Error detail -> fail detail);
      (* The original resource scenario continues through the actual exact
         Task/history producers and the TUI's owned source reads. It never
         supplies a current Task/list row or inspects rendered text. *)
      let module Ui = Masc_tui_types in
      let module Task_read = Masc.Tui_decode_task_inspection in
      let ui=Ui.create_state ~workspace:"source-task" ~local_base_path:base_path ~port:0 ~refresh_interval:0. () in
      ui.tools_async_selection <- Some target;ui.tools_async_detail_open <- true;
      let request=Ui.begin_tools_async_detail ui ~force:false |> Option.get in
      Ui.complete_tools_async_detail ui request (Detail.decode ~target projected);
      let source=match Ui.tools_async_source_task ui with
        | Ui.Async_source_task source -> source
        | _ -> fail "real original run lost its Task source" in
      check string "source link belongs to the original run" (Plan.Composition_run_id.to_string prepared.source.composition_run_id) source.ats_run_id;
      check string "source link retains original Task" "original-source-task" source.ats_task_id;
      let config=Workspace.default_config base_path in
      let description="Original resource evidence\n" ^ String.make 4096 'x' in
      let task id = Masc_domain.task_of_yojson (`Assoc ["id",`String id;"title",`String id;
        "description",`String description;"status",`String "todo";"created_at",`String "2026-10-19T00:00:00Z"])
        |> require "source Task fixture" in
      let backlog=Workspace_backlog.read_backlog_r config |> require "authoritative Task backlog" in
      Workspace_backlog.write_backlog config {backlog with tasks=[task source.ats_task_id;task "different-current-task"]};
      List.iter (fun task_id -> Workspace_utils_ops.log_event config (`Assoc
        ["type",`String "task_transition";"task_id",`String task_id;"ts",`String "2026-10-19T00:00:01Z";
         "from_status",`String "todo";"to_status",`String "claimed";"actor",`String keeper]))
        [source.ats_task_id;"different-current-task"];
      let read_body ?previous task_id = match Server_dashboard_task_detail.read ~config ~task_id:(Some task_id)
          |> Server_dashboard_task_detail.response with
        | `OK,json -> Task_read.detail ?previous ~task_id:source.ats_task_id json
        | _ -> Error "source Task producer unavailable" in
      let read_history ?task_id (request : Task_read.history_request) =
        let task_id=Option.value task_id ~default:request.hr_task_id in
        let status,json=Server_dashboard_task_history_page.read ~config ~task_id:(Some task_id)
          ~limit:(Some (string_of_int request.hr_limit)) ~cursor:request.hr_cursor in
        if status=`OK then Task_read.history_page ~request json else Error "original history page refused" in
      (* Continue the same original resource history through the production
         dated-page protocol. Later appends and another Task cannot replace
         the captured prefix; replacement refuses cursor advancement. *)
      let module History = Masc.Task.History_page in
      let page result = match result with Ok page -> page | Error _ -> fail "original history page unavailable" in
      let append action = Workspace_utils_ops.log_event config (`Assoc
        ["task_id",`String source.ats_task_id;"type",`String "task_transition";
         "action",`String action;"ts",`String "2026-10-19T00:00:02Z";
         "actor",`String keeper]) in
      append "original-before-a";append "original-before-b";
      let first=History.read ~config ~task_id:source.ats_task_id ~max_events:1 () |> page in
      let cursor=match first.next_cursor with Some cursor -> cursor | None -> fail "original prefix lost its older boundary" in
      let encoded=History.cursor_to_string cursor in
      let cursor=match History.cursor_of_string encoded with Ok cursor -> cursor | Error _ -> fail "producer cursor did not roundtrip" in
      append "newer-after-capture";
      (match History.read ~config ~task_id:"different-current-task" ~max_events:1 ~cursor () with
       | Error History.Source_changed -> () | _ -> fail "a foreign Task borrowed the original history cursor");
      let rec earlier cursor collected =
        let next=History.read ~config ~task_id:source.ats_task_id ~max_events:1 ~cursor () |> page in
        let collected=collected @ next.events in
        match next.next_cursor with None -> collected | Some cursor -> earlier cursor collected in
      let complete=first.events @ earlier cursor [] in
      let action name = List.exists (fun row -> Json_util.get_string (Yojson.Safe.Util.member "event" row) "action"=Some name) complete in
      check bool "older original records survive contiguous page traversal" true
        (action "original-before-a" && action "original-before-b");
      check bool "post-capture appends do not enter its older prefix" false (action "newer-after-capture");
      (match Task_read.history ~task_id:source.ats_task_id (`List complete) with
       | Ok _ -> () | Error detail -> fail detail);
      let status,json=Server_dashboard_task_history_page.read ~config
        ~task_id:(Some source.ats_task_id) ~limit:(Some "1") ~cursor:(Some encoded) in
      check bool "shared HTTP/H2 producer echoes the exact original cursor" true
        (status=`OK && Json_util.get_string json "cursor"=Some encoded
         && Json_util.get_string json "task_id"=Some source.ats_task_id);
      let events=Filename.concat (Workspace.masc_dir config) "events" in
      (* Corrupt dated membership is an unavailable source, even beside valid
         history. Only the shared layout authority's foreign entries are ignored. *)
      let refuse_invalid expected =
        let rejected = function
          | Error (History.Invalid_layout {entry}) when entry=expected -> true
          | Ok _ | Error _ -> false in
        check bool "invalid dated layout refuses a fresh observed prefix" true
          (rejected (History.read ~config ~task_id:source.ats_task_id ~max_events:1 ()));
        check bool "invalid dated layout refuses an original continuation" true
          (rejected (History.read ~config ~task_id:source.ats_task_id ~max_events:1 ~cursor ()));
        let status,json=Server_dashboard_task_history_page.read ~config
          ~task_id:(Some source.ats_task_id) ~limit:(Some "1") ~cursor:None in
        check bool "both HTTP transports receive the typed corrupt-layout failure" true
          (status=`Service_unavailable && Json_util.get_string json "error"=Some "task_history_invalid_layout") in
      let invalid_month=Filename.concat events "2026-13" in
      Unix.mkdir invalid_month 0o700;
      Fun.protect ~finally:(fun () -> Unix.rmdir invalid_month)
        (fun () -> refuse_invalid "events/2026-13");
      let month=Filename.concat events "2096-02" in
      Unix.mkdir month 0o700;
      Fun.protect ~finally:(fun () -> Unix.rmdir month) (fun () ->
        List.iter (fun name ->
          let path=Filename.concat month name in
          let oc=open_out_bin path in close_out oc;
          Fun.protect ~finally:(fun () -> Sys.remove path)
            (fun () -> refuse_invalid ("events/2096-02/" ^ name)))
          ["32.jsonl";"29.0000.jsonl"];
        let hidden=Filename.concat month ".DS_Store" in
        let oc=open_out_bin hidden in close_out oc;
        Fun.protect ~finally:(fun () -> Sys.remove hidden) (fun () ->
          match History.read ~config ~task_id:source.ats_task_id ~max_events:1 () with
          | Ok page when page.events<>[] -> ()
          | Ok _ | Error _ -> fail "foreign dotfile changed the original history observation"));
      let parked=Filename.concat base_path "original-event-prefix" in
      Unix.rename events parked;
      Fun.protect ~finally:(fun () -> if Sys.file_exists events then Unix.rmdir events;Unix.rename parked events) (fun () ->
        Unix.mkdir events 0o700;
        let invalid=Filename.concat events "2026-13" in
        Unix.mkdir invalid 0o700;
        Fun.protect ~finally:(fun () -> Unix.rmdir invalid)
          (fun () -> refuse_invalid "events/2026-13");
        match History.read ~config ~task_id:source.ats_task_id ~max_events:1 ~cursor () with
        | Error History.Source_changed -> ()
        | _ -> fail "replacement event store became an exhausted original history");
      ui.tools_async_task_source <- Some source;
      let old_body=Ui.begin_tools_async_task_body ui ~force:false |> Option.get in
      let old_history=Ui.begin_tools_async_task_history ui ~force:false ~limit:1 |> Option.get in
      Ui.suspend_workspace_readings ui;
      let current_body=Ui.begin_tools_async_task_body ui ~force:false |> Option.get in
      let current_history=Ui.begin_tools_async_task_history ui ~force:true ~limit:1 |> Option.get in
      Ui.complete_tools_async_task_body ui old_body (read_body source.ats_task_id);
      Ui.complete_tools_async_task_history ui old_history (read_history old_history.thr_page);
      check bool "retired Task reads cannot settle replacement reads" true
        (Masc_tui_fetched.in_flight ui.tools_async_task_body && Masc_tui_fetched.in_flight ui.tools_async_task_history);
      Ui.complete_tools_async_task_history ui current_history (read_history current_history.thr_page);
      check bool "history is observed while the body remains pending" true
        (Masc_tui_fetched.in_flight ui.tools_async_task_body &&
         match Masc_tui_fetched.view_for ~equal:Ui.equal_tools_async_task_source ui.tools_async_task_history ~key:source with
         | Ready history -> List.exists (fun (event : Masc.Tui_decode.task_history_event) ->
             event.th_actor=Some keeper && event.th_label="newer-after-capture") history.history_events
         | Absent | Loading | Failed _ | Stale _ -> false);
      let observed ()=Masc_tui_fetched.view_for ~equal:Ui.equal_tools_async_task_source ui.tools_async_task_history ~key:source in
      let prefix=Masc_tui_fetched.value (observed ()) |> Option.get in
      let failed=Ui.begin_tools_async_task_history ~older:true ui ~force:false ~limit:1 |> Option.get in
      Ui.complete_tools_async_task_history ui failed (Error "older original store unavailable");
      check bool "failed older read retains exact observed prefix and retry cursor" true
        (match observed () with Stale (retained,_) -> retained==prefix | _ -> false);
      check bool "cadence cannot replace the failed original continuation" true
        (Ui.begin_tools_async_task_history ui ~force:false ~limit:1=None);
      let retry=Ui.begin_tools_async_task_history ~older:true ui ~force:false ~limit:1 |> Option.get in
      check bool "explicit retry captures the same older boundary" true
        (retry.thr_page.hr_cursor=failed.thr_page.hr_cursor);
      Ui.complete_tools_async_task_history ui failed (read_history failed.thr_page);
      check bool "late success cannot settle the replacement continuation" true
        (Masc_tui_fetched.is_current ~equal:Ui.equal_tools_async_task_source ui.tools_async_task_history retry.thr_ticket);
      Ui.complete_tools_async_task_history ui retry (read_history retry.thr_page);
      let rec read_earlier ()=match Ui.begin_tools_async_task_history ~older:true ui ~force:false ~limit:1 with
        | None -> ()
        | Some request ->
          let result=read_history request.thr_page in
          (match result with Ok _ -> () | Error detail -> fail detail);
          Ui.complete_tools_async_task_history ui request result;read_earlier () in
      read_earlier ();
      let retained=Masc_tui_fetched.value (observed ()) |> Option.get in
      check bool "TUI continuation retains original transition evidence with its prefix" true
        (retained.history_next_cursor=None &&
         List.exists (fun (event : Masc.Tui_decode.task_history_event) ->
           event.th_actor=Some keeper && event.th_from_status=Some "todo"
           && event.th_to_status=Some "claimed") retained.history_events);
      Ui.complete_tools_async_task_body ui current_body (read_body source.ats_task_id);
      let module Document = Masc_tui_task_document in
      let module Observation = Masc_tui_task_document_observation in
      ui.view <- Ui.Tools;ui.tools_pane <- Ui.Tools_async;
      let started=Ui.sync_task_documents ui ~cols:96 in
      let find part requests = List.find (fun request ->
        let key=Masc_tui_fetched.request_key request.Ui.tdr_ticket in
        Document.part key.tdk_input=part) requests in
      let prepare request =
        let key=Masc_tui_fetched.request_key request.Ui.tdr_ticket in
        Ok (Observation.run request.tdr_observation ~name:"task.document.fixture.prepare_wait"
          (fun () -> Document.prepare key.tdk_input)) in
      let old_document=find Document.Body started in
      Ui.complete_task_document ui ~cols:72 old_document (prepare old_document);
      check bool "a terminal rejected owner cannot remain loading until reconciliation" false
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading);
      check bool "source/width rejection retains its actual disposition" true
        (match (Observation.facts old_document.tdr_observation).ui_disposition with
         | Some (_,Observation.Rejected Source_or_width_changed) -> true | _ -> false);
      let restarted=Ui.sync_task_documents ui ~cols:96 in
      let old_document=find Document.Body restarted in
      check bool "returning to the old width starts a live replacement owner" true
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading);
      let resized=Ui.sync_task_documents ui ~cols:72 in
      Ui.complete_task_document ui ~cols:72 old_document (prepare old_document);
      check bool "old-width preparation cannot settle the original Task's new width" true
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading);
      let history_document=find Document.History resized in
      let delivered,resolve_delivered=Eio.Promise.create () and released,resolve_released=Eio.Promise.create () in
      Masc_tui_workspace_job.fork ~key:history_document.tdr_job ~observation:true
        ~observe:(function
          | Masc_tui_workspace_job.Cancellation_requested ->
            Observation.observe history_document.tdr_observation Cancellation_requested
          | Registration_released ->
            Observation.observe history_document.tdr_observation Registration_released;
            Eio.Promise.resolve resolve_released ()) ui ~sw
        (fun () -> Eio.Promise.resolve resolve_delivered (prepare history_document));
      let history_result=Eio.Promise.await delivered in
      Eio.Promise.await released;
      Ui.complete_task_document ui ~cols:72 history_document history_result;
      check bool "actual worker/caller/registry/UI facts remain separate" true
        (let facts=Observation.facts history_document.tdr_observation in
         facts.worker_entered<>None && facts.worker_returned<>None
         && facts.caller_observed<>None && facts.registration_released_ns<>None
         && match facts.ui_disposition with Some (_,Observation.Applied) -> true | _ -> false);
      check bool "history preparation settles independently of body preparation" true
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading
         && not (Masc_tui_fetched.in_flight ui.task_document_history.tds_reading));
      (* A real fresh body read must not revoke a pending preparation when
         all decoded Task facts are unchanged. Admission/freshness still use
         the new physical read owner, not the retained immutable payload. *)
      let unchanged_document=find Document.Body resized in
      let reread=Ui.begin_tools_async_task_body ui ~force:false |> Option.get in
      Ui.complete_tools_async_task_body ui reread
        (read_body ?previous:reread.atr_previous source.ats_task_id);
      Ui.complete_task_document ui ~cols:72 unchanged_document (prepare unchanged_document);
      check bool "fresh identical original Task observations keep the actual preparation owner admissible" true
        (match (Observation.facts unchanged_document.tdr_observation).ui_disposition with
         | Some (_,Observation.Applied) -> true | _ -> false);
      (* Same Task/status/run but changed authoritative content must invalidate
         that reuse. Write through the actual backlog producer and read again. *)
      let description=description ^ "\nFresh original source evidence" in
      let backlog=Workspace_backlog.read_backlog_r config |> require "backlog before original content update" in
      Workspace_backlog.write_backlog config {backlog with tasks=List.map
        (fun (task : Masc_domain.task) -> if task.id=source.ats_task_id then {task with description} else task)
        backlog.tasks};
      let changed=Ui.begin_tools_async_task_body ui ~force:false |> Option.get in
      Ui.complete_tools_async_task_body ui changed
        (read_body ?previous:changed.atr_previous source.ats_task_id);
      let changed_documents=Ui.sync_task_documents ui ~cols:72 in
      let old_document=find Document.Body changed_documents in
      (* The same authoritative Task object, under another actual consumer,
         cannot borrow an async-source preparation owner's late reply. *)
      let original_detail=match Masc_tui_fetched.view_for ~equal:Ui.equal_tools_async_task_source ui.tools_async_task_body ~key:source with
        | Ready detail | Stale (detail,_) -> detail
        | _ -> fail "exact original Task body disappeared before consumer switch" in
      ui.task_payloads <- Ui.Task_payloads.observe [original_detail.task];
      ui.tasks <- Masc.Tui_decode.active_tasks_of_domain (Ui.task_domain_values ui);
      ui.view <- Ui.Planning;ui.planning_mode <- Ui.Planning_list;
      ui.task_detail_id <- Some source.ats_task_id;
      ui.task_focus <- Masc_tui_overview_tasks.land_on ui.tasks ~task_id:source.ats_task_id;
      ui.workspace_identity <- Ui.Workspace_identity_match;
      let read_work () =
        let request=Ui.begin_local_workspace_read ui ~intent:Ui.Snapshot_read.Refresh
          ~source:Ui.Local_work ~base_path ~started_ns:0L |> Option.get in
        let reading=Ui.Local_read_observation.run request.lwr_observation
          ~read:(fun () -> Masc_tui_loader.read_local_workspace base_path)
          ~prepare:(Masc_tui_loader.prepare_local_workspace request) in
        match Ui.take_local_workspace_read ui ~source:Ui.Local_work request (Ok reading) with
        | Some (Ok reading) -> Ui.Local_read_observation.apply request.lwr_observation
            (Masc_tui_loader.apply_local_workspace ui) reading
        | Some (Error _) | None -> fail "actual Work observation lost its original read owner" in
      read_work ();
      let work=Ui.sync_task_documents ui ~cols:72 in
      Ui.complete_task_document ui ~cols:72 old_document (prepare old_document);
      check bool "an async-source reply cannot settle the same-ID Work document" true
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading);
      let unchanged_work=find Document.Body work in
      (* A real write to another Task invalidates the whole backlog cache.
         The unchanged selected Task must keep its pending preparation owner,
         while the other Task's new facts land from the same actual read. *)
      let backlog=Workspace_backlog.read_backlog_r config |> require "backlog before other Task update" in
      Workspace_backlog.write_backlog config {backlog with tasks=List.map
        (fun (task : Masc_domain.task) -> if task.id="different-current-task"
          then {task with description="Other Task changed its authoritative evidence"} else task) backlog.tasks};
      read_work ();
      Ui.complete_task_document ui ~cols:72 unchanged_work (prepare unchanged_work);
      check bool "another Task's actual write keeps original Work preparation admissible" true
        (match (Observation.facts unchanged_work.tdr_observation).ui_disposition with
         | Some (_,Observation.Applied) -> true | _ -> false);
      check bool "the same read still applies the changed other Task" true
        (List.exists (fun (task : Masc_domain.task) -> task.id="different-current-task"
          && task.description="Other Task changed its authoritative evidence") (Ui.task_domain_values ui));
      (* The actual raw backlog snapshot remains cached on another Work read.
         Its stable observation stays intact while an independent authoritative
         Goal-link read fails; no old supplemental result may be borrowed. *)
      let retained_payloads=ui.task_payloads in
      let links=Workspace_goal_index.read_goal_task_links_authoritative_r config
        |> require "original Goal links before independent read failure" in
      Workspace_goal_index.write_goal_task_links_result config links
        |> require "persist original Goal links before corruption";
      let links_path=Workspace_goal_index.goal_task_links_path config in
      let original_links=read links_path in
      let write_links bytes = let oc=open_out_bin links_path in
        Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc bytes) in
      write_links "{}";
      Fun.protect ~finally:(fun () -> write_links original_links) (fun () ->
        read_work ();
        check bool "an actual cached Task snapshot retains its immutable source/value observation" true
          (ui.task_payloads==retained_payloads);
        check bool "same Task snapshot does not hide a fresh Goal-link source failure" true
          (match Ui.task_goal_reading ui ~task_id:source.ats_task_id with
           | Masc_tui_agenda.Read_failed _ -> true | Read _ | Not_read -> false));
      (* A change to the selected Task itself must not borrow that payload.
         Its new pending owner continues through the existing scope replay. *)
      let backlog=Workspace_backlog.read_backlog_r config |> require "backlog before Work Task update" in
      let work_description=description ^ "\nWork source observed newer evidence" in
      Workspace_backlog.write_backlog config {backlog with tasks=List.map
        (fun (task : Masc_domain.task) -> if task.id=source.ats_task_id
          then {task with description=work_description} else task) backlog.tasks};
      read_work ();
      check bool "selected Work Task content is newly observed under the same identity" true
        (List.exists (fun (task : Masc_domain.task) -> task.id=source.ats_task_id
          && task.description=work_description) (Ui.task_domain_values ui));
      let changed_work=Ui.sync_task_documents ui ~cols:72 in
      let work_body=find Document.Body changed_work in
      (* A real local Work result can arrive after its read epoch was withdrawn.
         It must retain its own rejection facts and cannot settle the replacement
         Work request or the independent required-metadata source. *)
      let late_work=Ui.begin_local_workspace_read ui ~intent:Ui.Snapshot_read.Refresh
        ~source:Ui.Local_work ~base_path ~started_ns:(Mtime_clock.elapsed_ns ()) |> Option.get in
      let late_reading=Ui.Local_read_observation.run late_work.lwr_observation
        ~read:(fun () -> Masc_tui_loader.read_local_workspace base_path)
        ~prepare:(Masc_tui_loader.prepare_local_workspace late_work) in
      Ui.suspend_workspace_readings ui;
      let replacement_work=Ui.begin_local_workspace_read ui ~intent:Ui.Snapshot_read.Refresh
        ~source:Ui.Local_work ~base_path ~started_ns:(Mtime_clock.elapsed_ns ()) |> Option.get in
      let metadata=Ui.begin_local_workspace_read ui ~intent:Ui.Snapshot_read.Refresh
        ~source:Ui.Local_keepers ~base_path ~started_ns:(Mtime_clock.elapsed_ns ()) |> Option.get in
      check bool "late actual Work result is rejected after source withdrawal" true
        (Option.is_none (Ui.take_local_workspace_read ui ~source:Ui.Local_work late_work (Ok late_reading)));
      check bool "late Work result leaves replacement and metadata independently pending" true
        (Ui.Local_read_order.in_flight ui.local_workspace_read_order
          && Ui.Local_read_order.in_flight ui.local_keeper_read_order);
      check bool "rejected original retains its source disposition without claiming state application" true
        (let facts=Ui.Local_read_observation.facts late_work.lwr_observation in
         match facts.ui_admission,facts.ui_application with
         | Some (_,Rejected Superseded),None -> true | _ -> false);
      let keeper_reading=Ui.Local_read_observation.run metadata.lwr_observation
        ~read:(fun () -> Masc_tui_loader.read_local_keepers base_path) ~prepare:Fun.id in
      (match Ui.take_local_workspace_read ui ~source:Ui.Local_keepers metadata (Ok keeper_reading) with
       | Some (Ok reading) -> Ui.Local_read_observation.apply metadata.lwr_observation
           (Masc_tui_loader.apply_local_keepers ui) reading
       | Some (Error _) | None -> fail "actual metadata result lost independent source ownership");
      check bool "required metadata can apply while replacement Work stays pending" true
        (Ui.Local_read_order.in_flight ui.local_workspace_read_order
          && not (Ui.Local_read_order.in_flight ui.local_keeper_read_order));
      let replacement_reading=Ui.Local_read_observation.run replacement_work.lwr_observation
        ~read:(fun () -> Masc_tui_loader.read_local_workspace base_path)
        ~prepare:(Masc_tui_loader.prepare_local_workspace replacement_work) in
      (match Ui.take_local_workspace_read ui ~source:Ui.Local_work replacement_work (Ok replacement_reading) with
       | Some (Ok reading) -> Ui.Local_read_observation.apply replacement_work.lwr_observation
           (Masc_tui_loader.apply_local_workspace ui) reading
       | Some (Error _) | None -> fail "replacement Work result lost its original source owner");
      check bool "replacement application is observed only for its own admitted result" true
        (match (Ui.Local_read_observation.facts replacement_work.lwr_observation).ui_application with
         | Some (_,Applied) -> true | _ -> false);
      let replacement_documents=Ui.sync_task_documents ui ~cols:72 in
      Ui.complete_task_document ui ~cols:72 work_body (prepare work_body);
      check bool "retired preparation cannot settle a reentered same-ID document" true
        (Masc_tui_fetched.in_flight ui.task_document_body.tds_reading);
      List.iter (fun request -> Ui.complete_task_document ui ~cols:72 request (prepare request)) replacement_documents;
      ui.view <- Ui.Tools;ui.task_payloads <- Ui.Task_payloads.empty;
      let refresh=Ui.begin_tools_async_task_body ui ~force:true |> Option.get in
      Ui.complete_tools_async_task_body ui refresh (Error "Task storage unavailable");
      check bool "body failure retains full original Task independently of list membership" true
        ((Ui.task_domain_values ui)=[] && match Masc_tui_fetched.view_for ~equal:Ui.equal_tools_async_task_source ui.tools_async_task_body ~key:source with
         | Stale (detail,_) -> detail.task.id=source.ats_task_id && detail.task.description=description
         | _ -> false);
      check bool "current Task cannot replace original Task detail" true (Result.is_error (read_body "different-current-task"));
      check bool "current Task events cannot replace original history" true (Result.is_error (read_history ~task_id:"different-current-task" current_history.thr_page));
      let late=Ui.begin_tools_async_task_body ui ~force:true |> Option.get in
      Ui.withdraw_tools_async_details ui;
      ui.tools_async_selection <- Some target;ui.tools_async_detail_open <- true;ui.tools_async_task_source <- Some source;
      let replacement=Ui.begin_tools_async_task_body ui ~force:false |> Option.get in
      Ui.complete_tools_async_task_body ui late (read_body source.ats_task_id);
      check bool "withdrawn same-ID Task reader cannot settle its replacement" true (Masc_tui_fetched.in_flight ui.tools_async_task_body);
      Ui.complete_tools_async_task_body ui replacement (read_body source.ats_task_id);
      check_json "exact marker retired after durable resolution" (`Bool true)
        (Yojson.Safe.Util.member "marker_retired" resolved);
      check bool "resolved marker no longer indexed" false (Sys.file_exists marker_path);
      let resolved_bytes = read path in
      check bool "resolution appends without rewriting original results" true (String.starts_with ~prefix:original resolved_bytes);
      let unchanged_terminal = Async.load_canonical_durable_terminal ~base_path ~caller:keeper request_id
        |> require "physical terminal after resolution" |> Async.durable_terminal_entry in
      check bool "logical decision preserves physical Lost outcome" true (Async.same_entry_record terminal unchanged_terminal);
      (match Journal.waiting_continuation prepared.journal with
       | Ok None -> () | Ok (Some _) | Error _ -> fail "resolved journal remained resumable");
      (match submit base_path sw prepared
          (fun ?launch_replay:_ ~tool_use_id:_ ~node:_ ~descriptor:_ ~schedule:_ ~input:_ () ->
            fail "resolved run attempted another child effect") with
       | Error (_,Some Journal.Ownership_changed) -> ()
       | Error _ | Ok _ -> fail "resolved source acquired another worker");
      check_json "same-command retry retains original decision and timestamp" resolved
        (run ~now:200. resolve |> journal_value "idempotent exact resolution retry" |> Command.outcome_to_json);
      (match run ~actor:"competing-operator" ~now:201. resolve with
       | Error Journal.Ownership_changed -> ()
       | Error _ | Ok _ -> fail "competing operator replaced committed resolution");
      check string "retry and competing decision preserve the committed journal" resolved_bytes (read path);
      let settled = pending () in
      check int "resolved original owner has no retained discovery failure" 0 (List.length settled.failures);
      check int "resolved original owner schedules no continuation" 0 (List.length settled.ready));
    check string "original child dispatched once" "one dispatch entry\n" (read (Filename.concat base_path "first-loss-effect")))

let test_exact_queued_admission () = with_workspace (fun env sw base_path ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let prepared = prepare base_path in
  let exact ?(caller = keeper) request_id =
    Async.load_canonical_durable_queued ~base_path ~caller request_id in
  let proof request_id = exact request_id
    |> function Ok proof -> Async.durable_queued_entry proof
      | Error error -> fail (Async.canonical_queued_error_to_string error) in
  let reject label predicate = function
    | Error error when predicate error -> ()
    | Error error -> failf "%s: %s" label (Async.canonical_queued_error_to_string error)
    | Ok _ -> fail (label ^ " unexpectedly admitted") in
  let replace name value = function
    | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
    | _ -> fail "actual canonical record must be an object" in
  let path request_id = Async.For_testing.active_record_path ~base_path ~request_id
    |> function Some path -> path | None -> fail "canonical active path" in
  let terminal_path request_id = Async.For_testing.terminal_record_path ~base_path ~request_id
    |> function Some path -> path | None -> fail "canonical terminal path" in
  let known_request = ref None in
  let probe request_id =
    known_request := Some request_id;
    let expected = proof request_id in
    check bool "actual acceptance is Queued" true (expected.status = Async.Queued);
    let original = read (path request_id) in
    let json = Yojson.Safe.from_string original in
    exact ~caller:"foreign-caller" request_id
    |> reject "foreign exact read" (function Async.Canonical_queued_access_rejected _ -> true | _ -> false);
    exact "absent-queued-fixture"
    |> reject "absent exact record" (function Async.Canonical_queued_absent -> true | _ -> false);
    Fun.protect ~finally:(fun () -> write (path request_id) original) (fun () ->
      write (path request_id) "{invalid";
      exact request_id |> reject "unreadable exact record"
        (function Async.Canonical_queued_unreadable _ -> true | _ -> false);
      check string "unavailable authority is not rewritten" "{invalid" (read (path request_id));
      write (path request_id) (replace "submitted_at" (`Float (expected.submitted_at +. 1.0)) json |> Yojson.Safe.to_string);
      exact request_id |> reject "cached reservation does not authorize conflicting disk"
        (function Async.Canonical_queued_runtime_conflict -> true | _ -> false));
    let terminal = terminal_path request_id in
    Fs_compat.mkdir_p (Filename.dirname terminal);
    Fun.protect ~finally:(fun () -> Unix.unlink terminal) (fun () ->
      let done_json = json |> replace "status" (`String "done")
        |> replace "completed_at" (`Float (expected.submitted_at +. 1.0))
        |> replace "ok" (`Bool true) |> replace "body" (`String "already settled") in
      write terminal (Yojson.Safe.to_string done_json);
      exact request_id |> reject "canonical terminal takes precedence over Queued memory and disk"
        (function Async.Canonical_queued_not_queued (Async.Done _) -> true | _ -> false);
      check string "active source remains unchanged" original (read (path request_id)));
    let created = ref [] in
    Fun.protect ~finally:(fun () -> List.iter Unix.unlink !created) (fun () ->
      let population = ref 0 in
      List.iter (fun unrelated ->
        for index = !population + 1 to unrelated do
          let clone_id = Printf.sprintf "queued-population-%d" index in
          let clone_path = path clone_id in
          write clone_path (replace "request_id" (`String clone_id) json |> Yojson.Safe.to_string);
          created := clone_path :: !created
        done;
        population := unrelated;
        let inventory () = Async.read_durable_active_inventory ~base_path
          |> require "actual baseline active inventory" in
        let baseline () =
          let inventory = inventory () in
          if List.length inventory.entries <> unrelated + 1 || inventory.record_errors <> []
          then fail "baseline population did not decode exactly";
          let entry = match List.filter (fun (entry : Async.entry) -> entry.request_id = request_id) inventory.entries with
            | [entry] -> entry | _ -> fail "one known baseline request" in
          if not (Async.same_entry_record entry expected) then fail "baseline original record changed";
          List.length inventory.entries in
        let candidate () =
          if not (Async.same_entry_record (proof request_id) expected) then fail "exact original record changed";
          1 in
        let measure read =
          let started = Monotonic_deadline.start () in
          let returned = read () + read () in
          Monotonic_deadline.elapsed_seconds started *. 1000.0, returned in
        (* Counts and sample repetitions describe this isolated experiment;
           neither controls product admission nor asserts a timing threshold. *)
        for sample = 1 to 5 do
          let (baseline_ms, baseline_records), (exact_ms, exact_records) =
            if sample mod 2 = 1 then let baseline = measure baseline in baseline, measure candidate
            else let candidate = measure candidate in measure baseline, candidate in
          Printf.printf "QUEUED_ACCEPTANCE_READ %s\n%!"
            (Yojson.Safe.to_string (`Assoc
              ["unrelated_active_records", `Int unrelated; "sample", `Int sample;
               "reads_per_path", `Int 2; "baseline_ms", `Float baseline_ms; "exact_ms", `Float exact_ms;
               "baseline_returned_records", `Int baseline_records; "exact_returned_records", `Int exact_records]))
        done) [0; 16; 64; 256];
      let poison = path "unrelated-corrupt-queued" in
      write poison "{unrelated-corruption";
      created := poison :: !created;
      check bool "unrelated corruption is observable in inventory" true
        (List.exists (fun (error : Async.active_inventory_record_error) -> error.request_id = Some "unrelated-corrupt-queued")
          (Async.read_durable_active_inventory ~base_path |> require "corrupt unrelated inventory").record_errors);
      check bool "exact admission is independent of unrelated corrupt records" true
        (Async.same_entry_record (proof request_id) expected)) in
  let calls = ref 0 in
  let submission = submit ~on_acceptance_probe:probe
      ~before_execute:(fun _ ->
        let request_id = !known_request |> Option.get in
        exact request_id |> reject "a started request cannot be admitted as Queued"
          (function Async.Canonical_queued_not_queued Async.Running
            | Canonical_queued_runtime_nonqueued Async.Running -> true | _ -> false))
      base_path sw prepared
      (fun ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () ->
        incr calls; Executor.dispatch_result (success base_path node "original-profile"))
    |> accepted in
  ignore (await base_path submission);
  ignore (executed submission |> require "exact-proof admission executes original plan");
  check int "real admitted plan dispatches each original node once" 3 !calls;
  exact submission.request.request_id |> reject "terminal request cannot be re-admitted"
    (function Async.Canonical_queued_not_queued (Async.Done _) -> true | _ -> false))

let test_pending_marker_retirement_rejects_replacement () =
  List.iter (fun damage -> with_workspace (fun _env sw base_path ->
    let prepared = prepare base_path in
    let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
      Executor.dispatch_result (success base_path node "original-profile") in
    let submission = submit base_path sw prepared dispatch |> accepted in
    ignore (await base_path submission);
    ignore (executed submission |> require "original plan completed");
    let original = ref None and replacement = ref None in
    let hook path =
      let bytes = read path in
      original := Some (path, bytes);
      let foreign = match Yojson.Safe.from_string bytes with
        | `Assoc fields -> Yojson.Safe.to_string (`Assoc
            (("keeper_name", `String "foreign-keeper") :: List.remove_assoc "keeper_name" fields)) ^ "\n"
        | _ -> fail "real marker is not an object" in
      let replacement_bytes = match damage with
        | `Physical_foreign -> foreign
        | `Physical_malformed -> "{malformed-marker\n"
        | `Same_inode_same_length -> String.make (String.length bytes - 1) 'x' ^ "\n" in
      (match damage with
       | `Physical_foreign | `Physical_malformed ->
         let staged = path ^ ".fixture-replacement" in
         write staged replacement_bytes;
         Unix.chmod staged 0o600;
         Unix.rename staged path
       | `Same_inode_same_length -> write path replacement_bytes);
      replacement := Some (replacement_bytes, (Unix.lstat path).st_ino) in
    let report = Journal.For_testing.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path ~before_retire:hook
        |> journal_value "guarded retirement discovery" in
    let path, bytes = !original |> Option.get in
    let replacement_bytes, inode = !replacement |> Option.get in
    check int "changed marker was not retired by stale proof" 0 report.retired;
    check bool "changed marker is reported" true (report.failures <> []);
    check string "actual replacement bytes retained" replacement_bytes (read path);
    check int "actual replacement inode retained" inode (Unix.lstat path).st_ino;
    let denied = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "changed authority remains visible" in
    check int "malformed or foreign authority remains unretired" 0 denied.retired;
    check bool "malformed or foreign authority remains refused" true (denied.failures <> []);
    write path bytes;
    let settled = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "restored exact authority retirement" in
    check int "fresh validated terminal proof retires restored marker" 1 settled.retired;
    check int "normal retirement has no failure" 0 (List.length settled.failures);
    let empty = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "retained infrastructure discovery" in
    check int "retired marker is not a pending marker" 0 empty.inspected;
    check int "retired marker discovery has no failure" 0 (List.length empty.failures);
    let lock_path = Fs_compat.private_jsonl_lock_path path in
    check bool "retirement leaves the lock sibling" true (Sys.file_exists lock_path);
    Unix.chmod lock_path 0o000;
    let skipped = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "orphaned lock discovery" in
    check int "orphaned lock is not a pending marker" 0 skipped.inspected;
    check int "orphaned lock is skipped without validation" 0 (List.length skipped.failures);
    Unix.chmod lock_path 0o600))
    [`Physical_foreign; `Physical_malformed; `Same_inode_same_length]

let test_pending_marker_retirement_settlement () =
  List.iter (fun failure -> with_workspace (fun _env sw base_path ->
    let prepared = prepare base_path in
    let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
      Executor.dispatch_result (success base_path node "original-profile") in
    let submission = submit base_path sw prepared dispatch |> accepted in
    ignore (await base_path submission);
    let directory = Filename.concat (Filename.concat
        (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests") "prepared_continuations" in
    let filename = Digestif.SHA256.(digest_string submission.request.request_id |> to_hex) ^ ".json" in
    let path = Filename.concat directory filename in
    let expected = Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
        |> require "actual terminal marker snapshot" in
    let first_close = ref true in
    let io : Fs_compat.private_jsonl_transaction_io_for_testing =
      {before_sync_parent=(fun _ -> match failure with
        | `Parent_sync -> raise (Unix.Unix_error (Unix.EIO, "fsync", "retired-marker-parent"))
        | `Close -> ());
       close_fd=(fun fd -> Unix.close fd;
         match failure with
         | `Close when !first_close -> first_close := false;
           raise (Unix.Unix_error (Unix.EIO, "close", "retired-marker-data"))
         | `Close | `Parent_sync -> ())} in
    let outcome = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
        ~io path ~expected in
    (match failure, outcome with
     | `Close, _ ->
       let receipt = outcome |> Fs_compat.private_jsonl_cursor_success_receipt
           |> require "known removal survives descriptor settlement failure" in
       check bool "known primary removal is missing" true
         (Fs_compat.Private_jsonl_cursor.is_missing receipt.value);
       check bool "descriptor settlement failure remains evidence" true
         (Option.is_some receipt.settlement_error)
     | `Parent_sync, Error (Fs_compat.Private_jsonl_operation_failed
         {operation=Fs_compat.Sync_removal_parent;_}) -> ()
     | `Parent_sync, _ -> fail "parent durability failure was not returned");
    check bool "unlink actually occurred" false (Sys.file_exists path);
    let report = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "post-settlement discovery" in
    check int "settled marker is not synthesized by lock validation" 0 report.inspected;
    check int "settled marker discovery has no failure" 0 (List.length report.failures);
    let lock_path = Fs_compat.private_jsonl_lock_path path in
    check bool "settlement leaves the lock sibling" true (Sys.file_exists lock_path);
    Unix.chmod lock_path 0o000;
    let skipped = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path |> journal_value "orphaned lock discovery" in
    check int "orphaned lock is not synthesized by lock validation" 0 skipped.inspected;
    check int "orphaned lock is skipped without validation" 0 (List.length skipped.failures);
    Unix.chmod lock_path 0o600))
    [`Close; `Parent_sync]

let launch_input = `Assoc ["argv", `List [`String "fixture-program"]]
let make_launch_plan () =
  Plan.create ~descriptors:(List.map descriptor ["keeper_job_start"])
    ~branch_failure_policy:Plan.Continue_independent
    [Plan.node ~id:(node_id "launcher") ~tool_name:"keeper_job_start"
       ~input:(Plan.Json_template.literal launch_input) ()]
  |> require "valid owned launch plan"
let launch_invocation_fixture absolute_turn =
  { Journal.trace_id = "launch-trace-fixture"
  ; turn_ref = Ids.Turn_ref.make ~trace_id:"launch-trace-fixture" ~absolute_turn
  ; keeper_turn_id = Some absolute_turn }
let launch_success (node : Plan.node) =
  Executor.dispatch_result
    (Tool_result.make_ok ~tool_name:node.tool_name ~start_time:(Tool_timing.start ())
       ~data:(`Assoc
         [ "job_id", `String "00000000-0000-7777-8000-000000000001"
         ; "status", `String "running"
         ; "result_ready", `Bool false
         ; "reconciliation", `Assoc [ "state", `String "not_observed"; "reason", `Null ]
         ; "source", `Assoc
             [ "task_id", `Null
             ; "turn_ref", `String "launch-trace-fixture#41"
             ; "tool_use_id", `String "fixture-launch"
             ; "trace_id", `String "launch-trace-fixture"
             ; "keeper_turn_id", `Int 41 ]
         ; "phase", `String "running"
         ; "cancel_requested", `Bool false
         ; "cleanup", `String
             (Masc.Keeper_owned_job_cleanup_state.to_string Resources_retained)
         ; "artifacts", `List []
         ; "detail", `Null
         ; "container_id", `Null
         ; "exit_code", `Null ])
       ())
let check_recheck_identity label expected replay =
  check string (label ^ " trace") expected.Journal.trace_id replay.Journal.invocation.trace_id;
  check int (label ^ " absolute turn") (Ids.Turn_ref.absolute_turn expected.turn_ref)
    (Ids.Turn_ref.absolute_turn replay.invocation.turn_ref);
  check string (label ^ " turn trace") (Ids.Turn_ref.trace_id expected.turn_ref)
    (Ids.Turn_ref.trace_id replay.invocation.turn_ref)

let test_interrupted_launch_replays_with_recorded_identity () = with_workspace (fun _env sw base_path ->
  let prepared = prepare ~plan:(make_launch_plan ()) base_path in
  let recorded = launch_invocation_fixture 41 in
  let entered, enter = Eio.Promise.create () and never, _ = Eio.Promise.create () in
  let original_occurrence = ref None in
  let dispatch ?launch_replay:_ ~tool_use_id ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    if node_name node = "launcher" then (
      original_occurrence := Some tool_use_id;
      Eio.Promise.resolve enter (); Eio.Promise.await never);
    launch_success node in
  let first = submit ~launch_invocation_of:(fun () -> Some recorded) base_path sw prepared dispatch
    |> accepted in
  Eio.Promise.await entered;
  (match Async.cancel ~base_path ~caller:keeper first.request.request_id with
   | Cancellation_requested Durably_committed -> () | _ -> fail "owned cancellation not durable");
  (match (await base_path first).status with
   | Cancelled _ -> () | _ -> fail "cancelled launch worker has no canonical terminal");
  (match Journal.lookup first.worker ~node_id:(node_id "launcher") ~tool_name:"keeper_job_start" ~input:launch_input with
   | Ok (Journal.Recheck_launch replay) ->
     check string "interrupted attempt preserves its occurrence" (Option.get !original_occurrence)
       replay.Journal.tool_use_id;
     check_recheck_identity "interrupted attempt" recorded replay
   | Ok _ -> fail "interrupted launch leaf did not authorize a launch replay"
   | Error error -> failf "interrupted launch lookup: %s" (Journal.error_to_string error));
  (* A later owner derives a different ambient identity. The replay must still
     carry the identity recorded on the durable occurrence. *)
  let replay_seen = ref None and calls = ref [] in
  let resume ?launch_replay ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    replay_seen := launch_replay;
    calls := node_name node :: !calls;
    launch_success node in
  let second = submit ~launch_invocation_of:(fun () -> Some (launch_invocation_fixture 52))
      base_path sw prepared resume |> accepted in
  ignore (await base_path second);
  check (list string) "interrupted launch leaf redispatches" ["launcher"] !calls;
  (match !replay_seen with
   | Some replay ->
     check string "resume replays the original occurrence" (Option.get !original_occurrence)
       replay.Journal.tool_use_id;
     check_recheck_identity "resume carries the recorded identity, not the ambient one" recorded replay
   | None -> fail "replayed launch dispatch carried no recorded invocation");
  (match executed second with
   | Ok rows ->
     let row = node_result "launcher" rows in
     check bool "replayed launch settles fresh" true (row.Executor.execution_origin = Executor.Fresh_dispatch);
     check string "replayed launch keeps the original occurrence join key" (Option.get !original_occurrence)
       row.Executor.tool_use_id
   | Error _ -> fail "replayed launch leaf did not complete");
  check_completion base_path prepared second)

let test_unknown_launch_effect_replays_with_recorded_identity () = with_workspace (fun _env sw base_path ->
  let prepared = prepare ~plan:(make_launch_plan ()) base_path in
  let recorded = launch_invocation_fixture 41 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~(node : Plan.node) ~descriptor:_ ~schedule:_ ~input:_ () =
    Executor.dispatch_result ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
      (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Runtime_failure
         ~effect_disposition:Tool_result.Effect_outcome_unknown
         ~start_time:(Tool_timing.start ()) "lost reply around the launch effect") in
  let first = submit ~launch_invocation_of:(fun () -> Some recorded) base_path sw prepared dispatch
    |> accepted in
  ignore (await base_path first);
  (match Journal.lookup first.worker ~node_id:(node_id "launcher") ~tool_name:"keeper_job_start" ~input:launch_input with
   | Ok (Journal.Recheck_launch replay) -> check_recheck_identity "unknown launch effect" recorded replay
   | Ok _ -> fail "unknown launch effect did not authorize a launch replay"
   | Error error -> failf "unknown launch lookup: %s" (Journal.error_to_string error));
  let calls = ref 0 in
  let resume ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    incr calls; launch_success node in
  let second = submit ~launch_invocation_of:(fun () -> Some recorded) base_path sw prepared resume
    |> accepted in
  ignore (await base_path second);
  check int "unknown launch effect redispatches exactly once" 1 !calls;
  (match executed second with
   | Ok _ -> ()
   | Error _ -> fail "replayed unknown launch effect did not complete");
  check_completion base_path prepared second)

let test_launch_replay_mode_survives_pre_effect_refusal () =
  List.iter (fun unknown -> with_workspace (fun _env sw base_path ->
    let prepared = prepare ~plan:(make_launch_plan ()) base_path in
    let recorded = launch_invocation_fixture 41 in
    let phase = if unknown then Tool_result.Effect_outcome_unknown else Tool_result.Proven_pre_effect in
    let first_dispatch ?launch_replay:_ ~tool_use_id:_ ~(node : Plan.node) ~descriptor:_ ~schedule:_ ~input:_ () =
      Executor.dispatch_result ~failure_effect_disposition:phase
        (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Runtime_failure
           ~effect_disposition:phase ~start_time:(Tool_timing.start ()) "first launch observation") in
    let first = submit ~launch_invocation_of:(fun () -> Some recorded)
        base_path sw prepared first_dispatch |> accepted in
    ignore (await base_path first);
    let calls = ref 0 in
    let resume ?launch_replay ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
      incr calls;
      check bool "only the original unknown effect requires Existing-only replay" unknown (Option.is_some launch_replay);
      launch_success node in
    let denied = submit ~launch_invocation_of:(fun () -> Some recorded)
        ~admit_node:(fun ~node:_ -> Error Executor.{detail="explicit admission refusal";data=`Assoc []})
        base_path sw prepared resume |> accepted in
    ignore (await base_path denied);
    check int "supported admission API refuses before producer dispatch" 0 !calls;
    (match Journal.lookup denied.worker ~node_id:(node_id "launcher")
        ~tool_name:"keeper_job_start" ~input:launch_input with
     | Ok (Journal.Recheck_launch original) when unknown ->
         check_recheck_identity "pre-effect refusal preserves original unknown launch" recorded original
     | Ok Journal.Dispatch when not unknown -> ()
     | Ok _ -> fail "pre-effect refusal changed the canonical launch mode"
     | Error error -> fail (Journal.error_to_string error));
    let restored = submit ~launch_invocation_of:(fun () -> Some (launch_invocation_fixture 63))
        base_path sw prepared resume |> accepted in
    ignore (await base_path restored);
    ignore (executed restored |> require "restored launch admission completes");
    check int "only restored admission reaches the producer" 1 !calls)) [true;false]

let test_launch_leaf_refuses_incomplete_invocation_identity () = with_workspace (fun _env sw base_path ->
  let prepared = prepare ~plan:(make_launch_plan ()) base_path in
  let calls = ref 0 in
  let dispatch ?launch_replay:_ ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ () =
    incr calls; launch_success node in
  let refused = function
    | Error {Executor.cause = Executor.Tool_did_not_complete row; _} ->
      check bool "incomplete identity refuses before dispatch" true
        (row.Executor.execution_origin = Executor.Dispatch_refused);
      check_json "refusal names the incomplete launch identity"
        (`String "launch_invocation_incomplete")
        (Tool_result.to_json row.Executor.result |> Yojson.Safe.Util.member "data" |> Yojson.Safe.Util.member "kind")
    | Ok _ | Error _ -> fail "incomplete launch identity was admitted" in
  let first = submit base_path sw prepared dispatch |> accepted in
  ignore (await base_path first);
  check int "launch without identity derivation never dispatches" 0 !calls;
  refused (executed first);
  (* An explicit derivation that cannot complete is refused the same way, and
     the refusal happens before any durable attempt is recorded. *)
  let second = submit ~launch_invocation_of:(fun () -> None) base_path sw prepared dispatch |> accepted in
  ignore (await base_path second);
  check int "incomplete derived identity never dispatches" 0 !calls;
  refused (executed second);
  (match Journal.lookup second.worker ~node_id:(node_id "launcher") ~tool_name:"keeper_job_start" ~input:launch_input with
   | Ok Journal.Dispatch -> ()
   | Ok _ | Error _ -> fail "identity refusal left a durable attempt behind"))

(* The actual create hook writes only canonical activity. Exercise that
   producer, both current source stores and the strict TUI page consumer. *)
let test_task_history_current_sources () = with_workspace (fun _env _sw base_path ->
  let module History = Masc.Task.History_page in
  let module Decode = Masc.Tui_decode_task_inspection in
  let config=Workspace.default_config base_path in
  Masc.Workspace_metric_hooks.install ();
  let created=Workspace.add_task_with_result ~created_by:keeper config
    ~title:"Canonical original task" ~priority:3 ~description:"original source" |> require "actual task create" in
  let task_id=created.task_id in
  let page result=match result with Ok page -> page | Error _ -> fail "current Task history unavailable" in
  let first=History.read ~config ~task_id ~max_events:1 () |> page in
  check bool "actual creation is readable without a generic event copy" true
    (List.exists (fun row -> Json_util.get_string row "source"=Some "activity-events"
      && Json_util.get_string (Yojson.Safe.Util.member "event" row) "kind"=Some "task.created") first.events);
  let decoded=Decode.history_page ~request:(Decode.history_first ~task_id ~limit:1) (History.to_json first)
    |> require "actual canonical TUI decoder" in
  check bool "original lifecycle actor and physical provenance survive" true
    (List.exists (fun (event:Masc.Tui_decode.task_history_event) ->
      event.th_actor=Some keeper && event.th_label="task.created"
      && Option.is_some event.th_origin) decoded.history_events);
  let emit kind = ignore (Masc.Activity_graph.emit config ~kind
    ~actor:(Masc.Activity_graph.entity ~kind:"agent" keeper)
    ~subject:(Masc.Activity_graph.entity ~kind:"task" task_id)
    ~payload:(`Assoc ["task_id",`String task_id]) ~tags:["task"] ()) in
  emit "task.started";
  let first=History.read ~config ~task_id ~max_events:1 () |> page in
  let cursor=first.next_cursor |> Option.get in
  let audit=Filename.concat (Workspace.masc_dir config) "events" in
  let absent=not (Sys.file_exists audit) in
  Workspace_utils_ops.log_event config (`Assoc ["task_id",`String task_id;"type",`String "task_transition";
    "ts",`String "2026-10-21T00:00:00Z";"actor",`String keeper;
    "handoff_context",`Assoc ["summary",`String "audit original handoff"]]);
  if absent then (match History.read ~config ~task_id ~max_events:1 ~cursor () with
    | Error History.Source_changed -> () | _ -> fail "newly created source entered a captured absent source");
  let first=History.read ~config ~task_id ~max_events:1 () |> page in
  let cursor=first.next_cursor |> Option.get in
  let cursor=History.cursor_of_string (History.cursor_to_string cursor) |> require "two-source cursor" in
  emit "task.after-capture";
  Workspace_utils_ops.log_event config (`Assoc ["task_id",`String task_id;"type",`String "audit-after-capture"]);
  let rec earlier cursor acc =
    let next=History.read ~config ~task_id ~max_events:1 ~cursor () |> page in
    let acc=acc @ next.events in match next.next_cursor with None -> acc | Some cursor -> earlier cursor acc in
  let all=first.events @ earlier cursor [] in
  let rows=Decode.history ~task_id (`List all) |> require "two-source original decode" in
  check bool "both original active stores retained" true
    (List.exists (fun row -> Json_util.get_string row "source"=Some "events") all
     && List.exists (fun row -> Json_util.get_string row "source"=Some "activity-events") all);
  check bool "later appends from either source excluded" false
    (List.exists (fun row -> let raw=Yojson.Safe.Util.member "event" row in
      Json_util.get_string raw "kind"=Some "task.after-capture"
      || Json_util.get_string raw "type"=Some "audit-after-capture") all);
  check bool "audit handoff survives alongside original lifecycle" true
    (List.exists (fun (event:Masc.Tui_decode.task_history_event) -> event.th_note=Some "audit original handoff") rows);
  let canonical=List.find (fun row -> Json_util.get_string row "source"=Some "activity-events") all in
  let corrupt=match canonical with
    | `Assoc fields ->
      let raw=List.assoc "event" fields in
      let raw=match raw with `Assoc fields -> `Assoc (("context",`Assoc ["task_id",`String "foreign-task"])::List.remove_assoc "context" fields)
        | _ -> fail "canonical producer shape" in
      `Assoc (("event",raw)::List.remove_assoc "event" fields)
    | _ -> fail "physical observation shape" in
  (match Decode.history ~task_id (`List [corrupt]) with Error _ -> () | Ok _ -> fail "conflicting nested task was accepted");
  (match Decode.history ~task_id (`List [canonical;canonical]) with Error _ -> () | Ok _ -> fail "same physical source row repeated");
  let origin=Json_util.get_string canonical "file" |> Option.get in
  let path=Filename.concat (Workspace.masc_dir config) origin in
  let original=read path in
  let parked=Filename.concat base_path "physical-activity-original" in
  Unix.rename path parked;
  Fun.protect ~finally:(fun () -> Unix.unlink path; Unix.rename parked path) (fun () ->
    write path original;
    match History.read ~config ~task_id ~max_events:1 ~cursor () with
    | Error History.Source_changed -> () | _ -> fail "replaced canonical source advanced original cursor"))

let () = match Array.to_list Sys.argv with
  | [_; "--resume-child"; base_path; run_id] -> child_resume base_path run_id
  | [_; "--refuse-active-child"; base_path; run_id] -> child_refuse_active base_path run_id
  | [_; "--lose-before-first-wait"; base_path; run_id; mode] -> child_first_loss base_path run_id mode
  | _ -> Alcotest.run "prepared async execution journal"
      ["continuation", [
        test_case "canonical creation and both current Task history sources" `Quick test_task_history_current_sources;
        test_case "restart reuses completed data and occurrence" `Quick test_restart_reuses_completed;
        test_case "source and plan identity refuse unsafe dispatch" `Quick test_source_and_plan_identity;
        test_case "original source observations freeze once without late backfill" `Quick test_source_observation_is_frozen_at_creation;
        test_case "resumed Ask never borrows missing source from current run" `Quick
          test_resumed_ask_uses_only_original_source_evidence;
        test_case "unavailable original evidence refuses dispatch" `Quick test_unavailable_evidence;
        test_case "canonical ownership, concurrent resume and stale worker" `Quick test_owned_transport_and_race;
        test_case "unknown, post-effect and deferred results are not replayed" `Quick test_unproven_outcomes_refuse_replay;
        test_case "foreign owned-job wait receipt cannot authorize rechecking" `Quick test_foreign_job_wait_receipt_is_rejected;
        test_case "owned cancellation retries only declared readonly unfinished work" `Quick test_cancelled_readonly_attempt;
        test_case "public prepare run resume preserves original task" `Quick test_public_run_resume_keeps_original_task;
        test_case "first Lost effectful attempt retains its marker" `Quick (test_first_loss_retains_unproven_effects "attempting");
        test_case "first Lost unknown outcome retains its marker" `Quick (test_first_loss_retains_unproven_effects "unknown");
        test_case "first Lost post-effect failure retains its marker" `Quick (test_first_loss_retains_unproven_effects "post_effect");
        test_case "first Lost unowned defer retains its marker" `Quick (test_first_loss_retains_unproven_effects "deferred");
        test_case "first Lost readonly attempt still resumes" `Quick (test_first_loss_retains_unproven_effects "readonly");
        test_case "pending marker retirement retains physical and same-inode replacements" `Quick test_pending_marker_retirement_rejects_replacement;
        test_case "pending marker retirement preserves settlement and durability failures" `Quick test_pending_marker_retirement_settlement;
        test_case "exact Queued admission and matched inventory read measurements" `Quick test_exact_queued_admission;
        test_case "interrupted launch leaf replays with its recorded identity" `Quick test_interrupted_launch_replays_with_recorded_identity;
        test_case "unknown launch effect replays with its recorded identity" `Quick test_unknown_launch_effect_replays_with_recorded_identity;
        test_case "launch replay mode survives a later pre-effect admission refusal" `Quick test_launch_replay_mode_survives_pre_effect_refusal;
        test_case "launch leaf refuses incomplete invocation identity" `Quick test_launch_leaf_refuses_incomplete_invocation_identity]]
