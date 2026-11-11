(** Every tool a keeper is handed must be one the approval policy can
    classify.

    [Keeper_tool_approval_policy.verdict_for] resolves a name through
    [Keeper_tool_descriptor] and asks when nothing owns it. That reject is the
    right answer for a name this build genuinely cannot classify, and the
    wrong one for a tool the bundle hands the model on purpose — the operator
    is asked about a call the policy simply failed to recognise, with a reason
    that tells them nothing they can act on.

    Such tools shipped that way. [keeper_compose_<name>],
    [keeper_composition_status] and [keeper_composition_cancel] are
    materialised as Agent-Core tools outside the descriptor registry, so
    every composition asked — including one whose whole plan is reads, while
    the same tools called directly ran unasked.

    Nothing caught it. The nearest test partitions [Descriptor.public_names ()]
    — the seven LLM-native names — against a hard-coded answer, and never
    looks at the bundle. So this walks the bundle the keeper actually gets and
    fails on any name the policy cannot place, whatever the reason it was
    added. A fifth kind of undescribed tool trips it on the way in rather than
    after an operator wonders why they are being asked.

    The same bundle is walked once more for a rule a provider applies to the
    whole tool list: no input schema holds [$ref] or [$defs]. *)

open Alcotest
open Masc

module Policy = Keeper_tool_approval_policy

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK -> Unix.unlink path
;;

let with_publication_recovery_registry ?(install_eio_context = false) ~registry_root f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let use_registry () =
    Masc_test_deps.with_publication_recovery_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root
      (fun registry -> f registry (Eio.Stdenv.net env) sw)
  in
  if install_eio_context then
    Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock
      ~mono_clock:env#mono_clock use_registry
  else use_registry ()
;;

let publication_recovery_turn_context ~registry ~keeper_name =
  Keeper_publication_recovery_availability.
    { provider = Masc_test_deps.publication_recovery_provider registry
    ; keeper_name
    }
;;

(* agent_name is not free-form: keeper_meta_json_parse rejects a meta whose
   agent_name is not "keeper-<name>-agent". Derived the way production does. *)
let make_meta ~name () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String "test-trace-bundle-classifiable"
          ])
  with
  | Ok meta -> meta
  | Error e -> failf "make_meta failed: %s" e
;;

(* A bundle with no skills carries no composition tools, so a gate run
   against one would only ever see the descriptor half — and would pass
   while the tools this gate exists for were never in it. These two skills
   put every kind in: an inline composition and an async one (which is what
   brings keeper_composition_status and _cancel with it). *)
let composition_skill ~deferred ~name ~execution =
  Printf.sprintf
    {|---
name: %s
description: A composition used by the bundle classification gate.
---

# %s

```toml composition
[[compositions]]
name = "%s"
description = "A composition used by the bundle classification gate."
execution = "%s"
%s
[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
    name name name execution (if deferred then "defer_loading = true\n" else "")
;;

let mixed_composition_document =
  {|---
name: gate-mixed
description: A read followed by a file write.
---
```toml composition
[[compositions]]
name = "gate-mixed"
execution = "inline"
[[compositions.nodes]]
id = "read"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "write"
tool = "Write"
after = ["read"]
[compositions.nodes.input]
kind = "literal"
value = { file_path = "fixture.txt", content = "written" }
```
|}
;;

let instruction_document =
  "---\nname: gate-instruction\ndescription: what the gate reads\n---\n\nbody\n"
;;

let skill_snapshot_and_catalog ?(deferred = false) () =
  let source_config =
    match
      Skill_source_config.parse_text
        "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"bundle-fixture\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
    with
    | Ok config -> config
    | Error _ -> fail "bundle Skill source config was rejected"
  in
  let source =
    match source_config.sources with
    | [ source ] -> source
    | _ -> fail "bundle Skill source count changed"
  in
  let resolved =
    Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
  in
  let documents =
    [ "gate-inline", composition_skill ~deferred ~name:"gate-inline" ~execution:"inline"
    ; "gate-async", composition_skill ~deferred ~name:"gate-async" ~execution:"async"
    ; "gate-instruction", instruction_document
    ; "gate-mixed", mixed_composition_document
    ] @ if deferred then ["gate-result", {|---
name: gate-result
description: Read a selected original job result.
---
```toml composition
[[compositions]]
name = "gate-result"
execution = "inline"
defer_loading = true
[[compositions.params]]
name = "job_id"
type = "string"
description = "Original selected job"
[[compositions.nodes]]
id = "result"
tool = "keeper_job_result"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "job_id"
[compositions.nodes.input.fields.value]
kind = "param"
name = "job_id"
```
|}] else []
  in
  let scan : Skill_catalog_snapshot.source_scan =
    { source = resolved
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = "/workspace/skills"
          ; candidates = List.length documents
          }
    ; candidates =
        List.map
          (fun (directory, source_text) ->
             Skill_catalog_snapshot.Candidate_document { directory; source_text })
          documents
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config:source_config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "bundle Skill snapshot was rejected"
  in
  match Keeper_skill_catalog.of_snapshot snapshot with
  | catalog, [] -> snapshot, catalog
  | _, _ :: _ -> fail "bundle Skill snapshot projection was rejected"
;;

let instruction_reference () =
  let source_id =
    match Skill_source_config.source_id_of_string "bundle-fixture" with
    | Ok source_id -> source_id
    | Error detail -> fail detail
  in
  let package_id =
    match Skill_reference.package_id_of_directory "gate-instruction" with
    | Ok package_id -> package_id
    | Error _ -> fail "invalid instruction fixture package"
  in
  Skill_reference.make
    ~identity:
      (Skill_reference.make_identity
         ~source_id
         ~package_id
         ~name:"gate-instruction")
    ~content_revision:
      (Skill_reference.content_revision_of_source_text instruction_document)
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

(* An attached work service's tools reach the bundle the same way the
   composition ones do, and the policy places them from what the service said
   about each. Included here rather than only where they are built: this is
   the gate that walks what the model is actually handed, and a later path
   that hands one out without recording its annotation would make every call
   ask with a reason nobody can act on. *)
let identity_tools () =
  let declaration =
    {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600

[authorize_params]
audience = "api.atlassian.com"
|}
  in
  let provider =
    match Keeper_oauth_provider.load ~file_name:"atlassian" ~contents:declaration with
    | Ok provider -> provider
    | Error e ->
      failf "the gate's own declaration must parse: %s"
        (Keeper_oauth_provider.error_to_string e)
  in
  let schema =
    `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
  in
  let catalog =
    { Keeper_identity_tools.provider_id = "atlassian"
    ; provider_label = "Atlassian"
    ; discovered_at = 0.0
    ; tools =
        (* One of each thing a service can say, so the gate covers all three
           arms rather than the convenient one. *)
        [ { Mcp_client.name = "readsOnly"; description = "reads"
          ; input_schema = schema; read_only = Some true }
        ; { Mcp_client.name = "mayWrite"; description = "writes"
          ; input_schema = schema; read_only = Some false }
        ; { Mcp_client.name = "saidNothing"; description = "unannotated"
          ; input_schema = schema; read_only = None }
        ]
    }
  in
  (Keeper_identity_tools.agent_tools ~provider catalog)
    .Keeper_identity_tools.offered
;;

let snapshot_reference snapshot name =
  match Skill_catalog_snapshot.find_effective_by_name snapshot name with
  | Some entry -> Skill_catalog_snapshot.entry_reference entry
  | None -> failf "exact snapshot reference %s missing" name
;;

let assert_exact_activation snapshot expected
      (activation : Keeper_skill_activation_ledger.activation)
  =
  let observed =
    Skill_reference.make
      ~identity:activation.identity
      ~content_revision:activation.content_revision
  in
  check bool "exact identity and content revision" true
    (Skill_reference.equal expected observed);
  check bool "exact frozen snapshot revision" true
    (Skill_catalog_snapshot.equal_snapshot_revision
       (Skill_catalog_snapshot.snapshot_revision snapshot)
       activation.snapshot_revision)
;;

let with_bundle_tools
      ?(record_activations = true)
      ?(agent_core = false)
      ?(deferred_compositions = false)
      ?(task_skill_names = ["gate-instruction"])
      ?(current_task_id = None)
      ?(tool_deny = [])
      ?(addon_exports = [])
      ?agent_cell
      ?(with_identity_surface = true)
      ?(install_eio_context = false)
      ?(check_bundle = fun _config _bundle _net _sw -> ())
      ?(check_on_demand = fun _ -> ())
      f
  =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_bundle_classifiable_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists dir then remove_tree dir)
    (fun () ->
       let config = Workspace.default_config dir in
       let meta = make_meta ~name:"bundle-classifiable" () in
       let current_task_id = Option.map (fun task_id ->
         match Keeper_id.Task_id.of_string task_id with
         | Ok task_id -> task_id | Error detail -> fail detail) current_task_id in
       let meta = {meta with current_task_id} in
       let skill_snapshot, skill_catalog = skill_snapshot_and_catalog ~deferred:deferred_compositions () in
       let trace_id = meta.runtime.trace_id in
       let session_dir =
         Keeper_fs.keeper_session_dir
           config
           (Keeper_id.Trace_id.to_string trace_id)
       in
       Unix.mkdir session_dir 0o700;
       let snapshot_revision =
         Skill_catalog_snapshot.snapshot_revision skill_snapshot
       in
       let skill_activation_context =
         let task_selection =
           match
             Keeper_task_skill_turn.resolve_for_task
               ~snapshot:skill_snapshot
               ~task_id:"task-001"
               (List.map (snapshot_reference skill_snapshot) task_skill_names)
           with
           | Ok selection -> selection
           | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
         in
         match
           Keeper_skill_activation_recorder.make ~keeper_name:"skill-keeper-fixture"
             ~trace_id
             ~runtime_id:(fun () -> Some "test.runtime")
             ~turn_ref:
               (Ids.Turn_ref.make
                  ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
                  ~absolute_turn:1)
             ~snapshot_revision
             ~task_selection
         with
         | Ok context -> context
         | Error error ->
           fail (Keeper_skill_activation_recorder.error_to_string error)
       in
       let ctx_snapshot =
         Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
       in
       with_publication_recovery_registry ~install_eio_context ~registry_root:dir
       @@ fun publication_recovery_registry net sw ->
       Option.iter (fun _ ->
         (* Load receipts read the current Task from the same Owner projection
            as a running Keeper, rather than from the frozen bundle metadata. *)
         (match Keeper_owner_registry.install_from_store
                  ~sw ~operation_runner:None ~on_turn_slot_released:None config with
          | Ok 0 -> ()
          | Ok count -> failf "expected an empty Keeper inventory, got %d owners" count
          | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
         match Keeper_owner_registry.create_meta ~base_path:config.base_path meta with
         | Ok (Some _) -> ()
         | Ok None -> fail "fixture Owner did not persist its Keeper metadata"
         | Error error -> fail (Keeper_owner_registry.command_error_to_string error))
         agent_cell;
       let publication_recovery =
         publication_recovery_turn_context
           ~registry:publication_recovery_registry
           ~keeper_name:meta.name
       in
       let composition_plan_index =
         Masc.Keeper_tool_composition_plan_index.create ()
       in
       let capability_surface =
         Keeper_capability_surface.create_with_descriptors
           ~tool_descriptors:(Keeper_tool_descriptor.all_descriptors ()
             @ List.map Keeper_lane_addon_descriptor.create addon_exports)
           ~tool_deny
           ~sandbox_profile:Masc.Keeper_types_profile.Docker
           ~skill_names:None
           ~global_skill_catalog:skill_catalog
           ~skill_inventory:(Keeper_skill_inventory.of_snapshot skill_snapshot)
           ~task_skills:[]
       in
       let receipt_context = Keeper_context_core.agent_core_context_of_context ctx_snapshot in
       let load_receipts =
         match Keeper_tool_load_receipts.restore
                 ~source:receipt_context ~target:receipt_context with
         | Ok restored -> restored
         | Error error -> fail (Keeper_tool_load_receipts.error_to_string error)
       in
       let bundle =
         Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot
           ~capability_surface
           ?identity_surface:
             (if with_identity_surface then Some
             { Masc.Keeper_tools_agent_core.offered = identity_tools ()
             ; agent_cell = Option.value ~default:(ref None) agent_cell
             ; history = []
             ; load_receipts
             ; keeper_turn_id = 1
             } else None)
           ~composition_plan_index
           ?skill_activation_context:
             (if record_activations then Some skill_activation_context else None)
           () |> Result.get_ok
       in
       Option.iter (fun cell -> cell := Some (Agent_core.Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
         ~config:(Agent_core.Types.default_config ~model:"fixture-model")
         ~net ~tools:bundle.agent_core_tools ())) agent_cell;
       Fun.protect ~finally:bundle.cleanup (fun () ->
         check_bundle config bundle net sw;
         check_on_demand bundle.on_demand_tool_names;
         f
           config
           meta
           skill_snapshot
           composition_plan_index
           capability_surface
           (if agent_core then bundle.agent_core_tools else bundle.tools)))
;;

let with_bundle f =
  with_bundle_tools
  @@ fun _config _meta _skill_snapshot composition_plan_index _surface tools ->
  f composition_plan_index
    (List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools)
;;

(* The bundle is the model-visible surface, whole. It used to be narrowable
   per Keeper through declared tool groups, and this asserted that a Tool
   outside the declared groups did not reach the bundle; #31728 removed the
   declaration because no Keeper ever wrote one, so there is no outside left
   for a Tool to be in. *)
(* An async composition is on this surface, so the shared request controls are
   built, each with its declared schema and execution contract. *)
let test_async_composition_controls_keep_their_contracts () =
  with_bundle_tools
  @@ fun _config _meta _skill_snapshot _composition_plan_index _surface tools ->
  List.iter
    (fun ((schema : Masc_domain.tool_schema), execution) ->
       let tool =
         match
           List.find_opt
             (fun (tool : Agent_core.Tool.t) -> String.equal tool.schema.name schema.name)
             tools
         with
         | Some tool -> tool
         | None -> failf "missing composition control %s" schema.name
       in
       check bool (schema.name ^ " input schema") true
         (tool.schema.input_schema = Some schema.input_schema);
       check bool (schema.name ^ " execution contract") true
         (Agent_core.Tool.execution_mode tool ~input:`Null = execution);
       check bool (schema.name ^ " continues after success") true
         (Agent_core.Tool.completion tool = Agent_core.Tool_contract.Continue_after_success))
    [ Tool_schemas_composition_control.status_schema, Agent_core.Tool_contract.Concurrent
    ; Tool_schemas_composition_control.cancel_schema, Agent_core.Tool_contract.Serial
    ]
;;

let test_the_bundle_is_the_model_visible_surface () =
  with_bundle_tools
  @@ fun _config _meta _skill_snapshot _composition_plan_index _surface tools ->
  let names =
    List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools
  in
  check bool "board Tool remains executable" true (List.mem "masc_board_list" names);
  check bool "Read is in the bundle, like every model-visible Tool" true
    (List.mem "Read" names)
;;

let check_stored_image_reader_is_callable_with_read_authority ~agent_core ~name ~input ~handler =
  (* This authority oracle exercises the eager fallback. Deferred loading is
     exercised with the real Agent and loader in the projection tests below. *)
  with_bundle_tools ~agent_core ~with_identity_surface:false
  @@ fun _config _meta _snapshot _plan_index surface tools ->
  let tool =
    match
      List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) tools
    with
    | Some tool -> tool
    | None -> fail "the stored-image reader is absent from the production bundle"
  in
  let descriptor =
    match Keeper_tool_descriptor_resolution.validated_descriptor_and_input_for_tool_call
            ~tool_name:tool.schema.name ~input with
    | Some (Ok (descriptor, prepared)) ->
      check bool "artifact and query reach the reader unchanged" true (prepared = input);
      descriptor
    | Some (Error _) | None -> fail "the model-visible reader call does not resolve"
  in
  check bool "the model call reaches the existing vision handler" true
    (descriptor.runtime_handler = handler);
  check bool "the reader is active in the frozen turn surface" true
    (List.exists
       (fun (capability : Keeper_capability_surface.tool_capability) ->
          capability.descriptor.id = descriptor.id
          && capability.availability = Keeper_capability_surface.Active)
       (Keeper_capability_surface.tool_capabilities surface));
  check (option bool) "image analysis retains read-only authority" (Some true)
    (Keeper_tool_descriptor_resolution.readonly_for_tool_call ~tool_name:name ~input);
  check bool "catalog requires read-state permission only" true
    ((Tool_catalog.metadata name).required_permission = Masc_domain.CanReadState);
  match Policy.verdict_for ~identity_tool_index:Masc.Keeper_identity_tool_index.empty ~composition_plan_index:None ~tool_name:name ~input with
  | Policy.Run -> ()
  | Policy.Ask { because } -> failf "stored-image reading asks for approval: %s" because
;;

let test_stored_image_reader_is_callable_with_read_authority () =
  List.iter (fun agent_core ->
    check_stored_image_reader_is_callable_with_read_authority ~agent_core
      ~name:"keeper_analyze_image"
      ~input:(`Assoc [ "artifact", `String "image-handle"; "query", `String "Read the chart" ])
      ~handler:Keeper_tool_descriptor.Tool_analyze_image;
    check_stored_image_reader_is_callable_with_read_authority ~agent_core
      ~name:"keeper_image_read"
      ~input:(`Assoc [ "artifact", `String "image-handle" ])
      ~handler:Keeper_tool_descriptor.Tool_read_image)
    [true; false]
;;

(* The handler is the tool. Reading only its schema would let a tool that
   answers nothing pass for one that works. *)
let tool_invocation ~tool_use_id (tool : Agent_core.Tool.t) =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id
      ~turn:0
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
;;

let run_tool ?(tool_use_id = "bundle-instruction-activation")
      (tool : Agent_core.Tool.t) input =
  let invocation = tool_invocation ~tool_use_id tool in
  match
    tool.handler
      (Agent_core.Tool.Execution_env.create ~invocation ())
      input
  with
  | Ok output -> output.Agent_core.Llm_provider.Types.content
  | Error err -> err.Agent_core.Llm_provider.Types.message
;;

let test_addon_exports_load_into_the_running_agent () =
  let name = "fixture_addon_command" in
  let tool = match Mcp_protocol.Mcp_types.tool_of_yojson
      (`Assoc ["name", `String name; "description", `String "Call the attached fixture";
        "inputSchema", `Assoc ["type", `String "object";
          "properties", `Assoc ["value", `Assoc ["type", `String "string"]];
          "required", `List [`String "value"]; "additionalProperties", `Bool false]]) with
    | Ok tool -> tool | Error detail -> fail detail in
  let export = Lane_addon_tool_export.create
      ~owner:(Lane_addon_tool_export.create_owner ~instance_id:"deferred-fixture") ~tool in
  let cell = ref None in
  with_bundle_tools ~agent_core:true ~addon_exports:[export] ~agent_cell:cell
    (fun _config _meta _snapshot _index _surface tools ->
      let agent = match !cell with Some agent -> agent | None -> fail "agent was not installed" in
      let callable name = Agent_core.Tool_set.mem name (Agent_core.Agent.tools agent) in
      check bool "unrequested Addon schema is absent from provider tools" false (callable name);
      let loader = match List.find_opt (fun (tool : Agent_core.Tool.t) ->
          tool.schema.name = Keeper_identity_tool_search.tool_name) tools with
        | Some tool -> tool | None -> fail "deferred Addon has no loader" in
      let invocation = tool_invocation ~tool_use_id:"bundle-addon-load" loader in
      (match Agent_core.Tool.execute ~invocation loader (`Assoc ["names", `List [`String name]]) with
       | Ok _ -> () | Error error -> fail error.Agent_core.Types.message);
      check bool "requested Addon becomes callable in the same agent" true (callable name);
      let loaded = match Agent_core.Tool_set.find name (Agent_core.Agent.tools agent) with
        | Some tool -> tool | None -> fail "loaded Addon disappeared" in
      check bool "loading keeps the original exported schema" true
        (loaded.schema.input_schema = Some tool.input_schema));
  with_bundle_tools ~agent_core:false ~addon_exports:[export]
    ~check_on_demand:(fun names ->
      check bool "official-client metadata defers the exported Addon tool" true
        (List.mem name names))
    (fun _config _meta _snapshot _index _surface tools ->
      check bool "fixed-tool runtimes retain the complete Addon schema" true
        (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) tools));
  let cell = ref None in
  with_bundle_tools ~agent_core:true ~addon_exports:[export] ~agent_cell:cell
    ~tool_deny:["addon:" ^ name]
    (fun _config _meta _snapshot _index _surface tools ->
      let agent = match !cell with Some agent -> agent | None -> fail "agent was not installed" in
      let loader = match List.find_opt (fun (tool : Agent_core.Tool.t) ->
          tool.schema.name = Keeper_identity_tool_search.tool_name) tools with
        | Some tool -> tool | None -> fail "fixture has no loader" in
      ignore (run_tool loader (`Assoc ["names", `List [`String name]]));
      check bool "loader cannot expose a denied Addon export" false
        (Agent_core.Tool_set.mem name (Agent_core.Agent.tools agent)))
;;

(* Exercise the real bundle and real deferred loader with an injected LLM
   transport. The separate HTTP test exercises the production Keeper driver.
   No external provider is contacted. *)
let image_projection_runtime ~declared =
  let source = {|[runtime]
default = "image_projection_fixture.selected"
[providers.image_projection_fixture]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1/v1"
[models.selected]
api-name = "image-projection-uncatalogued"
max-context = 4096
|} ^ (if declared then {|[models.selected.capabilities]
supports-image-input = true
supports-multimodal-inputs = true
|} else "") ^ "[image_projection_fixture.selected]\n" in
  let config = match Runtime_toml.parse_string source with
    | Ok config -> config
    | Error errors -> fail (String.concat "; "
        (List.map (fun (error : Runtime_toml.parse_error) -> error.message) errors)) in
  match config.bindings with
  | [binding] ->
    (match Runtime_instance.of_binding config binding with
     | Ok runtime ->
       (* An explicit endpoint capability override makes this fixture's broad
          provider premise real. Its model declaration remains unchanged:
          an unknown explicit provider otherwise has conservative defaults. *)
       (match runtime.Runtime_instance.execution with
        | Runtime_execution.Agent_core sealed ->
          let provider = Masc_test_deps.api_config sealed in
          let provider = {provider with
            Llm_provider.Provider_config.model_capabilities_override =
              Some (Llm_provider.Capabilities.capabilities_of_kind provider.kind)} in
          {runtime with Runtime_instance.execution =
             Runtime_execution.Agent_core (Runtime_account_access.seal_api provider)}
        | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
          fail "fixture must materialize an Agent Core runtime")
     | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason))
  | [] | _::_::_ -> fail "fixture must materialize exactly one selected runtime"
;;

let test_per_candidate_image_projection () =
  let image_name = "keeper_image_read" in
  let has_image tools = List.exists
      (fun (tool : Agent_core.Tool.t) -> tool.schema.name = image_name) tools in
  let tool_named tools name = match List.find_opt
      (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) tools with
    | Some tool -> tool | None -> fail ("missing projected tool " ^ name) in
  let text_runtime = image_projection_runtime ~declared:false in
  let image_runtime = image_projection_runtime ~declared:true in
  check string "the same runtime id can carry different immutable declarations"
    text_runtime.id image_runtime.id;
  let provider = match text_runtime.execution with
    | Runtime_execution.Agent_core sealed -> Masc_test_deps.api_config sealed
    | Codex_app_server _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
      fail "fixture must use the Agent Core transport" in
  check bool "the provider preset alone advertises images" true
    (Runtime_agent.provider_caps_of_config provider).supports_image_input;
  check bool "the model has no image capability declaration" true
    (Option.is_none text_runtime.model.capabilities);
  check bool "absent model declaration withholds admission" false
    (Runtime_agent.runtime_accepts_image_input ~runtime:text_runtime);
  let cell = ref None in
  with_bundle_tools ~agent_cell:cell
    ~check_bundle:(fun _config bundle net sw ->
      let allowed = bundle.Keeper_tools_agent_core.project_for_runtime
          ~runtime:image_runtime ~carried:[] in
      let denied = bundle.project_for_runtime ~runtime:text_runtime ~carried:[] in
      let check_denied (view : Keeper_tools_agent_core.model_tool_surface) =
        check bool "fixed and official-client schemas omit native pixels" false (has_image view.tools);
        check bool "Agent Core schemas omit native pixels" false (has_image view.agent_core_tools);
        check bool "official-client deferred names omit native pixels" false
          (List.mem image_name view.on_demand_tool_names);
        check bool "official-client bounds omit the withheld tool" false
          (List.mem_assoc image_name view.result_bounds);
        let loader = tool_named view.agent_core_tools Keeper_identity_tool_search.tool_name in
        check bool "the deferred listing omits native pixels" false
          (contains ~needle:image_name loader.schema.description);
        check bool "delegated analysis remains available" true
          (List.mem "keeper_analyze_image" view.on_demand_tool_names)
      in
      check_denied denied;
      check bool "declared image input keeps the official schema" true (has_image allowed.tools);
      check bool "unrelated handlers are shared across views" true
        (tool_named allowed.tools "keeper_analyze_image"
         == tool_named denied.tools "keeper_analyze_image");
      let run_view ~accepted (view : Keeper_tools_agent_core.model_tool_surface) =
        let requests = ref 0 and read_dispatches = ref 0 in
        let response content stop_reason : Agent_core.Types.api_response =
          {id="projection-fixture";model="image-projection-uncatalogued";
           unreadable_tool_uses = [];
           stop_reason;content;usage=None;telemetry=None} in
        let complete (request : Llm_provider.Llm_transport.completion_request) =
          incr requests;
          check bool "every actual completion uses the projected image schemas"
            (accepted && !requests > 1)
            (List.exists (fun schema -> Yojson.Safe.Util.member "name" schema = `String image_name)
               request.tools);
          match !requests with
          | 1 -> response [Llm_provider.Types.ToolUse {
              id="load-native-image";name=Keeper_identity_tool_search.tool_name;
              input=`Assoc ["names",`List [`String image_name]]}] Agent_core.Types.StopToolUse
          | 2 -> response [Llm_provider.Types.Text "projection checked"] Agent_core.Types.EndTurn
          | _ -> fail "projection fixture must finish after one loader result" in
        let transport = Llm_provider.Llm_transport.custom {
          complete_sync=(fun request -> {response=Ok (complete request);latency_ms=None});
          complete_stream=(fun ?on_telemetry:_ ~on_event:_ request -> Ok (complete request))} in
        let accepts_image_input = match view.image_admission with
          | Image_input_admitted -> true | Image_input_unavailable -> false in
        let hooks = {Agent_core.Hooks.empty with pre_tool_use=Some (fun event ->
          (match event with
           | Agent_core.Hooks.PreToolUse {tool_name;_} ->
             if tool_name=image_name then incr read_dispatches
           | BeforeTurn _ | BeforeTurnParams _ | AfterTurn _ | PostToolUse _
           | PostToolUseFailure _ | OnStop _ | OnError _ | OnToolError _ -> ());
          Keeper_image_read.admission_hook ~accepts_image_input event)} in
        let options = {Agent_core.Agent.default_options with provider_config=Some provider;
          transport=Some transport;hooks} in
        let agent = Agent_core.Agent.create ~media_store:(Agent_core.History.Memory_store.create ())
            ~config:(Agent_core.Types.default_config ~model:"image-projection-uncatalogued")
            ~net ~tools:view.agent_core_tools ~options () in
        cell := Some agent;
        (
          (match Agent_core.Agent.run ~sw agent "Load the native image tool once." with
           | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
          check int "only injected completion callbacks ran" 2 !requests;
          check int "loading or refusing a schema never dispatches an image read" 0 !read_dispatches;
          let messages = (Agent_core.Agent.checkpoint ~session_id:"projection" agent).messages in
          let outcomes = List.concat_map (fun (message : Agent_core.Types.message) -> message.content)
              messages |> List.filter_map (function
                | Agent_core.Types.ToolResult {tool_use_id;outcome;_} ->
                  if tool_use_id="load-native-image"
                  then Some (Agent_core.Types.tool_result_outcome_is_error outcome) else None
                | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
                | ToolUse _ | Image _ | Document _ | Audio _ -> None) in
          check (list bool) "the actual loader result distinguishes load from refusal"
            [not accepted] outcomes;
          let carried = Agent_core.Tool_set.to_list (Agent_core.Agent.tools agent) in
          if accepted then begin
            let next = bundle.project_for_runtime ~runtime:text_runtime ~carried in
            check_denied next;
            (* Even before replacing the previous, broader agent in the cell,
               its held image tool cannot escape through the new listing. *)
            let loader = tool_named next.agent_core_tools Keeper_identity_tool_search.tool_name in
            let invocation = tool_invocation ~tool_use_id:"refuse-held-image" loader in
            (match Agent_core.Tool.execute ~invocation loader
                (`Assoc ["names",`List [`String image_name]]) with
             | Error _ -> () | Ok _ -> fail "prior held image tool escaped the projected loader");
            let invocation = tool_invocation ~tool_use_id:"retain-held-listing" loader in
            (match Agent_core.Tool.execute ~invocation loader
                (`Assoc ["names",`List [`String Keeper_identity_tool_search.tool_name]]) with
             | Ok _ -> () | Error _ -> fail "the admitted listing must remain acknowledged as callable");
            let restored = bundle.project_for_runtime ~runtime:image_runtime ~carried:[] in
            check bool "withholding a view preserves the pending canonical load receipt" true
              (has_image restored.agent_core_tools)
          end;
          carried) in
      let carried = run_view ~accepted:true allowed in
      let next = bundle.project_for_runtime ~runtime:text_runtime ~carried in
      ignore (run_view ~accepted:false next);
      check bool "a later candidate cannot mutate the saved admitted view" true (has_image allowed.tools);
      check bool "a later candidate cannot mutate the saved withheld view" false (has_image denied.tools))
    (fun _ _ _ _ _ _ -> ());
  with_bundle_tools ~with_identity_surface:false
    ~check_bundle:(fun _config bundle _net _sw ->
      let view = bundle.Keeper_tools_agent_core.project_for_runtime ~runtime:text_runtime ~carried:[] in
      check bool "eager fallback also omits native pixels" false (has_image view.agent_core_tools);
      check bool "eager fallback retains delegated analysis" true
        (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name="keeper_analyze_image")
           view.agent_core_tools))
    (fun _ _ _ _ _ _ -> ())
;;

(* Two legal completed run_named requests over the real HTTP transport, using
   one bundle/Agent cell. A tool checkpoint forbids same-run failover, so this
   tests a candidate change between fresh requests without replaying pending
   work on a different runtime. Both endpoints are owned loopback fixtures. *)
let test_driver_image_projection_candidate_change () =
  let cell = ref None in
  with_bundle_tools ~agent_cell:cell ~install_eio_context:true
    ~check_bundle:(fun config bundle net sw ->
      let image = "keeper_image_read" in
      let clock = match Eio_context.get_clock () with Ok clock -> clock | Error detail -> fail detail in
      let wire_schemas body = Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "tools" |> to_list) in
      let has_image body = List.exists (fun schema ->
        Yojson.Safe.Util.(schema |> member "function" |> member "name") = `String image)
          (wire_schemas body) in
      let reply ~tool = Yojson.Safe.to_string (`Assoc [
        "id",`String "projection-driver";"model",`String "projection-driver-model";
        "choices",`List [`Assoc ["index",`Int 0;
          "finish_reason",`String (if tool then "tool_calls" else "stop");
          "message",`Assoc (if tool then ["role",`String "assistant";"content",`Null;
            "tool_calls",`List [`Assoc ["id",`String "driver-load-image";"type",`String "function";
              "function",`Assoc ["name",`String Keeper_identity_tool_search.tool_name;
                "arguments",`String (Yojson.Safe.to_string (`Assoc ["names",`List [`String image]]))]]]]
            else ["role",`String "assistant";"content",`String "driver projection completed"])]]]) in
      let vision_views = ref [] in
      let vision = Exact_output_fixture.start_server ~sw ~net ~clock
          (Exact_output_fixture.Reply_with (fun index body ->
            vision_views := has_image body :: !vision_views;
            check bool "the vision attempt loads pixels only after its loader result"
              (index > 0) (has_image body);
            if index=0 then `OK,reply ~tool:true
            else if index=1 then `OK,reply ~tool:false
            else fail "vision fixture received an unexpected extra provider round")) in
      let text = Exact_output_fixture.start_server ~sw ~net ~clock
          (Exact_output_fixture.Reply_with (fun index body ->
            check bool "the text attempt never transmits the carried image schema" false (has_image body);
            List.iter (fun schema ->
              let fn=Yojson.Safe.Util.member "function" schema in
              if Yojson.Safe.Util.member "name" fn = `String Keeper_identity_tool_search.tool_name then
                check bool "the text attempt's loader does not advertise native pixels" false
                  (contains ~needle:image Yojson.Safe.Util.(fn |> member "description" |> to_string)))
              (wire_schemas body);
            if index=0 then `OK,reply ~tool:true
            else if index=1 then begin
              check bool "the actual HTTP transcript retains the deferred refusal" true
                (contains ~needle:("not in the list: " ^ image) body);
              `OK,reply ~tool:false
            end else fail "text fixture received an unexpected extra provider round")) in
      let config_source ~text_declared = Printf.sprintf {|[runtime]
default = "projection_vision.vision"
[providers.projection_vision]
protocol = "openai-compatible-http"
endpoint = %S
[providers.projection_text]
protocol = "openai-compatible-http"
endpoint = %S
[models.vision]
api-name = "projection-driver-model"
max-context = 100000
[models.vision.capabilities]
supports-image-input = true
supports-multimodal-inputs = true
[models.selected]
api-name = "projection-driver-model"
max-context = 100000
%s
[projection_vision.vision]
[projection_text.selected]
|} vision.base_url text.base_url
        (if text_declared then "[models.selected.capabilities]\nsupports-image-input = true\nsupports-multimodal-inputs = true\n" else "") in
      let previous=Runtime.For_testing.snapshot () in
      let path=Filename.concat config.Workspace.base_path "image-driver-runtime.toml" in
      let load text_declared =
        Out_channel.with_open_text path (fun out -> output_string out (config_source ~text_declared));
        match Runtime.init_default ~config_path:path with Ok () -> () | Error detail -> fail detail in
      Fun.protect ~finally:(fun () -> Runtime.For_testing.restore previous;Sys.remove path) (fun () ->
        load false;
        let captured=ref [] and attempts=ref [] and native_reads=ref 0 in
        let project_for_runtime ~runtime ~carried =
          if runtime.Runtime_instance.id="projection_text.selected" then
            check bool "the real driver carries the completed request's loaded image for narrowing" true
              (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name=image) carried);
          let view=bundle.Keeper_tools_agent_core.project_for_runtime ~runtime ~carried in
          captured := (runtime.Runtime_instance.id,view) :: !captured;view in
        let hooks={Agent_core.Hooks.empty with pre_tool_use=Some (fun event ->
          (match event with Agent_core.Hooks.PreToolUse {tool_name;_} when tool_name=image -> incr native_reads
           | _ -> ());Agent_core.Hooks.Continue)} in
        let run_request runtime_id goal =
          Eio.Time.with_timeout_exn clock Exact_output_fixture.fixture_wait_seconds (fun () ->
          Keeper_turn_driver.run_named
            ~input_source:(Keeper_request_source.Keeper_history {trace_id="projection-driver"})
            ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk
            ~base_path:config.base_path ~media_store:(Agent_core.History.Memory_store.create ())
            ~runtime_id ~keeper_name:"projection-driver"
            ~system_prompt:"Exercise only the owned image-tool projection fixture."
            ~goal ~tools:bundle.tools
            ~agent_core_tools:bundle.agent_core_tools ~project_for_runtime ~agent_ref:cell ~hooks
            ~on_runtime_attempt:(fun attempt ->
              attempts := attempt.Keeper_turn_driver.runtime_id :: !attempts;
              if attempt.runtime_id="projection_text.selected" then load true)
            ~sw ~net ())
        in
        let assert_completed runtime_id = function
          | Ok selected ->
            check string "real driver used the requested candidate" runtime_id
              selected.Keeper_turn_driver.selected_runtime_id;
            (match selected.run_result.stop_reason with
             | Runtime_agent.Completed _ -> ()
             | Yielded_to_durable_stimulus _
             | InputRequired _ -> fail "candidate did not complete its own request")
          | Error error -> fail (Agent_core.Error.to_string error)
        in
        assert_completed "projection_vision.vision"
          (run_request "projection_vision.vision" "Load the native image tool once.");
        let image_agent = match !cell with Some agent -> agent | None -> fail "image Agent missing" in
        check bool "the completed image request really loaded its image schema" true
          (Agent_core.Tool_set.mem image (Agent_core.Agent.tools image_agent));
        assert_completed "projection_text.selected"
          (run_request "projection_text.selected" "Try loading the image tool in this new request.");
        check (list string) "the actual fresh requests use both candidate snapshots"
          ["projection_vision.vision";"projection_text.selected"] (List.rev !attempts);
        (match List.rev !vision_views with
         | false :: true :: rest when List.for_all Fun.id rest -> ()
         | _ -> fail "the completed vision request must load and transmit the image schema");
        check int "neither loading nor refusing dispatches a native image read" 0 !native_reads;
        check int "image candidate completes after its actual loader success" 2 (Atomic.get vision.posts);
        check int "text candidate finishes after its actual loader refusal" 2 (Atomic.get text.posts);
        let final_agent=match !cell with Some agent -> agent | None -> fail "driver did not retain its Agent" in
        check bool "the text Agent cannot carry the old native image tool" false
          (Agent_core.Tool_set.mem image (Agent_core.Agent.tools final_agent));
        let selected=match Runtime.get_runtime_by_id "projection_text.selected" with
          | Some runtime -> runtime | None -> fail "replacement fixture runtime is missing" in
        check bool "the private fixture catalog changed after candidate capture" true
          (Runtime_agent.runtime_accepts_image_input ~runtime:selected);
        let loader=match Agent_core.Tool_set.find Keeper_identity_tool_search.tool_name
            (Agent_core.Agent.tools final_agent) with Some loader -> loader | None -> fail "loader missing" in
        let invocation=tool_invocation ~tool_use_id:"captured-image-defense" loader in
        let defense=(Agent_core.Agent.options final_agent).hooks.pre_tool_use in
        let event=Agent_core.Hooks.PreToolUse {
          invocation;tool_name=image;input=`Assoc ["artifact",`String "never-read"];usage=None} in
        check bool "the actual host hook retains the exact captured false admission" true
          (Option.map (fun hook -> hook event) defense
           = Some (Keeper_image_read.admission_hook ~accepts_image_input:false event));
        check (list bool) "saved candidate views retain their original admissions"
          [true;false]
          (List.rev_map (fun (_,view) -> match view.Keeper_tools_agent_core.image_admission with
             | Image_input_admitted -> true | Image_input_unavailable -> false) !captured)))
    (fun _ _ _ _ _ _ -> ())
;;

let fetch_blob_exn ~base_path reference =
  match
    Tool_blob_store.fetch
      (Tool_blob_store.create ~base_path)
      ~sha256:reference.Tool_output.sha256
  with
  | Ok (Some payload) -> payload
  | Ok None -> fail "capability output blob is absent"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
;;

let decode_tool_json ~base_path content =
  match Tool_output.decode_from_agent_core content with
  | Tool_output.Not_marker -> Yojson.Safe.from_string content
  | Tool_output.Invalid_marker { detail } -> fail detail
  | Tool_output.Decoded reference ->
    let stored = fetch_blob_exn ~base_path reference |> Yojson.Safe.from_string in
    if String.equal reference.mime Tool_output.artifact_manifest_mime
    then
      (match Tool_output.artifact_manifest_of_json stored with
       | Tool_output.Decoded_artifact_manifest { structured_content; _ } ->
         structured_content
       | Tool_output.Not_artifact_manifest ->
         fail "capability output artifact is not a typed result manifest"
       | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)
    else stored
;;

let test_tools_list_reads_the_supplied_capability_surface () =
  with_bundle_tools
  @@ fun config _meta _snapshot _composition_plan_index capability_surface tools ->
  let tool =
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name "keeper_tools_list")
        tools
    with
    | Some tool -> tool
    | None -> fail "keeper_tools_list is absent from the supplied surface"
  in
  let observed =
    run_tool ~tool_use_id:"bundle-capability-surface" tool (`Assoc [])
    |> decode_tool_json ~base_path:config.base_path
  in
  let expected_text =
    Keeper_tool_shared_runtime.keeper_tools_list_json_for_surface
      ~capability_surface
  in
  check string "production bundle uses the exact supplied surface"
    (Yojson.Safe.to_string (Yojson.Safe.from_string expected_text))
    (Yojson.Safe.to_string observed);
  (* The full descriptor rows of this surface were 292,804 bytes, above every
     lane's inline ceiling, so the model only ever read a blob marker. *)
  check bool "the whole inventory fits the smallest lane inline ceiling" true
    (String.length expected_text <= Common.max_tool_result_wire_bytes);
  let active_tool_names =
    Yojson.Safe.Util.(observed |> member "tools" |> member "active" |> to_list)
    |> List.map (fun row -> Yojson.Safe.Util.(row |> member "name" |> to_string))
  in
  if not (List.mem "Read" active_tool_names)
  then fail "complete inventory omitted Read from the active Tools"
  else (
    check string "the inventory names the frozen surface it was built from"
      (Keeper_capability_surface.digest capability_surface)
      Yojson.Safe.Util.(observed |> member "surface_digest" |> to_string);
    let search_tool =
      match
        List.find_opt
          (fun (tool : Agent_core.Tool.t) ->
             String.equal tool.schema.name "keeper_capability_search")
          tools
      with
      | Some tool -> tool
      | None -> fail "keeper_capability_search is absent from the supplied surface"
    in
    let search =
      run_tool
        ~tool_use_id:"bundle-capability-search-scope"
        search_tool
        (`Assoc [ "query", `String "tool_read_file" ])
      |> decode_tool_json ~base_path:config.base_path
    in
    check string "search uses the frozen capability authority"
      "frozen_capability_surface"
      Yojson.Safe.Util.(search |> member "search_scope" |> to_string);
    check string "search reports the supplied surface digest"
      (Keeper_capability_surface.digest capability_surface)
      Yojson.Safe.Util.(search |> member "surface_digest" |> to_string);
    let matches = Yojson.Safe.Util.(search |> member "matches" |> to_list) in
    check bool "search answers from the frozen surface" true
      (List.exists
         (fun row ->
            String.equal
              "active"
              Yojson.Safe.Util.(
                row
                |> member "candidate"
                |> member "capability"
                |> member "availability"
                |> to_string))
         matches);
    let search_names id input =
      run_tool ~tool_use_id:id search_tool input
      |> decode_tool_json ~base_path:config.base_path
      |> Yojson.Safe.Util.member "matches"
      |> Yojson.Safe.Util.to_list
      |> List.map (fun row ->
        Yojson.Safe.Util.(row |> member "matched_name" |> to_string),
        Yojson.Safe.Util.(row |> member "invocation_name")) in
    let literal = search_names "bundle-capability-literal-skill"
        (`Assoc ["query",`String "gate-inline"]) in
    check bool "a plain hyphenated Skill name returns its real callable name" true
      (List.mem ("gate-inline",`String "keeper_compose_gate-inline") literal);
    let expressions = search_names "bundle-capability-expression"
        (`Assoc ["query",`String "\"gate-inline\" OR \"gate-async\"";"syntax",`String "fts5"]) in
    check bool "explicit FTS preserves both matching Skill invocations" true
      (List.mem ("gate-inline",`String "keeper_compose_gate-inline") expressions &&
       List.mem ("gate-async",`String "keeper_compose_gate-async") expressions))
;;

let run_composition_tool ?expected_failure (tool : Agent_core.Tool.t) =
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"bundle-composition-activation"
      ~turn:1
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
  in
  match Agent_core.Tool.execute ~invocation tool (`Assoc []), expected_failure with
  | Ok _, None -> ()
  | Error error, Some expected ->
    check bool "expected submission failure" true
      (contains ~needle:expected error.Agent_core.Types.message)
  | Ok _, Some expected -> failf "expected %s failure" expected
  | Error error, None -> fail error.Agent_core.Types.message
;;

let test_composition_activation_is_durable ?expected_failure ~skill_name tool_name =
  with_bundle_tools (fun config meta snapshot _composition_plan_index _surface tools ->
    let tool =
      match
        List.find_opt
          (fun (tool : Agent_core.Tool.t) ->
             String.equal tool.schema.name tool_name)
          tools
      with
      | Some tool -> tool
      | None -> failf "%s missing from exact snapshot bundle" tool_name
    in
    run_composition_tool ?expected_failure tool;
    let ledger =
      match
        Keeper_skill_activation_ledger.load
          ~config
          ~trace_id:meta.runtime.trace_id
      with
      | Ok ledger -> ledger
      | Error error ->
        fail (Keeper_skill_activation_ledger.store_error_to_string error)
    in
    match Keeper_skill_activation_ledger.activations ledger with
    | [ activation ] ->
      assert_exact_activation
        snapshot
        (snapshot_reference snapshot skill_name)
        activation;
      (match activation.invocation with
       | Keeper_skill_activation_ledger.Composition_invocation
           { origin = Session_composition; tool_name = observed; _ } ->
         check string "exact composition origin" tool_name observed
       | Keeper_skill_activation_ledger.Composition_invocation
           { origin = Task_composition _; _ }
       | Keeper_skill_activation_ledger.Instruction_invocation _
       | Keeper_skill_activation_ledger.Nested_composition_invocation _ ->
         fail "composition activation kept the wrong typed origin")
    | activations ->
      failf "expected one composition activation, got %d" (List.length activations))
;;

let test_task_selected_composition_is_callable_without_loading () =
  with_bundle_tools ~agent_core:true ~deferred_compositions:true
    ~task_skill_names:["gate-inline"; "gate-result"] ~current_task_id:(Some "task-001")
    (fun config meta snapshot _index _surface tools ->
      let name = "keeper_compose_gate-inline" in
      let tool = match List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) tools with
        | Some tool -> tool | None -> fail "exact Task composition was absent from the first callable surface" in
      check bool "the exact Task plan's ordinary result Tool is callable without a load" true
        (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_job_result") tools);
      check bool "one-call upstream recipe control needs no preliminary loader" true
        (List.exists (fun (tool : Agent_core.Tool.t) ->
          tool.schema.name = Keeper_composition_draft.run_tool_name) tools);
      check bool "another deferred composition remains behind the loader" false
        (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_compose_gate-async") tools);
      let before = match Keeper_skill_activation_ledger.load_existing ~config ~trace_id:meta.runtime.trace_id with
        | Ok None -> []
        | Ok (Some ledger) -> Keeper_skill_activation_ledger.activations ledger
        | Error error -> fail (Keeper_skill_activation_ledger.store_error_to_string error) in
      check int "providing a schema records no activation" 0 (List.length before);
      run_composition_tool tool;
      let ledger = match Keeper_skill_activation_ledger.load_existing ~config ~trace_id:meta.runtime.trace_id with
        | Ok (Some ledger) -> ledger
        | Ok None -> fail "actual exact composition call did not record activation"
        | Error error -> fail (Keeper_skill_activation_ledger.store_error_to_string error) in
      match Keeper_skill_activation_ledger.activations ledger with
      | [activation] -> assert_exact_activation snapshot (snapshot_reference snapshot "gate-inline") activation
      | _ -> fail "one actual exact composition call must retain one activation")
;;

let test_task_schema_readiness_keeps_other_task_and_profile_boundaries () =
  List.iter (fun (current_task_id, tool_deny) ->
    with_bundle_tools ~agent_core:true ~deferred_compositions:true
      ~task_skill_names:["gate-inline"] ~current_task_id ~tool_deny
      (fun _config _meta _snapshot _index _surface tools ->
        check bool "other Task or denied node cannot preload a composition" false
          (List.exists (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_compose_gate-inline") tools)))
    [Some "task-002", []; None, []; Some "task-001", ["keeper_lane_status"]]
;;

let test_inline_composition_activation_is_durable () =
  test_composition_activation_is_durable
    ~skill_name:"gate-inline"
    "keeper_compose_gate-inline"
;;

let test_async_composition_activation_is_durable () =
  test_composition_activation_is_durable
    ~expected_failure:"background_switch_unavailable"
    ~skill_name:"gate-async"
    "keeper_compose_gate-async"
;;

(* Guards against an empty-list false pass: a bundle that produced nothing
   would satisfy every assertion below by vacuity. *)
let test_the_bundle_is_not_empty () =
  with_bundle (fun _ names ->
    check bool "the keeper is handed tools at all" true (names <> []);
    (* Without these the gate would pass by not looking at anything. Each is a
       kind of undescribed tool the policy has an arm for. *)
    List.iter
      (fun expected ->
         check bool
           (Printf.sprintf "%s is in the bundle the gate walks" expected)
           true (List.mem expected names))
      [ "keeper_compose_gate-inline"
      ; "keeper_compose_gate-async"
      ; Keeper_tool_composition_catalog.status_tool_name
      ; Keeper_tool_composition_catalog.cancel_tool_name
      ; Keeper_tool_composition_catalog.skill_tool_name
      ])
;;

let test_skill_bundle_without_activation_context_is_rejected () =
  check_raises
    "Skill surface cannot bypass durable activation recording"
    (Invalid_argument
       "Skill-bearing Keeper bundle requires a frozen activation context")
    (fun () ->
       with_bundle_tools ~record_activations:false
         (fun _config _meta _snapshot _composition_plan_index _surface _tools -> ()))
;;

(* The point of the tool is that a body reaches the keeper. A tool that is on
   the surface and classifiable but answers nothing would pass every other
   assertion here. *)
let test_the_skill_tool_serves_the_body () =
  with_bundle_tools (fun config meta snapshot _composition_plan_index _surface tools ->
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name
             Keeper_tool_composition_catalog.skill_tool_name)
        tools
    with
    | None -> fail "the instruction skill put no tool on the surface"
    | Some tool ->
      check bool "the description names the skill it can serve" true
        (contains ~needle:"gate-instruction" tool.schema.description);
      let reference = instruction_reference () in
      let served = run_tool tool (Skill_reference.to_yojson reference) in
      check bool "asking by exact reference returns the body" true
        (contains ~needle:"body" served);
      let served_again =
        run_tool
          ~tool_use_id:"bundle-instruction-activation-second"
          tool
          (Skill_reference.to_yojson reference)
      in
      check bool "second invocation also returns the body" true
        (contains ~needle:"body" served_again);
      let ledger =
        match
          Keeper_skill_activation_ledger.load
            ~config
            ~trace_id:meta.runtime.trace_id
        with
        | Ok ledger -> ledger
        | Error error ->
          fail (Keeper_skill_activation_ledger.store_error_to_string error)
      in
      (match Keeper_skill_activation_ledger.activations ledger with
       | [ first; second ] ->
         assert_exact_activation snapshot reference first;
         assert_exact_activation snapshot reference second
       | activations ->
         failf "expected two instruction activations, got %d"
           (List.length activations));
      let stale =
        Skill_reference.make
          ~identity:reference.identity
          ~content_revision:
            (Skill_reference.content_revision_of_source_text "stale body")
      in
      let missing = run_tool tool (Skill_reference.to_yojson stale) in
      check bool "an exact reference the turn does not carry is refused" true
        (contains ~needle:"no instruction Skill matches exact reference" missing);
      check bool "and the refusal lists what it does carry" true
        (contains ~needle:"gate-instruction" missing))
;;

(* task-828: keepers that know a skill by name but not by revision sent ""
   (and copied placeholders) and were answered by a schema length error that
   could not name the catalog. The refusal has to hand back the exact
   references this keeper carries, revision included, so the next call can
   be the right one. *)
let test_a_revisionless_ask_is_taught_the_exact_reference () =
  with_bundle_tools (fun _config _meta _snapshot _composition_plan_index _surface tools ->
    match
      List.find_opt
        (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name
             Keeper_tool_composition_catalog.skill_tool_name)
        tools
    with
    | None -> fail "the instruction skill put no tool on the surface"
    | Some tool ->
      let reference = instruction_reference () in
      let name_only =
        match Skill_reference.to_yojson reference with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if String.equal key "content_revision"
                  then key, `String ""
                  else key, value)
               fields)
        | other -> other
      in
      let taught = run_tool tool name_only in
      check bool "an empty revision is refused, not served" true
        (contains ~needle:"requires one canonical exact Skill reference" taught);
      check bool "the refusal carries the references this keeper holds" true
        (contains ~needle:"this keeper carries:" taught);
      check bool "the taught list includes the revision to copy verbatim" true
        (contains
           ~needle:
             (Skill_reference.content_revision_to_string
                reference.content_revision)
           taught))
;;

let test_every_bundle_tool_is_classifiable () =
  with_bundle (fun composition_plan_index names ->
    (* The bundle offers [identity_tools ()], so this turn's index is built
       from the same list, as turn setup builds it from the tools it kept. *)
    let identity_tool_index =
      Masc.Keeper_identity_tool_index.of_tools (identity_tools ())
    in
    let unclassifiable =
      List.filter
        (fun tool_name ->
           not
             (Policy.classifies ~identity_tool_index
                ~composition_plan_index:(Some composition_plan_index) ~tool_name))
        names
    in
    match unclassifiable with
    | [] -> ()
    | names ->
      failf
        "the approval policy cannot classify %d tool(s) the bundle hands the \
         model: %s.\n\
         Each will ask the operator for approval with no reason they can act \
         on. A tool with a Keeper_tool_descriptor is classified by its group; \
         one without needs an arm in \
         Keeper_tool_approval_policy.verdict_for_undescribed."
        (List.length names)
        (String.concat ", " names))
;;

(* Names are unique, so a duplicate cannot hide an unclassifiable twin behind
   a classifiable one of the same name. *)
let test_bundle_names_are_unique () =
  with_bundle (fun _ names ->
    check
      int
      "bundle model names are unique"
      (List.length names)
      (List.length (List.sort_uniq String.compare names)))
;;

let test_bundle_matches_expected_projection () =
  with_bundle_tools (fun _config _meta snapshot _index _surface tools ->
    let names = List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools in
    let skill_catalog =
      match Keeper_skill_catalog.of_snapshot snapshot with
      | catalog, [] -> catalog
      | _, _ :: _ -> fail "bundle Skill snapshot projection was rejected"
    in
    (* [tools] is the official-client shape: the attached tools are in it as
       themselves, because those lanes cannot widen a running turn and a
       listing would name tools they can never make callable. The Agent Core
       shape lives in [agent_core_tools] and carries the listing instead. *)
    let identity_names =
      List.map
        (fun (offered : Keeper_identity_tools.offered_tool) ->
           offered.Keeper_identity_tools.schema.name)
        (identity_tools ())
    in
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        (* Named from the same fixture the bundle was handed. Passing [] here
           while the bundle carries them is what this check exists to catch,
           and it did. *)
        ~identity_names
        ~skill_catalog
        ~model_visible_descriptors:(Keeper_tool_descriptor.model_visible_descriptors ())
        ()
    in
    check
      (list string)
      "instruction and composition tools match the expected projection"
      expected
      (List.sort_uniq String.compare names);
    (* Measure the executable bundle's actual schemas, built independently of
       the schema-only profile path. Shared controls are not per-Skill bytes. *)
    Keeper_skill_observability.of_catalog skill_catalog
    |> List.iter (fun (profile : Keeper_skill_observability.profile) ->
      match profile.surface with
      | Keeper_skill_observability.Instruction_skill -> ()
      | Composition_skill _ ->
        let delivered =
          match List.find_opt (fun (tool : Agent_core.Tool.t) ->
            String.equal tool.schema.name profile.activation_tool) tools with
          | Some tool -> tool
          | None -> failf "profile activation tool missing: %s" profile.activation_tool
        in
        check (option int)
          (profile.activation_tool ^ " exact delivered schema-component bytes")
          (Some (Keeper_skill_observability.tool_component_bytes delivered))
          profile.tool_schema_bytes);
    let task_reference = snapshot_reference snapshot "gate-instruction" in
    let task_selection =
      match Keeper_task_skill_turn.resolve ~snapshot [ task_reference ] with
      | Ok selection -> selection
      | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
    in
    match
      Keeper_effective_tool_surface.For_testing.project
        ~keeper_name:"bundle-classifiable"
        ~runtime_id:"test.runtime"
        ~skills_left_out:[]
        ~official_client_kind:"agent_core"
        ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
        ~native_posture:None
        ~tool_deny:[]
        ~sandbox_profile:Masc.Keeper_types_profile.Docker
        ~skill_names:None
        ~current_task_id:(Some "task-001")
        ~task_skill_references:[ task_reference ]
        ~skill_snapshot:snapshot
        ~task_selection:(Some task_selection)
    with
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
    | Ok surface ->
      let effective_names =
        identity_names
        @ List.map
            (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
            surface.tools
        |> List.sort_uniq String.compare
      in
      check (list string) "actual bundle equals effective surface" effective_names
        (List.sort_uniq String.compare names))
;;

let test_bundle_effect_contracts () =
  with_bundle_tools
  @@ fun _config _meta _snapshot _index _surface tools ->
  let call_effect name input =
    match List.find_opt (fun (tool : Agent_core.Tool.t) ->
      String.equal tool.schema.name name) tools with
    | Some tool -> Agent_core.Tool.call_effect tool input
    | None -> fail ("fixture tool missing: " ^ name)
  in
  let check_effect name input expected =
    check bool (name ^ " effect contract") true (call_effect name input = expected)
  in
  check_effect "Read" (`Assoc ["file_path", `String "fixture.txt"])
    Agent_core.Tool.Read_only;
  check_effect "masc_board_list" (`Assoc []) Agent_core.Tool.Read_only;
  check_effect "keeper_compose_gate-inline" (`Assoc []) Agent_core.Tool.Read_only;
  check_effect "keeper_compose_gate-async" (`Assoc []) Agent_core.Tool.Effect_possible;
  check_effect "keeper_compose_gate-mixed" (`Assoc []) Agent_core.Tool.Effect_possible;
  check_effect "Write" (`Assoc []) Agent_core.Tool.Effect_possible;
  check_effect "Execute" (`Assoc []) Agent_core.Tool.Effect_possible
;;

(* A provider that refuses recursive JSON Schemas rejects the whole request,
   not only a call to the tool that carries one (Muse: 400 "Recursive JSON
   schemas are not currently supported"). The composition recipe schema was
   advertised with a recursive [$defs] and [$ref] (#43137), and every Muse
   keeper that loaded that schema through its own tool search then failed each
   turn until the build with #43150 was running: one keeper made no successful
   turn for about fourteen hours. #43150 pins that one schema. This walks the
   bundle a keeper is handed, so the next tool that carries a reference fails
   here and not in a keeper's turn.

   It does not look for a cycle: any [$ref] or [$defs] key fails. No tool in
   the bundle holds either today, and it is not known whether Muse also
   refuses a reference that does not recurse. *)
let rec has_schema_reference = function
  | `Assoc fields ->
    List.exists
      (fun (key, value) ->
         String.equal key "$ref"
         || String.equal key "$defs"
         || has_schema_reference value)
      fields
  | `List items -> List.exists has_schema_reference items
  | _ -> false
;;

(* [tools] is every tool the turn can run, attached-service tools included.
   [agent_core_tools] holds the same built-ins and, in place of the
   attached-service schemas, one listing tool that is not in [tools]. That
   listing tool's schema is not checked here. *)
let test_no_tool_advertises_a_schema_reference () =
  with_bundle_tools
  @@ fun _config _meta _snapshot _plan_index _surface tools ->
  check bool "the run control is in the bundle the gate walks" true
    (List.exists
       (fun (tool : Agent_core.Tool.t) ->
          String.equal tool.schema.name Keeper_composition_draft.run_tool_name)
       tools);
  List.iter
    (fun (tool : Agent_core.Tool.t) ->
       match tool.schema.input_schema with
       | Some schema when has_schema_reference schema ->
         failf "%s advertises an input schema holding $ref or $defs" tool.schema.name
       | Some _ | None -> ())
    tools
;;

let () =
  run
    "keeper_tool_bundle_classifiable"
    [ ( "the bundle"
      , [ test_case "Addon exports defer and load into the running agent" `Quick
            test_addon_exports_load_into_the_running_agent
        ; test_case "materialized image admission bounds each candidate tool view" `Quick
            test_per_candidate_image_projection
        ; test_case "real HTTP candidate changes retain captured image tool admission" `Quick
            test_driver_image_projection_candidate_change
        ; test_case "effect contracts survive bundle construction" `Quick
            test_bundle_effect_contracts
        ; test_case "no tool advertises a schema reference" `Quick
            test_no_tool_advertises_a_schema_reference
        ; test_case "is not empty" `Quick test_the_bundle_is_not_empty
        ; test_case "requires activation context" `Quick
            test_skill_bundle_without_activation_context_is_rejected
        ; test_case "names are unique" `Quick test_bundle_names_are_unique
        ; test_case "matches the expected projection" `Quick
            test_bundle_matches_expected_projection
        ; test_case "async composition controls keep their contracts" `Quick
            test_async_composition_controls_keep_their_contracts
        ; test_case "the bundle is the model-visible surface" `Quick
            test_the_bundle_is_the_model_visible_surface
        ; test_case "stored-image reader is callable with read authority" `Quick
            test_stored_image_reader_is_callable_with_read_authority
        ; test_case "tools list reads supplied capability surface" `Quick
            test_tools_list_reads_the_supplied_capability_surface
        ; test_case "the skill tool serves the body" `Quick
            test_the_skill_tool_serves_the_body
        ; test_case "a revisionless ask is taught the exact reference" `Quick
            test_a_revisionless_ask_is_taught_the_exact_reference
        ; test_case "current Task exact composition runs on the first callable surface" `Quick
            test_task_selected_composition_is_callable_without_loading
        ; test_case "Task schema readiness preserves other Task and profile boundaries" `Quick
            test_task_schema_readiness_keeps_other_task_and_profile_boundaries
        ; test_case "inline composition activation is durable" `Quick
            test_inline_composition_activation_is_durable
        ; test_case "async composition activation is durable" `Quick
            test_async_composition_activation_is_durable
        ] )
    ; ( "the approval policy"
      , [ test_case "can classify every tool in it" `Quick
            test_every_bundle_tool_is_classifiable
        ] )
    ]
;;
