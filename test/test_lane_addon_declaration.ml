(** The actual declaration owner shared by HTTP and Keeper tools. Only external
    workers are replaced: TOML parsing, files, CAS, reconcile and publication run. *)
open Alcotest
open Masc
module Runtime = struct
  include Lane_addon_runtime
  let fixture_access caller access = Option.value access ~default:(match caller with
    | None -> Lane_addon_sources.Operator_configuration
    | Some keeper -> Lane_addon_sources.Keeper keeper)
  let read_declaration ?caller ?access ~config args =
    Lane_addon_runtime.read_declaration ~access:(fixture_access caller access) ~config args
  let save_declaration ?caller ?access ~config args =
    Lane_addon_runtime.save_declaration ~access:(fixture_access caller access) ~config args
  let dispatch ?caller ?access ~config ~operation args =
    let access = Option.value ~default:(match caller with
      | None -> Lane_addon_sources.Operator_configuration
      | Some keeper -> Lane_addon_sources.Keeper keeper) access in
    Lane_addon_runtime.dispatch ?caller ~access ~config ~operation args
    |> Result.map_error Lane_addon_runtime.error_to_string
end
module Editor = Lane_addon_declaration
let packages (config : Workspace.config) = Config_dir_resolver.packages_dir ~base_path:config.base_path
module Types = Lane_addon_types
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let list key json = member key json |> Yojson.Safe.Util.to_list
let unwrap = function Ok v -> v | Error error -> fail error.Editor.message
let runtime_result = function Ok v -> v | Error message -> fail message
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let with_env name value f =
  let previous = Sys.getenv_opt name in Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f
let output : Types.output = {rows=[];coverage=[]}
let manifest = {|id="editor-test"
revision="1"
title="Editor fixture"
contributions=["observe"]
image="fixture/image"
command=["fixture"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=4096
|}
let declaration ?(id="observer") ?(manifest_path="../../package.toml") ?(value="first") () = Printf.sprintf {|id=%S
run_id="editor-world"
manifest_path=%S
[binding]
sources=[]
value=%S
|} id manifest_path value
let request ?revision ~mode ~file_name source_text =
  `Assoc (["mode",`String mode;"file_name",`String file_name;"source_text",`String source_text]
    @ Option.fold ~none:[] ~some:(fun value -> ["expected_source_revision",`String value]) revision)
let read config directory name =
  Runtime.read_declaration ~access:Lane_addon_sources.Operator_configuration ~config (`Assoc ["source_path",`String (Filename.concat directory name)]) |> unwrap
let save config args = Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config args |> unwrap
let inspect config = Runtime.dispatch ~config ~operation:Runtime.Inspect (`Assoc []) |> runtime_result
let reconcile config directory = Runtime.reconcile_configuration ~config ~directory |> runtime_result
let live config = inspect config |> list "instances" |> List.filter (fun item -> text "kind" (member "phase" item) <> "detached")
let one_live config = match live config with [entry] -> entry | _ -> fail "expected one active installation"
let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001;loop ()) in loop ()
let keeper_call config name args =
  let descriptor = match Keeper_tool_descriptor_resolution.descriptor_for_tool_name name with
    | Some d -> d | None -> fail "Keeper cannot discover declaration tool" in
  check bool "declaration tool is exposed under its Keeper model name" true
    (List.mem name (Keeper_tool_descriptor.keeper_model_names descriptor));
  check bool "Keeper dispatches through the in-process misc owner" true
    (descriptor.runtime_handler=Keeper_tool_descriptor.Tool_masc_misc_dispatch);
  let translated = Keeper_tool_descriptor.translate_input_for_descriptor descriptor args in
  let context : Tool_misc.context = {config;agent_name="editor-keeper";help_schemas=[]} in
  match Tool_misc.dispatch ~lane_access:(Lane_addon_sources.Keeper "editor-keeper") context ~name:descriptor.internal_name ~args:translated with
  | Some value -> value | None -> fail "Keeper descriptor has no executable declaration route"

let with_fixture f =
  let root = Filename.temp_dir "lane-editor-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let directory = Filename.concat config_root "lane-addons" in
    Fs_compat.mkdir_p directory;
    write (Filename.concat root ".masc/package.toml") manifest;
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
      with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          let clock = Eio.Stdenv.clock env in
          Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
            Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
              ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                Runtime.For_testing.reset ();
                let started = ref [] in
                let backend : Runtime.For_testing.backend = {
                  start=(fun ~sw:_ ~state_owner:_ ~instance_id ~installation_id:_ ~package:_ ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
                    started := instance_id :: !started;
                    let connection : Runtime.For_testing.connection = {browser=None;
        await_exit = (fun () -> Eio.Fiber.await_cancel ());
        resolved_image = (match Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') with
          | Ok image -> Some image | Error detail -> Alcotest.fail detail);
                      observe=(fun ~binding:_ ~sources:_ -> Ok output);
                      exported_tools = (fun () -> []);
                      call_exported_tool = (fun ~on_result:_ ~on_dispatch:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ -> Error (Lane_addon_call_context.Transport_error "no exported tools"));
                      operator_schema=(fun () -> None);
      observation_effect=(fun _ -> Lane_addon_call_context.May_change);
                      call_operator=(fun ~admit:_ ~arguments:_ -> Error Lane_addon_worker_protocol.Operator_unavailable);
                      action_schema=(fun () -> None);act=(fun ~arguments:_ -> Error "read-only");
                      host = None; stop=(fun () -> Ok (Masc.Lane_addon_lifecycle.Released {engine=Masc.Lane_addon_lifecycle.Docker_engine "fixture-engine";container_id=Some (instance_id)}));resource=Masc.Lane_addon_lifecycle.Container_resource instance_id} in ignore (on_authority (Masc.Lane_addon_lifecycle.Container_authority {runtime=Masc.Lane_addon_types.Docker;engine=Masc.Lane_addon_lifecycle.Docker_engine "fixture-engine"})); on_created connection;Ok connection);
                  package_ready=(fun ~package:_ -> Ok ());
                  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~read_browser_document:_ ~binding:_ -> Ok (`List []));
                  recover_stop=(fun ~state_owner:_ ~instance_id:_ ~authority ~resource ->
      match authority,resource with
      | Masc.Lane_addon_lifecycle.Container_authority {engine;_},None ->
          Ok (Masc.Lane_addon_lifecycle.Released {engine;container_id=None})
      | Masc.Lane_addon_lifecycle.Container_authority {engine;_},Some (Masc.Lane_addon_lifecycle.Container_resource id) ->
          Ok (Masc.Lane_addon_lifecycle.Released {engine;container_id=Some id})
      | Masc.Lane_addon_lifecycle.Container_authority _,Some (Masc.Lane_addon_lifecycle.Native_resource _)
      | Masc.Lane_addon_lifecycle.Native_admission _,(None | Some _) ->
          Error (Masc.Lane_addon_lifecycle.Cleanup_unconfirmed "container fixture cannot release native resources"));
                  condition_met = (fun ~runtime:_ _ -> true);
                  sweep = (fun ~runtime:_ ~is_live_instance:_ -> Ok [])} in
                let config = Workspace.default_config root in
                Runtime.For_testing.with_backend backend (fun () ->
                  f clock config directory root started;
                  Sys.readdir directory |> Array.iter (fun name ->
                    if Filename.check_suffix name ".toml" then Unix.unlink (Filename.concat directory name));
                  ignore (reconcile config directory);
                  await clock (fun () -> live config=[])))))))))

let test_invalid_ego_space_never_publishes_or_attaches () = with_fixture (fun _clock config directory root started ->
  let manifest_path=Filename.concat root ".masc/package.toml" in
  write manifest_path {|id="ego-declaration-test"
revision="1"
title="Ego declaration fixture"
runtime="host_process"
service="browser"
browser_backend="ego"
command=["masc-browser-addon-worker"]
contributions=["observe"]
[resources]
max_reply_bytes=4096
|};
  let invalid=Printf.sprintf "id=\"invalid-ego\"\nrun_id=\"test\"\nmanifest_path=%S\n[binding]\nsources=[]\nspace=-1\n" manifest_path in
  let response=Runtime.save_declaration ~config (request ~mode:"create" ~file_name:"invalid-ego.toml" invalid) in
  check bool "invalid Space rejected before declaration write" true
    (match response with Error {Editor.code=Editor.Invalid_declaration;_} -> true | Ok _|Error _ -> false);
  check bool "invalid declaration never appeared" false (Sys.file_exists (Filename.concat directory "invalid-ego.toml"));
  check bool "manual attach uses the same target validator before worker allocation" true
    (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Attach (`Assoc ["manifest_path",`String manifest_path;
      "run_id",`String "invalid-ego";"binding",`Assoc ["sources",`List [];"space",`Int (-1)]])));
  check (Alcotest.list Alcotest.string) "neither path started a worker" [] !started)

let test_keeper_create_operator_read_and_edit () = with_fixture (fun clock config directory _root started ->
  let bytes = declaration () in
  let created = keeper_call config "masc_lane_declaration_save" (request ~mode:"create" ~file_name:"observer.toml" bytes) in
  check bool "Keeper actually creates the declaration" true (Tool_result.is_success created);
  let receipt = Tool_result.data created in
  check string "create receipt" "created" (member "write" receipt |> text "state");
  check string "apply is not claimed by save" "pending_reconciliation" (text "application" receipt);
  check int "save does not start a worker inline" 0 (List.length !started);
  let observed = read config directory "observer.toml" in
  check string "exact source through operator read" bytes (text "source_text" observed);
  ignore (reconcile config directory);
  await clock (fun () -> List.length !started=1);
  let original_id = one_live config |> text "instance_id" in
  let commented = "# an operator's comment\n" ^ bytes in
  let updated = save config (request ~revision:(text "source_revision" observed) ~mode:"save" ~file_name:"observer.toml" commented) in
  let document = member "document" updated in
  check bool "raw edit changes source revision" true (text "source_revision" observed <> text "source_revision" document);
  check string "comment edit keeps semantic desired revision" (text "desired_revision" observed) (text "desired_revision" document);
  ignore (reconcile config directory);
  check string "comment edit preserves installed worker" original_id (one_live config |> text "instance_id");
  let keeper_read = keeper_call config "masc_lane_declaration_read"
    (`Assoc ["source_path",`String (Filename.concat directory "observer.toml")]) in
  check bool "Keeper can read the operator's edit" true (Tool_result.is_success keeper_read);
  check string "same source bytes" commented (Tool_result.data keeper_read |> text "source_text");
  let same = save config (request ~revision:(text "source_revision" document) ~mode:"save" ~file_name:"observer.toml" commented) in
  check string "identical bytes are not a new edit" "unchanged" (member "write" same |> text "state");
  let changed = save config (request ~revision:(text "source_revision" document) ~mode:"save" ~file_name:"observer.toml" (declaration ~value:"changed" ())) in
  check bool "binding edit changes desired revision" true (text "desired_revision" (member "document" changed) <> text "desired_revision" document);
  check string "saved bytes do not pretend current worker has changed" original_id (one_live config |> text "instance_id");
  ignore (reconcile config directory);
  await clock (fun () -> live config=[]);
  ignore (reconcile config directory);
  await clock (fun () -> List.length !started=2);
  check bool "reconcile owns actual replacement" true (original_id <> (one_live config |> text "instance_id")))

let test_keeper_declaration_cannot_capture_another_fusion_owner () =
  with_fixture (fun _clock config directory _root started ->
    let run_id = "editor-fusion-ownership" in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
      ~keeper:"another-keeper" ~preset:"default" ~roster:Fusion_types.preset_roster
      ~topology:Fusion_types.Simple ~started_at:1.;
    let source id = Printf.sprintf {|id=%S
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="fusion_run", source_id="fusion", run_id=%S}]
|} id run_id in
    let bytes = source "foreign-fusion" in
    let result = keeper_call config "masc_lane_declaration_save"
      (request ~mode:"create" ~file_name:"foreign.toml" bytes) in
    check bool "Keeper save rejects foreign Fusion capture" false (Tool_result.is_success result);
    check bool "rejected configuration cannot be reconciled as operator-owned" false
      (Sys.file_exists (Filename.concat directory "foreign.toml"));
    check int "rejection starts no worker" 0 (List.length !started);
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
      ~keeper:"editor-keeper" ~preset:"default" ~roster:Fusion_types.preset_roster
      ~topology:Fusion_types.Simple ~started_at:1.;
    let own = keeper_call config "masc_lane_declaration_save"
      (request ~mode:"create" ~file_name:"own.toml" bytes) in
    check bool "Keeper can save its own source without granting shared read authority" true
      (Tool_result.is_success own);
    match Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config
      (request ~mode:"create" ~file_name:"operator.toml" (source "operator-fusion")) with
    | Ok _ -> ()
    | Error error -> failf "operator declaration writer remains available: %s" error.Editor.message)

let test_only_the_operator_saves_record_grants () =
  with_fixture (fun _clock config directory _root _started ->
    let with_records id = declaration ~id () ^ {|[[binding.records]]
source_id = "notes"
kind = "board"
visibilities = ["public"]
|} in
    let keeper_save ?revision ~mode file_name bytes = Tool_result.is_success
      (keeper_call config "masc_lane_declaration_save" (request ?revision ~mode ~file_name bytes)) in
    check bool "Keeper save refuses a record grant" false
      (keeper_save ~mode:"create" "keeper.toml" (with_records "keeper-records"));
    (match Runtime.save_declaration ~access:Lane_addon_sources.Unauthenticated ~config
        (request ~mode:"create" ~file_name:"anonymous.toml" (with_records "anonymous-records")) with
     | Error error -> check string "unauthenticated save names the refusal"
         "only an operator-owned declaration may hold record grants" error.Editor.message
     | Ok _ -> fail "unauthenticated save accepted a record grant");
    check bool "refused declarations are not written" false
      (List.exists (fun name -> Sys.file_exists (Filename.concat directory name))
        ["keeper.toml"; "anonymous.toml"]);
    let operator_bytes = with_records "operator-records" in
    ignore (save config (request ~mode:"create" ~file_name:"operator.toml" operator_bytes));
    let current = read config directory "operator.toml" in
    check bool "Keeper edit that keeps the operator's record grant is refused" false
      (keeper_save ~revision:(text "source_revision" current) ~mode:"save" "operator.toml"
        ("# a Keeper's edit\n" ^ operator_bytes));
    check string "the operator's declaration is unchanged" operator_bytes
      (text "source_text" (read config directory "operator.toml")))

let test_operator_reassignment_revokes_old_document_owner () =
  with_fixture (fun _clock config directory _root _started ->
    let registry = Fusion_run_registry.global () in
    List.iter (fun (run_id, keeper) ->
      Fusion_run_registry.register_running registry ~run_id ~keeper ~preset:"default"
        ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple ~started_at:1.)
      ["editor-owner-a", "editor-keeper"; "editor-owner-b", "next-keeper"];
    let bytes ?(manifest_path="../../package.toml") run_id = Printf.sprintf {|id="private-transfer"
run_id="editor-world"
manifest_path=%S
[binding]
sources=[{kind="fusion_run",source_id="fusion",run_id=%S}]
|} manifest_path run_id in
    ignore (unwrap (Runtime.save_declaration ~caller:"editor-keeper" ~config
      (request ~mode:"create" ~file_name:"transfer.toml" (bytes "editor-owner-a"))));
    ignore (reconcile config directory);
    let path = Filename.concat directory "transfer.toml" in
    let read_as caller = Runtime.read_declaration ~caller ~config
      (`Assoc ["source_path", `String path]) in
    let declaration_denial name = match Runtime.read_declaration ~caller:"foreign-keeper" ~config
        (`Assoc ["source_path", `String (Filename.concat directory name)]) with
      | Error error -> error.Editor.code, error.message, error.current
      | Ok _ -> fail "foreign declaration read unexpectedly succeeded" in
    check bool "private and absent declarations expose the same complete error" true
      (declaration_denial "transfer.toml" = declaration_denial "absent.toml");
    write path (bytes "editor-owner-b");
    check bool "old owner cannot read reassigned bytes before reconciliation" true
      (Result.is_error (read_as "editor-keeper"));
    write path ((bytes "editor-owner-b") ^ "\n[unrelated]\nvalue = [");
    check bool "malformed replacement cannot reuse stale owner authority" true
      (Result.is_error (read_as "editor-keeper"));
    write path (bytes ~manifest_path:"../../missing-package.toml" "editor-owner-b");
    check bool "private replacement with missing package cannot disclose its source" true
      (Result.is_error (read_as "editor-keeper"));
    write path (bytes "editor-owner-b");
    ignore (reconcile config directory);
    check bool "old owner remains denied after journal reassignment" true
      (Result.is_error (read_as "editor-keeper"));
    check bool "new verified owner can read the reassigned document" true
      (Result.is_ok (read_as "next-keeper"));
    let current = read config directory "transfer.toml" in
    ignore (save config (request ~revision:(text "source_revision" current) ~mode:"save"
      ~file_name:"transfer.toml" ("enabled = false\n" ^ bytes "editor-owner-b")));
    ignore (reconcile config directory);
    await _clock (fun () -> live config = []);
    ignore (reconcile config directory);
    check bool "disabled preserved document remains readable to its Keeper" true
      (Result.is_ok (read_as "next-keeper"));
    check bool "disabled document remains private after worker cleanup" true
      (Result.is_error (read_as "editor-keeper"));
    let upstream_denial installation_id = Runtime.dispatch ~caller:"foreign-keeper" ~config
        ~operation:Runtime.Attach (`Assoc [
          "manifest_path", `String (Filename.concat _root ".masc/package.toml");
          "run_id", `String "editor-world";
          "binding", `Assoc ["sources", `List [`Assoc [
            "source_id", `String "upstream"; "kind", `String "lane_output";
            "installation_id", `String installation_id;
            "selection", `String "latest_completed"]]]]) in
    let private_denial = upstream_denial "private-transfer" in
    check (result string string) "private upstream reaches the ownership denial"
      (Error "upstream installation is unavailable to this caller")
      (Result.map Yojson.Safe.to_string private_denial);
    check bool "private and absent upstreams expose one denial" true
      (private_denial = upstream_denial "absent-installation");
    write path (declaration ~id:"private-transfer" ());
    ignore (reconcile config directory);
    check bool "private-to-shared reconciliation revokes exclusive Keeper authority" true
      (runtime_result (Lane_addon_document_owner.read
        ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") ~source_path:path) = None);
    check bool "shared declaration remains readable by other Keepers" true
      (Result.is_ok (read_as "another-keeper")))

let test_shared_saves_do_not_claim_keeper_ownership () =
  with_fixture (fun _clock config directory _root _started ->
    let bytes = declaration ~id:"shared-editor" () in
    ignore (save config (request ~mode:"create" ~file_name:"shared.toml" bytes));
    let path = Filename.concat directory "shared.toml" in
    let read_as keeper = Runtime.read_declaration ~caller:keeper ~config
      (`Assoc ["source_path",`String path]) |> unwrap in
    let edit = read_as "first-keeper" in
    ignore (unwrap (Runtime.save_declaration ~caller:"first-keeper" ~config
      (request ~revision:(text "source_revision" edit) ~mode:"save" ~file_name:"shared.toml" bytes)));
    ignore (read_as "other-keeper");
    check bool "shared save leaves no exclusive Keeper ownership" true
      (runtime_result (Lane_addon_document_owner.read
        ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") ~source_path:path) = None);
    let edit = read_as "other-keeper" in
    ignore (unwrap (Runtime.save_declaration ~caller:"local-dashboard"
      ~access:Lane_addon_sources.Unauthenticated ~config
      (request ~revision:(text "source_revision" edit) ~mode:"save" ~file_name:"shared.toml" bytes)));
    ignore (unwrap (Runtime.save_declaration ~caller:"local-dashboard"
      ~access:Lane_addon_sources.Unauthenticated ~config
      (request ~mode:"create" ~file_name:"local.toml" (declaration ~id:"local-editor" ())))))

let test_unconfirmed_shared_save_withdraws_private_owner () =
  with_fixture (fun _clock config directory _root _started ->
    let run_id = "unconfirmed-private-source" in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
      ~keeper:"editor-keeper" ~preset:"default" ~roster:Fusion_types.preset_roster
      ~topology:Fusion_types.Simple ~started_at:1.;
    let private_bytes = Printf.sprintf {|id="private-save"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="fusion_run",source_id="fusion",run_id=%S}]
|} run_id in
    let receipt = unwrap (Runtime.save_declaration ~caller:"editor-keeper" ~config
      (request ~mode:"create" ~file_name:"private.toml" private_bytes)) in
    let revision = text "source_revision" (member "document" receipt) in
    let shared = declaration ~id:"private-save" () in
    let replace_file path source = Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",directory))) path source in
    let writer ~packages ~workspace ~directory request = Editor.For_testing.write ~replace_file ~packages ~workspace ~directory request in
    let saved = Runtime.For_testing.with_declaration_writer writer (fun () ->
      Runtime.save_declaration ~caller:"editor-keeper" ~config
        (request ~revision ~mode:"save" ~file_name:"private.toml" shared)) |> unwrap in
    check string "visible shared save returns its durability receipt" "unconfirmed"
      (member "write" saved |> text "durability");
    let path = Filename.concat directory "private.toml" in
    let observed = Runtime.read_declaration ~caller:"another-keeper" ~config
      (`Assoc ["source_path",`String path]) |> unwrap in
    check string "shared bytes remain readable after private ownership withdrawal" shared
      (text "source_text" observed);
    check bool "another Keeper can edit the now shared declaration" true
      (Result.is_ok (Runtime.save_declaration ~caller:"another-keeper" ~config
        (request ~revision:(text "source_revision" observed) ~mode:"save" ~file_name:"private.toml"
          (declaration ~id:"private-save" ~value:"second-owner" ())))))

let test_conflicts_and_invalid_candidates_preserve_active () = with_fixture (fun clock config directory _root started ->
  let original = declaration () in
  let created = save config (request ~mode:"create" ~file_name:"observer.toml" original) in
  let revision = member "document" created |> text "source_revision" in
  ignore (reconcile config directory);await clock (fun () -> !started<>[]);
  let instance_id = one_live config |> text "instance_id" in
  let edited = "# external editor\n" ^ original in
  write (Filename.concat directory "observer.toml") edited;
  let conflict = keeper_call config "masc_lane_declaration_save"
    (request ~revision ~mode:"save" ~file_name:"observer.toml" (declaration ~value:"stale" ())) in
  check bool "Keeper gets a real failed outcome" false (Tool_result.is_success conflict);
  let details = Tool_result.data conflict in
  check string "typed conflict survives tool boundary" "revision_conflict" (text "code" details);
  check bool "Keeper conflict does not disclose a racing document" true
    (member "current" details = `Null);
  let current = read config directory "observer.toml" in
  List.iter (fun args ->
    match Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config args with
    | Error error -> check bool "invalid candidate is a typed rejection" true (error.code=Editor.Invalid_declaration)
    | Ok _ -> fail "invalid candidate was written")
    [request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"observer.toml" "id = [";
     request ~mode:"create" ~file_name:"duplicate.toml" original];
  check bool "duplicate file was never published" false (Sys.file_exists (Filename.concat directory "duplicate.toml"));
  check string "existing bytes remain exact" edited (read config directory "observer.toml" |> text "source_text");
  ignore (reconcile config directory);
  check string "invalid edits never retire active worker" instance_id (one_live config |> text "instance_id"))

(* The real configuration pass removes a released instance that a newer
   binding of the same owner supersedes, and folders no binding claims. *)
let test_superseded_instance_records_leave () = with_fixture (fun clock config directory root _started ->
  let store = Filename.concat root ".masc/lane-addons" in
  let at relative = Filename.concat store relative in
  let path = Filename.concat directory "observer.toml" in
  let attach () =
    write path (declaration ());
    ignore (reconcile config directory);
    await clock (fun () -> live config <> []);
    one_live config |> text "instance_id" in
  let folder folder = at (Lane_addon_store.instance_folder_path folder) in
  let fill relative =
    Fs_compat.mkdir_p (at relative);
    write (Filename.concat (at relative) "00000000000000000001.json") "{}" in
  let first = attach () in
  Unix.unlink path;
  ignore (reconcile config directory);
  await clock (fun () -> live config = []);
  let second = attach () in
  let key = Lane_addon_store.instance_key in
  let first_observations = Lane_addon_store.Observation_folder (key first)
  and second_actions = Lane_addon_store.Action_folder (key second)
  and orphan_observations = Lane_addon_store.Observation_folder (key "no-binding-observations")
  and orphan_actions = Lane_addon_store.Action_folder (key "no-binding-actions") in
  List.iter (fun f -> fill (Lane_addon_store.instance_folder_path f))
    [first_observations; second_actions; orphan_observations; orphan_actions];
  check bool "the detached first instance keeps its binding before the pass" true
    (Sys.file_exists (at (Lane_addon_store.binding_path first)));
  ignore (reconcile config directory);
  check bool "the superseded binding is removed" false
    (Sys.file_exists (at (Lane_addon_store.binding_path first)));
  List.iter (fun (name, f) -> check bool name false (Sys.file_exists (folder f)))
    ["the superseded instance's observations are removed", first_observations;
     "observations no binding claims are removed", orphan_observations;
     "actions no binding claims are removed", orphan_actions];
  check bool "the live instance keeps its binding" true
    (Sys.file_exists (at (Lane_addon_store.binding_path second)));
  check bool "the live instance keeps its actions" true (Sys.file_exists (folder second_actions));
  check string "the live instance is untouched" second (one_live config |> text "instance_id"))

let test_invalid_existing_source_can_be_repaired () = with_fixture (fun _clock config directory root _started ->
  let path = Filename.concat directory "broken.toml" in
  write path "id = [";
  let broken = read config directory "broken.toml" in
  check bool "invalid source remains readable" false (member "valid" (member "validation" broken) |> Yojson.Safe.Util.to_bool);
  write path ("id=\"duplicate\"\n" ^ declaration ());
  let duplicate = read config directory "broken.toml" in
  check bool "duplicate declaration keys remain readable" false
    (member "valid" (member "validation" duplicate) |> Yojson.Safe.Util.to_bool);
  write path "id = [";
  let saved = save config (request ~revision:(text "source_revision" broken) ~mode:"save" ~file_name:"broken.toml" (declaration ())) in
  check bool "repair validates using the final relative path" true
    (member "valid" (member "validation" (member "document" saved)) |> Yojson.Safe.Util.to_bool);
  let package_path = Filename.concat root ".masc/package.toml" in
  write package_path ("id=\"duplicate\"\n" ^ manifest);
  let missing_manifest = read config directory "broken.toml" in
  check string "invalid package still permits reading declaration bytes" (declaration ()) (text "source_text" missing_manifest);
  check bool "duplicate manifest is reported, not an uncaught exception" false
    (member "valid" (member "validation" missing_manifest) |> Yojson.Safe.Util.to_bool);
  Unix.unlink package_path;
  let missing = read config directory "broken.toml" in
  check string "missing package still permits reading declaration bytes" (declaration ()) (text "source_text" missing);
  check bool "a missing dependency does not hide the declaration inventory" true
    (Lane_addon_config.load ~packages:(packages config) ~workspace:config.Workspace.base_path ~directory).complete;
  write (Filename.concat root ".masc/replacement-package.toml") manifest;
  let repaired_source = declaration ~manifest_path:"../../replacement-package.toml" () in
  let repaired = save config (request ~revision:(text "source_revision" missing) ~mode:"save"
    ~file_name:"broken.toml" repaired_source) |> member "document" in
  check bool "saving another manifest repairs the declaration" true
    (member "valid" (member "validation" repaired) |> Yojson.Safe.Util.to_bool);
  check string "replacement declaration bytes are committed" repaired_source
    (read config directory "broken.toml" |> text "source_text");
  check bool "replacement manifest has a new semantic revision" true
    (text "desired_revision" repaired <> text "desired_revision" (member "document" saved));
  check bool "repair did not recreate the missing dependency" false (Sys.file_exists package_path);
  let unreadable = Filename.concat directory "unreadable.toml" in
  Unix.mkdir unreadable 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir unreadable) (fun () ->
    check bool "an unreadable declaration makes inventory incomplete" false
      (Lane_addon_config.load ~packages:(packages config) ~workspace:config.Workspace.base_path ~directory).complete;
    match Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config (request ~revision:(text "source_revision" repaired)
      ~mode:"save" ~file_name:"broken.toml" ("# cannot inventory peers\n" ^ repaired_source)) with
    | Error error -> check bool "unreadable inventory still blocks publication" true (error.code=Editor.Io_error)
    | Ok _ -> fail "saved without a readable declaration inventory");
  check string "unreadable inventory did not change committed bytes" repaired_source
    (read config directory "broken.toml" |> text "source_text"))

let test_request_paths_and_create_are_exact () = with_fixture (fun _clock config directory root _started ->
  let bytes = declaration () in
  List.iter (fun args -> check bool "invalid mode/revision combination refused" true
    (Result.is_error (Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config args)))
    [request ~mode:"save" ~file_name:"a.toml" bytes;
     request ~revision:(String.make 64 'a') ~mode:"create" ~file_name:"a.toml" bytes;
     request ~mode:"create" ~file_name:"../outside.toml" bytes;
     request ~mode:"create" ~file_name:"nested/a.toml" bytes];
  ignore (save config (request ~mode:"create" ~file_name:"a.toml" bytes));
  (match Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config (request ~mode:"create" ~file_name:"a.toml" bytes) with
   | Error error -> check bool "create never overwrites" true (error.code=Editor.Revision_conflict)
   | Ok _ -> fail "create replaced an existing declaration");
  let outside = Filename.concat root "outside.toml" in write outside bytes;
  Unix.symlink outside (Filename.concat directory "link.toml");
  List.iter (fun source_path ->
    check bool "read has no arbitrary filesystem path escape" true
      (Result.is_error (Runtime.read_declaration ~access:Lane_addon_sources.Operator_configuration ~config (`Assoc ["source_path",`String source_path]))))
    [outside;Filename.concat directory "link.toml"])

let test_two_writers_and_post_rename_failure () = with_fixture (fun _clock config directory _root _started ->
  let bytes = declaration () in
  let first = save config (request ~mode:"create" ~file_name:"a.toml" bytes) in
  let revision = member "document" first |> text "source_revision" in
  let args value = request ~revision ~mode:"save" ~file_name:"a.toml" (declaration ~value ()) in
  let a,b = Eio.Fiber.pair (fun () -> Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config (args "a"))
    (fun () -> Runtime.save_declaration ~access:Lane_addon_sources.Operator_configuration ~config (args "b")) in
  check int "one writer owns the observed source revision" 1 (List.length (List.filter Result.is_ok [a;b]));
  check int "the other writer observes the committed conflict" 1 (List.length (List.filter Result.is_error [a;b]));
  let current = read config directory "a.toml" in
  let next = declaration ~value:"visible-after-fsync-failure" () in
  let request = Editor.write_request (request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"a.toml" next) |> unwrap in
  let replace_file path source = Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
    ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",directory)))
    path source in
  let receipt = Eio_unix.run_in_systhread (fun () -> Editor.For_testing.write ~replace_file ~packages:(packages config) ~workspace:config.Workspace.base_path ~directory request) |> unwrap in
  let json = Editor.receipt_to_json receipt in
  check string "post-rename result records visible save" "saved" (member "write" json |> text "state");
  check string "failed parent fsync is not claimed durable" "unconfirmed" (member "write" json |> text "durability");
  check string "published bytes were not silently rolled back" next (read config directory "a.toml" |> text "source_text"))

let test_create_publication_collision_preserves_competing_bytes () = with_fixture (fun _clock config directory _root _started ->
  let path = Filename.concat directory "contested.toml" in
  let competing = declaration ~id:"external-writer" () in
  let staged_path = ref None in
  let replace_file staged bytes =
    staged_path := Some staged;
    match Fs_compat.save_file_atomic_strict_staged staged bytes with
    | Error error -> Error error
    | Ok () -> write path competing; Ok () in
  let request = Editor.write_request (request ~mode:"create" ~file_name:"contested.toml" (declaration ())) |> unwrap in
  (match Eio_unix.run_in_systhread (fun () -> Editor.For_testing.write ~replace_file ~packages:(packages config) ~workspace:config.Workspace.base_path ~directory request) with
   | Error error -> check bool "publication refuses a concurrently created file" true (error.code=Editor.Revision_conflict)
   | Ok _ -> fail "create overwrote the competing publication");
  check string "competing source bytes survive" competing (read config directory "contested.toml" |> text "source_text");
  match !staged_path with
  | None -> fail "publication staging was not exercised"
  | Some path -> check bool "owned staging is cleaned after refused publication" false (Sys.file_exists path))

(* A Keeper names a manifest only inside the workspace, and the refusal comes
   before the file is opened: the outside files are not valid TOML, so opening
   one would answer with its parse error instead. [escape] reads as
   [<root>/escape.toml] if [..] is folded before the link is followed; the
   kernel follows the link first and opens the file outside. Operator
   configuration still opens the path it names. *)
let test_keeper_manifest_outside_workspace_is_refused_unopened () =
  with_fixture (fun _clock config directory root started ->
  let outside = Filename.temp_file "lane-outside-" ".toml" in
  let escape_dir = Filename.temp_dir "lane-escape-" "" |> Unix.realpath in
  let escape_inner = Filename.concat escape_dir "inner" in
  let escape_file = Filename.concat escape_dir "escape.toml" in
  let escape_link = Filename.concat root "inner-link" in
  Unix.mkdir escape_inner 0o700;
  write escape_file "id = [unclosed";
  Unix.symlink escape_inner escape_link;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove outside;
      Unix.unlink escape_link;
      Sys.remove escape_file;
      Unix.rmdir escape_inner;
      Unix.rmdir escape_dir)
    (fun () ->
    write outside "id = [unclosed";
    let escape = Filename.concat escape_link "../escape.toml" in
    let link = Filename.concat root "outside-link.toml" in
    Unix.symlink outside link;
    check (option string) "a path inside the workspace resolves to the file it opens"
      (Some (Filename.concat root ".masc/package.toml"))
      (Lane_addon_manifest.resolve_in_workspace ~workspace:root
         (Filename.concat root ".masc/config/../package.toml"));
    let attach ?access path = Runtime.dispatch ~caller:"keeper-a" ?access ~config
        ~operation:Runtime.Attach (`Assoc ["manifest_path",`String path;"run_id",`String "outside";
          "binding",`Assoc ["sources",`List []]]) in
    let refused = Error Lane_addon_manifest.outside_workspace in
    check (result reject string) "Keeper attach outside the workspace" refused (attach outside);
    check (result reject string) "Keeper attach through a link inside the workspace" refused (attach link);
    check (result reject string) "Keeper attach through a link and then .." refused (attach escape);
    check bool "operator attach still opens the path it names" true
      (match attach ~access:Lane_addon_sources.Operator_configuration outside with
       | Error message -> message <> Lane_addon_manifest.outside_workspace
       | Ok _ -> false);
    (match Runtime.save_declaration ~caller:"keeper-a" ~config
             (request ~mode:"create" ~file_name:"outside.toml" (declaration ~manifest_path:outside ())) with
     | Error {Editor.code=Editor.Invalid_declaration;message;_} ->
         check string "Keeper save outside the workspace" Lane_addon_manifest.outside_workspace message
     | Ok _ | Error _ -> fail "Keeper save outside the workspace was not refused as a declaration");
    (match Runtime.save_declaration ~caller:"keeper-a" ~config
             (request ~mode:"create" ~file_name:"outside.toml" (declaration ~manifest_path:escape ())) with
     | Error {Editor.code=Editor.Invalid_declaration;message;_} ->
         check string "Keeper save through a link and then .." Lane_addon_manifest.outside_workspace message
     | Ok _ | Error _ -> fail "Keeper save through a link and then .. was not refused as a declaration");
    check bool "refused save wrote no declaration" false
      (Sys.file_exists (Filename.concat directory "outside.toml"));
    check (Alcotest.list Alcotest.string) "no worker started" [] !started))

let test_non_operator_cannot_run_host_process_or_read_outside_snapshot () =
  with_fixture (fun _clock config directory root started ->
    let host_manifest = Filename.concat root ".masc/host-worker.toml" in
    write host_manifest {|id="host-worker-test"
revision="1"
title="Host process fixture"
runtime="host_process"
command=["/bin/echo","ok"]
contributions=["observe"]
[resources]
max_reply_bytes=4096
|};
    let outside_snapshot = Filename.temp_file "lane-outside-snap-" ".json" in
    write outside_snapshot
      {|{"source_id":"s","incarnation":"1","cursor":"1","complete":true,"detail":null,"observations":[]}|};
    Fun.protect ~finally:(fun () -> if Sys.file_exists outside_snapshot then Sys.remove outside_snapshot) (fun () ->
      let attach_host =
        Runtime.dispatch ~caller:"keeper-a" ~config ~operation:Runtime.Attach
          (`Assoc ["manifest_path", `String host_manifest; "run_id", `String "host-attempt";
            "binding", `Assoc ["sources", `List []]])
      in
      check bool "Keeper cannot attach a host_process manifest" true (Result.is_error attach_host);
      let save_host =
        Runtime.save_declaration ~caller:"keeper-a" ~config
          (request ~mode:"create" ~file_name:"host-worker.toml"
             (declaration ~manifest_path:host_manifest ()))
      in
      check bool "Keeper cannot save a host_process declaration" true
        (match save_host with Error {Editor.code = Editor.Invalid_request; _} -> true | Ok _ | Error _ -> false);
      let attach_outside_snap =
        Runtime.dispatch ~caller:"keeper-a" ~config ~operation:Runtime.Attach
          (`Assoc ["manifest_path", `String (Filename.concat root ".masc/package.toml");
            "run_id", `String "snap-attempt";
            "binding", `Assoc ["sources", `List [`Assoc [
              "source_id", `String "s"; "kind", `String "snapshot_file";
              "path", `String outside_snapshot]]]])
      in
      check bool "Keeper cannot attach a snapshot_file outside workspace" true
        (Result.is_error attach_outside_snap);
      check bool "refused host_process save wrote no declaration" false
        (Sys.file_exists (Filename.concat directory "host-worker.toml"));
      check (Alcotest.list Alcotest.string) "no worker started" [] !started))

(* RFC lane-declaration-operator-authority. A file a declaration points at
   changes after the save; reconcile reads it again on every pass. *)
let host_manifest = {|id="host-worker-test"
revision="1"
title="Host process fixture"
runtime="host_process"
command=["/bin/echo","ok"]
contributions=["observe"]
[resources]
max_reply_bytes=4096
|}
let host_process_denied = "host_process execution requires operator configuration"
let issue_for json source_path = list "issues" json |> List.filter_map (fun issue ->
  if text "source_path" issue = source_path then Some (text "message" issue) else None)
let reads_as config = one_live config |> member "source_access" |> text "kind"
(* The first pass stops the worker; the next one decides the attach. *)
let reconcile_after_stop clock config directory =
  ignore (reconcile config directory);
  await clock (fun () -> live config = []);
  reconcile config directory

let test_keeper_declaration_cannot_reach_host_process_after_save () =
  with_fixture (fun clock config directory root started ->
    ignore (unwrap (Runtime.save_declaration ~caller:"keeper-a" ~config
      (request ~mode:"create" ~file_name:"observer.toml" (declaration ()))));
    ignore (reconcile config directory);
    check string "a Keeper's Shared declaration reads with the least authority" "unauthenticated"
      (reads_as config);
    write (Filename.concat root ".masc/package.toml") host_manifest;
    let after = reconcile_after_stop clock config directory in
    check bool "the host_process manifest is an issue of the Keeper's declaration" true
      (List.exists (String.starts_with ~prefix:host_process_denied)
        (issue_for after (Filename.concat directory "observer.toml")));
    check int "no host process started" 1 (List.length !started);
    check int "nothing runs" 0 (List.length (live config)))

let test_operator_edit_keeps_a_keeper_declaration_unprivileged () =
  with_fixture (fun clock config directory root started ->
    let snapshot_bytes =
      {|{"source_id":"s","incarnation":"1","cursor":"1","complete":true,"detail":null,"observations":[]}|} in
    let snapshot = Filename.concat root "snapshot.json" in
    write snapshot snapshot_bytes;
    let outside = Filename.temp_file "lane-outside-snap-" ".json" in
    write outside snapshot_bytes;
    Fun.protect ~finally:(fun () -> if Sys.file_exists outside then Sys.remove outside) (fun () ->
      let bytes value = Printf.sprintf {|id="reader"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="snapshot_file",source_id="s",path=%S}]
value=%S
|} snapshot value in
      ignore (unwrap (Runtime.save_declaration ~caller:"keeper-a" ~config
        (request ~mode:"create" ~file_name:"reader.toml" (bytes "first"))));
      ignore (reconcile config directory);
      check string "a Keeper's snapshot declaration reads with the least authority" "unauthenticated"
        (reads_as config);
      Unix.unlink snapshot;
      Unix.symlink outside snapshot;
      (* The operator edits the Keeper's file without adding the operator line. *)
      let path = Filename.concat directory "reader.toml" in
      write path (bytes "second");
      let after = reconcile_after_stop clock config directory in
      check bool "the edited declaration still cannot read outside the workspace" true
        (List.exists (String.starts_with ~prefix:"snapshot_file path must name a file inside the workspace")
          (issue_for after path));
      check int "no second worker started" 1 (List.length !started)))

let test_operator_line_runs_host_process_and_its_removal_stops_it () =
  with_fixture (fun clock config directory root started ->
    write (Filename.concat root ".masc/package.toml") host_manifest;
    let path = Filename.concat directory "host.toml" in
    write path ("operator_authority = \"yes\"\n" ^ declaration ~id:"host" ());
    check bool "operator_authority takes only a boolean" true
      (List.mem "operator_authority requires a boolean" (issue_for (reconcile config directory) path));
    write path ("operator_authority = true\n" ^ declaration ~id:"host" ());
    ignore (reconcile config directory);
    check string "a marked declaration reads as the operator" "operator_configuration" (reads_as config);
    write path (declaration ~id:"host" ());
    check bool "without the line the running host process is an issue" true
      (List.exists (String.starts_with ~prefix:host_process_denied) (issue_for (reconcile config directory) path));
    await clock (fun () -> live config = []);
    check int "the host process started once" 1 (List.length !started))

let test_only_the_operator_saves_operator_authority () =
  with_fixture (fun _clock config directory _root _started ->
    let marked id = "operator_authority = true\n" ^ declaration ~id () in
    let refused = function
      | Error {Editor.code = Editor.Invalid_request; message; _} ->
          String.equal message "only the operator can save operator_authority = true"
      | Ok _ | Error _ -> false in
    check bool "a Keeper cannot save the operator's line" true
      (refused (Runtime.save_declaration ~caller:"keeper-a" ~config
        (request ~mode:"create" ~file_name:"keeper.toml" (marked "keeper-marked"))));
    check bool "an unauthenticated caller cannot save it" true
      (refused (Runtime.save_declaration ~access:Lane_addon_sources.Unauthenticated ~config
        (request ~mode:"create" ~file_name:"anonymous.toml" (marked "anonymous-marked"))));
    check bool "refused declarations are not written" false
      (List.exists (fun name -> Sys.file_exists (Filename.concat directory name)) ["keeper.toml"; "anonymous.toml"]);
    let operator_bytes = marked "operator-marked" in
    ignore (save config (request ~mode:"create" ~file_name:"operator.toml" operator_bytes));
    let current = read config directory "operator.toml" in
    check bool "a Keeper edit that keeps the operator's line is refused" true
      (Result.is_error (Runtime.save_declaration ~caller:"keeper-a" ~config
        (request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"operator.toml"
          ("# a Keeper's edit\n" ^ operator_bytes))));
    let changes_operator_file = function
      | Error {Editor.code = Editor.Invalid_request; message; _} ->
          String.equal message
            "only the operator can change or remove a declaration that carries operator_authority = true"
      | Ok _ | Error _ -> false in
    check bool "a Keeper edit that drops the operator's line is refused" true
      (changes_operator_file (Runtime.save_declaration ~caller:"keeper-a" ~config
        (request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"operator.toml"
          (declaration ~id:"operator-marked" ~value:"a Keeper's" ()))));
    check bool "so is an unauthenticated caller's" true
      (changes_operator_file (Runtime.save_declaration ~access:Lane_addon_sources.Unauthenticated ~config
        (request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"operator.toml"
          (declaration ~id:"operator-marked" ~value:"anonymous" ()))));
    check string "the operator's declaration is unchanged" operator_bytes
      (text "source_text" (read config directory "operator.toml")))

let test_unmarked_operator_only_binding_is_refused () =
  with_fixture (fun _clock config directory _root started ->
    let registry = Fusion_run_registry.global () in
    List.iter (fun (run_id, keeper) ->
      Fusion_run_registry.register_running registry ~run_id ~keeper ~preset:"default"
        ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple ~started_at:1.)
      ["authority-run-a", "keeper-a"; "authority-run-b", "keeper-b"];
    let bytes = {|id="two-owners"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="fusion_run",source_id="a",run_id="authority-run-a"},{kind="fusion_run",source_id="b",run_id="authority-run-b"}]
|} in
    let path = Filename.concat directory "two-owners.toml" in
    write path bytes;
    check bool "an unmarked binding of two Keepers' runs is refused" true
      (List.mem "a binding that reads an operator-only source requires operator_authority = true"
        (issue_for (reconcile config directory) path));
    check int "nothing started" 0 (List.length !started);
    write path ("operator_authority = true\n" ^ bytes);
    ignore (reconcile config directory);
    check string "the marked binding reads as the operator" "operator_configuration" (reads_as config))

let test_inherited_visibility_does_not_grant_keeper_authority () =
  with_fixture (fun _clock config directory _root _started ->
    Fusion_run_registry.register_running (Fusion_run_registry.global ())
      ~run_id:"direct-authority-run" ~keeper:"keeper-a" ~preset:"default"
      ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple ~started_at:1.;
    write (Filename.concat directory "a-direct.toml") {|id="a-direct"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="fusion_run",source_id="a",run_id="direct-authority-run"}]
|};
    let inherited = Filename.concat directory "b-inherited.toml" in
    write inherited {|id="b-inherited"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="lane_output",source_id="upstream",installation_id="a-direct",selection="latest_completed"}]
|};
    let result = reconcile config directory in
    check bool "inheritance does not supply Keeper authority" true
      (List.mem "a binding that only inherits Keeper visibility requires operator_authority = true"
        (issue_for result inherited));
    check bool "the direct Fusion source still reads as its owner" true
      (member "source_access" (one_live config) =
       Lane_addon_sources.access_to_json (Lane_addon_sources.Keeper "keeper-a"));
    (* The save path refuses what reconcile would refuse, before writing. *)
    let keeper_inherited = {|id="c-inherited"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="lane_output",source_id="upstream",installation_id="a-direct",selection="latest_completed"}]
|} in
    (match Runtime.save_declaration ~caller:"keeper-a" ~config
        (request ~mode:"create" ~file_name:"c-inherited.toml" keeper_inherited) with
     | Error {Editor.code = Editor.Invalid_request; message; _} ->
         check string "the upstream's Keeper cannot save an inherited-only binding"
           "a binding that only inherits Keeper visibility requires operator_authority = true" message
     | Ok _ | Error _ -> fail "an inherited-only Keeper binding was saved");
    check bool "the refused binding is not written" false
      (Sys.file_exists (Filename.concat directory "c-inherited.toml")))

(* RFC lane-declaration-operator-authority 3.3: the line is outside the
   revision, so a pass that cannot apply the declaration still stops what
   only the line allowed. An unreadable second record of the declaration keeps
   this pass from applying it. *)
let test_removed_line_stops_a_host_process_the_pass_cannot_apply () =
  with_fixture (fun clock config directory root started ->
    write (Filename.concat root ".masc/package.toml") host_manifest;
    let path = Filename.concat directory "host.toml" in
    write path ("operator_authority = true\n" ^ declaration ~id:"host" ());
    ignore (reconcile config directory);
    check string "the marked host process runs as the operator" "operator_configuration" (reads_as config);
    let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    let unreadable_id = "unreadable-host-record" in
    let unreadable = match Lane_addon_store.bindings store with
      | Ok [`Assoc fields] ->
          `Assoc (("instance_id", `String unreadable_id) :: ("visibility", `String "unreadable")
            :: List.filter (fun (key, _) -> key <> "instance_id" && key <> "visibility") fields)
      | Ok _ | Error _ -> fail "expected the host worker's one record" in
    (match Lane_addon_store.save_binding store ~instance_id:unreadable_id unreadable with
     | Ok () -> () | Error message -> fail message);
    write path (declaration ~id:"host" ());
    let messages = issue_for (reconcile config directory) path in
    check bool "the pass cannot apply the declaration" true
      (List.exists (String.starts_with ~prefix:"Not applied while") messages);
    check bool "the removed line still stops the host process" true
      (List.mem (host_process_denied ^ "; only the operator allows it, with operator_authority = true") messages);
    await clock (fun () -> live config = []);
    check int "the host process started once" 1 (List.length !started);
    (match Lane_addon_store.remove_binding store ~instance_id:unreadable_id with
     | Ok () -> () | Error message -> fail message))

(* The operator's line is named only where it would lift the refusal. A marked
   Keeper_only file still reads as its Keeper, so its record grant stays
   refused. *)
let test_operator_line_is_named_only_where_it_lifts_the_refusal () =
  with_fixture (fun _clock config directory _root started ->
    Fusion_run_registry.register_running (Fusion_run_registry.global ())
      ~run_id:"hint-run" ~keeper:"keeper-a" ~preset:"default"
      ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple ~started_at:1.;
    let records = {|[[binding.records]]
source_id = "notes"
kind = "board"
visibilities = ["public"]
|} in
    let shared = Filename.concat directory "shared-records.toml" in
    write shared (declaration ~id:"shared-records" () ^ records);
    let private_ = Filename.concat directory "private-records.toml" in
    write private_ ({|id="private-records"
run_id="editor-world"
manifest_path="../../package.toml"
[binding]
sources=[{kind="fusion_run",source_id="a",run_id="hint-run"}]
|} ^ records);
    let result = reconcile config directory in
    let refused = "only an operator-owned declaration may hold record grants" in
    check (Alcotest.list Alcotest.string) "a Shared grant names the line that lifts it"
      [refused ^ "; only the operator allows it, with operator_authority = true"] (issue_for result shared);
    check (Alcotest.list Alcotest.string) "a Keeper_only grant does not name a line that would not lift it"
      [refused] (issue_for result private_);
    check int "nothing started" 0 (List.length !started))

(* RFC lane-declaration-operator-authority 3.5: a marked file is the
   operator's, so only the operator's Detach removes it. *)
let test_only_the_operator_removes_a_marked_declaration () =
  with_fixture (fun _clock config directory _root _started ->
    let path = Filename.concat directory "marked.toml" in
    write path ("operator_authority = true\n" ^ declaration ~id:"marked" ());
    ignore (reconcile config directory);
    let instance_id = text "instance_id" (one_live config) in
    let detach ?caller ?access () = Runtime.dispatch ?caller ?access ~config ~operation:Runtime.Detach
      (`Assoc ["instance_id", `String instance_id]) in
    let refused = function
      | Error message -> String.equal message
          "only the operator can change or remove a declaration that carries operator_authority = true"
      | Ok _ -> false in
    check bool "a Keeper cannot detach the operator's declaration" true (refused (detach ~caller:"keeper-a" ()));
    check bool "nor can an unauthenticated caller" true
      (refused (detach ~access:Lane_addon_sources.Unauthenticated ()));
    check bool "the declaration stays" true (Sys.file_exists path);
    check int "its worker keeps running" 1 (List.length (live config));
    (match detach () with Ok _ -> () | Error message -> fail message);
    check bool "the operator's Detach removes it" false (Sys.file_exists path))

let test_unmarked_manifest_outside_the_workspace_is_not_opened () =
  with_fixture (fun _clock config directory root started ->
    ignore (unwrap (Runtime.save_declaration ~caller:"keeper-a" ~config
      (request ~mode:"create" ~file_name:"observer.toml" (declaration ()))));
    ignore (reconcile config directory);
    let outside = Filename.temp_file "lane-outside-manifest-" ".toml" in
    (* Not a manifest: a parse of it would put its error text in the issue. *)
    write outside "id = [\n";
    Fun.protect ~finally:(fun () -> if Sys.file_exists outside then Sys.remove outside) (fun () ->
      let manifest = Filename.concat root ".masc/package.toml" in
      Unix.unlink manifest;
      Unix.symlink outside manifest;
      let messages = issue_for (reconcile config directory) (Filename.concat directory "observer.toml") in
      check bool "the outside file is refused before it is opened" true
        (messages <> [] && List.for_all (String.equal "manifest_path must name a file inside the workspace") messages);
      check int "no second worker started" 1 (List.length !started)))

let () = run "Lane declaration editing" ["shared TOML owner",[
  test_case "unmarked manifest outside the workspace is not opened" `Quick
      test_unmarked_manifest_outside_the_workspace_is_not_opened;
  test_case "Keeper declaration cannot reach host_process after its save" `Quick
      test_keeper_declaration_cannot_reach_host_process_after_save;
  test_case "operator edit keeps a Keeper declaration unprivileged" `Quick
      test_operator_edit_keeps_a_keeper_declaration_unprivileged;
  test_case "operator line runs host_process and its removal stops it" `Quick
      test_operator_line_runs_host_process_and_its_removal_stops_it;
  test_case "only the operator saves operator_authority" `Quick test_only_the_operator_saves_operator_authority;
  test_case "unmarked operator-only binding is refused" `Quick test_unmarked_operator_only_binding_is_refused;
  test_case "inherited visibility does not grant Keeper authority" `Quick
    test_inherited_visibility_does_not_grant_keeper_authority;
  test_case "removed line stops a host process the pass cannot apply" `Quick
    test_removed_line_stops_a_host_process_the_pass_cannot_apply;
  test_case "operator line is named only where it lifts the refusal" `Quick
    test_operator_line_is_named_only_where_it_lifts_the_refusal;
  test_case "only the operator removes a marked declaration" `Quick
    test_only_the_operator_removes_a_marked_declaration;
  test_case "non-operator cannot run host_process or read outside snapshot_file" `Quick
      test_non_operator_cannot_run_host_process_or_read_outside_snapshot;
  test_case "Keeper manifest outside the workspace is refused unopened" `Quick
      test_keeper_manifest_outside_workspace_is_refused_unopened;
  test_case "invalid Ego Space never publishes or attaches" `Quick test_invalid_ego_space_never_publishes_or_attaches;
  test_case "shared and local saves do not claim private ownership" `Quick test_shared_saves_do_not_claim_keeper_ownership;
  test_case "Keeper cannot save another owner's Fusion capture" `Quick
      test_keeper_declaration_cannot_capture_another_fusion_owner;
  test_case "only the operator saves record grants" `Quick test_only_the_operator_saves_record_grants;
  test_case "unconfirmed shared save withdraws private ownership" `Quick
      test_unconfirmed_shared_save_withdraws_private_owner;
  test_case "operator reassignment replaces private document authority" `Quick
      test_operator_reassignment_revokes_old_document_owner;
    test_case "Keeper creates and operator edits the same TOML" `Quick test_keeper_create_operator_read_and_edit;
  test_case "conflict and invalid candidate preserve active installation" `Quick test_conflicts_and_invalid_candidates_preserve_active;
  test_case "invalid source and missing package remain repairable" `Quick test_invalid_existing_source_can_be_repaired;
  test_case "superseded instance records leave in the configuration pass" `Quick test_superseded_instance_records_leave;
  test_case "mode, create-only and direct-child path boundaries" `Quick test_request_paths_and_create_are_exact;
  test_case "create publication collision preserves the competing file" `Quick test_create_publication_collision_preserves_competing_bytes;
  test_case "concurrent editors and visible post-rename failure" `Quick test_two_writers_and_post_rename_failure]]
