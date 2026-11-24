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
  ; capability_surface : Masc.Keeper_capability_surface.t
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
let _published_surface fixture =
  ignore fixture.capability_surface;
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
      ~clock:(Eio.Stdenv.clock env) ~turn_ctx_cell:cell () |> Result.get_ok in
  let fixture = {base_path;configured_base_path;meta;cell;make_bundle;capability_surface=surface;
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
  let digest = Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string request))) in
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
      ~scope:Server_tool_blob_scope.scope ~mode:Tool_blob_maintenance.Observe_only
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
      let expected_sha = Agent_core_sha256.(to_hex (digest_string expected)) in
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

let _await_composition env fixture accepted =
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
      ~config:(Workspace.default_config fixture.base_path) ~meta_after_triage:fixture.meta selection.source in
  let event = match inspect () with
    | Intake.Stimulus_observed [event] -> event
    | _ -> fail "complete original result was not admitted to the next prompt" in
  (match event.Masc.Keeper_world_observation.event_kind with
   | Owned_job_completed carried ->
     check_json "model observation has the typed original source" (Store.source_to_json original.source)
       (Keeper_owned_job_identity.source_to_json carried.oj_source)
   | _ -> fail "model observation lost typed completion identity");
  let preview = Yojson.Safe.from_string (Option.get event.preview) in
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
  (match inspect () with Intake.Stimulus_observed [_] -> () | _ -> fail "restored original owner cannot resume intake");
  let forged = {completion with oj_source={completion.oj_source with task_id=Some "task-B"}} in
  let forged_source = {selection.source with payload=Owned_job_completed forged} in
  (match Intake.pending_board_events_of_stimulus_result ~config:(Workspace.default_config fixture.base_path)
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



exception Fixture_result_observer_failed
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

type export_selection = Ordered_aliases | Without_exports
type result_scope_scenario = Direct_signal | Delivery_queue_recovery | Observer_scope_cancelled

let lose_native_parent_after_child_acceptance _ _ _ = ()

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

(* A shutdown that holds the Keeper's intake refuses the completion notice.
   That is a wait, not a store failure: each pass counts the job as waiting
   and keeps its delivery marker, and the first pass after the shutdown
   releases the intake delivers the notice once. *)
let test_completion_shutdown_hold_waits_then_delivers () =
  let module Fence = Masc.Keeper_shutdown_intake_fence in
  with_fixture @@ fun _env _initialize fixture ->
  set_source fixture ~task_id:"task-A" ~turn:41;
  let id = with_bundle fixture (fun bundle -> start fixture bundle ["fixture-program"]) |> job_id in
  control_job fixture id (`Assoc ["state", `String "exited"; "exit_code", `Int 0]);
  ignore (with_bundle fixture (fun bundle ->
    invoke fixture bundle ~tool_use_id:"collect-before-shutdown-hold" ~turn:42
      "keeper_job_status" (argument id)));
  check bool "complete result is durable before the hold" true (Store.result_ready (load fixture id));
  let operation_id = Masc.Keeper_shutdown_types.Operation_id.generate () in
  (match Fence.begin_shutdown ~base_path:fixture.base_path ~keeper_name:keeper ~operation_id with
   | Fence.Reserved _ -> ()
   | Fence.Already_reserved _ -> fail "the fixture Keeper already held a shutdown");
  let assert_held pass =
    let report = recover_completions fixture in
    (match report.failures with
     | [] -> ()
     | _ :: _ -> fail (pass ^ ": a shutdown hold was reported as a store failure"));
    check int (pass ^ ": the held completion waits") 1 report.waiting;
    check int (pass ^ ": the held completion is not delivered") 0 report.delivered;
    check_no_completion fixture;
    let held = load fixture id in
    check bool (pass ^ ": the held owner is not acknowledged") false held.completion_delivered in
  assert_held "first pass";
  assert_held "second pass";
  (match Fence.rollback_shutdown ~base_path:fixture.base_path ~keeper_name:keeper ~operation_id with
   | Fence.Rolled_back -> ()
   | Fence.Not_reserved | Fence.Reserved_by_other _ ->
     fail "the test's own shutdown did not roll back");
  let released = recover_completions fixture in
  (match released.failures with
   | [] -> ()
   | _ :: _ -> fail "the released completion failed to deliver");
  check int "the first pass after the release delivers" 1 released.delivered;
  let completion = completion_payload (only_selection fixture) in
  check string "the original job is delivered" id (Store.Job_id.to_string completion.oj_job_id);
  let delivered = load fixture id in
  check bool "delivery acknowledges the original owner" true delivered.completion_delivered

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
    ~scope:Server_tool_blob_scope.scope ~mode:Tool_blob_maintenance.Observe_only
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

let test_owned_job_logs_redact_secrets_before_blob_publication () =
  with_fixture @@ fun _env _initialize fixture ->
  let secret_stdout = "ghp" ^ "_" ^ "1234567890abcdefghijklmnopqrstuvwxyz" in
  let secret_stderr = "sk" ^ "-" ^ "proj-abcdefghijklmnopqrstuvwxyz0123456789" in
  let bundle = fixture.make_bundle () in
  set_source fixture ~task_id:"task-redact" ~turn:1;
  let launched =
    invoke fixture bundle ~tool_use_id:"start-redact" ~turn:1 "keeper_job_start"
      (`Assoc [ "argv", `List [ `String "fixture-program" ] ])
  in
  let id = launched |> member "job_id" |> to_string in
  control_job fixture id
    (`Assoc
      [ "state", `String "exited"
      ; "exit_code", `Int 0
      ; ( "custom_logs"
        , `Assoc
            [ "stdout", `String ("token=" ^ secret_stdout ^ "\nok\n")
            ; "stderr", `String ("api=" ^ secret_stderr ^ "\ndone\n")
            ] )
      ]);
  let exited =
    invoke fixture bundle ~tool_use_id:"status-redact" ~turn:1 "keeper_job_status"
      (`Assoc [ "job_id", `String id ])
  in
  check string "exited phase" "exited" (exited |> member "phase" |> to_string);
  let store = Tool_blob_store.create ~base_path:fixture.base_path in
  let fetch_artifact json =
    match Tool_output.normalized_artifact_ref_of_json json with
    | Tool_output.Decoded_normalized_artifact_ref reference ->
      Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256
      |> require "fetch redacted log artifact"
      |> Option.get
    | _ -> fail "expected normalized artifact reference"
  in
  match exited |> member "artifacts" |> to_list with
  | [ stdout_json; stderr_json ] ->
    let out_bytes = fetch_artifact stdout_json in
    let err_bytes = fetch_artifact stderr_json in
    check bool "stdout blob does not retain raw secret" false
      (String_util.contains_substring out_bytes secret_stdout);
    check bool "stderr blob does not retain raw secret" false
      (String_util.contains_substring err_bytes secret_stderr);
    check bool "stdout blob contains [REDACTED]" true
      (String_util.contains_substring out_bytes "[REDACTED]");
    check bool "stderr blob contains [REDACTED]" true
      (String_util.contains_substring err_bytes "[REDACTED]")
  | _ -> fail "expected 2 output log artifacts"

let () = match Array.to_list Sys.argv with
  | [_;"--lose-native-parent-after-child-acceptance";base_path;draft_sha;run_id] ->
    lose_native_parent_after_child_acceptance base_path draft_sha run_id
  | _ ->
  Printf.printf "owned_job_feature_transport=synthetic_docker_cli actual_public_handler=true actual_docker_execution=false\n%!";
  run "Keeper owned jobs"
    ["public lifecycle",
      [ test_case "owned job logs redact secrets before tool_blobs publication" `Quick
          test_owned_job_logs_redact_secrets_before_blob_publication
      ; test_case "structured launch, original source, restart and artifact ownership" `Quick test_running_restart_exit_and_artifacts
      ; test_case "parent-directory alias retains original invocation, input and complete outputs" `Quick
          test_parent_alias_keeps_original_job_and_outputs
      ; test_case "retargeted parent alias and copied owner cannot borrow original authority" `Quick
          test_parent_alias_retarget_cannot_borrow_original_authority
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
      ; test_case "job result rejects unavailable owner authority" `Quick test_job_result_rejects_unavailable_authority
      ; test_case "completion enqueue failure recovers original result after restart" `Quick test_completion_delivery_failure_and_restart
      ; test_case "consumed notification survives missing producer ACK" `Quick test_completion_consumed_before_producer_ack
      ; test_case "completion recovery retains unknown launch and corrupt owner" `Quick test_completion_retains_unknown_launch_and_owner
      ; test_case "cancelled unknown launch delivers and cleans without replay" `Quick test_cancelled_unknown_launch_delivery_and_cleanup
      ; test_case "finished without outputs and absent inventory is notified once and leaves waiting" `Quick test_finished_without_outputs_absent_inventory_notified_once
      ; test_case "running with absent inventory is notified once and leaves waiting" `Quick test_running_absent_inventory_notified_once
      ; test_case "maintenance admits new job recovery while another backend is blocked" `Quick test_completion_pulse_does_not_join_blocked_backend
      ; test_case "async discovery failure retains original output and recovers beside partial marker damage" `Quick
          test_completion_discovery_failure_preserves_original_result
      ; test_case "cancelled recovery retains original output and a fresh scope delivers once and cleans" `Quick
          test_completion_cancelled_round_preserves_original_result
      ; test_case "a shutdown hold waits and the first pass after its release delivers" `Quick
          test_completion_shutdown_hold_waits_then_delivers
      ; test_case "held absence uses a presence hint and reactivates only original authority" `Quick
          test_held_absent_presence_reactivates_only_original_authority
      ; test_case "changed cancellation bypasses process-local held absence" `Quick
          test_changed_cancel_intent_bypasses_held_presence
      ; test_case "held jobs share an original-backend presence round and preserve recovery" `Quick
          (test_shared_held_presence_round ~different_endpoint:false)
      ; test_case "different frozen backend endpoints cannot share presence" `Quick
          (test_shared_held_presence_round ~different_endpoint:true)
      ; test_case "recovery keeps refused foreign and corrupt owner bytes intact" `Quick test_completion_recovery_preserves_refused_owner_bytes
      
]]
