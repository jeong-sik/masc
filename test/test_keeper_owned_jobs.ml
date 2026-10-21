(** Public Keeper handlers exercise the real job producer, durable store and
    backend protocol. The Docker CLI transport is synthetic and persisted in a
    fixture-local file: these scenarios do not prove real Docker isolation. *)
open Alcotest
open Yojson.Safe.Util

module Workspace = Masc.Workspace
module Descriptor = Masc.Keeper_tool_descriptor
module Bundle = Masc.Keeper_tools_agent_core_bundle
module Store = Masc.Keeper_owned_job_store
module Invocation = Masc.Keeper_owned_job_invocation
module Call_log = Masc.Keeper_tool_call_log
module Journal = Masc.Keeper_tool_execution_journal
module Dependency = Masc.Keeper_composition_dependency
let dependency_job_id = function
  | Dependency.Owned_job job_id -> Store.Job_id.to_string job_id
  | Dependency.Composition_result _ -> fail "expected an owned job dependency"
let owned_dependency job_id = Dependency.Owned_job job_id

let keeper = "owned-job-feature"
let stdout_bytes = "original job stdout\n"
let stderr_bytes = "original job stderr\n"

let require label = function Ok value -> value | Error _ -> fail label
let store_value label = function
  | Ok value -> value
  | Error error -> failf "%s: %s" label (Store.error_to_string error)
let check_json label expected actual =
  check bool label true (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort actual))
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let read path = In_channel.with_open_bin path In_channel.input_all
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(* The protocol peer builds inspect receipts from the production create argv.
   It never constructs a Store record or calls a job helper on the test's
   behalf. State remains external to the OCaml process-local transport state. *)
let docker_peer = Keeper_owned_job_fixture_transport.source

type fixture =
  { base_path : string
  ; configured_base_path : string
  ; meta : Masc.Keeper_meta_contract.keeper_meta
  ; cell : Call_log.turn_ctx_cell
  ; control_path : string
  ; daemon_path : string
  ; kill_marker : string
  ; make_bundle : unit -> Masc.Keeper_tools_agent_core.tool_bundle
  }

let frozen_surface_with_observation ~observation ~tool_deny ~tool_descriptors ~base_path ~sandbox_profile =
  let config = Skill_source_config.parse_text
      "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n"
      |> require "skill source configuration" in
  let scans = List.map (fun source_config ->
      let source = Skill_source_config.resolve ~base_path ~user_home:None source_config in
      let resolved_path = match source.Skill_source_config.resolution with
        | Resolved path -> path
        | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ -> fail "source resolution" in
      { Skill_catalog_snapshot.source
      ; observation = observation resolved_path
      ; candidates=[] }) config.sources in
  let snapshot = Skill_catalog_snapshot.configured ~config scans |> require "frozen empty skills" in
  let global_skill_catalog, diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors:tool_descriptors snapshot in
  check int "frozen skill catalog has no diagnostics" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create_with_descriptors ~tool_deny ~tool_descriptors
    ~sandbox_profile ~skill_names:None ~global_skill_catalog
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors:tool_descriptors snapshot) ~task_skills:[]

let frozen_surface_with ~tool_deny ~tool_descriptors ~base_path ~sandbox_profile =
  frozen_surface_with_observation
    ~observation:(fun resolved_path -> Skill_catalog_snapshot.Source_ready {resolved_path;candidates=0})
    ~tool_deny ~tool_descriptors ~base_path ~sandbox_profile

let frozen_surface ~base_path ~sandbox_profile =
  frozen_surface_with ~tool_deny:[] ~tool_descriptors:(Descriptor.all_descriptors ())
    ~base_path ~sandbox_profile

(* The surface a restarted owner sees: the snapshot published from the Skill
   files on disk now, not the empty frozen one. *)
let published_surface fixture =
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
    |> require "published surface workspace" in
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> ()
   | Workspace_retired -> fail "published surface workspace retired");
  let snapshot = match Skill_catalog_snapshot_service.current ~workspace with
    | Some value -> value | None -> fail "published surface snapshot missing" in
  let descriptors = Descriptor.all_descriptors () in
  let catalog,diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  check int "published skill catalog has no diagnostics" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create_with_descriptors ~tool_descriptors:descriptors ~tool_deny:[]
    ~sandbox_profile:fixture.meta.sandbox_profile ~skill_names:None ~global_skill_catalog:catalog
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors snapshot) ~task_skills:[]

let with_environment values f =
  let rec loop = function
    | [] -> f ()
    | (name, value) :: rest -> Masc_test_deps.with_process_env name value (fun () -> loop rest)
  in loop values

let stage label = Printf.eprintf "OWNED_JOB_STAGE %s\n%!" label

let with_fixture ?fixture_base_path ?continuation_channel ?(parent_alias=false) f =
  let base_path = match fixture_base_path with Some path -> path | None ->
    let path = Filename.temp_file "masc-owned-job-feature-" "" in
    Unix.unlink path;
    Unix.mkdir path 0o700;
    path in
  (* macOS /var is a symlink. The production authority requires one canonical
     absolute spelling, so make the fixture itself use that spelling. *)
  let base_path = Unix.realpath base_path in
  Fun.protect ~finally:(fun () -> if Option.is_none fixture_base_path then remove_tree base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock ~sw env;
  Call_log.reset_for_testing ();
  Fun.protect ~finally:Call_log.reset_for_testing @@ fun () ->
  let initialize_transport () =
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env) in
  initialize_transport ();
  Fun.protect ~finally:Process_eio.reset_for_testing @@ fun () ->
  let python = Filename.concat base_path "docker-peer.py" in
  let docker = Filename.concat base_path "docker-peer.sh" in
  write python docker_peer;
  write docker ("#!/bin/sh\nexec python3 " ^ Filename.quote python ^ " \"$@\"\n");
  Unix.chmod docker 0o700;
  with_environment
    [ "MASC_TEST_FAKE_DOCKER_PATH", Some docker
    ; "DOCKER_CONTEXT", None; "DOCKER_HOST", None; "DOCKER_TLS_VERIFY", None
    ; "MASC_KEEPER_SANDBOX_RELAX_FS", Some "false"
    ; "MASC_KEEPER_SANDBOX_MEMORY", Some "2g"
    ; "MASC_KEEPER_SANDBOX_PIDS_LIMIT", Some "128"
    ; "MASC_KEEPER_SANDBOX_NOFILE_LIMIT", Some "245760"
    ; "MASC_KEEPER_SANDBOX_TMPFS_SIZE", Some "256m"
    ; "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE", Some ""
    ; "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS", Some "true"
    ; "MASC_KEEPER_SANDBOX_REQUIRE_USERNS", Some "true" ] @@ fun () ->
  let configured_base_path = if parent_alias then (
    let alias = Filename.concat base_path "workspace-parent-alias" in
    Unix.symlink (Filename.dirname base_path) alias;
    Filename.concat alias (Filename.basename base_path)) else base_path in
  let config = Workspace.default_config configured_base_path in
  if parent_alias then check string "actual public bundle uses the requested parent alias"
    configured_base_path config.base_path;
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  Fs_compat.mkdir_p (Filename.concat base_path ".agents/skills");
  Masc_test_deps.write_sandbox_image_catalog ~base_path ["base", "masc-sandbox-base:fixture-owned-job"];
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let meta = match fixture_base_path with
    | Some _ -> Masc.Keeper_meta_store.read_meta config keeper |> require "original fixture Keeper"
      |> (function Some meta -> meta | None -> fail "physical fixture lost original Keeper metadata")
    | None -> Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper; "activation_mode", `String "manual"])
      |> require "canonical Keeper metadata" in
  let meta = { meta with sandbox_profile = Masc.Keeper_types_profile.Docker; sandbox_image = Some "base" } in
  ignore (Masc.Keeper_meta_store.replace_snapshot config meta |> require "fixture Keeper persistence");
  ignore (Masc.Keeper_registry.register_offline ~base_path keeper meta);
  let surface = frozen_surface ~base_path:configured_base_path ~sandbox_profile:meta.sandbox_profile in
  let cell = Call_log.create_turn_ctx_cell () in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface
      ~config ~meta ~publication_recovery ~capability_surface:surface
      ?continuation_channel
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"owned job fixture")
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:cell () in
  let fixture = {base_path;configured_base_path;meta;cell;make_bundle;
      control_path=Filename.concat base_path "control.json";
      daemon_path=Filename.concat base_path "daemon.json";
      kill_marker=Filename.concat base_path "kill-entered"} in
  Exec_tap.enable ~writer:(fun line -> Printf.eprintf "OWNED_JOB_EXEC %s%!" line);
  Fun.protect ~finally:Exec_tap.disable @@ fun () ->
  Eio.Fiber.first
    (fun () -> f env initialize_transport fixture)
    (fun () ->
      (* Extend the existing fixture-only deadlock guard to every scenario,
         including setup calls made inside [f]. Evidence precedes cancellation;
         the race still joins cleanup and does not claim to force-stop it. *)
      Eio.Time.sleep (Eio.Stdenv.clock env) 15.;
      stage "owned job scenario watchdog expired";
      List.iter (fun path ->
        if Sys.file_exists path then
          Printf.eprintf "OWNED_JOB_EVIDENCE file=%s bytes=%s\n%!" (Filename.basename path) (read path)
        else Printf.eprintf "OWNED_JOB_EVIDENCE missing=%s\n%!" (Filename.basename path))
        [fixture.daemon_path;fixture.control_path;Filename.concat base_path "transport-events.jsonl"];
      fail "public owned job scenario did not finish; see process and transport evidence")

let set_source ?(answer_source_ids = []) fixture ~task_id ~turn =
  Call_log.set_turn_context ~cell:fixture.cell ~agent_name:keeper ~task_id
    ~answer_source_ids
    ~turn ~keeper_turn_id:turn
    ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ()
let write_control fixture ~shared ~jobs ~armed =
  write fixture.control_path (Yojson.Safe.to_string (`Assoc
    ["shared", shared; "jobs", `Assoc jobs; "armed", `List armed]))

let control_jobs fixture ids json =
  let shared,resource = json |> to_assoc |> List.partition (fun (name,_) ->
    List.mem name ["daemon_id";"presence_blocked";"presence_unavailable";
      "presence_wrong_scope";"presence_padding_bytes"]) in
  check bool "resource faults require an explicit original job target" true
    (resource=[] || ids<>[]);
  write_control fixture ~shared:(`Assoc shared)
    ~jobs:(List.map (fun id -> id,`Assoc resource) ids) ~armed:[]
let control_job fixture id json = control_jobs fixture [id] json
let control_shared fixture json = control_jobs fixture [] json
let control_reset fixture () = control_shared fixture (`Assoc [])

let control_launch fixture ~tool_use_id ~keeper_turn_id json =
  let trace_id = Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id in
  let source : Store.source =
    { task_id=Some "task-A"; keeper_turn_id; trace_id=Some trace_id;
      turn_ref=Some (Ids.Turn_ref.make ~trace_id ~absolute_turn:41);
      tool_use_id=Some tool_use_id } in
  let request = `Assoc ["argv",`List [`String "fixture-program"];"inputs",`List []] in
  let digest = Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string request))) in
  write_control fixture ~shared:(`Assoc []) ~jobs:[] ~armed:[`Assoc
    ["base_path",`String fixture.base_path;"keeper_name",`String keeper;
     "source",Store.source_to_json source;"request_sha256",`String digest;"fault",json]]

let daemon fixture = Yojson.Safe.from_string (read fixture.daemon_path)
let fixture_container fixture id = daemon fixture |> member "containers" |> member id
let set_fixture_container fixture id value =
  let state = daemon fixture |> to_assoc in
  let containers = List.assoc "containers" state |> to_assoc |> List.remove_assoc id in
  let containers = if value=`Null then containers else (id,value)::containers in
  write fixture.daemon_path (Yojson.Safe.to_string (`Assoc
    (("containers",`Assoc containers)::List.remove_assoc "containers" state)))
let remove_fixture_container fixture id = set_fixture_container fixture id `Null
let calls fixture = daemon fixture |> member "calls" |> to_list
let effect_count fixture operation =
  List.filter (fun json ->
      let args = json |> to_list |> List.map to_string in
      let rec command = function
        | ("--config" | "--host") :: _ :: rest -> command rest
        | "container" :: actual :: _ -> actual = operation
        | _ -> false in command args) (calls fixture) |> List.length

let result_document ~base_path content =
  let bytes = match Tool_output.decode_from_agent_core content with
    | Tool_output.Not_marker -> content
    | Tool_output.Invalid_marker {detail} -> fail detail
    | Tool_output.Decoded reference ->
        (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256 with
         | Ok (Some bytes) ->
             check int "wire marker names exact durable bytes" reference.bytes (String.length bytes);
             bytes
         | Ok None | Error _ -> fail "public job result artifact unavailable") in
  let json = Yojson.Safe.from_string bytes in
  match Tool_output.artifact_manifest_of_json json with
  | Tool_output.Decoded_artifact_manifest manifest -> manifest.structured_content
  | Tool_output.Invalid_artifact_manifest {detail} -> fail detail
  | Tool_output.Not_artifact_manifest ->
      (match json |> member "structured_content" with `Null -> json | structured -> structured)


let invoke_raw ?(planned_index=0) bundle ~tool_use_id ~turn name input =
  let tool = List.find_opt (fun (tool : Agent_core.Tool.t) -> tool.schema.name = name) bundle.Masc.Keeper_tools_agent_core.tools
    |> function Some tool -> tool | None -> failf "public job tool unavailable: %s" name in
  let execution_mode = Agent_core.Tool.execution_mode tool ~input in
  (match Tool_schemas_owned_job.find_definition name with
   | Some {read_only;_} ->
     let expected = if read_only then Agent_core.Tool_contract.Concurrent
       else Agent_core.Tool_contract.Serial in
     check bool "public job tool uses its canonical execution mode" true (execution_mode = expected)
   | None -> ());
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn
      ~schedule:{planned_index;batch_index=0;batch_size=1;execution_mode}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  stage (name ^ " execute entered");
  let result = Agent_core.Tool.execute ~invocation tool input in
  stage (name ^ " execute returned");
  result

let validate_job_output ~name ~input data =
  match Tool_schemas_owned_job.find_definition name with
  | None -> ()
  | Some _ ->
    let module Plan = Masc.Keeper_tool_plan in
    let node_id = Plan.Node_id.make "public-job-producer" |> require "output producer identity" in
    let node = Plan.node ~id:node_id ~tool_name:name
        ~input:(Plan.Json_template.literal input) () in
    let plan = match Plan.create ~descriptors:(Descriptor.all_descriptors ()) [node] with
      | Ok plan -> plan
      | Error error -> failf "%s output contract is invalid: %s" name (Plan.error_to_string error) in
    match Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ()) ~node_id data with
    | Ok _ -> ()
    | Error _ -> failf "%s public producer output violates its declared schema: %s"
        name (Yojson.Safe.to_string data)

let invoke fixture bundle ~tool_use_id ~turn name input =
  match invoke_raw bundle ~tool_use_id ~turn name input with
  | Ok output ->
    stage (name ^ " result decode entered");
    let data = result_document ~base_path:fixture.base_path output.content in
    stage (name ^ " result decode returned; schema validation entered");
    validate_job_output ~name ~input data;
    stage (name ^ " schema validation returned");
    data
  | Error error -> failf "public job handler failed: %s" error.Agent_core.Types.message

let job_id json = json |> member "job_id" |> to_string
let argument id = `Assoc ["job_id", `String id]
let load fixture id =
  stage "canonical job load entered";
  let record = Store.Job_id.of_string id |> require "typed job id"
    |> Store.load ~base_path:fixture.base_path ~keeper_name:keeper |> store_value "canonical durable job" in
  stage "canonical job load returned";
  record
let with_bundle fixture f =
  stage "bundle construction entered";
  let bundle = fixture.make_bundle () in
  stage "bundle construction returned";
  Fun.protect ~finally:(fun () ->
      stage "bundle cleanup entered";
      bundle.cleanup ();
      stage "bundle cleanup returned") (fun () -> f bundle)

let start fixture bundle ?(inputs=[]) argv =
  invoke fixture bundle ~tool_use_id:"start-original" ~turn:41 "keeper_job_start"
    (`Assoc ["argv", `List (List.map (fun value -> `String value) argv); "inputs", `List inputs])

let check_original_source fixture json =
  let expected_turn = Ids.Turn_ref.make
      ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:41 in
  check_json "original source survives later Task and invocation"
    (`Assoc ["task_id", `String "task-A"; "keeper_turn_id", `Int 41;
             "turn_ref", `String (Ids.Turn_ref.to_string expected_turn);
             "tool_use_id", `String "start-original";
             "trace_id", `String (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id)])
    (json |> member "source")

let first_create_argv fixture =
  calls fixture |> List.find_map (fun json ->
      let argv = json |> to_list |> List.map to_string in
      let rec command = function
        | ("--config" | "--host") :: _ :: rest -> command rest
        | "container" :: "create" :: _ -> Some argv
        | _ -> None in
      command argv)
  |> function Some argv -> argv | None -> fail "missing fixture create call"

let argv_option name argv =
  let rec find = function
    | key :: value :: _ when key = name -> value
    | _ :: rest -> find rest
    | [] -> failf "missing %s in create argv" name in
  find argv

(* Retarget one verified donor container at a cancelled job: a new identity,
   the cancelled job's name and ownership label, and its private workspace
   bind. Every other field already passes the backend contract. *)
let orphan_container ~job_id ~name ~workspace (container : Yojson.Safe.t) =
  let patch_labels = function
    | `Assoc fields -> `Assoc (List.map (function
        | ("masc.mcp.owned_job", _) -> ("masc.mcp.owned_job", `String job_id)
        | label -> label) fields)
    | json -> json in
  let patch_config = function
    | `Assoc fields -> `Assoc (List.map (function
        | "Labels", labels -> "Labels", patch_labels labels
        | field -> field) fields)
    | json -> json in
  let patch_mounts = function
    | `List mounts -> `List (List.map (function
        | `Assoc fields -> `Assoc (List.map (function
            | ("Source", `String _) -> ("Source", `String workspace)
            | field -> field) fields)
        | mount -> mount) mounts)
    | json -> json in
  let patch_state = function
    | `Assoc _ -> `Assoc ["Status", `String "created"; "Running", `Bool false;
                          "Paused", `Bool false; "Restarting", `Bool false;
                          "Dead", `Bool false; "ExitCode", `Int 0]
    | json -> json in
  match container with
  | `Assoc fields -> `Assoc (List.map (function
      | "Id", _ -> "Id", `String (String.make 64 'c')
      | "Name", _ -> "Name", `String ("/" ^ name)
      | "Config", config -> "Config", patch_config config
      | "Mounts", mounts -> "Mounts", patch_mounts mounts
      | "State", state -> "State", patch_state state
      | field -> field) fields)
  | _ -> fail "fixture container shape changed"

let test_running_restart_exit_and_artifacts () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let input_bytes = "immutable source input\n" in
  let input = Tool_blob_store.put_durable store ~bytes:input_bytes ~mime:"text/plain" in
  let argv = ["fixture-program"; "argument with spaces"; "; literal metacharacter"; "input.txt"] in
  let started = with_bundle fixture (fun bundle -> start fixture bundle
      ~inputs:[`Assoc ["path", `String "input.txt"; "artifact", Tool_output.normalized_artifact_ref_to_json input]] argv) in
  check string "public start observes running job" "running" (started |> member "phase" |> to_string);
  check_original_source fixture started;
  let id = job_id started in
  let record = load fixture id in
  let original_container_id = fixture_container fixture id |> member "Id" |> to_string in
  let paths = Store.paths ~base_path:fixture.base_path record.job_id in
  check string "real preparation copied immutable input" input_bytes (read (Filename.concat paths.workspace "input.txt"));
  let container = fixture_container fixture id in
  check_json "argv is structured and never shell-expanded" (`List (List.map (fun x -> `String x) (List.tl argv)))
    (container |> member "Config" |> member "Cmd");
  check string "workspace is private job mount" paths.workspace
    (container |> member "Mounts" |> to_list |> List.hd |> member "Source" |> to_string);
  check string "container network contract is none" "none"
    (container |> member "HostConfig" |> member "NetworkMode" |> to_string);
  check_json "no Keeper or host identity environment injected" (`List [])
    (container |> member "Config" |> member "Env");
  set_source fixture ~task_id:"task-B" ~turn:52;
  Process_eio.reset_for_testing ();
  initialize ();
  let running = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-later" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original container survives process-local reset" "running" (running |> member "phase" |> to_string);
  check_original_source fixture running;
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  let awaiting_outputs = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-output-unavailable" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original exit persists before output receipt" "exited" (awaiting_outputs |> member "phase" |> to_string);
  check_json "unavailable outputs are not invented" (`List []) (awaiting_outputs |> member "artifacts");
  check int "original output fetch attempted once" 1 (effect_count fixture "logs");
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "replacement", `Bool true]);
  let cloned = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-exited-clone" ~turn:52 "keeper_job_status" (argument id)) in
  check_json "same-label exited clone cannot supply original artifacts" (`List []) (cloned |> member "artifacts");
  check int "saved identity refuses clone logs before command" 1 (effect_count fixture "logs");
  (match (load fixture id).phase with
   | Store.Exited {container_id;_} -> check string "saved exited identity is immutable" original_container_id container_id
   | _ -> fail "original exited phase replaced by clone");
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "restore_identity", `Bool true]);
  let exited = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"status-terminal" ~turn:52 "keeper_job_status" (argument id)) in
  check string "original terminal state reconciles" "exited" (exited |> member "phase" |> to_string);
  check int "exact exit code retained" 7 (exited |> member "exit_code" |> to_int);
  check_original_source fixture exited;
  check int "job created exactly once" 1 (effect_count fixture "create");
  check int "job started exactly once" 1 (effect_count fixture "start");
  let outputs = exited |> member "artifacts" |> to_list |> List.map (fun json ->
      match Tool_output.normalized_artifact_ref_of_json json with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | _ -> fail "output artifact is not a canonical reference") in
  check int "both output streams retained" 2 (List.length outputs);
  List.iter2 (fun reference expected ->
      check (option string) "exact original output bytes"
        (Some expected) (Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 |> require "artifact fetch"))
    outputs [stdout_bytes;stderr_bytes];
  write (Filename.concat paths.workspace "output.txt") stdout_bytes;
  Unix.symlink "output.txt" (Filename.concat paths.workspace "latest");
  let dead = Tool_blob_store.put_durable store ~bytes:"unowned fixture artifact" ~mime:"text/plain" in
  let owner_path = Filename.concat paths.job_dir "owner.jsonl" in
  let owner_rows = read owner_path
    |> String.split_on_char '\n' |> List.filter (fun row -> String.trim row <> "")
    |> List.concat_map (fun row -> Yojson.Safe.from_string row |> Tool_output.normalized_artifact_refs_in_json) in
  List.iter (fun reference -> check bool "canonical owner journal retains exact output reference" true
      (List.exists (fun retained -> retained.Tool_output.sha256 = reference.Tool_output.sha256) owner_rows)) outputs;
  let observe () = Tool_blob_maintenance.run ~base_path:fixture.base_path
      ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode:Tool_blob_maintenance.Observe_only
      |> function Ok report -> report | Error error -> fail (Tool_blob_maintenance.error_to_string error) in
  let candidates () = read (Tool_blob_maintenance.candidate_snapshot_path ~base_path:fixture.base_path)
      |> Yojson.Safe.from_string |> member "unreferenced_candidates" |> to_list |> List.map to_string in
  ignore (observe ());
  (* Only observation passes run. Temporarily detaching this terminal owner
     proves no auxiliary bridge artifact silently owns its output references. *)
  let detached_owner = Filename.concat fixture.base_path "detached-job-owner.jsonl" in
  Unix.rename owner_path detached_owner;
  Fun.protect ~finally:(fun () -> Unix.rename detached_owner owner_path) (fun () ->
    ignore (observe ());
    let detached_candidates = candidates () in
    List.iter (fun reference -> check bool "terminal journal is the sole input/output retention owner" true
        (List.mem reference.Tool_output.sha256 detached_candidates)) (input :: outputs));
  let report = observe () in
  check bool "job workspace symlink cannot poison reference scan" true (report.live_references >= 3);
  let candidates = candidates () in
  List.iter (fun reference -> check bool "job owner references never become GC candidates" false
      (List.mem reference.Tool_output.sha256 candidates)) (input :: outputs);
  check bool "unowned artifact is recorded as a candidate" true (List.mem dead.sha256 candidates)

let test_unknown_create_absence_never_replays () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "create uncertainty preserves durable intent" "create_requested" (started |> member "phase" |> to_string);
  let repeated = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "original source recovers the unknown create handle" id (job_id repeated);
  List.iter (fun turn -> with_bundle fixture (fun bundle ->
      let status = invoke fixture bundle ~tool_use_id:("inspect-create-" ^ string_of_int turn) ~turn
          "keeper_job_status" (argument id) in
      check string "absence does not authorize a create" "create_requested" (status |> member "phase" |> to_string);
      check string "absent create is an explicit typed hold" "backend_absent"
        (status |> member "reconciliation" |> member "reason" |> to_string);
      check bool "absent create has no usable result" false (status |> member "result_ready" |> to_bool))) [42;43];
  check int "unknown create has one effectful command" 1 (effect_count fixture "create");
  check int "unknown create never starts" 0 (effect_count fixture "start");
  check bool "canonical create intent survives" true ((load fixture id).phase = Store.Create_requested)

let test_unknown_start_absence_never_replays () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "start_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "start uncertainty preserves durable intent" "start_requested" (started |> member "phase" |> to_string);
  let repeated = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "original source recovers the unknown start handle" id (job_id repeated);
  let status = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"inspect-start" ~turn:42
      "keeper_job_status" (argument id)) in
  check string "absent start is an explicit typed hold" "backend_absent"
    (status |> member "reconciliation" |> member "reason" |> to_string);
  check bool "unconfirmed start has no usable result" false (status |> member "result_ready" |> to_bool);
  check int "unknown start never recreates" 1 (effect_count fixture "create");
  check int "unknown start never restarts" 1 (effect_count fixture "start");
  (match (load fixture id).phase with Store.Start_requested _ -> () | _ -> fail "original start intent replaced")

let test_created_absence_reports_hold_instead_of_ready () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_created"]);
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let original = load fixture id in
  let container_id = fixture_container fixture id |> member "Id" |> to_string in
  (* Preserve the real create's exact handle at the acknowledged-created
     journal boundary, then lose that backend before any start intent. *)
  let created = Store.transition original ~phase:(Store.Created container_id)
      ~cancel_requested:false ~outputs:None ~detail:None |> store_value "created journal boundary" in
  remove_fixture_container fixture id;
  control_reset fixture ();
  let status = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-created-absent" ~turn:42
      "keeper_job_status" (argument id)) in
  check string "original durable phase is retained" "created" (status |> member "phase" |> to_string);
  check string "a missing created backend cannot look ready" "unconfirmed" (status |> member "status" |> to_string);
  check string "the action reports held reconciliation" "held"
    (status |> member "reconciliation" |> member "state" |> to_string);
  check string "the action reports typed absence" "backend_absent"
    (status |> member "reconciliation" |> member "reason" |> to_string);
  check bool "no final result is invented" false (status |> member "result_ready" |> to_bool);
  check_json "original source remains bound" (Store.source_to_json created.source) (status |> member "source");
  check bool "same original created handle remains durable" true
    ((load fixture id).phase = Store.Created container_id);
  check int "status creates no replacement" 1 (effect_count fixture "create");
  check int "status starts no absent program" 0 (effect_count fixture "start");
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-created-absent" ~turn:43
      "keeper_job_cancel" (argument id)) in
  check string "explicit cancellation resolves the same original job" "cancelled_unconfirmed_launch"
    (cancelled |> member "phase" |> to_string);
  check bool "confirmed cancellation makes the result ready" true (cancelled |> member "result_ready" |> to_bool);
  check int "resolution creates no replacement" 1 (effect_count fixture "create");
  check int "resolution starts no program" 0 (effect_count fixture "start")

let test_cancelled_unconfirmed_launch_closes_absent_create () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "unknown create preserves intent" "create_requested" (started |> member "phase" |> to_string);
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-absent-create" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "cancelled absent create closes terminally" "cancelled_unconfirmed_launch"
      (cancelled |> member "phase" |> to_string);
  check bool "terminal retains cancellation request" true (cancelled |> member "cancel_requested" |> to_bool);
  check bool "unconfirmed launch has no container" true
      ((cancelled |> member "container_id") = `Null);
  check int "cancelled absent create never recreates" 1 (effect_count fixture "create");
  check int "cancelled absent create never starts" 0 (effect_count fixture "start");
  check int "cancelled absent create has no kill" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "cancelled launch is not durable");
  let again = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-after-close" ~turn:43
      "keeper_job_status" (argument id)) in
  check string "terminal survives later status" "cancelled_unconfirmed_launch" (again |> member "phase" |> to_string);
  check int "terminal status never recreates" 1 (effect_count fixture "create");
  check_original_source fixture again

let test_cancelled_unconfirmed_launch_treats_late_container_as_orphan () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "start_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  check string "unknown start preserves intent" "start_requested" (started |> member "phase" |> to_string);
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-absent-start" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "cancelled absent start closes terminally" "cancelled_unconfirmed_launch"
      (cancelled |> member "phase" |> to_string);
  check int "cancelled absent start has no kill" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "cancelled start launch is not durable");
  control_reset fixture ();
  set_source fixture ~task_id:"task-B" ~turn:52;
  let donor_id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let container = fixture_container fixture donor_id in
  let create_argv = first_create_argv fixture in
  let name = argv_option "--name" create_argv in
  let a_job_id = Store.Job_id.of_string id |> require "typed cancelled job id" in
  let workspace = (Store.paths ~base_path:fixture.base_path a_job_id).workspace in
  let orphan = orphan_container ~job_id:id ~name ~workspace container in
  set_fixture_container fixture id orphan;
  let orphan_seen = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-orphan" ~turn:53
      "keeper_job_status" (argument id)) in
  check string "late same-label container stays orphan" "cancelled_unconfirmed_launch"
      (orphan_seen |> member "phase" |> to_string);
  check string "orphan observation cannot undo the cancellation outcome" "cancelled"
      (orphan_seen |> member "status" |> to_string);
  check bool "the original cancelled result remains ready" true (orphan_seen |> member "result_ready" |> to_bool);
  check string "the fresh orphan is a separate typed hold" "cancelled_job_orphan"
      (orphan_seen |> member "reconciliation" |> member "reason" |> to_string);
  check bool "orphan observation leaves cancellation evidence" true
      ((orphan_seen |> member "detail")
       = `String "same-label container after a cancelled launch is an orphan; cancellation evidence is retained");
  check int "orphan never recreates a job" 2 (effect_count fixture "create");
  check int "orphan never kills" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Cancelled_unconfirmed_launch -> ()
   | _ -> fail "orphan replaced the cancelled launch phase")

let test_cancel_in_flight_retains_exact_intent () = with_fixture @@ fun env _initialize fixture ->
  let clock = Eio.Stdenv.clock env in
        set_source fixture ~task_id:"task-A" ~turn:41;
        let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
        let id = job_id started in
        let before = load fixture id in
        set_source fixture ~task_id:"task-B" ~turn:52;
        control_job fixture id (`Assoc ["mode", `String "kill_blocked"]);
        let interrupted = with_bundle fixture (fun bundle ->
            Eio.Fiber.first
              (fun () -> ignore (invoke fixture bundle ~tool_use_id:"cancel-later" ~turn:52
                  "keeper_job_cancel" (argument id)); false)
              (fun () ->
                let rec wait () = if Sys.file_exists fixture.kill_marker then ()
                  else (Eio.Time.sleep clock 0.01; wait ()) in
                wait ();
                let pending = load fixture id in
                check bool "cancel intent persisted before blocked effect" true pending.cancel_requested;
                check int "cancel committed one exact transition" (before.sequence + 1) pending.sequence;
                true)) in
        check bool "foreground cancel invocation was interrupted" true interrupted;
        let pending = load fixture id in
        check bool "interruption retains cancellation intent" true pending.cancel_requested;
        check_json "interruption cannot change source ownership" (Store.source_to_json before.source) (Store.source_to_json pending.source);
        control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 137]);
        let completed = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-cancelled" ~turn:52
            "keeper_job_status" (argument id)) in
        check bool "terminal receipt retains requested cancellation" true (completed |> member "cancel_requested" |> to_bool);
        check string "exact cancelled container terminal observed" "exited" (completed |> member "phase" |> to_string);
        check int "verified terminal avoids another kill" 1 (effect_count fixture "kill");
        check int "cancel never relaunches" 1 (effect_count fixture "start");
        check_original_source fixture completed

let test_changed_mount_cannot_authorize_cancel () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let original_container_id = fixture_container fixture id |> member "Id" |> to_string in
  control_job fixture id (`Assoc ["corrupt", `String "mount"]);
  let refused = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-unowned-mount" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check string "unverified backend preserves original phase" "running" (refused |> member "phase" |> to_string);
  check bool "cancel obligation remains durable" true (refused |> member "cancel_requested" |> to_bool);
  check bool "unverified backend explains uncertainty" true (refused |> member "detail" <> `Null);
  check int "no kill crosses a changed mount authority" 0 (effect_count fixture "kill");
  control_job fixture id (`Assoc ["replacement", `Bool true]);
  let cloned = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-same-label-clone" ~turn:42
      "keeper_job_cancel" (argument id)) in
  check bool "same-label running clone retains cancel obligation" true (cloned |> member "cancel_requested" |> to_bool);
  check int "saved identity refuses clone kill before command" 0 (effect_count fixture "kill");
  (match (load fixture id).phase with
   | Store.Running container_id -> check string "saved running identity is immutable" original_container_id container_id
   | _ -> fail "original running phase replaced by clone");
  control_job fixture id (`Assoc ["restore_identity", `Bool true]);
  let recovered = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-restored-owner" ~turn:42
      "keeper_job_status" (argument id)) in
  check string "restored exact authority retires original container" "exited" (recovered |> member "phase" |> to_string);
  check int "one exact owned kill after restore" 1 (effect_count fixture "kill");
  check_original_source fixture recovered

let test_large_streams_publish_complete_original_artifacts () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"; "large output"]) in
  let id = job_id started in
  let head = Common.max_process_capture_head_bytes in
  let tail = Common.max_process_capture_tail_bytes in
  let body stream fill remainder =
    let prefix = stream ^ " beginning\n" in
    let middle = String.uppercase_ascii stream ^ "_DEEP_MIDDLE\n" in
    let terminal = String.uppercase_ascii stream ^ "_TERMINAL\n" in
    let bytes = prefix ^ String.make (head + tail) fill ^ middle
        ^ String.make tail remainder ^ terminal in
    let middle_offset = String.length prefix + head + tail in
    check bool "deep marker lies beyond preview head" true (middle_offset > head);
    check bool "deep marker lies before preview tail" true
      (middle_offset + String.length middle < String.length bytes - tail);
    bytes, middle_offset, middle, terminal
  in
  (* Expected bodies come from this independent producer fixture before the
     public status/capture/publication path; hashes use only these source bytes. *)
  let expected = [body "stdout" 'O' 'o'; body "stderr" 'E' 'e'] in
  set_source fixture ~task_id:"task-B" ~turn:52;
  control_job fixture id (`Assoc
      ["state", `String "exited"; "exit_code", `Int 0;
       "large_logs", `Assoc ["head", `Int head; "tail", `Int tail]]);
  let exited = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-large-streams" ~turn:52
      "keeper_job_status" (argument id)) in
  check string "large output job canonically exited" "exited" (exited |> member "phase" |> to_string);
  check_json "complete publication leaves no capture uncertainty" `Null (exited |> member "detail");
  check_original_source fixture exited;
  let references = exited |> member "artifacts" |> to_list |> List.map (fun json ->
      match Tool_output.normalized_artifact_ref_of_json json with
      | Tool_output.Decoded_normalized_artifact_ref reference -> reference
      | _ -> fail "large output artifact reference is not canonical") in
  check int "both complete streams have durable references" 2 (List.length references);
  let blobs = Tool_blob_store.create ~base_path:fixture.base_path in
  List.iter2 (fun reference (expected, middle_offset, middle, terminal) ->
      let expected_bytes = String.length expected in
      check bool "full stream exceeds process preview ceiling" true (expected_bytes > head + tail);
      check int "declared artifact bytes cover the complete stream" expected_bytes reference.Tool_output.bytes;
      let expected_sha = Digestif.SHA256.(to_hex (digest_string expected)) in
      check string "artifact SHA matches independent full source digest" expected_sha reference.sha256;
      let actual = match Tool_blob_store.fetch blobs ~sha256:reference.sha256 with
        | Ok (Some bytes) -> bytes
        | Ok None | Error _ -> fail "complete large stream artifact is unavailable" in
      check int "durable file contains all observed bytes" expected_bytes (String.length actual);
      check bool "artifact is original bytes without a rendered preview or truncation marker" true (String.equal expected actual);
      check string "omitted-preview middle survives in original artifact" middle
        (String.sub actual middle_offset (String.length middle));
      check string "terminal source bytes survive in original artifact" terminal
        (String.sub actual (String.length actual - String.length terminal) (String.length terminal))) references expected;
  check int "large result never recreates job" 1 (effect_count fixture "create");
  check int "large result never restarts job" 1 (effect_count fixture "start");
  check int "one real output capture command" 1 (effect_count fixture "logs")

let original_invocation fixture =
  let trace_id = Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id in
  let source : Store.source =
    {task_id=Some "task-A";keeper_turn_id=Some 41;trace_id=Some trace_id;
     turn_ref=Some (Ids.Turn_ref.make ~trace_id ~absolute_turn:41);
     tool_use_id=Some "start-original"} in
  match Invocation.invocation_of_source source with
  | Ok (Some invocation) -> invocation
  | Ok None | Error _ -> fail "original invocation identity unavailable"

let lookup_original fixture =
  match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
  | Ok (Some reservation) -> reservation
  | Ok None -> fail "original invocation reservation missing"
  | Error error -> fail (Store.error_to_string error.Invocation.cause)

let test_lost_start_reply_recovers_original_job () = with_fixture @@ fun env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "start_blocked"]);
  let marker = Filename.concat fixture.base_path "start-entered" in
  (* Fixture deadlock guard only; no timeout is added to the producer. *)
  let interrupted = with_bundle fixture (fun bundle ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Fiber.first
          (fun () -> ignore (start fixture bundle ["fixture-program"]); false)
          (fun () ->
            let rec wait () = if Sys.file_exists marker then ()
              else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; wait ()) in
            wait (); true))) in
  check bool "start reply was interrupted after the actual backend effect" true interrupted;
  let calls_before_lookup = List.length (calls fixture) in
  let reservation = lookup_original fixture in
  let id = Store.Job_id.to_string reservation.job_id in
  check int "source lookup consults no backend or job inventory" calls_before_lookup (List.length (calls fixture));
  (match (load fixture id).phase with Store.Start_requested _ -> ()
    | _ -> fail "lost reply did not retain the original start intention");
  set_source fixture ~task_id:"task-B" ~turn:52;
  let found_again = lookup_original fixture in
  check string "original source lookup survives current Task change" id (Store.Job_id.to_string found_again.job_id);
  check (option string) "source lookup keeps original Task" (Some "task-A") found_again.source.task_id;
  Process_eio.reset_for_testing (); initialize ();
  control_reset fixture ();
  set_source fixture ~task_id:"task-A" ~turn:41;
  let recovered = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  check string "same logical invocation recovers the original handle" id (job_id recovered);
  check string "original already-running backend is reconciled" "running" (recovered |> member "phase" |> to_string);
  check_original_source fixture recovered;
  check int "lost reply recovery never recreates the job" 1 (effect_count fixture "create");
  check int "lost reply recovery never restarts the program" 1 (effect_count fixture "start")

let assert_start_rejected fixture argv = with_bundle fixture (fun bundle ->
    match invoke_raw bundle ~tool_use_id:"start-original" ~turn:41 "keeper_job_start"
        (`Assoc ["argv", `List (List.map (fun value -> `String value) argv); "inputs", `List []]) with
    | Error _ -> ()
    | Ok _ -> fail "changed or corrupt invocation authority was accepted")

let test_original_invocation_rejects_rebinding () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let original = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id original in
  let calls_before = List.length (calls fixture) in
  assert_start_rejected fixture ["different-program"];
  check int "changed argv is rejected before any backend call" calls_before (List.length (calls fixture));
  set_source fixture ~task_id:"task-B" ~turn:41;
  assert_start_rejected fixture ["fixture-program"];
  check int "current Task cannot rebind original source" calls_before (List.length (calls fixture));
  let retained = lookup_original fixture in
  check string "conflict keeps the original handle" id (Store.Job_id.to_string retained.job_id);
  check (option string) "conflict keeps original Task authority" (Some "task-A") retained.source.task_id;
  check int "conflict never recreates" 1 (effect_count fixture "create");
  check int "conflict never restarts" 1 (effect_count fixture "start")

let test_corrupt_invocation_binding_cannot_launch () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  ignore (with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]));
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "owned_job_invocations" in
  let names = Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> Filename.extension name = ".json") in
  let location = match names with [name] -> Filename.concat directory name
    | _ -> fail "expected the original invocation binding" in
  let fields = read location |> Yojson.Safe.from_string |> function
    | `Assoc fields -> fields | _ -> fail "expected binding object" in
  write location (Yojson.Safe.to_string (`Assoc (("version", `Int 1) :: fields)) ^ "\n");
  let calls_before = List.length (calls fixture) in
  assert_start_rejected fixture ["fixture-program"];
  check int "corrupt source authority never touches backend" calls_before (List.length (calls fixture));
  (match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
   | Error {cause=Store.Corrupt _;_} -> ()
   | Ok _ | Error _ -> fail "corrupt authority became an absent or reusable binding");
  check int "corrupt authority never recreates" 1 (effect_count fixture "create");
  check int "corrupt authority never restarts" 1 (effect_count fixture "start")

let test_malformed_source_cannot_publish_binding () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"" ~turn:41;
  assert_start_rejected fixture ["fixture-program"];
  check bool "malformed whole source never calls backend" false (Sys.file_exists fixture.daemon_path);
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "owned_job_invocations" in
  check bool "malformed whole source never prepares a reservation directory" false (Sys.file_exists directory);
  (match Invocation.lookup ~base_path:fixture.base_path ~keeper_name:keeper (original_invocation fixture) with
   | Ok None -> () | Ok (Some _) | Error _ -> fail "malformed source published a binding")

let await_composition env fixture accepted =
  let module Async = Masc.Keeper_msg_async in
  let request_id = accepted |> member "request_id" |> to_string in
  (* A test deadlock guard, not a runtime completion or polling deadline. *)
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
    let rec read_terminal () =
      match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
          ~caller:keeper request_id with
      | Ok proof ->
          let entry = Async.durable_terminal_entry proof in
          (match entry.status with
           | Async.Done {ok;data=Some data;_} -> ok, data, entry
           | Async.Waiting_for_dependencies {data=Some data;_} -> false, data, entry
           | Async.Cancelled _ -> false, Async.entry_to_json entry, entry
           | Queued | Running | Cancelling _ | Lost _
           | Persistence_failed _ | Done {data=None;_}
           | Waiting_for_dependencies {data=None;_} ->
             failf "composition did not settle a result: %s"
               (Async.entry_to_json entry |> Yojson.Safe.to_string))
      | Error (Async.Canonical_terminal_absent | Canonical_terminal_runtime_active _) ->
          Eio.Fiber.yield (); read_terminal ()
      | Error error -> fail (Async.canonical_terminal_error_to_string error)
    in read_terminal ())

let composition_reference label json =
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | Tool_output.Not_normalized_artifact_ref ->
      failf "%s is not a canonical artifact reference: %s" label (Yojson.Safe.to_string json)
  | Tool_output.Invalid_normalized_artifact_ref {detail} ->
      failf "%s is invalid: %s; value=%s" label detail (Yojson.Safe.to_string json)

let composition_nodes fixture data =
  let reference = data |> member "execution_artifact" |> composition_reference "execution artifact" in
  let bytes = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256:reference.sha256 with
    | Ok (Some bytes) -> bytes | Ok None | Error _ -> fail "complete execution artifact unavailable" in
  check int "execution artifact retains exact bytes" reference.bytes (String.length bytes);
  result_document ~base_path:fixture.base_path bytes |> member "nodes" |> to_list

let composition_node name nodes = List.find (fun row -> row |> member "node_id" |> to_string = name) nodes

let test_named_async_result_parent ?(child_waits=false) ?(child_cancelled=false) ~child_fails () = with_fixture @@ fun env initialize fixture ->
  let module Async = Masc.Keeper_msg_async in
  let module Surface = Masc.Keeper_capability_surface in
  let module Recorder = Masc.Keeper_skill_activation_recorder in
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  if not child_waits then (
    control_job fixture id (`Assoc ["state",`String "exited"]);
    ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-child-input"
      ~turn:41 "keeper_job_status" (argument id))));
  let owned_id = Store.Job_id.of_string id |> require "original child job" in
  let owner = Filename.concat (Store.paths ~base_path:fixture.base_path owned_id).job_dir "owner.jsonl" in
  let owner_bytes = read owner in
  Fun.protect ~finally:(fun () -> write owner owner_bytes) @@ fun () ->
  let config = Workspace.default_config fixture.base_path in
  let child_independent = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:"completed child independent branch\n" ~mime:"text/plain" in
  let skill_dir = Filename.concat fixture.base_path ".agents/skills/named-result-child" in
  Fs_compat.mkdir_p skill_dir;
  write (Filename.concat skill_dir "SKILL.md") (Printf.sprintf {|---
name: named-result-child
description: Observe the original owned job and select its complete stdout.
---

```toml composition
[[compositions]]
name = "named-result-child"
execution = "async"
%s[[compositions.nodes]]
id = "observe"
after = [%s]
tool = "keeper_job_result"
[compositions.nodes.input]
kind = "literal"
value = { job_id = %S }
[[compositions.exports]]
name = "stdout"
node = "observe"
pointer = "/artifacts/0/_blob/sha256"
```
|} (if child_waits then Printf.sprintf {|[[compositions.nodes]]
id = "child-independent"
tool = "keeper_artifact_read"
[compositions.nodes.input]
kind = "literal"
value = { sha256 = %S }
|} child_independent.sha256 else "") (if child_waits then "\"child-independent\"" else "") id);
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
    |> require "named child workspace" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "named child publication retired");
  let snapshot = Skill_catalog_snapshot_service.current ~workspace
    |> function Some value -> value | None -> fail "named child snapshot missing" in
  let reference = match Skill_catalog_snapshot.entries snapshot with
    | [entry] -> Skill_catalog_snapshot.entry_reference entry | _ -> fail "one named child required" in
  let descriptors = Descriptor.all_descriptors () in
  let selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-A" [reference]
    |> require "named child original Task selection" in
  let catalog,diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  check int "named async child is publicly composable" 0 (List.length diagnostics);
  let surface = Surface.create_with_descriptors ~tool_descriptors:descriptors ~tool_deny:[]
      ~sandbox_profile:fixture.meta.sandbox_profile ~skill_names:None ~global_skill_catalog:catalog
      ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors snapshot)
      ~task_skills:(Masc.Keeper_task_skill_turn.skills selection) in
  let recorder = Recorder.make ~trace_id:fixture.meta.runtime.trace_id
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:1)
      ~runtime_id:(fun () -> Some "original.runtime")
      ~snapshot_revision:(Surface.skill_snapshot_revision surface) ~task_selection:selection
    |> require "named child original activation" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface ~config ~meta:fixture.meta
      ~publication_recovery ~capability_surface:surface ~skill_activation_context:recorder
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"canonical child result fixture")
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:fixture.cell () in
  let fixture = {fixture with make_bundle} in
  let entered,notify_entered = Eio.Promise.create () in
  let released,notify_released = Eio.Promise.create () in
  let latch_mutex = Stdlib.Mutex.create () and latch_condition = Condition.create () in
  let release_requested = ref false in
  let release () =
    Stdlib.Mutex.lock latch_mutex;
    release_requested := true;
    Condition.broadcast latch_condition;
    Stdlib.Mutex.unlock latch_mutex in
  Fun.protect ~finally:release @@ fun () ->
  Eio.Fiber.fork ~sw:(Async.server_background_switch () |> require "original child lock holder scope") (fun () ->
    let outcome = Eio_unix.run_in_systhread (fun () ->
      Fs_compat.update_existing_private_file_durable_locked_result owner (fun _bytes ->
        Eio.Promise.resolve notify_entered ();
        Stdlib.Mutex.lock latch_mutex;
        while not !release_requested do Condition.wait latch_condition latch_mutex done;
        Stdlib.Mutex.unlock latch_mutex;
        None, ())) in
    Eio.Promise.resolve notify_released outcome);
  Eio.Promise.await entered;
  let child = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"named-child-start"
      ~turn:41 "keeper_compose_named-result-child" (`Assoc [])) in
  let binding_json = child |> member "result_wait" in
  let binding = Dependency.composition_of_json binding_json |> require "producer-owned result binding" in
  check string "result binding retains actual accepted child" (child |> member "request_id" |> to_string) binding.request_id;
  check bool "result binding retains exact admitted revision" true (Skill_reference.equal reference binding.skill_reference);
  let child_backend_calls = List.length (calls fixture) in
  let assert_wrong_binding () = List.iter (fun (field,value) ->
      let changed = match binding_json with `Assoc fields -> `Assoc ((field,value)::List.remove_assoc field fields)
        | _ -> fail "named binding is not an object" in
      with_bundle fixture (fun bundle ->
        match invoke_raw bundle ~tool_use_id:("wrong-child-" ^ field) ~turn:52
            "keeper_composition_result" (`Assoc ["binding",changed]) with
        | Error _ -> () | Ok _ -> failf "changed original %s supplied a child result" field))
    ["composition_tool",`String "keeper_compose_other-child";
     "composition_run_id",`String (Masc.Keeper_tool_plan.Composition_run_id.to_string (Masc.Keeper_tool_plan.Composition_run_id.fresh ()));
     "source_task_id",`String "task-B";"source_turn",`Int 52;
     "parent_tool_use_id",`String "different-original-call";
     "skill_reference",Skill_reference.to_yojson (Skill_reference.make ~identity:reference.identity
       ~content_revision:(Skill_reference.content_revision_of_source_text "different revision"))] in
  assert_wrong_binding ();
  with_bundle fixture (fun bundle ->
    ignore (invoke fixture bundle ~tool_use_id:"direct-child-pending" ~turn:41
      "keeper_composition_result" (`Assoc ["binding",binding_json]));
    check bool "direct pending child read leaves the Keeper able to act" true
      (bundle.terminal_effect_state () = Masc.Keeper_tools_agent_core.Terminal_effect_open));
  check int "pending result reads never inspect the child backend" child_backend_calls (List.length (calls fixture));
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:"independent branch\n" ~mime:"text/plain" in
  let literal value = `Assoc ["kind",`String "literal";"value",value] in
  let await_node name = `Assoc ["id",`String name;"tool",`String "keeper_composition_result";
    "input",literal (`Assoc ["binding",binding_json])] in
  let recipe = `Assoc ["execution",`String "async";"branch_failure_policy",`String "continue_independent";
    "nodes",`List [await_node "await";await_node "await-also";
      `Assoc ["id",`String "sibling";"tool",`String "keeper_artifact_read";
        "input",literal (`Assoc ["sha256",`String sibling.sha256])];
      `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";"after",`List [`String "await"];
        "input",`Assoc ["kind",`String "object";"fields",`List
          [`Assoc ["name",`String "sha256";"value",`Assoc ["kind",`String "output";
            "node",`String "await";"pointer",`String "/result_artifact/_blob/sha256"]]]]]];
    "exports",`List [`Assoc ["name",`String "child_result";"node",`String "consume";"pointer",`String "/content"]]] in
  let started = Mtime_clock.counter () in
  let draft = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-child-parent"
      ~turn:41 "keeper_composition_prepare" recipe) in
  let sha256 = draft |> member "draft" |> composition_reference "child parent draft" |> fun ref -> ref.sha256 in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"run-child-parent"
      ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String sha256])) in
  let ok,first,entry = await_composition env fixture accepted in
  check bool "pending child parks its prepared parent" false ok;
  (match entry.status with
   | Async.Waiting_for_dependencies {dependencies;_} ->
     check bool "two reads retain one original child dependency" true
       (dependencies = [Dependency.Composition_result binding])
   | _ -> fail "pending child result became a terminal parent failure");
  let prepare_to_wait_ms = Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000. in
  let original_nodes = composition_nodes fixture first in
  let run_id = accepted |> member "composition_run_id" |> to_string in
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "parent identity")
    |> require "parent durable journal" in
  let continuation = Journal.waiting_continuation journal |> require "suspended child parent"
    |> function Some value -> value | None -> fail "child parent wait missing" in
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness continuation with
   | Ok Journal.Waiting_for_results -> () | Ok Results_ready | Error _ -> fail "active child result appeared ready");
  set_source fixture ~task_id:"task-B" ~turn:52;
  if child_fails then write owner "corrupt-original-child-owner\n";
  if child_cancelled then (
    match Async.cancel ~base_path:fixture.base_path ~caller:keeper binding.request_id with
    | Async.Cancellation_requested _ -> ()
    | other -> failf "actual named cancellation refused: %s"
        (Yojson.Safe.to_string (Async.cancel_result_to_json ~request_id:binding.request_id other)));
  release ();
  (match Eio.Promise.await released with
   | Fs_compat.Private_file_succeeded (Some ()) -> ()
   | _ -> fail "original owner read-lock fixture did not settle");
  let child_ok,child_result,child_entry = await_composition env fixture child in
  let child_ok,child_result,child_entry = if not child_waits then child_ok,child_result,child_entry else (
    (match child_entry.status with
     | Async.Waiting_for_dependencies {dependencies;_} ->
       check bool "named producer parks on its own original owned job" true
         (dependencies = [Dependency.Owned_job owned_id])
     | _ -> fail "named producer did not release its waiting worker");
    let original_child_nodes = composition_nodes fixture child_result in
    let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
        ~composition_run_id:binding.composition_run_id |> require "named producer journal" in
    let child_continuation = Journal.waiting_continuation child_journal |> require "named producer continuation"
      |> function Some value -> value | None -> fail "named producer lost its owned job wait" in
    (match (Journal.source child_journal).producer with
     | Journal.Named {activation=Some original;tool_name;skill_reference;origin=Standalone} ->
       check int "named original SDK turn remains distinct from the physical Keeper frame" 41
         (Journal.source child_journal).source_turn;
       check int "named physical Keeper frame remains sealed" 1
         (Ids.Turn_ref.absolute_turn (Recorder.bound_turn_ref original));
       check string "named journal retains the original tool" binding.composition_tool tool_name;
       check bool "named journal retains the exact reference" true (Skill_reference.equal reference skill_reference);
       check bool "named journal retains original Task Skill selection" true
         (List.exists (Skill_reference.equal reference) (Recorder.bound_task_references original))
     | Named {activation=None;_} | Named {activation=Some _;origin=Nested _;_} | Prepared -> fail "named original standalone activation was not sealed");
    with_bundle fixture (fun bundle -> ignore (invoke fixture bundle ~tool_use_id:"parked-child-read" ~turn:52
      "keeper_composition_result" (`Assoc ["binding",binding_json])));
    check bool "released child still leaves parent waiting" true
      (Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness continuation
       = Ok Journal.Waiting_for_results);
    control_job fixture id (`Assoc ["state",`String "exited"]);
    ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-original-child-job"
      ~turn:52 "keeper_job_status" (argument id)));
    Process_eio.reset_for_testing (); initialize ();
    let before = List.length (calls fixture) in
    let stopped_switch = Eio.Switch.run (fun sw -> sw) in
    let dispatched = ref 0 in
    let lost = Async.submit_worker_with_request_id ?request_context:child_entry.request_context
        ~background_sw:stopped_switch ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id -> Journal.bind_continuation child_continuation ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string)
        ~f:(fun ~request_id:_ _ -> incr dispatched;
          Async.worker_finished (Tool_result.make_ok ~tool_name:"unstarted-named-successor"
            ~start_time:(Tool_timing.start ()) ())) () in
    let lost_id = match lost with
      | Error (Async.Background_fork_failed {request_id;_}) -> request_id
      | Error _ | Ok _ -> fail "named successor did not stop after its actual journal admission" in
    check int "Lost named successor starts no replacement work" 0 !dispatched;
    let child_continuation = Journal.waiting_continuation child_journal |> require "Lost named recovery"
      |> function Some value -> value | None -> fail "Lost named successor lost original job wait" in
    check string "named recovery retains the current Lost owner" lost_id
      (Journal.continuation_request_id child_continuation);
    with_bundle fixture (fun bundle -> ignore (invoke fixture bundle ~tool_use_id:"lost-named-read" ~turn:52
      "keeper_composition_result" (`Assoc ["binding",binding_json])));
    check bool "recoverable Lost child keeps its original parent pending" true
      (Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness continuation
       = Ok Journal.Waiting_for_results);
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"fresh-named-continuation" ~turn:52
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    let settled = ref None in
    let raced_read = Masc.Keeper_composition_dependency_result.For_testing.handle
        ~after_owner_read:(fun (observed : Async.entry) ->
          if String.equal observed.request_id lost_id then (
            let successor = Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface:surface
                ~continuation:child_continuation ~config ~meta:fixture.meta ~publication_recovery
                ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"fresh named continuation")
                ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ()) ~invocation
                ~clock:(Eio.Stdenv.clock env) () |> Tool_result.data in
            check_json "named successor retains the first public result binding" binding_json (successor |> member "result_wait");
            check bool "named successor uses a new physical request" true
              (successor |> member "request_id" |> to_string <> binding.request_id);
            settled := Some (await_composition env fixture successor)))
        ~config ~meta:fixture.meta ~args:(`Assoc ["binding",binding_json]) in
    let outcome,completed,entry = match !settled with
      | Some settled -> settled | None -> fail "actual successor did not interleave the Lost result observation" in
    check bool "owner transition never publishes stale physical Lost as final failure" true
      (match raced_read.disposition with Tool_result.Completed () -> true | Deferred () | Failed _ -> false);
    (match raced_read.data with
     | Some data -> check_json "racing read selects the current successful logical result" completed (data |> member "result")
     | None -> fail "racing read lost the canonical structured result");
    check int "named continuation reads no backend after canonical job completion" before (List.length (calls fixture));
    List.iter (fun field -> check_json ("named result recheck retains original " ^ field)
      (composition_node "observe" original_child_nodes |> member field)
      (composition_node "observe" (composition_nodes fixture completed) |> member field)) ["execution_id";"tool_use_id"];
    check_json "named continuation reuses its completed independent node" (`String "retained_completion")
      (composition_node "child-independent" (composition_nodes fixture completed) |> member "execution_origin");
    (match entry.request_context with
     | Some fields -> check_json "named successor retains original Task" (`String "task-A") (List.assoc "source_task_id" fields)
     | None -> fail "named successor source missing");
    let competing = Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface:surface
        ~continuation:child_continuation ~config ~meta:fixture.meta ~publication_recovery
        ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"stale named continuation")
        ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ()) ~invocation
        ~clock:(Eio.Stdenv.clock env) () in
    check bool "completed named successor rejects stale sealed owner" false (Tool_result.is_success competing);
    outcome,completed,entry) in
  check bool "canonical named child preserves its actual success or failure" (not (child_fails || child_cancelled)) child_ok;
  if child_cancelled then (
    (match child_entry.status with Async.Cancelled _ -> () | _ -> fail "named cancellation did not remain Cancelled");
    let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
        ~composition_run_id:binding.composition_run_id |> require "cancelled named journal" in
    match Journal.waiting_continuation child_journal with
    | Ok None -> () | Ok (Some _) | Error _ -> fail "named cancellation granted successor authority");
  write owner owner_bytes;
  Process_eio.reset_for_testing (); initialize ();
  assert_wrong_binding ();
  if child_fails then with_bundle fixture (fun bundle ->
    let tool_use_id = "failed-child-reader" in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn:52
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
    let tool = List.find (fun (tool : Agent_core.Tool.t) -> tool.schema.name = "keeper_composition_result") bundle.tools in
    (match Agent_core.Tool.execute ~invocation tool (`Assoc ["binding",binding_json]) with
     | Error _ -> () | Ok _ -> fail "failed child read became success");
    let retained = Call_log.peek_retained_artifacts ~invocation () in
    let child_artifact = child_result |> member "execution_artifact" |> composition_reference "failed child execution" in
    check bool "actual failed public read keeps original artifact in per-call carrier" true
      (List.exists (fun (ref : Tool_output.artifact_ref) -> ref.sha256=child_artifact.sha256) retained));
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness continuation with
   | Ok Journal.Results_ready -> () | Ok Waiting_for_results | Error _ -> fail "canonical child completion did not ready its original parent");
  let copied = Async.submit_worker_with_request_id ?request_context:child_entry.request_context
      ~background_sw:(Async.server_background_switch () |> require "copied worker scope")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~f:(fun ~request_id:_ _ -> Async.worker_finished (Tool_result.make_ok ~tool_name:"copied-child-context"
        ~start_time:(Tool_timing.start ()) ~data:child_result ())) () |> require "real copied context worker" in
  ignore (await_composition env fixture (`Assoc ["request_id",`String copied.request_id]));
  let copied_binding = match binding_json with `Assoc fields -> `Assoc
      (("request_id",`String copied.request_id)::List.remove_assoc "request_id" fields) | _ -> fail "binding shape" in
  with_bundle fixture (fun bundle -> match invoke_raw bundle ~tool_use_id:"copied-child-read" ~turn:52
      "keeper_composition_result" (`Assoc ["binding",copied_binding]) with
    | Error _ -> () | Ok _ -> fail "generic copied source borrowed named child admission");
  let backend_before_resume = List.length (calls fixture) in
  let resumed_started = Mtime_clock.counter () in
  let resumed = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"resume-child-parent"
      ~turn:52 "keeper_composition_run" (`Assoc ["sha256",`String sha256;"resume_run_id",`String run_id])) in
  let parent_ok,completed,completed_entry = await_composition env fixture resumed in
  check bool "parent preserves original child outcome" (not (child_fails || child_cancelled)) parent_ok;
  check int "parent resumption never re-executes the original child backend" backend_before_resume (List.length (calls fixture));
  let completed_nodes = composition_nodes fixture completed in
  List.iter (fun name -> List.iter (fun field -> check_json (name ^ " retains original " ^ field)
      (composition_node name original_nodes |> member field) (composition_node name completed_nodes |> member field))
      ["execution_id";"tool_use_id"]) ["await";"await-also";"sibling"];
  check_json "independent completed branch is reused" (`String "retained_completion")
    (composition_node "sibling" completed_nodes |> member "execution_origin");
  if child_fails || child_cancelled then (
    let failure = composition_node "await" completed_nodes |> member "result" in
    if child_cancelled then check_json "cancelled child keeps its exact actor and reason" (Async.entry_to_json child_entry)
      (failure |> member "data" |> member "request")
    else check_json "failed child keeps its canonical structured diagnostic" child_result
      (failure |> member "data" |> member "request" |> member "result");
    check bool "child failure supplies no successful downstream stdout" true
      (completed |> member "exports" |> member "child_result" |> member "available" = `Bool false))
  else (
    let manifest = completed |> member "exports" |> member "child_result" |> member "value" |> to_string |> Yojson.Safe.from_string in
    let selected = match Tool_output.artifact_manifest_of_json manifest with
      | Tool_output.Decoded_artifact_manifest manifest -> manifest.structured_content
      | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> fail "dependent read lost full original child manifest" in
    check_json "dependent read consumes the full original canonical child result" child_result (selected |> member "result");
    check_json "dependent artifact read retains the original named result binding" binding_json (selected |> member "binding");
    let stdout_sha = selected |> member "result" |> member "exports" |> member "stdout" |> member "value" |> to_string in
    let stdout = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"read-original-child-stdout" ~turn:52
      "keeper_artifact_read" (`Assoc ["sha256",`String stdout_sha])) in
    check_json "selected child export still names complete original stdout" (`String stdout_bytes) (stdout |> member "content"));
  let source = match completed_entry.request_context with Some fields -> `Assoc fields | None -> fail "original parent source missing" in
  check_json "fresh turn retains original parent Task" (`String "task-A") (source |> member "source_task_id");
  check int "named child never recreates the original program" 1 (effect_count fixture "create");
  check int "named child never restarts the original program" 1 (effect_count fixture "start");
  Printf.printf "composition_named_result_measurement=%s\n%!" (Yojson.Safe.to_string
    (`Assoc ["scope",`String "public named readonly producer held by original owner transaction; fresh-turn parent resume; synthetic CLI";
      "child_failed",`Bool child_fails;"child_cancelled",`Bool child_cancelled;"child_released_worker",`Bool child_waits;"prepare_to_wait_ms",`Float prepare_to_wait_ms;
      "resume_to_terminal_ms",`Float (Mtime.Span.to_float_ns (Mtime_clock.count resumed_started) /. 1_000_000.);
      "resume_backend_calls",`Int (List.length (calls fixture)-backend_before_resume)]))

type parked_named_producer =
  { config : Workspace.config
  ; publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context
  ; surface : Masc.Keeper_capability_surface.t
  ; reference : Skill_reference.t
  ; binding_json : Yojson.Safe.t
  ; binding : Dependency.composition
  ; child : Yojson.Safe.t
  ; child_continuation : Journal.continuation
  ; parent_continuation : Journal.continuation
  ; job_id : string
  }

let with_parked_named_producer env fixture f =
  let module Async = Masc.Keeper_msg_async in
  let module Surface = Masc.Keeper_capability_surface in
  let module Recorder = Masc.Keeper_skill_activation_recorder in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let owned_id = Store.Job_id.of_string id |> require "original producer job" in
  let owner = Filename.concat (Store.paths ~base_path:fixture.base_path owned_id).job_dir "owner.jsonl" in
  let owner_bytes = read owner in
  Fun.protect ~finally:(fun () -> write owner owner_bytes) @@ fun () ->
  let config = Workspace.default_config fixture.base_path in
  let skill_dir = Filename.concat fixture.base_path ".agents/skills/named-result-child" in
  Fs_compat.mkdir_p skill_dir;
  write (Filename.concat skill_dir "SKILL.md") (Printf.sprintf {|---
name: named-result-child
description: Observe the original owned job and select its complete stdout.
---

```toml composition
[[compositions]]
name = "named-result-child"
execution = "async"
[[compositions.nodes]]
id = "observe"
after = []
tool = "keeper_job_result"
[compositions.nodes.input]
kind = "literal"
value = { job_id = %S }
[[compositions.exports]]
name = "stdout"
node = "observe"
pointer = "/artifacts/0/_blob/sha256"
```|} id);
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
    |> require "named producer workspace" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "named producer publication retired");
  let snapshot = Skill_catalog_snapshot_service.current ~workspace
    |> function Some value -> value | None -> fail "named producer snapshot missing" in
  let reference = match Skill_catalog_snapshot.entries snapshot with
    | [entry] -> Skill_catalog_snapshot.entry_reference entry | _ -> fail "one named producer required" in
  let descriptors = Descriptor.all_descriptors () in
  let catalog,diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  check int "named async producer is publicly composable" 0 (List.length diagnostics);
  let surface = Surface.create_with_descriptors ~tool_descriptors:descriptors ~tool_deny:[]
    ~sandbox_profile:fixture.meta.sandbox_profile ~skill_names:None ~global_skill_catalog:catalog
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors snapshot) ~task_skills:[] in
  let selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-A" [reference]
    |> require "named producer original Task selection" in
  let recorder = Recorder.make ~trace_id:fixture.meta.runtime.trace_id
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:41)
    ~runtime_id:(fun () -> Some "original.runtime")
    ~snapshot_revision:(Surface.skill_snapshot_revision surface) ~task_selection:selection
    |> require "named producer original activation" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface ~config ~meta:fixture.meta
    ~publication_recovery ~capability_surface:surface ~skill_activation_context:recorder
    ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"named producer refusal fixture")
    ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:fixture.cell () in
  let fixture = {fixture with make_bundle} in
  let entered,notify_entered = Eio.Promise.create () in
  let released,notify_released = Eio.Promise.create () in
  let latch_mutex = Stdlib.Mutex.create () and latch_condition = Condition.create () in
  let release_requested = ref false in
  let release () =
    Stdlib.Mutex.lock latch_mutex;
    release_requested := true;
    Condition.broadcast latch_condition;
    Stdlib.Mutex.unlock latch_mutex in
  Fun.protect ~finally:release @@ fun () ->
  Eio.Fiber.fork ~sw:(Async.server_background_switch () |> require "named producer lock holder scope") (fun () ->
    let outcome = Eio_unix.run_in_systhread (fun () ->
      Fs_compat.update_existing_private_file_durable_locked_result owner (fun _bytes ->
        Eio.Promise.resolve notify_entered ();
        Stdlib.Mutex.lock latch_mutex;
        while not !release_requested do Condition.wait latch_condition latch_mutex done;
        Stdlib.Mutex.unlock latch_mutex;
        None, ())) in
    Eio.Promise.resolve notify_released outcome);
  Eio.Promise.await entered;
  let child = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"named-producer-start"
      ~turn:41 "keeper_compose_named-result-child" (`Assoc [])) in
  let binding_json = child |> member "result_wait" in
  let binding = Dependency.composition_of_json binding_json |> require "producer-owned result binding" in
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:"independent parent branch\n" ~mime:"text/plain" in
  let literal value = `Assoc ["kind",`String "literal";"value",value] in
  let await_node name = `Assoc ["id",`String name;"tool",`String "keeper_composition_result";
    "input",literal (`Assoc ["binding",binding_json])] in
  let recipe = `Assoc ["execution",`String "async";"branch_failure_policy",`String "continue_independent";
    "nodes",`List [await_node "await";await_node "await-also";
      `Assoc ["id",`String "sibling";"tool",`String "keeper_artifact_read";
        "input",literal (`Assoc ["sha256",`String sibling.sha256])];
      `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";"after",`List [`String "await"];
        "input",`Assoc ["kind",`String "object";"fields",`List
          [`Assoc ["name",`String "sha256";"value",`Assoc ["kind",`String "output";
            "node",`String "await";"pointer",`String "/result_artifact/_blob/sha256"]]]]]];
    "exports",`List [`Assoc ["name",`String "child_result";"node",`String "consume";"pointer",`String "/content"]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-producer-parent"
      ~turn:41 "keeper_composition_prepare" recipe) in
  let sha256 = prepared |> member "draft" |> composition_reference "producer parent draft" |> fun ref -> ref.sha256 in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"run-producer-parent"
      ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String sha256])) in
  let ok,_first,entry = await_composition env fixture accepted in
  check bool "pending named producer parks its prepared parent" false ok;
  (match entry.status with
   | Async.Waiting_for_dependencies {dependencies;_} ->
     check bool "parent retains the producer-owned result dependency" true
       (dependencies = [Dependency.Composition_result binding])
   | _ -> fail "pending producer result became a terminal parent failure");
  (* The producer worker stays blocked on the held owner read while the
     parent parks; release it and wait for the producer's durable wait. *)
  release ();
  (match Eio.Promise.await released with
   | Fs_compat.Private_file_succeeded (Some ()) -> ()
   | _ -> fail "original owner read-lock fixture did not settle");
  let child_ok,_child_data,child_entry = await_composition env fixture child in
  check bool "pending named producer parks on its original owned job" false child_ok;
  (match child_entry.status with
   | Async.Waiting_for_dependencies {dependencies;_} ->
     check bool "named producer retains its original owned job dependency" true
       (dependencies = [Dependency.Owned_job owned_id])
   | _ -> fail "named producer did not park on its owned job wait");
  let parent_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.of_string
          (accepted |> member "composition_run_id" |> to_string) |> require "parent identity")
    |> require "parent durable journal" in
  let parent_continuation = Journal.waiting_continuation parent_journal |> require "suspended producer parent"
    |> function Some value -> value | None -> fail "parent wait missing" in
  let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:binding.composition_run_id |> require "named producer journal" in
  let child_continuation = Journal.waiting_continuation child_journal |> require "suspended named producer"
    |> function Some value -> value | None -> fail "named producer wait missing" in
  (match (Journal.source child_journal).producer with
   | Journal.Named {activation=Some original;tool_name;skill_reference;_} ->
     check string "named journal retains the original tool" binding.composition_tool tool_name;
     check bool "named journal retains the exact reference" true (Skill_reference.equal reference skill_reference);
     check bool "named journal retains original Task Skill selection" true
       (List.exists (Skill_reference.equal reference) (Recorder.bound_task_references original))
   | Named {activation=None;_} | Prepared -> fail "named original activation was not sealed");
  f { config; publication_recovery; surface; reference; binding_json; binding; child
    ; child_continuation; parent_continuation; job_id=id }

let resume_parked_continuation env fixture ?meta ?on_recovery_held surface continuation =
  let meta = match meta with None -> fixture.meta | Some meta -> meta in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"physical-continuation-intake"
      ~turn:52 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  Masc.Keeper_tool_composition_surface.resume_continuation ?on_recovery_held ~capability_surface:surface ~continuation
    ~config:(Workspace.default_config fixture.base_path) ~meta
    ~publication_recovery:{provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper}
    ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"named producer refusal fixture")
    ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
    ~invocation ~clock:(Eio.Stdenv.clock env) ()

(* Resuming under another Keeper's metadata fails intake and holds exactly
   once naming the sealed request: the keeper-identity gate runs before
   readiness is consulted, so no job completion is needed to reach it. *)
let test_owner_mismatch_reports_hold_before_readiness () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR", None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let readiness = Journal.continuation_readiness
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      parked.child_continuation in
  check bool "child still waits on its owned job" true (readiness = Ok Journal.Waiting_for_results);
  let wrong_meta = { fixture.meta with name = "someone-else" } in
  let held = ref [] in
  let resumed = resume_parked_continuation env fixture ~meta:wrong_meta parked.surface
      parked.child_continuation
      ~on_recovery_held:(fun ~request_id ~reason -> held := (request_id, reason) :: !held) in
  check bool "foreign metadata fails intake" true (Tool_result.is_failed resumed);
  check int "failing intake reports hold once" 1 (List.length !held);
  check string "hold names the sealed request" parked.binding.request_id (fst (List.hd !held));
  check string "hold reason pins the keeper-identity gate"
    (Journal.error_to_string Journal.Source_conflict) (snd (List.hd !held))

(* A pulse that reports held original authority is not resumed again by the
   same supervisor: the hold suppresses the repeat attempt for that exact
   canonical request, so a persistently failing cause grows no new request,
   outbox obligation or marker per pulse. A fresh supervisor — a restarted
   server — retries once, then holds again. Discovery is production; only
   the intake outcome is stubbed, and each pulse runs under its own switch
   so the forked intake fibers settle before the counts are read. *)
let test_held_continuation_is_not_retried_until_restart () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR", None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  control_job fixture parked.job_id (`Assoc ["state", `String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-before-hold-proof"
      ~turn:52 "keeper_job_status" (argument parked.job_id)));
  let discover () =
    Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "hold-proof discovery" in
  let report0 = discover () in
  let ready0 = report0.ready in
  let ready_ids report =
    List.sort String.compare (List.map Journal.continuation_request_id report.Journal.ready) in
  check bool "the parked child reads ready after collection" true
    (List.exists (fun candidate ->
       String.equal (Journal.continuation_request_id candidate) parked.binding.request_id) ready0);
  let calls = ref [] in
  let stub ~on_recovery_held ~profiles:_ ~context:_ candidate =
    let request_id = Journal.continuation_request_id candidate in
    calls := request_id :: !calls;
    on_recovery_held ~request_id ~cause:(Wake.Explicit_recovery_required "hold-proof stub holds every intake");
    Error (Wake.Runtime_failed "original worker authority requires explicit recovery") in
  let context =
    Eio.Switch.run @@ fun sw ->
    let open Masc.Keeper_types_profile in
    { config = Workspace.default_config fixture.base_path
    ; agent_name = keeper
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider
    } in
  (* The context's switch has exited by the time pulses run, which is sound
     here: the pulse forks on its own switch argument and the stub ignores
     the context, so only the config (discovery root) is live data. *)
  let pulse supervisor =
    Eio.Switch.run @@ fun sw ->
    Wake.For_testing.pulse ~resume:stub ~sw supervisor in
  let supervisor = Wake.create ~context () in
  pulse supervisor;
  let first = List.length !calls in
  check int "first pulse resumes every ready candidate" (List.length ready0) first;
  pulse supervisor;
  check int "second pulse resumes nothing while held" first (List.length !calls);
  let report1 = discover () in
  check int "held pulses settle nothing" (List.length ready0) (List.length report1.ready);
  check (list string) "held pulses keep the same ready candidates"
    (ready_ids report0) (ready_ids report1);
  check int "held pulses keep the same waiting count" report0.waiting report1.waiting;
  check int "held pulses retire nothing" report0.retired report1.retired;
  check int "held pulses add no discovery failure"
    (List.length report0.failures) (List.length report1.failures);
  let restarted = Wake.create ~context () in
  pulse restarted;
  check int "a restarted supervisor retries once" (first * 2) (List.length !calls);
  pulse restarted;
  check int "a restarted supervisor holds again after one retry" (first * 2) (List.length !calls)

let test_original_evidence_repair_reactivates_continuation ~skill_publication () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR", None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module O = Masc.Keeper_skill_preparation_observation in
  control_job fixture parked.job_id (`Assoc ["state", `String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-before-authority-repair" ~turn:52 "keeper_job_status" (argument parked.job_id)));
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path
      ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original authority recovery fixture\"\n";
  let source = Journal.continuation_source parked.child_continuation in
  let blob = Tool_blob_store.create ~base_path:fixture.base_path in
  let run_path = Filename.concat (Filename.concat (Tool_blob_store.root_dir blob)
      (String.sub source.run_reference.sha256 0 2)) source.run_reference.sha256 in
  let skills_path = Filename.concat fixture.base_path ".agents/skills" in
  let original_path = if skill_publication then skills_path else run_path in
  let detached_path = original_path ^ ".fixture-held" in
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "recovery fixture published workspace" in
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  let publish () = match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path; source_text=read runtime_path}) with
    | Published _ | Unchanged _ -> () | Workspace_retired -> fail "authority fixture publication retired" in
  let repair () =
    if Sys.file_exists detached_path then (
      if Sys.file_exists original_path then Unix.unlink original_path;
      Unix.rename detached_path original_path) in
  Fun.protect ~finally:repair @@ fun () ->
  let context : _ Masc.Keeper_types_profile.context =
    {config=parked.config; agent_name="authority-repair-maintenance";
     sw=Masc.Keeper_msg_async.server_background_switch () |> require "authority repair background switch";
     clock=Eio.Stdenv.clock env; proc_mgr=Some (Eio.Stdenv.process_mgr env); net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let outcomes = ref [] and reported_hold = ref None in
  let failed_preparations = ref [] and repaired_preparations = ref [] in
  let notify_again = ref (fun () -> ()) in
  let supervisor = Wake.create ~context ~on_result:(fun candidate outcome ->
      check (option string) "recovery retains the original Task" (Some "task-A")
        (Journal.continuation_source candidate).source_task_id;
      outcomes := (candidate, outcome) :: !outcomes) () in
  let initial_resume ~on_recovery_held ~profiles:_ ~context candidate =
    check string "fault is injected only into the original child intake"
      parked.binding.request_id (Journal.continuation_request_id candidate);
    Unix.rename original_path detached_path;
    if skill_publication then (write original_path "source temporarily not a directory\n"; publish ());
    let outcome = O.capture_result ~on_report:(fun report -> failed_preparations := report :: !failed_preparations)
      (fun () -> Wake.resume ~context candidate ~on_recovery_held:(fun ~request_id ~cause ->
        reported_hold := Some (request_id, cause); on_recovery_held ~request_id ~cause)) in
    (* A result hint at intake settlement still refers to this original
       canonical owner; it cannot release its unavailable evidence. *)
    !notify_again ();
    outcome in
  let backend_before = List.length (calls fixture) in
  Eio.Switch.run (fun sw ->
    let job = load fixture parked.job_id in
    let notification : Journal.result_notification =
      {base_path=job.base_path;keeper_name=job.keeper_name;dependency=Dependency.Owned_job job.job_id} in
    let notify () = Wake.For_testing.notify_result_ready ~resume:initial_resume ~sw supervisor notification in
    notify_again := notify;
    notify ();
    notify ());
  check int "one original intake reports the unavailable evidence" 1 (List.length !outcomes);
  (match !reported_hold with
   | Some (request_id, Wake.Original_run_unavailable _) when not skill_publication ->
     check string "run hold owns the sealed request" parked.binding.request_id request_id
   | Some (request_id, Wake.Task_skill_publication_unavailable _) when skill_publication ->
     check string "Skill hold owns the sealed request" parked.binding.request_id request_id
   | None | Some _ -> fail "pre-intake authority was not reported as a typed recoverable hold");
  let failed = match !failed_preparations with
    | [report] -> report | _ -> fail "one original failed preparation capture expected" in
  check bool "unavailable original evidence remains a failed preparation, not a retained success" true
    (failed.outcome=O.Returned_error
     && not (List.exists (fun (sample : O.sample) -> sample.component=O.Retained_turn_surface) failed.samples));
  let pulse () = Eio.Switch.run (fun sw -> Wake.pulse ~sw supervisor) in
  pulse ();
  check int "unchanged unavailable evidence starts no further intake" 1 (List.length !outcomes);
  check int "unavailable evidence never calls the job backend" backend_before (List.length (calls fixture));
  repair ();
  if skill_publication then (
    pulse ();
    check int "file restoration alone cannot borrow an unpublished Skill view" 1 (List.length !outcomes);
    publish ());
  set_source fixture ~task_id:"task-other" ~turn:90;
  ignore (O.capture_result ~on_report:(fun report -> repaired_preparations := report :: !repaired_preparations)
    (fun () -> pulse (); Ok ()));
  check int "repaired evidence revalidates the same original child once" 2 (List.length !outcomes);
  let repaired = match !repaired_preparations with
    | [report] -> report | _ -> fail "one repaired preparation capture expected" in
  check bool "repaired original child retains a completed preparation before consuming saved results" true
    (repaired.outcome=O.Returned
     && List.exists (fun (sample : O.sample) ->
       sample.component=O.Retained_turn_surface && sample.outcome=O.Returned
       && sample.decision=Some O.Reused) repaired.samples);
  let accepted_child = match snd (List.hd !outcomes) with
    | Ok result when Tool_result.is_success result -> Tool_result.data result
    | Ok _ | Error _ -> fail "repaired original child was not accepted" in
  let child_ok, _, child_entry = await_composition env fixture accepted_child in
  check bool "the original child produces a usable result after repair" true child_ok;
  check bool "physical recovery keeps a distinct request" true
    (child_entry.request_id <> parked.binding.request_id);
  ignore (Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
      |> require "original child result publication after repair");
  pulse ();
  let accepted_parent = List.find_map (fun (candidate, outcome) ->
      let source = Journal.continuation_source candidate in
      if Masc.Keeper_tool_plan.Composition_run_id.equal source.composition_run_id
          (Journal.continuation_source parked.parent_continuation).composition_run_id
      then match outcome with
        | Ok result when Tool_result.is_success result -> Some (Tool_result.data result)
        | Ok _ | Error _ -> None
      else None) !outcomes |> function
    | Some accepted -> accepted | None -> fail "original parent did not resume from the repaired child result" in
  let parent_ok, _, _ = await_composition env fixture accepted_parent in
  check bool "the original parent consumes its child's usable result" true parent_ok;
  check int "recovery consumes saved results without backend replay" backend_before (List.length (calls fixture))

let reject_cancelled_recovery_scope invoke =
  let exception Cancelled_recovery_scope in
  let rejected = ref false in
  (try Eio.Switch.run (fun sw -> Eio.Cancel.protect (fun () ->
     Eio.Switch.fail sw Cancelled_recovery_scope;
     match invoke sw with
     | () -> ()
     | exception (Eio.Cancel.Cancelled _) -> rejected := true))
   with Cancelled_recovery_scope -> ());
  check bool "cancelled recovery scope is refused even inside protected cleanup" true !rejected

let test_continuation_pulse_shares_declarations ~invalid_initial () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR", None] @@ fun () ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Profiles = Masc.Keeper_types_profile in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"])
    |> job_id in
  let recipe = `Assoc ["execution", `String "async"; "nodes", `List
      [`Assoc ["id", `String "await"; "tool", `String "keeper_job_result";
        "input", `Assoc ["kind", `String "literal"; "value", argument id]]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-profile-round" ~turn:41 "keeper_composition_prepare" recipe) in
  let draft = prepared |> member "draft" |> composition_reference "profile round draft" in
  let original_requests = List.map (fun suffix ->
      let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
          ~tool_use_id:("run-profile-round-" ^ suffix) ~turn:41
          "keeper_composition_run" (`Assoc ["sha256", `String draft.sha256])) in
      let ok, _, entry = await_composition env fixture accepted in
      check bool "each original run waits for its exact job" false ok;
      (match entry.Async.status with
       | Async.Waiting_for_dependencies {dependencies; _} ->
         check (list string) "both waits retain the original job" [id]
           (List.map dependency_job_id dependencies)
       | _ -> fail "profile round requires canonical original waits");
      entry.request_id) ["first"; "second"] in
  control_job fixture id (`Assoc ["state", `String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-before-profile-round" ~turn:52 "keeper_job_status" (argument id)));
  let discover () = Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "profile round canonical discovery" in
  let ready_ids () = (discover ()).ready |> List.map Journal.continuation_request_id
      |> List.sort String.compare in
  let original_requests = List.sort String.compare original_requests in
  check (list string) "two independent original runs become ready" original_requests (ready_ids ());
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path
      ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  let write_profile instructions = write declaration (Printf.sprintf
      "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = %S\n"
      instructions) in
  if invalid_initial then write declaration "[keeper\n" else write_profile "original projection";
  let context : _ Profiles.context =
    {config=Workspace.default_config fixture.base_path; agent_name="profile-round-maintenance";
     sw=Async.server_background_switch () |> require "profile round background switch";
     clock=Eio.Stdenv.clock env; proc_mgr=Some (Eio.Stdenv.process_mgr env); net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let supervisor = Wake.create ~context () in
  reject_cancelled_recovery_scope (fun sw ->
    Wake.pulse ~sw supervisor);
  check (list string) "rejected scope retains both canonical original waits" original_requests (ready_ids ());
  let backend_before = List.length (calls fixture) in
  let pulse ~invalid ~instructions =
    let observed = ref [] in
    Eio.Switch.run (fun sw ->
      Wake.For_testing.pulse ~sw supervisor
        ~resume:(fun ~on_recovery_held:_ ~profiles ~context:_ candidate ->
          check (option string) "shared declarations retain the original Task" (Some "task-A")
            (Journal.continuation_source candidate).source_task_id;
          (match Profiles.snapshot_profile_defaults profiles keeper with
           | Error {kind=Profiles.Parse_error; _} when invalid -> ()
           | Ok defaults when not invalid ->
             check (option string) "each intake uses the pulse's immutable declaration"
               (Some instructions) defaults.instructions
           | Ok _ | Error _ -> fail "declaration error was hidden or another projection was borrowed");
          observed := Journal.continuation_request_id candidate :: !observed;
          (* An edit after the first intake cannot split this pulse's projection.
             It must become visible to the next independent pulse. *)
          if List.length !observed = 1 then write_profile "next projection";
          Error (Wake.Runtime_failed "observation-only intake retains the canonical wait")));
    check (list string) "both original requests use this projection" original_requests
      (List.sort String.compare !observed) in
  pulse ~invalid:invalid_initial ~instructions:"original projection";
  pulse ~invalid:false ~instructions:"next projection";
  (* Explicit recovery has its own projection even after a maintenance pulse. *)
  write declaration "[keeper\n";
  let candidate = List.hd (discover ()).ready in
  (match Wake.resume ~context candidate with
   | Error (Wake.Profile_unavailable {kind=Profiles.Parse_error; _}) -> ()
   | Ok _ | Error _ -> fail "explicit resume borrowed an earlier maintenance declaration");
  check (list string) "projection failures preserve original canonical requests" original_requests (ready_ids ());
  check int "declaration projections never relaunch or query the job backend"
    backend_before (List.length (calls fixture))

let test_named_producer_skill_loss_settles_run_and_ends_parent () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Async = Masc.Keeper_msg_async in
  (* Readiness and original authority precede even a proven producer absence. *)
  control_job fixture parked.job_id (`Assoc ["state",`String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-before-producer-removal"
      ~turn:52 "keeper_job_status" (argument parked.job_id)));
  let skill_dir = Filename.concat fixture.base_path ".agents/skills/named-result-child" in
  Unix.unlink (Filename.concat skill_dir "SKILL.md");
  Unix.rmdir skill_dir;
  let empty_surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let before_calls = List.length (calls fixture) in
  let ledger_path = Filename.concat (Masc.Keeper_fs.keeper_session_dir parked.config
      (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id)) "skill-activation-events.jsonl" in
  let original_ledger = read ledger_path in
  Fun.protect ~finally:(fun () -> write ledger_path original_ledger) (fun () ->
    write ledger_path "corrupt-original-activation\n";
    let unavailable = resume_parked_continuation env fixture empty_surface parked.child_continuation in
    check bool "producer absence cannot bypass corrupt original activation" true (Tool_result.is_failed unavailable);
    let original_entry = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
        ~caller:keeper parked.binding.request_id |> require "corrupt activation preserves original terminal"
        |> Async.durable_terminal_entry in
    (match original_entry.status with
     | Async.Waiting_for_dependencies _ -> ()
     | _ -> fail "corrupt original activation closed the waiting named producer"));
  let unreadable_surface = frozen_surface_with_observation
      ~observation:(fun resolved_path -> Skill_catalog_snapshot.Source_unavailable
        {resolved_path;operation=Read_source_directory;detail="isolated source read unavailable"})
      ~tool_deny:[] ~tool_descriptors:(Descriptor.all_descriptors ())
      ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let unconfirmed = resume_parked_continuation env fixture unreadable_surface parked.child_continuation in
  check bool "unavailable source scan is not producer absence" true (Tool_result.is_failed unconfirmed);
  let unconfirmed_owner = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:parked.binding.composition_run_id |> require "unavailable source original owner"
      |> Journal.waiting_continuation |> require "unavailable source retains original wait"
      |> function Some continuation -> continuation | None -> fail "unavailable source became permanent" in
  check string "unavailable source scan preserves canonical owner" parked.binding.request_id
    (Journal.continuation_request_id unconfirmed_owner);
  let settled = resume_parked_continuation env fixture empty_surface parked.child_continuation in
  check bool "permanent refusal keeps an accepted successor transport" true (Tool_result.is_success settled);
  check int "permanent refusal dispatches no producer work" before_calls (List.length (calls fixture));
  let refused_ok,refusal_data,refusal_entry = await_composition env fixture (Tool_result.data settled) in
  check bool "refused producer settles as a durable terminal failure" false refused_ok;
  check_json "terminal failure carries proven original producer absence"
    (`String "original_producer_absent") (refusal_data |> member "kind");
  (match refusal_entry.status with
   | Async.Done {ok=false;_} -> ()
   | _ -> fail "refusal successor is not a canonical terminal failure");
  check bool "refusal settles under a new physical request" true
    (refusal_entry.request_id <> parked.binding.request_id);
  (* The next sweep retires the refused run's markers instead of re-readying it. *)
  let discovery = Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "post-refusal discovery" in
  check int "refused producer markers retire after settlement" 2 discovery.retired;
  check int "refused producer is not a ready candidate again" 0
    (List.length (List.filter (fun candidate ->
        String.equal (Journal.continuation_request_id candidate) parked.binding.request_id)
        discovery.ready));
  check int "parent dependency becomes the only ready candidate" 1 (List.length discovery.ready);
  check string "ready candidate is the original parent"
    (Journal.continuation_request_id parked.parent_continuation)
    (Journal.continuation_request_id (List.hd discovery.ready));
  check int "retired markers leave no discovery failure" 0 (List.length discovery.failures);
  (* The parent resumes, receives the refused child's canonical failure, and ends. *)
  let resumed = resume_parked_continuation env fixture parked.surface parked.parent_continuation in
  check bool "parent intake accepts its ready continuation" true (Tool_result.is_success resumed);
  let parent_ok,completed,_completed_entry = await_composition env fixture (Tool_result.data resumed) in
  check bool "parent ends with the refused child outcome" false parent_ok;
  let completed_nodes = composition_nodes fixture completed in
  let failure = composition_node "await" completed_nodes |> member "result" in
  check_json "refused child keeps its canonical structured diagnostic"
    (Async.entry_to_json refusal_entry) (failure |> member "data" |> member "request");
  check bool "refused child supplies no successful downstream export" true
    (completed |> member "exports" |> member "child_result" |> member "available" = `Bool false)

let test_named_producer_switched_to_inline_settles_run_and_ends_parent () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Async = Masc.Keeper_msg_async in
  let module Wake = Masc.Keeper_composition_continuation_wake in
  control_job fixture parked.job_id (`Assoc ["state",`String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-before-producer-switch"
      ~turn:52 "keeper_job_status" (argument parked.job_id)));
  let skill_md = Filename.concat fixture.base_path ".agents/skills/named-result-child/SKILL.md" in
  let inline_md = String.concat {|execution = "inline"|}
      (Astring.String.cuts ~sep:{|execution = "async"|} (read skill_md)) in
  write skill_md inline_md;
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "refusal fixture workspace" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  let inline_surface = published_surface fixture in
  check bool "a new producer revision does not prove producer absence" false
    (Masc.Keeper_capability_surface.exact_skill_absence_proven inline_surface parked.reference);
  check bool "changed producer revision is proven from the published identity" true
    (Masc.Keeper_capability_surface.changed_skill_proven inline_surface parked.reference);
  let settled = resume_parked_continuation env fixture inline_surface parked.child_continuation in
  check bool "present-but-changed producer accepts a refusal successor" true (Tool_result.is_success settled);
  let refused_ok,refusal_data,refusal_entry = await_composition env fixture (Tool_result.data settled) in
  check bool "switched-to-inline producer settles as a durable terminal failure" false refused_ok;
  check_json "terminal failure carries proven original producer change"
    (`String "original_producer_changed") (refusal_data |> member "kind");
  check bool "refusal settles under a new physical request" true
    (refusal_entry.request_id <> parked.binding.request_id);
  let discovery = Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "post-change-refusal discovery" in
  check int "changed producer markers retire after settlement" 2 discovery.retired;
  check int "parent dependency becomes the only ready candidate" 1 (List.length discovery.ready);
  (* Also verify deleted Keeper metadata settles the parent via Wake.resume *)
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration {|[keeper]
activation_mode = "manual"
sandbox_profile = "docker"
sandbox_image = "base"
network_mode = "inherit"
instructions = "Refusal fixture"
|};
  ignore (Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}));
  let metadata_path = Masc.Keeper_types_profile.keeper_meta_path parked.config keeper in
  if Sys.file_exists metadata_path then Unix.unlink metadata_path;
  let context : _ Masc.Keeper_types_profile.context =
    {config=parked.config;agent_name="continuation-refusal-fixture";
     sw=Async.server_background_switch () |> require "continuation refusal switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let meta_refused = Wake.resume ~context parked.parent_continuation |> require "deleted metadata settles parent" in
  check bool "deleted keeper metadata accepts a refusal successor" true (Tool_result.is_success meta_refused);
  let parent_ok,parent_data,_ = await_composition env fixture (Tool_result.data meta_refused) in
  check bool "parent ends as terminal failure when keeper metadata is missing" false parent_ok;
  check_json "parent refusal records owner_metadata_missing"
    (`String "owner_metadata_missing") (parent_data |> member "kind");
  let after_parent = Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "post-metadata-refusal discovery" in
  check int "all ready candidates are retired after metadata refusal" 0 (List.length after_parent.ready)

let test_temporary_keeper_refusal_keeps_named_run_open () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Async = Masc.Keeper_msg_async in
  let foreign_meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name",`String "foreign-keeper";"activation_mode",`String "manual"])
    |> require "foreign keeper metadata" in
  let before_calls = List.length (calls fixture) in
  let refused = resume_parked_continuation env fixture ~meta:foreign_meta parked.surface parked.child_continuation in
  check bool "foreign keeper refusal stays an intake rejection" true (Tool_result.is_failed refused);
  check_json "foreign keeper refusal carries the typed source-conflict cause"
    (`Assoc ["kind",`String "source_conflict"]) (Tool_result.data refused);
  check int "temporary refusal has no producer work" before_calls (List.length (calls fixture));
  (* The refused run is not closed: its owner, continuation and marker survive. *)
  let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:parked.binding.composition_run_id |> require "named producer journal" in
  let continuation = Journal.waiting_continuation child_journal |> require "named producer wait survives"
    |> function Some value -> value | None -> fail "temporary refusal closed the named producer" in
  check string "temporary refusal keeps the exact original owner" parked.binding.request_id
    (Journal.continuation_request_id continuation);
  let discovery = Journal.pending_continuations
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "post-refusal discovery" in
  check int "temporary refusal retires no marker" 0 discovery.retired;
  check int "temporary refusal adds no discovery failure" 0 (List.length discovery.failures);
  check int "both parked runs stay waiting" 2 discovery.waiting;
  (* The right Keeper can still resume the run to its canonical result. *)
  control_job fixture parked.job_id (`Assoc ["state",`String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-producer-job"
      ~turn:52 "keeper_job_status" (argument parked.job_id)));
  check bool "collected job readies the original producer wait" true
    (Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
       continuation = Ok Journal.Results_ready);
  let resumed = resume_parked_continuation env fixture parked.surface continuation in
  check bool "retry intake accepts the still-open run" true (Tool_result.is_success resumed);
  let retry_ok,_retry_data,retry_entry = await_composition env fixture (Tool_result.data resumed) in
  check bool "retry completes the named producer canonically" true retry_ok;
  check bool "retry settles under a new physical request" true
    (retry_entry.request_id <> parked.binding.request_id)

let test_operator_resolves_permanent_continuation_mismatch () = with_fixture @@ fun env _initialize fixture ->
  let module Async = Masc.Keeper_msg_async in
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  set_source fixture ~task_id:"original-resolution-task" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let blob = Tool_blob_store.create ~base_path:fixture.base_path in
  let sibling = Tool_blob_store.put_durable blob ~bytes:"retained sibling before explicit resolution\n" ~mime:"text/plain" in
  let literal value = `Assoc ["kind",`String "literal";"value",value] in
  let recipe = `Assoc ["execution",`String "async";
    "branch_failure_policy",`String "continue_independent";
    "nodes",`List [
      `Assoc ["id",`String "await";"tool",`String "keeper_job_result";"input",literal (argument id);"after",`List []];
      `Assoc ["id",`String "sibling";"tool",`String "keeper_artifact_read";
        "input",literal (`Assoc ["sha256",`String sibling.sha256]);"after",`List []]];
    "exports",`List [`Assoc ["name",`String "job";"node",`String "await";"pointer",`String "/job_id"]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
    ~tool_use_id:"prepare-permanent-resolution" ~turn:41 "keeper_composition_prepare" recipe) in
  let draft = prepared |> member "draft" |> composition_reference "permanent resolution draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
    ~tool_use_id:"run-permanent-resolution" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String draft.sha256])) in
  let _,_,entry = await_composition env fixture accepted in
  let run_id = accepted |> member "composition_run_id" |> to_string in
  let composition_run_id = Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "resolution run id" in
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper ~composition_run_id
    |> require "original journal before mismatch" in
  let continuation = match Journal.waiting_continuation journal with
    | Ok (Some continuation) -> continuation
    | Ok None | Error _ -> fail "original job did not suspend the Composition" in
  let captured = Journal.observe_request ~base_path:fixture.base_path ~composition_run_id entry
    |> require "original logical status before resolution" in
  let status tool_use_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id ~turn:41 "keeper_composition_status" (`Assoc ["request_id",`String entry.request_id])) in
  let before_status = status "status-before-permanent-resolution" in
  check_json "unresolved status keeps the physical wait" (`String "waiting_for_dependencies")
    (member "status" before_status);
  check_json "unresolved logical observation is explicit" `Null
    (before_status |> member "continuation" |> member "observation" |> member "resolution");
  let terminal_path = Async.For_testing.terminal_record_path ~base_path:fixture.base_path ~request_id:entry.request_id
    |> Option.get in
  let foreign = Store.Job_id.fresh () |> Store.Job_id.to_string in
  let malformed = read terminal_path |> Yojson.Safe.from_string |> to_assoc
    |> List.map (fun (key,value) -> key, if key = "dependencies" then
      `List [`Assoc ["kind",`String "owned_job";"job_id",`String foreign]] else value)
    |> fun fields -> `Assoc fields |> Yojson.Safe.to_string in
  write terminal_path malformed;
  let pending () = Journal.pending_continuations
    ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path:fixture.base_path
    |> require "permanent mismatch discovery" in
  let report = pending () in
  (match report.failures with [_,Journal.Invalid_result _] -> ()
   | _ -> fail "canonical dependency mismatch was not retained as Invalid_result");
  let module Command = Operator_composition_resolution_command in
  let command name fields = Command.parse_tool_command (`Assoc
    (["command",`String name;"keeper_name",`String keeper;"composition_run_id",`String run_id;
      "request_id",`String entry.request_id] @ fields)) |> require "operator resolution command" in
  let execute now command = Command.execute ~base_path:fixture.base_path ~actor:"operator-fixture" ~now command
    |> require "operator resolution outcome" |> Command.outcome_to_json in
  let observed = execute 100. (command "observe" []) in
  let version = observed |> member "expected_version" |> to_string in
  let decision = command "reject" ["expected_version",`String version;
    "reason",`String "permanently mismatched original dependency"] in
  let resolved = execute 101. decision in
  check_json "explicit rejection retires the exact pending marker" (`Bool true) (member "marker_retired" resolved);
  let after_status = status "status-after-permanent-resolution" in
  check_json "resolved status still retains physical waiting outcome" (`String "waiting_for_dependencies")
    (member "status" after_status);
  let logical = after_status |> member "continuation" |> member "observation" in
  check_json "status carries the explicit logical rejection" (`String "rejected")
    (logical |> member "resolution" |> member "decision");
  check_json "logical status keeps the original source Task" (`String "original-resolution-task")
    (member "source_task_id" logical);
  let canonical = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper entry.request_id
    |> require "resolved canonical physical status" |> Async.durable_terminal_entry in
  let current = Journal.observe_request ~base_path:fixture.base_path ~composition_run_id canonical
    |> require "resolved logical snapshot" in
  check bool "old logical snapshot is not current authority" false (Journal.same_request_observation captured current);
  check_json "captured observation was not mutated by resolution" `Null
    (Journal.request_observation_to_json captured |> member "resolution");
  let http_status = Server_async_request_observability.project_request
    ~base_path:fixture.base_path ~submitted_by:keeper ~request_id:entry.request_id in
  check_json "HTTP exact observation finds a terminal attempt outside active inventory" (`String "observed")
    (member "status" http_status);
  check_json "HTTP status exposes the original logical decision" (`String "rejected")
    (http_status |> member "request" |> member "continuation" |> member "observation" |> member "resolution" |> member "decision");
  let foreign_status = Server_async_request_observability.project_request
    ~base_path:fixture.base_path ~submitted_by:"foreign-status-owner" ~request_id:entry.request_id in
  check_json "wrong Keeper cannot inspect another owner's status" (`String "rejected") (member "status" foreign_status);
  check_json "wrong Keeper gets no physical request payload" `Null (member "request" foreign_status);
  check string "operator preserves the original physical mismatch for audit" malformed (read terminal_path);
  check (option string) "retained sibling remains available" (Some "retained sibling before explicit resolution\n")
    (Tool_blob_store.fetch blob ~sha256:sibling.sha256 |> require "retained sibling after resolution");
  check_json "resolution retry retains its original terminal decision" resolved (execute 200. decision);
  (match Journal.continuation_readiness
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness continuation with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "sealed continuation still admitted a dependency read");
  let settled = pending () in
  check bool "resolved mismatch has no pending work or failure" true
    (settled.ready = [] && settled.waiting = 0 && settled.failures = []);
  let refused = with_bundle fixture (fun bundle -> invoke_raw bundle
    ~tool_use_id:"resume-resolved-original" ~turn:42 "keeper_composition_run"
    (`Assoc ["sha256",`String draft.sha256;"resume_run_id",`String run_id])) in
  (match refused with Error _ -> () | Ok _ -> fail "public resume accepted a logically terminal original run");
  check string "refused resume preserves the original job record" id
    (Store.Job_id.to_string (load fixture id).job_id)

let test_public_composition_wait_and_resume () = with_fixture @@ fun env initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"])
    |> job_id in
  let direct_before = List.length (calls fixture) in
  with_bundle fixture (fun bundle ->
    ignore (invoke fixture bundle ~tool_use_id:"direct-result-pending" ~turn:41 "keeper_job_result" (argument id));
    check bool "direct result wait lets the Keeper continue other work" true
      (bundle.terminal_effect_state () = Masc.Keeper_tools_agent_core.Terminal_effect_open));
  check int "direct pending result has no backend operation" direct_before (List.length (calls fixture));
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:"independent retained result\n" ~mime:"text/plain" in
  let literal value = `Assoc ["kind", `String "literal"; "value", value] in
  let node name tool input after = `Assoc ["id", `String name; "tool", `String tool;
      "input", input; "after", `List (List.map (fun name -> `String name) after)] in
  let output = `Assoc ["kind", `String "output"; "node", `String "await";
      "pointer", `String "/artifacts/0/_blob/sha256"] in
  let recipe = `Assoc ["execution", `String "async";
      "branch_failure_policy", `String "continue_independent";
      "nodes", `List
        [node "await" "keeper_job_result" (literal (argument id)) [];
         node "await-also" "keeper_job_result" (literal (argument id)) [];
         node "sibling" "keeper_artifact_read" (literal (`Assoc ["sha256", `String sibling.sha256])) [];
         node "consumer" "keeper_artifact_read"
           (`Assoc ["kind", `String "object"; "fields", `List
             [`Assoc ["name", `String "sha256"; "value", output]]]) ["await"]];
      "exports", `List [`Assoc ["name", `String "job"; "node", `String "await"; "pointer", `String "/job_id"]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-wait" ~turn:41 "keeper_composition_prepare" recipe) in
  let draft_reference = prepared |> member "draft" |> composition_reference "prepared draft" in
  let sha256 = draft_reference.sha256 in
  let draft_bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256
    |> require "actual prepared draft bytes" |> function
    | Some bytes -> bytes | None -> fail "prepared draft artifact is missing" in
  let draft_manifest = Yojson.Safe.from_string draft_bytes in
  (match Tool_output.artifact_manifest_of_json draft_manifest with
   | Tool_output.Decoded_artifact_manifest _ -> ()
   | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
     fail "schema definitions poisoned the prepared artifact manifest");
  let contract_rows = draft_manifest |> member "structured_content" |> member "contracts"
    |> member "tools" |> to_list in
  let await_contract = contract_rows |> List.find (fun row ->
      row |> member "node_id" |> to_string = "await") in
  let frozen_contract = await_contract |> member "contract_json" |> to_string
    |> Yojson.Safe.from_string in
  check_json "literal contract keeps the declared normalized wrapper schema"
    (`String "object")
    (frozen_contract |> member "output_schema" |> member "properties"
     |> member "artifacts" |> member "items" |> member "properties"
     |> member "_blob" |> member "type");
  let calls_before = List.length (calls fixture) in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-wait" ~turn:41 "keeper_composition_run" (`Assoc ["sha256", `String sha256])) in
  let ok, first, first_entry = await_composition env fixture accepted in
  check bool "pending job suspends this worker attempt" false ok;
  (match first_entry.status with
   | Masc.Keeper_msg_async.Waiting_for_dependencies {dependencies;_} ->
     check (list string) "broker retains typed original job identities" [id]
       (List.map dependency_job_id dependencies)
   | _ -> fail "owned job wait was flattened into terminal composition failure");
  let module Async = Masc.Keeper_msg_async in
  let module Queue = Masc.Keeper_registry_event_queue in
  let run_id = accepted |> member "composition_run_id" |> to_string in
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.of_string run_id
        |> require "original run UUID") |> require "original run journal" in
  let continuation () = match Journal.waiting_continuation journal with
    | Ok (Some continuation) -> continuation
    | Ok None -> fail "original run is not canonically waiting"
    | Error error -> fail (Journal.error_to_string error) in
  let original_continuation = continuation () in
  let resume_candidate capability_surface continuation =
    let config = Workspace.default_config fixture.base_path in
    let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
      {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"physical-continuation-intake"
      ~turn:52 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
    Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface ~continuation
      ~config ~meta:fixture.meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"continuation fixture")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation ~clock:(Eio.Stdenv.clock env) () in
  let current_surface ?(tool_deny=[]) ?(tool_descriptors=Descriptor.all_descriptors ()) () =
    frozen_surface_with ~tool_deny ~tool_descriptors ~base_path:fixture.base_path
      ~sandbox_profile:fixture.meta.sandbox_profile in
  let not_ready = resume_candidate (current_surface ()) original_continuation in
  check bool "typed not-ready intake starts no worker" true (Tool_result.is_deferred not_ready);
  check string "not-ready intake keeps original owner" first_entry.request_id
    (Journal.continuation_request_id (continuation ()));
  check int "not-ready intake never queries the backend" calls_before (List.length (calls fixture));
  let pending () = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path:fixture.base_path
      |> require "pending continuation discovery" in
  let discovery = pending () in
  check int "saved wait remains discoverable" 1 discovery.waiting;
  check int "running job never dispatches from discovery" 0 (List.length discovery.ready);
  check int "saved wait has valid original authority" 0 (List.length discovery.failures);
  check (list string) "two waiting nodes capture one original job" [id]
    (List.map dependency_job_id (Journal.continuation_dependencies original_continuation));
  check string "continuation captures original worker" first_entry.request_id
    (Journal.continuation_request_id original_continuation);
  check (option string) "continuation captures original Task" (Some "task-A")
    (Journal.continuation_source original_continuation).source_task_id;
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness original_continuation with
   | Ok Journal.Waiting_for_results -> ()
   | Ok Results_ready | Error _ -> fail "running original job appeared ready");
  let terminal_path = match Async.For_testing.terminal_record_path
      ~base_path:fixture.base_path ~request_id:first_entry.request_id with
    | Some path -> path | None -> fail "original waiting request has no canonical path" in
  let original_wire = read terminal_path in
  let wire = Yojson.Safe.from_string original_wire in
  (match Async.For_testing.load_record ~base_path:fixture.base_path
      ~request_id:first_entry.request_id with
   | Found {status=Async.Waiting_for_dependencies {dependencies;_};_} ->
     check (list string) "strict record roundtrip keeps the original wait" [id]
       (List.map dependency_job_id dependencies)
   | Found _ | Absent | Unreadable _ | Rejected _ ->
     fail "durable waiting outcome cannot roundtrip");
  let invalid_wait ids = match wire with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        key, if key="dependencies" then `List (List.map (fun id -> `Assoc ["kind",`String "owned_job";"job_id",id]) ids) else value) fields)
    | _ -> fail "waiting record is not an object" in
  List.iter (fun ids ->
    Fun.protect ~finally:(fun () -> write terminal_path original_wire) (fun () ->
      write terminal_path (Yojson.Safe.to_string (invalid_wait ids));
      match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
          ~caller:keeper first_entry.request_id with
      | Error (Async.Canonical_terminal_unreadable _) -> ()
      | Error _ | Ok _ -> fail "strict wait decoder accepted missing/duplicate/invalid identity"))
    [[];[`String id;`String id];[`String "unknown-job"]];
  Fun.protect ~finally:(fun () -> write terminal_path original_wire) (fun () ->
    let foreign = Store.Job_id.fresh () |> Store.Job_id.to_string in
    write terminal_path (Yojson.Safe.to_string (invalid_wait [`String foreign]));
    match Journal.waiting_continuation journal with
    | Error (Journal.Invalid_result _) -> ()
    | Ok _ | Error _ -> fail "a different canonical job set authorized continuation");
  let first_job = Store.Job_id.of_string id |> require "original job identity" in
  (match Async.worker_waiting_for_dependencies ~dependencies:[owned_dependency first_job]
      (Tool_result.make_ok ~tool_name:"fixture" ~start_time:(Tool_timing.start ()) ()) with
   | Error _ -> () | Ok _ -> fail "a completed result claimed owned-job suspension");
  let reconcile = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "waiting attempt outbox recovery" in
  check int "waiting attempt emits no failed completion" 0 reconcile.delivered;
  let sources = Queue.pending_selections_result ~base_path:fixture.base_path keeper
    |> require "waiting attempt queue" in
  check int "waiting attempt has no false composition terminal notification" 0
    (List.length (List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with Composition_completed _ -> true | _ -> false) sources));
  check int "waiting for result performs no backend operation" calls_before (List.length (calls fixture));
  let first_nodes = composition_nodes fixture first in
  let awaiting = composition_node "await" first_nodes in
  check_json "producer owns the durable job wait" (`String "owned_job_result_wait") (awaiting |> member "deferred_kind");
  check_json "job read is proven before any command effect" (`String "proven_pre_effect")
    (awaiting |> member "failure_effect_disposition");
  check bool "consumer waits for complete original output" false
    (List.exists (fun row -> row |> member "node_id" |> to_string = "consumer") first_nodes);
  let resume () = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"resume-wait" ~turn:52 "keeper_composition_run"
      (`Assoc ["sha256", `String sha256; "resume_run_id", `String run_id])) in
  set_source fixture ~task_id:"task-B" ~turn:52;
  Process_eio.reset_for_testing (); initialize ();
  let owner_record = load fixture id in
  let owner_path = Filename.concat (Store.paths ~base_path:fixture.base_path owner_record.job_id).job_dir "owner.jsonl" in
  let owner_bytes = read owner_path in
  let before_refusal = List.length (calls fixture) in
  let refused_data = Fun.protect ~finally:(fun () -> write owner_path owner_bytes) (fun () ->
      write owner_path "{temporarily-invalid-owner\n";
      let unreadable = pending () in
      check int "corrupt job authority leaves no ready continuation" 0 (List.length unreadable.ready);
      check int "corrupt job authority is reported and retained" 1 (List.length unreadable.failures);
      (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness original_continuation with
       | Error (Journal.Invalid_result _) -> ()
       | Ok _ | Error _ -> fail "corrupt original job owner became a ready continuation");
      let refused = resume () in
      let ok, data, _ = await_composition env fixture refused in
      check bool "unreadable original owner refuses result rechecking" false ok;
      data) in
  check int "transient result refusal cannot call the backend" before_refusal (List.length (calls fixture));
  let refused_node = composition_nodes fixture refused_data |> composition_node "await" in
  List.iter (fun field -> check_json ("refusal preserves original occurrence " ^ field)
      (awaiting |> member field) (refused_node |> member field)) ["execution_id";"tool_use_id"];
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-unavailable" ~turn:52 "keeper_job_status" (argument id)));
  let before_resume = List.length (calls fixture) in
  let still_pending = resume () in
  let ok, second, _ = await_composition env fixture still_pending in
  check bool "exit without complete outputs remains waiting" false ok;
  check int "resuming a wait never collects or relaunches" before_resume (List.length (calls fixture));
  let second_nodes = composition_nodes fixture second in
  let ready_continuation = continuation () in
  List.iter (fun field -> check_json ("same waiting occurrence " ^ field)
      (awaiting |> member field) (composition_node "await" second_nodes |> member field)) ["execution_id";"tool_use_id"];
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-complete" ~turn:52 "keeper_job_status" (argument id)));
  let before_completed_resume = List.length (calls fixture) in
  let discovered = pending () in
  check int "completed result is discovered without another event" 1 (List.length discovered.ready);
  check int "completed result has readable original authority" 0 (List.length discovered.failures);
  let discovered = List.hd discovered.ready in
  check string "discovery keeps the same waiting owner"
    (Journal.continuation_request_id ready_continuation)
    (Journal.continuation_request_id discovered);
  check (option string) "discovery keeps original Task after current Task changed"
    (Some "task-A") (Journal.continuation_source discovered).source_task_id;
  Process_eio.reset_for_testing (); initialize ();
  let restarted_discovery = pending () in
  check int "same ready wait survives transport reinitialization" 1 (List.length restarted_discovery.ready);
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ready_continuation with
   | Ok Journal.Results_ready -> ()
   | Ok Waiting_for_results | Error _ -> fail "complete original outputs are not ready");
  let changed_surface = current_surface ~tool_deny:["keeper_job_start"] () in
  let module Draft = Masc.Keeper_composition_draft in
  let alias_base = Filename.concat fixture.base_path "." in
  let original_source = Journal.continuation_source discovered in
  let alias_prepared = Journal.prepare ~base_path:alias_base original_source
    |> require "same original journal through an alias base" in
  let alias_loaded = Journal.load ~base_path:(fixture.base_path ^ "/") ~keeper_name:keeper
      ~composition_run_id:original_source.composition_run_id
    |> require "same original journal through a trailing slash" in
  let capture journal = match Journal.waiting_continuation journal with
    | Ok (Some candidate) -> candidate
    | Ok None | Error _ -> fail "alias lost the original waiting continuation" in
  List.iter (fun journal ->
    let candidate = capture journal in
    check string "journal ingress stores canonical workspace authority" fixture.base_path
      (Journal.continuation_base_path candidate);
    ignore (Draft.load_continuation ~base_path:alias_base ~capability_surface:changed_surface candidate
      |> require "same physical workspace admits an alias continuation")) [alias_prepared;alias_loaded];
  let discovered = capture alias_loaded in
  (match Draft.load ~base_path:fixture.base_path ~capability_surface:changed_surface ~keeper_name:keeper ~sha256 with
   | Error Draft.Capability_changed -> ()
   | Ok _ | Error _ -> fail "ordinary draft admission silently adopted a changed whole surface");
  let preserved = Draft.load_continuation ~base_path:fixture.base_path
      ~capability_surface:changed_surface discovered |> require "sealed original continuation contracts" in
  check string "continuation retains original draft" sha256 (Draft.reference preserved).sha256;
  let other_base = Filename.concat fixture.base_path "other-workspace" in
  Unix.mkdir other_base 0o700;
  (match Draft.load_continuation ~base_path:other_base ~capability_surface:changed_surface discovered with
   | Error (Draft.Malformed_draft _) -> ()
   | Ok _ | Error _ -> fail "sealed continuation was loaded in a different workspace");
  (match Draft.load_continuation ~base_path:fixture.base_path
      ~capability_surface:(current_surface ~tool_deny:["keeper_job_result"] ()) discovered with
   | Error _ -> ()
   | Ok _ -> fail "ordinary continuation admission executed a currently denied Tool");
  check string "validation-only denial keeps original owner" (Journal.continuation_request_id discovered)
    (Journal.continuation_request_id (continuation ()));
  let lost_worker_calls = ref 0 in
  let lose_after_binding candidate =
    (* A closed target switch makes the real broker fail after durable Queued
       acceptance and Journal binding, before any worker can run. No canonical
       owner or terminal record is manufactured by the fixture. *)
    let stopped_switch = Eio.Switch.run (fun sw -> sw) in
    let lost = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
        ~background_sw:stopped_switch ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id ->
          Journal.bind_continuation candidate ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string)
        ~f:(fun ~request_id:_ _ ->
          incr lost_worker_calls;
          Async.worker_finished (Tool_result.make_ok ~tool_name:"unstarted-continuation"
            ~start_time:(Tool_timing.start ()) ())) () in
    let request_id = match lost with
      | Error (Async.Background_fork_failed {request_id;_} as error) ->
        check_json "fork refusal does not guess the canonical request status" `Null
          (Async.submit_error_to_json error |> member "status");
        request_id
      | Error _ | Ok _ -> fail "closed worker switch did not publish post-binding Lost" in
    let proof = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
        ~caller:keeper request_id |> require "canonical post-binding Lost" in
    let entry = Async.durable_terminal_entry proof in
    (match entry.status with Lost _ -> () | _ -> fail "unstarted bound worker did not remain Lost");
    check string "Lost successor remains the exact journal owner" request_id
      (Journal.continuation_request_id (continuation ()));
    check int "post-binding loss starts no worker" 0 !lost_worker_calls;
    check int "post-binding loss has no backend operation" before_completed_resume (List.length (calls fixture));
    let report = pending () in
    check int "post-binding Lost remains discoverable" 1 (List.length report.ready);
    check int "post-binding Lost keeps readable original authority" 0 (List.length report.failures);
    List.hd report.ready, entry in
  let after_first_loss, first_lost_entry = lose_after_binding discovered in
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness discovered with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "prior waiting candidate recaptured its Lost successor");
  let after_second_loss, second_lost_entry = lose_after_binding after_first_loss in
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness after_first_loss with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "first Lost candidate recaptured its second successor");
  let first_lost_path = Async.For_testing.terminal_record_path ~base_path:fixture.base_path
      ~request_id:first_lost_entry.request_id
    |> function Some path -> path | None -> fail "first Lost terminal path" in
  let first_lost_bytes = read first_lost_path in
  Fun.protect ~finally:(fun () -> write first_lost_path first_lost_bytes) (fun () ->
    let changed = match Yojson.Safe.from_string first_lost_bytes with
      | `Assoc fields -> `Assoc (("reason",`String "changed predecessor terminal evidence")
          :: List.remove_assoc "reason" fields)
      | _ -> fail "canonical Lost record is not an object" in
    write first_lost_path (Yojson.Safe.to_string changed);
    match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness after_second_loss with
    | Error Journal.Ownership_changed -> ()
    | Ok _ | Error _ -> fail "changed canonical predecessor authorized the sealed continuation");
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness after_second_loss with
   | Ok Journal.Results_ready -> ()
   | Ok Waiting_for_results | Error _ -> fail "restored original wait cannot recover repeated Lost successors");
  let retain_wait_without_dispatch candidate =
    (* Real broker admission binds a successor, then its worker returns the
       original wait before touching any node. This is the journal boundary
       used when activation authority becomes unavailable after acceptance. *)
    let accepted = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
        ~background_sw:(Async.server_background_switch () |> require "original wait successor switch")
        ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id -> Journal.bind_continuation candidate ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string)
        ~f:(fun ~request_id:_ _ ->
          Async.worker_waiting_for_dependencies ~dependencies:(Journal.continuation_dependencies candidate)
            (Tool_result.make_deferred ~tool_name:"original-child-activation-unavailable"
              ~start_time:(Tool_timing.start ()) ~data:(`Assoc ["dispatch_started",`Bool false]) ())
          |> require "original wait before node dispatch") ()
      |> require "actual no-dispatch successor admission" in
    let ok,_,entry = await_composition env fixture (`Assoc ["request_id",`String accepted.request_id]) in
    check bool "no-dispatch successor preserves waiting outcome" false ok;
    let preserved = continuation () in
    check string "canonical waiting successor owns its inherited wait" entry.request_id
      (Journal.continuation_request_id preserved);
    check (list string) "inherited wait retains exact original jobs" [id]
      (List.map dependency_job_id (Journal.continuation_dependencies preserved));
    check int "inherited wait never queries or relaunches backend" before_completed_resume (List.length (calls fixture));
    (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness candidate with
     | Error Journal.Ownership_changed -> ()
     | Ok _ | Error _ -> fail "inherited wait reused stale predecessor ownership");
    let report = pending () in
    check int "inherited wait remains discoverable after the worker settles" 1 (List.length report.ready);
    check int "inherited wait retains exact predecessor evidence" 0 (List.length report.failures);
    preserved in
  let recovery_candidate = retain_wait_without_dispatch after_second_loss |> retain_wait_without_dispatch in
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  let write_profile ?(path=declaration) ?declared_name deny =
    let name = match declared_name with None -> "" | Some name -> "name = \"" ^ name ^ "\"\n" in
    let tools = if deny then "\n[keeper.tools]\ndeny = [\"keeper_job_result\"]\n" else "" in
    write path ("[keeper]\n" ^ name ^ "activation_mode = \"manual\"\nsandbox_profile = \"docker\"\n"
      ^ "sandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original result continuation fixture\"\n" ^ tools) in
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "canonical fixture Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "fixture Skill publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="continuation-maintenance-fixture";
     sw=Async.server_background_switch () |> require "continuation maintenance switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let active_requests () = Async.list_for_keeper ~base_path:fixture.base_path ~caller:keeper
      ~keeper_name:keeper () |> require "active requests at maintenance profile admission"
      |> List.map (fun (entry : Async.entry) -> entry.request_id) |> List.sort String.compare in
  (* The real discovery returns a sealed original ready owner. Inject only
     the intake refusal to exercise the controller's held-owner scheduling;
     canonical requests, journal and backend remain untouched. *)
  let held_intakes = ref 0 in
  let held,notify_held = Eio.Promise.create () in
  let held_wake = Wake.create ~context ~on_result:(fun _ _ -> Eio.Promise.resolve notify_held ()) () in
  let held_owner = Journal.continuation_request_id recovery_candidate in
  let held_resume ~on_recovery_held ~profiles:_ ~context:_ candidate =
    incr held_intakes;
    on_recovery_held ~request_id:(Journal.continuation_request_id candidate)
      ~cause:(Wake.Explicit_recovery_required "original child authority requires repair");
    Ok (Tool_result.make_err ~tool_name:"keeper_composition_run" ~start_time:(Tool_timing.start ())
      ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
      "original child authority requires repair") in
  let before_hold = active_requests () in
  Wake.For_testing.pulse ~resume:held_resume ~sw:context.sw held_wake;
  Eio.Promise.await held;
  Wake.For_testing.pulse ~resume:held_resume ~sw:context.sw held_wake;
  Wake.For_testing.pulse ~resume:held_resume ~sw:context.sw held_wake;
  Eio.Fiber.yield ();
  check int "unchanged held owner never repeats automatic intake" 1 !held_intakes;
  check string "held intake never replaces the original request" held_owner
    (Journal.continuation_request_id (continuation ()));
  check (list string) "held intake starts no physical worker" before_hold (active_requests ());
  let profile_owner_refusals = ref 0 in
  let assert_profile_owner_refused label =
    let requests_before = active_requests () in
    let refused,notify_refused = Eio.Promise.create () in
    let wake = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify_refused outcome) () in
    Wake.pulse ~sw:context.sw wake;
    (match Eio.Promise.await refused with
     | Error (Wake.Profile_unavailable {kind=Invalid_name;_}) -> incr profile_owner_refusals
     | Error error -> failf "%s: unexpected profile failure: %s" label (Wake.error_to_string error)
     | Ok _ -> failf "%s: invalid declaration owner reached async intake" label);
    check string (label ^ " retains original owner") (Journal.continuation_request_id recovery_candidate)
      (Journal.continuation_request_id (continuation ()));
    check (list string) (label ^ " starts no async worker") requests_before (active_requests ());
    check int (label ^ " performs no backend operation") before_completed_resume (List.length (calls fixture));
    (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness recovery_candidate with
     | Ok Journal.Results_ready -> ()
     | Ok Waiting_for_results | Error _ -> failf "%s: original wait is no longer ready" label) in
  write_profile ~declared_name:"continuation-foreign" false;
  assert_profile_owner_refused "maintenance rejects filename/declaration owner mismatch";
  write_profile false;
  let duplicate_declaration = Config_dir_resolver.keeper_toml_path_for_base_path
      ~base_path:fixture.base_path "continuation-duplicate" in
  Fun.protect ~finally:(fun () -> Unix.unlink duplicate_declaration) (fun () ->
    write_profile ~path:duplicate_declaration ~declared_name:keeper false;
    assert_profile_owner_refused "maintenance rejects duplicate declaration owner claims");
  write_profile false;
  let accepted,notify_accepted = Eio.Promise.create () in
  let accepted_callbacks = ref 0 and other_intakes = ref [] in
  (* A fresh supervisor proves durable discovery does not depend on the
     previous intake's process-local reservation. This is not an OS restart. *)
  let wake = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_callbacks; Eio.Promise.resolve notify_accepted result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let recovery_started = Mtime_clock.counter () in
  Wake.pulse ~sw:context.sw wake;
  Wake.pulse ~sw:context.sw wake;
  let resumed = Eio.Promise.await accepted |> Tool_result.data in
  let ok, completed, completed_entry = await_composition env fixture resumed in
  let recovery_ms = Mtime.Span.to_float_ns (Mtime_clock.count recovery_started) /. 1_000_000. in
  if not ok then
    failf "original completed job resume failed: %s" (Yojson.Safe.to_string completed);
  check bool "original complete job continues the remaining DAG" true ok;
  check int "repeated maintenance pulses accept only one original worker" 1 !accepted_callbacks;
  let deferred_intakes,failed_intakes,unavailable_intakes = List.fold_left
      (fun (deferred,failed,unavailable) -> function
        | Ok (Tool_result.Deferred _) -> deferred+1,failed,unavailable
        | Ok (Tool_result.Failed _) -> deferred,failed+1,unavailable
        | Error _ -> deferred,failed,unavailable+1
        | Ok (Tool_result.Completed _) -> fail "accepted intake was recorded as a refusal")
      (0,0,0) !other_intakes in
  check string "run identity survives resumption" run_id (resumed |> member "composition_run_id" |> to_string);
  check int "completed result read has no backend operation" before_completed_resume (List.length (calls fixture));
  Printf.printf "OWNED_CONTINUATION_RECOVERY %s\n%!" (Yojson.Safe.to_string
    (`Assoc ["post_binding_losses",`Int (List.length [first_lost_entry;second_lost_entry]);
      "no_dispatch_wait_successors",`Int 2;
      "maintenance_pulse_to_continuation_completion_ms",`Float recovery_ms;
      "accepted_intakes",`Int !accepted_callbacks;
      "deferred_intakes",`Int deferred_intakes;
      "failed_intakes",`Int failed_intakes;
      "unavailable_intakes",`Int unavailable_intakes;
      "profile_owner_refusals",`Int !profile_owner_refusals;
      "backend_calls",`Int (List.length (calls fixture) - before_completed_resume);
      "unstarted_worker_calls",`Int !lost_worker_calls;
      "program_creates",`Int (effect_count fixture "create");
      "program_starts",`Int (effect_count fixture "start")]));
  check string "continuation does not rewrite original preparation evidence" draft_bytes
    (Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256
      |> require "original preparation evidence after continuation"
      |> function Some bytes -> bytes | None -> fail "original draft disappeared");
  let completed_nodes = composition_nodes fixture completed in
  let final_wait = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("original wait identity " ^ field)
      (awaiting |> member field) (final_wait |> member field)) ["execution_id";"tool_use_id"];
  List.iter (fun field -> check_json ("second wait keeps its own occurrence " ^ field)
      (composition_node "await-also" first_nodes |> member field)
      (composition_node "await-also" completed_nodes |> member field)) ["execution_id";"tool_use_id"];
  let original_sibling = composition_node "sibling" first_nodes
  and final_sibling = composition_node "sibling" completed_nodes in
  List.iter (fun field -> check_json ("completed sibling retains " ^ field)
      (original_sibling |> member field) (final_sibling |> member field)) ["execution_id";"tool_use_id";"result"];
  check_json "completed sibling never dispatches again" (`String "retained_completion")
    (final_sibling |> member "execution_origin");
  let consumer = composition_node "consumer" completed_nodes in
  check_json "consumer reads exact original stdout" (`String stdout_bytes)
    (consumer |> member "result" |> member "data" |> member "content");
  check_json "nonzero program exit remains explicit" (`Int 7)
    (final_wait |> member "result" |> member "data" |> member "exit_code");
  List.iter (fun entry ->
    let context = match entry.Masc.Keeper_msg_async.request_context with Some fields -> `Assoc fields | None -> fail "lost source context" in
    check_json "completion belongs to original Task" (`String "task-A") (context |> member "source_task_id"))
    [first_entry;completed_entry];
  (match Journal.waiting_continuation journal with
   | Ok None -> () | Ok (Some _) | Error _ -> fail "completed run remained a suspended candidate");
  (match Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ready_continuation with
   | Error Journal.Ownership_changed -> ()
   | Ok _ | Error _ -> fail "stale candidate remained ready after its winner completed");
  let stale_worker_calls = ref 0 and stale_admission_error = ref None in
  let background_sw = Async.server_background_switch () |> require "server switch" in
  let stale = Async.submit_worker_with_request_id ?request_context:first_entry.request_context
      ~background_sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Journal.bind_continuation ready_continuation ~request_id with
        | Error error -> stale_admission_error := Some error; Error (Journal.error_to_string error)
        | Ok _ -> Ok ())
      ~f:(fun ~request_id:_ _ ->
        incr stale_worker_calls;
        Async.worker_finished (Tool_result.make_ok ~tool_name:"stale-continuation"
          ~start_time:(Tool_timing.start ()) ())) () in
  (match stale,!stale_admission_error with
   | Error (Async.Acceptance_persistence_failed _),Some Journal.Ownership_changed -> ()
   | _ -> fail "stale continuation rebound after the competing worker completed");
  check int "a stale continuation never starts its worker" 0 !stale_worker_calls;
  let retired = pending () in
  check int "completed requests leave no ready continuation" 0 (List.length retired.ready);
  check int "completed request discovery has no unavailable authority" 0 (List.length retired.failures);
  let stable = pending () in
  check int "retirement leaves no pending marker work" 0 stable.inspected;
  check int "composition never recreates original program" 1 (effect_count fixture "create");
  check int "composition never restarts original program" 1 (effect_count fixture "start");
  (* A current explicit denial ends a second logical run through an ordinary
     failure successor and one durable notification, without rewriting its
     original Waiting attempt or retrying the refused run on later pulses. *)
  (* The retained first resource and its targeted exit fault remain intact. *)
  set_source fixture ~task_id:"task-C" ~turn:61;
  let second_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-second" ~turn:61 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program-second"]; "inputs", `List []])) |> job_id in
  (match (load fixture second_id).phase with
   | Store.Running _ -> ()
   | Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
   | Store.Exited _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch ->
     fail "second job did not pass its own durable start intent");
  check int "both original jobs were actually created" 2 (effect_count fixture "create");
  check int "both original jobs were actually started" 2 (effect_count fixture "start");
  let second_literal value = `Assoc ["kind", `String "literal"; "value", value] in
  let second_node name tool input after = `Assoc ["id", `String name; "tool", `String tool;
      "input", input; "after", `List (List.map (fun name -> `String name) after)] in
  let second_recipe = `Assoc ["execution", `String "async";
      "nodes", `List [second_node "await-second" "keeper_job_result"
        (second_literal (argument second_id)) []]] in
  let second_prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-wait-second" ~turn:61 "keeper_composition_prepare" second_recipe) in
  let second_draft = second_prepared |> member "draft" |> composition_reference "second prepared draft" in
  let second_accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-wait-second" ~turn:61 "keeper_composition_run"
      (`Assoc ["sha256", `String second_draft.sha256])) in
  let second_ok, _, second_entry = await_composition env fixture second_accepted in
  check bool "second run suspends on its original job wait" false second_ok;
  control_job fixture second_id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-second" ~turn:61 "keeper_job_status" (argument second_id)));
  let second_ready = pending () in
  check int "completed second job is discovered without another event" 1 (List.length second_ready.ready);
  check int "second ready wait has readable original authority" 0 (List.length second_ready.failures);
  (* An explicit current TOML denial ends the logical run through a standard
     CAS-bound failure successor, preserving the original Waiting record. *)
  write_profile true;
  let before_refusal_calls = List.length (calls fixture) in
  let second_candidate = List.hd second_ready.ready in
  let draft_path = Filename.concat (Filename.concat
      (Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:fixture.base_path))
      (String.sub second_draft.sha256 0 2)) second_draft.sha256 in
  let detached_draft = draft_path ^ ".fixture-detached" in
  let pre_admission_intakes = ref 0 and pre_admission_hold = ref None in
  let held_outcome,notify_held_outcome = Eio.Promise.create () in
  let unavailable_wake = Wake.create ~context ~on_result:(fun _ outcome ->
      incr pre_admission_intakes; Eio.Promise.resolve notify_held_outcome outcome) () in
  let before_unavailable = active_requests () in
  (* Discover the real canonical ready owner first, then detach only its
     original draft at intake. Discovery itself refuses a missing artifact, so
     removing it before pulse would never exercise this admission boundary. *)
  let resume_without_original ~on_recovery_held ~profiles:_ ~context candidate =
    Unix.rename draft_path detached_draft;
    Wake.resume ~on_recovery_held:(fun ~request_id ~cause ->
      pre_admission_hold := Some request_id; on_recovery_held ~request_id ~cause)
      ~context candidate in
  Fun.protect
      ~finally:(fun () -> if Sys.file_exists detached_draft then Unix.rename detached_draft draft_path)
      (fun () ->
        Wake.For_testing.pulse ~resume:resume_without_original ~sw:context.sw unavailable_wake;
        (match Eio.Promise.await held_outcome with
         | Ok result -> check bool "missing draft remains an unaccepted intake refusal" true (Tool_result.is_failed result)
         | Error error -> fail (Wake.error_to_string error));
        check (option string) "pre-admission refusal holds the sealed original owner"
          (Some second_entry.request_id) !pre_admission_hold;
        let unchanged = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
            ~caller:keeper second_entry.request_id |> require "missing original draft keeps canonical Waiting" in
        check_json "missing draft never overwrites original Waiting" (Async.entry_to_json second_entry)
          (Async.entry_to_json (Async.durable_terminal_entry unchanged)));
  (* Restoring readable evidence makes discovery ready again. The production
     controller must keep this same owner held until explicit resume, rather
     than accepting another worker on each ordinary maintenance pulse. *)
  Wake.pulse ~sw:context.sw unavailable_wake;
  Wake.pulse ~sw:context.sw unavailable_wake;
  Eio.Fiber.yield ();
  check int "repaired unchanged owner does not repeat automatic intake" 1 !pre_admission_intakes;
  check (list string) "pre-admission hold never starts a physical worker" before_unavailable (active_requests ());
  check int "pre-admission hold never calls the backend" before_refusal_calls (List.length (calls fixture));
  let denied_surface = frozen_surface_with ~tool_deny:["keeper_job_result"]
      ~tool_descriptors:(Descriptor.all_descriptors ()) ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let job_owner = Filename.concat (Store.paths ~base_path:fixture.base_path
      (Store.Job_id.of_string second_id |> require "refusal original job identity")).job_dir "owner.jsonl" in
  let original_job_owner = read job_owner in
  set_source fixture ~task_id:"task-D" ~turn:72;
  let fault_settled,notify_fault_settled = Eio.Promise.create () in
  let fault_request = ref None and fault_callbacks = ref 0 in
  let fault_entry = Fun.protect
      ~finally:(fun () -> if Sys.file_exists detached_draft then Unix.rename detached_draft draft_path)
      (fun () ->
        let invocation = Agent_core.Tool_contract.Invocation.create
            ~tool_use_id:"physical-refusal-authority-fault" ~turn:72
            ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
            ~completion:Agent_core.Tool_contract.Continue_after_success in
        let accepted = Masc.Keeper_tool_composition_surface.For_testing.resume_continuation
            ~after_refusal_binding:(fun ~request_id ->
              check bool "refusal authority fault injects once after actual CAS" true (Option.is_none !fault_request);
              let queued = Async.load_canonical_durable_queued ~base_path:fixture.base_path
                  ~caller:keeper request_id |> require "actual refusal Queued before authority fault"
                  |> Async.durable_queued_entry in
              let accepted_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
                  ~composition_run_id:(Journal.continuation_source second_candidate).composition_run_id
                |> require "actual refusal journal before authority fault" in
              Journal.validate_request accepted_journal queued |> require "refusal successor has actual journal membership";
              fault_request := Some request_id;
              Unix.rename draft_path detached_draft)
            ~after_refusal_settled:(fun () ->
              incr fault_callbacks; Eio.Promise.resolve notify_fault_settled ())
            ~capability_surface:denied_surface ~continuation:second_candidate ~config ~meta:fixture.meta
            ~publication_recovery:{provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper}
            ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"actual refusal authority fault")
            ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
            ~invocation ~clock:(Eio.Stdenv.clock env) () in
        check bool "authority fault follows actual accepted refusal transport" true (Tool_result.is_success accepted);
        let request_id = match !fault_request with Some request_id -> request_id
          | None -> fail "refusal hook ran without a real bound successor" in
        check_json "accepted transport identifies the actual faulted request" (`String request_id)
          (Tool_result.data accepted |> member "request_id");
        Eio.Promise.await fault_settled;
        check int "actual refusal production settlement callback finishes once" 1 !fault_callbacks;
        let rec lost () = match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
            ~caller:keeper request_id with
          | Ok proof -> let entry = Async.durable_terminal_entry proof in
            (match entry.status with Async.Lost _ -> entry
             | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
             | Waiting_for_dependencies _ | Done _ ->
               fail "post-CAS refusal authority failure became a logical terminal")
          | Error (Async.Canonical_terminal_runtime_active _) -> Eio.Fiber.yield (); lost ()
          | Error error -> fail (Async.canonical_terminal_error_to_string error) in
        let entry = lost () in
        (match Journal.completion_disposition ~base_path:fixture.base_path entry with
         | Error _ -> ()
         | Ok _ -> fail "unavailable frozen draft authorized a logical completion projection");
        let reconciliation = Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
            |> require "actual refusal outbox while original authority is unavailable" in
        check int "faulted refusal callback/outbox announces no logical failure" 0 reconciliation.delivered;
        check bool "unavailable authority remains an explicit outbox error" true (reconciliation.failures <> []);
        let completions = Queue.pending_selections_result ~base_path:fixture.base_path keeper
            |> require "actual refusal fault pending completion sources" in
        check bool "faulted refusal enqueues no completion source" false
          (List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
            match selection.source.payload with
            | Keeper_event_queue.Composition_completed completion -> String.equal completion.cc_request_id request_id
            | _ -> false) completions);
        let original = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
            ~caller:keeper second_entry.request_id |> require "original Waiting survives post-CAS authority failure"
            |> Async.durable_terminal_entry in
        check_json "post-CAS refusal fault never overwrites original Waiting"
          (Async.entry_to_json second_entry) (Async.entry_to_json original);
        check string "original child job remains byte-identical during refusal interruption"
          original_job_owner (read job_owner);
        check int "post-CAS refusal interruption has zero backend calls" before_refusal_calls (List.length (calls fixture));
        entry) in
  let restored_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Journal.continuation_source second_candidate).composition_run_id
    |> require "restore original refusal journal" in
  let restored = Journal.waiting_continuation restored_journal |> require "recover original refusal wait"
      |> function Some candidate -> candidate | None -> fail "restored authority cannot recover faulted refusal owner" in
  check string "restored continuation retains exact Lost successor owner" fault_entry.request_id
    (Journal.continuation_request_id restored);
  check (option string) "restored continuation keeps original Task despite current Task D" (Some "task-C")
    (Journal.continuation_source restored).source_task_id;
  check_json "interruption retains original dependency and result authority"
    (`List (List.map Dependency.to_json (Journal.continuation_dependencies second_candidate)))
    (`List (List.map Dependency.to_json (Journal.continuation_dependencies restored)));
  (match Journal.completion_disposition ~base_path:fixture.base_path fault_entry with
   | Ok Journal.Recovery_pending -> ()
   | Ok (Journal.Canonical_completion | Journal.Unadmitted_attempt) | Error _ ->
     fail "restored original authority promoted recoverable refusal Lost to logical failure");
  let retirements () =
    let identities = ref [] in
    let report = Journal.For_testing.pending_continuations
        ~before_retire:(fun path -> identities := (Yojson.Safe.from_string (read path)
          |> member "request_id" |> to_string) :: !identities)
        ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path:fixture.base_path
      |> require "identity-bound continuation marker discovery" in
    report,List.sort String.compare !identities in
  let restored_discovery,restored_retirements = retirements () in
  check int "restored discovery sees original and current Lost markers" 2 restored_discovery.inspected;
  check int "restored discovery retires only the original predecessor marker" 1 restored_discovery.retired;
  check (list string) "restored discovery retirement is bound to exact original request"
    [second_entry.request_id] restored_retirements;
  check int "restored discovery finds exactly one recoverable refusal owner" 1 (List.length restored_discovery.ready);
  check int "restored original authority has no discovery error" 0 (List.length restored_discovery.failures);
  let second_candidate = List.hd restored_discovery.ready in
  check string "public recovery intake uses the current Lost owner" fault_entry.request_id
    (Journal.continuation_request_id second_candidate);
  let refused,notify_refused = Eio.Promise.create () in
  let denied_wake = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify_refused outcome) () in
  Wake.pulse ~sw:context.sw denied_wake;
  let accepted_refusal = match Eio.Promise.await refused with
    | Ok result when Tool_result.is_success result -> Tool_result.data result
    | Ok _ -> fail "current Tool denial did not accept a failure successor"
    | Error error -> fail (Wake.error_to_string error) in
  let refused_ok,refusal_data,refusal_entry = await_composition env fixture accepted_refusal in
  let losing_worker_calls = ref 0 in
  (* The public maintenance intake completes the winner before a second broker
     admission uses the same stale candidate. A Keeper submission lock covers
     on_accepted, so that callback must not wait for another same-Keeper submit.
     The loser still durably records Queued/outbox before its real Journal CAS
     fails, preserving the exact physical failure and notification boundary. *)
  let losing = Async.submit_worker_with_request_id ?request_context:second_entry.request_context
      ~background_sw:(Async.server_background_switch () |> require "competing intake switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        Masc.Keeper_composition_completion_outbox.prepare ~base_path:fixture.base_path
          ~keeper_name:keeper ~request_id ~composition_tool:Masc.Keeper_tool_composition_catalog.run_tool_name
        |> Result.map_error Masc.Keeper_composition_completion_outbox.error_to_string
        |> fun prepared -> Result.bind prepared (fun () ->
          Journal.bind_continuation second_candidate ~request_id
          |> Result.map (fun _ -> ()) |> Result.map_error Journal.error_to_string))
      ~f:(fun ~request_id:_ _ ->
        incr losing_worker_calls;
        Async.worker_finished (Tool_result.make_ok ~tool_name:"unadmitted-intake"
          ~start_time:(Tool_timing.start ()) ())) () in
  let losing_request = match losing with
    | Error (Async.Acceptance_persistence_failed {request_id;_}) -> request_id
    | Error _ | Ok _ -> fail "competing stale intake was not rejected by the actual Journal CAS" in
  check int "CAS loser never starts a worker" 0 !losing_worker_calls;
  let loser_marker = Filename.concat
      (Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path)
         "keeper_msg_requests") "prepared_continuations")
      (Digestif.SHA256.(to_hex (digest_string losing_request)) ^ ".json") in
  check bool "rejected CAS never publishes a continuation marker" false (Sys.file_exists loser_marker);
  let losing_entry = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
      ~caller:keeper losing_request |> require "CAS loser canonical acceptance failure"
      |> Async.durable_terminal_entry in
  (match losing_entry.status with
   | Async.Persistence_failed {attempted_status=Async.Acceptance_callback;_} -> ()
   | _ -> fail "losing intake lost its physical acceptance failure evidence");
  (match Journal.completion_disposition ~base_path:fixture.base_path losing_entry with
   | Ok Journal.Unadmitted_attempt -> ()
   | Ok (Journal.Canonical_completion | Journal.Recovery_pending) | Error _ ->
     fail "exact-source CAS loser was promoted to logical completion");
  check bool "current Tool denial settles the successor as a terminal failure" false refused_ok;
  check bool "refusal successor has a distinct physical request" true
    (refusal_entry.request_id <> second_entry.request_id);
  check_json "failure carries exact current Tool denial" (`String "current_tool_denied")
    (refusal_data |> member "kind");
  check_json "failure preserves the refused original node" (`String "await-second")
    (refusal_data |> member "node_id");
  let old_wait = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper second_entry.request_id
    |> require "original Waiting remains immutable after failure successor" |> Async.durable_terminal_entry in
  check_json "failure successor never rewrites old Waiting" (Async.entry_to_json second_entry) (Async.entry_to_json old_wait);
  let stale = resume_parked_continuation env fixture denied_surface second_candidate in
  check bool "stale denied candidate cannot settle the newer owner" true (Tool_result.is_failed stale);
  let stable_failure = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper refusal_entry.request_id
    |> require "failure successor after stale intake" |> Async.durable_terminal_entry in
  check_json "stale candidate leaves winning owner unchanged" (Async.entry_to_json refusal_entry) (Async.entry_to_json stable_failure);
  check int "permanent refusal performs no backend operation" before_refusal_calls (List.length (calls fixture));
  let reconcile = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "permanent refusal completion outbox reconcile" in
  check int "refusal completion has no unavailable delivery authority" 0 (List.length reconcile.failures);
  check int "reconcile never announces the CAS loser's physical failure" 0 reconcile.delivered;
  let sources = Queue.pending_selections_result ~base_path:fixture.base_path keeper
    |> require "permanent refusal completion queue" in
  let failure_completions = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Composition_completed completion
        when String.equal completion.cc_request_id refusal_entry.request_id ->
        (match completion.cc_terminal with
         | Keeper_event_queue.Composition_failed _ -> true
         | Keeper_event_queue.Composition_succeeded
         | Keeper_event_queue.Composition_cancelled _ -> false)
      | _ -> false) sources in
  check int "exactly one failure completion reaches the original Keeper" 1 (List.length failure_completions);
  let losing_completions = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
    match selection.source.payload with
    | Keeper_event_queue.Composition_completed completion -> String.equal completion.cc_request_id losing_request
    | _ -> false) sources in
  check int "CAS loser has zero logical completion notifications" 0 (List.length losing_completions);
  check bool "restored refusal Lost never becomes a stale logical notification" false
    (List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Composition_completed completion -> String.equal completion.cc_request_id fault_entry.request_id
      | _ -> false) sources);
  check_json "final refusal successor retains original Task C" (`String "task-C")
    (Async.entry_to_json refusal_entry |> member "request_context" |> member "source_task_id");
  check_json "final refusal successor retains original run identity"
    (`String (Masc.Keeper_tool_plan.Composition_run_id.to_string (Journal.continuation_source restored).composition_run_id))
    (Async.entry_to_json refusal_entry |> member "request_context" |> member "composition_run_id");
  check string "original child job remains byte-identical after refusal recovery" original_job_owner (read job_owner);
  let again = Masc.Keeper_composition_completion_wake.reconcile
      ~base_path:fixture.base_path |> require "permanent refusal completion outbox re-reconcile" in
  check int "a settled refusal delivers exactly once" 0 again.delivered;
  (* Discovery retires the marker, so the next pulse has 0 ready candidates. *)
  let after_refusal,final_retirements = retirements () in
  check int "next discovery has no ready continuation" 0 (List.length after_refusal.ready);
  check int "final discovery inspects Lost and winner markers" 2 after_refusal.inspected;
  check int "Lost and winner markers both retire" 2 after_refusal.retired;
  check (list string) "final marker retirement preserves both admitted physical identities"
    (List.sort String.compare [fault_entry.request_id;refusal_entry.request_id]) final_retirements;
  check int "both discoveries retire all three admitted physical request markers" 3
    (restored_discovery.retired + after_refusal.retired);
  let quiet_wake = Wake.create ~context () in
  Wake.pulse ~sw:context.sw quiet_wake;
  check int "next pulse has 0 ready candidates" 0 (List.length (pending ()).ready);
  write_profile false;
  let restored_wake = Wake.create ~context () in
  Wake.pulse ~sw:context.sw restored_wake;
  check int "restored contract cannot resurrect a settled run" 0 (List.length (pending ()).ready);
  check (list string) "failure successor leaves no active async worker" [] (active_requests ())

let test_historical_output_contract_refuses_current_resume () = with_fixture @@ fun env _initialize fixture ->
  let module Draft = Masc.Keeper_composition_draft in
  let module Plan = Masc.Keeper_tool_plan in
  let module Executor = Masc.Keeper_tool_plan_executor in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
    [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
      "input",`Assoc ["kind",`String "literal";"value",argument id]]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-history"
      ~turn:41 "keeper_composition_prepare" recipe) in
  let current_reference = prepared |> member "draft" |> composition_reference "current canonical draft" in
  let surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let current_draft = Draft.load ~base_path:fixture.base_path ~capability_surface:surface
      ~keeper_name:keeper ~sha256:current_reference.sha256 |> require "canonical current draft plan" in
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let bytes = Tool_blob_store.fetch store ~sha256:current_reference.sha256
      |> require "canonical prepared manifest" |> function Some bytes -> bytes | None -> fail "draft missing" in
  let content,document = match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string bytes) with
    | Tool_output.Decoded_artifact_manifest {content;structured_content;_} -> content,structured_content
    | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> fail "invalid draft manifest" in
  let replace name value = function
    | `Assoc fields -> `Assoc ((name,value) :: List.remove_assoc name fields)
    | _ -> fail "historical fixture expected an object" in
  (* Authored historical evidence, not an old-binary execution claim. The
     current descriptor remains registry-owned. Only the previous frozen
     output definition differs, under a fresh durable artifact address. *)
  let rows = document |> member "contracts" |> member "tools" |> to_list in
  let rows = List.map (fun row ->
    let contract = row |> member "contract_json" |> to_string |> Yojson.Safe.from_string in
    let schema = contract |> member "output_schema" in
    let properties = schema |> member "properties" |> to_assoc in
    let schema = replace "properties"
        (`Assoc (("previous_optional_field",`Assoc ["type",`String "string"]) :: properties)) schema in
    let contract = replace "output_schema" schema contract in
    replace "contract_json" (`String (Yojson.Safe.to_string (Yojson.Safe.sort contract))) row) rows in
  let document = replace "contracts" (replace "tools" (`List rows) (document |> member "contracts")) document in
  let persist json = Tool_blob_store.put_durable store
      ~bytes:(Yojson.Safe.to_string (Tool_output.artifact_manifest_to_json ~content ~structured_content:json))
      ~mime:Tool_output.artifact_manifest_mime |> fun reference -> Tool_output.with_preview reference "" in
  let historical_reference = persist document in
  check bool "historical contract owns a different immutable artifact" true
    (historical_reference.sha256 <> current_reference.sha256);
  let composition_run_id = Plan.Composition_run_id.fresh () in
  let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"original-historical-run" ~turn:41
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let run_reference = persist (`Assoc
    ["draft",Tool_output.normalized_artifact_ref_to_json historical_reference;
     "nested_calls",document |> member "nested_calls";
     "nested_activation",`Null;
     "composition_run_id",`String (Plan.Composition_run_id.to_string composition_run_id);
     "tool_use_id",`String (Agent_core.Tool_contract.Invocation.tool_use_id invocation);
     "source_turn",`Int (Agent_core.Tool_contract.Invocation.turn invocation)]) in
  let source : Journal.source = {keeper_name=keeper;composition_run_id;
    draft_reference=historical_reference;run_reference;parent_tool_use_id="original-historical-run";
    source_turn=41;source_task_id=Some "task-A";producer=Journal.Prepared} in
  let journal = Journal.prepare ~base_path:fixture.base_path source |> require "historical source journal" in
  let admitted = ref None in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let request_context =
    ["composition_tool",`String Masc.Keeper_composition_draft.run_tool_name;
     "composition_run_id",`String (Plan.Composition_run_id.to_string source.composition_run_id);
     "draft_reference",Tool_output.normalized_artifact_ref_to_json source.draft_reference;
     "run_artifact",Tool_output.normalized_artifact_ref_to_json source.run_reference;
     "parent_tool_use_id",`String source.parent_tool_use_id;
     "source_turn",`Int source.source_turn;
     "source_task_id",`String "task-A"] in
  let accepted = Async.submit_worker_with_request_id ~request_context
      ~background_sw:(Async.server_background_switch () |> require "historical worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id -> match Journal.bind_request journal ~request_id with
        | Ok worker -> admitted := Some worker; Ok ()
        | Error error -> Error (Journal.error_to_string error))
      ~f:(fun ~request_id:_ request_sw ->
        let worker = match !admitted with Some worker -> worker | None -> fail "historical worker unbound" in
        let actual = Eio_context.with_turn_switch request_sw (fun () ->
          Executor.execute_keeper ~capability_surface:surface ~plan:(Draft.plan current_draft)
            ~run_id:(Plan.Run_id.fresh ()) ~composition_run_id ~parent_invocation:invocation
            ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
            ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"historical contract fixture")
            ~keeper_turn_id:(fun () -> Some 41)
            ~source_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
            ~clock:(Eio.Stdenv.clock env) ~journal:worker ()) in
        let node = match actual with
          | Error {cause=Executor.Tool_did_not_complete node;_} -> node
          | Ok _ | Error _ -> fail "actual original producer did not wait" in
        let job_id = match node.deferred_kind with
          | Some (Masc.Keeper_tool_execution.Owned_job_result_wait job_id) -> job_id
          | Some _ | None -> fail "actual original producer did not bind its job wait" in
        check string "historical wait uses the original actual job" id (Store.Job_id.to_string job_id);
        Async.worker_waiting_for_dependencies ~dependencies:[owned_dependency job_id] node.result |> require "historical worker wait") ()
      |> require "historical original worker acceptance" in
  ignore (await_composition env fixture (`Assoc ["request_id",`String accepted.request_id]));
  let capture () = match Journal.waiting_continuation journal with
    | Ok (Some candidate) -> candidate
    | Ok None | Error _ -> fail "historical original wait unavailable" in
  let continuation = capture () in
  let before = List.length (calls fixture) in
  let refused = Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface:surface
      ~continuation ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"current canonical intake")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation ~clock:(Eio.Stdenv.clock env) () in
  check bool "changed original output contract refuses before async acceptance" true (Tool_result.is_failed refused);
  check_json "schema drift retains typed contract rejection" (`String "capability_changed")
    (Tool_result.data refused |> member "kind");
  check string "schema drift never recaptures original owner" accepted.request_id
    (Journal.continuation_request_id (capture ()));
  check string "schema drift preserves the historical draft identity" historical_reference.sha256
    (Journal.continuation_source (capture ())).draft_reference.sha256;
  check int "contract refusal has no backend operation" before (List.length (calls fixture));
  check int "contract refusal never relaunches original program" 1 (effect_count fixture "start")

let test_cancelled_continuation_cannot_restart () =
  List.iter (fun mode -> with_fixture @@ fun env _initialize fixture ->
    let module Async = Masc.Keeper_msg_async in
    set_source fixture ~task_id:"task-A" ~turn:41;
    Call_log.init ~base_path:fixture.base_path ();
    let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
    let recipe = `Assoc ["execution",`String "async";
      "nodes",`List [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
        "input",`Assoc ["kind",`String "literal";"value",argument id];"after",`List []]];
      "exports",`List [`Assoc ["name",`String "job";"node",`String "await";"pointer",`String "/job_id"]]] in
    let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"prepare-cancel"
        ~turn:41 "keeper_composition_prepare" recipe) in
    let sha256 = (prepared |> member "draft" |> composition_reference "cancellable draft").sha256 in
    let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"run-cancel"
        ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String sha256])) in
    let _, _, waiting_entry = await_composition env fixture accepted in
    let run_id = accepted |> member "composition_run_id" |> to_string
      |> Masc.Keeper_tool_plan.Composition_run_id.of_string |> require "cancelled original run UUID" in
    let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper ~composition_run_id:run_id
      |> require "cancelled original journal" in
    let candidate = match Journal.waiting_continuation journal with
      | Ok (Some candidate) -> candidate
      | Ok None | Error _ -> fail "cancellation fixture has no original job wait" in
    let backend_before = List.length (calls fixture) in
    let worker_calls = ref 0 and intent = ref None in
    let admitted_worker = ref None in
    let entered, notify_entered = Eio.Promise.create () in
    let release, allow_return = Eio.Promise.create () in
    let settled, notify_settled = Eio.Promise.create () in
    let background_sw = match mode with
      | `Fork | `Startup -> Eio.Switch.run (fun sw -> sw)
      | `Signal_failure -> Async.server_background_switch () |> require "live cancelled worker switch" in
    let save_intent request_id =
      match Async.poll ~base_path:fixture.base_path ~caller:keeper request_id with
      | Found {status=Cancelling {reason;cancelled_by};_} -> intent := Some (reason,cancelled_by)
      | Found _ | Absent | Unreadable _ | Rejected _ -> fail "committed cancel intent is unavailable" in
    let submission = Async.submit_worker_with_request_id ?request_context:waiting_entry.request_context
        ~background_sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
        ~on_accepted:(fun request_id ->
          match Journal.bind_continuation candidate ~request_id with
          | Error error -> Error (Journal.error_to_string error)
          | Ok worker ->
            admitted_worker := Some worker;
            (match mode with
             | `Signal_failure -> ()
             | `Fork | `Startup ->
               (match Async.cancel ~base_path:fixture.base_path ~caller:keeper request_id with
                | Cancellation_requested Durably_committed -> ()
                | _ -> fail "pre-fork cancellation did not commit its exact intent");
               save_intent request_id);
            (* Explicit fixture process-memory reset leaves the actual durable
               Cancelling record for the exclusive startup recovery path. *)
            (match mode with
             | `Startup -> Async.For_testing.forget ~base_path:fixture.base_path ~caller:keeper ~request_id
             | `Fork | `Signal_failure -> ());
            Ok ())
        ~on_worker_settled:(fun _ -> Eio.Promise.resolve notify_settled ())
        ~f:(fun ~request_id:_ request_sw ->
          incr worker_calls;
          let worker = match !admitted_worker with Some worker -> worker
            | None -> fail "cancelled worker has no actual journal binding" in
          let surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
          let draft = Masc.Keeper_composition_draft.load_continuation ~base_path:fixture.base_path
              ~capability_surface:surface candidate |> require "cancelled worker's original draft" in
          let source = Journal.continuation_source candidate in
          let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:source.parent_tool_use_id
              ~turn:source.source_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
              ~completion:Agent_core.Tool_contract.Continue_after_success in
          let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
            {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
          let module Executor = Masc.Keeper_tool_plan_executor in
          let actual = Eio_context.with_turn_switch request_sw (fun () ->
            Executor.execute_keeper ~capability_surface:surface ~plan:(Masc.Keeper_composition_draft.plan draft)
              ~run_id:(Masc.Keeper_tool_plan.Run_id.fresh ()) ~composition_run_id:run_id ~parent_invocation:invocation
              ~config:(Workspace.default_config fixture.base_path) ~meta:fixture.meta ~publication_recovery
              ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"cancelled continuation fixture")
              ~keeper_turn_id:(fun () -> Some 41)
              ~source_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
              ~clock:(Eio.Stdenv.clock env) ~journal:worker ()) in
          let node = match actual with
            | Error {cause=Executor.Tool_did_not_complete node;_} -> node
            | Ok _ | Error _ -> fail "actual original job result did not produce a durable wait" in
          let job_id = match node.deferred_kind with
            | Some (Masc.Keeper_tool_execution.Owned_job_result_wait job_id) -> job_id
            | Some _ | None -> fail "actual producer did not own the deferred job identity" in
          Eio.Promise.resolve notify_entered ();
          Eio.Promise.await release;
          Async.worker_waiting_for_dependencies ~dependencies:[owned_dependency job_id] node.result
            |> require "actual cancelled worker wait") () in
    let request_id = match mode,submission with
      | (`Fork | `Startup), Error (Background_fork_failed {request_id;_} as error) ->
        let wire = Async.submit_error_to_json error in
        check_json "cancelled fork response keeps the exact request identity" (`String request_id)
          (wire |> member "request_id");
        check_json "fork failure transport cannot misreport cancellation as Lost" `Null
          (wire |> member "status");
        request_id
      | `Signal_failure, Ok outcome ->
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () -> Eio.Promise.await entered);
        let request_id = outcome.request_id in
        let ops = Async.For_testing.make_request_ops
            ~signal_cancel:(fun _ _ -> failwith "fixture worker cancellation signal failed") () in
        (match Async.For_testing.cancel ops ~base_path:fixture.base_path ~caller:keeper request_id with
         | Cancel_worker_signal_failed {durability=Durably_committed;_} -> ()
         | _ -> fail "failed cancellation signal did not retain durable operator intent");
        save_intent request_id;
        Eio.Promise.resolve allow_return ();
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () -> Eio.Promise.await settled);
        request_id
      | (`Fork | `Startup | `Signal_failure), (Error _ | Ok _) ->
        fail "cancellation scenario did not exercise its worker settlement boundary" in
    (match mode with
    | `Startup ->
      (match Async.poll ~base_path:fixture.base_path ~caller:keeper request_id with
       | Found {status=Cancelling _;_} -> ()
       | Found _ | Absent | Unreadable _ | Rejected _ -> fail "ordinary polling stole disk-only cancellation");
      let recovered = Async.recover_lost_disk_records ~base_path:fixture.base_path () in
      check int "startup does not turn operator cancellation into Lost" 0 recovered.lost;
      check int "startup finalizes the exact cancellation" 1 recovered.finalized;
      check int "startup cancellation settlement has no persistence failure" 0 recovered.failed
    | `Fork | `Signal_failure -> ());
    let terminal = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper request_id
      |> require "cancelled continuation canonical terminal" |> Async.durable_terminal_entry in
    (match terminal.status with
     | Cancelled {reason;cancelled_by} ->
       check (option (pair string string)) "terminal preserves exact cancellation reason and actor"
         !intent (Some (reason,cancelled_by))
     | _ -> fail "operator cancellation became a resumable Lost request");
    (match Journal.waiting_continuation journal with
     | Ok None -> () | Ok (Some _) | Error _ -> fail "cancelled original run regained continuation authority");
    let discovery = Journal.pending_continuations ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness ~base_path:fixture.base_path |> require "cancelled pending discovery" in
    check int "cancelled owner dispatches no ready continuation" 0 (List.length discovery.ready);
    check int "cancelled owner retirement retains no unreadable evidence" 0 (List.length discovery.failures);
    check int "cancelled continuation admits only its original live worker"
      (match mode with `Signal_failure -> 1 | `Fork | `Startup -> 0) !worker_calls;
    check int "cancelled continuation has no backend effect" backend_before (List.length (calls fixture));
    check int "cancellation never relaunches the program" 1 (effect_count fixture "start"))
    [`Fork;`Startup;`Signal_failure]

let test_job_result_rejects_unavailable_authority () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let record = load fixture id in
  let owner = Filename.concat (Store.paths ~base_path:fixture.base_path record.job_id).job_dir "owner.jsonl" in
  write owner "{invalid-owner\n";
  let before = List.length (calls fixture) in
  with_bundle fixture (fun bundle ->
    match invoke_raw bundle ~tool_use_id:"result-corrupt" ~turn:41 "keeper_job_result" (argument id) with
    | Error _ -> () | Ok _ -> fail "unavailable authority was treated as a pending or complete result");
  check int "result authority failure performs no backend call" before (List.length (calls fixture))

module Completion_wake = Masc.Keeper_owned_job_completion_wake
module Event_registry = Masc.Keeper_registry_event_queue
module Intake = Masc.Keeper_heartbeat_stimulus_intake

let pending_completions fixture =
  Event_registry.pending_selections_result ~base_path:fixture.base_path keeper
  |> require "durable pending selections"
let recover_completions fixture =
  Completion_wake.reconcile ~config:(Workspace.default_config fixture.base_path)
  |> store_value "actual maintenance completion recovery"
let completion_payload (selection : Keeper_event_queue_state.pending_selection) =
  match selection.source.payload with
  | Keeper_event_queue.Owned_job_completed completion -> completion
  | _ -> fail "pending source is not the original job completion"
let only_selection fixture = match pending_completions fixture with
  | [selection] -> selection | _ -> fail "expected one durable original completion"
let owner_path fixture id =
  let paths = Store.paths ~base_path:fixture.base_path (load fixture id).job_id in
  Filename.concat paths.job_dir "owner.jsonl"
let check_no_completion fixture =
  check int "no terminal result is delivered prematurely" 0 (List.length (pending_completions fixture))
let check_artifact_bytes fixture expected json =
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference ->
    (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:fixture.base_path) ~sha256:reference.sha256 with
     | Ok (Some bytes) -> check string "complete original output remains retrievable" expected bytes
     | Ok None | Error _ -> fail "completed original output artifact is missing")
  | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ ->
    fail "completion output is not a canonical artifact reference"

let test_completion_delivery_failure_and_restart () =
  let channel = Keeper_continuation_channel.dashboard ~thread_id:"original-task-thread"
    |> require "original submission channel" in
  with_fixture ~continuation_channel:channel @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let original = load fixture id in
  check_json "owner captures the originating channel"
    (Keeper_continuation_channel.to_yojson channel)
    (Keeper_continuation_channel.to_yojson original.completion_channel);
  let running = recover_completions fixture in
  check int "running job remains pending" 1 running.waiting;
  check_no_completion fixture;
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  let unavailable = recover_completions fixture in
  check int "exit without complete output keeps its obligation" 1 unavailable.waiting;
  check bool "exit alone is not a result" false (Store.result_ready (load fixture id));
  check_no_completion fixture;
  (* A real durable snapshot failure happens after the backend has delivered
     complete output. No producer callback or fabricated owner is substituted. *)
  let queue_path = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path:fixture.base_path) keeper)
      Keeper_event_queue_schema.snapshot_filename in
  Fs_compat.mkdir_p (Filename.dirname queue_path);
  let prior = if Sys.file_exists queue_path then Some (read queue_path) else None in
  (match prior with Some _ -> Unix.unlink queue_path | None -> ());
  Unix.mkdir queue_path 0o700;
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  let failed = recover_completions fixture in
  check int "failed enqueue is visible" 1 (List.length failed.failures);
  check bool "complete result committed before enqueue" true (Store.result_ready (load fixture id));
  check bool "failed delivery is not acknowledged" false (load fixture id).completion_delivered;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "pending discovery" in
  check int "failed delivery stays discoverable" 1 (List.length discovery.entries);
  Unix.rmdir queue_path;
  (match prior with Some bytes -> write queue_path bytes | None -> ());
  Process_eio.reset_for_testing (); initialize ();
  set_source fixture ~task_id:"task-B" ~turn:52;
  let before = List.length (calls fixture) in
  let begin_recovery = Unix.gettimeofday () in
  let delivered = recover_completions fixture in
  let recovery_ms = (Unix.gettimeofday () -. begin_recovery) *. 1000. in
  check int "restart delivers the original complete result" 1 delivered.delivered;
  check int "durable result recovery needs no backend call" before (List.length (calls fixture));
  check bool "canonical owner acknowledges durable delivery" true (load fixture id).completion_delivered;
  let selection = only_selection fixture in
  let completion = completion_payload selection in
  check string "completion names original job" id (Store.Job_id.to_string completion.oj_job_id);
  check_json "completion retains original source" (Store.source_to_json original.source)
    (Keeper_owned_job_identity.source_to_json completion.oj_source);
  check_json "queue continuation routes to original conversation" (Keeper_continuation_channel.to_yojson channel)
    (Keeper_continuation_channel.to_yojson completion.oj_channel);
  check bool "the wake carries original routing" true
    (Keeper_event_queue.continuation_channel_of_payload selection.source.payload = Some channel);
  check bool "actual single-source turn defaults route to the original conversation" true
    (Masc.Keeper_unified_turn.continuation_channel_of_wake
       (Masc.Keeper_registry.Woken [selection.source.payload]) = Some channel);
  let decoded = Keeper_event_queue.stimulus_of_yojson (Keeper_event_queue.stimulus_to_yojson selection.source)
    |> require "strict durable completion round trip" in
  check bool "typed completion survives the queue wire" true
    (Keeper_event_queue.stimulus_identity_equal selection.source decoded);
  let inspect () = Intake.pending_board_events_of_stimulus_result
      ~base_path:fixture.base_path ~meta_after_triage:fixture.meta selection.source in
  let event = match inspect () with
    | Intake.Stimulus_consumed [event] -> event
    | _ -> fail "complete original result was not admitted to the next prompt" in
  (match event.Masc.Keeper_world_observation.event_kind with
   | Owned_job_completed carried ->
     check_json "model observation has the typed original source" (Store.source_to_json original.source)
       (Keeper_owned_job_identity.source_to_json carried.oj_source)
   | _ -> fail "model observation lost typed completion identity");
  let preview = Yojson.Safe.from_string event.preview in
  check bool "admitted result is available" true (preview |> member "result_available" |> to_bool);
  check int "nonzero exit remains exact observed result" 7 (preview |> member "result" |> member "exit_code" |> to_int);
  let outputs = preview |> member "result" |> member "artifacts" |> to_list in
  (match outputs with [stdout;stderr] ->
     check_artifact_bytes fixture stdout_bytes stdout;
     check_artifact_bytes fixture stderr_bytes stderr
   | _ -> fail "complete result did not retain both original output references");
  let path = owner_path fixture id in
  let owner_bytes = read path in
  write path "not a canonical owner journal\n";
  (match inspect () with
   | Intake.Stimulus_job_unavailable (job_id,_) ->
     check string "unavailable intake retains original identity" id (Store.Job_id.to_string job_id)
   | _ -> fail "unavailable owner was consumed as an empty Board row");
  check int "unreadable result remains durably pending" 1 (List.length (pending_completions fixture));
  write path owner_bytes;
  (match inspect () with Intake.Stimulus_consumed [_] -> () | _ -> fail "restored original owner cannot resume intake");
  let forged = {completion with oj_source={completion.oj_source with task_id=Some "task-B"}} in
  let forged_source = {selection.source with payload=Owned_job_completed forged} in
  (match Intake.pending_board_events_of_stimulus_result ~base_path:fixture.base_path
     ~meta_after_triage:fixture.meta forged_source with
   | Intake.Stimulus_job_unavailable _ -> () | _ -> fail "a different Task authorized the original result");
  Event_registry.ack_pending_result ~base_path:fixture.base_path keeper ~selection
    |> require "actual completion queue consumption";
  let before_cleanup = List.length (calls fixture) in
  let again = recover_completions fixture in
  let cleanup_backend_calls = List.length (calls fixture) - before_cleanup in
  check int "acknowledged job remains discoverable for its later cleanup round" 1 again.inspected;
  check int "later cleanup confirms resources and retires the same owner" 1 again.retired;
  check int "later cleanup has no unavailable authority" 0 (List.length again.failures);
  let cleaned = load fixture id in
  check bool "resource cleanup is canonically complete" true (cleaned.cleanup = Store.Resources_removed);
  check bool "complete original result remains readable after cleanup" true (Store.result_ready cleaned);
  check_json "cleanup preserves the original result source" (Store.source_to_json original.source)
    (Store.source_to_json cleaned.source);
  let settled = recover_completions fixture in
  check int "confirmed cleanup leaves no pending marker work" 0 settled.inspected;
  check_no_completion fixture;
  check int "original command is created once" 1 (effect_count fixture "create");
  check int "original command is started once" 1 (effect_count fixture "start");
  Printf.printf "owned_job_completion_measurement=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope", `String "synthetic CLI public job, completed-output enqueue failure and restart recovery";
      "durable_result_recovery_ms", `Float recovery_ms; "backend_calls_on_delivery_recovery", `Int 0;
      "backend_calls_on_resource_cleanup", `Int cleanup_backend_calls;
      "creates", `Int 1; "starts", `Int 1; "completion_notifications", `Int 1]))

let test_completion_consumed_before_producer_ack () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-original" ~turn:42
      "keeper_job_status" (argument id)));
  let record = load fixture id in
  check bool "complete result is durable at interruption boundary" true (Store.result_ready record);
  check bool "producer has not acknowledged delivery" false record.completion_delivered;
  (* Seed the actual durable enqueue at the interruption boundary. Consumption
     can finish before the producer CAS; recovery must consult queue evidence. *)
  let completion : Keeper_event_queue.owned_job_completion =
    {oj_job_id=record.job_id;oj_source=record.source;oj_channel=record.completion_channel} in
  let stimulus : Keeper_event_queue.stimulus =
    {post_id=Keeper_event_queue.owned_job_completion_post_id completion;urgency=Immediate;
     arrived_at=Unix.gettimeofday ();payload=Owned_job_completed completion} in
  (match Event_registry.enqueue_stimulus_once_durable_result ~base_path:fixture.base_path keeper stimulus with
   | Stimulus_enqueued -> () | _ -> fail "actual interruption-boundary enqueue failed");
  let selection = only_selection fixture in
  (match Event_registry.terminalize_pending_turn_completed_result
      ~base_path:fixture.base_path keeper ~applied_at:(Unix.gettimeofday ()) ~selection with
   | Ok (Event_registry.Turn_source_acked _) -> ()
   | Ok Event_registry.Turn_selection_withdrawn -> fail "original completion selection was withdrawn"
   | Error detail -> fail ("consumer terminalization failed: " ^ detail));
  let path = owner_path fixture id in
  let complete_prefix = read path in
  write path (complete_prefix ^ "{\"completion_delivered\":tr");
  (match Store.load ~base_path:fixture.base_path ~keeper_name:keeper record.job_id with
   | Error (Store.Corrupt _) -> () | _ -> fail "strict result read accepted a torn owner ACK");
  Process_eio.reset_for_testing (); initialize ();
  let before = List.length (calls fixture) in
  let report = recover_completions fixture in
  check int "consumed delivery closes its original producer obligation" 1 report.delivered;
  check_no_completion fixture;
  check bool "producer ACK follows existing durable consumer evidence" true (load fixture id).completion_delivered;
  check int "producer ACK recovery makes no backend command" before (List.length (calls fixture));
  check int "no original launch replay" 1 (effect_count fixture "start");
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "cleanup discovery" in
  check int "acknowledged cleanup remains discoverable" 1 (List.length discovery.entries);
  let cleaned = recover_completions fixture in
  check int "a later maintenance round retires confirmed cleanup" 1 cleaned.retired;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "cleaned acknowledged marker is retired" 0 (List.length discovery.entries)

let test_completion_retains_unknown_launch_and_owner () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_absent"]);
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  Process_eio.reset_for_testing (); initialize ();
  set_source fixture ~task_id:"task-B" ~turn:52;
  let pending = recover_completions fixture in
  check int "unknown launch remains pending" 1 pending.waiting;
  check_no_completion fixture;
  check int "unknown create is not replayed by completion recovery" 1 (effect_count fixture "create");
  check int "unconfirmed original job is never started" 0 (effect_count fixture "start");
  let path = owner_path fixture id in
  let original = read path in
  let held = path ^ ".held" in
  Unix.rename path held;
  let missing = recover_completions fixture in
  check int "missing original authority remains visible" 1 (List.length missing.failures);
  check bool "recovery never creates a missing owner" false (Sys.file_exists path);
  Unix.rename held path;
  write path "corrupt original owner\n";
  let before = List.length (calls fixture) in
  let corrupt = recover_completions fixture in
  check int "unreadable original owner stays visible" 1 (List.length corrupt.failures);
  check int "corrupt authority authorizes no backend operation" before (List.length (calls fixture));
  check_no_completion fixture;
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retained owner discovery" in
  check int "uncertain owner is not retired" 1 (List.length discovery.entries);
  write path original;
  ignore (recover_completions fixture);
  check int "restored owner still cannot repeat original create" 1 (effect_count fixture "create");
  check int "restored owner still cannot authorize an absent start" 0 (effect_count fixture "start")


let test_cancelled_unknown_launch_delivery_and_cleanup () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_absent"]);
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-unknown-completion" ~turn:42
      "keeper_job_cancel" (argument id)));
  let delivered = recover_completions fixture in
  check int "cancelled unknown launch delivers once" 1 delivered.delivered;
  check int "cancelled unknown launch leaves waiting" 0 delivered.waiting;
  check int "cancellation delivery has no failure" 0 (List.length delivered.failures);
  let queued = completion_payload (only_selection fixture) in
  check string "notification keeps the original cancelled job" id (Store.Job_id.to_string queued.oj_job_id);
  let cleaned = recover_completions fixture in
  check int "next pulse confirms absence and retires cancellation" 1 cleaned.retired;
  check int "cancellation cleanup has no failure" 0 (List.length cleaned.failures);
  let record = load fixture id in
  check bool "cancellation remains a readable result" true (Store.result_ready record);
  check bool "cancellation resources are removed" true (record.cleanup = Store.Resources_removed);
  check int "absence-only cleanup never removes an unknown container" 0 (effect_count fixture "rm");
  Process_eio.reset_for_testing (); initialize ();
  check int "retired cancellation is not reinspected" 0 (recover_completions fixture).inspected;
  check int "cancellation is not redelivered" 1 (List.length (pending_completions fixture));
  check int "unknown launch is never repeated" 1 (effect_count fixture "create");
  check int "cancelled unknown launch never starts" 0 (effect_count fixture "start")

let test_finished_without_outputs_absent_inventory_notified_once () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  (* Confirmed exit first; output capture fails while the container exists. *)
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7; "mode", `String "logs_unknown"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"status-exited" ~turn:42
      "keeper_job_status" (argument id)));
  check bool "exit without outputs is not yet a result" false (Store.result_ready (load fixture id));
  check int "output capture attempted once" 1 (effect_count fixture "logs");
  (* The exact owned container is then removed externally. *)
  remove_fixture_container fixture id;
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  let delivered = recover_completions fixture in
  check int "absent inventory closes the finished job exactly once" 1 delivered.delivered;
  check int "closed job leaves the waiting set" 0 delivered.waiting;
  let record = load fixture id in
  check bool "closed terminal is a ready result" true (Store.result_ready record);
  (match record.outputs with
   | Some (Store.Outputs_unavailable {evidence}) ->
       check bool "closure carries exact absence evidence" true (String.length evidence > 0)
   | _ -> fail "finished job without outputs was not closed as unavailable");
  check bool "canonical owner acknowledged the one delivery" true record.completion_delivered;
  let cleanup = recover_completions fixture in
  check int "next pulse retires delivered unavailable result" 1 cleanup.retired;
  check int "unavailable result cleanup has no failure" 0 (List.length cleanup.failures);
  check bool "original resources are confirmed removed" true ((load fixture id).cleanup = Store.Resources_removed);
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "delivery marker is retired by the one notification" 0 (List.length discovery.entries);
  check int "absence closure collects no further output commands" 1 (effect_count fixture "logs");
  let selection = only_selection fixture in
  let completion = completion_payload selection in
  check string "the one completion names the original job" id (Store.Job_id.to_string completion.oj_job_id);
  (* A later pulse sees no pending marker, so nothing is reinspected or redelivered. *)
  Process_eio.reset_for_testing (); initialize ();
  let again = recover_completions fixture in
  check int "retired job is not reinspected" 0 again.inspected;
  check int "completion is not duplicated" 1 (List.length (pending_completions fixture));
  Event_registry.ack_pending_result ~base_path:fixture.base_path keeper ~selection
    |> require "actual completion queue consumption";
  let after_ack = recover_completions fixture in
  check int "acknowledged closure stays retired" 0 after_ack.inspected;
  check_no_completion fixture;
  check int "closed job never relaunches" 1 (effect_count fixture "create");
  check int "closed job never restarts" 1 (effect_count fixture "start")

let test_running_absent_inventory_notified_once () = with_fixture @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let started = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let id = job_id started in
  let initial = load fixture id in
  let container_id = match initial.phase with
    | Store.Running cid -> cid
    | _ -> fail "expected confirmed Running phase after start" in
  (* The exact owned container is removed externally while in Running phase (e.g. daemon reset). *)
  remove_fixture_container fixture id;
  let delivered = recover_completions fixture in
  check int "absent inventory closes the running job exactly once" 1 delivered.delivered;
  check int "closed running job leaves the waiting set" 0 delivered.waiting;
  let record = load fixture id in
  check bool "closed running job is a ready result" true (Store.result_ready record);
  (match record.outputs with
   | Some (Store.Outputs_unavailable {evidence}) ->
       check bool "closure evidence names the absent container" true
         (String.length evidence > 0 && Astring.String.is_infix ~affix:container_id evidence)
   | _ -> fail "running job with absent inventory was not closed as unavailable");
  check bool "canonical owner acknowledged the one delivery" true record.completion_delivered;
  let cleanup = recover_completions fixture in
  check int "next pulse retires delivered unavailable result" 1 cleanup.retired;
  check int "unavailable result cleanup has no failure" 0 (List.length cleanup.failures);
  check bool "original resources are confirmed removed" true ((load fixture id).cleanup = Store.Resources_removed);
  let discovery = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "retired discovery" in
  check int "delivery marker is retired by the one notification" 0 (List.length discovery.entries);
  let result_doc = with_bundle fixture (fun bundle ->
      invoke fixture bundle ~tool_use_id:"read-closed-running" ~turn:42 "keeper_job_result" (argument id)) in
  check string "keeper_job_result returns unavailable status" "unavailable"
    (result_doc |> member "status" |> to_string);
  Process_eio.reset_for_testing (); initialize ();
  let again = recover_completions fixture in
  check int "retired running job is not reinspected" 0 again.inspected;
  check int "completion is not duplicated" 1 (List.length (pending_completions fixture));
  check int "closed running job never relaunches" 1 (effect_count fixture "create");
  check int "closed running job never restarts" 1 (effect_count fixture "start")


let test_completion_hint_resumes_original_dag () = with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "await";"tool",`String "keeper_job_result";
         "input",`Assoc ["kind",`String "literal";"value",argument id]];
       `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";
         "after",`List [`String "await"];
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "sha256";"value",`Assoc
             ["kind",`String "output";"node",`String "await";
              "pointer",`String "/artifacts/0/_blob/sha256"]]]]]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-hint" ~turn:41 "keeper_composition_prepare" recipe) in
  let reference = prepared |> member "draft" |> composition_reference "actual completion hint draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-hint" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String reference.sha256])) in
  let ok,waiting,waiting_entry = await_composition env fixture accepted in
  check bool "original DAG is suspended before completion" false ok;
  (match waiting_entry.status with
   | Async.Waiting_for_dependencies {dependencies;_} ->
     check (list string) "completion hint has the original job wait" [id] (List.map dependency_job_id dependencies)
   | _ -> fail "original DAG was not canonically waiting for the job");
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original completion hint fixture\"\n";
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "completion hint Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "completion hint publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="completion-hint-fixture";
     sw=Async.server_background_switch () |> require "completion hint background switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let resumed,notify_resumed = Eio.Promise.create () in
  let accepted_intakes = ref 0 and other_intakes = ref [] in
  let continuations = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_intakes; Eio.Promise.resolve notify_resumed result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let hints = ref [] in
  let jobs = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      hints := (record,Store.result_ready record,pending_completions fixture,List.length (calls fixture)) :: !hints;
      Wake.pulse ~sw:context.sw continuations) () in
  (* Change the current turn before the original job completes. No direct
     composition resume or independent continuation pulse follows this point. *)
  set_source fixture ~task_id:"task-B" ~turn:52;
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  let backend_before = List.length (calls fixture) in
  let completion_started = Mtime_clock.counter () in
  Completion_wake.pulse ~sw:context.sw jobs;
  let resumed = Eio.Promise.await resumed |> Tool_result.data in
  let ok,completed,completed_entry = await_composition env fixture resumed in
  let completion_ms = Mtime.Span.to_float_ns (Mtime_clock.count completion_started) /. 1_000_000. in
  check bool "durable completion hint finishes the original DAG" true ok;
  check int "durable completion hint accepts one original worker" 1 !accepted_intakes;
  let record,ready,queued,backend_at_ready = match !hints with
    | [hint] -> hint | _ -> fail "expected exactly one original durable result hint" in
  check bool "hint follows full durable output" true ready;
  check string "hint identifies the original job" id (Store.Job_id.to_string record.job_id);
  check (option string) "hint keeps the original Task" (Some "task-A") record.source.task_id;
  let job_notifications = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Owned_job_completed completion ->
        Store.Job_id.to_string completion.oj_job_id = id
      | _ -> false) queued in
  check int "original notification is durable before hint" 1 (List.length job_notifications);
  let rec await_original_ack () =
    if (load fixture id).completion_delivered then ()
    else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_original_ack ()) in
  await_original_ack ();
  check bool "ordinary completion ACK is retained" true (load fixture id).completion_delivered;
  check int "continuation does not query the backend after complete output" backend_at_ready (List.length (calls fixture));
  check string "completion keeps the original run" (accepted |> member "composition_run_id" |> to_string)
    (resumed |> member "composition_run_id" |> to_string);
  let waiting_nodes = waiting |> member "settled" |> to_list
  and completed_nodes = completed |> member "actions" |> to_list in
  let waiting_node = composition_node "await" waiting_nodes
  and completed_node = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("completion hint keeps original occurrence " ^ field)
      (waiting_node |> member field) (completed_node |> member field)) ["execution_id";"tool_use_id"];
  check_json "hint consumer receives complete original stdout" (`String stdout_bytes)
    (composition_node "consume" completed_nodes |> member "result"
     |> member "data" |> member "content");
  let request_context = match completed_entry.request_context with
    | Some fields -> `Assoc fields | None -> fail "original hint completion has no source context" in
  check_json "hint completion belongs to original Task" (`String "task-A") (request_context |> member "source_task_id");
  check int "completion never recreates the original program" 1 (effect_count fixture "create");
  check int "completion never restarts the original program" 1 (effect_count fixture "start");
  Printf.printf "OWNED_COMPLETION_HINT_CONTINUATION %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public start/prepare/run and actual durable completion supervisor hint";
     "completion_pulse_to_original_dag_completion_ms",`Float completion_ms;
     "backend_calls_to_complete_original_job",`Int (backend_at_ready-backend_before);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-backend_at_ready);
     "accepted_intakes",`Int !accepted_intakes;"other_intakes",`Int (List.length !other_intakes);
     "durable_job_notifications_before_hint",`Int (List.length job_notifications);
     "program_creates",`Int (effect_count fixture "create");"program_starts",`Int (effect_count fixture "start")]))


let test_prepared_job_launch_and_continuation ~launch_after_result () = with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  let original_answer = Masc.Keeper_ask.answer_source_id ~ask_id:"original-prepared-question" ~answered_at:100.
      |> Option.get in
  let later_answer = Masc.Keeper_ask.answer_source_id ~ask_id:"later-prepared-question" ~answered_at:200.
      |> Option.get in
  let original_trace = Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id in
  set_source ~answer_source_ids:[original_answer] fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "launch";"tool",`String "keeper_job_start";
         "input",`Assoc ["kind",`String "literal";"value",`Assoc
           ["argv",`List [`String "fixture-program"]]]];
       `Assoc ["id",`String "await";"tool",`String "keeper_job_result";
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "job_id";"value",`Assoc
             ["kind",`String "output";"node",`String "launch";"pointer",`String "/job_id"]]]]];
       `Assoc ["id",`String "consume";"tool",`String "keeper_artifact_read";
         "after",`List [`String "await"];
         "input",`Assoc ["kind",`String "object";"fields",`List
           [`Assoc ["name",`String "sha256";"value",`Assoc
             ["kind",`String "output";"node",`String "await";
              "pointer",`String "/artifacts/0/_blob/sha256"]]]]]]] in
  let ask_next = `Assoc ["id",`String "ask-next";"tool",`String "masc_ask";
      "after",`List [`String "consume"];"input",`Assoc ["kind",`String "literal";
        "value",`Assoc ["task_id",`String "explicit-decision-task";
          "questions",`List [`Assoc ["header",`String "Next action";
            "prompt",`String "Which action follows the original result?";
            "mode",`String "single";"free_text",`Bool true]]]]] in
  let recipe = match recipe with
    | `Assoc fields -> `Assoc (List.map (function
        | "nodes",`List nodes -> "nodes",`List (nodes@[ask_next])
        | field -> field) fields)
    | _ -> fail "prepared job recipe is not an object" in
  let recipe = if not launch_after_result then recipe else
    let next = `Assoc ["id",`String "launch-next";"tool",`String "keeper_job_start";
      "after",`List [`String "consume"];"input",`Assoc ["kind",`String "literal";
        "value",`Assoc ["argv",`List [`String "fixture-next-program"]]]] in
    match recipe with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="nodes" then match value with
          | `List nodes -> key, `List (nodes@[next])
          | _ -> fail "prepared job nodes are not an array"
        else key,value) fields)
    | _ -> fail "prepared job recipe is not an object" in
  let prepare_started = Mtime_clock.counter () in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-hint" ~turn:41 "keeper_composition_prepare" recipe) in
  check bool "preparing a launch plan performs no backend operation" false (Sys.file_exists fixture.daemon_path);
  let reference = prepared |> member "draft" |> composition_reference "actual completion hint draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-hint" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String reference.sha256])) in
  let ok,waiting,waiting_entry = await_composition env fixture accepted in
  let prepare_to_wait_ms = Mtime.Span.to_float_ns (Mtime_clock.count prepare_started) /. 1_000_000. in
  check bool "original DAG is suspended before completion" false ok;
  let id = match waiting_entry.status with
    | Async.Waiting_for_dependencies {dependencies=[id];_} -> dependency_job_id id
    | _ -> fail "prepared launch did not produce one canonical original job wait" in
  let waiting_nodes = waiting |> member "settled" |> to_list in
  let original_launch = composition_node "launch" waiting_nodes in
  check string "prepared launch result is the exact awaited job" id
    (original_launch |> member "result" |> member "data" |> member "job_id" |> to_string);
  let original_job = load fixture id in
  let original_backend_id = fixture_container fixture id |> member "Id" |> to_string in
  (match original_job.phase with
   | Store.Running container_id ->
       check string "first launch confirms its actual Running identity" original_backend_id container_id
   | Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
   | Store.Exited _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch ->
       fail "the first prepared launch did not confirm Running");
  check bool "first backend actually started before its completion fault" true
    (fixture_container fixture id |> member "State" |> member "Running" |> to_bool);
  check (option string) "prepared launch belongs to the original Task" (Some "task-A") original_job.source.task_id;
  check (option string) "durable launch belongs to its exact node occurrence"
    (Some (original_launch |> member "tool_use_id" |> to_string)) original_job.source.tool_use_id;
  let before_refused_preparation = List.length (calls fixture) in
  let denied_job_id = Store.Job_id.fresh () |> Store.Job_id.to_string in
  List.iter (fun tool ->
    let unsupported = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "unsupported";"tool",`String tool;
        "input",`Assoc ["kind",`String "literal";"value",argument denied_job_id]]]] in
    with_bundle fixture (fun bundle ->
      match invoke_raw bundle ~tool_use_id:("unsupported-" ^ tool) ~turn:41 "keeper_composition_prepare" unsupported with
      | Error _ -> () | Ok _ -> failf "prepared launch admission also admitted %s" tool))
    ["keeper_job_status";"keeper_job_cancel"];
  check int "refused status/cancel preparation performs no backend operation" before_refused_preparation (List.length (calls fixture));
  let config = Workspace.default_config fixture.base_path in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original completion hint fixture\"\n";
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
      |> require "completion hint Skill publication authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "completion hint publication retired early");
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="completion-hint-fixture";
     sw=Async.server_background_switch () |> require "completion hint background switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let resumed,notify_resumed = Eio.Promise.create () in
  let accepted_intakes = ref 0 and other_intakes = ref [] in
  let continuations = Wake.create ~context ~on_result:(fun _ outcome -> match outcome with
      | Ok (Tool_result.Completed _ as result) ->
        incr accepted_intakes; Eio.Promise.resolve notify_resumed result
      | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ ->
        other_intakes := outcome :: !other_intakes) () in
  let hints = ref [] in
  let jobs = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      hints := (record,Store.result_ready record,pending_completions fixture,List.length (calls fixture)) :: !hints;
      Wake.pulse ~sw:context.sw continuations) () in
  (* Change the current turn before the original job completes. No direct
     composition resume or independent continuation pulse follows this point. *)
  set_source ~answer_source_ids:[later_answer] fixture ~task_id:"task-B" ~turn:52;
  let later_trace = Keeper_id.Trace_id.of_string "prepared-later-runtime-trace" |> require "later trace" in
  let later_meta = {fixture.meta with runtime={fixture.meta.runtime with trace_id=later_trace}} in
  ignore (Masc.Keeper_meta_store.replace_snapshot config later_meta |> require "persist later metadata trace");
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  let backend_before = List.length (calls fixture) in
  let completion_started = Mtime_clock.counter () in
  Completion_wake.pulse ~sw:context.sw jobs;
  let resumed = Eio.Promise.await resumed |> Tool_result.data in
  let ok,completed,completed_entry = await_composition env fixture resumed in
  let completion_ms = Mtime.Span.to_float_ns (Mtime_clock.count completion_started) /. 1_000_000. in
  check bool "durable completion hint finishes the original DAG" true ok;
  check int "durable completion hint accepts one original worker" 1 !accepted_intakes;
  let continued_ask = Masc.Keeper_ask_store.open_asks ~base_path:fixture.base_path ~keeper_name:keeper
      |> List.find (fun (ask : Masc.Keeper_ask.ask) -> ask.task_id=Some "explicit-decision-task") in
  check (option string) "fresh post-wait Ask belongs to original execution, not current Task B"
    (Some (original_trace ^ "#41"))
    (Option.map Ids.Turn_ref.to_string continued_ask.source_turn_ref);
  let record,ready,queued,backend_at_ready = match !hints with
    | [hint] -> hint | _ -> fail "expected exactly one original durable result hint" in
  check bool "hint follows full durable output" true ready;
  check string "hint identifies the original job" id (Store.Job_id.to_string record.job_id);
  check (option string) "hint keeps the original Task" (Some "task-A") record.source.task_id;
  let job_notifications = List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      match selection.source.payload with
      | Keeper_event_queue.Owned_job_completed completion ->
        Store.Job_id.to_string completion.oj_job_id = id
      | _ -> false) queued in
  check int "original notification is durable before hint" 1 (List.length job_notifications);
  let rec await_original_ack () =
    if (load fixture id).completion_delivered then ()
    else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_original_ack ()) in
  await_original_ack ();
  check bool "ordinary completion ACK is retained" true (load fixture id).completion_delivered;
  if not launch_after_result then
    check int "continuation does not query the backend after complete output" backend_at_ready (List.length (calls fixture));
  check string "completion keeps the original run" (accepted |> member "composition_run_id" |> to_string)
    (resumed |> member "composition_run_id" |> to_string);
  let completed_nodes = completed |> member "actions" |> to_list in
  let waiting_node = composition_node "await" waiting_nodes
  and completed_node = composition_node "await" completed_nodes in
  List.iter (fun field -> check_json ("completion hint keeps original occurrence " ^ field)
      (waiting_node |> member field) (completed_node |> member field)) ["execution_id";"tool_use_id"];
  let retained_launch = composition_node "launch" completed_nodes in
  List.iter (fun field -> check_json ("completed launch retains original " ^ field)
      (original_launch |> member field) (retained_launch |> member field)) ["execution_id";"tool_use_id";"result"];
  check_json "completed effectful launch is reused without dispatch" (`String "retained_completion")
    (retained_launch |> member "execution_origin");
  check_json "hint consumer receives complete original stdout" (`String stdout_bytes)
    (composition_node "consume" completed_nodes |> member "result"
     |> member "data" |> member "content");
  let request_context = match completed_entry.request_context with
    | Some fields -> `Assoc fields | None -> fail "original hint completion has no source context" in
  check_json "hint completion belongs to original Task" (`String "task-A") (request_context |> member "source_task_id");
  Call_log.flush_now ();
  let all_rows = Call_log.read_recent ~keeper_name:keeper () |> require "recovered original Tool observations" in
  let await_rows = List.filter (fun row -> member "composition_node_id" row=`String "await"
      && member "composition_run_id" row=member "composition_run_id" accepted) all_rows in
  check int "waiting and completed result reads both retain physical observations" 2 (List.length await_rows);
  let physical_ids = List.map (fun row -> member "physical_execution_id" row |> to_string) await_rows in
  check int "one logical wait retains two distinct physical calls" 2
    (List.length (List.sort_uniq String.compare physical_ids));
  List.iter (fun row ->
    check_json "physical result rechecks retain one logical node identity"
      (member "execution_id" waiting_node) (member "execution_id" row);
    check_json "physical rechecks retain the original answer input"
      (`List [`String original_answer]) (member "answer_source_ids" row);
    check_json "physical rechecks retain the original trace" (`String original_trace) (member "trace_id" row);
    check_json "physical rechecks retain the original Keeper turn" (`Int 41) (member "keeper_turn_id" row)) await_rows;
  let recovered_rows = all_rows
      |> List.filter (fun row -> member "tool" row=`String "keeper_artifact_read"
          && member "composition_run_id" row=member "composition_run_id" accepted) in
  check int "the actual post-completion consumer has one physical Tool result" 1 (List.length recovered_rows);
  List.iter (fun row ->
    check_json "fresh continuation keeps the original answer input" (`List [`String original_answer])
      (member "answer_source_ids" row);
    check_json "fresh continuation keeps the original trace despite current metadata" (`String original_trace)
      (member "trace_id" row);
    check_json "fresh continuation keeps the original physical Keeper turn" (`Int 41) (member "keeper_turn_id" row);
    check_json "fresh continuation never adopts the current Task" (`String "task-A") (member "task_id" row)) recovered_rows;
  if launch_after_result then (
    let next = composition_node "launch-next" completed_nodes in
    let next_id = next |> member "result" |> member "data" |> member "job_id" |> to_string in
    check bool "the post-wait node starts its own distinct job" true (next_id<>id);
    let next_job = load fixture next_id in
    let next_backend_id = match next_job.phase with
      | Store.Running container_id -> container_id
      | Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
      | Store.Exited _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch ->
          fail "post-wait launch did not confirm its own Running backend" in
    check bool "the second successful start owns a distinct physical container" true
      (next_backend_id <> original_backend_id);
    let next_container = fixture_container fixture next_id in
    check string "canonical Running identity matches the second actual backend"
      next_backend_id (next_container |> member "Id" |> to_string);
    check bool "second backend actually started, not merely attempted create" true
      (next_container |> member "State" |> member "Running" |> to_bool);
    check string "second backend is running despite the first job's targeted exit"
      "running" (next_container |> member "State" |> member "Status" |> to_string);
    check string "the first physical resource remains retained"
      original_backend_id (fixture_container fixture id |> member "Id" |> to_string);
    check int "the retained original resource keeps its own terminal exit" 7
      (fixture_container fixture id |> member "State" |> member "ExitCode" |> to_int);
    check bool "second launch never rewrites the original terminal phase" true
      ((load fixture id).phase = record.phase);
    check bool "second launch never rewrites the original complete outputs" true
      ((load fixture id).outputs = record.outputs);
    check (option string) "new post-wait launch keeps the original Task" (Some "task-A") next_job.source.task_id;
    check (option string) "new post-wait launch keeps the original trace" (Some original_trace) next_job.source.trace_id;
    check (option int) "new post-wait launch keeps the original physical Keeper turn" (Some 41)
      next_job.source.keeper_turn_id);
  let expected_programs = if launch_after_result then 2 else 1 in
  check int "only the declared distinct programs are created" expected_programs (effect_count fixture "create");
  check int "only the declared distinct programs are started" expected_programs (effect_count fixture "start");
  Printf.printf "OWNED_PREPARED_JOB_LAUNCH_CONTINUATION %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public prepare/run launching an owned job within the original DAG";
     "launch_after_saved_result",`Bool launch_after_result;
     "prepare_and_launch_to_saved_job_wait_ms",`Float prepare_to_wait_ms;
     "completion_pulse_to_original_dag_completion_ms",`Float completion_ms;
     "backend_calls_to_complete_original_job",`Int (backend_at_ready-backend_before);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-backend_at_ready);
     "accepted_intakes",`Int !accepted_intakes;"other_intakes",`Int (List.length !other_intakes);
     "durable_job_notifications_before_hint",`Int (List.length job_notifications);
     "program_creates",`Int (effect_count fixture "create");"program_starts",`Int (effect_count fixture "start")]))

let invocation_binding_job_ids fixture =
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path)
         "keeper_msg_requests") "owned_job_invocations" in
  Array.to_list (Sys.readdir directory)
  |> List.filter (fun name -> Filename.check_suffix name ".json")
  |> List.map (fun name ->
      Yojson.Safe.from_file (Filename.concat directory name) |> member "job_id" |> to_string)

let test_interrupted_prepared_launch_resumes_the_same_job keeper_turn_id () = with_fixture @@ fun env initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Async = Masc.Keeper_msg_async in
  let module Draft = Masc.Keeper_composition_draft in
  let module Plan = Masc.Keeper_tool_plan in
  Call_log.set_turn_context ~cell:fixture.cell ~agent_name:keeper ~task_id:"task-A"
    ~turn:41 ?keeper_turn_id
    ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ();
  Call_log.init ~base_path:fixture.base_path ();
  let recipe = `Assoc
    [ "execution", `String "async"
    ; "nodes", `List
        [ `Assoc
            [ "id", `String "launch"
            ; "tool", `String "keeper_job_start"
            ; "input", `Assoc
                [ "kind", `String "literal"
                ; "value", `Assoc ["argv", `List [`String "fixture-program"]] ] ] ] ] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-interrupted" ~turn:41 "keeper_composition_prepare" recipe) in
  let reference = prepared |> member "draft" |> composition_reference "interrupted launch draft" in
  let capability_surface = frozen_surface ~base_path:fixture.base_path ~sandbox_profile:fixture.meta.sandbox_profile in
  let draft = Draft.load ~base_path:fixture.base_path ~capability_surface ~keeper_name:keeper
      ~sha256:reference.sha256 |> require "interrupted launch draft" in
  let composition_run_id = Plan.Composition_run_id.fresh () in
  let parent_invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"run-interrupted"
      ~turn:41 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let run_reference = Draft.record_invocation ~base_path:fixture.base_path ~composition_run_id
      ~invocation:parent_invocation draft |> require "interrupted launch run artifact" in
  let source : Journal.source =
    { keeper_name = keeper; composition_run_id
    ; draft_reference = Draft.reference draft; run_reference
    ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation
    ; source_turn = 41; source_task_id = Some "task-A"; producer=Journal.Prepared } in
  (* The producer records the trace and Keeper turn its turn context holds, as
     the composition surface does when it prepares a journal. Without that
     observation the launch identity is unknown and the executor refuses the
     launch before it can be interrupted. *)
  let observation : Journal.source_observation =
    { trace_id = Some fixture.meta.runtime.trace_id; session_id = None; keeper_turn_id; answer_source_ids = [] } in
  let journal = Journal.prepare ~observation ~base_path:fixture.base_path source |> require "interrupted launch journal" in
  let run = Plan.Composition_run_id.to_string composition_run_id in
  let parent = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation in
  let launch_tool_use_id = Printf.sprintf "composition:%d:%s:%d:%s:%d:%s"
      (String.length run) run (String.length parent) parent (String.length "launch") "launch" in
  control_launch fixture ~tool_use_id:launch_tool_use_id ~keeper_turn_id
    (`Assoc ["mode",`String "start_blocked"]);
  let request_context = Some
      [ "composition_tool", `String Draft.run_tool_name
      ; "parent_tool_use_id", `String source.parent_tool_use_id
      ; "source_turn", `Int 41
      ; "composition_run_id", `String (Plan.Composition_run_id.to_string composition_run_id)
      ; "draft_reference", Tool_output.normalized_artifact_ref_to_json source.draft_reference
      ; "run_artifact", Tool_output.normalized_artifact_ref_to_json source.run_reference
      ; "source_task_id", `String "task-A" ] in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let config = Workspace.default_config fixture.base_path in
  let module Surface = Masc.Keeper_tool_composition_surface in
  let module Outbox = Masc.Keeper_composition_completion_outbox in
  let module Wake = Masc.Keeper_composition_completion_wake in
  (* Intercept the actual production worker at its real backend start. This
     is an in-process interrupted worker, not process-crash/startup evidence. *)
  let worker1 = ref None in
  let settled1, notify_settled1 = Eio.Promise.create () in
  let first = Async.submit_worker_with_request_id ?request_context
      ~background_sw:(Async.server_background_switch () |> require "interrupted worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Outbox.prepare ~base_path:fixture.base_path ~keeper_name:keeper
            ~request_id ~composition_tool:Draft.run_tool_name with
        | Error error -> Error (Outbox.error_to_string error)
        | Ok () -> Journal.bind_request journal ~request_id
            |> Result.map (fun worker -> worker1 := Some worker)
            |> Result.map_error Journal.error_to_string)
      ~on_worker_settled:(fun settlement ->
        Wake.on_worker_settled ~base_path:fixture.base_path
          ~composition_tool:Draft.run_tool_name settlement;
        Eio.Promise.resolve notify_settled1 settlement)
      ~f:(fun ~request_id request_sw ->
        let worker = match !worker1 with Some worker -> worker | None -> fail "unbound interrupted worker" in
        let rec await_start () =
          if Sys.file_exists (Filename.concat fixture.base_path "start-entered") then ()
          else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.005; await_start ()) in
        Eio.Fiber.first
          (fun () -> Surface.For_testing.async_worker_result
            ~composition_execution:Masc.Keeper_tool_composition_catalog.Async
            ~tool_kind:Descriptor.Async_composition_tool ~plan:(Draft.plan draft) ~journal:worker
            ~tool_name:Draft.run_tool_name ~request_id ~composition_run_id ~source_invocation:parent_invocation
            ~request_sw ~config ~meta:fixture.meta
            ~capability_authority:(Masc.Keeper_tool_runtime.Frozen_surface capability_surface)
            ~publication_recovery
            ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"actual interrupted launch")
            ~keeper_turn_id:(fun () -> Some 1)
            ~turn_context:(Some (Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ()))
            ~clock:(Eio.Stdenv.clock env) ())
          (fun () -> await_start ();
            Async.worker_interrupted ~reason:"fixture interrupted the actual start reply")) () in
  let first = first |> require "interrupted original request accepted" in
  ignore (Eio.Promise.await settled1);
  let terminal request_id =
    let rec read () = match Async.load_canonical_durable_terminal ~base_path:fixture.base_path
        ~caller:keeper request_id with
      | Ok proof -> Async.durable_terminal_entry proof
      | Error (Async.Canonical_terminal_absent | Async.Canonical_terminal_runtime_active _) ->
          Eio.Fiber.yield (); read ()
      | Error error -> fail (Async.canonical_terminal_error_to_string error) in read () in
  let check_lost ?(queued = 0) label entry =
    (match entry.Async.status with
     | Async.Lost _ -> ()
     | Async.Done _ | Async.Queued | Async.Running | Async.Cancelling _ | Async.Cancelled _
     | Async.Persistence_failed _ | Async.Waiting_for_dependencies _ ->
         fail (label ^ " became a logical terminal"));
    check bool (label ^ " retains pending logical completion") true
      (Journal.completion_pending ~base_path:fixture.base_path entry |> require "pending launch proof");
    let delivered = ref 0 in
    let report = Outbox.flush ~base_path:fixture.base_path
        ~deliver:(fun ~completion:_ ~composition_tool:_ _ -> incr delivered; Ok ()) |> require "actual pending outbox" in
    check int (label ^ " emits no outbox notification") 0 !delivered;
    check int (label ^ " delivers no terminal") 0 report.delivered;
    check (list (pair string string)) (label ^ " keeps readable guarded outbox authority") []
      (List.map (fun (identity,error) -> identity,Outbox.error_to_string error) report.failures);
    let pending = pending_completions fixture in
    check int (label ^ " adds no queue completion") queued (List.length pending);
    let original_request_notifications = pending |> List.filter
        (fun (selection : Keeper_event_queue_state.pending_selection) ->
          match selection.source.payload with
          | Keeper_event_queue.Composition_completed completion ->
            String.equal completion.cc_request_id entry.request_id
          | _ -> false) in
    check int (label ^ " leaves no false queue completion") 0
      (List.length original_request_notifications) in
  check_lost "first interrupted launch" (terminal first.request_id);
  (match Journal.waiting_continuation journal |> require "first Lost launch is publicly resumable" with
   | Some continuation -> check int "first Lost invents no dependency wait" 0
       (List.length (Journal.continuation_dependencies continuation))
   | None -> fail "first Lost launch fell back to fresh request admission");
  let bound_ids = invocation_binding_job_ids fixture in
  check int "interrupted launch reserved exactly one job" 1 (List.length bound_ids);
  let id = List.hd bound_ids in
  (match (load fixture id).phase with
   | Store.Start_requested _ -> ()
   | _ -> fail "interrupted launch did not retain its exact start intent");
  check int "interrupted launch created the job exactly once" 1 (effect_count fixture "create");
  check int "interrupted launch started the program exactly once" 1 (effect_count fixture "start");
  (match Journal.lookup (Option.get !worker1) ~node_id:(Plan.Node_id.make "launch" |> require "launch node")
        ~tool_name:"keeper_job_start" ~input:(`Assoc ["argv", `List [`String "fixture-program"]]) with
   | Ok (Journal.Recheck_launch replay) ->
     check string "interrupted launch replay preserves its recorded trace"
       (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) replay.Journal.invocation.trace_id;
     check int "interrupted launch replay preserves its recorded turn" 41
       (Ids.Turn_ref.absolute_turn replay.Journal.invocation.turn_ref)
   | Ok _ -> fail "interrupted launch leaf did not authorize a launch replay"
   | Error error -> fail (Journal.error_to_string error));
  let original_job = load fixture id in
  let original_source = Store.source_to_json original_job.source in
  check_json "first launch records the actual source-context K, not the callback K"
    (match keeper_turn_id with Some value -> `Int value | None -> `Null)
    (original_source |> member "keeper_turn_id");
  let binding_directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path)
         "keeper_msg_requests") "owned_job_invocations" in
  let binding_path = Array.to_list (Sys.readdir binding_directory)
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> function [name] -> Filename.concat binding_directory name
         | _ -> fail "expected one original invocation binding" in
  let original_binding = read binding_path in
  let saved_binding = Filename.concat fixture.base_path "saved-original-binding" in
  Process_eio.reset_for_testing (); initialize ();
  let meta_for trace =
    let trace_id = Keeper_id.Trace_id.of_string trace |> require "current trace" in
    {fixture.meta with runtime={fixture.meta.runtime with trace_id}} in
  let later_meta = meta_for "interrupted-current-B" in
  let final_meta = meta_for "interrupted-current-C" in
  let resume ~meta ~task_id ~turn =
    Call_log.set_turn_context ~cell:fixture.cell ~agent_name:keeper ~task_id
      ~turn ~keeper_turn_id:turn
      ~trace_id:(Keeper_id.Trace_id.to_string meta.Masc.Keeper_meta_contract.runtime.trace_id) ();
    let tools = Surface.make_tools ~capability_surface ~config ~meta ~publication_recovery
        ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"public original launch resume")
        ~turn_ctx_cell:fixture.cell ~clock:(Eio.Stdenv.clock env) () in
    let tool = List.find_map (fun (tool,_,_) ->
        if tool.Agent_core.Tool.schema.name = Draft.run_tool_name then Some tool else None) tools
      |> Option.get in
    let invocation = Agent_core.Tool_contract.Invocation.create
        ~tool_use_id:("public-launch-resume-" ^ string_of_int turn) ~turn
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    let output = Agent_core.Tool.execute ~invocation tool
        (`Assoc ["sha256",`String reference.sha256;"resume_run_id",
          `String (Plan.Composition_run_id.to_string composition_run_id)])
      |> require "actual public launch resume accepted" in
    let ack = result_document ~base_path:fixture.base_path output.content in
    check_json "public resume retains original logical run"
      (`String (Plan.Composition_run_id.to_string composition_run_id)) (ack |> member "composition_run_id");
    let entry = terminal (ack |> member "request_id" |> to_string) in
    check_json "public successor retains original Task A" (`String "task-A")
      (match entry.request_context with Some fields -> List.assoc "source_task_id" fields
       | None -> fail "public resume dropped original source");
    entry in
  let altered_binding field value =
    Yojson.Safe.from_string original_binding |> to_assoc
    |> List.map (fun (name, prior) -> name, if name = field then value else prior)
    |> fun fields -> Yojson.Safe.to_string (`Assoc fields) in
  let different_request_sha = Digestif.SHA256.(to_hex (digest_string
      (Yojson.Safe.to_string (`Assoc
        ["argv", `List [`String "different-program"]; "inputs", `List []])))) in
  (* Every retry crosses the real broker/Executor/Handler/Dispatcher/Runtime.
     Faults replace only the original binding authority; the launched job and
     its intent remain untouched. A normal reserve here would create Fresh
     when missing, or accept a later Task after a wrong identity derivation. *)
  List.iter (fun (label, replacement) ->
    Unix.rename binding_path saved_binding;
    Fun.protect ~finally:(fun () ->
        remove_tree binding_path; Unix.rename saved_binding binding_path) (fun () ->
      (match replacement with
       | `Missing -> ()
       | `Directory -> Unix.mkdir binding_path 0o700
       | `Bytes bytes -> write binding_path bytes; Unix.chmod binding_path 0o600);
      let calls_before = List.length (calls fixture) in
      let entry = resume ~meta:later_meta ~task_id:"task-B" ~turn:52 in
      check_lost label entry;
      check int (label ^ " makes no backend call") calls_before (List.length (calls fixture));
      check int (label ^ " never creates") 1 (effect_count fixture "create");
      check int (label ^ " never starts") 1 (effect_count fixture "start");
      check_json (label ^ " preserves original Task/trace/TurnRef/K") original_source
        (Store.source_to_json (load fixture id).source);
      check bool (label ^ " preserves the unconfirmed start intent") true
        ((load fixture id).phase = original_job.phase);
      (match replacement with
       | `Missing -> check bool "missing binding is not recreated" false (Sys.file_exists binding_path)
       | `Directory -> check bool "nonregular authority is not overwritten" true
           ((Unix.lstat binding_path).Unix.st_kind = Unix.S_DIR)
       | `Bytes bytes -> check string (label ^ " retains rejected bytes") bytes (read binding_path)));
    check string (label ^ " restores the exact original bytes") original_binding (read binding_path))
    [ "missing", `Missing
    ; "malformed", `Bytes "{invalid binding json"
    ; "unreadable nonregular binding", `Directory
    ; "foreign owner", `Bytes (altered_binding "keeper_name" (`String "different-keeper"))
    ; "different argv", `Bytes (altered_binding "request_sha256" (`String different_request_sha)) ];
  let entry = resume ~meta:final_meta ~task_id:"task-C" ~turn:63 in
  let data = match entry.status with
    | Async.Done {ok=true;data=Some data;_} -> data
    | Async.Done {ok=false;_} | Async.Done {ok=true;data=None;_}
    | Async.Queued | Async.Running | Async.Cancelling _ | Async.Cancelled _ | Async.Lost _
    | Async.Persistence_failed _ | Async.Waiting_for_dependencies _ -> fail "restored public resume did not complete" in
  let action = data |> member "actions" |> to_list
      |> List.find (fun action -> action |> member "node_id" |> to_string = "launch") in
  check_json "public completion returns original job" (`String id)
    (action |> member "result" |> member "data" |> member "job_id");
  let job = load fixture id in
  check string "restored launch returns the same job" id (Store.Job_id.to_string job.job_id);
  check_json "Task C and trace C cannot contaminate the original source" original_source
    (Store.source_to_json job.source);
  check string "recovery never changes the original binding" original_binding (read binding_path);
  check int "recovery retains exactly one invocation binding" 1 (List.length (invocation_binding_job_ids fixture));
  check int "recovery never recreates the original program" 1 (effect_count fixture "create");
  check int "recovery never restarts the original program" 1 (effect_count fixture "start");
  check bool "completed public successor clears its pending result" false
    (Journal.completion_pending ~base_path:fixture.base_path entry |> require "actual completed membership");
  ignore (Wake.reconcile ~base_path:fixture.base_path |> require "actual completion recovery");
  check int "only final public success notifies the original run" 1 (List.length (pending_completions fixture));
  let pre_reserve_run_id = Plan.Composition_run_id.fresh () in
  let pre_reserve_invocation = Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"run-interrupted-before-reserve" ~turn:41
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let pre_reserve_run_ref = Draft.record_invocation ~base_path:fixture.base_path
      ~composition_run_id:pre_reserve_run_id ~invocation:pre_reserve_invocation draft
    |> require "pre-reserve interrupted launch run artifact" in
  let pre_reserve_source : Journal.source =
    { source with composition_run_id = pre_reserve_run_id
    ; run_reference = pre_reserve_run_ref
    ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id pre_reserve_invocation } in
  let pre_reserve_journal = Journal.prepare ~observation ~base_path:fixture.base_path pre_reserve_source
      |> require "pre-reserve interrupted launch journal" in
  let pre_reserve_context = Some
      [ "composition_tool", `String Draft.run_tool_name
      ; "parent_tool_use_id", `String pre_reserve_source.parent_tool_use_id
      ; "source_turn", `Int 41
      ; "composition_run_id", `String (Plan.Composition_run_id.to_string pre_reserve_run_id)
      ; "draft_reference", Tool_output.normalized_artifact_ref_to_json pre_reserve_source.draft_reference
      ; "run_artifact", Tool_output.normalized_artifact_ref_to_json pre_reserve_source.run_reference
      ; "source_task_id", `String "task-A" ] in
  let pre_worker = ref None in
  let pre_settled, notify_pre_settled = Eio.Promise.create () in
  let pre_trace = Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id in
  (* Preserve the first run's queued public success without allowing this
     interrupted launch to add another completion. Capture before submission. *)
  let queued_before = List.length (pending_completions fixture) in
  let pre_first = Async.submit_worker_with_request_id ?request_context:pre_reserve_context
      ~background_sw:(Async.server_background_switch () |> require "pre-reserve worker switch")
      ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id ->
        match Outbox.prepare ~base_path:fixture.base_path ~keeper_name:keeper
            ~request_id ~composition_tool:Draft.run_tool_name with
        | Error error -> Error (Outbox.error_to_string error)
        | Ok () -> Journal.bind_request pre_reserve_journal ~request_id
            |> Result.map (fun worker -> pre_worker := Some worker)
            |> Result.map_error Journal.error_to_string)
      ~on_worker_settled:(fun settlement ->
        Wake.on_worker_settled ~base_path:fixture.base_path
          ~composition_tool:Draft.run_tool_name settlement;
        Eio.Promise.resolve notify_pre_settled settlement)
      ~f:(fun ~request_id:_ _request_sw ->
        let worker = Option.get !pre_worker in
        Journal.validate_plan worker ~plan:(Draft.plan draft)
        |> Result.map_error Journal.error_to_string |> require "pre-reserve plan validation";
        ignore (Journal.begin_attempt worker
            ~node_id:(Plan.Node_id.make "launch" |> require "launch node")
            ~tool_name:"keeper_job_start"
            ~input:(`Assoc ["argv", `List [`String "fixture-program"]])
            ~execution_id:(Ids.Execution_id.generate ())
            ~tool_use_id:"pre-reserve-launch-leaf" ~readonly:false
            ~launch_invocation:{trace_id=pre_trace;
              turn_ref=Ids.Turn_ref.make ~trace_id:pre_trace ~absolute_turn:41;
              keeper_turn_id} ()
          |> Result.map_error Journal.error_to_string |> require "pre-reserve attempting record");
        Async.worker_interrupted ~reason:"interrupted before Invocation.reserve") ()
    |> require "pre-reserve request accepted" in
  ignore (Eio.Promise.await pre_settled);
  check_lost ~queued:queued_before "pre-reserve interrupted launch" (terminal pre_first.request_id);
  Call_log.set_turn_context ~cell:fixture.cell ~agent_name:keeper ~task_id:"task-C"
    ~turn:64 ~keeper_turn_id:99
    ~trace_id:(Keeper_id.Trace_id.to_string final_meta.runtime.trace_id) ();
  let tools = Surface.make_tools ~capability_surface ~config ~meta:final_meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"pre-reserve launch resume")
      ~turn_ctx_cell:fixture.cell ~clock:(Eio.Stdenv.clock env) () in
  let tool = List.find_map (fun (tool,_,_) ->
      if tool.Agent_core.Tool.schema.name = Draft.run_tool_name then Some tool else None) tools
    |> Option.get in
  let pre_resume_inv = Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"public-pre-reserve-resume" ~turn:64
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let pre_output = Agent_core.Tool.execute ~invocation:pre_resume_inv tool
      (`Assoc ["sha256",`String reference.sha256;"resume_run_id",
        `String (Plan.Composition_run_id.to_string pre_reserve_run_id)])
    |> require "pre-reserve public launch resume accepted" in
  let pre_ack = result_document ~base_path:fixture.base_path pre_output.content in
  let pre_entry = terminal (pre_ack |> member "request_id" |> to_string) in
  let pre_data = match pre_entry.status with
    | Async.Done {ok=true;data=Some data;_} -> data
    | Async.Done {ok=false;_} | Async.Done {ok=true;data=None;_}
    | Async.Queued | Async.Running | Async.Cancelling _ | Async.Cancelled _ | Async.Lost _
    | Async.Persistence_failed _ | Async.Waiting_for_dependencies _ ->
        fail "pre-reserve public resume did not complete" in
  let pre_job_id = pre_data |> member "actions" |> to_list
      |> List.find (fun action -> action |> member "node_id" |> to_string = "launch")
      |> member "result" |> member "data" |> member "job_id" |> to_string in
  let pre_job = load fixture pre_job_id in
  check (option string) "pre-reserve resume preserves original Task A" (Some "task-A") pre_job.source.task_id;
  check (option int) "pre-reserve resume preserves original K" keeper_turn_id pre_job.source.keeper_turn_id;
  Printf.printf "OWNED_INTERRUPTED_LAUNCH_PUBLIC_RESUME job=%s originalK=%s refusals=5 create=1 start=1 source_preserved=true\n%!"
    id (match keeper_turn_id with None -> "none" | Some value -> string_of_int value)

let with_nested_job_skill ?fixture_base_path ?(wait_only=false)
    ?(parameterized=false)
    ?(exports=["stdout","consume","/content"])
    ?(branch_failure_policy=Masc.Keeper_tool_plan.default_branch_failure_policy) ~execution operation =
  with_fixture ?fixture_base_path @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  let module Async = Masc.Keeper_msg_async in
  let module Recorder = Masc.Keeper_skill_activation_recorder in
  let module Surface = Masc.Keeper_capability_surface in
  let module Delivery = Masc.Keeper_composition_result_delivery in
  let config = Workspace.default_config fixture.base_path in
  set_source fixture ~task_id:"task-A" ~turn:41;
  Call_log.init ~base_path:fixture.base_path ();
  let original_job = if not wait_only then None else (
    let path = Filename.concat fixture.base_path "physical-original-job" in
    if Sys.file_exists path then Some (read path) else
    let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
    write path id; Some id) in
  let skill_dir = Filename.concat fixture.base_path ".agents/skills/nested-owned-job" in
  Fs_compat.mkdir_p skill_dir;
  let export_source = exports |> List.map (fun (name,node,pointer) ->
      Printf.sprintf "[[compositions.exports]]\nname = %S\nnode = %S\npointer = %S\n" name node pointer)
    |> String.concat "" in
  let launch_source = Printf.sprintf {|---
name: nested-owned-job
description: Launch one owned job and consume its original complete stdout.
---

```toml composition
[[compositions]]
name = "nested-owned-job"
execution = "%s"
branch_failure_policy = %S
[[compositions.nodes]]
id = "launch"
tool = "keeper_job_start"
[compositions.nodes.input]
kind = "literal"
value = { argv = ["fixture-program"] }
[[compositions.nodes]]
id = "await"
tool = "keeper_job_result"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "job_id"
[compositions.nodes.input.fields.value]
kind = "output"
node = "launch"
pointer = "/job_id"
[[compositions.nodes]]
id = "consume"
tool = "keeper_artifact_read"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "sha256"
[compositions.nodes.input.fields.value]
kind = "output"
node = "await"
pointer = "/artifacts/0/_blob/sha256"
%s
```
|} (match execution with Masc.Keeper_tool_composition_catalog.Inline -> "inline" | Async -> "async")
    (Masc.Keeper_tool_plan.branch_failure_policy_to_string branch_failure_policy) export_source in
  let parameters,job_input = match original_job,parameterized with
    | Some id,true -> Printf.sprintf {|[[compositions.params]]
name = "job_id"
type = "string"
enum = [%S]
description = "The exact original owned job."
|} id,
        "kind = \"object\"\n[[compositions.nodes.input.fields]]\nname = \"job_id\"\n[compositions.nodes.input.fields.value]\nkind = \"param\"\nname = \"job_id\""
    | Some id,false -> "",Printf.sprintf "kind = \"literal\"\nvalue = { job_id = %S }" id
    | None,(true | false) -> "","" in
  let source = match original_job with None -> launch_source | Some _ -> Printf.sprintf {|---
name: nested-owned-job
description: Wait for the original owned job and read its complete stdout.
---

```toml composition
[[compositions]]
name = "nested-owned-job"
execution = %S
branch_failure_policy = %S
%s
[[compositions.nodes]]
id = "await"
tool = "keeper_job_result"
[compositions.nodes.input]
%s
[[compositions.nodes]]
id = "consume"
tool = "keeper_artifact_read"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "sha256"
[compositions.nodes.input.fields.value]
kind = "output"
node = "await"
pointer = "/artifacts/0/_blob/sha256"
%s
```
|} (match execution with Masc.Keeper_tool_composition_catalog.Inline -> "inline" | Async -> "async")
    (Masc.Keeper_tool_plan.branch_failure_policy_to_string branch_failure_policy) parameters job_input export_source in
  write (Filename.concat skill_dir "SKILL.md") source;
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original nested owned-job continuation fixture\"\n";
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:fixture.base_path in
  write runtime_path "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = \"fixture\"\nanchor = \"base-path\"\npath = \".agents/skills\"\naccess = \"read-write\"\n";
  let workspace = Skill_catalog_snapshot_service.workspace_of_base_path ~base_path:fixture.base_path
    |> require "nested Skill workspace authority" in
  Fun.protect ~finally:(fun () -> Skill_catalog_snapshot_service.retire ~workspace) @@ fun () ->
  (match Skill_catalog_snapshot_service.refresh ~workspace ~user_home:None
      ~read_config:(fun () -> {path=runtime_path;source_text=read runtime_path}) with
   | Published _ | Unchanged _ -> () | Workspace_retired -> fail "nested Skill workspace retired early");
  let snapshot = Skill_catalog_snapshot_service.current ~workspace
    |> function Some value -> value | None -> fail "published nested Skill snapshot missing" in
  let reference = match Skill_catalog_snapshot.entries snapshot with
    | [entry] -> Skill_catalog_snapshot.entry_reference entry | _ -> fail "one exact nested job Skill required" in
  let descriptors = Descriptor.all_descriptors () in
  let selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-A" [reference]
    |> require "original Task nested Skill selection" in
  let catalog,diagnostics = Masc.Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  check int "actual published nested job Skill has no projection error" 0 (List.length diagnostics);
  let surface = Surface.create_with_descriptors ~tool_descriptors:descriptors ~tool_deny:[]
      ~sandbox_profile:fixture.meta.sandbox_profile ~skill_names:None ~global_skill_catalog:catalog
      ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors snapshot)
      ~task_skills:(Masc.Keeper_task_skill_turn.skills selection) in
  let runtime = ref "original.runtime" and runtime_reads = ref 0 in
  let recorder = Recorder.make ~trace_id:fixture.meta.runtime.trace_id
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:41)
      ~runtime_id:(fun () -> incr runtime_reads; Some !runtime)
      ~snapshot_revision:(Surface.skill_snapshot_revision surface) ~task_selection:selection
    |> require "original nested job activation recorder" in
  let publication_recovery : Masc.Keeper_publication_recovery_availability.turn_context =
    {provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper} in
  let physical_turn_ref = Ids.Turn_ref.make
    ~trace_id:(Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) ~absolute_turn:73 in
  let delivery = Delivery.create ~base_path:fixture.base_path ~physical_turn_ref in
  let make_bundle () = Bundle.make_tool_bundle_for_capability_surface ~config ~meta:fixture.meta
      ~publication_recovery ~capability_surface:surface ~skill_activation_context:recorder
      ~composition_result_delivery:delivery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"nested owned-job fixture")
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:fixture.cell () in
  let fixture = {fixture with make_bundle} in
  operation ~env ~fixture ~config ~surface ~reference ~runtime ~runtime_reads
    ~publication_recovery ~physical_turn_ref ~delivery ~recorder ~snapshot

type child_export_selection = Stdout_only | Ordered_aliases | Without_exports

let test_fixed_async_skill_child ?(child_failure=false) ?(dynamic_arguments=false) ?(launch_in_child=false)
    ?(parent_tool_denied=false) ?(export_selection=Stdout_only) () =
  let exports = match export_selection with
    | Stdout_only -> ["stdout","consume","/content"]
    | Ordered_aliases ->
      ["z/stdout~","consume","/content";"a/bytes","consume","/total_bytes";
       "m/sha256","consume","/sha256"]
    | Without_exports -> [] in
  with_nested_job_skill ~wait_only:(not launch_in_child) ~parameterized:dynamic_arguments ~exports
    ~execution:Masc.Keeper_tool_composition_catalog.Async
  @@ fun ~env ~fixture ~config ~surface ~reference ~runtime ~runtime_reads
      ~publication_recovery ~physical_turn_ref:_ ~delivery:_ ~recorder:_ ~snapshot ->
  let module Async = Masc.Keeper_msg_async in
  let module Ledger = Masc.Keeper_skill_activation_ledger in
  let module Tools = Masc.Keeper_tool_composition_surface in
  let module Plan = Masc.Keeper_tool_plan in
  let module Surface = Masc.Keeper_capability_surface in
  let original_args,independent_bytes = if dynamic_arguments then
      let id = read (Filename.concat fixture.base_path "physical-original-job") in
      argument id,id
    else `Assoc [],"independent parent work\n" in
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:independent_bytes ~mime:"text/plain" in
  let child_arguments = if not dynamic_arguments then "args",`Assoc []
    else "input",`Assoc ["kind",`String "object";"fields",`List
      [`Assoc ["name",`String "job_id";"value",`Assoc
        ["kind",`String "output";"node",`String "sibling";"pointer",`String "/content"]]]] in
  let denial_probe = if parent_tool_denied then
      [`Assoc ["id",`String "denial-probe";"tool",`String "keeper_lane_status";
        "input",`Assoc ["kind",`String "literal";"value",`Assoc []]]] else [] in
  let dependent,export_node,export_pointer,expected_stdout = match export_selection with
    | Stdout_only -> [],"child","/stdout",stdout_bytes
    | Ordered_aliases ->
      [`Assoc ["id",`String "after-child";"tool",`String "keeper_artifact_read";
        "input",`Assoc ["kind",`String "object";"fields",`List
          [`Assoc ["name",`String "sha256";"value",`Assoc ["kind",`String "output";
            "node",`String "child";"pointer",`String "/m~1sha256"]]]]]],
      "child","/z~1stdout~0",stdout_bytes
    | Without_exports ->
      [`Assoc ["id",`String "after-child";"tool",`String "keeper_artifact_read";
        "after",`List [`String "child"];
        "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String sibling.sha256]]]],
      "after-child","/content",independent_bytes in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List (
      [`Assoc ["id",`String "sibling";"tool",`String "keeper_artifact_read";
          "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String sibling.sha256]]];
       `Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;child_arguments]] @ dependent @ denial_probe);
      "exports",`List [`Assoc ["name",`String "stdout";"node",`String export_node;"pointer",`String export_pointer]]] in
  let started = Mtime_clock.counter () in
  let backend_calls () = if Sys.file_exists fixture.daemon_path then List.length (calls fixture) else 0 in
  let backend_before_prepare = backend_calls () in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-fixed-async-child" ~turn:41 "keeper_composition_prepare" recipe) in
  check int "async child preparation has no backend effects" backend_before_prepare (backend_calls ());
  let draft = prepared |> member "draft" |> composition_reference "fixed async child draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-fixed-async-child" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String draft.sha256])) in
  let ok,waiting,parent_entry = await_composition env fixture accepted in
  check bool "parent releases its worker while the original child is pending" false ok;
  let binding = match parent_entry.status with
    | Async.Waiting_for_dependencies {dependencies=[Dependency.Composition_result binding];_} -> binding
    | _ -> fail "compiled child did not establish its exact canonical result wait" in
  let child_ok,child_wait,child_entry = await_composition env fixture
      (`Assoc ["request_id",`String binding.request_id]) in
  check bool "real async child releases its own worker on the original job" false child_ok;
  let id = match child_entry.status with
    | Async.Waiting_for_dependencies {dependencies=[dependency];_} -> dependency_job_id dependency
    | _ -> fail "fixed child did not run the actual owned job producer" in
  let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:binding.composition_run_id |> require "fixed original child journal" in
  (match (Journal.source child_journal).producer with
   | Journal.Named {skill_reference;activation=Some original;origin=(Nested _ as origin);_} ->
     check bool "child source retains the exact frozen Skill" true (Skill_reference.equal reference skill_reference);
     check_json "child source retains the resolved original arguments"
       original_args
       (Journal.named_origin_to_yojson origin |> member "args");
     check int "child retains original physical frame" 41
       (Ids.Turn_ref.absolute_turn (Masc.Keeper_skill_activation_recorder.bound_turn_ref original))
   | Named {origin=Standalone;_} | Named {activation=None;origin=Nested _;_} | Prepared ->
     fail "native child became a standalone or unsealed named submission");
  let ledger = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "original fixed child ledger" |> function Some value -> value | None -> fail "child has no actual Nested activation" in
  let activation = match Ledger.activations ledger with [activation] -> activation
    | _ -> fail "fixed child recorded duplicate or missing activation" in
  (match activation.invocation with Ledger.Nested_composition_invocation _ -> ()
   | Instruction_invocation _ | Composition_invocation _ -> fail "native producer re-recorded child as standalone composition");
  check string "logical child invocation is the actual original receipt" activation.skill_tool_use_id binding.parent_tool_use_id;
  let nodes = composition_nodes fixture waiting in
  check_json "independent parent work settles while child is pending" (`String "completed")
    (composition_node "[\"sibling\"]" nodes |> member "result" |> member "disposition");
  (match export_selection with
   | Stdout_only -> ()
   | Ordered_aliases | Without_exports ->
     check bool "dependent work does not start while canonical child result is pending" false
       (List.exists (fun node -> member "node_id" node = `String "[\"after-child\"]") nodes));
  let prepare_to_wait_ms = Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000. in
  let candidate journal = Journal.waiting_continuation journal |> require "original async continuation"
      |> function Some value -> value | None -> fail "original async result wait disappeared" in
  let child_continuation = candidate child_journal in
  let parent_run = accepted |> member "composition_run_id" |> to_string |> Plan.Composition_run_id.of_string
      |> require "original native parent identity" in
  let parent_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper ~composition_run_id:parent_run
      |> require "original native parent journal" in
  let parent_continuation = candidate parent_journal in
  check bool "pending canonical child keeps original parent suspended" true
    (Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      parent_continuation = Ok Journal.Waiting_for_results);
  set_source fixture ~task_id:"task-B" ~turn:52;
  runtime := "later.runtime";
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-fixed-child-job"
    ~turn:52 "keeper_job_status" (argument id)));
  let backend_after_result = List.length (calls fixture) in
  let resume ?(capability_surface=surface) continuation tool_use_id =
    let invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn:52
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
        ~completion:Agent_core.Tool_contract.Continue_after_success in
    Tools.resume_continuation ~capability_surface ~continuation ~config ~meta:fixture.meta
      ~publication_recovery ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"fresh fixed child supervisor")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation ~clock:(Eio.Stdenv.clock env) () in
  let recovery_started = Mtime_clock.counter () in
  let restore_output = if child_failure then (
      let stdout = match (load fixture id).outputs with
        | Some (Store.Outputs_complete (stdout,_)) -> stdout
        | Some (Store.Outputs_unavailable {evidence}) ->
          failf "original completed job output is unavailable: %s" evidence
        | None -> fail "original completed job has no canonical stdout" in
      let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:fixture.base_path) in
      let path = Filename.concat (Filename.concat root (String.sub stdout.sha256 0 2)) stdout.sha256 in
      let original = read path in
      Sys.remove path;
      fun () -> write path original)
    else fun () -> () in
  let child_ok,child_completed,_ = Fun.protect ~finally:restore_output (fun () ->
      let resumed_child = resume child_continuation "resume-original-fixed-child" in
      check bool "fresh supervisor accepts original child continuation" true (Tool_result.is_success resumed_child);
      check_json "child successor retains the original public binding" (Dependency.composition_to_json binding)
        (Tool_result.data resumed_child |> member "result_wait");
      await_composition env fixture (Tool_result.data resumed_child)) in
  check bool "actual canonical child outcome is preserved" (not child_failure) child_ok;
  let child_nodes = match export_selection with
    | Stdout_only | Ordered_aliases -> composition_nodes fixture child_completed
    | Without_exports ->
      check_json "canonical no-export child omits the export projection" `Null (member "exports" child_completed);
      child_completed |> member "actions" |> to_list in
  if launch_in_child then (
    check_json "completed child launch is retained on fresh continuation" (`String "retained_completion")
      (composition_node "launch" child_nodes |> member "execution_origin");
    check (option string) "child's own job keeps the original Task" (Some "task-A") (load fixture id).source.task_id);
  let previous_child_nodes = match export_selection with
    | Stdout_only | Ordered_aliases -> composition_nodes fixture child_wait
    | Without_exports -> child_wait |> member "settled" |> to_list in
  List.iter (fun field -> check_json ("original child job occurrence " ^ field)
      (composition_node "await" previous_child_nodes |> member field)
      (composition_node "await" child_nodes |> member field)) ["execution_id";"tool_use_id"];
  let parent_surface = if not parent_tool_denied then surface else (
      let descriptors = Descriptor.all_descriptors () in
      let selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-A" [reference]
          |> require "denied parent original Task selection" in
      let denied = Surface.create_with_descriptors ~tool_descriptors:descriptors
          ~tool_deny:["keeper_lane_status"] ~sandbox_profile:fixture.meta.sandbox_profile
          ~skill_names:None ~global_skill_catalog:(Surface.skill_catalog surface)
          ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot ~descriptors snapshot)
          ~task_skills:(Masc.Keeper_task_skill_turn.skills selection) in
      let ledger_path = Filename.concat (Masc.Keeper_fs.keeper_session_dir config
          (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id)) "skill-activation-events.jsonl" in
      let original_ledger = read ledger_path in
      Fun.protect ~finally:(fun () -> write ledger_path original_ledger) (fun () ->
        write ledger_path "unreadable original Nested activation\n";
        let refused = resume ~capability_surface:denied parent_continuation "refuse-unreadable-denied-parent" in
        check bool "proven Tool denial cannot bypass unavailable original child authority" true
          (Tool_result.is_failed refused));
      let retained = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
          ~composition_run_id:parent_run |> require "denied parent original journal"
          |> Journal.waiting_continuation |> require "unreadable child authority retains parent"
          |> function Some value -> value | None -> fail "unreadable original child authority closed the parent" in
      check string "temporary authority refusal keeps the original bound parent request"
        parent_entry.request_id (Journal.continuation_request_id retained);
      denied) in
  let resumed_parent = resume ~capability_surface:parent_surface parent_continuation "resume-original-fixed-parent" in
  check bool "whole canonical child result makes original parent ready" true (Tool_result.is_success resumed_parent);
  let parent_ok,completed,parent_completed = await_composition env fixture (Tool_result.data resumed_parent) in
  check bool "native result barrier preserves actual whole-child failure"
    (not child_failure && not parent_tool_denied) parent_ok;
  if parent_tool_denied then (
    check_json "denied parent settles a typed permanent refusal" (`String "current_tool_denied")
      (completed |> member "kind");
    check_json "permanent refusal names the exact denied ordinary Tool" (`String "keeper_lane_status")
      (completed |> member "tool_name");
    (match parent_completed.status with
     | Async.Done {ok=false;_} -> ()
     | _ -> fail "denied nested parent did not reach canonical terminal failure");
    check bool "permanent refusal has a new physical successor" true
      (parent_completed.request_id <> parent_entry.request_id);
    let predecessor = Async.load_canonical_durable_terminal ~base_path:fixture.base_path
        ~caller:keeper parent_entry.request_id |> require "immutable nested parent predecessor"
        |> Async.durable_terminal_entry in
    (match predecessor.status with
     | Async.Waiting_for_dependencies _ -> ()
     | _ -> fail "permanent refusal rewrote the original waiting predecessor");
    let discovery = Journal.pending_continuations
        ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
        ~base_path:fixture.base_path |> require "terminal denied parent discovery" in
    check bool "permanent refusal never re-readies the original parent" false
      (List.exists (fun continuation ->
        (Journal.continuation_source continuation).composition_run_id = parent_run) discovery.ready))
  else (
  if child_failure then
    check_json "failed canonical child provides no successful parent export" (`Bool false)
      (completed |> member "exports" |> member "stdout" |> member "available")
  else
    check_json "parent consumes exact completed dependency output" (`String expected_stdout)
      (completed |> member "exports" |> member "stdout" |> member "value");
  let completed_nodes = composition_nodes fixture completed in
  let scope = prepared |> member "nested_calls" |> to_list |> List.hd |> member "scope" in
  let submission_id = scope |> member "submission" |> to_string in
  (match export_selection with
   | Stdout_only -> ()
   | Ordered_aliases | Without_exports ->
     let selected = composition_node (scope |> member "result" |> to_string) completed_nodes
         |> member "result" |> member "data" in
     (match export_selection with
      | Stdout_only -> fail "expected an explicit export scenario"
      | Ordered_aliases ->
        check (list string) "native result preserves declared export order and exact escaped names"
          ["z/stdout~";"a/bytes";"m/sha256"] (selected |> to_assoc |> List.map fst);
        check_json "selected string value remains complete" (`String stdout_bytes) (member "z/stdout~" selected);
        check_json "selected integer value keeps its type" (`Int (String.length stdout_bytes)) (member "a/bytes" selected);
        let consumed = composition_node "consume" child_nodes |> member "result" |> member "data" in
        check_json "selected artifact identity belongs to the completed child"
          (member "sha256" consumed) (member "m/sha256" selected)
      | Without_exports -> check_json "native no-export result is an empty object" (`Assoc []) selected);
     let dependent = composition_node "[\"after-child\"]" completed_nodes in
     check_json "canonical result releases the actual dependent handler" (`String "completed")
       (dependent |> member "result" |> member "disposition");
     check_json "dependent handler reads the selected original artifact" (`String expected_stdout)
       (dependent |> member "result" |> member "data" |> member "content"));
  List.iter (fun field -> check_json ("original parent submission occurrence " ^ field)
      (composition_node submission_id nodes |> member field)
      (composition_node submission_id completed_nodes |> member field)) ["execution_id";"tool_use_id"];
  check_json "accepted child submission is retained rather than resubmitted" (`String "retained_completion")
    (composition_node submission_id completed_nodes |> member "execution_origin"));
  check int "fresh child and parent use no backend after canonical output" backend_after_result (List.length (calls fixture));
  check int "fixed child creates one job" 1 (effect_count fixture "create");
  check int "fixed child starts one job" 1 (effect_count fixture "start");
  check int "native submission and continuation read original runtime once" 1 !runtime_reads;
  let final_ledger = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "final original Nested receipt" |> function Some value -> value | None -> fail "original receipt was removed" in
  check bool "all continuations retain exact original Nested activation" true
    (Ledger.activations ledger = Ledger.activations final_ledger);
  check_json "parent result remains attached to original Task" (`String "task-A")
    (match parent_completed.request_context with Some fields -> List.assoc "source_task_id" fields
      | None -> fail "completed parent source missing");
  Printf.eprintf "%s_ASYNC_CHILD_MEASURE prepare_to_wait_ms=%.3f recovery_ms=%.3f creates=%d starts=%d runtime_reads=%d\n%!"
    (if launch_in_child then "OWNED_LAUNCH" else if dynamic_arguments then "UPSTREAM" else "FIXED")
    prepare_to_wait_ms (Mtime.Span.to_float_ns (Mtime_clock.count recovery_started) /. 1_000_000.)
    (effect_count fixture "create") (effect_count fixture "start") !runtime_reads

let test_upstream_arguments_reject_before_child_activation () =
  with_nested_job_skill ~wait_only:true ~parameterized:true ~execution:Masc.Keeper_tool_composition_catalog.Async
  @@ fun ~env ~fixture ~config ~surface:_ ~reference ~runtime:_ ~runtime_reads:_
      ~publication_recovery:_ ~physical_turn_ref:_ ~delivery:_ ~recorder:_ ~snapshot:_ ->
  let original_job = read (Filename.concat fixture.base_path "physical-original-job") in
  let output = `Assoc ["kind",`String "output";"node",`String "arguments";"pointer",`String "/content"] in
  let object_ fields = `Assoc ["kind",`String "object";"fields",`List
      (List.map (fun (name,value) -> `Assoc ["name",`String name;"value",value]) fields)] in
  List.iter (fun (label,bytes,input) ->
    let blob = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
        ~bytes ~mime:"text/plain" in
    let recipe = `Assoc ["execution",`String "async";"nodes",`List
      [`Assoc ["id",`String "arguments";"tool",`String "keeper_artifact_read";
        "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String blob.sha256]]];
       `Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;"input",input]]] in
    let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
        ~tool_use_id:("prepare-rejected-" ^ label) ~turn:41 "keeper_composition_prepare" recipe) in
    let draft = prepared |> member "draft" |> composition_reference "deferred child arguments draft" in
    let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
        ~tool_use_id:("run-rejected-" ^ label) ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String draft.sha256])) in
    let ok,_,_ = await_composition env fixture accepted in
    check bool (label ^ " is rejected by the actual running parent") false ok;
    let activations = Masc.Keeper_skill_activation_ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
        |> require "canonical activation observation after invalid arguments"
        |> function None -> [] | Some ledger -> Masc.Keeper_skill_activation_ledger.activations ledger in
    check int (label ^ " creates no child activation") 0 (List.length activations))
    ["enum","wrong-original-job",object_ ["job_id",output];
     "object-type",original_job,output;
     "extra-field",original_job,object_ ["job_id",output;"extra",output]];
  check int "invalid arguments never create another job" 1 (effect_count fixture "create");
  check int "invalid arguments never start another job" 1 (effect_count fixture "start")

let test_public_upstream_inline_arguments ~reject () =
  let cases = if reject then ["enum";"object-type";"extra-field"] else ["valid"] in
  List.iter (fun label ->
  with_nested_job_skill ~wait_only:true ~parameterized:true ~execution:Masc.Keeper_tool_composition_catalog.Inline
  @@ fun ~env:_ ~fixture ~config ~surface:_ ~reference ~runtime:_ ~runtime_reads
      ~publication_recovery:_ ~physical_turn_ref:_ ~delivery:_ ~recorder:_ ~snapshot:_ ->
  let module Ledger = Masc.Keeper_skill_activation_ledger in
  let id = read (Filename.concat fixture.base_path "physical-original-job") in
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-original-inline-result"
    ~turn:41 "keeper_job_status" (`Assoc ["job_id",`String id])) |> ignore;
  let backend_at_ready = List.length (calls fixture) in
  let bytes = if label = "enum" then "wrong-original-job" else id in
  let blob = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path) ~bytes ~mime:"text/plain" in
  let output = `Assoc ["kind",`String "output";"node",`String "arguments";"pointer",`String "/content"] in
  let fields = ["job_id",output] @ if label = "extra-field" then ["extra",output] else [] in
  let input = if label = "object-type" then output else
      `Assoc ["kind",`String "object";"fields",`List
        (List.map (fun (name,value) -> `Assoc ["name",`String name;"value",value]) fields)] in
  let recipe = `Assoc ["execution",`String "inline";"nodes",`List
      [`Assoc ["id",`String "arguments";"tool",`String "keeper_artifact_read";
        "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String blob.sha256]]];
       `Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;"input",input]];
      "exports",`List [`Assoc ["name",`String "stdout";"node",`String "child";"pointer",`String "/stdout"]]] in
  let started = Mtime_clock.counter () in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-public-upstream-inline" ~turn:41 "keeper_composition_prepare" recipe) in
  let activations () = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "inline original activation authority"
      |> function None -> [] | Some ledger -> Ledger.activations ledger in
  check int "inline prepare never activates the child" 0 (List.length (activations ()));
  check int "inline prepare has no backend calls" backend_at_ready (List.length (calls fixture));
  let draft = prepared |> member "draft" |> composition_reference "public upstream inline draft" in
  let result = with_bundle fixture (fun bundle -> invoke_raw bundle
      ~tool_use_id:"run-public-upstream-inline" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String draft.sha256])) in
  (match reject,result with
   | true,Error _ ->
     check int (label ^ " is rejected before child activation") 0 (List.length (activations ()));
     check int "invalid inline arguments never select a runtime" 0 !runtime_reads
   | false,Ok output ->
     let completed = result_document ~base_path:fixture.base_path output.Agent_core.Types.content in
     check_json "inline parent returns the original full selected export" (`String stdout_bytes)
       (completed |> member "exports" |> member "stdout" |> member "value");
     check int "valid inline arguments activate exactly one child" 1 (List.length (activations ()));
     check int "valid inline child binds its runtime once" 1 !runtime_reads;
     let argument_id = prepared |> member "nested_calls" |> to_list |> List.hd
       |> member "scope" |> member "argument_node" |> to_string in
     check_json "public inline evidence retains the actual validated input" (`Assoc ["job_id",`String id])
       (composition_nodes fixture completed |> composition_node argument_id |> member "input");
     check bool "inline completion does not become an async submission" true (member "request_id" completed = `Null)
   | true,Ok _ -> failf "%s reached public inline success" label
   | false,Error error -> failf "valid public inline arguments failed: %s" error.Agent_core.Types.message);
  check int "canonical inline reads need no backend dispatch" backend_at_ready (List.length (calls fixture));
  check int "inline argument binding creates no additional job" 1 (effect_count fixture "create");
  check int "inline argument binding starts no additional job" 1 (effect_count fixture "start");
  Printf.eprintf "UPSTREAM_INLINE_MEASURE case=%s prepare_to_result_ms=%.3f creates=%d starts=%d runtime_reads=%d\n%!"
    label (Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000.)
    (effect_count fixture "create") (effect_count fixture "start") !runtime_reads) cases

let lose_native_parent_after_child_acceptance base_path draft_sha run_id =
  with_nested_job_skill ~fixture_base_path:base_path ~wait_only:true ~parameterized:true
    ~branch_failure_policy:Masc.Keeper_tool_plan.Continue_independent
    ~execution:Masc.Keeper_tool_composition_catalog.Async
  @@ fun ~env ~fixture ~config ~surface ~reference:_ ~runtime:_ ~runtime_reads
      ~publication_recovery ~physical_turn_ref:_ ~delivery:_ ~recorder ~snapshot:_ ->
  let module Async = Masc.Keeper_msg_async in
  let module Draft = Masc.Keeper_composition_draft in
  let module Plan = Masc.Keeper_tool_plan in
  let draft = Draft.load ~base_path ~capability_surface:surface ~keeper_name:keeper ~sha256:draft_sha
      |> require "physical child loads actual original draft" in
  let composition_run_id = Plan.Composition_run_id.of_string run_id |> require "physical parent run ID" in
  let source_invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:"original-native-parent"
      ~turn:41 ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let bound = Masc.Keeper_skill_activation_recorder.bind_async recorder |> require "original physical recorder" in
  let run_reference = Draft.record_invocation ~base_path ~nested_activation:bound ~composition_run_id
      ~invocation:source_invocation draft |> require "physical parent immutable source" in
  let source : Journal.source = {keeper_name=keeper;composition_run_id;draft_reference=Draft.reference draft;
    run_reference;parent_tool_use_id="original-native-parent";source_turn=41;source_task_id=Some "task-A";
    producer=Journal.Prepared} in
  let journal = Journal.prepare ~base_path source |> require "physical actual parent journal" in
  let request_context = ["composition_tool",`String Draft.run_tool_name;
    "composition_run_id",`String run_id;
    "draft_reference",Tool_output.normalized_artifact_ref_to_json source.draft_reference;
    "run_artifact",Tool_output.normalized_artifact_ref_to_json source.run_reference;
    "parent_tool_use_id",`String source.parent_tool_use_id;"source_turn",`Int source.source_turn;
    "source_task_id",`String "task-A"] in
  let worker = Atomic.make None in
  let accepted = Async.submit_worker_with_request_id ~request_context
      ~background_sw:(Async.server_background_switch () |> require "physical actual broker switch")
      ~base_path ~caller:keeper ~keeper_name:keeper
      ~on_accepted:(fun request_id -> Journal.bind_request journal ~request_id
        |> Result.map (fun bound -> Atomic.set worker (Some bound)) |> Result.map_error Journal.error_to_string)
      ~f:(fun ~request_id request_sw ->
        let worker = match Atomic.get worker with Some worker -> worker | None -> fail "physical parent not actually bound" in
        Masc.Keeper_tool_composition_surface.For_testing.async_worker_result
          ~composition_execution:Masc.Keeper_tool_composition_catalog.Async ~tool_kind:Descriptor.Async_composition_tool
          ~nested_calls:(Draft.nested_calls draft) ~nested_activation:bound ~plan:(Draft.plan draft) ~journal:worker
          ~tool_name:Draft.run_tool_name ~request_id ~composition_run_id ~source_invocation ~request_sw ~config
          ~meta:fixture.meta ~capability_authority:(Masc.Keeper_tool_runtime.Frozen_surface surface)
          ~publication_recovery ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"physical accepted child loss")
          ~turn_context:(Some (Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ()))
          ~after_child_submission:(fun result ->
            check bool "loss follows actual successful child acceptance" true (Tool_result.is_success result);
            let binding = Tool_result.data result |> member "result_wait" in
            ignore (Dependency.composition_of_json binding |> require "actual accepted child binding before process loss");
            write (Filename.concat base_path "physical-native-acceptance.json")
              (Yojson.Safe.to_string (`Assoc ["parent_request_id",`String request_id;"child_binding",binding;
                "original_runtime_reads",`Int !runtime_reads]));
            (* Real process death after the protected child callback, before
               Executor can append the parent submission settlement or wait. *)
            Unix._exit 0)
          ~clock:(Eio.Stdenv.clock env) ()) () |> require "physical original parent submission" in
  ignore (await_composition env fixture (`Assoc ["request_id",`String accepted.request_id]));
  fail "physical accepted-child fault did not stop its process"

let test_typed_continuation_recovery () =
  let module Recovery = Masc.Keeper_tool_composition_surface.For_testing in
  let failed class_ = Tool_result.make_err ~tool_name:"fixture-child" ~start_time:(Tool_timing.start ())
      ~class_ "original child refused" in
  let decision class_ effect_disposition =
    Recovery.continuation_recovery_of_result ~effect_disposition (failed class_) in
  let is_held = function
    | Recovery.Hold_original_authority _ -> true
    | Recovery.Complete_original_result -> false in
  List.iter (fun class_ ->
    check bool "proven pre-effect policy/workflow refusal terminates" false
      (is_held (decision class_ (Some Tool_result.Proven_pre_effect)));
    List.iter (fun disposition ->
      check bool "policy wording never terminates unknown or possible effects" true
        (is_held (decision class_ disposition)))
      [None; Some Tool_result.Effect_outcome_unknown; Some Tool_result.Proven_post_effect])
    [Tool_result.Policy_rejection; Tool_result.Workflow_rejection];
  List.iter (fun class_ ->
    check bool "runtime/dependency/cancellation cause holds original authority" true
      (is_held (decision class_ (Some Tool_result.Proven_pre_effect))))
    [Tool_result.Runtime_failure; Tool_result.Dependency_unavailable; Tool_result.Operator_cancelled];
  let permanent = decision Tool_result.Policy_rejection (Some Tool_result.Proven_pre_effect)
  and uncertain = decision Tool_result.Workflow_rejection (Some Tool_result.Effect_outcome_unknown) in
  check bool "uncertain parallel cause dominates an earlier permanent refusal" true
    (is_held (Recovery.combine_recovery permanent uncertain));
  check bool "uncertain parallel cause dominates a later permanent refusal" true
    (is_held (Recovery.combine_recovery uncertain permanent))

let test_native_child_acceptance_survives_physical_parent_loss () =
  with_nested_job_skill ~wait_only:true ~parameterized:true ~execution:Masc.Keeper_tool_composition_catalog.Async
    ~branch_failure_policy:Masc.Keeper_tool_plan.Continue_independent
  @@ fun ~env ~fixture ~config ~surface ~reference ~runtime ~runtime_reads
      ~publication_recovery ~physical_turn_ref:_ ~delivery:_ ~recorder:_ ~snapshot:_ ->
  let module Async = Masc.Keeper_msg_async in
  let module Plan = Masc.Keeper_tool_plan in
  let original_job = read (Filename.concat fixture.base_path "physical-original-job") in
  let sibling = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
      ~bytes:original_job ~mime:"text/plain" in
  let recipe = `Assoc ["execution",`String "async";"branch_failure_policy",`String "continue_independent";
    "nodes",`List
    [`Assoc ["id",`String "earlier-wait";"tool",`String "keeper_job_result";
       "input",`Assoc ["kind",`String "literal";"value",argument original_job]];
     `Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;
       "input",`Assoc ["kind",`String "object";"fields",`List
         [`Assoc ["name",`String "job_id";"value",`Assoc
           ["kind",`String "output";"node",`String "sibling";"pointer",`String "/content"]]]]];
     `Assoc ["id",`String "sibling";"tool",`String "keeper_artifact_read";
       "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String sibling.sha256]]]];
    "exports",`List [`Assoc ["name",`String "stdout";"node",`String "child";"pointer",`String "/stdout"]]] in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"physical-prepare"
      ~turn:41 "keeper_composition_prepare" recipe) in
  let draft = prepared |> member "draft" |> composition_reference "physical native draft" in
  let run_id = Plan.Composition_run_id.fresh () in
  Eio.Process.run (Eio.Stdenv.process_mgr env)
    [Sys.executable_name;"--lose-native-parent-after-child-acceptance";fixture.base_path;draft.sha256;
      Plan.Composition_run_id.to_string run_id];
  let proof = Filename.concat fixture.base_path "physical-native-acceptance.json" |> read |> Yojson.Safe.from_string in
  let binding_json = proof |> member "child_binding" in
  let binding = Dependency.composition_of_json binding_json |> require "physical original child binding" in
  let parent_request = proof |> member "parent_request_id" |> to_string in
  check_json "physical process bound original runtime once" (`Int 1) (member "original_runtime_reads" proof);
  let recovered = Async.recover_lost_disk_records ~base_path:fixture.base_path () in
  check bool "actual startup recovery finds the interrupted worker" true (recovered.lost > 0);
  let terminal = Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper parent_request
      |> require "physical parent canonical terminal proof" |> Async.durable_terminal_entry in
  (match terminal.status with Lost _ -> () | _ -> fail "physical parent did not become original canonical Lost");
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper ~composition_run_id:run_id
      |> require "original physically interrupted journal" in
  let candidate journal = Journal.waiting_continuation journal |> require "physical original continuation"
      |> function Some value -> value | None -> fail "actual accepted child lost parent recovery" in
  let continuation = candidate journal in
  check int "acceptance recovery has no fabricated prior result wait" 0 (List.length (Journal.continuation_dependencies continuation));
  check bool "committed acceptance is immediately recoverable while original job is pending" true
    (Journal.continuation_readiness ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      continuation = Ok Journal.Results_ready);
  set_source fixture ~task_id:"task-B" ~turn:52;
  runtime := "fresh.runtime";
  let resume continuation tool_use_id =
    Masc.Keeper_tool_composition_surface.resume_continuation ~capability_surface:surface ~continuation
      ~config ~meta:fixture.meta ~publication_recovery
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"fresh physical child recovery")
      ~turn_context:(Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
      ~invocation:(Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn:52
        ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Concurrent}
        ~completion:Agent_core.Tool_contract.Continue_after_success)
      ~clock:(Eio.Stdenv.clock env) () in
  let scope = prepared |> member "nested_calls" |> to_list |> List.hd |> member "scope" in
  let submission_id = scope |> member "submission" |> to_string
  and result_id = scope |> member "result" |> to_string in
  let fault_continuation continuation fault =
    let module Draft = Masc.Keeper_composition_draft in
    let source = Journal.continuation_source continuation in
    let draft = Draft.load_continuation ~base_path:fixture.base_path ~capability_surface:surface continuation
        |> require "original ACK-ready draft before post-acceptance authority fault" in
    let bound = Draft.load_nested_activation ~base_path:fixture.base_path source
        |> require "original ACK-ready recorder" |> function Some bound -> bound
        | None -> fail "ACK-ready source lost its original recorder" in
    let events = Filename.concat
        (Masc.Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id))
        "skill-activation-events.jsonl" in
    let journal_file = Filename.concat
        (Filename.concat
          (Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path)
            "keeper_msg_requests") "execution_journals")
          Digestif.SHA256.(digest_string keeper |> to_hex))
        (Plan.Composition_run_id.to_string run_id ^ ".jsonl") in
    let blob_root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:fixture.base_path) in
    let draft_file = Filename.concat
        (Filename.concat blob_root (String.sub source.draft_reference.sha256 0 2))
        source.draft_reference.sha256 in
    let restore = ref (fun () -> ()) in
    let faulted = ref false in
    let corrupt path =
      check bool "one actual authority boundary is corrupted" false !faulted;
      let original = read path in
      restore := (fun () -> write path original);
      faulted := true;
      write path "invalid-original-authority-after-accepted-continuation\n" in
    let interrupt_publication () =
      check bool "one actual publication boundary is interrupted" false !faulted;
      let original_root = blob_root ^ ".original-before-publication" in
      check bool "publication backup does not replace existing evidence" false (Sys.file_exists original_root);
      Sys.rename blob_root original_root;
      restore := (fun () -> if Sys.file_exists blob_root then Sys.remove blob_root;
        Sys.rename original_root blob_root);
      faulted := true;
      write blob_root "temporarily unavailable artifact directory\n" in
    let refused_result = ref false and held_request = ref None in
    let fault_request = Fun.protect ~finally:(fun () -> !restore ()) (fun () ->
      let worker = Atomic.make None in
      let settled,notify_settled = Eio.Promise.create () in
      let accepted = Async.submit_worker_with_request_id ?request_context:terminal.request_context
          ~background_sw:(Async.server_background_switch () |> require "ACK-ready accepted worker fault switch")
          ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
          ~on_accepted:(fun request_id ->
            let ( let* ) = Result.bind in
            let* () = Masc.Keeper_composition_completion_outbox.prepare ~base_path:fixture.base_path
                ~keeper_name:keeper ~request_id ~composition_tool:Draft.run_tool_name
              |> Result.map_error Masc.Keeper_composition_completion_outbox.error_to_string in
            Journal.bind_continuation continuation ~request_id
            |> Result.map (fun admitted -> Atomic.set worker (Some admitted);
              if fault = `Before_restore then corrupt events)
            |> Result.map_error Journal.error_to_string)
          ~on_worker_settled:(fun settlement ->
            Masc.Keeper_composition_completion_wake.on_worker_settled ~base_path:fixture.base_path
              ~composition_tool:Draft.run_tool_name settlement;
            Eio.Promise.resolve notify_settled ())
          ~f:(fun ~request_id request_sw ->
            let worker = match Atomic.get worker with Some worker -> worker | None -> fail "fault worker not actually bound" in
            Masc.Keeper_tool_composition_surface.For_testing.async_worker_result
              ~composition_execution:Masc.Keeper_tool_composition_catalog.Async ~tool_kind:Descriptor.Async_composition_tool
              ~nested_calls:(Draft.nested_calls draft) ~nested_activation:bound ~continuation
              ~on_recovery_held:(fun ~request_id ~reason:_ -> held_request := Some request_id)
              ?before_child_dispatch:(if fault = `Before_native then Some (fun () -> corrupt events) else None)
              ?before_plan_execution:(if fault = `Before_plan then Some (fun () -> corrupt draft_file) else None)
              ?after_child_submission:(if fault = `Before_submission_settle
                then Some (fun _ -> corrupt journal_file) else None)
              ?before_child_submission_publication:(if fault = `Before_submission_publication
                then Some interrupt_publication else None)
              ?before_child_result_publication:(if fault = `Before_result_publication
                then Some interrupt_publication else None)
              ?after_node_observation:(if fault = `Before_result_lookup then Some (fun node ->
                if Plan.Node_id.to_string node.Masc.Keeper_tool_plan_executor.node_id = submission_id
                then corrupt journal_file;
                if Plan.Node_id.to_string node.node_id = result_id then
                  match node.execution_origin with
                  | Masc.Keeper_tool_plan_executor.Dispatch_refused -> refused_result := true
                  | Fresh_dispatch | Retained_completion -> ()) else None)
              ~plan:(Draft.plan draft) ~journal:worker ~tool_name:Draft.run_tool_name
              ~request_id ~composition_run_id:run_id ~request_sw ~config ~meta:fixture.meta
              ~source_invocation:(Agent_core.Tool_contract.Invocation.create ~tool_use_id:source.parent_tool_use_id
                ~turn:source.source_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
                ~completion:Agent_core.Tool_contract.Continue_after_success)
              ~capability_authority:(Masc.Keeper_tool_runtime.Frozen_surface surface) ~publication_recovery
              ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"ACK-ready authority fault")
              ~turn_context:(Some { (Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell ())
                with task_id=source.source_task_id }) ~clock:(Eio.Stdenv.clock env) ()) ()
        |> require "real ACK-ready acceptance before transient authority fault" in
      let rec read_loss () = match Async.load_canonical_durable_terminal ~base_path:fixture.base_path ~caller:keeper accepted.request_id with
        | Ok proof -> (match (Async.durable_terminal_entry proof).status with
            | Lost _ -> () | _ -> fail "transient ACK-ready authority fault became logical completion")
        | Error (Canonical_terminal_absent | Canonical_terminal_runtime_active _) -> Eio.Fiber.yield (); read_loss ()
        | Error error -> fail (Async.canonical_terminal_error_to_string error) in
      read_loss ();
      Eio.Promise.await settled;
      check (option string) "held recovery reports the actual accepted physical owner"
        (Some accepted.request_id) !held_request;
      check bool "the actual accepted worker reaches the selected fault boundary" true !faulted;
      if fault = `Before_result_lookup then
        check bool "actual native result lookup is refused by its unreadable journal" true !refused_result;
      accepted.request_id) in
    let recovery = Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
        |> require "recover original physical attempt completion obligations" in
    if fault <> `Before_result_publication then
      check int "recovery publishes no false logical completion" 0 recovery.delivered;
    check int "original recovery authority is now readable" 0 (List.length recovery.failures);
    check bool "recoverable physical attempt enqueues no logical completion" false
      (List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
        match selection.source.payload with
        | Keeper_event_queue.Composition_completed completion ->
          String.equal completion.cc_request_id fault_request
        | _ -> false) (pending_completions fixture));
    let retained = candidate journal in
    check string "transient authority fault keeps the accepted physical owner recoverable" fault_request
      (Journal.continuation_request_id retained);
    check_json "authority fault retains the exact original dependency wait"
      (`List (List.map Dependency.to_json (Journal.continuation_dependencies continuation)))
      (`List (List.map Dependency.to_json (Journal.continuation_dependencies retained)));
    retained in
  let continuation = List.fold_left fault_continuation continuation
      [`Before_restore;`Before_native;`Before_plan;`Before_submission_publication;
      `Before_submission_settle;`Before_result_lookup] in
  let resumed = resume continuation "recover-physical-parent-ack" in
  check bool "fresh parent recovers actual acknowledgement" true (Tool_result.is_success resumed);
  let ok,pending,entry = await_composition env fixture (Tool_result.data resumed) in
  check bool "recovered acknowledgement is not mistaken for child completion" false ok;
  (match entry.status with
   | Waiting_for_dependencies {dependencies;_} ->
     check int "both independently pending producers are retained" 2 (List.length dependencies);
     check bool "first real result wait retains original accepted child" true
       (List.exists (function Dependency.Composition_result original ->
          Yojson.Safe.equal binding_json (Dependency.composition_to_json original)
         | Owned_job _ -> false) dependencies);
     check bool "lower planned owned-job wait is not lost behind child admission" true
       (List.exists (function Dependency.Owned_job id -> Store.Job_id.to_string id = original_job
         | Composition_result _ -> false) dependencies)
   | _ -> fail "parent did not park on both original producers");
  check_json "independent parent work proceeds before child completion" (`String "completed")
    (composition_node "[\"sibling\"]" (composition_nodes fixture pending) |> member "result" |> member "disposition");
  let child_journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:binding.composition_run_id |> require "same physically interrupted child journal" in
  let original_origin = match (Journal.source child_journal).producer with
    | Journal.Named {origin=(Nested _ as origin);_} -> Journal.named_origin_to_yojson origin
    | _ -> fail "physical child lost original producer origin" in
  check_json "physical loss and recovery preserve the resolved upstream job argument"
    (argument original_job) (member "args" original_origin);
  let original_ledger = Masc.Keeper_skill_activation_ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "physical original child receipt" |> function Some ledger -> ledger
      | None -> fail "physical child has no original ledger" in
  check int "physical child is activated exactly once" 1
    (List.length (Masc.Keeper_skill_activation_ledger.activations original_ledger));
  check_json "native accepted child still belongs to original Nested source"
    (Skill_reference.to_yojson reference) (match (Journal.source child_journal).producer with
      | Journal.Named {origin=Nested _;skill_reference;_} -> Skill_reference.to_yojson skill_reference
      | _ -> fail "physical recovery invented standalone child");
  let id = read (Filename.concat fixture.base_path "physical-original-job") in
  control_job fixture id (`Assoc ["state",`String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"collect-physical-original-job"
      ~turn:52 "keeper_job_status" (argument id)));
  let backend = List.length (calls fixture) in
  let child_resumed = resume (candidate child_journal) "resume-physical-original-child" in
  check bool "original child continues without resubmission" true (Tool_result.is_success child_resumed);
  let child_ok,_,_ = await_composition env fixture (Tool_result.data child_resumed) in
  check bool "original child reaches canonical whole result" true child_ok;
  let continuation = fault_continuation (candidate journal) `Before_result_publication in
  let canonical_child = Journal.named_result_owner child_journal binding |> require "original successful child remains readable" in
  (match canonical_child.status with Done {ok=true;_} -> ()
   | _ -> fail "reader publication fault changed the actual successful child");
  let parent_resumed = resume continuation "finish-physical-original-parent" in
  let parent_ok,completed,_ = await_composition env fixture (Tool_result.data parent_resumed) in
  check bool "original parent finishes after true child result" true parent_ok;
  check_json "recovered child exports complete original output" (`String stdout_bytes)
    (completed |> member "exports" |> member "stdout" |> member "value");
  let submission_id = original_origin |> member "parent_node_id" |> to_string in
  let submission = composition_node submission_id (composition_nodes fixture completed) in
  check_json "recovered submission retains the exact original resolved input"
    (argument original_job) (member "input" submission);
  check_json "recovered parent acknowledgement retains original execution ID"
    (original_origin |> member "parent_execution_id") (member "execution_id" submission);
  check_json "recovered parent acknowledgement retains original tool-use ID"
    (original_origin |> member "parent_occurrence_tool_use_id") (member "tool_use_id" submission);
  let final_ledger = Masc.Keeper_skill_activation_ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "physical final original child receipt" |> function Some ledger -> ledger
      | None -> fail "physical recovery removed original ledger" in
  check bool "physical recovery never reactivates original Nested child" true
    (Masc.Keeper_skill_activation_ledger.activations original_ledger = Masc.Keeper_skill_activation_ledger.activations final_ledger);
  check int "physical recovery never creates replacement job" 1 (effect_count fixture "create");
  check int "physical recovery never restarts original job" 1 (effect_count fixture "start");
  check int "canonical result recovery performs zero further backend calls" backend (List.length (calls fixture));
  check int "fresh process uses sealed original runtime without current callback" 0 !runtime_reads

let test_nested_skill_job_continuation ?(fault_after_acceptance=false) ?(dynamic_arguments=false) () =
  with_nested_job_skill ~wait_only:dynamic_arguments ~parameterized:dynamic_arguments
    ~execution:Masc.Keeper_tool_composition_catalog.Inline
  @@ fun ~env ~fixture ~config ~surface ~reference ~runtime ~runtime_reads
      ~publication_recovery ~physical_turn_ref ~delivery ~recorder:_ ~snapshot ->
  let module Async = Masc.Keeper_msg_async in
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Ledger = Masc.Keeper_skill_activation_ledger in
  let module Delivery = Masc.Keeper_composition_result_delivery in
  let module Async_delivery = Masc.Keeper_skill_async_delivery in
  let module Recorder = Masc.Keeper_skill_activation_recorder in
  let module Surface = Masc.Keeper_capability_surface in
  let argument_nodes,child_input = if dynamic_arguments then (
    let id = read (Filename.concat fixture.base_path "physical-original-job") in
    let blob = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
        ~bytes:id ~mime:"text/plain" in
    [`Assoc ["id",`String "arguments";"tool",`String "keeper_artifact_read";
      "input",`Assoc ["kind",`String "literal";"value",`Assoc ["sha256",`String blob.sha256]]]],
    ("input",`Assoc ["kind",`String "object";"fields",`List
      [`Assoc ["name",`String "job_id";"value",`Assoc ["kind",`String "output";
        "node",`String "arguments";"pointer",`String "/content"]]]]))
    else [],("args",`Assoc []) in
  let backend_before_prepare = if dynamic_arguments then List.length (calls fixture) else 0 in
  let recipe = `Assoc ["execution",`String "async";"nodes",`List
      (argument_nodes @ [`Assoc ["id",`String "child";"skill_reference",Skill_reference.to_yojson reference;child_input]]);
      "exports",`List [`Assoc ["name",`String "stdout";"node",`String "child";"pointer",`String "/stdout"]]] in
  let prepare_started = Mtime_clock.counter () in
  let prepared = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"prepare-nested-job" ~turn:41 "keeper_composition_prepare" recipe) in
  if dynamic_arguments then
    check int "dynamic inline prepare has no backend calls" backend_before_prepare (List.length (calls fixture))
  else check bool "nested prepare never launches a program" false (Sys.file_exists fixture.daemon_path);
  let before_activation = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
    |> require "preparation activation authority" in
  check int "nested preparation activates no child" 0
    (Option.fold ~none:0 ~some:(fun ledger -> List.length (Ledger.activations ledger)) before_activation);
  let draft = prepared |> member "draft" |> composition_reference "nested owned-job draft" in
  let accepted = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"run-nested-job" ~turn:41 "keeper_composition_run" (`Assoc ["sha256",`String draft.sha256])) in
  let ok,waiting,waiting_entry = await_composition env fixture accepted in
  let prepare_to_wait_ms = Mtime.Span.to_float_ns (Mtime_clock.count prepare_started) /. 1_000_000. in
  check bool "nested owned job suspends its original parent" false ok;
  let id = match waiting_entry.status with
    | Async.Waiting_for_dependencies {dependencies=[id];_} -> dependency_job_id id
    | _ -> fail "nested child did not produce one exact owned-job wait" in
  let run_id = accepted |> member "composition_run_id" |> to_string in
  let journal = Journal.load ~base_path:fixture.base_path ~keeper_name:keeper
      ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.of_string run_id |> require "nested original run")
    |> require "nested original journal" in
  let candidate () = match Journal.waiting_continuation journal with
    | Ok (Some candidate) -> candidate | Ok None | Error _ -> fail "nested original wait lost authority" in
  let original_activation = match Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "nested child actual activation" with
    | Some ledger -> (match Ledger.activations ledger with [activation] -> activation | _ -> fail "one actual child activation required")
    | None -> fail "nested dispatch recorded no activation" in
  check string "child activation binds original selected runtime" "original.runtime" original_activation.runtime_id;
  check bool "child activation binds exact published Skill" true
    (Skill_reference.equal_identity reference.identity original_activation.identity
     && reference.content_revision = original_activation.content_revision);
  (match original_activation.invocation with
   | Ledger.Nested_composition_invocation {scope;origin=Ledger.Task_composition {task_ids};_} ->
     check string "child activation belongs to original run" run_id scope.composition_run_id;
     check (list string) "child activation belongs to original Task" ["task-A"]
       (Ledger.task_id_set_to_list task_ids |> List.map Keeper_id.Task_id.to_string)
   | _ -> fail "nested job activation lost its exact Task scope");
  check int "original runtime bound once" 1 !runtime_reads;
  set_source fixture ~task_id:"task-B" ~turn:52;
  runtime := "later.runtime";
  let context : _ Masc.Keeper_types_profile.context =
    {config;agent_name="nested-job-continuation-fixture";
     sw=Async.server_background_switch () |> require "nested continuation switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let refused,notify_refused = Eio.Promise.create () in
  let refusals = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify_refused outcome) () in
  let backend_at_ready = ref None in
  let ready,notify_ready = Eio.Promise.create () in
  let jobs = Completion_wake.create ~config ~on_result_ready:(fun (record : Store.record) ->
      check bool "nested completion hint follows actual durable output" true (Store.result_ready record);
      backend_at_ready := Some (List.length (calls fixture));
      if not fault_after_acceptance then
        Wake.pulse ~sw:context.sw refusals;
      Eio.Promise.resolve notify_ready ()) () in
  let events = Filename.concat
      (Masc.Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id))
      "skill-activation-events.jsonl" in
  let original_events = read events in
  let backend_before_completion = List.length (calls fixture) in
  let accepted_worker_calls = ref 0 in
  let retained_wait_request = Fun.protect ~finally:(fun () -> write events original_events) (fun () ->
    if not fault_after_acceptance then write events "invalid-original-child-activation\n";
    control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
    Completion_wake.pulse ~sw:context.sw jobs;
    Eio.Promise.await ready;
    let expected_request = if not fault_after_acceptance then (
      (match Eio.Promise.await refused with
       | Ok (Tool_result.Failed failure) -> check bool "refused original child has no new exports" true
           (Tool_result.data (Tool_result.Failed failure) |> member "exports" = `Null)
       | Ok _ | Error _ -> fail "corrupt original activation reached successor acceptance");
      waiting_entry.request_id)
    else (
      let module Draft = Masc.Keeper_composition_draft in
      let prior = candidate () in
      let source = Journal.continuation_source prior in
      let draft = Draft.load_continuation ~base_path:fixture.base_path ~capability_surface:surface prior
        |> require "actual original draft before accepted activation fault" in
      let bound = Draft.load_nested_activation ~base_path:fixture.base_path source
        |> require "original bound authority before accepted fault" |> function
        | Some bound -> bound | None -> fail "nested worker has no original bound context" in
      check string "original ledger is intact before successor acceptance" original_events (read events);
      let original_invocation = Agent_core.Tool_contract.Invocation.create ~tool_use_id:source.parent_tool_use_id
          ~turn:source.source_turn ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
          ~completion:Agent_core.Tool_contract.Continue_after_success in
      let physical = Masc.Keeper_tool_call_log_context.get_turn_context_record ~cell:fixture.cell () in
      let worker = Atomic.make None in
      let successor = Async.submit_worker_with_request_id ?request_context:waiting_entry.request_context
          ~background_sw:context.sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
          ~on_accepted:(fun request_id ->
            Journal.bind_continuation prior ~request_id |> Result.map (fun accepted ->
              Atomic.set worker (Some accepted);
              write events "invalid-child-authority-after-durable-acceptance\n")
            |> Result.map_error Journal.error_to_string)
          ~f:(fun ~request_id request_sw ->
            incr accepted_worker_calls;
            let worker = match Atomic.get worker with Some worker -> worker
              | None -> fail "worker started without actual durable binding" in
            Masc.Keeper_tool_composition_surface.For_testing.async_worker_result
              ~composition_execution:Masc.Keeper_tool_composition_catalog.Async
              ~tool_kind:Descriptor.Async_composition_tool ~nested_calls:(Draft.nested_calls draft)
              ~nested_activation:bound ~continuation:prior ~plan:(Draft.plan draft) ~journal:worker
              ~tool_name:Draft.run_tool_name ~request_id ~composition_run_id:source.composition_run_id
              ~source_invocation:original_invocation ~request_sw ~config ~meta:fixture.meta
              ~capability_authority:(Masc.Keeper_tool_runtime.Frozen_surface surface) ~publication_recovery
              ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"accepted child authority fault")
              ~turn_context:(Some {physical with task_id=source.source_task_id}) ~clock:(Eio.Stdenv.clock env) ()) ()
        |> require "actual broker acceptance before worker activation fault" in
      let ok,data,entry = await_composition env fixture (`Assoc ["request_id",`String successor.request_id]) in
      check bool "accepted worker stops with the original wait" false ok;
      (match entry.status with
       | Async.Waiting_for_dependencies {dependencies;_} -> check (list string) "accepted fault retains exact original job" [id]
           (List.map dependency_job_id dependencies)
       | _ -> fail "accepted activation fault retired original job work");
      check bool "accepted authority fault returns no original child exports" true (member "exports" data = `Null);
      check int "production worker actually rechecks original authority" 1 !accepted_worker_calls;
      successor.request_id) in
    check string "activation fault retains exact canonical wait owner" expected_request
      (Journal.continuation_request_id (candidate ()));
    expected_request) in
  let ready_backend = match !backend_at_ready with Some count -> count | None -> fail "nested result hint never fired" in
  let detached = Filename.concat fixture.base_path "detached-original-child-activation.jsonl" in
  Unix.rename events detached;
  Fun.protect ~finally:(fun () -> Unix.rename detached events) (fun () ->
    let refused,notify = Eio.Promise.create () in
    let wake = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify outcome) () in
    Wake.pulse ~sw:context.sw wake;
    (match Eio.Promise.await refused with
     | Ok (Tool_result.Failed _) -> () | Ok _ | Error _ -> fail "missing original activation was invented");
    check string "missing activation keeps exact original owner" retained_wait_request
      (Journal.continuation_request_id (candidate ())));
  let resumed,notify = Eio.Promise.create () in
  let fresh = Wake.create ~context ~on_result:(fun _ outcome -> Eio.Promise.resolve notify outcome) () in
  let recovery_started = Mtime_clock.counter () in
  Wake.pulse ~sw:context.sw fresh;
  let resumed = match Eio.Promise.await resumed with
    | Ok (Tool_result.Completed _ as result) -> Tool_result.data result
    | Ok _ | Error _ -> fail "restored nested activation could not resume original work" in
  let ok,completed,entry = await_composition env fixture resumed in
  let recovery_ms = Mtime.Span.to_float_ns (Mtime_clock.count recovery_started) /. 1_000_000. in
  check bool "fresh supervisor finishes original nested DAG" true ok;
  (match Journal.waiting_continuation journal with
   | Ok None -> () | Ok (Some _) | Error _ -> fail "completed nested parent left a waiting continuation");
  check int "nested recovery has zero backend calls after full result" ready_backend (List.length (calls fixture));
  check_json "parent exports original complete stdout" (`String stdout_bytes)
    (completed |> member "exports" |> member "stdout" |> member "value");
  let mappings = prepared |> member "nested_calls" |> to_list |> List.hd |> member "scope" |> member "node_mapping" |> to_list in
  let expanded name = mappings |> List.find (fun row -> row |> member "source" |> to_string = name)
    |> member "expanded" |> to_string in
  let waiting_nodes = composition_nodes fixture waiting and completed_nodes = composition_nodes fixture completed in
  let retained_node = if dynamic_arguments then
      prepared |> member "nested_calls" |> to_list |> List.hd |> member "scope" |> member "argument_node" |> to_string
    else expanded "launch" in
  List.iter (fun node -> List.iter (fun field -> check_json ("nested original occurrence " ^ node ^ "/" ^ field)
      (composition_node node waiting_nodes |> member field)
      (composition_node node completed_nodes |> member field)) ["execution_id";"tool_use_id"])
    [retained_node;expanded "await"];
  check_json "original completed child operand is retained without dispatch" (`String "retained_completion")
    (composition_node retained_node completed_nodes |> member "execution_origin");
  if dynamic_arguments then check_json "fresh supervisor keeps original resolved inline arguments"
    (`Assoc ["job_id",`String id]) (composition_node retained_node completed_nodes |> member "input");
  let scopes = completed |> member "nested_scopes" |> to_list in
  check int "final result retains one original child scope" 1 (List.length scopes);
  check_json "original child completed" (`String "completed") (List.hd scopes |> member "disposition");
  let final_activation = match Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
      |> require "same nested activation after fresh recovery" with
    | Some ledger -> (match Ledger.activations ledger with [activation] -> activation | _ -> fail "nested recovery created a second activation")
    | None -> fail "nested recovery lost original activation" in
  check bool "nested recovery retains exact activation, time, Task and runtime" true (original_activation = final_activation);
  let request_context = match entry.request_context with Some fields -> `Assoc fields | None -> fail "nested original request context missing" in
  check_json "fresh nested completion belongs to original Task" (`String "task-A") (member "source_task_id" request_context);
  check (option string) "nested producer keeps original Task" (Some "task-A") (load fixture id).source.task_id;
  check int "later runtime callback is never selected for original work" 1 !runtime_reads;
  check int "nested program creates once" 1 (effect_count fixture "create");
  check int "nested program starts once" 1 (effect_count fixture "start");
  let transport_started = Mtime_clock.counter () in
  let lookup ?(turn=1) ?(planned_index=0) ?(request_id=entry.request_id) tool_use_id = with_bundle fixture (fun bundle ->
    match invoke_raw ~planned_index bundle ~tool_use_id ~turn "keeper_composition_status"
        (`Assoc ["request_id",`String request_id]) with
    | Ok output -> output.Agent_core.Types.content
    | Error error -> failf "actual async status transport failed: %s" error.Agent_core.Types.message) in
  let status_id = "status-original-result-in-new-turn" in
  let wire = lookup status_id in
  let observed = ref [] and errors = ref [] and durable = ref [] in
  let observe observation =
    observed := observation :: !observed;
    match Delivery.persist ~config observation with
    | Ok (Some delivery) -> durable := delivery :: !durable
    | Ok None -> fail "actual admitted nested child has no durable handoff"
    | Error error -> failf "actual child handoff persistence failed: %s" (Delivery.error_to_string error)
  and on_error error = errors := error :: !errors in
  let stage_response ?(id=status_id) ?(content=wire) ?(turn=2) () =
    let messages = [{Agent_core.Types.role=Tool;
      content=[Agent_core.Types.ToolResult {tool_use_id=id;content;
        outcome=Agent_core.Llm_provider.Types.Tool_succeeded;json=None;content_blocks=None}];
      name=None;tool_call_id=None;metadata=[]}] in
    Delivery.stage_provider delivery ~runtime_id:"later.provider.runtime" ~agent_core_turn:turn
      ~tool_results:(Masc.Keeper_run_tools_hooks.trailing_tool_result_contents messages) in
  let commit turn = Delivery.commit_provider_response delivery ~agent_core_turn:turn ~observe ~on_error in
  stage_response (); Delivery.clear_pending delivery; commit 2;
  check int "failed provider request proves no child result receipt" 0 (List.length !observed);
  stage_response (); commit 3;
  check int "unrelated response cannot consume pending result" 0 (List.length !observed);
  commit 2;
  check int "matching actual provider response correlates one result" 1 (List.length !observed);
  let observation = List.hd !observed in
  check bool "physical result turn stays separate from original activation" true
    (Ids.Turn_ref.equal physical_turn_ref observation.Delivery.physical_turn_ref
     && not (Ids.Turn_ref.equal original_activation.turn_ref observation.physical_turn_ref));
  check string "transport retains actual status call ID" status_id observation.transport_receipt.tool_use_id;
  check string "result retains original canonical request ID" entry.request_id
    (Delivery.request_id observation.binding);
  check_json "transport retains original Task" (`String "task-A")
    (Delivery.observation_to_json observation |> member "original_source_task_id");
  check_json "transport restores original recorder Turn_ref"
    (Ids.Turn_ref.to_yojson original_activation.turn_ref)
    (Delivery.observation_to_json observation |> member "original_recorder" |> member "turn_ref");
  check bool "small actual status payload delivers inline data" true
    (observation.presentation = Delivery.Inline_result);
  let transport_ms = Mtime.Span.to_float_ns (Mtime_clock.count transport_started) /. 1_000_000. in
  stage_response ~id:"unbound-status-result" (); commit 2;
  stage_response ~content:(wire ^ " ") (); commit 2;
  check int "unbound and changed wire payloads grant no receipt" 1 (List.length !observed);
  let invocation ?(turn=1) ?(planned_index=0) tool_use_id = Agent_core.Tool_contract.Invocation.create ~tool_use_id ~turn
    ~schedule:{planned_index;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Concurrent}
    ~completion:Agent_core.Tool_contract.Continue_after_success in
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation status_id) ~content:wire ~observe ~on_error;
  check int "actual official result callback keeps its own handoff" 2 (List.length !observed);
  let manifest = wire |> Yojson.Safe.from_string |> member "artifact_manifest"
    |> composition_reference "actual status result manifest" in
  let marker = Tool_output.encode_for_agent_core (Tool_output.Stored manifest) in
  Delivery.observe_official_result delivery ~runtime_id:"later.reference.runtime"
    ~invocation:(invocation status_id) ~content:marker ~observe ~on_error;
  check int "exact transmitted reference is correlated" 3 (List.length !observed);
  check bool "reference handoff does not claim inline child body" true
    ((List.hd !observed).presentation = Delivery.Manifest_reference);
  check int "transport receipt counts actual marker bytes" (String.length marker)
    (List.hd !observed).transport_receipt.content_bytes;
  let repeated_id = "status-original-result-again" in
  let repeated_wire = lookup repeated_id in
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation repeated_id) ~content:repeated_wire ~observe ~on_error;
  check int "repeated lookup keeps a distinct actual handoff" 4 (List.length !observed);
  check string "repeated lookup never rewrites transport identity" repeated_id
    (List.hd !observed).transport_receipt.tool_use_id;
  let original_run = Journal.source journal |> fun source -> source.run_reference in
  let blob_store = Tool_blob_store.create ~base_path:fixture.base_path in
  let original_bytes = Tool_blob_store.fetch blob_store ~sha256:original_run.sha256
    |> require "read original authority for transport fault"
    |> function Some bytes -> bytes | None -> fail "original transport run authority missing" in
  check bool "remove original authority in isolated fixture" true
    (Tool_blob_store.delete blob_store ~sha256:original_run.sha256 |> require "remove original transport authority");
  Fun.protect ~finally:(fun () -> ignore (Tool_blob_store.put_durable blob_store
    ~bytes:original_bytes ~mime:original_run.mime)) (fun () ->
    stage_response (); commit 2;
    check int "missing original authority cannot publish retained result binding" 4 (List.length !observed);
    check int "missing original authority stays an explicit observation failure" 1 (List.length !errors));
  stage_response (); commit 2;
  check int "restored original authority correlates without new work" 5 (List.length !observed);
  let reused_wire = lookup ~turn:3 status_id in
  check bool "SDK occurrence seal distinguishes otherwise identical terminal status lookups" false
    (String.equal wire reused_wire);
  stage_response ~content:wire ~turn:4 (); commit 4;
  stage_response ~content:marker ~turn:4 (); commit 4;
  check int "unstaged old inline and marker results cannot borrow the latest occurrence" 5 (List.length !observed);
  stage_response ~content:reused_wire ~turn:4 ();
  let later_wire = lookup ~turn:5 status_id in
  commit 4;
  check int "later ID reuse preserves the already staged provider handoff" 6 (List.length !observed);
  check int "staged provider result keeps its original SDK occurrence" 3
    (Agent_core.Tool_contract.Invocation.turn (Delivery.status_invocation (List.hd !observed).binding));
  let errors_before_reuse = List.length !errors in
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:3 status_id) ~content:reused_wire ~observe ~on_error;
  check int "stale official callback cannot borrow a later occurrence" 6 (List.length !observed);
  check int "stale official callback reports the invocation mismatch" (errors_before_reuse+1) (List.length !errors);
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:5 status_id) ~content:later_wire ~observe ~on_error;
  check int "reused ID supports the fresh occurrence's first handoff" 7 (List.length !observed);
  let replanned_wire = lookup ~turn:5 ~planned_index:7 status_id in
  check bool "planned occurrence is sealed even when ID and SDK turn are reused" false
    (String.equal later_wire replanned_wire);
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:5 status_id) ~content:later_wire ~observe ~on_error;
  check int "same SDK turn with another planned occurrence cannot borrow authority" 7 (List.length !observed);
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:5 ~planned_index:7 status_id) ~content:replanned_wire ~observe ~on_error;
  check int "fresh planned occurrence supports its first official handoff" 8 (List.length !observed);
  (* A canonical generic worker can copy every source field and output without
     being admitted by the prepared run. Canonical existence is not membership. *)
  let copied = Async.submit_worker_with_request_id ?request_context:entry.request_context
      ~background_sw:context.sw ~base_path:fixture.base_path ~caller:keeper ~keeper_name:keeper
      ~f:(fun ~request_id:_ _ -> Async.worker_finished
        (Tool_result.make_ok ~tool_name:"copied-context-worker" ~start_time:(Tool_timing.start ()) ~data:completed ())) ()
    |> require "actual generic worker with copied prepared context" in
  let copied_ok,_,copied_entry = await_composition env fixture (`Assoc ["request_id",`String copied.request_id]) in
  check bool "copied context worker is a real canonical terminal request" true copied_ok;
  (match Journal.validate_request journal copied_entry with
   | Error (Journal.Invalid_source _) -> ()
   | Ok () | Error _ -> fail "unadmitted canonical request borrowed prepared run membership");
  Journal.validate_request journal entry |> require "original completed request retains admitted membership";
  Journal.validate_request journal waiting_entry |> require "actual historical predecessor retains admitted membership";
  stage_response ~content:replanned_wire ~turn:6 ();
  let copied_wire = lookup ~turn:6 ~request_id:copied.request_id status_id in
  check_json "public status still returns the generic worker's canonical result" (`String copied.request_id)
    (result_document ~base_path:fixture.base_path copied_wire |> member "request_id");
  commit 6;
  check int "rejected new lookup preserves the previously staged original result" 9 (List.length !observed);
  check string "copied request cannot retarget a staged original handoff" entry.request_id
    (Delivery.request_id (List.hd !observed).binding);
  stage_response ~content:replanned_wire ~turn:7 (); commit 7;
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:5 ~planned_index:7 status_id) ~content:replanned_wire ~observe ~on_error;
  check int "rejected lookup evicts the old slot for future provider and official delivery" 9 (List.length !observed);
  let restored_wire = lookup ~turn:7 status_id in
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:7 status_id) ~content:restored_wire ~observe ~on_error;
  check int "valid later occurrence can bind again without a permanent ID tombstone" 10 (List.length !observed);
  let failed_lookup ~turn input = with_bundle fixture (fun bundle ->
    match invoke_raw bundle ~tool_use_id:status_id ~turn "keeper_composition_status" input with
    | Error _ -> () | Ok _ -> fail "invalid actual status lookup unexpectedly succeeded") in
  stage_response ~content:restored_wire ~turn:8 ();
  failed_lookup ~turn:8 (`Assoc ["request_id",`String "missing-canonical-request"]);
  commit 8;
  check int "absent status request does not revoke an already staged original handoff" 11 (List.length !observed);
  stage_response ~content:restored_wire ~turn:9 (); commit 9;
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:7 status_id) ~content:restored_wire ~observe ~on_error;
  check int "absent actual lookup revokes the old slot for future delivery" 11 (List.length !observed);
  let valid_again = lookup ~turn:9 status_id in
  failed_lookup ~turn:10 (`Assoc []);
  stage_response ~content:valid_again ~turn:11 (); commit 11;
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:9 status_id) ~content:valid_again ~observe ~on_error;
  check int "public input validation refusal also revokes the old producer slot" 11 (List.length !observed);
  let final_wire = lookup ~turn:11 status_id in
  Delivery.observe_official_result delivery ~runtime_id:"later.official.runtime"
    ~invocation:(invocation ~turn:11 status_id) ~content:final_wire ~observe ~on_error;
  check int "valid reused ID recovers after canonical and input refusals" 12 (List.length !observed);
  let lifecycle = Masc.Keeper_run_tools_hooks.composition_result_lifecycle_hook delivery in
  let sdk_hooks = {Agent_core.Hooks.empty with pre_tool_use=Some lifecycle;post_tool_use_failure=Some lifecycle} in
  let execute_sdk ~turn tools name input =
    Agent_core.Agent_tools.execute_tools ~context:(Agent_core.Context.create ()) ~tools ~hooks:sdk_hooks
      ~event_bus:None ~tracer:Agent_core.Tracing.null ~agent_name:keeper ~turn_count:turn
      ~usage:Agent_core.Types.empty_usage
      [Agent_core.Types.ToolUse {id=status_id;name;input}]
    |> require "real SDK status input and tool occurrence boundary" in
  let invalid = with_bundle fixture (fun bundle ->
    execute_sdk ~turn:12 bundle.Masc.Keeper_tools_agent_core.tools "keeper_composition_status" (`Assoc [])) in
  (match invalid.completed_results with
   | [result] -> check bool "SDK rejects malformed status before handler execution" true
       (result.outcome = Agent_core.Types.Tool_failed {failure_kind=Validation_error;error_class=Some Deterministic})
   | [] | _::_::_ -> fail "SDK validation did not produce one exact result");
  stage_response ~content:final_wire ~turn:13 (); commit 13;
  check int "actual SDK validation failure revokes the prior status slot" 12 (List.length !observed);
  let non_status_wire = lookup ~turn:13 status_id in
  let other = Agent_core.Tool.create ~name:"fixture_other_tool" ~description:"Return saved status bytes as unrelated tool data"
      ~parameters:[] (fun _ -> Ok {Agent_core.Types.content=non_status_wire;content_blocks=None;_meta=None}) in
  let other_result = execute_sdk ~turn:14 [other] "fixture_other_tool" (`Assoc []) in
  let other_wire = match other_result.completed_results with
    | [result] -> result.content | [] | _::_::_ -> fail "actual other tool did not execute once" in
  stage_response ~content:other_wire ~turn:15 (); commit 15;
  check int "real SDK reuse by another tool cannot inherit status result authority" 12 (List.length !observed);
  let ledger () = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
    |> require "durable child handoff replay" |> function Some ledger -> ledger | None -> fail "original ledger missing" in
  let replay = ledger () in
  let deliveries = Ledger.async_result_deliveries replay in
  check int "actual repeated provider boundary is durable exactly once" 11 (List.length deliveries);
  check bool "original activation, Task and activation clock are unchanged" true
    (Ledger.activations replay = [original_activation]);
  let summary = Ledger.summarize replay in
  check int "repeated inline handoffs count one child provider delivery" 1 summary.composition_provider_deliveries;
  check int "official client handoffs count one child separately" 1 summary.composition_official_client_handoffs;
  check int "a result receipt does not invent a later action" 0 summary.composition_actions_observed;
  check bool "reference handoff remains separate from inline result delivery" true
    (List.exists (fun (delivery : Async_delivery.t) -> delivery.presentation = Async_delivery.Manifest_reference) deliveries);
  List.iter (fun (delivery : Async_delivery.t) ->
    check bool "durable physical handoff keeps the original activation turn" true
      (Ids.Turn_ref.equal original_activation.turn_ref delivery.original_turn_ref
       && Ids.Turn_ref.equal physical_turn_ref delivery.physical_turn_ref);
    check (list string) "durable handoff binds exact original admitted child" [original_activation.skill_tool_use_id]
      (List.map (fun (child : Async_delivery.child_activation) -> child.skill_tool_use_id) delivery.child_activations);
    check string "durable handoff retains canonical original request" entry.request_id delivery.request_id) deliveries;
  let projection = Ledger.to_yojson replay |> Ledger.of_projection_yojson |> require "self-contained async ledger projection" in
  check int "canonical projection retains all physical handoffs" 11 (List.length (Ledger.async_result_deliveries projection));
  let repeated = List.hd !durable in
  let repeated_observation = List.hd !observed in
  let idempotent = Delivery.persist ~config repeated_observation |> require "actual handoff re-observation"
    |> function Some value -> value | None -> fail "re-observation lost original child" in
  check_json "idempotent handoff retains first durable clock" (Async_delivery.to_json repeated) (Async_delivery.to_json idempotent);
  let valid_events = read events in
  let change_field name value = function
    | `Assoc fields -> `Assoc (List.map (fun (key,known) -> key, if String.equal key name then value else known) fields)
    | _ -> fail "original child frame is not an object" in
  let change_task = function
    | `Assoc fields -> `Assoc (List.map (function
        | "invocation", invocation ->
          "invocation", change_field "origin" (`Assoc ["kind",`String "task_composition";"task_ids",`List [`String "task-B"]]) invocation
        | field -> field) fields)
    | _ -> fail "original child frame is not an object" in
  List.iter (fun mutate ->
    let tampered = String.split_on_char '\n' valid_events
      |> List.filter (fun row -> not (String.equal row ""))
      |> List.map (fun row ->
        let json = Yojson.Safe.from_string row in
        match json with
        | `Assoc fields when List.assoc_opt "kind" fields = Some (`String "activation_recorded") ->
          `Assoc (List.map (function "activation", activation -> "activation", mutate activation | field -> field) fields)
          |> Yojson.Safe.to_string
        | _ -> row)
      |> String.concat "\n" in
    Fun.protect ~finally:(fun () -> write events valid_events) (fun () ->
      write events (tampered ^ "\n");
      match Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id with
      | Error (Ledger.Decode_failed (Ledger.Invalid_async_result_evidence _)) -> ()
      | Error error -> failf "altered original frame returned wrong refusal: %s" (Ledger.store_error_to_string error)
      | Ok _ -> fail "canonical event replay rebound handoff to an altered original frame"))
    [change_task;change_field "runtime_id" (`String "another-runtime");
     change_field "activated_at" (`String "2026-10-14T12:00:03Z")];
  Fun.protect ~finally:(fun () -> write events valid_events) (fun () ->
    write events "corrupt-original-child-ledger\n";
    match Delivery.persist ~config repeated_observation with
    | Error (Delivery.Recorder_failed _) -> ()
    | Ok _ | Error _ -> fail "corrupt original ledger acquired a durable child receipt");
  Delivery.persist ~config repeated_observation |> require "original child receipt recovers without dispatch" |> ignore;
  check int "ledger recovery creates no second handoff" 11 (List.length (Ledger.async_result_deliveries (ledger ())));
  let module Action = Masc.Keeper_skill_async_action in
  let module Action_observer = Masc.Keeper_skill_async_action_observer in
  let physical_runtime = ref observation.runtime_id in
  let physical_selection = Masc.Keeper_task_skill_turn.resolve_for_task ~snapshot ~task_id:"task-B" []
    |> require "receiving Task has independent Skill selection" in
  let receiving_recorder = Recorder.make ~trace_id:fixture.meta.runtime.trace_id ~turn_ref:physical_turn_ref
    ~runtime_id:(fun () -> Some !physical_runtime) ~snapshot_revision:(Surface.skill_snapshot_revision surface)
    ~task_selection:physical_selection |> require "physical receiving recorder" in
  let action_observer = Action_observer.create ~config ~context:receiving_recorder in
  let action_errors = ref [] in
  let action_hook = Action_observer.sdk_hook action_observer ~on_error:(fun error -> action_errors := error :: !action_errors) in
  let action_hooks = {Agent_core.Hooks.empty with pre_tool_use=Some action_hook;
    post_tool_use=Some action_hook;post_tool_use_failure=Some action_hook} in
  let handoff observation =
    Action_observer.begin_handoff action_observer;
    Action_observer.record_delivery action_observer observation |> require "actual original result action authority" |> ignore in
  let action_count () = List.length (Ledger.async_actions (ledger ())) in
  let result = Ok {Agent_core.Types.content="follow-on-result";content_blocks=None;_meta=None} in
  let success_tool = Agent_core.Tool.create ~name:"fixture_follow_on" ~description:"Consume the original child result"
    ~parameters:[] (fun _ -> result) in
  let failed_tool = Agent_core.Tool.create ~name:"fixture_follow_on_error" ~description:"Return an actual typed handler failure"
    ~parameters:[] (fun _ -> Error {Agent_core.Types.message="actual-handler-error";recoverable=false;error_class=Some Deterministic}) in
  let execute_action ?(input=`Assoc []) ~turn ~id tool =
    Agent_core.Agent_tools.execute_tools ~context:(Agent_core.Context.create ()) ~tools:[tool] ~hooks:action_hooks
      ~event_bus:None ~tracer:Agent_core.Tracing.null ~agent_name:keeper ~turn_count:turn
      ~usage:Agent_core.Types.empty_usage [Agent_core.Types.ToolUse {id;name=tool.Agent_core.Tool.schema.name;input}]
    |> require "real SDK follow-on execution" in
  handoff observation;
  let before_actions = action_count () in
  let intent = invocation ~turn:2 "intent-without-execution" in
  ignore (action_hook (Agent_core.Hooks.PreToolUse {invocation=intent;tool_name="fixture_follow_on";input=`Assoc [];usage=None}));
  check int "pre-dispatch intent is not an executed action fact" before_actions (action_count ());
  let actual = execute_action ~turn:2 ~id:"follow-on-reused-id" success_tool in
  check int "real SDK handler result attaches to original child" (before_actions+1) (action_count ());
  check int "one actual handler result returned" 1 (List.length actual.completed_results);
  let first_action = List.hd (Ledger.async_actions (ledger ())) in
  (match first_action.occurrence with
   | Action.Sdk_result {invocation;result=Handler_returned {bytes;_}} ->
     check string "actual SDK action retains its exact call id" "follow-on-reused-id"
       (Agent_core.Tool_contract.Invocation.tool_use_id invocation);
     check int "result bytes are actual handler text" (String.length "follow-on-result") bytes
   | Sdk_result {result=Handler_errored _;_} | Native_started _ -> fail "success handler result was misclassified");
  execute_action ~turn:3 ~id:"follow-on-reused-id" success_tool |> ignore;
  check int "a later occurrence can reuse the same SDK ID" (before_actions+2) (action_count ());
  execute_action ~turn:3 ~id:"failed-follow-on" failed_tool |> ignore;
  check int "typed handler error is one executed result, not a second failure callback fact" (before_actions+3) (action_count ());
  let validating_schema = Agent_core.Types.tool_schema_of_input_schema ~name:"fixture_validated_follow_on"
    ~description:"Require an actual result reference before execution"
    ~input_schema:(`Assoc ["type",`String "object";"required",`List [`String "reference"];
      "properties",`Assoc ["reference",`Assoc ["type",`String "string"]]]) () |> require "actual SDK validation schema" in
  let validation_effects = ref 0 in
  let validating = Agent_core.Tool.of_schema validating_schema
    (Agent_core.Tool.ignoring_execution_env (fun _ -> incr validation_effects; result)) in
  execute_action ~turn:3 ~id:"invalid-follow-on" validating |> ignore;
  check int "schema refusal never enters the handler" 0 !validation_effects;
  check int "schema refusal is not executed action evidence" (before_actions+3) (action_count ());
  let repeated = Ledger.observe_async_action ~config ~trace_id:fixture.meta.runtime.trace_id first_action
    |> require "idempotent actual action replay" |> snd in
  check_json "re-observation preserves the first actual result clock" (Action.to_json first_action) (Action.to_json repeated);
  let changed = Action.make ~delivery_sha256:first_action.delivery_sha256 ~physical_turn_ref
    ~runtime_id:first_action.runtime_id ~tool_name:first_action.tool_name
    ~occurrence:(match first_action.occurrence with Sdk_result {invocation;_} ->
      Sdk_result {invocation;result=Action.sdk_result (Ok {Agent_core.Types.content="changed";content_blocks=None;_meta=None})}
      | Native_started _ -> fail "expected actual SDK occurrence") ~observed_at:first_action.observed_at
    |> require "changed actual result candidate" in
  (match Ledger.observe_async_action ~config ~trace_id:fixture.meta.runtime.trace_id changed with
   | Error (Ledger.Decode_failed (Ledger.Invalid_async_action_evidence _)) -> ()
   | Ok _ | Error _ -> fail "same occurrence accepted a different actual result");
  Action_observer.clear action_observer;
  ignore (action_hook (Agent_core.Hooks.PostToolUse {invocation=intent;tool_name="fixture_follow_on";input=`Assoc [];
    output=result;result_bytes=16;duration_ms=0.}));
  check int "late old-attempt post-hook cannot borrow new causal authority" (before_actions+3) (action_count ());
  let official_observation = List.find (fun (value : Delivery.observation) ->
    value.runtime_id="later.official.runtime" && value.presentation=Delivery.Inline_result) !observed in
  physical_runtime := official_observation.runtime_id;
  handoff official_observation;
  let native = {Runtime_native_tools.identity=Some (Call_id "native-follow-on");tool_name=Some "native-read";origin=Built_in} in
  let native_observe ~official_turn ~identity ~tool_name =
    Action_observer.native_started action_observer ~runtime_id:!physical_runtime ~official_turn ~identity ~tool_name
    |> require "actual official native start callback" |> ignore in
  Runtime_native_tools.observe_exact_action ~official_turn:0 ~observe:native_observe native;
  Runtime_native_tools.observe_exact_action ~official_turn:0 ~observe:native_observe native;
  check int "native starts are observed once independently of SDK turn 41" (before_actions+4) (action_count ());
  (match Action_observer.native_started action_observer ~runtime_id:!physical_runtime ~official_turn:0
      ~identity:(Call_id "native-follow-on") ~tool_name:"contradictory-native-name" with
   | Error (Action_observer.Ledger_failed (Ledger.Decode_failed (Ledger.Invalid_async_action_evidence _))) -> ()
   | Ok _ | Error _ -> fail "same native occurrence accepted a different tool name");
  check int "contradictory native name is refused without inflating action count" (before_actions+4) (action_count ());
  handoff official_observation;
  let action_events = read events in
  Fun.protect ~finally:(fun () -> write events action_events) (fun () ->
    write events "corrupt-original-action-ledger\n";
    execute_action ~turn:20 ~id:"refused-original-authority" success_tool |> ignore);
  check int "corrupt original ledger reports one evidence refusal" 1 (List.length !action_errors);
  execute_action ~turn:21 ~id:"no-stale-authority-after-refusal" success_tool |> ignore;
  check int "ledger refusal clears active authority" (before_actions+4) (action_count ());
  handoff official_observation;
  execute_action ~turn:22 ~id:"recovered-original-authority" success_tool |> ignore;
  check int "restored authority recovers without dispatching original child" (before_actions+5) (action_count ());
  check bool "follow-on actions never rewrite original Task or activation clock" true
    (Ledger.activations (ledger ()) = [original_activation]);
  check int "summary counts actual SDK results and separately typed native start observations" 5
    (Ledger.summarize (ledger ())).composition_actions_observed;
  let action_projection = Ledger.to_yojson (ledger ()) |> Ledger.of_projection_yojson
    |> require "actual action canonical projection" in
  check int "canonical projection retains actual follow-on facts" 5 (List.length (Ledger.async_actions action_projection));
  let sibling_observation = List.find (fun (value : Delivery.observation) ->
    value.runtime_id=official_observation.runtime_id && value.presentation=Delivery.Inline_result
    && value.transport_receipt.tool_use_id <> official_observation.transport_receipt.tool_use_id) !observed in
  handoff official_observation;
  Action_observer.record_delivery action_observer sibling_observation
    |> require "sibling official result preserves earlier active receipt" |> ignore;
  execute_action ~turn:23 ~id:"action-after-sibling-results" success_tool |> ignore;
  check int "one actual SDK occurrence links both delivered receipts" 7 (action_count ());
  check int "two receipt links count the same physical occurrence once per child" 6
    (Ledger.summarize (ledger ())).composition_actions_observed;
  let linked_actions = Ledger.async_actions (ledger ()) in
  let linked = List.find (fun (value : Action.t) -> match value.occurrence with
    | Sdk_result {invocation;_} -> Agent_core.Tool_contract.Invocation.tool_use_id invocation = "action-after-sibling-results"
    | Native_started _ -> false) linked_actions in
  let conflicting_link = Action.make ~delivery_sha256:linked.delivery_sha256 ~physical_turn_ref
    ~runtime_id:linked.runtime_id ~tool_name:"different-tool-for-same-sibling-occurrence"
    ~occurrence:linked.occurrence ~observed_at:linked.observed_at |> require "contradictory sibling link candidate" in
  (match Ledger.observe_async_action ~config ~trace_id:fixture.meta.runtime.trace_id conflicting_link with
   | Error (Ledger.Decode_failed (Ledger.Invalid_async_action_evidence _)) -> ()
   | Ok _ | Error _ -> fail "same physical sibling occurrence accepted contradictory tool facts");
  let linked_events = read events in
  let tampered_events = String.split_on_char '\n' linked_events |> List.map (fun row ->
    if String.equal row "" then row else
    let json = Yojson.Safe.from_string row in
    match json with
    | `Assoc fields when List.assoc_opt "kind" fields = Some (`String "async_action_observed") ->
      (match List.assoc_opt "action" fields with
       | Some (`Assoc action) when List.assoc_opt "delivery_sha256" action = Some (`String linked.delivery_sha256)
           && List.assoc_opt "tool_name" action = Some (`String "fixture_follow_on") ->
         `Assoc (List.map (function "action", `Assoc action -> "action", `Assoc
           (List.map (fun (key,value) -> key, if key="tool_name" then `String "contradictory-replayed-name" else value) action)
           | field -> field) fields) |> Yojson.Safe.to_string
       | Some _ | None -> row)
    | _ -> row) |> String.concat "\n" in
  Fun.protect ~finally:(fun () -> write events linked_events) (fun () ->
    write events tampered_events;
    match Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id with
    | Error (Ledger.Decode_failed (Ledger.Invalid_async_action_evidence _)) -> ()
    | Ok _ | Error _ -> fail "canonical replay hid contradictory sibling occurrence facts");
  physical_runtime := observation.runtime_id;
  Action_observer.clear action_observer;
  let sibling_provider = List.find (fun (value : Delivery.observation) ->
    value.runtime_id=observation.runtime_id && value.presentation=Delivery.Inline_result
    && value.boundary <> observation.boundary) !observed in
  Eio.Switch.run (fun io_sw ->
    let started,notify_started = Eio.Promise.create () in
    let finished,notify_finished = Eio.Promise.create () in
    let session_dir = Masc.Keeper_fs.keeper_session_dir config
      (Keeper_id.Trace_id.to_string fixture.meta.runtime.trace_id) in
    Masc.Keeper_checkpoint_store.with_session_lock ~session_dir (fun _ ->
      Eio.Fiber.fork ~sw:io_sw (fun () ->
        Eio.Promise.resolve notify_started ();
        Eio.Promise.resolve notify_finished (Action_observer.record_delivery action_observer observation));
      Eio.Promise.await started;
      (* The real durable write cannot finish while this canonical lock is
         held. A fresh attempt may select the same runtime id. *)
      Action_observer.clear action_observer)
    |> require "actual canonical lock at an in-flight handoff reset";
    Eio.Promise.await finished |> require "old handoff finishes its original durable observation" |> ignore);
  Action_observer.record_delivery action_observer sibling_provider
    |> require "new attempt receives its own result after the old write" |> ignore;
  execute_action ~turn:25 ~id:"fresh-attempt-after-io-reset" success_tool |> ignore;
  check int "late old handoff never reactivates after actual I/O reset with same runtime id" 8 (action_count ());
  check int "fresh attempt links only its own received result" 7 (Ledger.summarize (ledger ())).composition_actions_observed;
  let reference_observation = List.find (fun (value : Delivery.observation) ->
    value.presentation=Delivery.Manifest_reference) !observed in
  physical_runtime := reference_observation.runtime_id;
  handoff reference_observation;
  execute_action ~turn:24 ~id:"reference-is-not-body-authority" success_tool |> ignore;
  check int "reference-only handoff has no body action authority" 8 (action_count ());
  let reference = Skill_reference.make ~identity:original_activation.identity
    ~content_revision:original_activation.content_revision in
  let detail_started = Mtime_clock.counter () in
  let discovery = Masc.Keeper_skill_activation_discovery.discover config reference in
  (match discovery.latest with
   | Masc.Keeper_skill_activation_discovery.Most_recent_observed evidence ->
     check bool "fresh retained discovery preserves original Task admission" true
       (evidence.activation = original_activation);
     check int "fresh retained discovery keeps every physical handoff" 11
       (List.length evidence.async_evidence.result_deliveries);
     check int "fresh retained discovery keeps SDK and native action links" 8
       (List.length evidence.async_evidence.action_observations)
   | Masc.Keeper_skill_activation_discovery.Not_observed
   | Masc.Keeper_skill_activation_discovery.Most_recent_observed_timestamp_tie _ -> fail "fresh retained async Skill detail is missing");
  let detail = Server_skill_evidence.project ~config reference in
  let evidence = detail |> member "activation" |> member "evidence" in
  check string "detail uses required async evidence contract" "masc.skill-evidence/v7"
    (detail |> member "schema" |> to_string);
  check_json "detail returns the original Task and admission frame"
    (Ledger.activation_to_yojson original_activation) (evidence |> member "activation");
  check int "detail exposes exact selected physical handoffs" 11
    (evidence |> member "async_result_deliveries" |> to_list |> List.length);
  check int "detail exposes actual selected causal action links" 8
    (evidence |> member "async_actions" |> to_list |> List.length);
  let decoded_detail = Ledger.async_evidence_of_yojson ~expected_trace_id:fixture.meta.runtime.trace_id
    ~activation:original_activation (`Assoc
      ["async_result_deliveries", member "async_result_deliveries" evidence;
       "async_actions", member "async_actions" evidence]) |> require "detail strict selected evidence decoder" in
  check int "detail can be consumed without rewriting original admission" 8
    (List.length decoded_detail.action_observations);
  let display = Masc.Tui_skill_async_evidence.project decoded_detail in
  check int "display decisions preserve the eleven physical handoffs" 11
    (List.length display.result_deliveries);
  check int "display decisions distinguish seven physical actions from eight links" 7
    (List.length display.actions);
  check int "display decisions retain every causal link" 8 display.action_link_count;
  let detail_ms = Mtime.Span.to_float_ns (Mtime_clock.count detail_started) /. 1_000_000. in
  Printf.printf "OWNED_RETAINED_ASYNC_SKILL_DETAIL %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope", `String "synthetic public owned async flow, fresh retained discovery and actual detail projection";
     "retained_discovery_and_detail_projection_ms", `Float detail_ms;
     "original_activation_turn", `Int 41; "physical_receiving_turn", `Int 73;
     "selected_physical_handoffs", `Int 11; "selected_action_link_facts", `Int 8;
     "original_activation_unchanged", `Bool true;
     "backend_calls_after_result_ready", `Int (List.length (calls fixture)-ready_backend)]));
  Printf.printf "OWNED_ASYNC_CAUSAL_ACTIONS %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic owned continuation, actual SDK dispatcher results and official native start callback";
     "original_activation_turn",`Int 41;"physical_receiving_turn",`Int 73;
     "sdk_result_facts",`Int 7;"native_starts",`Int 1;"unique_child_actions_observed",`Int 7;"actual_io_attempt_resets",`Int 1;"validation_handler_calls",`Int !validation_effects;
     "evidence_write_refusals",`Int (List.length !action_errors);
     "original_activation_unchanged",`Bool true;"backend_calls_after_result_ready",`Int (List.length (calls fixture)-ready_backend)]));
  check int "all result correlation performs zero backend operations" ready_backend (List.length (calls fixture));
  check int "result correlation creates no program" 1 (effect_count fixture "create");
  check int "result correlation starts no program" 1 (effect_count fixture "start");
  let retained = Ledger.load_existing ~config ~trace_id:fixture.meta.runtime.trace_id
    |> require "original activation after transport correlation" in
  check bool "transport correlation preserves original child activation" true
    (Option.exists (fun ledger -> Ledger.activations ledger = [original_activation]) retained);
  Printf.printf "OWNED_ASYNC_RESULT_TRANSPORT_BINDING %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public prepare/run/fresh continuation/status and actual wire correlation boundary";
     "status_lookup_and_provider_receipt_ms",`Float transport_ms;
     "observed_transport_handoffs",`Int (List.length !observed);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-ready_backend);
     "original_activation_count",`Int 1;
     "durable_child_delivery_ledger_updated",`Bool true;
     "unique_durable_child_handoffs",`Int (List.length deliveries)]));
  Printf.printf "OWNED_NESTED_SKILL_CONTINUATION %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI public nested async parent and fresh original child authority recovery";
     "prepare_to_saved_wait_ms",`Float prepare_to_wait_ms;"fresh_pulse_to_original_dag_ms",`Float recovery_ms;
     "backend_calls_to_complete_original_job",`Int (ready_backend-backend_before_completion);
     "backend_calls_after_result_ready",`Int (List.length (calls fixture)-ready_backend);
     "original_activation_count",`Int 1;"activation_fault_refusals",`Int 2;
     "fault_after_durable_acceptance",`Bool fault_after_acceptance;
     "upstream_inline_arguments",`Bool dynamic_arguments;
     "accepted_fault_worker_calls",`Int !accepted_worker_calls;
     "program_creates",`Int (effect_count fixture "create");"program_starts",`Int (effect_count fixture "start")]))

exception Fixture_result_observer_failed

let test_prepared_discovery_demand_survives_observer_failure () =
  with_fixture @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  control_job fixture parked.job_id (`Assoc ["state",`String "exited"]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-before-prepared-discovery" ~turn:52 "keeper_job_status" (argument parked.job_id)));
  let original_job = load fixture parked.job_id in
  let job_notification : Journal.result_notification =
    {base_path=original_job.base_path;keeper_name=original_job.keeper_name;
     dependency=Dependency.Owned_job original_job.job_id} in
  let child_notification : Journal.result_notification =
    {base_path=fixture.base_path;keeper_name=keeper;
     dependency=Dependency.Composition_result parked.binding} in
  let child_source = Journal.continuation_source parked.child_continuation
  and parent_source = Journal.continuation_source parked.parent_continuation in
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original discovery demand fixture\"\n";
  let context : _ Masc.Keeper_types_profile.context =
    {config=parked.config;agent_name="prepared-discovery-maintenance";
     sw=Async.server_background_switch () |> require "prepared discovery background switch";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "prepared_continuations" in
  let original_markers = Sys.readdir directory |> Array.to_list |> List.map (fun name ->
    name,read (Filename.concat directory name)) in
  let saved_directory = directory ^ ".fixture-saved" in
  Unix.rename directory saved_directory;
  write directory "actual prepared discovery directory unavailable\n";
  let read_pending () = Journal.pending_continuations ~base_path:fixture.base_path
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness in
  let original_error = match read_pending () with
    | Error error -> error | Ok _ -> fail "actual pending directory fault did not reject discovery" in
  let child, publish_child = Eio.Promise.create ()
  and parent, publish_parent = Eio.Promise.create () in
  let observed = Eio.Stream.create 0 in
  let released, release = Eio.Promise.create () in
  let exception Discovery_observer_failed in
  let supervisor = Wake.create ~context
      ~on_discovery:(fun ~base_path result ->
        Eio.Stream.add observed (base_path,result);
        match result with
        | Ok () -> ()
        | Error _ -> Eio.Promise.await released; raise Discovery_observer_failed)
      ~on_result:(fun candidate outcome ->
        let source = Journal.continuation_source candidate in
        if Masc.Keeper_tool_plan.Composition_run_id.equal source.composition_run_id child_source.composition_run_id then (
          if not (Eio.Promise.is_resolved child) then Eio.Promise.resolve publish_child (candidate,outcome))
        else if Masc.Keeper_tool_plan.Composition_run_id.equal source.composition_run_id parent_source.composition_run_id then (
          if not (Eio.Promise.is_resolved parent) then Eio.Promise.resolve publish_parent (candidate,outcome))) () in
  let independent : Keeper_event_queue.stimulus =
    {post_id="independent-during-prepared-discovery";urgency=Normal;arrived_at=201.;payload=Bootstrap} in
  let require_returned () =
    let base_path,result = Eio.Stream.take observed in
    check string "discovery retains its original workspace" fixture.base_path base_path;
    result |> require "actual fresh prepared discovery" in
  let accepted promise original =
    let candidate,outcome = Eio.Promise.await promise in
    check string "intake retains original canonical waiting request"
      (Journal.continuation_request_id original) (Journal.continuation_request_id candidate);
    check (option string) "intake retains original Task after current turn changes" (Some "task-A")
      (Journal.continuation_source candidate).source_task_id;
    match outcome with
    | Ok (Tool_result.Completed _ as result) -> Tool_result.data result
    | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ -> fail "original continuation was not accepted" in
  set_source fixture ~task_id:"task-other" ~turn:90;
  let completed_child,completed_parent = Eio.Switch.run (fun sw ->
    Fun.protect
      ~finally:(fun () -> if not (Eio.Promise.is_resolved released) then Eio.Promise.resolve release ())
      (fun () ->
        Wake.pulse ~sw supervisor;
        Wake.notify_result_ready ~sw supervisor job_notification;
        Event_registry.enqueue_durable_result ~base_path:fixture.base_path keeper independent
          |> require "independent durable work before discovery observation";
        let base_path,result = Eio.Stream.take observed in
        check string "failed discovery retains original workspace" fixture.base_path base_path;
        (match result with
         | Error error -> check bool "original typed discovery error reaches observation" true (error=original_error)
         | Ok () -> fail "failed or unfinished discovery became success");
        List.iter (fun (name,bytes) -> check string "failed discovery preserves original marker bytes"
          bytes (read (Filename.concat saved_directory name))) original_markers;
        check bool "failed scan admits no child" false (Eio.Promise.is_resolved child);
        Sys.remove directory;
        Unix.rename saved_directory directory;
        write (Filename.concat directory "malformed-marker.json") "not-json\n";
        (* Both triggers arrive while the original error observer is still
           active. Its ordinary failure must leave a fresh original pass due. *)
        Wake.notify_result_ready ~sw supervisor job_notification;
        Wake.pulse ~sw supervisor;
        Eio.Promise.resolve release ();
        require_returned ();
        let child_request = accepted child parked.child_continuation in
        let child_ok,completed_child,_ = await_composition env fixture child_request in
        check bool "fresh discovery resumes the original named child" true child_ok;
        ignore (Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
          |> require "publish original child terminal result");
        Wake.notify_result_ready ~sw supervisor child_notification;
        require_returned ();
        let parent_request = accepted parent parked.parent_continuation in
        let parent_ok,completed_parent,parent_entry = await_composition env fixture parent_request in
        check bool "fresh result demand resumes the original parent" true parent_ok;
        let source = match parent_entry.request_context with
          | Some fields -> `Assoc fields | None -> fail "original parent source context was lost" in
        check_json "completed parent retains original Task" (`String "task-A") (source |> member "source_task_id");
        completed_child,completed_parent)) in
  let stdout_sha = completed_child |> member "exports" |> member "stdout" |> member "value" |> to_string in
  let stdout = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"read-discovery-original-stdout"
      ~turn:91 "keeper_artifact_read" (`Assoc ["sha256",`String stdout_sha])) in
  check_json "recovered original child exposes usable complete stdout" (`String stdout_bytes) (stdout |> member "content");
  check_json "original parent consumes its child's actual result" (`Bool true)
    (completed_parent |> member "exports" |> member "child_result" |> member "available");
  let recovered_job = load fixture parked.job_id in
  check bool "discovery does not replace or rewrite the original completed job" true
    (recovered_job.phase=original_job.phase && recovered_job.outputs=original_job.outputs
     && recovered_job.source=original_job.source);
  check bool "independent durable work survives both original continuations" true
    (pending_completions fixture |> List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
      Keeper_event_queue.stimulus_identity_equal independent selection.source));
  let pending = read_pending () |> require "canonical final prepared discovery" in
  (match pending.ready,pending.failures with
   | [],[name,Journal.Invalid_continuation_marker _] ->
       check string "partial marker failure remains explicit" "malformed-marker.json" name
   | _ -> fail "original continuations remained ready or partial damage disappeared")

type result_signal_scenario = Direct_signal | Delivery_queue_recovery | Observer_scope_cancelled

let test_prepared_result_scope_preserves_original_resources ?(parent_alias=false) ~scenario () =
  with_fixture ~parent_alias @@ fun env _initialize fixture ->
  with_environment ["MASC_CONFIG_DIR",None] @@ fun () ->
  with_parked_named_producer env fixture @@ fun parked ->
  let module Wake = Masc.Keeper_composition_continuation_wake in
  let module Async = Masc.Keeper_msg_async in
  set_source fixture ~task_id:"independent-task" ~turn:80;
  let peer_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"result-scope-independent-job" ~turn:80 "keeper_job_start"
      (`Assoc ["argv",`List [`String "fixture-program"]])) |> job_id in
  let notification (record : Store.record) : Journal.result_notification =
    {base_path=record.base_path;keeper_name=record.keeper_name;
     dependency=Dependency.Owned_job record.job_id} in
  let original_owner = load fixture parked.job_id in
  check string "actual producer hint has the physical journal workspace"
    fixture.base_path original_owner.base_path;
  let original_hint = notification original_owner in
  let discover hint = Journal.discover_pending_continuations
      ~scope:(Journal.Result_notifications [hint]) ~on_ready:ignore
      ~read_composition_result:Masc.Keeper_composition_dependency_result.readiness
      ~base_path:fixture.base_path |> require "actual scoped pending discovery" in
  let not_ready = discover original_hint in
  check (list string) "a hint cannot make a still-running result ready" []
    (List.map Journal.continuation_request_id not_ready.ready);
  check bool "original job wait remains canonically waiting" true (not_ready.waiting > 0);
  check bool "parent's distinct result dependency stays explicitly unselected" true (not_ready.unselected > 0);
  control_jobs fixture [parked.job_id;peer_id] (`Assoc ["state",`String "exited"]);
  List.iter (fun id -> ignore (with_bundle fixture (fun bundle ->
    invoke fixture bundle ~tool_use_id:("collect-scoped-" ^ id) ~turn:81
      "keeper_job_status" (argument id)))) [parked.job_id;peer_id];
  let original_job = load fixture parked.job_id and peer = load fixture peer_id in
  check bool "both distinct actual jobs have durable usable results" true
    (original_job.job_id <> peer.job_id && Store.result_ready original_job && Store.result_ready peer);
  let peer_bytes = read (owner_path fixture peer_id) in
  let other_root = Filename.concat fixture.base_path "another-result-workspace" in
  Unix.mkdir other_root 0o700;
  List.iter (fun hint ->
    let report = discover hint in
    check (list string) "unrelated original coordinates admit no ready candidate" []
      (List.map Journal.continuation_request_id report.ready);
    check bool "unselected is distinct from proved waiting" true (report.unselected > 0);
    check int "unrelated valid marker authority remains readable" 0 (List.length report.failures))
    [notification peer; {original_hint with base_path=other_root};
     {original_hint with keeper_name="another-result-keeper"}];
  let declaration = Config_dir_resolver.keeper_toml_path_for_base_path
      ~base_path:fixture.base_path keeper in
  Fs_compat.mkdir_p (Filename.dirname declaration);
  write declaration "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"inherit\"\ninstructions = \"Original result-scoped continuation fixture\"\n";
  let context : _ Masc.Keeper_types_profile.context =
    {config=parked.config;agent_name="result-scoped-maintenance";
     sw=Async.server_background_switch () |> require "result-scoped background lifetime";
     clock=Eio.Stdenv.clock env;proc_mgr=Some (Eio.Stdenv.process_mgr env);net=None;
     publication_recovery_provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider} in
  let child,publish_child = Eio.Promise.create ()
  and parent,publish_parent = Eio.Promise.create () in
  let supervisor = Wake.create ~context
      ~on_result:(fun candidate outcome ->
        let request_id = Journal.continuation_request_id candidate in
        if String.equal request_id (Journal.continuation_request_id parked.child_continuation) then (
          if not (Eio.Promise.is_resolved child) then Eio.Promise.resolve publish_child (candidate,outcome))
        else if String.equal request_id (Journal.continuation_request_id parked.parent_continuation) then (
          if not (Eio.Promise.is_resolved parent) then Eio.Promise.resolve publish_parent (candidate,outcome))
        else fail "result signal admitted an unrelated canonical continuation") () in
  let accepted promise original =
    let candidate,outcome = Eio.Promise.await promise in
    check string "selected intake keeps exact original canonical request"
      (Journal.continuation_request_id original) (Journal.continuation_request_id candidate);
    check (option string) "selected intake keeps original Task after unrelated work" (Some "task-A")
      (Journal.continuation_source candidate).source_task_id;
    match outcome with
    | Ok (Tool_result.Completed _ as result) -> Tool_result.data result
    | Ok (Tool_result.Deferred _ | Tool_result.Failed _) | Error _ -> fail "selected original intake refused" in
  let independent : Keeper_event_queue.stimulus =
    {post_id="independent-through-composition-signal";urgency=Normal;arrived_at=301.;payload=Bootstrap} in
  Event_registry.enqueue_durable_result ~base_path:fixture.base_path keeper independent
    |> require "independent original queue work before result signal";
  let queue_path = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path:fixture.base_path) keeper)
      Keeper_event_queue_persistence.snapshot_filename in
  let original_queue = read queue_path in
  let alias = Filename.concat fixture.base_path "result-observer-root-alias" in
  Unix.symlink fixture.base_path alias;
  let child_result,parent_result = Eio.Switch.run (fun sw ->
    Masc.Keeper_composition_completion_wake.observe_results ~sw ~base_path:alias
      ~on_result_ready:(Wake.notify_result_ready ~sw supervisor);
    let stopped_observer = match scenario with
      | Direct_signal | Delivery_queue_recovery -> None
      | Observer_scope_cancelled ->
        let installed,mark_installed = Eio.Promise.create () in
        let blocked,_unused_release = Eio.Promise.create () in
        let observer = Eio.Fiber.fork_promise ~sw (fun () ->
          let exception Stop_observer in
          try Eio.Switch.run (fun observer_sw ->
            Masc.Keeper_composition_completion_wake.observe_results
              ~sw:observer_sw ~base_path:alias ~on_result_ready:(fun _ ->
                Eio.Switch.fail observer_sw Stop_observer;
                Eio.Switch.check observer_sw);
            Eio.Promise.resolve mark_installed ();
            Eio.Promise.await blocked)
          with Stop_observer | Eio.Cancel.Cancelled _ -> ()) in
        Eio.Promise.await installed;
        Some observer in
    (match scenario with
     | Delivery_queue_recovery -> write queue_path "actual broken queue snapshot during original child completion"
     | Direct_signal | Observer_scope_cancelled -> ());
    (* Real unrelated and related notifications coalesce before discovery.
       The scope can select the original child without admitting its parent. *)
    Wake.notify_result_ready ~sw supervisor (notification peer);
    Wake.notify_result_ready ~sw supervisor original_hint;
    let child_request = accepted child parked.child_continuation in
    let child_ok,child_result,_ = await_composition env fixture child_request in
    check bool "original child finishes from its saved job result" true child_ok;
    (match scenario with
     | Direct_signal | Observer_scope_cancelled -> ()
     | Delivery_queue_recovery ->
       let failed = Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
         |> require "original child outbox retained through actual queue fault" in
       check bool "exact original physical result retains its failed delivery obligation" true
         (List.exists (fun (request_id,_) -> String.equal request_id
           (child_request |> member "request_id" |> to_string)) failed.failures);
       check bool "queue fault publishes no usable parent result" false (Eio.Promise.is_resolved parent);
       write queue_path original_queue;
       ignore (Masc.Keeper_composition_completion_wake.reconcile ~base_path:fixture.base_path
         |> require "retry actual original completion after queue repair"));
    (* No manual parent result hint or maintenance pulse: direct completion or
       recovered durable delivery must notify the original dependent parent. *)
    let parent_request = accepted parent parked.parent_continuation in
    let parent_ok,parent_result,_ = await_composition env fixture parent_request in
    check bool "original parent consumes its exact named child result" true parent_ok;
    Option.iter Eio.Promise.await_exn stopped_observer;
    child_result,parent_result) in
  let stdout_sha = child_result |> member "exports" |> member "stdout" |> member "value" |> to_string in
  let stdout = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"read-result-scoped-original-stdout" ~turn:82 "keeper_artifact_read"
      (`Assoc ["sha256",`String stdout_sha])) in
  check_json "selected original result remains useful" (`String stdout_bytes) (stdout |> member "content");
  check_json "parent's usable result retains the original child" (`Bool true)
    (parent_result |> member "exports" |> member "child_result" |> member "available");
  check bool "independent queue work survives automatic original parent resumption" true
    (pending_completions fixture |> List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
      Keeper_event_queue.stimulus_identity_equal independent selection.source));
  check string "unrelated job's actual durable owner bytes survive both scoped intakes"
    peer_bytes (read (owner_path fixture peer_id));
  let after = load fixture parked.job_id in
  check bool "original job handle, phase, source and output authority are retained" true
    (after.job_id=original_job.job_id && after.phase=original_job.phase
     && after.source=original_job.source && after.outputs=original_job.outputs)


let test_completion_discovery_failure_preserves_original_result () =
  let channel = Keeper_continuation_channel.dashboard ~thread_id:"discovery-original-thread"
    |> require "original discovery completion channel" in
  with_fixture ~continuation_channel:channel @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle ->
    invoke fixture bundle ~tool_use_id:"collect-before-discovery-failure" ~turn:42
      "keeper_job_status" (argument id)));
  let original = load fixture id in
  check bool "complete original output precedes discovery" true (Store.result_ready original);
  let original_owner = read (owner_path fixture id) in
  let directory = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:fixture.base_path) "keeper_msg_requests")
      "owned_job_completion_pending" in
  let marker_name = id ^ ".json" in
  let marker_bytes = read (Filename.concat directory marker_name) in
  let saved_directory = directory ^ ".fixture-saved" in
  Unix.rename directory saved_directory;
  write directory "original pending directory is unavailable\n";
  let original_error = match Store.pending_deliveries ~base_path:fixture.base_path with
    | Error error -> error
    | Ok _ -> fail "actual pending directory fault did not reject discovery" in
  let exception Discovery_observer_failed in
  let discoveries = Eio.Stream.create 0 in
  let supervisor = Completion_wake.create ~config:(Workspace.default_config fixture.base_path)
      ~on_discovery:(fun ~base_path result ->
        Eio.Stream.add discoveries (base_path,result);
        match result with Ok () -> () | Error _ -> raise Discovery_observer_failed) () in
  let independent : Keeper_event_queue.stimulus =
    {post_id="independent-during-owned-job-discovery";urgency=Normal;
     arrived_at=201.;payload=Bootstrap} in
  let failed = Eio.Switch.run (fun sw ->
    Completion_wake.pulse ~sw supervisor;
    (* Commit actual independent queue work before joining the scan observer;
       no replacement marker reader or manufactured owner is installed. *)
    Event_registry.enqueue_durable_result ~base_path:fixture.base_path keeper independent
      |> require "independent durable work during discovery";
    Eio.Stream.take discoveries) in
  (match failed with
   | base_path, Error error ->
       check string "failed discovery retains its workspace" fixture.base_path base_path;
       check bool "async observation retains the actual typed directory error" true (error=original_error)
   | _, Ok () -> fail "failed or unfinished discovery became success");
  (match pending_completions fixture with
   | [selection] -> check bool "only independent work committed during discovery failure" true
       (Keeper_event_queue.stimulus_identity_equal independent selection.source)
   | [] | _ :: _ -> fail "independent work was lost or a completion was invented");
  check string "failed scan and failed observer preserve original owner bytes"
    original_owner (read (owner_path fixture id));
  check string "failed scan preserves original delivery obligation bytes"
    marker_bytes (read (Filename.concat saved_directory marker_name));
  Sys.remove directory;
  Unix.rename saved_directory directory;
  let damaged_name = Store.Job_id.to_string (Store.Job_id.fresh ()) ^ ".json" in
  let damaged_path = Filename.concat directory damaged_name in
  let damaged_bytes = "not-json\n" in
  write damaged_path damaged_bytes;
  Unix.chmod damaged_path 0o600;
  let fresh_round () =
    let base_path,result = Eio.Switch.run (fun sw ->
      Completion_wake.pulse ~sw supervisor;
      Eio.Stream.take discoveries) in
    check string "fresh discovery retains original workspace" fixture.base_path base_path;
    result |> store_value "fresh original discovery with partial marker damage" in
  let expected : Keeper_event_queue.owned_job_completion =
    {oj_job_id=original.job_id;oj_source=original.source;oj_channel=channel} in
  let completion_post_id = Keeper_event_queue.owned_job_completion_post_id expected in
  let require_original () =
    let pending = pending_completions fixture in
    check bool "independent durable source remains usable after recovery" true
      (List.exists (fun (selection : Keeper_event_queue_state.pending_selection) ->
        Keeper_event_queue.stimulus_identity_equal independent selection.source) pending);
    match List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
        String.equal selection.source.post_id completion_post_id) pending with
    | [selection] ->
        let completion = completion_payload selection in
        check string "only the original job is delivered" id (Store.Job_id.to_string completion.oj_job_id);
        check_json "delivery preserves original Task and turn"
          (Store.source_to_json original.source) (Store.source_to_json completion.oj_source);
        check_json "delivery preserves original conversation"
          (Keeper_continuation_channel.to_yojson channel)
          (Keeper_continuation_channel.to_yojson completion.oj_channel)
    | [] | _ :: _ -> fail "original notification was lost or duplicated" in
  fresh_round ();
  require_original ();
  let delivered = load fixture id in
  check bool "fresh recovery acknowledges original queue delivery" true delivered.completion_delivered;
  check_json "delivery retains complete original result" (Store.result_json original) (Store.result_json delivered);
  fresh_round ();
  require_original ();
  (match Store.pending_deliveries ~base_path:fixture.base_path |> store_value "partial final marker discovery" with
   | {entries=[];failures=[name,Store.Corrupt _]} ->
       check string "partial marker failure retains its original filename" damaged_name name
   | _ -> fail "original cleanup did not retire its marker or partial damage was hidden");
  check string "partial damaged marker bytes remain unchanged" damaged_bytes (read damaged_path);
  let cleaned = load fixture id in
  check bool "cleanup preserves original terminal output" true
    (cleaned.phase=original.phase && cleaned.outputs=original.outputs);
  (match cleaned.outputs with
   | Some (Store.Outputs_complete (stdout,stderr)) ->
       check_artifact_bytes fixture stdout_bytes (Tool_output.normalized_artifact_ref_to_json stdout);
       check_artifact_bytes fixture stderr_bytes (Tool_output.normalized_artifact_ref_to_json stderr)
   | None | Some (Store.Outputs_unavailable _) -> fail "original output bytes were lost")

let test_completion_cancelled_round_preserves_original_result () =
  let module Fence = Masc.Keeper_shutdown_intake_fence in
  let channel = Keeper_continuation_channel.dashboard ~thread_id:"recovery-original-thread"
    |> require "original recovery channel" in
  with_fixture ~continuation_channel:channel @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle ->
    invoke fixture bundle ~tool_use_id:"collect-before-recovery-cancellation" ~turn:42
      "keeper_job_status" (argument id)));
  let original = load fixture id in
  check bool "original complete result is durable before recovery" true (Store.result_ready original);
  let check_original_result (record : Store.record) =
    check string "original job is retained" id (Store.Job_id.to_string record.job_id);
    check_json "original Task and turn survive recovery" (Store.source_to_json original.source)
      (Store.source_to_json record.source);
    check_json "original completion channel survives recovery"
      (Keeper_continuation_channel.to_yojson channel)
      (Keeper_continuation_channel.to_yojson record.completion_channel);
    check bool "original terminal phase survives recovery" true (original.phase = record.phase);
    check bool "original outputs survive recovery" true (original.outputs = record.outputs);
    match record.outputs with
    | Some (Store.Outputs_complete (stdout, stderr)) ->
        check_artifact_bytes fixture stdout_bytes (Tool_output.normalized_artifact_ref_to_json stdout);
        check_artifact_bytes fixture stderr_bytes (Tool_output.normalized_artifact_ref_to_json stderr)
    | None | Some (Store.Outputs_unavailable _) -> fail "complete original output was lost" in
  check_original_result original;
  let discovered, publish_discovered = Eio.Promise.create () in
  let supervisor = Completion_wake.create ~config:(Workspace.default_config fixture.base_path)
      ~on_discovery:(fun ~base_path result ->
        if not (Eio.Promise.is_resolved discovered) then
          Eio.Promise.resolve publish_discovered (base_path,result)) () in
  Eio.Switch.run (fun hold_sw ->
    let entered, enter = Eio.Promise.create () in
    let released, release = Eio.Promise.create () in
    Fun.protect
      ~finally:(fun () ->
        if not (Eio.Promise.is_resolved released) then Eio.Promise.resolve release ())
      (fun () ->
        (* Hold the real Keeper intake mutex. Any admitted recovery child must
           wait here before queue commit, even if discovery yields to it. *)
        let holder = Eio.Fiber.fork_promise ~sw:hold_sw (fun () ->
          Fence.run_durable_intake_if_open ~base_path:fixture.base_path ~keeper_name:keeper
            (fun _ -> Eio.Promise.resolve enter (); Eio.Promise.await released)) in
        Eio.Promise.await entered;
        let exception Stop_recovery_round in
        let cancelled =
          try
            Eio.Switch.run (fun sw ->
              Completion_wake.pulse ~sw supervisor;
              let base_path,result = Eio.Promise.await discovered in
              check string "cancelled round discovered the original workspace" fixture.base_path base_path;
              result |> store_value "original jobs reserved before cancellation";
              Eio.Switch.fail sw Stop_recovery_round);
            false
          with Stop_recovery_round -> true in
        check bool "selected recovery scope joins its cancelled children" true cancelled;
        (match pending_completions fixture with
         | [] -> () | _ :: _ -> fail "cancelled recovery committed through held intake");
        let retained = load fixture id in
        check_original_result retained;
        check bool "undelivered original result remains recoverable" false retained.completion_delivered;
        Eio.Promise.resolve release ();
        match Eio.Promise.await_exn holder with
        | Fence.Intake_committed () -> ()
        | Fence.Intake_shutdown_reserved _ -> fail "admitted original intake holder changed"));
  let pulse () = Eio.Switch.run (fun sw ->
    Completion_wake.pulse ~sw supervisor) in
  pulse ();
  let selected = only_selection fixture in
  let completion = completion_payload selected in
  check string "fresh round delivers the original job" id (Store.Job_id.to_string completion.oj_job_id);
  check_json "delivered source retains original Task and turn"
    (Store.source_to_json original.source) (Store.source_to_json completion.oj_source);
  check_json "delivered notification retains original route"
    (Keeper_continuation_channel.to_yojson channel)
    (Keeper_continuation_channel.to_yojson completion.oj_channel);
  let delivered = load fixture id in
  check_original_result delivered;
  check bool "durable queue delivery acknowledges original owner" true delivered.completion_delivered;
  pulse ();
  let cleaned = load fixture id in
  check_original_result cleaned;
  (match cleaned.cleanup with
   | Store.Resources_removed -> ()
   | Store.Resources_retained | Store.Container_removal_requested | Store.Container_removed
   | Store.Data_removal_requested -> fail "later recovery did not clean original resources");
  let pending = Store.pending_deliveries ~base_path:fixture.base_path
    |> store_value "original delivery marker after cleanup" in
  (match pending.entries, pending.failures with
   | [], [] -> () | _ -> fail "cleaned original owner retained a delivery marker or discovery failure");
  pulse ();
  let repeated = only_selection fixture in
  check string "cleanup and later recovery preserve the single original notification"
    selected.source.post_id repeated.source.post_id

let test_completion_pulse_does_not_join_blocked_backend () = with_fixture @@ fun env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let running = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) in
  let blocked_id = job_id running in
  let config = Workspace.default_config fixture.base_path in
  let failed_observers = ref [] in
  let discovered, publish_discovered = Eio.Promise.create () in
  let supervisor = Completion_wake.create ~config
      ~on_discovery:(fun ~base_path result ->
        if not (Eio.Promise.is_resolved discovered) then
          Eio.Promise.resolve publish_discovered (base_path,result))
      ~on_result_ready:(fun (record : Store.record) ->
      failed_observers := record.job_id :: !failed_observers;
      raise Fixture_result_observer_failed) () in
  let authority_before = read (owner_path fixture blocked_id) in
  reject_cancelled_recovery_scope (fun sw ->
    Completion_wake.pulse ~sw supervisor);
  check string "rejected recovery leaves original owner journal unchanged"
    authority_before (read (owner_path fixture blocked_id));
  let entered = Filename.concat fixture.base_path "inspect-entered" in
  let release = Filename.concat fixture.base_path "inspect-release" in
  control_job fixture blocked_id (`Assoc ["mode", `String "inspect_blocked"]);
  (* Fixture deadlock guard only. The production pulse has no deadline. *)
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. @@ fun () ->
  Eio.Switch.run @@ fun job_sw ->
  Completion_wake.pulse ~sw:job_sw supervisor;
  let base_path,result = Eio.Promise.await discovered in
  check string "completed discovery precedes later independent admission" fixture.base_path base_path;
  result |> store_value "first original discovery completed before independent job";
  let rec await_condition condition =
    if condition () then () else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_condition condition) in
  await_condition (fun () -> Sys.file_exists entered);
  check bool "shared maintenance control returned while backend remains blocked" false (Sys.file_exists release);
  (* The peer retains the blocked inspection's old container snapshot. Open a
     separate original job while that process waits; durable completed output
     recovery of this new job must not join the older inspection. *)
  (* Keep the earlier exact resource while the independent job is created. *)
  set_source fixture ~task_id:"task-B" ~turn:52;
  let later = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-independent" ~turn:52 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program"]])) in
  let later_id = job_id later in
  check bool "independent work owns a distinct original job" true (later_id <> blocked_id);
  write_control fixture ~shared:(`Assoc []) ~armed:[] ~jobs:
    [blocked_id,`Assoc ["mode",`String "inspect_blocked"];
     later_id,`Assoc ["state",`String "exited";"exit_code",`Int 0]];
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-independent" ~turn:53 "keeper_job_status" (argument later_id)));
  let calls_before = List.length (calls fixture) in
  Completion_wake.pulse ~sw:job_sw supervisor;
  await_condition (fun () -> List.length (pending_completions fixture) = 1
      && (load fixture later_id).completion_delivered);
  let completion = only_selection fixture |> completion_payload in
  check string "new completed job delivers while older backend is blocked" later_id
    (Store.Job_id.to_string completion.oj_job_id);
  check int "active blocked worker is not duplicated by another pulse" calls_before (List.length (calls fixture));
  check (list string) "failed observer cannot block the independent result ACK" [later_id]
    (List.map Store.Job_id.to_string !failed_observers);
  check bool "pending first job has not been misclassified completed" false (load fixture blocked_id).completion_delivered;
  write release "continue the original inspection\n";
  Printf.printf "owned_job_completion_supervisor_measurement=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope", `String "synthetic CLI actual maintenance supervisor";
      "pulse_returned_before_backend_release", `Bool true;
      "new_job_delivered_before_backend_release", `Bool true;
      "failed_result_observers", `Int (List.length !failed_observers);
      "duplicate_blocked_worker_backend_calls", `Int 0]))


let test_held_absent_presence_reactivates_only_original_authority () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_created"]);
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let config = Workspace.default_config fixture.base_path in
  let supervisor = Completion_wake.create ~config () in
  let pulse supervisor = Eio.Switch.run @@ fun sw ->
    Completion_wake.pulse ~sw supervisor in
  control_job fixture id (`Assoc ["mode", `String "hide_owner_inventory"]);
  let before = List.length (calls fixture) in
  pulse supervisor;
  let full_absence_calls = List.length (calls fixture) - before in
  check int "initial absence requires daemon and exact inventory" 2 full_absence_calls;
  let owner_bytes = read (owner_path fixture id) in
  let before = List.length (calls fixture) in
  pulse supervisor;
  let held_presence_calls = List.length (calls fixture) - before in
  check int "unchanged held absence uses one exact inventory hint" 1 held_presence_calls;
  check string "a missing presence hint does not rewrite the owner" owner_bytes (read (owner_path fixture id));
  let restarted = Completion_wake.create ~config () in
  let before = List.length (calls fixture) in
  pulse restarted;
  check int "fresh supervisor cannot inherit process-local absence" 2 (List.length (calls fixture) - before);
  let record = load fixture id in
  let paths = Store.paths ~base_path:fixture.base_path record.job_id in
  let injected = Filename.concat paths.cli_config_dir "config.json" in
  write injected "{}";
  let before = List.length (calls fixture) in
  pulse supervisor;
  check int "private CLI changes refuse before even the presence command" before (List.length (calls fixture));
  check int "presence refusal cannot launch the original program" 0 (effect_count fixture "start");
  Unix.unlink injected;
  let before = List.length (calls fixture) in
  pulse supervisor;
  check int "failed presence evidence is cleared before recovery" 2 (List.length (calls fixture) - before);
  control_shared fixture (`Assoc ["daemon_id", `String "replacement-daemon"]);
  pulse supervisor;
  check int "positive hint cannot bypass original daemon identity" 0 (effect_count fixture "start");
  check bool "foreign daemon never advances original create intent" true ((load fixture id).phase=Store.Create_requested);
  control_reset fixture ();
  pulse supervisor;
  check int "late original container is started once" 1 (effect_count fixture "start");
  check int "reactivation never prepares another container" 1 (effect_count fixture "create");
  (match (load fixture id).phase with Store.Running _ -> () | _ -> fail "late original did not resume");
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 7]);
  pulse supervisor;
  let completion = only_selection fixture |> completion_payload in
  check string "eventual result names the exact original job" id (Store.Job_id.to_string completion.oj_job_id);
  check bool "original result is acknowledged after durable notification" true (load fixture id).completion_delivered;
  Printf.printf "owned_job_held_presence_measurement=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope", `String "synthetic CLI actual maintenance supervisor";
      "full_absence_backend_calls", `Int full_absence_calls;
      "unchanged_held_backend_calls", `Int held_presence_calls;
      "owner_unchanged_on_hint", `Bool true;
      "original_creates", `Int (effect_count fixture "create");
      "original_starts", `Int (effect_count fixture "start");
      "original_result_delivered", `Bool true]))

let test_shared_held_presence_round ~different_endpoint () = with_fixture @@ fun env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let launch tool_use_id = with_bundle fixture (fun bundle ->
    invoke fixture bundle ~tool_use_id ~turn:41 "keeper_job_start"
      (`Assoc ["argv",`List [`String "fixture-program"]])) |> job_id in
  control_launch fixture ~tool_use_id:"shared-presence-first" ~keeper_turn_id:(Some 41) (`Assoc ["mode",`String "create_unknown_created"]);
  let first = launch "shared-presence-first" in
  control_launch fixture ~tool_use_id:"shared-presence-second" ~keeper_turn_id:(Some 41) (`Assoc ["mode",`String "create_unknown_absent"]);
  let second = if different_endpoint then
      with_environment ["DOCKER_HOST",Some "unix:///fixture/other-docker.sock"] (fun () -> launch "shared-presence-second")
    else launch "shared-presence-second" in
  check bool "the scenario owns two distinct original jobs" true (first<>second);
  let transport_calls () = read (Filename.concat fixture.base_path "transport-events.jsonl")
    |> String.split_on_char '\n' |> List.filter (fun line -> String.trim line<>"")
    |> List.map Yojson.Safe.from_string
    |> List.filter (fun row -> member "event" row=`String "entered")
    |> List.map (fun row -> member "argv" row |> to_list |> List.map to_string) in
  let call_count () = List.length (transport_calls ()) in
  let option name args =
    let rec find = function
      | key::value::_ when key=name -> value
      | _::rest -> find rest
      | [] -> fail ("transport omitted " ^ name) in
    find args in
  let pending_discovery = ref None in
  let supervisor = Completion_wake.create ~config:(Workspace.default_config fixture.base_path)
      ~on_discovery:(fun ~base_path result ->
        match !pending_discovery with
        | None -> ()
        | Some publish ->
            pending_discovery := None;
            Eio.Promise.resolve publish (base_path,result)) () in
  let discover ~sw =
    let observed,publish = Eio.Promise.create () in
    pending_discovery := Some publish;
    Completion_wake.pulse ~sw supervisor;
    let base_path,result = Eio.Promise.await observed in
    check string "shared backend scan retains original workspace" fixture.base_path base_path;
    result |> store_value "actual shared maintenance discovery" in
  let pulse () = Eio.Switch.run (fun sw -> discover ~sw) in
  control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory"]);
  let before = call_count () in
  pulse ();
  check int "fresh owners each retain full daemon and inventory verification" 4 (call_count ()-before);
  let owners = List.map (fun id -> id,read (owner_path fixture id)) [first;second] in
  let before = call_count () in
  if different_endpoint then pulse () else (
    control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory";"presence_blocked",`Bool true]);
    Eio.Switch.run (fun sw ->
      discover ~sw;
      let entered = Filename.concat fixture.base_path "presence-entered" in
      let rec await_shared () =
        if Sys.file_exists entered then ()
        else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;await_shared ()) in
      await_shared ();
      let active_calls = call_count () in
      discover ~sw;
      check int "another pulse cannot duplicate the blocked original read" active_calls (call_count ());
      write (Filename.concat fixture.base_path "presence-release") "release original shared inventory\n");
    control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory"]));
  let batch_calls = List.drop before (transport_calls ()) in
  let routes = if different_endpoint then 2 else 1 in
  check int "one shared inventory per exact frozen backend route" routes (List.length batch_calls);
  let private_clis = List.map (fun id ->
    let job_id = Store.Job_id.of_string id |> require "typed shared job" in
    (Store.paths ~base_path:fixture.base_path job_id).cli_config_dir) [first;second] in
  List.iter (fun args ->
    let cli = option "--config" args in
    check bool "shared observation never borrows either job's CLI" false (List.mem cli private_clis);
    check bool "completed shared read releases its exact empty CLI scope" false (Sys.file_exists cli)) batch_calls;
  check int "different frozen endpoints never join one read" routes
    (List.length (List.sort_uniq String.compare (List.map (option "--host") batch_calls)));
  List.iter (fun (id,bytes) -> check string "absence cannot rewrite an original owner"
    bytes (read (owner_path fixture id))) owners;
  check int "presence observation does not start a program" 0 (effect_count fixture "start");
  if not different_endpoint then (
    control_shared fixture (`Assoc ["presence_wrong_scope",`Bool true]);
    let before = call_count () in
    pulse ();
    check int "a malformed shared ownership projection is fetched once" 1 (call_count ()-before);
    check int "foreign projected ownership cannot start either job" 0 (effect_count fixture "start");
    control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory"]);
    let before = call_count () in
    pulse ();
    check int "failed shared evidence clears each owner's held hint" 4 (call_count ()-before);
    let injected = Filename.concat (List.hd private_clis) "config.json" in
    write injected "{}";
    let before = call_count () in
    pulse ();
    check int "one changed private CLI cannot stop the other owner from observing" 1 (call_count ()-before);
    Unix.unlink injected;
    pulse ();
    pulse ();
    control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory";"presence_unavailable",`Bool true]);
    let before = call_count () in
    pulse ();
    check int "one failed transport is shared without per-job retry" 1 (call_count ()-before);
    control_jobs fixture [first;second] (`Assoc ["mode",`String "hide_owner_inventory"]);
    let before = call_count () in
    pulse ();
    check int "transport failure sends both original owners through full recovery" 4 (call_count ()-before);
    let second_owner = read (owner_path fixture second) in
    control_shared fixture (`Assoc ["presence_padding_bytes",`Int
      (Common.max_process_capture_head_bytes+Common.max_process_capture_tail_bytes+1)]);
    pulse ();
    check int "late original in the middle of a complete inventory starts only its original program" 1 (effect_count fixture "start");
    check int "shared hints never prepare replacement programs" 2 (effect_count fixture "create");
    check string "another original job stays held without a phase rewrite" second_owner (read (owner_path fixture second));
    (match (load fixture first).phase with Store.Running _ -> () | _ -> fail "the original visible job did not resume");
    control_job fixture first (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
    pulse ();
    let completion = only_selection fixture |> completion_payload in
    check string "durable result delivery keeps the exact original job" first (Store.Job_id.to_string completion.oj_job_id));
  Printf.printf "owned_job_shared_presence_round=%s\n%!"
    (Yojson.Safe.to_string (`Assoc ["scope",`String "synthetic CLI actual maintenance supervisor";
      "held_original_jobs",`Int 2;"distinct_frozen_backend_routes",`Int routes;
      "as_is_expected_per_job_presence_calls",`Int 2;"after_observed_shared_presence_calls",`Int (List.length batch_calls);
      "borrows_job_private_cli",`Bool false;"original_owner_bytes_unchanged_on_absence",`Bool true]))

let test_changed_cancel_intent_bypasses_held_presence () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode", `String "create_unknown_created"]);
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let supervisor = Completion_wake.create ~config:(Workspace.default_config fixture.base_path) () in
  let pulse () = Eio.Switch.run @@ fun sw ->
    Completion_wake.pulse ~sw supervisor in
  control_job fixture id (`Assoc ["mode", `String "hide_owner_inventory"]);
  pulse ();
  let current = load fixture id in
  ignore (Store.transition current ~phase:current.phase ~cancel_requested:true
    ~outputs:current.outputs ~detail:current.detail |> store_value "durable original cancellation intent");
  let before = List.length (calls fixture) in
  pulse ();
  check int "changed cancellation requires full inspection, not a held hint" 2 (List.length (calls fixture) - before);
  let current = load fixture id in
  check bool "original cancelled launch closes explicitly" true (current.phase=Store.Cancelled_unconfirmed_launch);
  check bool "cancelled result is delivered instead of waiting on stale absence" true current.completion_delivered;
  check int "cancellation never recreates the uncertain program" 1 (effect_count fixture "create");
  check int "cancellation never starts the uncertain program" 0 (effect_count fixture "start")

let test_completion_recovery_preserves_refused_owner_bytes () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let first_id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let first_path = owner_path fixture first_id in
  let original_first = read first_path in
  (* Keep the earlier exact resource while the independent job is created. *)
  set_source fixture ~task_id:"task-B" ~turn:52;
  let foreign_id = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"start-foreign" ~turn:52 "keeper_job_start"
      (`Assoc ["argv", `List [`String "fixture-program"]])) |> job_id in
  control_job fixture foreign_id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"collect-foreign" ~turn:53 "keeper_job_status" (argument foreign_id)));
  let foreign_prefix = read (owner_path fixture foreign_id) in
  let foreign_bytes = foreign_prefix ^ "{\"completion_delivered\":tr" in
  write first_path foreign_bytes;
  let before = List.length (calls fixture) in
  let refused = recover_completions fixture in
  check int "foreign complete prefix is refused before tail repair" 1 (List.length refused.failures);
  check string "foreign owner and torn suffix retain all original evidence" foreign_bytes (read first_path);
  check int "foreign authority authorizes no backend call" before (List.length (calls fixture));
  check string "valid independent original result still delivers" foreign_id
    (Store.Job_id.to_string (only_selection fixture |> completion_payload).oj_job_id);
  let corrupt_bytes = "complete malformed owner row\n{\"partial\":" in
  write first_path corrupt_bytes;
  let corrupt = recover_completions fixture in
  check int "complete malformed prefix stays refused" 1 (List.length corrupt.failures);
  check string "complete corruption and incomplete suffix remain byte-identical" corrupt_bytes (read first_path);
  check int "independent valid acknowledged owner alone authorizes cleanup" 1 (effect_count fixture "rm");
  check int "corrupt owner never authorizes another program launch" 2 (effect_count fixture "create");
  write first_path original_first;
  check bool "original authority remains recoverable after restoration" false (load fixture first_id).completion_delivered

let terminal_cleanup_fixture fixture =
  set_source fixture ~task_id:"task-A" ~turn:41;
  let input = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:fixture.base_path)
    ~bytes:"cleanup immutable input" ~mime:"text/plain" in
  let inputs = [`Assoc ["path",`String "input.txt";
    "artifact",Tool_output.normalized_artifact_ref_to_json input]] in
  let id = with_bundle fixture (fun bundle -> start fixture bundle ~inputs ["fixture-program"]) |> job_id in
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  let completed = with_bundle fixture (fun bundle -> invoke fixture bundle
    ~tool_use_id:"collect-before-cleanup" ~turn:42 "keeper_job_status" (argument id)) in
  let delivered = recover_completions fixture in
  check int "terminal result delivery precedes cleanup" 1 delivered.delivered;
  check int "result delivery issues no container removal" 0 (effect_count fixture "rm");
  let original = load fixture id in
  check bool "original owner acknowledged before cleanup" true original.completion_delivered;
  let paths = Store.paths ~base_path:fixture.base_path original.job_id in
  id,paths,completed,original

let check_cleaned_original fixture id (original : Store.record) =
  let record = load fixture id in
  check bool "resource cleanup is confirmed" true (record.cleanup=Store.Resources_removed);
  check_json "cleanup retains original source" (Store.source_to_json original.source)
    (Store.source_to_json record.source);
  check bool "cleanup retains exact terminal phase" true (record.phase=original.phase);
  check bool "cleanup retains exact full output references" true (record.outputs=original.outputs);
  let pending = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "cleanup discovery" in
  check int "only confirmed cleanup retires discovery" 0 (List.length pending.entries);
  check int "original completion stays queued once" 1 (List.length (pending_completions fixture));
  let before = List.length (calls fixture) in
  set_source fixture ~task_id:"task-B" ~turn:52;
  let result = with_bundle fixture (fun bundle -> invoke fixture bundle
    ~tool_use_id:"read-after-cleanup" ~turn:52 "keeper_job_result" (argument id)) in
  let status = with_bundle fixture (fun bundle -> invoke fixture bundle
    ~tool_use_id:"status-after-cleanup" ~turn:52 "keeper_job_status" (argument id)) in
  check_original_source fixture result;
  check string "public status exposes confirmed cleanup" "resources_removed" (status |> member "cleanup" |> to_string);
  check int "result and status after cleanup use no backend" before (List.length (calls fixture));
  result

let test_terminal_cleanup_preserves_result_and_gc () = with_fixture @@ fun _env _initialize fixture ->
  let id,paths,completed,original = terminal_cleanup_fixture fixture in
  let outside = Filename.concat fixture.base_path "unrelated-output" in
  Unix.mkdir outside 0o700;
  let sentinel = Filename.concat outside "keep.txt" in write sentinel "keep unrelated bytes";
  Unix.symlink outside (Filename.concat paths.workspace "unrelated-link");
  Unix.link sentinel (Filename.concat paths.workspace "unrelated-hardlink");
  Unix.mkfifo (Filename.concat paths.workspace "program-pipe") 0o600;
  let cleanup_backend_before = List.length (calls fixture) in
  let counter = Mtime_clock.counter () in
  let report = recover_completions fixture in
  let cleanup_ms = Mtime.Span.to_float_ns (Mtime_clock.count counter) /. 1_000_000. in
  check int "cleanup retires one terminal obligation" 1 report.retired;
  check string "cleanup never follows a program link" "keep unrelated bytes" (read sentinel);
  check bool "private workspace CLI and captures are removed" false (Sys.file_exists (Filename.dirname paths.workspace));
  let result = check_cleaned_original fixture id original in
  check_json "public result retains complete original output" (completed |> member "artifacts") (result |> member "artifacts");
  (match result |> member "artifacts" |> to_list with
   | [stdout;stderr] -> check_artifact_bytes fixture stdout_bytes stdout; check_artifact_bytes fixture stderr_bytes stderr
   | _ -> fail "cleanup lost an original stream");
  let owner = read (owner_path fixture id) in
  check bool "canonical owner journal remains after data cleanup" true (String.length owner > 0);
  ignore (Tool_blob_maintenance.run ~base_path:fixture.base_path
    ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode:Tool_blob_maintenance.Observe_only
    |> require "GC observation after cleanup");
  let candidates = read (Tool_blob_maintenance.candidate_snapshot_path ~base_path:fixture.base_path)
    |> Yojson.Safe.from_string |> member "unreferenced_candidates" |> to_list |> List.map to_string in
  let references = Tool_output.normalized_artifact_refs_in_json (Yojson.Safe.from_string
    (List.hd (String.split_on_char '\n' owner))) in
  let references = references @ (match original.outputs with
    | Some (Store.Outputs_complete (stdout,stderr)) -> [stdout;stderr]
    | Some (Store.Outputs_unavailable {evidence}) ->
      failf "cleanup fixture output is unavailable: %s" evidence
    | None -> fail "cleanup fixture has no complete original outputs") in
  List.iter (fun (reference : Tool_output.artifact_ref) -> check bool "retained owner remains a GC root" false
    (List.mem reference.sha256 candidates)) references;
  check int "one exact terminal container removal" 1 (effect_count fixture "rm");
  check int "cleanup never creates a replacement program" 1 (effect_count fixture "create");
  check int "cleanup never restarts the program" 1 (effect_count fixture "start");
  Printf.printf "owned_job_cleanup_measurement=%s\n%!" (Yojson.Safe.to_string (`Assoc
    ["scope",`String "synthetic CLI actual terminal cleanup";"cleanup_ms",`Float cleanup_ms;
     "container_removals",`Int 1;"program_replays",`Int 0;
     "cleanup_backend_calls",`Int (List.length (calls fixture)-cleanup_backend_before);
     "complete_outputs_retained",`Bool true;"private_data_removed",`Bool true]))

let test_cleanup_refuses_backend_change fault = with_fixture @@ fun _env _initialize fixture ->
  let id,paths,_,original = terminal_cleanup_fixture fixture in
  control_job fixture id (`Assoc fault);
  let refused = recover_completions fixture in
  check int "changed backend retains cleanup failure" 1 (List.length refused.failures);
  check int "changed authority never removes a container" 0 (effect_count fixture "rm");
  check bool "refused cleanup preserves private data" true (Sys.file_exists paths.workspace);
  check bool "unconfirmed cleanup retains its durable intent" true
    ((load fixture id).cleanup=Store.Container_removal_requested);
  let pending = Store.pending_deliveries ~base_path:fixture.base_path |> store_value "refused cleanup discovery" in
  check int "refused cleanup stays discoverable" 1 (List.length pending.entries);
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7;"restore_identity",`Bool true]);
  check int "restored original resource can be cleaned" 1 (recover_completions fixture).retired;
  ignore (check_cleaned_original fixture id original)

let test_cleanup_recovers_lost_remove_receipt () = with_fixture @@ fun _env initialize fixture ->
  let id,paths,_,original = terminal_cleanup_fixture fixture in
  control_job fixture id (`Assoc ["mode",`String "remove_unknown_removed"]);
  let uncertain = recover_completions fixture in
  check int "lost removal receipt remains unconfirmed" 1 (List.length uncertain.failures);
  check int "the original remove actually ran once" 1 (effect_count fixture "rm");
  check bool "actual container is gone before confirmation" true (fixture_container fixture id = `Null);
  check bool "data waits for canonical container absence" true (Sys.file_exists paths.workspace);
  check bool "removal intent survives missing receipt" true ((load fixture id).cleanup=Store.Container_removal_requested);
  Process_eio.reset_for_testing (); initialize ();
  control_reset fixture ();
  check int "fresh maintenance confirms the original absence" 1 (recover_completions fixture).retired;
  check int "absence recovery never repeats removal" 1 (effect_count fixture "rm");
  ignore (check_cleaned_original fixture id original)

let enter_original_data_cleanup (original : Store.record) =
  (* Stop between real durable cleanup boundaries, with the actual producer's
     removal receipt. No fabricated owner or backend absence is substituted. *)
  let intent = Store.advance_cleanup original Store.Container_removal_requested |> store_value "real cleanup intent" in
  Masc.Keeper_owned_job_backend.remove_container ~target:(match original.phase with
    | Store.Exited {container_id;exit_code} -> Masc.Keeper_owned_job_backend.After_exit {container_id;exit_code}
    | Store.Prepared | Store.Create_requested | Store.Created _ | Store.Start_requested _
    | Store.Running _ | Store.Cancelled_before_start _ | Store.Cancelled_unconfirmed_launch -> fail "original terminal handle") original.preparation
    |> require "actual original container removal";
  let removed = Store.advance_cleanup intent Store.Container_removed |> store_value "actual removal confirmation" in
  Store.advance_cleanup removed Store.Data_removal_requested |> store_value "real data cleanup intent"

let test_cleanup_recovers_partial_data ~symbolic_replacement () = with_fixture @@ fun _env initialize fixture ->
  let id,paths,_,original = terminal_cleanup_fixture fixture in
  ignore (enter_original_data_cleanup original);
  Unix.unlink (Filename.concat paths.workspace "input.txt");
  Unix.rmdir paths.cli_config_dir;
  let data = Filename.dirname paths.workspace in
  let detached = Filename.concat fixture.base_path "interrupted-original-data" in
  Unix.rename data detached;
  let foreign = Filename.concat fixture.base_path "unrelated-cleanup-target" in
  Unix.mkdir foreign 0o700;
  write (Filename.concat foreign "keep.txt") "foreign target remains";
  if symbolic_replacement then Unix.symlink foreign data
  else (Unix.mkdir data 0o700; write (Filename.concat data "keep.txt") "replacement remains");
  Process_eio.reset_for_testing (); initialize ();
  let backend_before = List.length (calls fixture) in
  let refused = recover_completions fixture in
  check int "replacement data identity refuses cleanup" 1 (List.length refused.failures);
  check string "unrelated target remains untouched" "foreign target remains" (read (Filename.concat foreign "keep.txt"));
  if symbolic_replacement then Unix.unlink data
  else (check string "replacement tree remains untouched" "replacement remains" (read (Filename.concat data "keep.txt"));
    Unix.unlink (Filename.concat data "keep.txt"); Unix.rmdir data);
  Unix.rename detached data;
  check int "fresh maintenance resumes partial original data cleanup" 1 (recover_completions fixture).retired;
  check bool "partial original data is fully removed" false (Sys.file_exists data);
  check int "data cleanup recovery performs no Docker I/O" backend_before (List.length (calls fixture));
  ignore (check_cleaned_original fixture id original)

let test_cleanup_recovers_data_absence_under_original_parent () = with_fixture @@ fun _env initialize fixture ->
  let id,paths,_,original = terminal_cleanup_fixture fixture in
  ignore (enter_original_data_cleanup original);
  Masc.Keeper_owned_job_backend.remove_data original.preparation |> require "actual complete original data removal";
  let data = Filename.dirname paths.workspace in
  check bool "data effect finished before journal confirmation" false (Sys.file_exists data);
  let parent = Filename.dirname data in
  let held = Filename.concat fixture.base_path "original-owned-data-parent" in
  Unix.rename parent held;
  Unix.mkdir parent 0o700;
  let sentinel = Filename.concat parent "keep.txt" in write sentinel "replacement parent remains";
  Process_eio.reset_for_testing (); initialize ();
  let backend_before = List.length (calls fixture) in
  let refused = recover_completions fixture in
  check int "target absence cannot bypass changed parent authority" 1 (List.length refused.failures);
  check string "replacement parent remains untouched" "replacement parent remains" (read sentinel);
  Unix.unlink sentinel; Unix.rmdir parent; Unix.rename held parent;
  check int "original parent confirms lost successful data removal" 1 (recover_completions fixture).retired;
  check int "confirmed original data absence needs no Docker call" backend_before (List.length (calls fixture));
  ignore (check_cleaned_original fixture id original)

let test_cleanup_cancelled_before_start () = with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  control_launch fixture ~tool_use_id:"start-original" ~keeper_turn_id:(Some 41) (`Assoc ["mode",`String "create_unknown_created"]);
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  control_reset fixture ();
  let cancelled = with_bundle fixture (fun bundle -> invoke fixture bundle ~tool_use_id:"cancel-created"
    ~turn:42 "keeper_job_cancel" (argument id)) in
  check string "actual created job cancels before start" "cancelled_before_start" (cancelled |> member "phase" |> to_string);
  check int "cancelled program was never started" 0 (effect_count fixture "start");
  check int "before-start cancellation is delivered first" 1 (recover_completions fixture).delivered;
  let original = load fixture id in
  check int "the exact created container is later cleaned" 1 (recover_completions fixture).retired;
  check int "one exact created-container removal" 1 (effect_count fixture "rm");
  let result = check_cleaned_original fixture id original in
  check_json "before-start cancellation does not fabricate logs" (`List []) (result |> member "artifacts")


let test_parent_alias_keeps_original_job_and_outputs () =
  with_fixture ~parent_alias:true @@ fun _env initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let input_bytes = "original alias input\n" in
  let input = Tool_blob_store.put_durable store ~bytes:input_bytes ~mime:"text/plain" in
  let inputs = [`Assoc ["path",`String "input.txt";
      "artifact",Tool_output.normalized_artifact_ref_to_json input]] in
  let argv = ["fixture-program";"input.txt"] in
  let started = with_bundle fixture (fun bundle -> start fixture bundle ~inputs argv) in
  let id = job_id started in
  let original = load fixture id in
  let module Backend = Masc.Keeper_owned_job_backend in
  let spec = Backend.specification original.preparation in
  check string "owner records the physical workspace" fixture.base_path original.base_path;
  check string "backend preparation uses the same physical workspace" original.base_path spec.base_path;
  let paths = Store.paths ~base_path:fixture.base_path original.job_id in
  check string "original input reaches the actual private workspace" input_bytes
    (read (Filename.concat paths.workspace "input.txt"));
  check string "actual bind mount agrees with the canonical owner" paths.workspace
    (fixture_container fixture id |> member "Mounts" |> to_list |> List.hd |> member "Source" |> to_string);
  Process_eio.reset_for_testing (); initialize ();
  let replayed = with_bundle fixture (fun bundle -> start fixture bundle ~inputs argv) in
  check string "original invocation through the alias reuses its durable job" id (job_id replayed);
  set_source fixture ~task_id:"task-B" ~turn:52;
  control_job fixture id (`Assoc ["state",`String "exited";"exit_code",`Int 7]);
  ignore (with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"alias-original-status" ~turn:52 "keeper_job_status" (argument id)));
  let result = with_bundle fixture (fun bundle -> invoke fixture bundle
      ~tool_use_id:"alias-original-result" ~turn:52 "keeper_job_result" (argument id)) in
  check bool "the alias returns the original usable result" true (result |> member "result_ready" |> to_bool);
  check int "original exit code survives the alias" 7 (result |> member "exit_code" |> to_int);
  let completed = load fixture id in
  let from_alias = Store.load ~base_path:fixture.configured_base_path ~keeper_name:keeper original.job_id
    |> store_value "same original job through the alias" in
  let recovered = Store.recover ~base_path:fixture.configured_base_path ~keeper_name:keeper original.job_id
    |> store_value "same committed original owner through alias recovery" in
  check bool "physical and aliased reads retain the same committed owner" true
    (completed=from_alias && completed=recovered);
  check bool "source and inputs survive replay and later Task" true
    (completed.source=original.source && completed.inputs=original.inputs);
  check_json "frozen original preparation is not rewritten on reads"
    (Backend.preparation_to_json original.preparation) (Backend.preparation_to_json completed.preparation);
  check_original_source fixture (Store.result_json completed);
  (match completed.outputs with
   | Some (Store.Outputs_complete (stdout,stderr)) ->
     List.iter (fun (reference,bytes) ->
       check (option string) "actual original output bytes remain readable" (Some bytes)
         (Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 |> require "original alias output"))
       [stdout,stdout_bytes;stderr,stderr_bytes]
   | None | Some (Store.Outputs_unavailable _) -> fail "alias lost original complete outputs")

let test_parent_alias_retarget_cannot_borrow_original_authority () =
  with_fixture ~parent_alias:true @@ fun _env _initialize fixture ->
  let module Backend = Masc.Keeper_owned_job_backend in
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  let original = load fixture id in
  let owner = owner_path fixture id in
  let original_bytes = read owner in
  let foreign_parent = Filename.concat fixture.base_path "foreign-parent" in
  let foreign_root = Filename.concat foreign_parent (Filename.basename fixture.base_path) in
  Fs_compat.mkdir_p foreign_root;
  let foreign_paths = Store.paths ~base_path:foreign_root original.job_id in
  Fs_compat.mkdir_p foreign_paths.job_dir;
  let foreign_owner = Filename.concat foreign_paths.job_dir "owner.jsonl" in
  write foreign_owner original_bytes;
  Unix.chmod foreign_owner 0o600;
  (match Store.load ~base_path:foreign_root ~keeper_name:keeper original.job_id with
   | Error (Store.Invalid_authority _) -> ()
   | Ok _ | Error (Corrupt _ | Missing | Conflict | Io_failed _ | Commit_unconfirmed _) ->
     fail "a copied original journal must not acquire foreign workspace authority");
  let alias = Filename.dirname fixture.configured_base_path in
  Unix.unlink alias;
  Unix.symlink foreign_parent alias;
  let spec = Backend.specification original.preparation in
  let original_paths = Store.paths ~base_path:fixture.base_path original.job_id in
  (match Backend.prepare ~config:(Workspace.default_config fixture.configured_base_path)
      ~meta:fixture.meta ~docker_config_path:original_paths.cli_config_dir spec with
   | Error (Backend.Invalid_spec _) -> ()
   | Ok _ | Error (Image_refused _ | Preparation_refused _ | Process_refused _ | Command_failed _
       | Response_rejected _ | Log_capture_incomplete _ | Log_capture_failed _ | Log_publication_failed _) ->
     fail "retargeted configuration must refuse the original preparation before backend effects");
  (match Store.load ~base_path:fixture.configured_base_path ~keeper_name:keeper original.job_id with
   | Error (Store.Invalid_authority _) -> ()
   | Ok _ | Error (Corrupt _ | Missing | Conflict | Io_failed _ | Commit_unconfirmed _) ->
     fail "retargeted alias must not inherit the copied original owner");
  let leaf_alias = Filename.concat fixture.base_path "root-leaf-alias" in
  Unix.symlink fixture.base_path leaf_alias;
  (match Store.load ~base_path:leaf_alias ~keeper_name:keeper original.job_id with
   | Error (Store.Invalid_authority _) -> ()
   | Ok _ | Error (Corrupt _ | Missing | Conflict | Io_failed _ | Commit_unconfirmed _) ->
     fail "root-leaf symlink must remain refused");
  (match Store.load ~base_path:(Filename.concat fixture.base_path "missing-root") ~keeper_name:keeper original.job_id with
   | Error Store.Missing -> ()
   | Ok _ | Error (Invalid_authority _ | Corrupt _ | Conflict | Io_failed _ | Commit_unconfirmed _) ->
     fail "missing original authority must stay missing");
  check string "foreign copied journal is never rewritten" original_bytes (read foreign_owner);
  check string "original durable owner is never rewritten" original_bytes (read owner);
  (match Backend.inspect original.preparation with
   | Backend.Running container_id ->
     (match original.phase with
      | Store.Running original_id -> check string "original running container retains its frozen authority" original_id container_id
      | Prepared | Create_requested | Created _ | Start_requested _ | Exited _ | Cancelled_before_start _
      | Cancelled_unconfirmed_launch -> fail "original job did not start")
   | Absent | Created _ | Stopped _ | Unconfirmed _ -> fail "retargeted alias disturbed the original backend")

let () = match Array.to_list Sys.argv with
  | [_;"--lose-native-parent-after-child-acceptance";base_path;draft_sha;run_id] ->
    lose_native_parent_after_child_acceptance base_path draft_sha run_id
  | _ ->
  Printf.printf "owned_job_feature_transport=synthetic_docker_cli actual_public_handler=true actual_docker_execution=false\n%!";
  run "Keeper owned jobs"
    ["public lifecycle",
      [ test_case "structured launch, original source, restart and artifact ownership" `Quick test_running_restart_exit_and_artifacts
      ; test_case "parent-directory alias retains original invocation, input and complete outputs" `Quick
          test_parent_alias_keeps_original_job_and_outputs
      ; test_case "retargeted parent alias and copied owner cannot borrow original authority" `Quick
          test_parent_alias_retarget_cannot_borrow_original_authority
      ; test_case "aliased producer automatically resumes original child and parent" `Quick
          (test_prepared_result_scope_preserves_original_resources ~parent_alias:true ~scenario:Direct_signal)
      ; test_case "terminal cleanup preserves full result and GC ownership" `Quick test_terminal_cleanup_preserves_result_and_gc
      ; test_case "cleanup refuses a changed daemon" `Quick (fun () -> test_cleanup_refuses_backend_change ["daemon_id",`String "different-daemon"])
      ; test_case "cleanup refuses a same-label replacement container" `Quick (fun () -> test_cleanup_refuses_backend_change ["replacement",`Bool true])
      ; test_case "cleanup refuses a running terminal resource" `Quick (fun () -> test_cleanup_refuses_backend_change ["state",`String "running"])
      ; test_case "cleanup refuses a changed terminal exit code" `Quick (fun () -> test_cleanup_refuses_backend_change ["state",`String "exited";"exit_code",`Int 99])
      ; test_case "cleanup checks saved ID beyond owner-label absence" `Quick (fun () -> test_cleanup_refuses_backend_change ["mode",`String "hide_owner_inventory"])
      ; test_case "cleanup refuses changed private mount authority" `Quick (fun () -> test_cleanup_refuses_backend_change ["corrupt",`String "mount"])
      ; test_case "fresh maintenance recovers a lost successful removal receipt" `Quick test_cleanup_recovers_lost_remove_receipt
      ; test_case "partial data cleanup refuses a replaced original tree" `Quick (test_cleanup_recovers_partial_data ~symbolic_replacement:false)
      ; test_case "partial data cleanup never follows a replaced root symlink" `Quick (test_cleanup_recovers_partial_data ~symbolic_replacement:true)
      ; test_case "lost data removal confirmation retains exact parent authority" `Quick test_cleanup_recovers_data_absence_under_original_parent
      ; test_case "cancelled-before-start job cleans its exact created resources" `Quick test_cleanup_cancelled_before_start
      ; test_case "unknown create absence cannot relaunch" `Quick test_unknown_create_absence_never_replays
      ; test_case "unknown start absence cannot restart" `Quick test_unknown_start_absence_never_replays
      ; test_case "created backend absence reports a typed hold instead of ready" `Quick
          test_created_absence_reports_hold_instead_of_ready
      ; test_case "cancelled absent create closes terminally" `Quick test_cancelled_unconfirmed_launch_closes_absent_create
      ; test_case "late same-label container stays an orphan" `Quick test_cancelled_unconfirmed_launch_treats_late_container_as_orphan
      ; test_case "interrupted cancellation retains exact intent" `Quick test_cancel_in_flight_retains_exact_intent
      ; test_case "changed mount or cloned identity cannot authorize a kill" `Quick test_changed_mount_cannot_authorize_cancel
      ; test_case "large stdout and stderr preserve complete original artifacts" `Quick test_large_streams_publish_complete_original_artifacts
      ; test_case "lost start reply recovers the original job" `Quick test_lost_start_reply_recovers_original_job
      ; test_case "original invocation rejects request and source rebinding" `Quick test_original_invocation_rejects_rebinding
      ; test_case "corrupt invocation authority cannot launch" `Quick test_corrupt_invocation_binding_cannot_launch
      ; test_case "malformed whole source cannot publish a binding" `Quick test_malformed_source_cannot_publish_binding
      ; test_case "explicit operator rejection resolves permanent continuation mismatch" `Quick test_operator_resolves_permanent_continuation_mismatch
      ; test_case "public Composition waits and resumes the original job result" `Quick test_public_composition_wait_and_resume
      ; test_case "public named async result parks and resumes its original parent" `Quick
          (test_named_async_result_parent ~child_fails:false)
      ; test_case "actual named cancellation remains failed to its original parent" `Quick
          (test_named_async_result_parent ~child_cancelled:true ~child_fails:false)
      ; test_case "named producer releases and resumes before its original parent" `Quick
          (test_named_async_result_parent ~child_waits:true ~child_fails:false)
      ; test_case "canonical named child failure remains failed on fresh parent resume" `Quick
          (test_named_async_result_parent ~child_fails:true)
      ; test_case "permanent producer skill loss settles the run and ends its parent" `Quick
          test_named_producer_skill_loss_settles_run_and_ends_parent
      ; test_case "producer switched to inline and deleted keeper metadata settle as terminal failures" `Quick
          test_named_producer_switched_to_inline_settles_run_and_ends_parent
      ; test_case "temporary keeper refusal keeps the named run resumable" `Quick
          test_temporary_keeper_refusal_keeps_named_run_open
      ; test_case "historical output contract refuses current canonical resume" `Quick test_historical_output_contract_refuses_current_resume
      ; test_case "cancelled continuation preserves intent at fork, startup and signal failure" `Quick test_cancelled_continuation_cannot_restart
      ; test_case "job result rejects unavailable owner authority" `Quick test_job_result_rejects_unavailable_authority
      ; test_case "completion enqueue failure recovers original result after restart" `Quick test_completion_delivery_failure_and_restart
      ; test_case "consumed notification survives missing producer ACK" `Quick test_completion_consumed_before_producer_ack
      ; test_case "completion recovery retains unknown launch and corrupt owner" `Quick test_completion_retains_unknown_launch_and_owner
      ; test_case "cancelled unknown launch delivers and cleans without replay" `Quick test_cancelled_unknown_launch_delivery_and_cleanup
      ; test_case "finished without outputs and absent inventory is notified once and leaves waiting" `Quick test_finished_without_outputs_absent_inventory_notified_once
      ; test_case "running with absent inventory is notified once and leaves waiting" `Quick test_running_absent_inventory_notified_once
      ; test_case "durable completion hint resumes original DAG without a provider turn" `Quick test_completion_hint_resumes_original_dag
      ; test_case "prepared DAG launches an owned job and resumes its original result" `Quick
          (test_prepared_job_launch_and_continuation ~launch_after_result:false)
      ; test_case "post-wait new launch keeps the captured original frame after metadata changes" `Quick
          (test_prepared_job_launch_and_continuation ~launch_after_result:true)
      ; test_case "interrupted prepared launch publicly resumes original K41" `Quick
          (test_interrupted_prepared_launch_resumes_the_same_job (Some 41))
      ; test_case "interrupted prepared launch publicly preserves absent K" `Quick
          (test_interrupted_prepared_launch_resumes_the_same_job None)
      ; test_case "fixed async Skill child submits once and resumes its canonical whole result" `Quick (test_fixed_async_skill_child ~child_failure:false)
      ; test_case "fixed async Skill child preserves an actual canonical whole-child failure" `Quick (test_fixed_async_skill_child ~child_failure:true)
      ; test_case "native child exports preserve order, escaped names and dependent artifact reads" `Quick
          (test_fixed_async_skill_child ~export_selection:Ordered_aliases)
      ; test_case "native child without exports releases its dependent after canonical completion" `Quick
          (test_fixed_async_skill_child ~export_selection:Without_exports)
      ; test_case "typed recovery terminates proven refusal and holds uncertain effects" `Quick test_typed_continuation_recovery
      ; test_case "nested parent distinguishes a denied Tool from unavailable original child authority" `Quick
          (test_fixed_async_skill_child ~parent_tool_denied:true)
      ; test_case "upstream async Skill arguments survive fresh child and parent continuation" `Quick (test_fixed_async_skill_child ~dynamic_arguments:true)
      ; test_case "async Skill child launches its own isolated job once and resumes the whole result" `Quick (test_fixed_async_skill_child ~launch_in_child:true)
      ; test_case "upstream enum, type and extra-field rejection creates no child activation" `Quick test_upstream_arguments_reject_before_child_activation
      ; test_case "public inline Skill consumes upstream arguments without async submission" `Quick
          (test_public_upstream_inline_arguments ~reject:false)
      ; test_case "public inline argument refusal precedes activation and leaf effects" `Quick
          (test_public_upstream_inline_arguments ~reject:true)
      ; test_case "real parent loss retains upstream arguments and original accepted child" `Quick test_native_child_acceptance_survives_physical_parent_loss
      ; test_case "fresh supervisor retains nested child authority through owned-job waits" `Quick
          (test_nested_skill_job_continuation ~fault_after_acceptance:false)
      ; test_case "accepted worker activation fault keeps original child wait recoverable" `Quick
          (test_nested_skill_job_continuation ~fault_after_acceptance:true)
      ; test_case "fresh supervisor retains upstream inline arguments and original child authority" `Quick
          (test_nested_skill_job_continuation ~dynamic_arguments:true)
      ; test_case "maintenance admits new job recovery while another backend is blocked" `Quick test_completion_pulse_does_not_join_blocked_backend
      ; test_case "async discovery failure retains original output and recovers beside partial marker damage" `Quick
          test_completion_discovery_failure_preserves_original_result
      ; test_case "prepared discovery preserves new demand through observer failure and resumes original child and parent" `Quick
          test_prepared_discovery_demand_survives_observer_failure
      ; test_case "typed original child completion automatically resumes parent and retains unrelated job" `Quick
          (test_prepared_result_scope_preserves_original_resources ~scenario:Direct_signal)
      ; test_case "actual queue failure and completion recovery retain original parent and job outputs" `Quick
          (test_prepared_result_scope_preserves_original_resources ~scenario:Delivery_queue_recovery)
      ; test_case "another observer's cancelled lifetime cannot suppress original parent result" `Quick
          (test_prepared_result_scope_preserves_original_resources ~scenario:Observer_scope_cancelled)
      ; test_case "cancelled recovery retains original output and a fresh scope delivers once and cleans" `Quick
          test_completion_cancelled_round_preserves_original_result
      ; test_case "held absence uses a presence hint and reactivates only original authority" `Quick
          test_held_absent_presence_reactivates_only_original_authority
      ; test_case "changed cancellation bypasses process-local held absence" `Quick
          test_changed_cancel_intent_bypasses_held_presence
      ; test_case "held jobs share an original-backend presence round and preserve recovery" `Quick
          (test_shared_held_presence_round ~different_endpoint:false)
      ; test_case "different frozen backend endpoints cannot share presence" `Quick
          (test_shared_held_presence_round ~different_endpoint:true)
      ; test_case "recovery keeps refused foreign and corrupt owner bytes intact" `Quick test_completion_recovery_preserves_refused_owner_bytes
      ; test_case "owner mismatch reports hold before readiness" `Quick test_owner_mismatch_reports_hold_before_readiness
      ; test_case "held continuation is not retried until restart" `Quick test_held_continuation_is_not_retried_until_restart
      ; test_case "ready continuations share declarations until the next pulse" `Quick
          (test_continuation_pulse_shares_declarations ~invalid_initial:false)
      ; test_case "shared declaration failures remain explicit until a new projection" `Quick
          (test_continuation_pulse_shares_declarations ~invalid_initial:true)
      ; test_case "exact run restoration reactivates original child and parent" `Quick
          (test_original_evidence_repair_reactivates_continuation ~skill_publication:false)
      ; test_case "published Skill repair reactivates original child and parent" `Quick
          (test_original_evidence_repair_reactivates_continuation ~skill_publication:true) ]]
