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
let prepare ?plan base_path =
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
    ; source_task_id = Some "original-source-task" } in
  {draft; source; journal = Journal.prepare ~base_path source |> journal_value "prepare journal"}
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
    ?(before_execute = fun _ -> ()) ?plan ?observe base_path sw prepared dispatch =
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
            ~run_id:(Plan.Run_id.fresh ()) ~journal:worker ~dispatch ?observe_node_result:observe () in
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
let initial_dispatch base_path phase ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
  if node_name node = "consumer" then failing phase node
  else Executor.dispatch_result (success base_path node "original-profile")
let resume_dispatch base_path calls ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
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
let no_dispatch calls ~tool_use_id:_ ~node:_ ~descriptor:_ ~schedule:_ ~input:_ =
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
      ~tool_use_id:"original-consumer" ~readonly:true |> journal_value "record input identity");
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
  let discovery = Journal.pending_continuations ~base_path |> journal_value "pre-dispatch discovery" in
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
      ~tool_use_id:"pre-resume-occurrence" ~readonly:true |> journal_value "original attempt" in
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
    let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
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
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
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
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
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

let test_public_run_resume_keeps_original_task () = with_workspace (fun env sw base_path ->
  let module Tools = Masc.Keeper_tool_composition_surface in
  let module Call_log = Masc.Keeper_tool_call_log in
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  Call_log.init ~base_path ();
  let config = Workspace.default_config base_path in
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String keeper; "activation_mode", `String "manual"])
      |> require "public keeper metadata" in
  let ctx_snapshot = Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"public continuation fixture" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider; keeper_name = keeper} in
  let cell = Call_log.create_turn_ctx_cell () in
  Call_log.set_turn_context ~cell ~agent_name:keeper ~turn:42 ~keeper_turn_id:1 ~task_id:"task-A" ();
  let tools = Tools.make_tools ~capability_surface:(surface base_path) ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_ctx_cell:cell ~clock:(Eio.Stdenv.clock env) () in
  let invoke ~turn ~id name input =
    let tool = List.find_map (fun (tool, _, _) ->
        if tool.Agent_core.Tool.schema.name = name then Some tool else None) tools
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
  Call_log.set_turn_context ~cell ~agent_name:keeper ~turn:43 ~keeper_turn_id:2 ~task_id:"task-B" ();
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
  let projected = Masc.Keeper_composition_completion_result.read ~base_path ~keeper_name:keeper completion
      |> Masc.Keeper_composition_completion_result.to_json in
  check_json "public wake carries task A" (`String "task-A") (projected |> member "source" |> member "source_task_id"))

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
      (fun ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ ->
        incr calls; Executor.dispatch_result (success base_path node "original-profile"))
    |> accepted in
  ignore (await base_path submission);
  ignore (executed submission |> require "exact-proof admission executes original plan");
  check int "real admitted plan dispatches each original node once" 3 !calls;
  exact submission.request.request_id |> reject "terminal request cannot be re-admitted"
    (function Async.Canonical_queued_not_queued (Async.Done _) -> true | _ -> false))

let () = match Array.to_list Sys.argv with
  | [_; "--resume-child"; base_path; run_id] -> child_resume base_path run_id
  | [_; "--refuse-active-child"; base_path; run_id] -> child_refuse_active base_path run_id
  | _ -> Alcotest.run "prepared async execution journal"
      ["continuation", [
        test_case "restart reuses completed data and occurrence" `Quick test_restart_reuses_completed;
        test_case "source and plan identity refuse unsafe dispatch" `Quick test_source_and_plan_identity;
        test_case "unavailable original evidence refuses dispatch" `Quick test_unavailable_evidence;
        test_case "canonical ownership, concurrent resume and stale worker" `Quick test_owned_transport_and_race;
        test_case "unknown, post-effect and deferred results are not replayed" `Quick test_unproven_outcomes_refuse_replay;
        test_case "foreign owned-job wait receipt cannot authorize rechecking" `Quick test_foreign_job_wait_receipt_is_rejected;
        test_case "owned cancellation retries only declared readonly unfinished work" `Quick test_cancelled_readonly_attempt;
        test_case "public prepare run resume preserves original task" `Quick test_public_run_resume_keeps_original_task;
        test_case "exact Queued admission and matched inventory read measurements" `Quick test_exact_queued_admission]]
