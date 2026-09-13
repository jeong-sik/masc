(** Real declaration, Skill publication, turn projection, and resource reader.
    Only observer process/source acquisition use a fixture backend. This does
    not claim a model turn, game action, or Docker qualification. *)
open Alcotest
open Masc
module Lane = Lane_addon_runtime
module Snapshot = Skill_catalog_snapshot
module Service = Skill_catalog_snapshot_service
module Catalog = Keeper_skill_catalog
module Surface = Standalone_skill_tools

let get = function Ok value -> value | Error _ -> fail "fixture operation failed"
let unwrap = function Ok value -> value | Error message -> fail message
let member = Yojson.Safe.Util.member
let json_string key value = member key value |> Yojson.Safe.Util.to_string
let values key value = member key value |> Yojson.Safe.Util.to_list
let digest bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let with_environment name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f

let ordinary_body = "Continue the ordinary task using the existing tools."
let document name body =
  Printf.sprintf "---\nname: %s\ndescription: Read task evidence\n---\n%s" name body
let base_config = {|[skills]
resource-read-max-bytes = 65536
[[skills.sources]]
id = "ordinary"
anchor = "base-path"
path = "skills"
access = "read-only"
|}
let bundled_files = [
  "lane.toml";
  "skills/msx-observe/SKILL.md";
  "skills/msx-observe/references/observations.md";
  "skills/msx-observe/scripts/summarize.py";
]
let fixture_package_source =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "addons/msx-observer"
  | None -> Filename.concat (Filename.dirname Sys.executable_name) "../addons/msx-observer"

type fixture = {
  config : Workspace.config;
  workspace : Service.workspace;
  declarations : string;
  declaration : string;
  runtime_config : string;
  package : string;
  stops : int ref;
}

let backend stops : Lane.For_testing.backend = {
  start = (fun ~sw:_ ~instance_id ~package:_ ~on_created ->
    let stopped = ref false in
    let connection : Lane.For_testing.connection = {
      container_id = digest instance_id;
        action_schema = (fun () -> None);
        act = (fun ~arguments:_ -> Error "read-only fixture");
      observe = (fun ~binding:_ ~sources:_ -> Ok { Lane_addon_types.rows = []; coverage = [] });
      stop = (fun () -> if not !stopped then (stopped := true; incr stops); Ok ());
    } in
    on_created connection;
    Ok connection);
  acquire = (fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~instance_id:_ ~container_id:_ ~max_reply_bytes:_ -> Ok ());
}

let dispatch fixture operation fields =
  Lane.dispatch ~config:fixture.config ~operation (`Assoc fields)
  |> Result.map_error Lane.error_to_string |> unwrap
let inspect fixture = dispatch fixture Lane.Inspect []
let reconcile fixture =
  Lane.reconcile_configuration ~config:fixture.config ~directory:fixture.declarations |> unwrap
let snapshot fixture =
  match Service.current ~workspace:fixture.workspace with
  | Some snapshot -> snapshot
  | None -> fail "the existing Skill service has no publication"
let refresh_base fixture =
  match Service.refresh ~workspace:fixture.workspace ~user_home:None
    ~read_config:(fun () -> Service.Config_text (read fixture.runtime_config)) with
  | Service.Published snapshot | Unchanged snapshot -> snapshot
  | Workspace_retired -> fail "fixture workspace retired"
let skill snapshot name =
  match Snapshot.find_effective_by_name snapshot name with
  | Some entry -> entry
  | None -> failf "Skill %s is absent: %s" name (Yojson.Safe.to_string (Snapshot.to_public_yojson snapshot))
let absent snapshot name = Option.is_none (Snapshot.find_effective_by_name snapshot name)
let tool fixture =
  match Surface.for_workspace ~config:fixture.config () |> unwrap with
  | [tool] -> tool
  | _ -> fail "expected the existing keeper_skill tool"
let invoke tool id input =
  let invocation = Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:id ~turn:0
    ~schedule:{ planned_index=0; batch_index=0; batch_size=1; execution_mode=Agent_core.Tool_contract.Serial }
    ~completion:(Agent_core.Tool.completion tool) in
  tool.Agent_core.Tool.handler (Agent_core.Tool.Execution_env.create ~invocation ()) input
let checked_read tool id input expected =
  match invoke tool id input with
  | Error error -> fail error.Agent_core.Llm_provider.Types.message
  | Ok (output : Agent_core.Llm_provider.Types.tool_output) ->
      check string "exact resource/body bytes" expected output.content;
      let metadata = match output._meta with Some value -> value | None -> fail "Skill read metadata missing" in
      check string "actual read SHA-256" (digest expected) (json_string "sha256" metadata);
      check int "actual read byte count" (String.length expected)
        (member "bytes" metadata |> Yojson.Safe.Util.to_int)
let with_file reference file =
  match Skill_reference.to_yojson reference with
  | `Assoc fields -> `Assoc (("file", `String file) :: fields)
  | _ -> fail "Skill reference is not an object"
let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001; loop ()) in
  loop ()
let installed fixture =
  inspect fixture |> values "instances"
  |> List.find (fun row -> member "configuration" row |> json_string "id" = "msx-installation")
let await_observer clock fixture =
  await clock (fun () -> installed fixture |> member "observation_seq" |> Yojson.Safe.Util.to_int |> fun seq -> seq > 0)
let detach clock fixture =
  let id = installed fixture |> json_string "instance_id" in
  ignore (dispatch fixture Lane.Detach ["instance_id", `String id]);
  await clock (fun () -> !(fixture.stops) = 1);
  await clock (fun () -> installed fixture |> member "phase" |> json_string "kind" = "detached");
  (* Exercise the maintenance publication after cleanup completes. This
     fixture drives reconciliation explicitly rather than starting Pulse. *)
  ignore (reconcile fixture);
  await clock (fun () -> absent (snapshot fixture) "msx-observe")

let with_fixture ?(runtime_text=base_config) f =
  let root = Filename.temp_dir "lane-skill-workflow-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let declarations = Filename.concat config_root "lane-addons" in
    Fs_compat.mkdir_p declarations;
    let runtime_config = Filename.concat config_root "runtime.toml" in
    write runtime_config runtime_text;
    write (Filename.concat root "skills/ordinary-guide/SKILL.md") (document "ordinary-guide" ordinary_body);
    let package = Filename.concat root "packages/msx-observer" in
    List.iter (fun relative -> write (Filename.concat package relative)
      (read (Filename.concat fixture_package_source relative))) bundled_files;
    let declaration = Filename.concat declarations "msx.toml" in
    write declaration (Printf.sprintf {|id = "msx-installation"
run_id = "existing-machine"
manifest_path = %S
[binding]
machine_id = "workspace-msx"
sources = [{source_id = "machine", kind = "msx_capture"}]
|} (Filename.concat package "lane.toml"));
    with_environment "MASC_CONFIG_DIR" config_root (fun () ->
      with_environment "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
            Eio.Switch.run (fun sw ->
              Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                  Lane.For_testing.reset ();
                  let workspace = Service.workspace_of_base_path ~base_path:root |> get in
                  Fun.protect ~finally:(fun () -> Service.retire ~workspace) (fun () ->
                    let fixture = { config=Workspace.default_config root; workspace; declarations;
                      declaration; runtime_config; package; stops=ref 0 } in
                    ignore (refresh_base fixture);
                    Lane.register_skill_export_handler Server_skill_snapshot_runtime.publish_lane_skills;
                    Lane.For_testing.with_backend (backend fixture.stops)
                      (fun () -> f (Eio.Stdenv.clock env) fixture)))))))))

let test_declaration_catalog_and_resources () = with_fixture (fun clock fixture ->
  let original_config = read fixture.runtime_config in
  let ordinary_reference = skill (snapshot fixture) "ordinary-guide" |> Snapshot.entry_reference in
  ignore (reconcile fixture);
  await_observer clock fixture;
  let published = snapshot fixture in
  check int "ordinary and package Skill are both discovered" 2 (List.length (Snapshot.effective_entries published));
  let entry = skill published "msx-observe" in
  let reference = Snapshot.entry_reference entry in
  check string "stable declaration-owned source identity"
    (Lane.skill_source_id (Lane.Declaration "msx-installation"))
    (Skill_source_config.source_id_to_string entry.identity.source_id);
  let source = Snapshot.sources published |> List.find (fun (scan : Snapshot.source_scan) -> scan.source.source.id = entry.identity.source_id) in
  check bool "package source is read-only" true (source.source.source.access = Skill_source_config.Read_only);
  let raw_document = read (Filename.concat fixture.package "skills/msx-observe/SKILL.md") in
  check string "content revision identifies exact SKILL.md bytes"
    (Skill_reference.content_revision_of_source_text raw_document
     |> Skill_reference.content_revision_to_string)
    (Snapshot.content_revision_to_string entry.content_revision);
  let reader = tool fixture in
  checked_read reader "read-skill" (Skill_reference.to_yojson reference) entry.document.body;
  List.iter (fun file ->
    checked_read reader ("read-" ^ file) (with_file reference file)
      (read (Filename.concat fixture.package ("skills/msx-observe/" ^ file))))
    ["scripts/summarize.py"; "references/observations.md"];
  let catalog, diagnostics = Catalog.of_snapshot published in
  check int "instruction projection is valid" 0 (List.length diagnostics);
  let selected = Catalog.project_turn ~names:(Some ["ordinary-guide"]) ~global:catalog ~task:[] in
  check (list string) "existing exact-name selection remains authoritative" ["ordinary-guide"]
    (Catalog.skills selected.catalog |> List.map (fun (s : Catalog.skill) -> s.name));
  let none = Catalog.project_turn ~names:(Some []) ~global:catalog ~task:[] in
  check int "existing explicit empty selection still exposes none" 0 (List.length (Catalog.skills none.catalog));
  checked_read reader "ordinary-still-readable" (Skill_reference.to_yojson ordinary_reference) ordinary_body;
  ignore (refresh_base fixture);
  check bool "ordinary refresh retains registered package sources" false (absent (snapshot fixture) "msx-observe");
  check string "publication does not edit runtime configuration" original_config (read fixture.runtime_config);
  detach clock fixture)

let test_invalid_document_and_detach_preserve_ordinary_work () = with_fixture (fun clock fixture ->
  ignore (reconcile fixture);
  await_observer clock fixture;
  let published = snapshot fixture in
  let entry = skill published "msx-observe" in
  let reference = Snapshot.entry_reference entry in
  let frozen_reader = tool fixture in
  let ordinary_reference = skill published "ordinary-guide" |> Snapshot.entry_reference in
  let path = Filename.concat fixture.package "skills/msx-observe/SKILL.md" in
  let original = read path in
  write path "---\nname: msx-observe\n---\nMissing required description.\n";
  ignore (refresh_base fixture);
  check bool "malformed package document is absent from new discovery" true (absent (snapshot fixture) "msx-observe");
  check int "malformed document remains diagnosed" 1 (List.length (Snapshot.rejections (snapshot fixture)));
  checked_read (tool fixture) "ordinary-after-invalid" (Skill_reference.to_yojson ordinary_reference) ordinary_body;
  checked_read frozen_reader "frozen-turn-after-invalid" (Skill_reference.to_yojson reference) entry.document.body;
  check int "an invalid optional Skill does not stop its observer" 0 !(fixture.stops);
  write path original;
  ignore (refresh_base fixture);
  check bool "corrected document is discoverable" false (absent (snapshot fixture) "msx-observe");
  detach clock fixture;
  check bool "managed detach removes the installation declaration" false (Sys.file_exists fixture.declaration);
  checked_read (tool fixture) "ordinary-after-detach" (Skill_reference.to_yojson ordinary_reference) ordinary_body;
  checked_read frozen_reader "frozen-turn-after-detach" (Skill_reference.to_yojson reference) entry.document.body;
  (match invoke (tool fixture) "new-turn-after-detach" (Skill_reference.to_yojson reference) with
   | Error _ -> () | Ok _ -> fail "a new turn discovered the detached package Skill"))

let test_missing_read_policy_remains_an_optional_export_diagnostic () =
  with_fixture ~runtime_text:"" (fun clock fixture ->
    ignore (reconcile fixture);
    await_observer clock fixture;
    check int "no invented read policy exposes package resources" 0 (List.length (Snapshot.entries (snapshot fixture)));
    check bool "missing policy has a visible package-source diagnostic" true
      (Service.additional_source_diagnostics ~workspace:fixture.workspace <> []);
    check string "read policy is not written into runtime.toml" "" (read fixture.runtime_config);
    check int "optional export rejection does not remove the observer" 0 !(fixture.stops);
    detach clock fixture)

let () = run "Lane package Skill workflow"
  ["declaration to existing reader", [
    test_case "catalog, exact body/resource bytes and existing controls" `Quick test_declaration_catalog_and_resources;
    test_case "invalid and detached exports preserve ordinary frozen turns" `Quick test_invalid_document_and_detach_preserve_ordinary_work;
    test_case "missing read policy remains local" `Quick test_missing_read_policy_remains_an_optional_export_diagnostic;
  ]]
