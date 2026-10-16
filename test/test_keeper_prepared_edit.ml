open Alcotest
open Masc

module FS = Keeper_tool_filesystem_runtime

let get = function Ok value -> value | Error detail -> fail detail
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun output -> output_string output bytes)
;;

let rec remove path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
;;

let fixture operation =
  let base = Filename.temp_file "masc-prepared-edit-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let base = Unix.realpath base in
  Fun.protect ~finally:(fun () -> remove base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  Masc_test_deps.ensure_rng_initialized ();
  let config = Workspace.default_config base in
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "prepared-edit"; "trace_id", `String "prepared-edit-trace"]) |> get in
  let meta = {meta with sandbox_profile = Keeper_types_profile.Docker} in
  let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p root;
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs ~registry_root:base
  @@ fun registry ->
  let recovery : Keeper_publication_recovery_availability.turn_context =
    {provider = Masc_test_deps.publication_recovery_provider registry; keeper_name = meta.name} in
  operation env sw config meta recovery root
;;

let args path before after =
  `Assoc ["path", `String path; "mode", `String "patch"
         ; "old_string", `String before; "new_string", `String after]
;;

let prepare sw config meta input =
  match FS.prepare_edit ~sw ~config ~meta ~args:input with
  | Ok (Some prepared) -> prepared
  | Ok None -> fail "existing regular Edit resource was not prepared"
  | Error error -> fail (FS.edit_preparation_error_to_execution error).raw_output
;;

let consume config meta recovery prepared input =
  FS.handle_file_write_with_outcome ~turn_sandbox_factory:None ~config ~meta
    ~publication_recovery:recovery ?prepared_edit:prepared ~args:input ()
;;

let completed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ -> fail result.raw_output
;;

let failed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Failed _ -> ()
  | Tool_result.Completed () | Tool_result.Deferred () -> fail "changed prepared authority performed an Edit"
;;

let execute ?(hooks = Agent_core.Hooks.empty) env tools calls =
  let agent = Agent_core.Agent.create ~tools ~net:env#net
      ~config:(Agent_core.Types.default_config ~model:"fixture") () in
  let options = Agent_core.Agent.options agent in
  match Agent_core.Agent_tools.execute_tools ~context:(Agent_core.Agent.context agent)
      ~tools ~hooks ~event_bus:options.event_bus ~tracer:options.tracer
      ~agent_name:(Agent_core.Agent.state agent).config.name ~turn_count:2
      ~usage:(Agent_core.Agent.state agent).usage calls with
  | Ok report -> report.completed_results
  | Error _ -> fail "Edit batch failed outside its tool results"
;;

let dispatch ?hooks env tools calls =
  let rows = execute ?hooks env tools calls in
    List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
      match row.outcome with
      | Agent_core.Types.Tool_succeeded -> ()
      | Tool_failed _ -> fail row.content) rows;
  rows
;;

let batch env config meta recovery inputs =
  let to_sdk result = match result.Keeper_tool_execution.disposition with
    | Tool_result.Completed () ->
      Ok {Agent_core.Types.content = result.raw_output; content_blocks = None; _meta = None}
    | Tool_result.Deferred () | Tool_result.Failed _ ->
      Error {Agent_core.Types.message = result.raw_output; recoverable = false
            ; error_class = Some Agent_core.Types.Unknown} in
  let descriptor = Agent_core.Tool.ordinary_descriptor_scoped
      ~call_effect:(fun _ -> Agent_core.Tool.Effect_possible) ~prepare:(fun ~sw input ->
    match FS.prepare_edit ~sw ~config ~meta ~args:input with
    | Error error -> FS.edit_preparation_error_to_execution error |> to_sdk |> Result.map (fun _ -> None)
    | Ok None -> Ok None
    | Ok (Some prepared) ->
      (match FS.prepared_edit_scopes prepared with
       | [] -> fail "prepared Edit has no occupied resource"
       | scope :: additional_scopes ->
         Ok (Some (Agent_core.Tool.scoped_call ~scope ~additional_scopes
           (fun _ input -> consume config meta recovery (Some prepared) input |> to_sdk))))) in
  let schema = Agent_core.Types.tool_schema_of_input_schema ~name:"fixture_edit"
      ~description:"Exercise the actual existing-file Edit producer."
      ~input_schema:(`Assoc ["type", `String "object"]) () |> get in
  let tool = Agent_core.Tool.of_schema ~descriptor schema
      (fun _ input -> consume config meta recovery None input |> to_sdk) in
  let calls = List.mapi (fun index input -> Agent_core.Types.ToolUse
      {id = "edit-" ^ string_of_int index; name = "fixture_edit"; input}) inputs in
  dispatch env [tool] calls
;;

let public_bundle ?snapshot ?(sourceful = true) ?(with_read = false) env sw config meta recovery operation =
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some config.Workspace.base_path) @@ fun () ->
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw Config_dir_resolver.reset;
  ignore (Workspace.init config ~agent_name:(Some "public-edit-operator") : string);
  let references = match snapshot with
    | None -> []
    | Some snapshot -> Skill_catalog_snapshot.entries snapshot |> List.map Skill_catalog_snapshot.entry_reference in
  let task = Workspace.add_task_with_result ~created_by:"public-edit-operator" ~skills:references config
      ~title:"Edit the original files" ~priority:1 ~description:"Keep the original Task and trace."
      |> function Ok value -> value | Error error -> fail (Workspace.add_task_error_to_string error) in
  Workspace.claim_task_r config ~agent_name:meta.Keeper_meta_contract.name ~task_id:task.task_id ()
    |> (function Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
  let meta = {meta with current_task_id = Some (Keeper_id.Task_id.of_string task.task_id |> get)
                     ; sandbox_image = Some "base"} in
  Masc_test_deps.write_sandbox_image_catalog ~base_path:config.base_path
    ["base", "masc-sandbox-base:fixture-prepared-edit"];
  Masc_test_deps.init_unified_tool_registry ();
  Keeper_tool_call_log.init ~base_path:config.base_path ();
  let cell = Keeper_tool_call_log.create_turn_ctx_cell () in
  Keeper_tool_call_log.set_turn_context ~cell ~agent_name:meta.name ~task_id:task.task_id
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~keeper_turn_id:13 ~turn:2 ();
  let descriptor = match Keeper_tool_descriptor.find_id "agent.edit_file" with
    | Some value -> value | None -> fail "canonical public Edit descriptor is absent" in
  let descriptors = if not with_read then [descriptor] else
    match Keeper_tool_descriptor.find_id "agent.read_file" with
    | Some read -> [descriptor; read]
    | None -> fail "canonical public Read descriptor is absent" in
  let snapshot = match snapshot with
    | Some snapshot -> snapshot
    | None -> Skill_catalog_snapshot.config_unreadable ~detail:"tool-only fixture has no shared Skill source" in
  let catalog, diagnostics = Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  check int "published Edit Skills project without errors" 0 (List.length diagnostics);
  let selection = Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:task.task_id references
      |> function Ok value -> value | Error error -> fail (Keeper_task_skill_turn.error_to_string error) in
  let skill_activation_context = if references = [] then None else
    Some (Keeper_skill_activation_recorder.make ~trace_id:meta.runtime.trace_id
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ~absolute_turn:13)
      ~runtime_id:(fun () -> Some "fixture.resource-edit")
      ~snapshot_revision:(Skill_catalog_snapshot.snapshot_revision snapshot) ~task_selection:selection
      |> function Ok value -> value | Error error -> fail (Keeper_skill_activation_recorder.error_to_string error)) in
  let surface = Keeper_capability_surface.create_with_descriptors ~tool_descriptors:descriptors
      ~tool_deny:[] ~sandbox_profile:meta.sandbox_profile ~skill_names:None
      ~global_skill_catalog:catalog
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot ~descriptors snapshot)
      ~task_skills:(Keeper_task_skill_turn.skills selection) in
  let causal = Keeper_gate_causal_context.create ~turn_id:(Some 13)
      ~initial:(`Assoc ["task_id", `String task.task_id]) in
  let bundle = Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface ~config ~meta
      ~publication_recovery:recovery ~capability_surface:surface ~clock:env#clock ~gate_context:causal
      ?skill_activation_context
      ?turn_ctx_cell:(if sourceful then Some cell else None)
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"public Edit feature fixture") () in
  Eio.Switch.on_release sw bundle.cleanup;
  operation meta task.task_id cell causal bundle
;;

let public_args path before after =
  `Assoc ["file_path", `String path; "old_string", `String before; "new_string", `String after]
;;

let public_calls inputs = List.mapi (fun index input -> Agent_core.Types.ToolUse
    {id = "public-edit-" ^ string_of_int index; name = "Edit"; input}) inputs
;;

let publish_edit_skills ?(two_nodes = false) ?(ordered = false)
    ?(third_node = false) ?(continue_independent = false) ?read_path_param sw config =
  let source_config = "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"edit-fixture\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n" in
  let document name =
    let first = ["file_path", "file_path"; "old_string", "old_string"; "new_string", "new_string"] in
    let second = ["file_path", "other_path"; "old_string", "other_old"; "new_string", "other_new"] in
    let third = ["file_path", "later_path"; "old_string", "later_old"; "new_string", "later_new"] in
    let params = List.map snd
      (first @ (if two_nodes then second else []) @ if third_node then third else []) in
    let params = match read_path_param with
      | Some param when not (List.mem param params) -> params @ [param]
      | Some _ | None -> params in
    let node ?(after = []) id bindings =
      Printf.sprintf "[[compositions.nodes]]\nid = %S\ntool = \"Edit\"\nafter = [%s]\n[compositions.nodes.input]\nkind = \"object\"\n"
        id (String.concat ", " (List.map (Printf.sprintf "%S") after))
      ^ String.concat "" (List.map (fun (field, param) -> Printf.sprintf
          "[[compositions.nodes.input.fields]]\nname = %S\n[compositions.nodes.input.fields.value]\nkind = \"param\"\nname = %S\n" field param) bindings) in
    Printf.sprintf "---\nname: %s\ndescription: Apply the selected exact patch\n---\n```toml composition\n[[compositions]]\nname = %S\nexecution = \"inline\"\n" name name
    ^ (if continue_independent then "branch_failure_policy = \"continue_independent\"\n" else "")
    ^ String.concat "" (List.map (fun name -> Printf.sprintf
        "[[compositions.params]]\nname = %S\ntype = \"string\"\ndescription = \"Original patch input\"\n" name) params)
    ^ node "patch" first
    ^ (if two_nodes then node ~after:(if ordered then ["patch"] else []) "other-patch" second else "")
    ^ (if third_node then node "later-patch" third else "")
    ^ (match read_path_param with
       | None -> ""
       | Some param ->
         "[[compositions.nodes]]\nid = \"read\"\ntool = \"Read\"\n[compositions.nodes.input]\nkind = \"object\"\n"
         ^ Printf.sprintf "[[compositions.nodes.input.fields]]\nname = \"file_path\"\n[compositions.nodes.input.fields.value]\nkind = \"param\"\nname = %S\n" param)
    ^ "```\n" in
  List.iter (fun name -> write (Filename.concat config.Workspace.base_path
      ("skills/" ^ name ^ "/SKILL.md")) (document name)) ["edit-left"; "edit-right"];
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:config.base_path
      |> function Ok value -> value | Error error -> fail (Config_dir_resolver.canonical_base_path_error_to_string error) in
  Eio.Switch.on_release sw (fun () -> Skill_catalog_snapshot_service.retire ~workspace);
  let snapshot = match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path = Filename.concat config.base_path ".masc/config/runtime.toml"; source_text = source_config}) with
    | Published value | Unchanged value -> value
    | Workspace_retired -> fail "published Edit Skill workspace retired" in
  check int "both exact Skill documents were published" 2 (List.length (Skill_catalog_snapshot.entries snapshot));
  check int "published documents have no source rejection" 0 (List.length (Skill_catalog_snapshot.rejections snapshot));
  Fs_compat.mkdir_p (Keeper_fs.keeper_session_dir config "prepared-edit-trace");
  snapshot
;;

let inline_calls bundle inputs = List.mapi (fun index input ->
  let name = "keeper_compose_edit-" ^ (if index = 0 then "left" else "right") in
  check bool "published Inline tool is in the actual bundle" true
    (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) bundle.Keeper_tools_agent_core.tools);
  Agent_core.Types.ToolUse {id = "inline-edit-" ^ string_of_int index; name; input}) inputs
;;

let two_patch_args left before after right other_before other_after =
  match public_args left before after with
  | `Assoc fields -> `Assoc (fields @ ["other_path", `String right;
      "other_old", `String other_before; "other_new", `String other_after])
  | _ -> fail "public patch fixture did not construct an object"
;;

let physical_leaves meta =
  Keeper_tool_call_log.read_recent ~keeper_name:meta.Keeper_meta_contract.name ()
  |> (function Ok rows -> rows | Error (Index_unavailable detail) -> fail detail)
  |> List.filter (fun row -> Yojson.Safe.Util.member "composition_node_id" row <> `Null)
;;

let test_one_inline_overlaps_its_disjoint_edits () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun meta task_id _cell causal bundle ->
  let left = Filename.concat root "one-parent/left" and right = Filename.concat root "one-parent/right" in
  write left "left-before"; write right "right-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
    (fun () -> dispatch env bundle.tools (inline_calls bundle
      [two_patch_args left "left-before" "left-after" right "right-before" "right-after"])) in
  check int "one outer Skill result" 1 (List.length rows);
  check int "both inner authorization boundaries overlapped" 2 !entered;
  check string "left actual bytes" "left-after" (read left);
  check string "right actual bytes" "right-after" (read right);
  let leaves = physical_leaves meta in
  check int "both inner handlers committed physical rows" 2 (List.length leaves);
  List.iter (fun row ->
    check string "original Task survives inner overlap" task_id
      Yojson.Safe.Util.(member "task_id" row |> to_string);
    check string "original parent invocation survives inner overlap" "inline-edit-0"
      Yojson.Safe.Util.(member "parent_tool_use_id" row |> to_string)) leaves;
  check int "both inner results join the original Gate aggregate" 2
    Yojson.Safe.Util.(member "completed_tool_calls"
      (Keeper_gate_causal_context.snapshot causal).snapshot |> to_list |> List.length)
;;

let test_one_inline_preserves_physical_conflicts () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let directory = Filename.concat root "inner-original" in
  let path = Filename.concat directory "file" and alias = Filename.concat root "inner-alias" in
  write path "first"; Unix.symlink directory alias;
  ignore (dispatch env bundle.tools (inline_calls bundle [two_patch_args path "first" "second"
    (Filename.concat alias "file") "second" "third"]));
  check string "alias conflict consumes real predecessor bytes" "third" (read path)
;;

let test_one_inline_preserves_explicit_dependency () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true ~ordered:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let left = Filename.concat root "dependent-left/file" and right = Filename.concat root "dependent-right/file" in
  write left "first"; write right "first";
  let entered = ref 0 in
  ignore (FS.For_testing.with_before_write_authorization (fun () ->
      incr entered;
      if !entered = 2 then check string "explicit successor sees committed predecessor"
        "second" (read left))
    (fun () -> dispatch env bundle.tools (inline_calls bundle
      [two_patch_args left "first" "second" right "first" "second"])));
  check int "both explicitly ordered real handlers entered" 2 !entered;
  check string "dependent right actual bytes" "second" (read right)
;;

let test_one_inline_failure_blocks_conflict_only () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true ~third_node:true
    ~continue_independent:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun meta _task _cell _causal bundle ->
  let left = Filename.concat root "failed-left/file" and right = Filename.concat root "surviving-right/file" in
  write left "first"; write right "first";
  let input = match two_patch_args left "missing" "failed" right "first" "second" with
    | `Assoc fields -> `Assoc (fields @ ["later_path", `String left;
        "later_old", `String "first"; "later_new", `String "must-not-land"])
    | _ -> fail "public patch fixture did not construct an object" in
  let rows = execute env bundle.tools (inline_calls bundle [input]) in
  (match rows with
   | [row] -> (match row.Agent_core.Agent_tools.outcome with
     | Agent_core.Types.Tool_failed _ -> ()
     | Tool_succeeded -> fail "failed inner patch became a successful outer Skill")
   | _ -> fail "one failed outer Skill was not settled");
  check string "failed predecessor and its resource successor wrote nothing" "first" (read left);
  check string "disjoint sibling still committed" "second" (read right);
  check int "failed and successful handlers retained, conflicted successor absent" 2
    (List.length (physical_leaves meta))
;;

let test_cancelled_inner_edits_release_for_next_invocation () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let left = Filename.concat root "cancel-inner-left/file" and right = Filename.concat root "cancel-inner-right/file" in
  write left "first"; write right "first";
  let input = two_patch_args left "first" "second" right "first" "second" in
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  (match Eio.Switch.run (fun child ->
    FS.For_testing.with_before_write_authorization (fun () ->
        incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
        Eio.Fiber.await_cancel ()) (fun () ->
      Eio.Fiber.fork ~sw:child (fun () ->
        ignore (dispatch env bundle.tools (inline_calls bundle [input])));
      Eio.Promise.await both;
      Eio.Switch.fail child Exit)) with
   | () -> fail "inner caller cancellation did not propagate"
   | exception Exit -> ());
  check string "cancelled left authorization wrote nothing" "first" (read left);
  check string "cancelled right authorization wrote nothing" "first" (read right);
  ignore (dispatch env bundle.tools [Agent_core.Types.ToolUse
    {id = "inline-after-cancel"; name = "keeper_compose_edit-left"; input}]);
  check string "new invocation can acquire left resource" "second" (read left);
  check string "new invocation can acquire right resource" "second" (read right)
;;

let test_published_inline_edits_overlap_and_retain_receipts () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun meta task_id _cell causal bundle ->
  let left = Filename.concat root "inline-left/file" and right = Filename.concat root "inline-right/file" in
  write left "left-before"; write right "right-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
      (fun () -> dispatch env bundle.tools
        (inline_calls bundle [public_args left "left-before" "left-after"; public_args right "right-before" "right-after"])) in
  check int "both published Inline leaves entered real authorization" 2 !entered;
  check string "Inline left actual bytes" "left-after" (read left);
  check string "Inline right actual bytes" "right-after" (read right);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "outer Inline wave contains both actual calls" 2
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows;
  let ledger = Keeper_tool_call_log.read_recent ~keeper_name:meta.name ()
      |> function Ok rows -> rows | Error (Index_unavailable detail) -> fail detail in
  let leaves = List.filter (fun row -> Yojson.Safe.Util.member "composition_node_id" row <> `Null) ledger in
  check int "both real leaves committed physical rows" 2 (List.length leaves);
  List.iter (fun row ->
    check string "Inline leaf keeps original Task" task_id Yojson.Safe.Util.(member "task_id" row |> to_string);
    check string "Inline leaf keeps original trace" (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      Yojson.Safe.Util.(member "trace_id" row |> to_string);
    List.iter (fun key -> check bool ("Inline leaf retains " ^ key) true
      (match Yojson.Safe.Util.member key row with `String value -> value <> "" | _ -> false))
      ["execution_id"; "composition_run_id"; "parent_tool_use_id"]) leaves;
  let activations = Keeper_skill_activation_ledger.load_existing ~config ~trace_id:meta.runtime.trace_id
      |> function
      | Ok (Some ledger) -> Keeper_skill_activation_ledger.activations ledger
      | Ok None -> fail "actual published Skill activation ledger is absent"
      | Error error -> fail (Keeper_skill_activation_ledger.store_error_to_string error) in
  check int "both exact published Skills activated" 2 (List.length activations);
  check (list string) "original outer invocations own activations" ["inline-edit-0"; "inline-edit-1"]
    (List.map (fun (activation : Keeper_skill_activation_ledger.activation) -> activation.skill_tool_use_id) activations
      |> List.sort String.compare);
  check int "both leaf results join the turn Gate aggregate" 2
    Yojson.Safe.Util.(member "completed_tool_calls" (Keeper_gate_causal_context.snapshot causal).snapshot |> to_list |> List.length)
;;

let test_published_inline_conflicts_keep_predecessor_bytes () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let path = Filename.concat root "inline-conflict/file" in
  write path "first";
  let rows = dispatch env bundle.tools
      (inline_calls bundle [public_args path "first" "second"; public_args path "second" "third"]) in
  check string "later published Skill consumes actual predecessor bytes" "third" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "conflicting outer Skills use separate waves" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_public_and_published_inline_share_conflict_order () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let path = Filename.concat root "direct-inline-conflict/file" in
  write path "first";
  let calls = public_calls [public_args path "first" "second"]
      @ inline_calls bundle [public_args path "second" "third"] in
  let rows = dispatch env bundle.tools calls in
  check string "Inline claim conflicts with the public producer's same entry" "third" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "direct and Inline conflicting occurrences do not overlap" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_published_inline_claims_include_later_leaves () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~two_nodes:true sw config in
  public_bundle ~snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let left = Filename.concat root "multi-left/file" and right = Filename.concat root "multi-right/file"
  and shared = Filename.concat root "multi-shared/file" in
  write left "first"; write right "second"; write shared "first";
  let input path before after = match public_args path before after with
    | `Assoc fields -> `Assoc (fields @ ["other_path", `String shared; "other_old", `String before; "other_new", `String after])
    | _ -> fail "public patch fixture did not construct an object" in
  let rows = dispatch env bundle.tools (inline_calls bundle [input left "first" "second"; input right "second" "third"]) in
  check string "left first leaf completed" "second" (read left);
  check string "right first leaf completed" "third" (read right);
  check string "later shared leaf consumes the previous Skill's bytes" "third" (read shared);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "a later leaf's conflict separates outer waves" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_public_edits_overlap_through_handler_and_bridge () =
  fixture @@ fun env sw config meta recovery root ->
  public_bundle env sw config meta recovery @@ fun meta task_id cell causal bundle ->
  let hooks = Keeper_hooks_agent_core.make_hooks ~config ~meta_ref:(ref meta)
      ~turn_ctx_cell:cell ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~keeper_turn_id:13 ~on_after_turn_ordinal:(fun _ -> ())
      ~tool_result_commit_required:(fun () -> true) () in
  let left = Filename.concat root "public-parent/left" and right = Filename.concat root "public-parent/right" in
  write left "left-before"; write right "right-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
      (fun () -> dispatch ~hooks env bundle.Keeper_tools_agent_core.tools
        (public_calls [public_args left "left-before" "left-after"; public_args right "right-before" "right-after"])) in
  check int "two public Edit handlers entered the real authorization boundary" 2 !entered;
  check string "public left bytes" "left-after" (read left);
  check string "public right bytes" "right-after" (read right);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "public effect wave has both occurrences" 2
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows;
  let ledger = Keeper_tool_call_log.read_recent ~keeper_name:meta.name ()
      |> function Ok rows -> rows | Error (Index_unavailable detail) -> fail detail in
  let rows = List.filter (fun row -> match Yojson.Safe.Util.member "tool_use_id" row with
      | `String "public-edit-0" | `String "public-edit-1" -> true | _ -> false) ledger in
  check int "both actual public handlers recorded physical execution rows" 2 (List.length rows);
  List.iter (fun row ->
    check string "public handler keeps original Task" task_id
      Yojson.Safe.Util.(member "task_id" row |> to_string);
    check string "public handler keeps original trace" (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      Yojson.Safe.Util.(member "trace_id" row |> to_string);
    check bool "actual execution identity is present" true
      (match Yojson.Safe.Util.member "execution_id" row with `String id -> id <> "" | _ -> false)) rows;
  let snapshot = (Keeper_gate_causal_context.snapshot causal).snapshot in
  check int "both public results reached the turn Gate aggregate" 2
    Yojson.Safe.Util.(member "completed_tool_calls" snapshot |> to_list |> List.length)
;;

let test_public_conflicting_edits_keep_current_bytes () =
  fixture @@ fun env sw config meta recovery root ->
  public_bundle env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let path = Filename.concat root "public-conflict/file" in
  write path "first";
  let rows = dispatch env bundle.Keeper_tools_agent_core.tools
      (public_calls [public_args path "first" "second"; public_args path "second" "third"]) in
  check string "public second patch consumes the predecessor's actual bytes" "third" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "conflicting public edits have separate waves" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_public_edits_without_source_stay_serial () =
  fixture @@ fun env sw config meta recovery root ->
  public_bundle ~sourceful:false env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let path = Filename.concat root "public-no-source/file" in
  write path "before";
  let rows = dispatch env bundle.Keeper_tools_agent_core.tools
      (public_calls [public_args path "before" "after"]) in
  check string "ordinary public Edit still executes" "after" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check bool "missing source authority retains Serial admission" true
      ((Agent_core.Tool_contract.Invocation.schedule row.invocation).execution_mode = Agent_core.Tool_contract.Serial)) rows
;;

let test_disjoint_actual_edits_overlap () =
  fixture @@ fun env _sw config meta recovery root ->
  let left = Filename.concat root "same-parent/left" and right = Filename.concat root "same-parent/right" in
  write left "left-before"; write right "right-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered;
      if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
      (fun () -> batch env config meta recovery
        [args left "left-before" "left-after"; args right "right-before" "right-after"]) in
  check int "both actual authorization boundaries overlapped" 2 !entered;
  check string "left actual file" "left-after" (read left);
  check string "right actual file" "right-after" (read right);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    let schedule = Agent_core.Tool_contract.Invocation.schedule row.invocation in
    check int "actual disjoint wave contains both calls" 2 schedule.batch_size;
    check bool "effect stays Concurrent without claiming readonly" true
      (schedule.execution_mode = Agent_core.Tool_contract.Concurrent)) rows
;;

let test_shared_source_edits_overlap ~in_skill () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = if in_skill then Some (publish_edit_skills ~two_nodes:true sw config) else None in
  public_bundle ?snapshot env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let source = Filename.concat root "shared-source/original" in
  let left = Filename.concat root "target-left/file" and right = Filename.concat root "target-right/file" in
  write source "shared-before";
  List.iter (fun target ->
    Fs_compat.mkdir_p (Filename.dirname target);
    Unix.symlink "../shared-source/original" target) [left; right];
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let calls = if in_skill then inline_calls bundle
      [two_patch_args left "shared-before" "left-after" right "shared-before" "right-after"]
    else public_calls [public_args left "shared-before" "left-after";
                       public_args right "shared-before" "right-after"] in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered;
      if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
    (fun () -> dispatch env bundle.Keeper_tools_agent_core.tools calls) in
  check int "both actual edits share source reads while overlapping target writes" 2 !entered;
  check int "original public calls complete" (if in_skill then 1 else 2) (List.length rows);
  check string "left target receives its own replacement" "left-after" (read left);
  check string "right target receives its own replacement" "right-after" (read right);
  check string "shared original bytes are not modified" "shared-before" (read source);
  List.iter (fun target ->
    check bool "atomic replacement replaces the lexical symlink entry" true
      ((Unix.lstat target).st_kind = Unix.S_REG)) [left; right];
  if not in_skill then List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "public mixed-resource calls share one actual wave" 2
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_source_write_precedes_later_alias_read () =
  fixture @@ fun env sw config meta recovery root ->
  public_bundle env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let source = Filename.concat root "ordered-source/original" in
  let target = Filename.concat root "ordered-target/file" in
  write source "first";
  Fs_compat.mkdir_p (Filename.dirname target);
  Unix.symlink "../ordered-source/original" target;
  let rows = dispatch env bundle.Keeper_tools_agent_core.tools
      (public_calls [public_args source "first" "second";
                     public_args target "second" "third"]) in
  check string "source write commits its original result" "second" (read source);
  check string "later alias read consumes the newly replaced source" "third" (read target);
  match rows with
  | [first; second] ->
    let wave row = (Agent_core.Tool_contract.Invocation.schedule
        row.Agent_core.Agent_tools.invocation).batch_index in
    check bool "write/read overlap keeps the original ordering edge" true (wave first < wave second)
  | [] | [_] | _ :: _ :: _ :: _ -> fail "ordered write/read results changed"
;;

let test_successive_patches_use_current_source () =
  fixture @@ fun env _sw config meta recovery root ->
  let path = Filename.concat root "same/file" in
  write path "first";
  let rows = batch env config meta recovery [args path "first" "second"; args path "second" "third"] in
  check string "later patch reads the earlier atomic replacement" "third" (read path);
  match rows with
  | [first; second] ->
    let schedule row = Agent_core.Tool_contract.Invocation.schedule
        row.Agent_core.Agent_tools.invocation in
    check bool "conflicting occurrence follows the prior wave" true
      ((schedule first).batch_index < (schedule second).batch_index)
  | [] | [_] | _ :: _ :: _ :: _ -> fail "successive Edit results changed"
;;

let test_directory_alias_keeps_patch_order () =
  fixture @@ fun env _sw config meta recovery root ->
  let directory = Filename.concat root "real" in
  let path = Filename.concat directory "file" in
  write path "first";
  let alias = Filename.concat root "alias" in
  Unix.symlink "real" alias;
  let rows = batch env config meta recovery
      [args path "first" "second"; args (Filename.concat alias "file") "second" "third"] in
  check string "alias patch consumes the original predecessor bytes" "third" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "physical aliases do not share a concurrent wave" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_distinct_entries_under_nested_parents_overlap () =
  fixture @@ fun env _sw config meta recovery root ->
  let parent = Filename.concat root "parent/file" in
  let child = Filename.concat root "parent/child/file" in
  write parent "parent-before"; write child "child-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
    (fun () -> batch env config meta recovery
      [args parent "parent-before" "parent-after"; args child "child-before" "child-after"]) in
  check int "nested directories do not serialize independent actual entries" 2 !entered;
  check string "parent actual file" "parent-after" (read parent);
  check string "child actual file" "child-after" (read child);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "distinct entries in nested parents share one wave" 2
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_object_aliases_retain_backend_mutation_order ~spelling_alias () =
  fixture @@ fun env sw config meta recovery root ->
  public_bundle env sw config meta recovery @@ fun _meta _task _cell _causal bundle ->
  let left = Filename.concat root "object-alias/Original" in
  let right = Filename.concat root (if spelling_alias then "object-alias/original" else "object-alias/linked") in
  write left "first";
  (* Observe the real filesystem, without inventing a case-folding rule. On a
     case-sensitive filesystem the alternate spelling becomes a hard link. *)
  let same_entry = Sys.file_exists right in
  if not same_entry then Unix.link left right;
  check bool "fixture aliases share the original inode" true
    ((Unix.stat left).st_ino = (Unix.stat right).st_ino);
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered;
      if !entered = 2 then check string "prior replacement commits before alias admission"
        "second" (read left))
    (fun () -> dispatch env bundle.Keeper_tools_agent_core.tools
      (public_calls [public_args left "first" "second";
                     public_args right (if same_entry then "second" else "first") "third"])) in
  check int "both original public calls complete" 2 !entered;
  check string "left entry retains its actual replacement semantics"
    (if same_entry then "third" else "second") (read left);
  check string "alias reads its actual predecessor source" "third" (read right);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "object aliases retain separate mutation waves" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_parent_swap_and_input_or_owner_change_do_not_write () =
  fixture @@ fun _env sw config meta recovery root ->
  let directory = Filename.concat root "original" in
  let path = Filename.concat directory "file" in
  write path "original";
  let input = args path "original" "changed" in
  let prepared = prepare sw config meta input in
  check string "preparation never edits the source" "original" (read path);
  consume config meta recovery (Some prepared) (args path "original" "another") |> failed;
  let other = {meta with current_task_id = Some (Keeper_id.Task_id.of_string "task-902" |> get)} in
  consume config other recovery (Some prepared) input |> failed;
  let retained = directory ^ "-retained" in
  Unix.rename directory retained;
  write path "replacement";
  consume config meta recovery (Some prepared) input |> failed;
  check string "replacement parent remains untouched" "replacement" (read path);
  check string "retained original remains untouched" "original" (read (Filename.concat retained "file"))
;;

let test_preparation_preserves_containment_under_manual_gate () =
  fixture @@ fun _env sw config meta recovery _root ->
  Keeper_approval_queue.For_testing.reset_runtime_state ();
  Eio.Switch.on_release sw Keeper_approval_queue.For_testing.reset_runtime_state;
  (match Keeper_approval_queue.install_persistence ~base_path:config.Workspace.base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue_result.install_error_to_string error));
  Keeper_gate_mode.set config ~actor:"fixture" Keeper_gate_mode.Manual |> get |> ignore;
  let path = Filename.concat config.base_path "project-file" in
  write path "before";
  let input = args path "before" "after" in
  (match FS.prepare_edit ~sw ~config ~meta ~args:input with
   | Error (FS.Edit_path_refused _) -> ()
   | Error (FS.Edit_resource_unavailable detail) -> fail detail
   | Ok None | Ok (Some _) -> fail "Manual Gate does not widen the Keeper's allowed root");
  check string "outside source remains untouched" "before" (read path);
  (* The current Shared_mount root is exactly the Keeper playground. Its
     established capability-authorized write bypass remains under Manual. *)
  let internal = Filename.concat (Keeper_sandbox.host_root_abs_of_meta ~config meta) "inside" in
  write internal "before";
  let input = args internal "before" "after" in
  let prepared = prepare sw config meta input in
  consume config meta recovery (Some prepared) input |> completed;
  check string "existing internal playground authorization is preserved" "after" (read internal)
;;

let test_cancelled_prepared_edit_releases_for_a_later_call () =
  fixture @@ fun _env sw config meta recovery root ->
  let path = Filename.concat root "cancelled/file" in
  write path "before";
  let input = args path "before" "after" in
  let entered, resolve_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  (match Eio.Switch.run (fun child ->
    let prepared = prepare child config meta input in
    Eio.Fiber.fork ~sw:child (fun () ->
      FS.For_testing.with_before_write_authorization (fun () ->
        Eio.Promise.resolve resolve_entered (); Eio.Promise.await never)
        (fun () -> consume config meta recovery (Some prepared) input |> completed));
    Eio.Promise.await entered;
    Eio.Switch.fail child Exit) with
   | () -> fail "caller cancellation did not propagate"
   | exception Exit -> ());
  check string "cancelled authorization performed no effect" "before" (read path);
  let prepared = prepare sw config meta input in
  consume config meta recovery (Some prepared) input |> completed;
  check string "later original call is not held by cancelled resources" "after" (read path)
;;

let test_untransferred_preparation_releases_without_effect () =
  fixture @@ fun _env sw config meta recovery root ->
  let path = Filename.concat root "untransferred/file" in
  write path "before";
  let input = args path "before" "after" in
  let prepared = prepare sw config meta input in
  FS.release_prepared_edit prepared;
  FS.release_prepared_edit prepared;
  consume config meta recovery (Some prepared) input |> failed;
  check string "released preparation cannot spend the old capability" "before" (read path);
  consume config meta recovery None input |> completed;
  check string "ordinary later Edit remains usable" "after" (read path)
;;

(* Open descriptors of this process, listed from /dev/fd. The listing holds one
   descriptor for the directory it reads, in every count alike. The counts only
   compare when nothing else in the process opens or closes a descriptor
   between them, so the test runs alone in a serial suite. *)
let open_descriptor_count () = Array.length (Sys.readdir "/dev/fd")

let test_release_closes_the_pinned_directories () =
  fixture @@ fun _env sw config meta _recovery root ->
  let path = Filename.concat root "pinned/file" in
  write path "before";
  let input = args path "before" "after" in
  (* The first preparation settles anything created lazily, so the counts
     below compare like with like. *)
  FS.release_prepared_edit (prepare sw config meta input);
  let before = open_descriptor_count () in
  let prepared = prepare sw config meta input in
  let pinned = open_descriptor_count () in
  FS.release_prepared_edit prepared;
  let after = open_descriptor_count () in
  check bool "a preparation pins directory descriptors" true (pinned > before);
  check int "release closes every pinned descriptor" before after
;;

(* A Skill with a Read node carries artifact references, so its settlement
   reaches the model as a tool-result manifest marker (the same projection
   test_keeper_owned_jobs.ml resolves in [result_document]), not as inline
   JSON. Resolve the marker to the structured document before reading it. *)
let mixed_settlement_document ~base_path (row : Agent_core.Agent_tools.tool_execution_result) =
  match Tool_output.decode_from_agent_core row.content with
  | Tool_output.Not_marker -> Yojson.Safe.from_string row.content
  | Tool_output.Invalid_marker { detail } -> fail detail
  | Tool_output.Decoded reference ->
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256 with
     | Ok (Some bytes) ->
       check int "marker names the exact durable bytes" reference.bytes (String.length bytes);
       let json = Yojson.Safe.from_string bytes in
       (match Tool_output.artifact_manifest_of_json json with
        | Tool_output.Decoded_artifact_manifest manifest -> manifest.structured_content
        | Tool_output.Invalid_artifact_manifest { detail } -> fail detail
        | Tool_output.Not_artifact_manifest -> json)
     | Ok None | Error _ -> fail "mixed Skill settlement artifact unavailable")
;;

let mixed_read_content ~base_path (row : Agent_core.Agent_tools.tool_execution_result) =
  let open Yojson.Safe.Util in
  let actions = mixed_settlement_document ~base_path row |> member "actions" |> to_list in
  let read = List.find (fun action -> member "node_id" action = `String "read") actions in
  member "result" read |> member "data" |> member "content" |> to_string
;;

let test_mixed_skills_share_read_claims_while_writes_overlap () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~read_path_param:"read_path" sw config in
  public_bundle ~snapshot ~with_read:true env sw config meta recovery
  @@ fun _meta _task _cell _causal bundle ->
  let source = Filename.concat root "mixed/shared" in
  let left = Filename.concat root "mixed/left" and right = Filename.concat root "mixed/right" in
  write source "read-only shared bytes"; write left "before"; write right "before";
  let input path = match public_args path "before" "after" with
    | `Assoc fields -> `Assoc (fields @ ["read_path", `String source])
    | _ -> fail "patch arguments are not an object" in
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered; if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
    (fun () -> dispatch env bundle.tools (inline_calls bundle [input left; input right])) in
  check int "both real mixed Skill write boundaries overlap" 2 !entered;
  List.iter (fun row ->
    check string "shared Read returned its actual source" "read-only shared bytes"
      (mixed_read_content ~base_path:config.Workspace.base_path row)) rows;
  check string "left committed" "after" (read left);
  check string "right committed" "after" (read right);
  check string "shared source stayed unchanged" "read-only shared bytes" (read source)
;;

let test_mixed_read_observes_preceding_edit ~symlink () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~read_path_param:"file_path" sw config in
  public_bundle ~snapshot ~with_read:true env sw config meta recovery
  @@ fun _meta _task _cell _causal bundle ->
  let original = Filename.concat root "mixed-order/original" in
  let path = Filename.concat root "mixed-order/entry" in
  write original "before";
  if symlink then Unix.symlink "original" path else write path "before";
  let rows = dispatch env bundle.tools (inline_calls bundle [public_args path "before" "after"]) in
  match rows with
  | [row] ->
    check string "Read consumed the earlier atomic replacement" "after"
      (mixed_read_content ~base_path:config.Workspace.base_path row);
    check string "actual replacement bytes" "after" (read path);
    check string "other source entry stayed unchanged" "before" (read original)
  | _ -> fail "one mixed Skill did not return one settlement"
;;

let test_prepared_read_rejects_changed_authority_and_keeps_line_window () =
  fixture @@ fun _env sw config meta _recovery root ->
  let absent = {meta with name = "absent-reader"} in
  let absent_root = Keeper_sandbox.host_root_abs_of_meta ~config absent in
  check bool "fixture starts without the other Keeper tree" false (Sys.file_exists absent_root);
  (match FS.prepare_read ~sw ~config ~meta:absent ~args:(`Assoc ["path", `String "missing"]) with
   | Ok (Some _) -> fail "a missing tree produced a file preparation"
   | Ok None | Error _ -> ());
  check bool "Read preparation creates no sandbox bundle" false (Sys.file_exists absent_root);
  let path = Filename.concat root "read-window/file" in
  write path "one\ntwo\nthree\n";
  let input = `Assoc ["path", `String path; "offset", `Int 2; "limit", `Int 1] in
  let prepared = match FS.prepare_read ~sw ~config ~meta ~args:input with
    | Ok (Some value) -> value
    | Ok None -> fail "owned regular Read was not prepared"
    | Error detail -> fail detail in
  let consume meta args = FS.handle_prepared_read_file_with_outcome
      ~prepared_read:prepared ~config ~meta ~args in
  let changed = {meta with name = "another-owner"} in
  consume changed input |> failed;
  consume meta (`Assoc ["path", `String path]) |> failed;
  let result = consume meta input in
  completed result;
  check string "line-based Read contract survives preparation" "two\n"
    Yojson.Safe.Util.(Yojson.Safe.from_string result.raw_output |> member "content" |> to_string);
  let other = Filename.concat root "read-window/other" in
  write other "unclaimed bytes";
  Unix.unlink path;
  Unix.symlink "other" path;
  consume meta input |> failed;
  Unix.unlink path;
  write path "one\ntwo\nthree\n";
  FS.release_prepared_read prepared;
  consume meta input |> failed
;;

let test_mixed_missing_or_nonregular_read_keeps_ordinary_admission () =
  fixture @@ fun env sw config meta recovery root ->
  let snapshot = publish_edit_skills ~read_path_param:"read_path" sw config in
  public_bundle ~snapshot ~with_read:true env sw config meta recovery
  @@ fun _meta _task _cell _causal bundle ->
  let edit_path = Filename.concat root "read-fallback/edit" in
  let valid_path = Filename.concat root "read-fallback/valid" in
  let missing_path = Filename.concat root "read-fallback/missing" in
  let directory = Filename.concat root "read-fallback/directory" in
  write edit_path "before"; write valid_path "readable"; Fs_compat.mkdir_p directory;
  List.iter (fun (read_path, scoped) ->
    let input = match public_args edit_path "before" "after" with
      | `Assoc fields -> `Assoc (fields @ ["read_path", `String read_path])
      | _ -> fail "patch arguments are not an object" in
    let name = match inline_calls bundle [input] with
      | [Agent_core.Types.ToolUse call] -> call.name
      | _ -> fail "one Skill did not produce one call" in
    let tool = List.find (fun tool -> String.equal tool.Agent_core.Tool.schema.name name) bundle.tools in
    check bool "the actual mixed producer opts into resource preparation" true
      (Agent_core.Tool.has_scoped_admission tool);
    let ordinary_calls = ref 0 in
    (* Observe fallback selection without starting its sandbox process. Actual
       file preparation and all partial-capability cleanup remain real. *)
    let tool = Agent_core.Tool.map_handler (fun _handler _env _input ->
        incr ordinary_calls;
        Ok {Agent_core.Types.content = "ordinary fallback"; content_blocks = None; _meta = None}) tool in
    Eio.Switch.run (fun preparation_sw ->
      let prepared = Agent_core.Tool.prepare_call ~sw:preparation_sw tool ~input in
      check bool "only existing regular resources transfer scoped admission" scoped
        (Option.is_some (Agent_core.Tool.prepared_call_scopes prepared));
      if not scoped then begin
        (match Agent_core.Tool.execute_prepared prepared with
         | Ok _ -> ()
         | Error error -> fail error.message);
        check int "unsupported Read selects the ordinary handler" 1 !ordinary_calls
      end);
    check string "preparation/fallback selection has not executed the Edit" "before" (read edit_path))
    [valid_path, true; missing_path, false; directory, false]
;;

let test_prepared_read_skips_a_long_line_and_stops_at_eof () =
  fixture @@ fun _env sw config meta _recovery root ->
  let path = Filename.concat root "read-window/long-line" in
  write path (String.make (Tool_shard_limits.read_file_max_max_bytes + 1) 'x' ^ "\nwanted\n");
  List.iter (fun (offset, expected) ->
    let input = `Assoc ["path", `String path; "offset", `Int offset; "limit", `Int 1] in
    let prepared = match FS.prepare_read ~sw ~config ~meta ~args:input with
      | Ok (Some value) -> value
      | Ok None -> fail "long-line regular Read was not prepared"
      | Error detail -> fail detail in
    let result = FS.handle_prepared_read_file_with_outcome ~prepared_read:prepared ~config ~meta ~args:input in
    completed result;
    check string "line skipping streams past the buffer bound and terminates at EOF" expected
      Yojson.Safe.Util.(Yojson.Safe.from_string result.raw_output |> member "content" |> to_string);
    FS.release_prepared_read prepared)
    [2, "wanted\n"; max_int, ""]
;;

let () = run "prepared actual file resources"
  ["actual filesystem and SDK", [
    test_case "disjoint actual Edits overlap" `Quick test_disjoint_actual_edits_overlap;
    test_case "conflicting patches read current predecessor bytes" `Quick test_successive_patches_use_current_source;
    test_case "directory aliases retain planned order" `Quick test_directory_alias_keeps_patch_order;
    test_case "distinct entries in nested directories overlap" `Quick test_distinct_entries_under_nested_parents_overlap;
    test_case "changed owner input or parent cannot write" `Quick test_parent_swap_and_input_or_owner_change_do_not_write;
    test_case "Manual Gate retains the same containment and playground authority" `Quick test_preparation_preserves_containment_under_manual_gate;
    test_case "caller cancellation releases prepared Edit" `Quick test_cancelled_prepared_edit_releases_for_a_later_call;
    test_case "untransferred preparation releases without an effect" `Quick test_untransferred_preparation_releases_without_effect;
    test_case "release closes the pinned directories" `Quick test_release_closes_the_pinned_directories];
    "actual public bundle and SDK", [
      test_case "hard-link entries retain backend mutation order" `Quick
        (test_object_aliases_retain_backend_mutation_order ~spelling_alias:false);
      test_case "filesystem spelling aliases retain backend mutation order" `Quick
        (test_object_aliases_retain_backend_mutation_order ~spelling_alias:true);
      test_case "public Edits overlap while sharing the resolved source" `Quick
        (test_shared_source_edits_overlap ~in_skill:false);
      test_case "source write precedes a later alias read" `Quick
        test_source_write_precedes_later_alias_read;
      test_case "public Edit keeps handler observers bridge and source while overlapping" `Quick
        test_public_edits_overlap_through_handler_and_bridge;
      test_case "public conflicting patches consume predecessor bytes" `Quick test_public_conflicting_edits_keep_current_bytes;
      test_case "public Edit with unavailable source stays Serial" `Quick test_public_edits_without_source_stay_serial];
    "published Inline Skills and actual Edit", [
      test_case "one published Skill overlaps Edits sharing the resolved source" `Quick
        (test_shared_source_edits_overlap ~in_skill:true);
      test_case "one published Skill overlaps its independent real Edits" `Quick
        test_one_inline_overlaps_its_disjoint_edits;
      test_case "one published Skill orders physical aliases" `Quick
        test_one_inline_preserves_physical_conflicts;
      test_case "one published Skill retains explicit dependencies" `Quick
        test_one_inline_preserves_explicit_dependency;
      test_case "failed inner Edit blocks its conflict while a sibling commits" `Quick
        test_one_inline_failure_blocks_conflict_only;
      test_case "cancelled inner Edits release for a new invocation" `Quick
        test_cancelled_inner_edits_release_for_next_invocation;
      test_case "published Skills overlap and retain activation run and leaf receipts" `Quick
        test_published_inline_edits_overlap_and_retain_receipts;
      test_case "published conflicts consume predecessor bytes" `Quick test_published_inline_conflicts_keep_predecessor_bytes;
      test_case "public and published Inline producers share conflict order" `Quick
        test_public_and_published_inline_share_conflict_order;
      test_case "outer claims include a conflict on the later leaf" `Quick
        test_published_inline_claims_include_later_leaves];
    "mixed Read and Edit", [
      test_case "missing and nonregular Read cleanly retain ordinary admission" `Quick
        test_mixed_missing_or_nonregular_read_keeps_ordinary_admission;
      test_case "prepared Read streams a long line and terminates large offsets at EOF" `Quick
        test_prepared_read_skips_a_long_line_and_stops_at_eof;
      test_case "mixed Skills share real reads while disjoint writes overlap" `Quick
        test_mixed_skills_share_read_claims_while_writes_overlap;
      test_case "Read observes the preceding regular-file Edit" `Quick
        (fun () -> test_mixed_read_observes_preceding_edit ~symlink:false ());
      test_case "Read observes an Edit that replaces its symlink entry" `Quick
        (fun () -> test_mixed_read_observes_preceding_edit ~symlink:true ());
      test_case "prepared Read retains owner input release and line-window semantics" `Quick
        test_prepared_read_rejects_changed_authority_and_keeps_line_window]]
