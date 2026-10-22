(** Isolated explicit-cycle preparation harness. The scripted streaming peer
    and an explicitly configured HTTP Runtime are separate experiment inputs.
    The owned-job CLI peer is synthetic in both cases. *)
open Masc
open Yojson.Safe.Util

module Jobs = Keeper_owned_job_store
module Calls = Keeper_tool_call_log
module Queue = Keeper_registry_event_queue
module Ledger = Keeper_reaction_ledger

let keeper = "preparation-harness"
let get render = function Ok value -> value | Error error -> failwith (render error)
let require condition detail = if not condition then failwith detail
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
    output_string channel bytes; flush channel; Unix.fsync (Unix.descr_of_out_channel channel))
let json path value =
  let temporary = path ^ ".writing" in
  write temporary (Yojson.Safe.pretty_to_string value ^ "\n");
  Unix.rename temporary path;
  let descriptor = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> Unix.fsync descriptor)
let append_event path value =
  Out_channel.with_open_gen [Open_wronly;Open_creat;Open_append;Open_binary] 0o600 path (fun channel ->
    output_string channel (Yojson.Safe.to_string value ^ "\n");
    flush channel; Unix.fsync (Unix.descr_of_out_channel channel))
let load path = Yojson.Safe.from_string (read path)
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let field name value = member name value
let string name value = field name value |> to_string
let integer name value = field name value |> to_int
type trial_clock = { tc_counter : Mtime_clock.counter; tc_ref : string }

let now counter =
  (* Epoch is wall-clock metadata, never a counter endpoint. The opaque ref
     names this driver invocation's counter; setup and each arm own new refs. *)
  let elapsed = Mtime_clock.count counter.tc_counter |> Mtime.Span.to_uint64_ns in
  `Assoc ["epoch",`Float (Unix.gettimeofday ());
    "clock_domain",`String "driver_counter";"clock_ref",`String counter.tc_ref;
    "monotonic_ns",`String (Printf.sprintf "%Lu" elapsed)]
type preparation_stage =
  | Initialize_workspace | Publish_snapshot | Install_owner | Create_keeper
  | Register_keeper | Claim_task | Build_bundle | Start_job of int | Collect_job of int
  | Deliver_setup_results | Initialize_runtime | Admit_source | Run_cycle

type stage_state = Entered | Returned | Failed

let stage_fields = function
  | Initialize_workspace -> "initialize_workspace", []
  | Publish_snapshot -> "publish_snapshot", []
  | Install_owner -> "install_owner", []
  | Create_keeper -> "create_keeper", []
  | Register_keeper -> "register_keeper", []
  | Claim_task -> "claim_task", []
  | Build_bundle -> "build_bundle", []
  | Start_job index -> "start_job", ["job_index", `Int index]
  | Collect_job index -> "collect_job", ["job_index", `Int index]
  | Deliver_setup_results -> "deliver_setup_results", []
  | Initialize_runtime -> "initialize_runtime", []
  | Admit_source -> "admit_source", []
  | Run_cycle -> "run_cycle", []

let observe_stage ~counter ~receipt stage operation =
  let name, fields = stage_fields stage in
  let record state =
    let state = match state with Entered -> "entered" | Returned -> "returned" | Failed -> "failed" in
    let event = `Assoc (["schema_version", `Int 1; "stage", `String name;
      "state", `String state; "observed", now counter] @ fields) in
    append_event (receipt ^ ".stages.jsonl") event;
    Printf.eprintf "PREPARATION_STAGE %s\n%!" (Yojson.Safe.to_string event) in
  record Entered;
  match operation () with
  | value -> record Returned; value
  | exception (Eio.Cancel.Cancelled _ as error) -> raise error
  | exception error ->
    let backtrace = Printexc.get_raw_backtrace () in
    record Failed;
    Printexc.raise_with_backtrace error backtrace

let store_error = Jobs.error_to_string
let index_error = function Calls.Index_unavailable detail -> detail
let fixture_path base = Filename.concat base "preparation-fixture.json"
let config_path base = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:base
let exact_keys expected value =
  let keys = to_assoc value |> List.map fst in
  require (List.sort String.compare keys = List.sort String.compare expected)
    ("unexpected or duplicated fields: " ^ String.concat "," keys)

type runtime_mode = Synthetic_streaming | Configured_http of string

type preparation_case = Upstream_inline | Named_inline
let preparation_case experiment = match string "case" experiment with
  | "upstream_inline" -> Upstream_inline
  | "named_inline" -> Named_inline
  | _ -> failwith "unsupported preparation case"

type synthetic_outcome = Successful | Provider_refusal | Malformed_final | Fixed_child
let synthetic_outcome experiment = match string "synthetic_outcome" experiment with
  | "success" -> Successful
  | "provider_refusal" -> Provider_refusal
  | "malformed_final" -> Malformed_final
  | "fixed_child" -> Fixed_child
  | _ -> failwith "unsupported synthetic outcome"

let runtime_mode runtime = match string "mode" runtime with
  | "synthetic_streaming" -> Synthetic_streaming
  | "configured_http" -> Configured_http (string "configuration" runtime)
  | _ -> failwith "unsupported preparation Runtime mode"

let validate_http_configuration configuration =
  let config = Runtime_toml.parse_string configuration |> get (fun _ ->
    "explicit HTTP Runtime configuration did not parse") in
  require (Option.is_some config.default_runtime_id) "explicit Runtime default is required";
  require (config.keeper_assignments = [] && config.lane_decls = [])
    "experiment must select its default Runtime without Keeper assignments or failover lanes";
  List.iter (fun (provider : Runtime_schema.provider) ->
    (match provider.transport with
     | Runtime_schema.Http _ -> ()
     | Runtime_schema.Cli _ -> failwith "configured preparation Runtime must use HTTP");
    require (provider.headers = None || provider.headers = Some [])
      "experiment authentication must use an environment credential, not inline headers";
    match provider.credentials with
    | None | Some (Runtime_schema.Env _) -> ()
    | Some (Runtime_schema.File _ | Runtime_schema.Inline _) ->
      failwith "experiment credentials must name an existing environment variable") config.providers
;;

let settings experiment =
  require (integer "schema_version" experiment = 1) "unsupported experiment schema";
  ignore (preparation_case experiment : preparation_case);
  require (integer "pairs" experiment > 0) "pairs must be positive";
  let runtime = field "runtime" experiment in
  (match runtime_mode runtime with
   | Synthetic_streaming ->
     exact_keys ["schema_version";"case";"pairs";"runtime";"synthetic_outcome"] experiment;
     exact_keys ["mode";"model_id";"max_context_tokens";"max_output_tokens"] runtime;
     let model = string "model_id" runtime in
     require (String.trim model = model && model <> "") "model_id must be explicit and nonblank";
     require (integer "max_context_tokens" runtime > 0 && integer "max_output_tokens" runtime > 0)
       "model capability declarations must be positive";
     ignore (synthetic_outcome experiment : synthetic_outcome)
   | Configured_http configuration ->
     exact_keys ["schema_version";"case";"pairs";"runtime"] experiment;
     exact_keys ["mode";"configuration"] runtime;
     validate_http_configuration configuration);
  runtime

let source_document = {|---
name: preparation-stdout
description: Read the complete stdout of the exact selected original owned job.
---

```toml composition
[[compositions]]
name = "preparation-stdout"
execution = "inline"
[[compositions.params]]
name = "job_id"
type = "string"
description = "The exact original owned job selected by the immutable input."
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
[[compositions.nodes]]
id = "consume"
tool = "keeper_artifact_read"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "sha256"
[compositions.nodes.input.fields.value]
kind = "output"
node = "result"
pointer = "/artifacts/0/_blob/sha256"
[[compositions.exports]]
name = "stdout"
node = "consume"
pointer = "/content"
```
|}

let skills_config = {|[skills]
resource-read-max-bytes = 16384
[[skills.sources]]
id = "preparation-fixture"
anchor = "base-path"
path = ".agents/skills"
access = "read-write"
|}

let publish_snapshot ~base =
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:base
      |> get Config_dir_resolver.canonical_base_path_error_to_string in
  let path = config_path base in
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path;source_text=read path}) with
   | Published _ | Unchanged _ -> ()
   | Workspace_retired -> failwith "fixture Skill workspace retired");
  let snapshot = match Skill_catalog_snapshot_service.current ~workspace with
    | Some value -> value | None -> failwith "fixture Skill snapshot absent" in
  let reference = match Skill_catalog_snapshot.entries snapshot with
    | [entry] -> Skill_catalog_snapshot.entry_reference entry
    | [] | _ :: _ -> failwith "exactly one frozen Skill is required" in
  workspace,snapshot,reference

let document ~base content =
  let bytes = match Tool_output.decode_from_agent_core content with
    | Not_marker -> content
    | Invalid_marker {detail} -> failwith detail
    | Decoded reference ->
      (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:base) ~sha256:reference.sha256 with
       | Ok (Some bytes) ->
         require (String.length bytes = reference.bytes && sha bytes = reference.sha256)
           "wire marker integrity mismatch";
         bytes
       | Ok None -> failwith "wire artifact missing"
       | Error error -> failwith (Tool_blob_store.fetch_error_to_string error)) in
  let value = Yojson.Safe.from_string bytes in
  match Tool_output.artifact_manifest_of_json value with
  | Decoded_artifact_manifest manifest -> manifest.structured_content
  | Invalid_artifact_manifest {detail} -> failwith detail
  | Not_artifact_manifest ->
    (match Tool_output.normalized_artifact_ref_of_json (field "artifact_manifest" value) with
     | Decoded_normalized_artifact_ref reference ->
       require (reference.mime=Tool_output.artifact_manifest_mime) "wrong inline manifest media type";
       ignore (Agent_core.Execution_json.object_fields ~context:"preparation public result"
         ~required:["structured_content";"artifact_manifest"] ~optional:["content"] value |> get Fun.id);
       let stored = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:base) ~sha256:reference.sha256 with
         | Ok (Some bytes) ->
           require (String.length bytes=reference.bytes && sha bytes=reference.sha256) "inline manifest integrity mismatch";
           bytes
         | Ok None -> failwith "inline manifest is unavailable"
         | Error error -> failwith (Tool_blob_store.fetch_error_to_string error) in
       let original = match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string stored) with
         | Decoded_artifact_manifest manifest -> manifest.structured_content
         | Invalid_artifact_manifest {detail} -> failwith detail
         | Not_artifact_manifest -> failwith "typed inline reference does not name a canonical manifest" in
       let delivered = field "structured_content" value in
       require (Yojson.Safe.equal delivered original) "inline content differs from durable manifest";
       delivered
     | Invalid_normalized_artifact_ref {detail} -> failwith detail
     | Not_normalized_artifact_ref ->
       require (field "structured_content" value=`Null) "unsealed structured envelope";
       value)

let invoke bundle ~id ~turn name input =
  let tool = match List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name=name)
      bundle.Keeper_tools_agent_core.tools with
    | Some tool -> tool | None -> failwith ("public tool unavailable: " ^ name) in
  let execution_mode = Agent_core.Tool.execution_mode tool ~input in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:id ~turn
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  Agent_core.Tool.execute ~invocation tool input |> get (fun error -> error.Agent_core.Types.message)

let pending base = Queue.pending_selections_result ~base_path:base keeper |> get Fun.id
let blob_bytes base (reference : Tool_output.artifact_ref) =
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:base) ~sha256:reference.sha256 with
  | Ok (Some bytes) ->
    require (sha bytes = reference.sha256 && String.length bytes = reference.bytes) "artifact integrity mismatch";
    bytes
  | Ok None -> failwith "original artifact missing"
  | Error error -> failwith (Tool_blob_store.fetch_error_to_string error)

let empty_surface ~base ~meta =
  let parsed = Skill_source_config.parse_text skills_config |> get (fun _ -> "Skill config rejected") in
  let scans = List.map (fun source_config ->
    let source = Skill_source_config.resolve ~base_path:base ~user_home:None source_config in
    let resolved_path = match source.Skill_source_config.resolution with
      | Resolved path -> path
      | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> failwith "fixture source resolution" in
    {Skill_catalog_snapshot.source;observation=Source_ready {resolved_path;candidates=0};candidates=[]}) parsed.sources in
  let snapshot = Skill_catalog_snapshot.configured ~config:parsed scans |> get (fun _ -> "empty Skill snapshot") in
  let descriptors = Keeper_tool_descriptor.all_descriptors () in
  let catalog,diagnostics = Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  require (diagnostics=[]) "empty setup catalog projection rejected";
  Keeper_capability_surface.create_with_descriptors ~tool_descriptors:descriptors ~tool_deny:[]
    ~sandbox_profile:meta.Keeper_meta_contract.sandbox_profile ~skill_names:None ~global_skill_catalog:catalog
    ~skill_inventory:(Keeper_skill_inventory.of_snapshot ~descriptors snapshot) ~task_skills:[]

let install_owner ~sw config =
  Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config
  |> get Keeper_owner_registry.install_error_to_string |> ignore

let configure_keeper ~base ~instructions =
  let path = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:base keeper in
  write path (Printf.sprintf
    "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"none\"\nactivation_mode = \"autonomous\"\ninstructions = %S\n" instructions)

let setup ~base ~experiment ~counter ~receipt ~sw ~env =
  let stage phase = observe_stage ~counter ~receipt phase in
  let config = Workspace.default_config base in
  ignore (stage Initialize_workspace (fun () ->
    Workspace.init config ~agent_name:(Some "preparation-operator")) : string);
  Masc_test_deps.write_sandbox_image_catalog ~base_path:base ["base","masc-sandbox-base:fixture-owned-job"];
  write (config_path base) skills_config;
  let skill_path = Filename.concat base ".agents/skills/preparation-stdout/SKILL.md" in
  write skill_path source_document;
  let workspace,snapshot,reference = stage Publish_snapshot (fun () -> publish_snapshot ~base) in
  Eio.Switch.on_release sw (fun () -> Skill_catalog_snapshot_service.retire ~workspace);
  let descriptors = Keeper_tool_descriptor.all_descriptors () in
  let catalog,diagnostics = Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  require (diagnostics=[]) "published Skill is not executable";
  let named_fields = match preparation_case experiment with
    | Upstream_inline -> []
    | Named_inline ->
      (match Keeper_skill_catalog.composition_entries catalog with
       | [entry] -> ["skill_tool_name",`String (Keeper_tool_composition_catalog.tool_name entry)]
       | [] | _ :: _ -> failwith "one executable named Inline Skill is required") in
  let task = Workspace.add_task_with_result ~created_by:"preparation-operator" ~skills:[reference]
      config ~title:"Read selected original stdout" ~priority:1
      ~description:"Read the immutable selection input and return the selected original job's complete stdout SHA-256."
    |> get Workspace.add_task_error_to_string in
  configure_keeper ~base ~instructions:"Follow the addressed task and report independently verified original output.";
  stage Install_owner (fun () -> install_owner ~sw config);
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper]) |> get Fun.id in
  let meta = {meta with current_task_id=Some (Keeper_id.Task_id.of_string task.task_id |> get Fun.id);
      sandbox_profile=Keeper_types_profile.Docker;sandbox_image=Some "base"} in
  ignore (stage Create_keeper (fun () -> Keeper_owner_registry.create_meta ~base_path:base meta
    |> get Keeper_owner_registry.command_error_to_string));
  let meta = match Keeper_meta_store.read_effective_meta config keeper |> get Fun.id with
    | Some value -> value | None -> failwith "effective setup Keeper missing" in
  let entry = stage Register_keeper (fun () -> Keeper_registry.register_offline ~base_path:base keeper meta) in
  Eio.Switch.on_release sw (fun () -> ignore (Keeper_registry.unregister_exact entry));
  ignore (stage Claim_task (fun () -> Workspace.claim_task_r config ~agent_name:keeper ~task_id:task.task_id ()
    |> get Masc_domain.masc_error_to_string));
  let cell = Calls.create_turn_ctx_cell () in
  Calls.set_turn_context ~cell ~agent_name:keeper ~task_id:task.task_id ~turn:0 ~keeper_turn_id:0
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ();
  let surface = empty_surface ~base ~meta in
  let publication_recovery : Keeper_publication_recovery_availability.turn_context =
    {provider=Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let bundle = stage Build_bundle (fun () ->
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface ~config ~meta
      ~publication_recovery ~capability_surface:surface ~turn_ctx_cell:cell
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"fixture input preparation")
      ~clock:env#clock ()) in
  Eio.Switch.on_release sw bundle.cleanup;
  let create index large =
    json (Filename.concat base "control.json")
      (`Assoc ["shared",`Assoc [];"jobs",`Assoc [];"armed",`List []]);
    let started = stage (Start_job index) (fun () ->
      invoke bundle ~id:("fixture-launch-" ^ string_of_int index) ~turn:0
        "keeper_job_start" (`Assoc ["argv",`List [`String "fixture-program";`String (string_of_int index)]])) in
    let start = document ~base started.content in
    require (string "phase" start = "running") "setup job did not enter canonical Running";
    let id = string "job_id" start in
    let control = ["state",`String "exited";"exit_code",`Int 0] @
      if large then ["large_logs",`Assoc ["head",`Int (String.length "alpha");"tail",`Int (String.length "omega")]] else [] in
    json (Filename.concat base "control.json") (`Assoc
      ["shared",`Assoc [];"jobs",`Assoc [id,`Assoc control];"armed",`List []]);
    ignore (stage (Collect_job index) (fun () ->
      invoke bundle ~id:("fixture-collect-" ^ string_of_int index) ~turn:0
        "keeper_job_status" (`Assoc ["job_id",`String id])));
    let record = Jobs.load ~base_path:base ~keeper_name:keeper (Jobs.Job_id.of_string id |> get Fun.id)
      |> get store_error in
    let stdout,stderr = match record.outputs with
      | Some (Jobs.Outputs_complete (stdout,stderr)) -> stdout,stderr
      | Some (Jobs.Outputs_unavailable {evidence}) ->
        failwith ("setup original outputs are unavailable: " ^ evidence)
      | None -> failwith "setup original outputs are not complete" in
    let body = blob_bytes base stdout in
    require (record.source.task_id=Some task.task_id) "setup job lost original Task identity";
    (* Independent preparation trials explicitly reset their synthetic peer.
       This is fixture setup, not evidence of real Docker resource cleanup. *)
    if Sys.file_exists (Filename.concat base "daemon.json") then Unix.unlink (Filename.concat base "daemon.json");
    `Assoc ["job_id",`String id;"source",Jobs.source_to_json record.source;
      "stdout",Tool_output.normalized_artifact_ref_to_json stdout;
      "stderr",Tool_output.normalized_artifact_ref_to_json stderr;"stdout_sha256",`String (sha body)]
  in
  let first = create 1 false in
  let second = create 2 true in
  require (string "stdout_sha256" first <> string "stdout_sha256" second) "fixture outputs are not distinct";
  let selected_id = string "job_id" second in
  let selection = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:base)
      ~bytes:selected_id ~mime:"text/plain" in
  (* Fixture setup owns these two completed jobs and has consumed their complete
     outputs. Deliver and acknowledge only those exact setup notifications
     through supported producer/queue APIs before freezing the common input.
     No turn completion or reaction timestamp is invented for this setup ACK. *)
  let delivered = stage Deliver_setup_results (fun () ->
    Keeper_owned_job_completion_wake.reconcile ~config |> get store_error) in
  require (delivered.waiting=0 && delivered.failures=[]) "fixture completion delivery is unavailable";
  let acknowledgements = pending base |> List.map (fun (pending : Keeper_event_queue_state.pending_selection) ->
    let completion = match pending.source.Keeper_event_queue.payload with
      | Keeper_event_queue.Owned_job_completed completion -> completion
      | _ -> failwith "unexpected non-job setup stimulus; refusing to discard it" in
    let job_id = Jobs.Job_id.to_string completion.oj_job_id in
    let expected = match List.filter (fun job -> string "job_id" job=job_id) [first;second] with
      | [job] -> job | [] | _ :: _ -> failwith "setup notification does not belong to an original fixture job" in
    require (Yojson.Safe.equal (Jobs.source_to_json completion.oj_source) (field "source" expected))
      "setup notification changed its original source";
    let record = Jobs.load ~base_path:base ~keeper_name:keeper completion.oj_job_id |> get store_error in
    let stdout,stderr = match record.outputs with
      | Some (Jobs.Outputs_complete (stdout,stderr)) -> stdout,stderr
      | Some (Jobs.Outputs_unavailable {evidence}) ->
        failwith ("setup notification output is unavailable: " ^ evidence)
      | None -> failwith "setup notification has no complete original output" in
    require (sha (blob_bytes base stdout)=string "stdout_sha256" expected)
      "setup notification stdout differs from the consumed original";
    ignore (blob_bytes base stderr);
    Queue.ack_pending_result ~base_path:base keeper ~selection:pending |> get Fun.id;
    `Assoc ["job_id",`String job_id;"source_snapshot_ref",`String (Keeper_event_queue_state.source_snapshot_ref pending.source);
      "admitted_revision",`String (Int64.to_string pending.admitted_revision);
      "source",Jobs.source_to_json completion.oj_source;"ack_observed",now counter]) in
  require (pending base = []) "setup unexpectedly queued a stimulus";
  json (Filename.concat base "preparation-setup-notification-acks.json")
    (`Assoc ["scope",`String "fixture_setup_only";"acks",`List acknowledgements;
      "producer_delivered",`Int delivered.delivered;"no_turn_completion_claim",`Bool true]);
  let manifest = `Assoc (named_fields @ ["schema_version",`Int 1;"base_path",`String base;"keeper",`String keeper;
      "task_id",`String task.task_id;"trace_id",`String (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
      "skill_reference",Skill_reference.to_yojson reference;"skill_document_sha256",`String (sha source_document);
      "selection",Tool_output.normalized_artifact_ref_to_json selection;"selection_sha256",`String selection.sha256;
      "jobs",`List [first;second];"selected_job_id",`String selected_id;
      "expected_stdout_sha256",field "stdout_sha256" second;"runtime",settings experiment]) in
  json (fixture_path base) manifest;
  json receipt (`Assoc ["outcome",`String "setup_complete";"observed",now counter;"fixture",manifest])

type strategy = Direct | Exact_skill
let strategy_name = function Direct -> "direct" | Exact_skill -> "exact_skill"
let strategy_of_string = function
  | "direct" -> Direct | "exact_skill" -> Exact_skill
  | name -> failwith ("unsupported strategy: " ^ name)

type objective_validation =
  | Verified_json of Yojson.Safe.t
  | Missing_final
  | Malformed_json
  | Wrong_shape
  | Wrong_original_job
  | Wrong_stdout_digest
  | Scripted_wire_mismatch

let validate_objective ~fixture ~scripted = function
  | None -> Missing_final
  | Some actual when (match scripted with Some expected -> expected<>actual | None -> false) -> Scripted_wire_mismatch
  | Some actual ->
    match Yojson.Safe.from_string actual with
    | `Assoc fields as answer ->
      if List.sort String.compare (List.map fst fields)<>["job_id";"stdout_sha256"] then Wrong_shape
      else (match List.assoc_opt "job_id" fields,List.assoc_opt "stdout_sha256" fields with
        | Some (`String job_id),Some (`String digest) ->
          if job_id<>string "selected_job_id" fixture then Wrong_original_job
          else if digest<>string "expected_stdout_sha256" fixture then Wrong_stdout_digest
          else Verified_json answer
        | _ -> Wrong_shape)
    | _ -> Wrong_shape
    | exception Yojson.Json_error _ -> Malformed_json

let objective_validation_json = function
  | Verified_json _ -> `String "verified"
  | Missing_final -> `String "missing_final"
  | Malformed_json -> `String "malformed_json"
  | Wrong_shape -> `String "wrong_shape"
  | Wrong_original_job -> `String "wrong_original_job"
  | Wrong_stdout_digest -> `String "wrong_stdout_digest"
  | Scripted_wire_mismatch -> `String "scripted_wire_mismatch"

type step = Select | Direct_result | Direct_stdout | Run | Named_skill | Finish | Finished
let step_name = function
  | Select -> "select" | Direct_result -> "direct-result" | Direct_stdout -> "direct-stdout"
  | Run -> "run" | Named_skill -> "named-skill"
  | Finish -> "finish" | Finished -> "finished"

type composition_projection = Selected_stdout | Full_actions
type composition_arguments = Selection_output | Selected_literal

let recipe ~projection ~arguments fixture =
  let selected,producers = match arguments with
    | Selection_output ->
      `Assoc ["kind",`String "output";"node",`String "arguments";"pointer",`String "/content"],
      [`Assoc ["id",`String "arguments";"tool",`String "keeper_artifact_read";
        "args",`Assoc ["sha256",field "selection_sha256" fixture]]]
    | Selected_literal ->
      `Assoc ["kind",`String "literal";"value",field "selected_job_id" fixture],[] in
  `Assoc ["execution",`String "inline";"nodes",`List
    (producers @ [`Assoc ["id",`String "resolved_stdout";"skill_reference",field "skill_reference" fixture;
      "input",`Assoc ["kind",`String "object";"fields",`List
        [`Assoc ["name",`String "job_id";"value",selected]]]]]);
    "exports",`List (match projection with
      | Selected_stdout ->
        [`Assoc ["name",`String "job_id";"node",`String "arguments";"pointer",`String "/content"];
         `Assoc ["name",`String "stdout";"node",`String "resolved_stdout";"pointer",`String "/stdout"]]
      | Full_actions -> [])]

let reference value = match Tool_output.normalized_artifact_ref_of_json value with
  | Decoded_normalized_artifact_ref reference -> reference
  | Invalid_normalized_artifact_ref {detail} -> failwith detail
  | Not_normalized_artifact_ref -> failwith "normalized artifact reference required"

let row_document ~base row = match field "output" row with
  | `String bytes -> document ~base bytes
  | value -> document ~base (blob_bytes base (reference value))

let commit_identity (event : Calls.committed_call) =
  let text value = match value with None -> `Null | Some value -> `String value in
  ["keeper",`String event.keeper_name;"tool",`String event.tool_name;
   "execution_id",text (Option.map Ids.Execution_id.to_string event.execution_id);
   "tool_use_id",text event.tool_use_id;"trace_id",text event.trace_id;
   "task_id",text event.task_id;
   "keeper_turn_id",(match event.keeper_turn_id with None -> `Null | Some value -> `Int value);
   "composition_node_id",text event.composition_node_id;
   "parent_tool_use_id",text event.parent_tool_use_id]

let commit_matches row (event : Calls.committed_call) =
  Option.is_some event.execution_id &&
  List.for_all (fun (name,value) -> Yojson.Safe.equal (field name row) value) (commit_identity event)

let decode_evidence f =
  try Some (f ()) with
  | Failure _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let original_turn_source ~fixture ~(turn : Turn_record.t) row =
  field "task_id" row=field "task_id" fixture && field "trace_id" row=field "trace_id" fixture &&
  field "keeper_turn_id" row=`Int turn.absolute_turn &&
  match Tool_result.recorded_call_outcome row with
  | Recorded_succeeded -> true
  | Recorded_deferred | Recorded_failed | Recorded_unsettled | Recorded_malformed -> false

let sdk_member ~fixture ~(turn : Turn_record.t) row =
  original_turn_source ~fixture ~turn row &&
  List.exists (fun id -> field "execution_id" row=`String (Ids.Execution_id.to_string id)) turn.execution_ids

let exact_sdk_reply ~base ~raw_records parent =
  let replies = List.filter_map (fun (record : Agent_core.Raw_trace.record) ->
    match record.record_type, record.tool_use_id, record.tool_name, record.tool_error with
    | Tool_execution_finished, Some id, Some name, Some false
      when field "tool_use_id" parent=`String id && field "tool" parent=`String name -> record.tool_result
    | (Run_started | Assistant_block | Tool_execution_started | Tool_execution_finished
      | Native_tool_started | Native_tool_finished | Hook_invoked | Run_finished), _, _, _ -> None) raw_records in
  match replies with
  | [bytes] -> document ~base bytes
  | [] | _ :: _ -> failwith "no unique original SDK run reply"

(* Both are current producer contracts: selected exports retain a complete
   execution artifact; a run without outer exports retains its full actions.
   The caller has already verified the exact SDK reply's sealed manifest. *)
let execution_nodes ~base run =
  match field "execution_artifact" run with
  | `Null ->
    require (field "exports" run=`Null) "selected exports have no canonical execution artifact";
    field "actions" run |> to_list
  | artifact -> document ~base (blob_bytes base (reference artifact)) |> field "nodes" |> to_list

let execution_run_id ~fixture ~turn ~parent ~reply rows =
  let value = match field "composition_run_id" reply,field "composition_tool" reply with
    | `String id,`String name when field "tool" parent=`String name -> id
    | `String id,`Null -> id
    | `Null,`String name when field "tool" parent=`String name ->
      (* Named Tools expose their canonical node artifact, while the original
         run identity belongs to the durable summary of this same SDK call. *)
      let summaries = List.filter (fun row -> original_turn_source ~fixture ~turn row &&
        field "tool" row=`String Keeper_tool_composition_surface.composition_run_summary_tool_name &&
        field "tool_use_id" row=field "tool_use_id" parent &&
        field "parent_tool_use_id" row=field "tool_use_id" parent) rows in
      (match summaries with
       | [summary] ->
         (match Tool_result.recorded_call_outcome summary with
          | Recorded_succeeded -> string "composition_run_id" summary
          | Recorded_deferred | Recorded_failed | Recorded_unsettled | Recorded_malformed ->
            failwith "named composition summary did not succeed")
       | [] | _ :: _ -> failwith "no unique original named composition summary")
    | _ -> failwith "composition reply did not identify its original execution" in
  let id = Keeper_tool_plan.Composition_run_id.of_string value
      |> get (fun _ -> "invalid original composition run identity") in
  `String (Keeper_tool_plan.Composition_run_id.to_string id)

let physical_execution_owned ~base ~fixture ~turn ~raw_records rows row =
  if field "composition_node_id" row=`Null then
    sdk_member ~fixture ~turn row && field "parent_tool_use_id" row=`Null
  else
    let parents = List.filter (fun parent -> sdk_member ~fixture ~turn parent &&
      field "tool_use_id" parent=field "parent_tool_use_id" row) rows in
    match parents with
    | [parent] -> decode_evidence (fun () ->
      let reply = exact_sdk_reply ~base ~raw_records parent in
      require (execution_run_id ~fixture ~turn ~parent ~reply rows=field "composition_run_id" row)
        "physical Tool belongs to a different composition";
      List.exists (fun node ->
        field "node_id" node=field "composition_node_id" row &&
        field "execution_id" node=field "execution_id" row &&
        field "tool_use_id" node=field "tool_use_id" row &&
        field "tool_name" node=field "tool" row &&
        Yojson.Safe.equal (field "input" node) (field "input" row)) (execution_nodes ~base reply)) = Some true
    | [] | _ :: _ -> false

let full_stdout_reads ~base ~fixture ~turn ~raw_records rows =
  List.filter (fun row ->
    original_turn_source ~fixture ~turn row && field "tool" row=`String "keeper_artifact_read" &&
    field "sha256" (field "input" row)=field "expected_stdout_sha256" fixture &&
    decode_evidence (fun () ->
      let page = row_document ~base row in
      field "offset" page=`Int 0 && field "eof" page=`Bool true &&
      sha (string "content" page)=string "expected_stdout_sha256" fixture) = Some true &&
    physical_execution_owned ~base ~fixture ~turn ~raw_records rows row) rows

let named_execution_proven ~base ~fixture ~turn ~raw_records rows stdout_rows
    ~(activation : Keeper_skill_activation_ledger.activation) ~tool_name =
  let parents = List.filter (fun row -> sdk_member ~fixture ~turn row &&
    field "tool" row=`String tool_name &&
    field "tool_use_id" row=`String activation.skill_tool_use_id &&
    field "turn" row=`Int activation.agent_core_turn &&
    field "input" row=`Assoc ["job_id",field "selected_job_id" fixture]) rows in
  match parents with
  | [parent] -> decode_evidence (fun () ->
    let run = exact_sdk_reply ~base ~raw_records parent in
    let nodes = execution_nodes ~base run in
    let run_id = execution_run_id ~fixture ~turn ~parent ~reply:run rows in
    List.exists (fun row ->
      field "parent_tool_use_id" row=field "tool_use_id" parent &&
      field "composition_run_id" row=run_id &&
      List.exists (fun node -> field "execution_id" node=field "execution_id" row &&
        field "tool_use_id" node=field "tool_use_id" row &&
        field "node_id" node=field "composition_node_id" row &&
        field "tool_name" node=field "tool" row &&
        Yojson.Safe.equal (field "input" node) (field "input" row)) nodes) stdout_rows) = Some true
  | [] | _ :: _ -> false

(* A templated input may contain only constants. Its serialized "upstream"
   kind is not proof that this child consumed an in-run producer's output. *)
let selection_dependency_proven ~base ~fixture ~turn ~parent ~draft ~argument_node ~composition_run_id ~nodes rows =
  let module Plan = Keeper_tool_plan in
  let canonical = field "nodes" (field "plan" draft) |> to_list in
  let unique id values = match List.filter (fun node -> field "id" node=`String id) values with
    | [node] -> node
    | [] | _ :: _ -> failwith "canonical producer or argument node is not unique" in
  let template node = Keeper_tool_plan_request.template_of_json (field "input" node)
      |> get (fun _ -> "canonical input template could not be decoded") in
  match template (unique argument_node canonical) with
  | Plan.Json_template.Object ["job_id",Plan.Json_template.Output {node_id;pointer}] ->
    require (Plan.Json_pointer.to_string pointer="/content") "child does not consume selection content";
    let producer_id = Plan.Node_id.to_string node_id in
    let producer = unique producer_id canonical in
    require (field "tool" producer=`String "keeper_artifact_read") "child producer is not the selection reader";
    let input = Plan.Json_template.resolve ~lookup:(fun _ -> None) (template producer)
        |> get (fun _ -> "selection producer input is not fixed") in
    require (field "sha256" input=field "selection_sha256" fixture) "producer reads a different original input";
    let physical = List.filter (fun node -> field "node_id" node=`String producer_id &&
      field "tool_name" node=`String "keeper_artifact_read" && Yojson.Safe.equal (field "input" node) input) nodes in
    (match physical with
     | [node] -> List.exists (fun row -> original_turn_source ~fixture ~turn row &&
       field "execution_id" row=field "execution_id" node &&
       field "composition_node_id" row=field "node_id" node &&
       field "tool" row=field "tool_name" node && Yojson.Safe.equal (field "input" row) input &&
       field "parent_tool_use_id" row=field "tool_use_id" parent &&
       field "composition_run_id" row=`String composition_run_id &&
       match Tool_result.recorded_call_outcome row with
       | Recorded_succeeded ->
         let page = row_document ~base row in
         field "offset" page=`Int 0 && field "eof" page=`Bool true &&
         field "content" page=field "selected_job_id" fixture &&
         sha (string "content" page)=string "selection_sha256" fixture
       | Recorded_deferred | Recorded_failed | Recorded_unsettled | Recorded_malformed -> false) rows
     | [] | _ :: _ -> false)
  | Plan.Json_template.Literal _ | Plan.Json_template.Output _ | Plan.Json_template.Param _
  | Plan.Json_template.Object _ | Plan.Json_template.Array _ -> false

let nested_execution_proven ~base ~fixture ~turn ~skill_reference
    ~(scope : Keeper_skill_activation_ledger.nested_composition_scope) ~raw_records rows stdout_rows =
  let parents = List.filter (fun row ->
    sdk_member ~fixture ~turn row &&
    field "tool" row=`String Keeper_composition_draft.run_tool_name &&
    field "tool_use_id" row=`String scope.Keeper_skill_activation_ledger.parent_tool_use_id) rows in
  match parents with
  | [parent] -> decode_evidence (fun () ->
    let run = exact_sdk_reply ~base ~raw_records parent in
    require (field "composition_run_id" run=`String scope.composition_run_id) "activation run mismatch";
    let nodes = execution_nodes ~base run in
    let draft_reference = reference (field "draft" run) in
    let draft = document ~base (blob_bytes base draft_reference) in
    let binding = document ~base (blob_bytes base (reference (field "run_artifact" run))) in
    require (field "draft" binding=field "draft" run &&
      field "composition_run_id" binding=field "composition_run_id" run &&
      field "tool_use_id" binding=field "tool_use_id" parent &&
      field "source_turn" binding=field "turn" parent &&
      field "keeper" draft=field "keeper" fixture)
      "prepared source binding differs from the original SDK invocation";
    (match field "input" parent with
     | `Assoc ["sha256",`String digest] ->
       require (digest=draft_reference.sha256) "original prepared digest differs"
     | `Assoc ["recipe",`Assoc fields] ->
       require (List.assoc_opt "skill" fields=None &&
         field "execution" (`Assoc fields)=field "execution" draft &&
         Yojson.Safe.equal (`Assoc (List.remove_assoc "execution" fields)) (field "recipe" draft))
         "original task recipe differs from the sealed draft"
     | _ -> failwith "expected one fresh task composition source");
    List.exists (fun call ->
      field "alias" call=`String scope.alias &&
      Yojson.Safe.equal (field "reference" call) (Skill_reference.to_yojson skill_reference) &&
      field "kind" (field "arguments" call)=`String "upstream" &&
      let child_scope = field "scope" call in
      selection_dependency_proven ~base ~fixture ~turn ~parent ~draft
        ~argument_node:(string "argument_node" child_scope) ~composition_run_id:scope.composition_run_id ~nodes rows &&
      let arguments = List.filter (fun node -> field "node_id" node=field "argument_node" child_scope) nodes in
      List.exists (fun node -> field "input" node=`Assoc ["job_id",field "selected_job_id" fixture]) arguments &&
      List.exists (fun mapping -> field "source" mapping=`String "consume" &&
        List.exists (fun node -> field "node_id" node=field "expanded" mapping &&
          List.exists (fun row -> field "execution_id" row=field "execution_id" node &&
            field "composition_run_id" row=`String scope.composition_run_id &&
            field "parent_tool_use_id" row=`String scope.parent_tool_use_id) stdout_rows) nodes)
        (field "node_mapping" child_scope |> to_list)) (field "nested_calls" draft |> to_list))
      = Some true
  | [] | _ :: _ -> false

let tool_content ~id request =
  let messages = field "messages" request |> to_list in
  let matches = List.filter (fun message ->
    field "role" message = `String "tool" && field "tool_call_id" message = `String id) messages in
  match matches with
  | [message] -> string "content" message
  | [] | _ :: _ -> failwith ("missing/ambiguous actual tool result: " ^ id)

let tool_answer ~base ~id request = document ~base (tool_content ~id request)

let sse ~model ~delta ~finish =
  let event delta finish = "data: " ^ Yojson.Safe.to_string (`Assoc
      ["id",`String "synthetic-preparation";"model",`String model;"choices",`List
        [`Assoc ["index",`Int 0;"delta",delta;"finish_reason",finish]]]) ^ "\n\n" in
  event delta `Null ^ event (`Assoc []) (`String finish) ^ "data: [DONE]\n\n"

let start_provider ~sw ~env ~base ~attempt_dir ~counter ~experiment ~fixture ~strategy events =
  let runtime = settings experiment in
  let model = string "model_id" runtime in
  (* Exercise both valid result presentations with the existing scenarios.
     The malformed-final case still fails solely its final JSON contract. *)
  let outcome = synthetic_outcome experiment in
  let projection = match outcome with
    | Successful | Provider_refusal -> Selected_stdout
    | Malformed_final | Fixed_child -> Full_actions in
  let arguments = match outcome with
    | Fixed_child -> Selected_literal
    | Successful | Provider_refusal | Malformed_final -> Selection_output in
  let next_step = ref (match strategy,preparation_case experiment,projection with
    | Exact_skill,Upstream_inline,Selected_stdout -> Run
    | Direct,_,_ | Exact_skill,Named_inline,_ | Exact_skill,Upstream_inline,Full_actions -> Select) in
  let awaiting = ref None in
  let loading = ref None in
  let selected = ref None and stdout = ref None and draft_sha = ref None in
  let final_answer = ref None in
  let observed_requests = ref [] in
  let serial = ref 0 in
  let add_event kind fields =
    let event = `Assoc (["kind",`String kind;"observed",now counter] @ fields) in
    append_event (Filename.concat attempt_dir "events.jsonl") event;
    events := event :: !events in
  let handler _connection _request body =
    let raw = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let request = Yojson.Safe.from_string raw in
    incr serial;
    let request_number = !serial in
    write (Filename.concat attempt_dir (Printf.sprintf "provider-request-%03d.body" request_number)) raw;
    json (Filename.concat attempt_dir (Printf.sprintf "provider-request-%03d.json" request_number)) request;
    observed_requests := request :: !observed_requests;
    add_event "synthetic_provider_received" ["index",`Int request_number;"body_sha256",`String (sha raw);
      "body_bytes",`Int (String.length raw);"stream",field "stream" request;"model",field "model" request];
    require (field "stream" request = `Bool true) "actual runtime did not request streaming";
    require (field "model" request = `String model) "actual request model differs from declared model";
    if outcome = Provider_refusal then
      Cohttp_eio.Server.respond_string ~status:`Bad_request
        ~body:{|{"error":{"type":"synthetic_refusal","message":"Declared fixture refusal"}}|} ()
    else (
      (match !loading with
       | None -> ()
       | Some id ->
         ignore (tool_content ~id request);
         loading := None);
      (match !awaiting with
       | None -> ()
       | Some (step,id) ->
         let value = tool_answer ~base ~id request in
         awaiting := None;
         (match step with
          | Select ->
            require (field "eof" value = `Bool true) "selection read did not return complete bytes";
            let id = string "content" value in
            require (id = string "selected_job_id" fixture) "input selected the wrong original job";
            selected := Some id;
            next_step := (match strategy,preparation_case experiment,projection with
              | Direct,_,_ -> Direct_result
              | Exact_skill,Named_inline,_ -> Named_skill
              | Exact_skill,Upstream_inline,_ -> Run)
          | Direct_result ->
            let artifacts = field "artifacts" value |> to_list in
            let value = match artifacts with first :: _ -> first | [] -> failwith "result has no stdout artifact" in
            let reference = reference value in
            draft_sha := Some reference.sha256;
            next_step := Direct_stdout
          | Direct_stdout ->
            require (field "eof" value = `Bool true) "stdout read did not reach EOF";
            stdout := Some (string "content" value);
            next_step := Finish
          | Named_skill ->
            let nodes = execution_nodes ~base value in
            json (Filename.concat attempt_dir "actual-composition-execution.json")
              (`Assoc ["nodes",`List nodes;"source_result",value]);
            let selected_stdout = field "stdout" (field "exports" value) in
            require (field "available" selected_stdout = `Bool true) "named Skill stdout is unavailable";
            stdout := Some (string "value" selected_stdout);
            next_step := Finish
          | Run ->
            let nodes = execution_nodes ~base value in
            json (Filename.concat attempt_dir "actual-composition-execution.json")
              (`Assoc ["nodes",`List nodes;"source_result",value]);
            let prepared = document ~base (blob_bytes base (reference (field "draft" value))) in
            let argument_node = match field "nested_calls" prepared |> to_list with
              | [call] -> call |> field "scope" |> string "argument_node"
              | [] | _ :: _ -> failwith "one actual nested call was required" in
            let arguments = nodes |> List.filter (fun node ->
                field "node_id" node=`String argument_node) in
            (match arguments with
             | [node] ->
               require (field "input" node=`Assoc ["job_id",field "selected_job_id" fixture])
                 "actual child barrier did not preserve resolved upstream input"
             | [] | _ :: _ -> failwith "actual argument barrier was not uniquely executed");
            let exports = match projection with
              | Selected_stdout ->
                let exports = field "exports" value in
                let job = field "job_id" exports in
                require (field "available" job=`Bool true) "selection export is unavailable";
                let id = string "value" job in
                require (id=string "selected_job_id" fixture) "recipe selected the wrong original job";
                selected := Some id;
                exports
              | Full_actions ->
                (match field "nested_scopes" value |> to_list with
                 | [scope] -> field "exports" scope
                 | [] | _ :: _ -> failwith "one actual child result was required") in
            let selected_stdout = field "stdout" exports in
            require (field "available" selected_stdout = `Bool true) "Skill stdout is unavailable";
            stdout := Some (string "value" selected_stdout);
            next_step := Finish
          | Finish | Finished -> failwith "unexpected tool acknowledgement after final response"));
      let actual_tools = field "tools" request |> to_list |> List.map (fun tool ->
          tool |> field "function" |> string "name") in
      let call name args id =
        require (List.mem name actual_tools) ("tool was not offered by actual runtime: " ^ name);
        add_event "synthetic_provider_tool_call" ["tool",`String name;"tool_use_id",`String id;"input",args];
        sse ~model ~finish:"tool_calls" ~delta:(`Assoc ["role",`String "assistant";"tool_calls",`List
          [`Assoc ["index",`Int 0;"id",`String id;"type",`String "function";"function",`Assoc
            ["name",`String name;"arguments",`String (Yojson.Safe.to_string args)]]]]) in
      let needed value = match value with Some value -> value | None -> failwith "prior actual tool result absent" in
      let response = match !next_step with
        | Finish ->
          let body = needed !stdout and job_id = needed !selected in
          let digest = sha body in
          require (digest = string "expected_stdout_sha256" fixture) "actual selected stdout digest differs";
          let answer = Yojson.Safe.to_string (`Assoc ["job_id",`String job_id;"stdout_sha256",`String digest]) in
          let answer = if outcome=Malformed_final
            then "Result: " ^ answer else answer in
          final_answer := Some answer;
          next_step := Finished;
          sse ~model ~finish:"stop" ~delta:(`Assoc ["role",`String "assistant";"content",`String answer])
        | Finished -> failwith "unexpected provider call after scripted final answer"
        | (Select | Direct_result | Direct_stdout | Run | Named_skill) as step ->
          let name,args = match step with
            | Select -> "keeper_artifact_read",`Assoc ["sha256",field "selection_sha256" fixture]
            | Direct_result -> "keeper_job_result",`Assoc ["job_id",`String (needed !selected)]
            | Direct_stdout -> "keeper_artifact_read",`Assoc ["sha256",`String (needed !draft_sha)]
            | Named_skill -> string "skill_tool_name" fixture,`Assoc ["job_id",`String (needed !selected)]
            | Run -> Keeper_composition_draft.run_tool_name,`Assoc ["recipe",recipe ~projection ~arguments fixture]
            | Finish | Finished -> failwith "final step cannot dispatch a tool" in
          let id = Printf.sprintf "call-%d-%s" request_number (step_name step) in
          if List.mem name actual_tools then (
            awaiting := Some (step,id);
            call name args id)
          else (
            let load_id = "preparation-load-" ^ step_name step in
            require (not (List.exists (fun message -> field "tool_call_id" message = `String load_id)
              (field "messages" request |> to_list))) "loader did not make the exact tool available";
            loading := Some load_id;
            call Keeper_identity_tool_search.tool_name (`Assoc ["names",`List [`String name]]) load_id)
      in
      write (Filename.concat attempt_dir (Printf.sprintf "provider-response-%03d.sse" request_number)) response;
      Cohttp_eio.Server.respond_string ~status:`OK
        ~headers:(Cohttp.Header.init_with "content-type" "text/event-stream") ~body:response ()) in
  let socket = Eio.Net.listen env#net ~sw ~backlog:8 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_,port) -> port
    | `Unix _ -> failwith "loopback peer did not bind TCP" in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun error ->
      add_event "synthetic_provider_error" ["detail",`String (Printexc.to_string error)]));
  Printf.sprintf "http://127.0.0.1:%d" port,final_answer,observed_requests

let initialize_synthetic_runtime ~base ~endpoint runtime =
  let model = string "model_id" runtime in
  let catalog_path = Filename.concat base "model-catalog.toml" in
  write catalog_path (Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = \"preparation_fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = %d\nmax_output_tokens = %d\nsupports_tools = true\nsupports_native_streaming = true\n"
    model (integer "max_context_tokens" runtime) (integer "max_output_tokens" runtime));
  Llm_provider.Model_catalog.load_file catalog_path |> get Fun.id |> Llm_provider.Model_catalog.set_global;
  write (config_path base) (Printf.sprintf
    "[runtime]\ndefault = \"preparation_fixture.sample\"\n[providers.preparation_fixture]\nprotocol = \"openai-compatible-http\"\nendpoint = %S\n[models.sample]\napi-name = %S\nmax-context = %d\nstreaming = true\n[preparation_fixture.sample]\n%s"
    endpoint model (integer "max_context_tokens" runtime) skills_config);
  ()

let initialize_runtime ~base ~endpoint runtime =
  (match runtime_mode runtime with
   | Synthetic_streaming -> initialize_synthetic_runtime ~base ~endpoint runtime
   | Configured_http configuration ->
     validate_http_configuration configuration;
     write (config_path base) (configuration ^ "\n" ^ skills_config));
  match Runtime.init_default_degraded_report ~config_path:(config_path base) with
  | Ok Runtime.Initialized -> ()
  | Ok (Runtime.Initialized_degraded _) -> failwith "isolated runtime initialized degraded"
  | Error error -> failwith (Runtime.strict_init_error_to_string error)

let run_trial ~base ~experiment ~strategy ~prompt_root ~counter ~receipt ~sw ~env =
  let stage phase = observe_stage ~counter ~receipt phase in
  let fixture = load (fixture_path base) in
  require (string "base_path" fixture = base && string "keeper" fixture = keeper)
    "fixture does not own this canonical base";
  require (Yojson.Safe.equal (field "runtime" fixture) (settings experiment)) "common runtime settings changed";
  let config = Workspace.default_config base in
  let attempt_dir = Filename.dirname receipt in
  let events = ref [] in
  let runtime = settings experiment in
  let endpoint,final_answer,requests = match runtime_mode runtime with
    | Synthetic_streaming -> start_provider ~sw ~env ~base ~attempt_dir ~counter
        ~experiment ~fixture ~strategy events
    | Configured_http _ -> "configured_http", ref None, ref [] in
  stage Initialize_runtime (fun () -> initialize_runtime ~base ~endpoint (settings experiment));
  let workspace,_,reference = stage Publish_snapshot (fun () -> publish_snapshot ~base) in
  Eio.Switch.on_release sw (fun () -> Skill_catalog_snapshot_service.retire ~workspace);
  require (Yojson.Safe.equal (Skill_reference.to_yojson reference) (field "skill_reference" fixture))
    "exact published inventory changed after restoration";
  require (sha (read (Filename.concat base ".agents/skills/preparation-stdout/SKILL.md")) =
      string "skill_document_sha256" fixture) "Skill source bytes changed";
  let common_instruction =
    "Complete this read-only task using the completed original artifacts. Read the selection artifact first and the complete selected stdout. Return exactly one JSON object with only job_id and stdout_sha256; no prose or Markdown. The artifact address is its SHA-256 and the harness independently checks the returned full bytes. Do not execute new programs, declare the Task complete, or modify any source." in
  let assignment = match strategy,preparation_case experiment with
    | Direct,_ -> "Assigned strategy: direct. Use ordinary keeper_job_result and keeper_artifact_read for the selected original job."
    | Exact_skill,Upstream_inline -> "Assigned strategy: exact_skill. Call keeper_composition_run once with a recipe whose first producer reads the selection artifact, whose exact Inline Skill consumes that producer's output through an explicit input template, and whose exports return job_id and stdout. Use the offered exact reference."
    | Exact_skill,Named_inline -> "Assigned strategy: exact_skill. Reuse the offered named Inline Skill directly with the selected original job_id; use the offered exact reference." in
  configure_keeper ~base ~instructions:(common_instruction ^ "\n" ^ assignment);
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir prompt_root;
  Prompt_defaults.init ();
  stage Install_owner (fun () -> install_owner ~sw config);
  let meta = match Keeper_meta_store.read_effective_meta config keeper |> get Fun.id with
    | Some meta -> meta | None -> failwith "original Keeper metadata is absent" in
  require (Keeper_id.Trace_id.to_string meta.runtime.trace_id = string "trace_id" fixture) "original trace changed";
  require (Option.map Keeper_id.Task_id.to_string meta.current_task_id = Some (string "task_id" fixture))
    "original Task changed";
  let registry_entry = stage Register_keeper (fun () ->
    Keeper_registry.register_offline ~base_path:base keeper meta) in
  Eio.Switch.on_release sw (fun () -> ignore (Keeper_registry.unregister_exact registry_entry));
  require (pending base = []) "setup stimulus would steal measured intake";
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs
      ~registry_root:(Workspace.masc_dir config) @@ fun publication_registry ->
  let ctx : _ Keeper_types_profile.context =
    {config;agent_name="preparation-operator";sw;clock=env#clock;proc_mgr=Some env#process_mgr;net=Some env#net;
     publication_recovery_provider=Masc_test_deps.publication_recovery_provider publication_registry} in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  ignore (Board_dispatch.create_post ~author:"synthetic-user" ~content:"unaddressed fixture baseline"
      ~post_kind:Board.Human_post ~visibility:Board.Internal () |> get Board.show_board_error);
  ignore (Keeper_world_observation.collect_board_events ~base_path:base ~meta);
  Board_dispatch.set_board_signal_hook (Keeper_keepalive_signal.wakeup_relevant_keeper_for_board_signal ~config);
  let content = Printf.sprintf
    "@%s Read selection artifact sha256=%s. It contains the exact original job ID as UTF-8 text. Common exact Inline Skill reference=%s. Return that job's complete stdout digest."
    keeper (string "selection_sha256" fixture) (Yojson.Safe.to_string (field "skill_reference" fixture)) in
  let admission_entered = now counter in
  let post = stage Admit_source (fun () -> Board_dispatch.create_post ~author:"synthetic-user" ~content
      ~post_kind:Board.Human_post ~visibility:Board.Internal () |> get Board.show_board_error) in
  let admission_returned = now counter in
  let selection = match pending base with
    | [selection] -> selection
    | [] | _ :: _ -> failwith "one exact addressed source was not durably admitted" in
  let stimulus_id = Ledger.stimulus_id_of_event_queue selection.source in
  let source_ref = Keeper_event_queue_state.source_snapshot_ref selection.source in
  let admission = `Assoc ["post_id",`String (Board.Post_id.to_string post.id);"stimulus_id",`String stimulus_id;
      "source_snapshot_ref",`String source_ref;"admitted_revision",`String (Int64.to_string selection.admitted_revision);
      "first_admitted_at",(match selection.first_admitted_at with None -> `Null | Some value -> `Float value);
      "enqueue_entered",admission_entered;"enqueue_returned",admission_returned] in
  json (Filename.concat attempt_dir "admission.json") admission;
  let lifecycle = Keeper_lifecycle_admission.state ~paused:meta.paused ~latched_reason:meta.latched_reason in
  (match Keeper_heartbeat_loop.classify_turn_intake_admission
      ~lifecycle:(Keeper_lifecycle_admission.admit_autonomous lifecycle) with
   | Intake_admitted -> ()
   | Intake_lifecycle_blocked denial -> failwith (Keeper_lifecycle_admission.autonomous_denial_to_wire denial));
  let frontier = Calls.current_frontier ~keeper_name:keeper |> get index_error in
  let observations = ref [] in
  let commit_path = Filename.concat attempt_dir "tool-commit-events.jsonl" in
  write commit_path "";
  let commit_observer = Calls.make_commit_observer (fun (event : Calls.committed_call) ->
    if event.keeper_name=keeper && event.record_kind=Calls.Tool_call then
      let observed = now counter in
      append_event commit_path (`Assoc
        (["schema_version",`Int 1;"boundary",`String "durable_tool_call_commit";
          "observed",observed] @ commit_identity event));
      observations := (event,observed) :: !observations) in
  (* This fixture invokes the real cycle on its current Eio fiber instead of
     launching the perpetual keepalive loop. Production registration starts
     Offline; mark this actual fiber entry before asking the cycle to run. *)
  Keeper_registry.dispatch_event_exact registry_entry Keeper_state_machine.Fiber_started
    |> get Keeper_state_machine.transition_error_to_string |> ignore;
  let http_observation = Keeper_preparation_http_observation.create
      ~path:(Filename.concat attempt_dir "http-events.jsonl") ~now:(fun () -> now counter) in
  let cycle_entered = now counter in
  let outcome = stage Run_cycle (fun () ->
    Calls.with_commit_observer commit_observer @@ fun () ->
    Keeper_preparation_http_observation.within http_observation @@ fun () ->
    Keeper_heartbeat_loop.run_keepalive_unified_turn
      ~wake:Keeper_world_observation.Attention_wake ~ctx ~registry_entry ~meta_after_triage:meta
      ~pending_board_events:[] ~stop:(Atomic.make false) ~proactive_warmup_elapsed:true ~reactive_wake:true
      ~shared_context:(Agent_core.Context.create ()) ~deferred_runtime_lane:None
      ~on_deferred_runtime_consumed:(fun () -> ())
      ~settle_deferred_runtime_lane:(function None -> () | Some _ -> failwith "unexpected runtime failover")) in
  let cycle_returned = now counter in
  let http_metrics = Keeper_preparation_http_observation.snapshot http_observation in
  let first_offered_tools_sha256 = match field "first_dispatched_tools" http_metrics with
    | `Assoc fields -> (match List.assoc_opt "json_sha256" fields with Some (`String _ as hash) -> hash | _ -> `Null)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> `Null in
  let batch = Calls.read_after ~keeper_name:keeper ~after:frontier ~project:Option.some |> get index_error in
  let rows = List.map (fun (row : Yojson.Safe.t Keeper_tool_call_index.positioned) -> row.value) batch.rows in
  let committed_rows = List.filter (fun row -> field "record_kind" row=`String "tool_call") rows in
  let commit_coverage_complete = Calls.failed_commit_deliveries commit_observer=0 &&
    List.for_all (fun row ->
      List.length (List.filter (fun (event,_) -> commit_matches row event) !observations)=1) committed_rows &&
    List.for_all (fun (event,_) ->
      List.length (List.filter (fun row -> commit_matches row event) committed_rows)=1) !observations in
  let commit_metrics = `Assoc ["boundary",`String "durable_tool_call_commit";
    "mode",`String "scoped_synchronous_commit";
    "coverage",`String (if commit_coverage_complete then "complete" else "incomplete");
    "delivery_failures",`Int (Calls.failed_commit_deliveries commit_observer);
    "events",`Int (List.length !observations);"events_sha256",`String (sha (read commit_path))] in
  let previous = load receipt |> to_assoc |> List.remove_assoc "timing" in
  json receipt (`Assoc (("timing",`Assoc ["admission",admission;
    "cycle_entered",cycle_entered;"cycle_returned",cycle_returned])::
    ("http_metrics",http_metrics)::("tool_commit_observation",commit_metrics)::
    ("first_offered_tools_sha256",first_offered_tools_sha256)::
    ("common_instruction_sha256",`String (sha common_instruction))::previous));
  json (Filename.concat attempt_dir "tool-calls.json") (`List rows);
  json (Filename.concat attempt_dir "provider-events.json") (`List (List.rev !events));
  let store = Keeper_types_support.keeper_turn_record_store config keeper in
  let turn_json,turn = match Dated_jsonl.read_recent_result store 1 |> get Dated_jsonl.read_error_to_string with
    | [Dated_jsonl.Parsed value] -> value,(Turn_record.of_json value |> get Fun.id)
    | [] | _ :: _ -> failwith "one canonical TurnRecord was not available" in
  json (Filename.concat attempt_dir "turn-record.json") turn_json;
  let raw_records = match turn.raw_trace_run_ref with
    | None -> []
    | Some run ->
      let original : Agent_core.Raw_trace.run_ref =
        {worker_run_id=run.worker_run_id;path=run.path;start_seq=run.start_seq;end_seq=run.end_seq;
         agent_name=run.agent_name;session_id=Some run.session_id} in
      Agent_core.Raw_trace_query.read_run original |> get Agent_core.Error.to_string in
  json (Filename.concat attempt_dir "exact-run-records.json")
    (`List (List.map Agent_core.Raw_trace.record_to_yojson raw_records));
  let evidence = match Ledger.event_queue_reaction_evidence_result ~base_path:base ~keeper_name:keeper ~stimulus_id
      |> get Ledger.event_queue_reaction_evidence_error_to_string with
    | Evidence_complete evidence -> evidence
    | Evidence_quarantined _ -> failwith "measured source reaction evidence is quarantined" in
  let unknown reason = `Assoc ["state",`String "unknown";"reason",`String reason] in
  let manifest_path = Keeper_runtime_manifest.path_for_trace config ~keeper_name:keeper
      ~trace_id:turn.trace_id in
  let manifest_rows = read manifest_path |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line <> "") |> List.map Yojson.Safe.from_string in
  json (Filename.concat attempt_dir "runtime-manifest.json") (`List manifest_rows);
  let entries = List.filter_map (fun value ->
    match Keeper_runtime_manifest.decode_persisted_row value |> get Fun.id with
    | Active_row row when row.event=Keeper_runtime_manifest.Turn_started &&
        row.keeper_name=keeper && row.trace_id=turn.trace_id &&
        row.keeper_turn_id=Some (integer "absolute_turn" turn_json) -> Some row
    | Active_row _ | Unsupported_row _ -> None) manifest_rows in
  let expected_sources = `List [`Assoc (List.map (fun key -> key,field key admission)
      ["stimulus_id";"source_snapshot_ref";"admitted_revision";"first_admitted_at"])] in
  let intake_turn_entry = match entries with
    | [row] when Yojson.Safe.equal (field "intake_sources" row.decision) expected_sources ->
      let persisted = Keeper_runtime_manifest.to_json row in
      json (Filename.concat attempt_dir "turn-entry-manifest.json") persisted;
      require (field "intake_sources" (field "decision" (Keeper_runtime_manifest.public_to_json row))=`Null)
        "private intake source identity leaked through public manifest projection";
      `Assoc ["state",`String "observed";"ts",`String row.ts;
        "trace_id",`String row.trace_id;"keeper_turn_id",`Int (integer "absolute_turn" turn_json);
        "sources",expected_sources;"clock_refs",field "clock_refs" row.decision;
        "manifest_sha256",`String (sha (read (Filename.concat attempt_dir "turn-entry-manifest.json")))]
    | [_] -> unknown "exact turn-entry manifest did not retain this intake selection"
    | [] | _ :: _ -> unknown "no unique exact-turn entry manifest" in
  let useful =
    let candidates = List.filter (fun row -> original_turn_source ~fixture ~turn row &&
      field "tool" row=`String "keeper_artifact_read" &&
      field "sha256" (field "input" row)=field "selection_sha256" fixture) committed_rows in
    if not commit_coverage_complete then unknown "durable Tool commit observation coverage is incomplete"
    else if not (List.for_all (physical_execution_owned ~base ~fixture ~turn ~raw_records rows) candidates)
      then unknown "selection-read ownership is incomplete"
    else
      let first = List.find_map (fun (event,observed) ->
        Option.map (fun row -> row,observed) (List.find_opt (fun row -> commit_matches row event) candidates))
          (List.rev !observations) in
      match first with
      | None -> unknown "no committed successful original selection read"
      | Some (row,observed) ->
        let value = row_document ~base row in
        require (string "content" value=string "selected_job_id" fixture && field "eof" value=`Bool true &&
          field "offset" value=`Int 0) "successful useful leaf returned wrong or incomplete original selection";
        `Assoc ["state",`String "observed";"boundary",`String "durable_tool_call_commit";
          "observed",observed;"execution_id",field "execution_id" row;
          "composition_node_id",field "composition_node_id" row;"parent_tool_use_id",field "parent_tool_use_id" row;
          "tool_use_id",field "tool_use_id" row;"sdk_turn",field "turn" row;
          "planned_index",field "planned_index" row;"batch_index",field "batch_index" row;
          "batch_size",field "batch_size" row;"execution_mode",field "execution_mode" row;
          "ledger_completed_at",field "ts" row;"task_id",field "task_id" row;
          "trace_id",field "trace_id" row;"keeper_turn_id",field "keeper_turn_id" row] in
  let _,checkpoint = Keeper_context_runtime.load_context_from_checkpoint_classified
      ~keeper_name:keeper ~trace_id:(string "trace_id" fixture) ~base_dir:(Keeper_types_support.session_base_dir_ config) in
  let checkpoint_last_assistant = match checkpoint with
    | Checkpoint_loaded context ->
      let messages = Keeper_context_runtime.messages_of_context context in
      List.filter_map (fun (message : Agent_core.Types.message) -> match message.role with
        | Assistant -> Some (Agent_core.Types.text_of_message message)
        | User | System | Tool -> None) messages |> List.rev |> (function [] -> None | first :: _ -> Some first)
    | Checkpoint_absent -> None
    | Checkpoint_unread error -> failwith (Keeper_checkpoint_store.checkpoint_load_error_to_string error) in
  (* RFC-0385 deliberately omits internal final thoughts from replay history.
     The completed TurnRecord owns the exact durable raw run; use the same
     strict projection as the autonomous-turn inspector, not another run or
     the synthetic peer's own final string as proof of acceptance. *)
  let accepted = Keeper_autonomous_turn_source.load_recent ~config ~keeper_name:keeper ~limit:1 ()
      |> List.filter (fun (observed : Keeper_autonomous_turn_source.turn) ->
        observed.turn_id = Ids.Turn_ref.to_string turn.turn_ref) in
  let accepted_answer = match accepted with
    | [observed] -> observed.final_text
    | [] | _ :: _ -> None in
  let raw_run = match turn.raw_trace_run_ref with
    | None -> `Null
    | Some run -> `Assoc ["worker_run_id",`String run.worker_run_id;"path",`String run.path;
        "start_seq",`Int run.start_seq;"end_seq",`Int run.end_seq;
        "agent_name",`String run.agent_name;"session_id",`String run.session_id] in
  json (Filename.concat attempt_dir "accepted-final-answer.json") (`Assoc
    ["source",`String "TurnRecord_exact_raw_run";"turn_ref",`String (Ids.Turn_ref.to_string turn.turn_ref);
     "raw_trace_run_ref",raw_run;
     "final_text",(match accepted_answer with None -> `Null | Some text -> `String text);
     "checkpoint_last_assistant",(match checkpoint_last_assistant with None -> `Null | Some text -> `String text);
     "checkpoint_retention",`String "internal final thoughts are excluded by the production replay contract"]);
  let objective_validation = validate_objective ~fixture ~scripted:!final_answer accepted_answer in
  let final = match objective_validation with
    | Verified_json value -> Some value
    | Missing_final | Malformed_json | Wrong_shape | Wrong_original_job
    | Wrong_stdout_digest | Scripted_wire_mismatch -> None in
  let activation_ledger = Keeper_skill_activation_ledger.load_existing ~config ~trace_id:meta.runtime.trace_id
      |> get Keeper_skill_activation_ledger.store_error_to_string in
  let activations = match activation_ledger with
    | None -> [] | Some ledger -> Keeper_skill_activation_ledger.activations ledger in
  json (Filename.concat attempt_dir "skill-activations.json")
    (`List (List.map Keeper_skill_activation_ledger.activation_to_yojson activations));
  let stdout_rows = full_stdout_reads ~base ~fixture ~turn ~raw_records rows in
  let compliant = match strategy,activations with
    | Direct,[] -> List.exists (fun row -> field "composition_node_id" row=`Null) stdout_rows
    | Direct,_ :: _ | Exact_skill,[] -> false
    | Exact_skill,[(activation : Keeper_skill_activation_ledger.activation)] ->
      let module A = Keeper_skill_activation_ledger in
      Skill_reference.equal_identity activation.identity reference.Skill_reference.identity &&
      Skill_reference.equal_content_revision activation.content_revision reference.content_revision &&
      Ids.Turn_ref.equal activation.turn_ref turn.turn_ref &&
      (match preparation_case experiment,activation.invocation with
       | Upstream_inline,A.Nested_composition_invocation {origin=A.Task_composition {task_ids};scope;_} ->
         nested_execution_proven ~base ~fixture ~turn ~skill_reference:reference ~scope ~raw_records rows stdout_rows &&
         List.exists (fun id -> Keeper_id.Task_id.to_string id=string "task_id" fixture)
           (A.task_id_set_to_list task_ids)
       | Named_inline,A.Composition_invocation {origin=A.Task_composition {task_ids};tool_name;_} ->
         tool_name=string "skill_tool_name" fixture && activation.runtime_id=turn.runtime_profile &&
         named_execution_proven ~base ~fixture ~turn ~raw_records rows stdout_rows ~activation ~tool_name &&
         List.exists (fun id -> Keeper_id.Task_id.to_string id=string "task_id" fixture)
           (A.task_id_set_to_list task_ids)
       | (Upstream_inline | Named_inline),A.Instruction_invocation _
       | Upstream_inline,A.Composition_invocation _
       | Named_inline,A.Nested_composition_invocation _
       | Named_inline,A.Composition_invocation {origin=A.Session_composition;_}
       | Upstream_inline,A.Nested_composition_invocation {origin=A.Session_composition;_} -> false)
    | Exact_skill,_ :: _ :: _ -> false in
  let correct = Option.is_some final && stdout_rows<>[] &&
      evidence.event_queue_ack_seen && outcome.stimuli_acked &&
      turn.trace_id=string "trace_id" fixture &&
      turn.finish_reason=Some (Keeper_execution_receipt.stop_reason_to_string Runtime_agent.Completed) &&
      pending base=[] in
  let timing = ["admission",admission;"cycle_entered",cycle_entered;"cycle_returned",cycle_returned;
      "intake_turn_entry",intake_turn_entry;
      "replay_turn_started",(match evidence.turn_started_recorded_at with
        | Some epoch -> `Assoc ["state",`String "observed";"epoch",`Float epoch]
        | None -> unknown "current production Board source does not own a Turn_started reaction");
      "first_useful_leaf",useful;"evidence_collected",now counter] in
  let backend_calls = if Sys.file_exists (Filename.concat base "daemon.json") then
      decode_evidence (fun () -> load (Filename.concat base "daemon.json") |> field "calls" |> to_list |> List.length)
    else Some 0 in
  let synthetic = match runtime_mode runtime with Synthetic_streaming -> true | Configured_http _ -> false in
  let observations = ["schema_version",`Int 1;
    "clock_ref",`String counter.tc_ref;
    "scope",`String (if synthetic then "synthetic_isolated_keeper_explicit_cycle_preparation"
      else "configured_http_isolated_keeper_explicit_cycle_preparation");
    "case",field "case" experiment;
    "strategy",`String (strategy_name strategy);"strategy_compliant",`Bool compliant;
    "common_instruction_sha256",`String (sha common_instruction);
    "fixture_sha256",`String (sha (read (fixture_path base)));"input",field "selection" fixture;
    "skill_reference",field "skill_reference" fixture;"runtime",settings experiment;
    "transport_endpoint",(if synthetic then `String endpoint else `Null);
    "provider_requests",(if synthetic then `Int (List.length !requests) else `Null);
    "configured_runtime_sha256",(match runtime_mode runtime with
      | Synthetic_streaming -> `Null | Configured_http configuration -> `String (sha configuration));
    "http_metrics",http_metrics;"tool_commit_observation",commit_metrics;
    "verified_stdout_read_execution_ids",`List (List.map (field "execution_id") stdout_rows);
    "provider_metrics",`Assoc ["selected_model",field "selected_model" turn_json;
      "reported_usage",`Assoc (List.map (fun name -> name,field name turn_json)
        ["input_tokens";"cache_creation_input_tokens";"cache_read_input_tokens";
         "output_tokens";"usage_scope"]);
      "request_count_scope",`String (if synthetic then "synthetic peer received requests" else "unobserved");
      "total_serialized_input_bytes",`Null;"response_reported_model",`Null];
    "first_offered_tools_sha256",first_offered_tools_sha256;
    "backend_calls_after_ready",(match backend_calls with Some count -> `Int count | None -> `Null);
    "timing",`Assoc timing;"objective",(match final with None -> `Null | Some value -> value);
    "objective_validation",objective_validation_json objective_validation;
    "source_ack",`Bool evidence.event_queue_ack_seen;
    "turn_ref",`String (Ids.Turn_ref.to_string turn.turn_ref);
    "remaining_queue",`Int (List.length (pending base));
    "claims",`List (List.map (fun value -> `String value)
      ((if synthetic then ["synthetic provider protocol only"]
        else ["configured HTTP transport is not proof of response-reported model identity"])
       @ ["synthetic Docker CLI only";"no speedup or fleet scheduling latency claim";
          "HTTP counts/input bytes and first Tool inventory retain their explicit native observation coverage";
          "Request_wire_observer is not a complete body recorder"]))] in
  (* Preserve measured evidence before any independent boundary check can
     reject the attempt. The outer failure path retains these fields. *)
  json receipt (`Assoc (("outcome",`String "unfinished")::observations));
  require (backend_calls=Some 0)
    "measured work unexpectedly called the synthetic backend after complete outputs";
  List.iter (fun job ->
    let record = Jobs.load ~base_path:base ~keeper_name:keeper
        (Jobs.Job_id.of_string (string "job_id" job) |> get Fun.id) |> get store_error in
    require (Yojson.Safe.equal (Jobs.source_to_json record.source) (field "source" job))
      "trial changed an original job source";
    let stdout = match record.outputs with
      | Some (Jobs.Outputs_complete (stdout,_)) -> stdout
      | Some (Jobs.Outputs_unavailable {evidence}) ->
        failwith ("trial original output is unavailable: " ^ evidence)
      | None -> failwith "trial lost original complete output" in
    require (sha (blob_bytes base stdout)=string "stdout_sha256" job) "trial changed an original output")
    (field "jobs" fixture |> to_list);
  let outcome_name = if correct then "correct" else "explicit_failure" in
  json receipt (`Assoc (("outcome",`String outcome_name)::
    ("timing",`Assoc (timing @ ["validation_finished",now counter]))::
    List.remove_assoc "timing" observations));
  require correct "actual Keeper cycle did not satisfy the original objective"

let with_environment values operation =
  let rec loop = function
    | [] -> operation ()
    | (key,value)::rest -> Masc_test_deps.with_process_env key value (fun () -> loop rest) in
  loop values

let main () =
  let mode = ref "" and base = ref "" and experiment_path = ref "" and receipt = ref ""
  and strategy = ref "" and prompt_root = ref "" in
  Arg.parse
    ["--mode",Arg.Set_string mode,"setup or run";"--base",Arg.Set_string base,"fresh isolated canonical base";
     "--experiment",Arg.Set_string experiment_path,"explicit experiment JSON";
     "--receipt",Arg.Set_string receipt,"receipt outside restored base";
     "--strategy",Arg.Set_string strategy,"direct or exact_skill";
     "--prompt-root",Arg.Set_string prompt_root,"frozen keeper prompt directory"]
    (fun value -> failwith ("unexpected argument: " ^ value)) "keeper_preparation_trial_driver";
  require (!base<>"" && not (Filename.is_relative !base)) "--base must be explicit and absolute";
  require (!receipt<>"" && not (Filename.is_relative !receipt)) "--receipt must be explicit and absolute";
  (* NDT-OK: invocation-local observation owner; never scheduling or admission authority. *)
  let counter = {tc_counter=Mtime_clock.counter ();tc_ref=Random_id.uuid_v7 ()} in
  let initial = `Assoc ["schema_version",`Int 1;"outcome",`String "unfinished";"mode",`String !mode;
      "strategy",`String !strategy;"clock_ref",`String counter.tc_ref;"started",now counter] in
  json !receipt initial;
  try
    let experiment = load !experiment_path in
    ignore (settings experiment);
    (match !mode with
     | "setup" -> require (not (Sys.file_exists !base)) "setup base must not exist"; Unix.mkdir !base 0o700
     | "run" -> require (Sys.is_directory !base) "restored base is absent"
     | name -> failwith ("unsupported mode: " ^ name));
    let base_path = Unix.realpath !base in
    require (base_path = !base) "base must have one canonical absolute spelling";
    Sys.chdir base_path;
    Config_dir_resolver.reset ();
    with_environment
      ["MASC_BASE_PATH",Some base_path;
       "MASC_CONFIG_DIR",Some (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config");
       "XDG_CONFIG_HOME",Some (Filename.concat base_path "xdg-config");
       "MASC_TEST_FAKE_DOCKER_PATH",Some (Filename.concat base_path "docker-peer.sh");
       "DOCKER_CONTEXT",None;"DOCKER_HOST",None;"DOCKER_TLS_VERIFY",None;
       "MASC_KEEPER_SANDBOX_RELAX_FS",Some "false";"MASC_KEEPER_SANDBOX_MEMORY",Some "2g";
       "MASC_KEEPER_SANDBOX_PIDS_LIMIT",Some "128";"MASC_KEEPER_SANDBOX_NOFILE_LIMIT",Some "245760";
       "MASC_KEEPER_SANDBOX_TMPFS_SIZE",Some "256m";"MASC_KEEPER_SANDBOX_SECCOMP_PROFILE",Some "";
       "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS",Some "true";"MASC_KEEPER_SANDBOX_REQUIRE_USERNS",Some "true"] @@ fun () ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Fs_compat.set_fs env#fs;
    Masc_test_deps.init_eio_clock ~sw env;
    Eio_context.set_net env#net;
    Eio_context.set_mono_clock env#mono_clock;
    Process_eio.init ~cwd_default:Eio.Path.(env#fs / base_path) ~proc_mgr:env#process_mgr ~clock:env#clock;
    Masc_test_deps.ensure_rng_initialized ();
    Eio.Switch.on_release sw Process_eio.reset_for_testing;
    Calls.init ~base_path ();
    Masc_test_deps.init_unified_tool_registry ();
    (match !mode with
     | "setup" ->
       let python = Filename.concat base_path "docker-peer.py" in
       write python Keeper_owned_job_fixture_transport.source;
       write (Filename.concat base_path "docker-peer.sh")
         ("#!/bin/sh\nexec python3 " ^ Filename.quote python ^ " \"$@\"\n");
       Unix.chmod (Filename.concat base_path "docker-peer.sh") 0o700;
       setup ~base:base_path ~experiment ~counter ~receipt:!receipt ~sw ~env
     | "run" ->
       require (not (Filename.is_relative !prompt_root) && Sys.file_exists (Filename.concat !prompt_root "keeper.md"))
         "--prompt-root must be a frozen absolute prompt directory";
       run_trial ~base:base_path ~experiment ~strategy:(strategy_of_string !strategy)
         ~prompt_root:!prompt_root ~counter ~receipt:!receipt ~sw ~env
     | name -> failwith ("unsupported mode: " ^ name))
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error ->
    let detail = Printexc.to_string error in
    let previous = load !receipt in
    json !receipt (`Assoc (("outcome",`String "explicit_failure")::("error",`String detail)::
      (to_assoc previous |> List.remove_assoc "outcome" |> List.remove_assoc "error")));
    prerr_endline detail;
    exit 1

let () = main ()
