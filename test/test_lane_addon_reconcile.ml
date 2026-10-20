(** TOML installation lifecycle through the real configuration reader and
    runtime reconciler. Only the external worker and source acquisition are
    replaced by observable barriers; no Docker daemon or model is required. *)
open Alcotest
open Masc
module Runtime = struct
  include Lane_addon_runtime
  let dispatch ?caller ?access ~config ~operation args =
    let access = Option.value ~default:(match caller with
      | None -> Lane_addon_sources.Operator_configuration
      | Some keeper -> Lane_addon_sources.Keeper keeper) access in
    Lane_addon_runtime.dispatch ?caller ~access ~config ~operation args
    |> Result.map_error Lane_addon_runtime.error_to_string
end
module Types = Lane_addon_types
module Store = Lane_addon_store
let ( let* ) = Result.bind

let unwrap = function Ok value -> value | Error message -> fail message
let member = Yojson.Safe.Util.member
let text key value = member key value |> Yojson.Safe.Util.to_string
let number key value = member key value |> Yojson.Safe.Util.to_int
let values key value = member key value |> Yojson.Safe.Util.to_list
let write path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
  | _ -> Sys.remove path

(* The resolver trims empty environment values, as its own feature tests do.
   The override exists only for this owned temporary configuration directory. *)
let with_environment name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f

type worker_event = Started of string | Startup_failed of string
  | Stop_requested of string | Stopped of string
  | Recovery_requested of string * string option
  | Recovery_completed of string * string option

module Fake = Lane_addon_fake_engine
module Lifecycle = Lane_addon_lifecycle

type fake = {
  events : worker_event list ref;
  state_owners : (string, string option) Hashtbl.t;
  recovered_state_owners : (string, string option) Hashtbl.t;
  recovered_runtimes : (string, Types.runtime) Hashtbl.t;
  observations : (string * Yojson.Safe.t) list ref;
  recovery_barrier : unit Eio.Promise.t option ref;
  startup_available : bool ref;
  startup_barrier : unit Eio.Promise.t option ref;
  cleanup_available : bool ref;
  image_available : bool ref;
  create_refusal : string option ref;
  world : Fake.t;
  home : Fake.engine;
  condition_checks : int ref;
  sweeps : int ref;
  swept : Lane_addon_slot.sweep_item list ref;
  liveness : (string -> bool) option ref;
}

let output : Types.output = {
  rows = [{ id = "observed-row"; lane_id = "fixture/observations"; kind = Types.Event;
    title = "Package observation"; observed_at = 1.; subject_id = "fixture-target";
    clock = None; actor = None; fields = []; evidence = []; related_ids = [] }];
  coverage = [{ source_id = "fixture"; incarnation = "fixture-incarnation";
    cursor = Some "1"; complete = true; detail = None }];
}

let container_name instance_id = "masc-lane-" ^ Store.digest instance_id

(* The engine the fixture starts on. Tests point the world at another engine,
   or switch an engine off, the way an operator's Docker context changes. *)
let make_backend () =
  let home = Fake.docker "engine-a" in
  let state = { events = ref []; state_owners=Hashtbl.create 4; recovered_state_owners=Hashtbl.create 4; recovered_runtimes=Hashtbl.create 4; observations = ref []; recovery_barrier = ref None;
                startup_available = ref true; startup_barrier = ref None; cleanup_available = ref true;
                image_available = ref true; create_refusal = ref None;
                world = Fake.create home; home; condition_checks = ref 0; sweeps = ref 0; swept = ref []; liveness = ref None } in
  let record event = state.events := event :: !(state.events) in
  let proven ~engine work =
    Lane_addon_slot.proven (Fake.port state.world) ~expected:engine ~lift:Fun.id work in
  let backend : Runtime.For_testing.backend = {
    start = (fun ~sw:_ ~state_owner ~instance_id ~installation_id:_ ~(package : Types.package) ~binding:_ ~on_authority ~is_live_instance ~on_created ->
      let* container = Types.container package
        |> Result.map_error (fun detail -> Lifecycle.Worker_failed detail) in
      Hashtbl.replace state.state_owners instance_id
        (Option.map (Lane_addon_worker_state.volume_name ~runtime:container.runtime) state_owner);
      let stopped, release_stop = Eio.Promise.create () in
      let stop_sent = ref false in
      let container_id = Store.digest instance_id in
      match (Fake.port state.world).read_engine () with
      | Error (Lifecycle.Unreachable detail) ->
          record (Startup_failed instance_id);
          Error (Lifecycle.Engine_unreachable detail)
      | Error (Lifecycle.Identity_unreadable detail) ->
          record (Startup_failed instance_id);
          Error (Lifecycle.Worker_failed detail)
      | Ok engine ->
      let connection : Runtime.For_testing.connection = {browser=None;host=None;
        resource = Lifecycle.Container_resource container_id;
        exported_tools = (fun () -> []);
        call_exported_tool = (fun ~on_result:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ -> Error (Lane_addon_call_context.Transport_error "no exported tools"));
        action_schema = (fun () -> None);
        act = (fun ~arguments:_ -> Error "read-only fixture");
        observe = (fun ~binding ~sources:_ ->
          state.observations := (instance_id, binding) :: !(state.observations);
          match package.id with
          | "held" -> Eio.Promise.await stopped; Error "owned observer stopped"
          | _ -> Ok output);
        stop = (fun () ->
          record (Stop_requested instance_id);
          if not !(state.cleanup_available) then Error (Lifecycle.Cleanup_unconfirmed "cleanup dependency unavailable")
          else
            let removed = proven ~engine (fun () ->
              Fake.remove state.world container_id;
              if Fake.exists state.world container_id
              then Error (Lifecycle.Cleanup_unconfirmed "container remains visible")
              else Ok ()) in
            Result.map (fun () ->
              if not !stop_sent then begin
                stop_sent := true;
                record (Stopped instance_id);
                Eio.Promise.resolve release_stop ()
              end;
              Lifecycle.Released {engine;container_id=Some container_id}) removed);
      } in
      if not !(state.startup_available) then begin
        record (Startup_failed instance_id);
        Error (Lifecycle.Worker_failed "worker dependency unavailable")
      end else begin
        match on_authority (Lifecycle.Container_authority {runtime=container.runtime;engine}) with
        | Error detail -> Error (Lifecycle.Persistence_failed detail)
        | Ok () when !(state.create_refusal) <> None ->
            (* The engine is on record; the create itself is refused. *)
            record (Startup_failed instance_id);
            Error (Lifecycle.Worker_failed (Option.value ~default:"" !(state.create_refusal)))
        | Ok () ->
            let name, mine = match state_owner with
              | Some owner ->
                  Lane_addon_worker_state.container_name ~runtime:container.runtime owner,
                  Some (Lane_addon_worker_state.identity owner)
              | None -> container_name instance_id, None in
            (match Lane_addon_slot.claim (Fake.port state.world) ~name ~instance_id ~mine ~is_live_instance with
             | Error failure -> record (Startup_failed instance_id); Error failure
             | Ok () ->
                 match Fake.add (Fake.current state.world) ~id:container_id ~name
                         ~labels:(["masc.lane.instance", instance_id; Lane_addon_engine.scope_label, Fake.scope_of_world]
                                  @ Option.fold ~none:[] ~some:(fun owner -> ["masc.lane.state.owner", owner]) mine) () with
                 | Error detail -> record (Startup_failed instance_id); Error (Lifecycle.Worker_failed detail)
                 | Ok _ ->
                     record (Started instance_id);
                     on_created connection;
                     Option.iter Eio.Promise.await !(state.startup_barrier);
                     Ok connection)
      end);
    acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
    package_ready = (fun ~package:_ ->
      if !(state.image_available) then Ok () else Error "image is not on the host");
    recover_stop = (fun ~state_owner ~instance_id ~authority ~resource ->
      match authority,resource with
      | Lifecycle.Native_admission _,_ | Lifecycle.Container_authority _,Some (Lifecycle.Native_resource _) ->
          Error (Lifecycle.Cleanup_unconfirmed "container fixture requires container authority")
      | Lifecycle.Container_authority {runtime;engine},(None | Some (Lifecycle.Container_resource _)) ->
      let container_id = Option.bind resource Lifecycle.container_id in
      Hashtbl.replace state.recovered_runtimes instance_id runtime;
      Hashtbl.replace state.recovered_state_owners instance_id
        (Option.map (Lane_addon_worker_state.volume_name ~runtime) state_owner);
      if Option.exists (fun id -> id <> Store.digest instance_id) container_id
      then Error (Lifecycle.Cleanup_unconfirmed "persisted container does not belong to instance")
      else begin
        record (Recovery_requested (instance_id, container_id));
        if not !(state.cleanup_available) then Error (Lifecycle.Cleanup_unconfirmed "historical cleanup dependency unavailable")
        else begin
          Option.iter Eio.Promise.await !(state.recovery_barrier);
          let lookup, mine = match container_id, state_owner with
            | Some id, _ -> Lane_addon_engine.Id id, Option.map Lane_addon_worker_state.identity state_owner
            | None, Some owner ->
                Lane_addon_engine.Name (Lane_addon_worker_state.container_name ~runtime owner),
                Some (Lane_addon_worker_state.identity owner)
            | None, None -> Lane_addon_engine.Name (container_name instance_id), None in
          let removed = proven ~engine (fun () ->
            Lane_addon_slot.release (Fake.port state.world) ~lookup ~instance_id ~mine) in
          Result.map (fun () -> record (Recovery_completed (instance_id, container_id));
            Lifecycle.Released {engine;container_id}) removed
        end
      end);
    condition_met = (fun ~runtime:_ condition ->
      incr state.condition_checks;
      Fake.condition_met state.world condition);
    sweep = (fun ~runtime ~is_live_instance ->
      incr state.sweeps;
      state.liveness := Some is_live_instance;
      let result = Lane_addon_slot.sweep (Fake.port state.world) ~runtime ~is_live_instance in
      Result.iter (fun items -> state.swept := !(state.swept) @ items) result;
      result);
  } in
  state, backend

let package ?(runtime = Types.Docker) directory id =
  let path = Filename.concat directory (id ^ "-package.toml") in
  write path (Printf.sprintf {|id = %S
%s
revision = "fixture-1"
title = "Declared observer"
image = "fixture/observer"
command = ["observer"]
contributions = ["observe"]
[resources]
cpus = %s
memory_bytes = 67108864
%s
max_reply_bytes = 4096
|} id (match runtime with Types.Docker -> "" | Apple_container -> "runtime = \"apple_container\"")
    (match runtime with Types.Docker -> "0.5" | Apple_container -> "1")
    (match runtime with Types.Docker -> "pids = 16" | Apple_container -> ""));
  path

let declaration ?enabled ?(setting = "initial") ~id ~manifest () =
  (Option.fold ~none:"" ~some:(fun value -> Printf.sprintf "enabled = %b\n" value) enabled) ^
  Printf.sprintf {|id = %S
run_id = "declared-world"
manifest_path = %S
[binding]
sources = []
setting = %S
|} id manifest setting

let dispatch config operation fields =
  Runtime.dispatch ~config ~operation (`Assoc fields) |> unwrap
let inspect config = dispatch config Runtime.Inspect []
let instances config = inspect config |> values "instances"
let instance config id =
  instances config |> List.find (fun value -> text "instance_id" value = id)
let phase value = value |> member "phase" |> text "kind"
let active config = instances config |> List.filter (fun value -> phase value <> "detached")
let configuration_id value = value |> member "configuration" |> text "id"
let declared_instance config id =
  active config |> List.find (fun value -> match member "configuration" value with
    | `Null -> false
    | owner -> text "id" owner = id)
let starts state = List.filter_map (function Started id -> Some id | _ -> None) !(state.events)
let stops state = List.filter_map (function Stopped id -> Some id | _ -> None) !(state.events)
let reconcile config directory = unwrap (Runtime.reconcile_configuration ~config ~directory)
let application config id =
  let declaration = inspect config |> member "configuration" |> values "declarations"
    |> List.find (fun item -> text "id" item = id) in
  member "application" declaration
let check_application config id expected =
  (* `Unknown` has three causes in the product -- an incomplete inventory, two
     workers claiming the same declaration, and no operator access at all --
     and they are told apart only by `application.messages`. Alcotest prints
     Expected/Received and drops the rest, so a failure used to say `"unknown"`
     and nothing about which one fired. *)
  let observed = application config id in
  let actual = text "kind" observed in
  if actual <> expected then
    failf "observed declaration application: expected %S, got %S (application: %s)"
      expected actual (Yojson.Safe.to_string observed)
let lifecycle value = member "lifecycle" value
let failed_record value = lifecycle value |> member "failed"
let attempts state =
  List.length (List.filter (function Started _ | Startup_failed _ -> true | _ -> false) !(state.events))
let recovery_requests state =
  List.length (List.filter (function Recovery_requested _ -> true | _ -> false) !(state.events))

let await clock predicate =
  let rec loop () =
    if predicate () then () else (Eio.Time.sleep clock 0.001; loop ())
  in loop ()
let await_ready clock config id =
  await clock (fun () -> number "observation_seq" (instance config id) > 0)
let await_detached clock config id =
  await clock (fun () -> phase (instance config id) = "detached");
  (* Detached history remains in Inspect, while active rows are released only
     after both the worker and cleanup fibers have finished. *)
  await clock (fun () ->
    inspect config |> values "rows"
    |> List.for_all (fun row -> text "lane_id" row <> id ^ "/fixture/observations"))
let detach clock config id =
  ignore (dispatch config Runtime.Detach ["instance_id", `String id]);
  await_detached clock config id

let with_fixture f =
  let root = Filename.temp_dir "lane-reconcile-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let masc = Filename.concat root ".masc" in
    Unix.mkdir masc 0o700;
    let config_root = Filename.concat masc "config" in
    Unix.mkdir config_root 0o700;
    let directory = Filename.concat config_root "lane-addons" in
    Unix.mkdir directory 0o700;
    let packages = Filename.concat root "packages" in
    Unix.mkdir packages 0o700;
    with_environment "MASC_CONFIG_DIR" config_root (fun () ->
      with_environment "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
            Eio.Switch.run (fun sw ->
              Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
                ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                  Runtime.For_testing.reset ();
                  let config = Workspace.default_config root in
                  check string "public Detach resolves the owned declaration directory"
                    directory (Runtime.configuration_directory config);
                  let state, backend = make_backend () in
                  Runtime.For_testing.with_backend backend (fun () ->
                    f env sw config directory packages state))))))))

let test_install_idempotence_rename_and_public_detach () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    let applied = reconcile config directory in
    check (list string) "one declarative installation discovered" ["observer"]
      (values "declarations" applied |> List.map (text "id"));
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    check string "actual parsed binding reaches the worker" "initial"
      (List.assoc id !(state.observations) |> text "setting");
    check int "installed package contributes a row" 1 (List.length (inspect config |> values "rows"));
    ignore (reconcile config directory);
    ignore (reconcile config directory);
    write path ("# Presentation edit must not restart the observer.\n" ^ bytes);
    ignore (reconcile config directory);
    let renamed = Filename.concat directory "renamed.toml" in
    Sys.rename path renamed;
    ignore (reconcile config directory);
    check (list string) "same declaration starts one worker" [id] (starts state);
    check string "rename preserves the active instance" id
      (declared_instance config "observer" |> text "instance_id");
    check string "renamed declaration is tracked for explicit removal" renamed
      (instance config id |> member "configuration" |> text "source_path");
    detach clock config id;
    check bool "public Detach removes the current declaration file" false (Sys.file_exists renamed);
    ignore (reconcile config directory);
    check int "removed declaration is not silently reattached" 1 (List.length (starts state));
    check (list string) "owned worker stopped exactly once" [id] (stops state))

let test_changed_binding_retires_before_replacement () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let manifest_bytes = In_channel.with_open_bin manifest In_channel.input_all in
    write manifest (manifest_bytes ^ {|
[world.state]
mode = "persistent"
|});
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    let old_row = inspect config |> values "rows" |> List.hd |> text "id" in
    write path (declaration ~id:"observer" ~manifest ~setting:"changed" ());
    ignore (reconcile config directory);
    check int "retirement reconciliation does not create a second worker" 1 (List.length (starts state));
    await_detached clock config old_id;
    check (list string) "old owner stopped before next reconciliation" [old_id] (stops state);
    check bool "changed declaration remains desired" true (Sys.file_exists path);
    ignore (reconcile config directory);
    let new_id = declared_instance config "observer" |> text "instance_id" in
    check bool "changed semantics create a new execution identity" true (old_id <> new_id);
    await_ready clock config new_id;
    let original_state = Hashtbl.find state.state_owners old_id in
    check bool "persistent installation has a state owner" true (Option.is_some original_state);
    check (option string) "new incarnation retains the logical installation state"
      original_state (Hashtbl.find state.state_owners new_id);
    check string "replacement receives changed binding" "changed"
      (List.assoc new_id !(state.observations) |> text "setting");
    check int "only one current owner" 1 (List.length (active config));
    check bool "old evidence survives replacement" true
      (dispatch config Runtime.Slice [] |> values "rows"
       |> List.exists (fun row -> text "id" row = old_row));
    detach clock config new_id)

let test_persistent_runtime_switch_requires_new_installation () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let original = In_channel.with_open_bin manifest In_channel.input_all in
    write manifest (original ^ "\n[world.state]\nmode = \"persistent\"\n");
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    write manifest {|id = "ready"
revision = "fixture-2"
title = "Declared observer"
runtime = "apple_container"
image = "fixture/observer"
command = ["observer"]
contributions = ["observe"]
[world.state]
mode = "persistent"
[resources]
cpus = 1
memory_bytes = 67108864
max_reply_bytes = 4096
|};
    let refused = reconcile config directory in
    check bool "runtime switch is visible as configuration issue" true
      (values "issues" refused <> []);
    check (list string) "old owner remains running" [old_id] (starts state);
    check (list string) "refused migration does not stop old owner" [] (stops state);
    let fresh = Filename.concat directory "fresh.toml" in
    write fresh (declaration ~id:"fresh" ~manifest ());
    ignore (reconcile config directory);
    let fresh_id = declared_instance config "fresh" |> text "instance_id" in
    await_ready clock config fresh_id;
    check bool "new installation owns a different state volume" true
      (Hashtbl.find state.state_owners old_id <> Hashtbl.find state.state_owners fresh_id);
    (* The changed declaration cannot be deleted through its stale live handle.
       Remove desired state and reconcile before testing retained history. *)
    Sys.remove path;
    ignore (reconcile config directory);
    await_detached clock config old_id;
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    check int "detached history still protects the original state" 2 (List.length (starts state));
    Sys.remove path;
    detach clock config fresh_id)

let test_invalid_inventory_preserves_existing_activity () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    write path "id = [\n";
    let malformed = reconcile config directory in
    check bool "malformed declaration is visible" true (values "issues" malformed <> []);
    check string "parse failure preserves the previous owner" id
      (declared_instance config "observer" |> text "instance_id");
    write path bytes;
    let duplicate = Filename.concat directory "duplicate.toml" in
    write duplicate bytes;
    let ambiguous = reconcile config directory in
    check int "duplicate identities select neither declaration" 0
      (List.length (values "declarations" ambiguous));
    check bool "duplicate identity is visible" true (values "issues" ambiguous <> []);
    check int "invalid inventory creates no additional workers" 1 (List.length (starts state));
    check int "invalid inventory does not retire the existing worker" 0 (List.length (stops state));
    ignore (dispatch config Runtime.Observe ["instance_id", `String id]);
    await clock (fun () -> number "observation_seq" (instance config id) >= 2);
    Sys.remove duplicate;
    ignore (reconcile config directory);
    check string "repair reuses the prior owner" id
      (declared_instance config "observer" |> text "instance_id");
    detach clock config id)

let test_deleted_declaration_retains_history () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let row = inspect config |> values "rows" |> List.hd |> text "id" in
    Sys.remove path;
    ignore (reconcile config directory);
    await_detached clock config id;
    check (list string) "deleting a declaration stops its worker" [id] (stops state);
    let retained = dispatch config Runtime.Slice ["run_id", `String "declared-world"] in
    check bool "deleting configuration preserves retained observations" true
      (values "rows" retained |> List.exists (fun value -> text "id" value = row));
    ignore (reconcile config directory);
    check int "absence does not create a replacement" 1 (List.length (starts state)))

let test_duplicate_toml_keys_preserve_applied_workers () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let original_manifest = In_channel.with_open_bin manifest In_channel.input_all in
    let path = Filename.concat directory "observer.toml" in
    let original_declaration = declaration ~id:"observer" ~manifest () in
    write path original_declaration;
    let independent_manifest = package packages "independent" in
    write (Filename.concat directory "independent.toml")
      (declaration ~id:"independent" ~manifest:independent_manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    let independent = declared_instance config "independent" |> text "instance_id" in
    await_ready clock config id;
    await_ready clock config independent;
    let original_binding = instance config id |> member "binding" in
    let original_revision = instance config id |> member "configuration" |> text "revision" in
    let duplicate_port = "\n[world.outputs]\nframes={all_lanes=true}\nframes={all_lanes=true}\n" in
    List.iter (fun (label, corrupt, expected_id) ->
      write manifest original_manifest;
      write path original_declaration;
      corrupt ();
      let report = reconcile config directory in
      check bool (label ^ ": directory membership remains authoritative") true
        (member "complete" report = `Bool true);
      let issue = values "issues" report |> List.find (fun issue -> text "source_path" issue = path) in
      check bool (label ^ ": issue retains only a successfully parsed identity") true
        (member "id" issue = expected_id);
      check bool (label ^ ": parser diagnostic remains visible") true
        (String.trim (text "message" issue) <> "");
      check string (label ^ ": previous worker keeps ownership") id
        (declared_instance config "observer" |> text "instance_id");
      check string (label ^ ": applied revision is not replaced by malformed input") original_revision
        (instance config id |> member "configuration" |> text "revision");
      check bool (label ^ ": applied binding remains unchanged") true
        ((instance config id |> member "binding") = original_binding);
      check int (label ^ ": invalid input starts no replacement") 2 (List.length (starts state));
      check int (label ^ ": invalid input stops no worker") 0 (List.length (stops state));
      List.iter (fun instance_id ->
        let seq = number "observation_seq" (instance config instance_id) in
        ignore (dispatch config Runtime.Observe ["instance_id", `String instance_id]);
        await clock (fun () -> number "observation_seq" (instance config instance_id) > seq)) [id; independent])
      ["duplicate manifest port", (fun () -> write manifest (original_manifest ^ duplicate_port)), `String "observer";
       "duplicate declaration key", (fun () -> write path ("id=\"ambiguous\"\n" ^ original_declaration)), `Null];
    write manifest original_manifest;
    write path original_declaration;
    check int "repair clears the parser issues" 0 (values "issues" (reconcile config directory) |> List.length);
    check string "repair reuses the original applied owner" id
      (declared_instance config "observer" |> text "instance_id");
    detach clock config id;
    detach clock config independent)

let test_restart_recovers_exact_owner_before_replacement ?(runtime = Types.Docker) () =
  with_fixture (fun env sw config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package ~runtime packages "ready" in
    let manifest_bytes = In_channel.with_open_bin manifest In_channel.input_all in
    write manifest (manifest_bytes ^ {|
[world.state]
mode = "persistent"
|});
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    let captured = instance config old_id in
    let container_id = member "resource" captured |> text "id" in
    (match runtime with
     | Types.Docker -> check bool "current Docker writer omits its default runtime" false
         (List.mem_assoc "runtime" (member "package" captured |> Yojson.Safe.Util.to_assoc))
     | Types.Apple_container -> ());
    check string "runtime snapshot marks actual entry live" "live" (text "runtime_presence" captured);
    detach clock config old_id;
    (* All live fake work is stopped before replaying the captured persistent
       binding. Reset alone is never used to abandon an active worker. *)
    Runtime.For_testing.reset ();
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id captured);
    check string "restart overrides persisted live provenance" "retained"
      (text "runtime_presence" (instance config old_id));
    write path bytes;
    let recovered, release_recovery = Eio.Promise.create () in
    state.recovery_barrier := Some recovered;
    ignore (reconcile config directory);
    await clock (fun () -> List.mem (Recovery_requested (old_id, Some container_id)) !(state.events));
    ignore (reconcile config directory);
    check int "pending recovery does not start a replacement" 1 (List.length (starts state));
    check int "repeated reconciliation does not duplicate exact recovery" 1
      (List.length (List.filter (function Recovery_requested _ -> true | _ -> false) !(state.events)));
    let primary = Eio.Fiber.fork_promise ~sw (fun () -> "ordinary work continues") in
    check string "recovery does not block ordinary work" "ordinary work continues"
      (Eio.Promise.await_exn primary);
    Eio.Promise.resolve release_recovery ();
    await_detached clock config old_id;
    check bool "the persisted exact container was recovered" true
      (List.mem (Recovery_completed (old_id, Some container_id)) !(state.events));
    ignore (reconcile config directory);
    let replacement = declared_instance config "observer" |> text "instance_id" in
    check bool "restart uses a fresh instance after cleanup" true (replacement <> old_id);
    await_ready clock config replacement;
    let original_state = Hashtbl.find state.state_owners old_id in
    check bool "persistent installation has a state owner" true (Option.is_some original_state);
    check (option string) "new incarnation retains the logical installation state"
      original_state (Hashtbl.find state.state_owners replacement);
    check (option string) "historical cleanup restores the original state owner"
      original_state (Hashtbl.find state.recovered_state_owners old_id);
    check bool "historical cleanup uses its retained runtime" true
      (Hashtbl.find state.recovered_runtimes old_id = runtime);
    let relevant = List.rev !(state.events) |> List.filter (function
      | Recovery_completed _ -> true | Started id -> id = replacement | _ -> false) in
    check bool "recovery confirmation precedes replacement acquisition" true
      (relevant = [Recovery_completed (old_id, Some container_id); Started replacement]);
    detach clock config replacement)

let test_held_observer_does_not_block_other_declarations () =
  with_fixture (fun env sw config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let held_manifest = package packages "held" in
    let held_path = Filename.concat directory "held.toml" in
    write held_path (declaration ~id:"held" ~manifest:held_manifest ());
    ignore (reconcile config directory);
    let held_id = declared_instance config "held" |> text "instance_id" in
    await clock (fun () -> List.mem_assoc held_id !(state.observations));
    let ready_manifest = package packages "ready" in
    let ready_path = Filename.concat directory "ready.toml" in
    write ready_path (declaration ~id:"ready" ~manifest:ready_manifest ());
    let primary = Eio.Fiber.fork_promise ~sw (fun () -> "primary action completed") in
    ignore (reconcile config directory);
    let ready_id = declared_instance config "ready" |> text "instance_id" in
    await_ready clock config ready_id;
    check string "primary work completes before blocked observation is released"
      "primary action completed" (Eio.Promise.await_exn primary);
    check int "held observer remains unreleased" 0 (List.length (stops state));
    check int "held observation has no fabricated result" 0 (number "observation_seq" (instance config held_id));
    ignore (dispatch config Runtime.Observe ["instance_id", `String ready_id]);
    await clock (fun () -> number "observation_seq" (instance config ready_id) >= 2);
    Sys.remove held_path;
    ignore (reconcile config directory);
    await_detached clock config held_id;
    check string "removal preserves another declaration's owner" ready_id
      (declared_instance config "ready" |> text "instance_id");
    ignore (dispatch config Runtime.Observe ["instance_id", `String ready_id]);
    await clock (fun () -> number "observation_seq" (instance config ready_id) >= 3);
    detach clock config ready_id)

let test_detach_preserves_newer_or_malformed_declaration () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let original = declaration ~id:"observer" ~manifest () in
    write path original;
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let changed = declaration ~id:"observer" ~manifest ~setting:"new editor save" () in
    write path changed;
    let attempt () = Runtime.dispatch ~config ~operation:Runtime.Detach
      (`Assoc ["instance_id", `String id]) in
    check bool "stale applied revision cannot delete a newer declaration" true
      (Result.is_error (attempt ()));
    check string "newer desired bytes survive rejected Detach" changed
      (In_channel.with_open_bin path In_channel.input_all);
    let malformed = "id = [\n" in
    write path malformed;
    check bool "unreadable desired identity is not unlinked speculatively" true
      (Result.is_error (attempt ()));
    check string "malformed declaration remains available for repair" malformed
      (In_channel.with_open_bin path In_channel.input_all);
    check int "uncertain removal does not stop the active worker" 0 (List.length (stops state));
    ignore (dispatch config Runtime.Observe ["instance_id", `String id]);
    await clock (fun () -> number "observation_seq" (instance config id) >= 2);
    write path original;
    detach clock config id;
    check bool "matching corrected declaration can be removed" false (Sys.file_exists path))

(* Reuse Eio's manual clock; the wrapper only reports when Pulse schedules its
   next wait. Advancing this clock never sleeps for the maintenance interval. *)
let service_clock () =
  let manual = Eio_mock.Clock.make () in
  let sleeps = Eio.Stream.create max_int in
  let module Clock = struct
    type t = Eio_mock.Clock.t * float Eio.Stream.t
    type time = float
    let now (clock, _) = Eio.Time.now clock
    let sleep_until (clock, scheduled) deadline =
      Eio.Stream.add scheduled deadline;
      Eio.Time.sleep_until clock deadline
  end in
  let clock = Eio.Resource.T ((manual, sleeps), Eio.Time.Pi.clock (module Clock)) in
  clock, manual, sleeps

let await_yield predicate =
  let rec loop () = if predicate () then () else (Eio.Fiber.yield (); loop ()) in
  loop ()

let failures state =
  List.filter_map (function Startup_failed id -> Some id | _ -> None) !(state.events)
let stop_requests state =
  List.filter_map (function Stop_requested id -> Some id | _ -> None) !(state.events)

let test_startup_dependency_recovers_without_editing_toml () =
  with_fixture (fun env sw config directory packages state ->
    let real_clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    state.startup_available := false;
    let clock, manual, sleeps = service_clock () in
    Runtime.start_configuration_service ~config ~sw ~clock;
    await_yield (fun () -> failures state <> []);
    let failed_id = List.hd (failures state) in
    await_yield (fun () -> phase (instance config failed_id) = "failed");
    let scheduled = Eio.Stream.take sleeps in
    check bool "startup failure leaves a future maintenance wait" true
      (scheduled > Eio.Time.now clock);
    ignore (inspect config);
    check int "dependency failure does not immediately restart itself" 1 (List.length (failures state));
    check int "unavailable dependency produced no running worker" 0 (List.length (starts state));
    state.startup_available := true;
    Eio_mock.Clock.set_time manual scheduled;
    (* Recovery can finish ownership cleanup before the next installation.
       Step scheduled maintenance only if cleanup does not nudge replacement. *)
    let rec advance_until_started () =
      if starts state <> [] then ()
      else begin
        let next = Eio.Stream.take sleeps in
        ignore (inspect config);
        if starts state = [] then Eio_mock.Clock.set_time manual next;
        advance_until_started ()
      end
    in
    advance_until_started ();
    check bool "a startup that never created a container leaves no retained record" false
      (instances config |> List.exists (fun value -> text "instance_id" value = failed_id));
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready real_clock config id;
    check string "recovered worker receives the original binding" "initial"
      (List.assoc id !(state.observations) |> text "setting");
    check string "dependency recovery requires no TOML rewrite" bytes
      (In_channel.with_open_bin path In_channel.input_all);
    check int "successful recovery starts exactly one worker" 1 (List.length (starts state));
    detach real_clock config id)

let test_historical_missing_container_identity_is_recovered () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    let captured = instance config old_id in
    let row = inspect config |> values "rows" |> List.hd |> text "id" in
    detach clock config old_id;
    Runtime.For_testing.reset ();
    let fields = Yojson.Safe.Util.to_assoc captured in
    let without_id = `Assoc (("resource", `Null) :: List.remove_assoc "resource" fields) in
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id without_id);
    write path bytes;
    let recovered, release = Eio.Promise.create () in
    state.recovery_barrier := Some recovered;
    ignore (reconcile config directory);
    await_yield (fun () -> List.mem (Recovery_requested (old_id, None)) !(state.events));
    check int "missing CID waits for ownership recovery before replacement" 1 (List.length (starts state));
    Eio.Promise.resolve release ();
    await_detached clock config old_id;
    check bool "worker backend verified the missing-CID recovery" true
      (List.mem (Recovery_completed (old_id, None)) !(state.events));
    ignore (reconcile config directory);
    let new_id = declared_instance config "observer" |> text "instance_id" in
    check bool "confirmed missing-CID cleanup permits fresh execution" true (new_id <> old_id);
    await_ready clock config new_id;
    check bool "ownership recovery preserves retained observation history" true
      (dispatch config Runtime.Slice [] |> values "rows"
       |> List.exists (fun value -> text "id" value = row));
    detach clock config new_id)

(* A binding a previous process left for a worker that never started -- no
   observation, no container -- is recovered like any other, and once it is
   detached it leaves no file: the rule [persist] applies to a live worker
   holds on the restart path too. *)
let test_historical_never_started_leaves_no_binding () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    state.startup_available := false;
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await clock (fun () -> phase (instance config old_id) = "failed");
    let never_started = instance config old_id in
    check int "failed startup has no observation history" 0
      (number "observation_seq" never_started);
    check bool "failed startup owns no container" true
      (member "resource" never_started = `Null);
    check int "the backend never observed" 0 (List.length !(state.observations));
    ignore (dispatch config Runtime.Detach ["instance_id", `String old_id]);
    await clock (fun () ->
      not (List.exists (fun value -> text "instance_id" value = old_id) (instances config)));
    Runtime.For_testing.reset ();
    state.events := [];
    state.startup_available := true;
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id never_started);
    let has_binding () =
      unwrap (Store.bindings store)
      |> List.exists (function
        | `Assoc binding -> List.assoc_opt "instance_id" binding = Some (`String old_id)
        | _ -> false)
    in
    write path bytes;
    ignore (reconcile config directory);
    await_yield (fun () -> not (has_binding ()));
    check bool "a never-started binding is gone after restart recovery" false (has_binding ());
    check int "a record that names no engine never issued a create, so no engine is asked" 0
      (recovery_requests state);
    (* Recovery nudges configuration, but this test runs no configuration
       service, so the declaration attaches again only on the next reconcile. *)
    ignore (reconcile config directory);
    let new_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config new_id;
    detach clock config new_id)

let test_cleanup_failure_retries_on_maintenance_without_hotloop () =
  with_fixture (fun env sw config directory packages state ->
    let real_clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    let clock, manual, sleeps = service_clock () in
    Runtime.start_configuration_service ~config ~sw ~clock;
    await_yield (fun () -> starts state <> []);
    let old_id = List.hd (starts state) in
    await_ready real_clock config old_id;
    let change_beat = Eio.Stream.take sleeps in
    write path (declaration ~id:"observer" ~manifest ~setting:"changed" ());
    state.cleanup_available := false;
    Eio_mock.Clock.set_time manual change_beat;
    await_yield (fun () -> stop_requests state <> []);
    await_yield (fun () -> phase (instance config old_id) = "failed");
    let retry_beat = Eio.Stream.take sleeps in
    check bool "failed cleanup keeps the next retry in the future" true
      (retry_beat > Eio.Time.now clock);
    ignore (inspect config);
    check int "cleanup failure does not nudge an immediate retry loop" 1 (List.length (stop_requests state));
    check int "cleanup failure preserves the previous ownership boundary" 1 (List.length (starts state));
    let primary = Eio.Fiber.fork_promise ~sw (fun () -> "primary work is available") in
    check string "pending cleanup preserves primary progress" "primary work is available"
      (Eio.Promise.await_exn primary);
    state.cleanup_available := true;
    Eio_mock.Clock.set_time manual retry_beat;
    await_yield (fun () -> List.mem (Stopped old_id) !(state.events));
    await_detached real_clock config old_id;
    (* Successful cleanup may nudge replacement immediately; otherwise the
       next scheduled maintenance beat can apply the unchanged desired file. *)
    let rec advance_until_replaced () =
      if List.length (starts state) = 2 then ()
      else begin
        let next = Eio.Stream.take sleeps in
        ignore (inspect config);
        if List.length (starts state) < 2 then Eio_mock.Clock.set_time manual next;
        advance_until_replaced ()
      end
    in
    advance_until_replaced ();
    let id = declared_instance config "observer" |> text "instance_id" in
    check bool "replacement starts after cleanup becomes available" true (id <> old_id);
    await_ready real_clock config id;
    check string "replacement applies the pending configuration" "changed"
      (List.assoc id !(state.observations) |> text "setting");
    check int "one failed cleanup and one successful retry" 2 (List.length (stop_requests state));
    detach real_clock config id)

let test_historical_recovery_failure_waits_for_maintenance () =
  with_fixture (fun env sw config directory packages state ->
    let real_clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready real_clock config old_id;
    let captured = instance config old_id in
    let cid = Some (member "resource" captured |> text "id") in
    detach real_clock config old_id;
    Runtime.For_testing.reset ();
    (* Replay only after the live fake has actually stopped. The service must
       now use historical_detach/recover_stop, never the live connection. *)
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id captured);
    write path bytes;
    state.cleanup_available := false;
    let requests () = List.filter (function
      | Recovery_requested (id, container_id) -> id = old_id && container_id = cid
      | _ -> false) !(state.events) |> List.length in
    let clock, manual, sleeps = service_clock () in
    Runtime.start_configuration_service ~config ~sw ~clock;
    await_yield (fun () -> requests () >= 1);
    await_yield (fun () -> phase (instance config old_id) = "failed");
    let first_retry = Eio.Stream.take sleeps in
    ignore (inspect config);
    check int "historical failure does not nudge itself at startup" 1 (requests ());
    check_application config "observer" "failed";
    check bool "historical retry waits for a future beat" true
      (first_retry > Eio.Time.now clock);
    Eio_mock.Clock.set_time manual first_retry;
    await_yield (fun () -> requests () >= 2);
    await_yield (fun () -> phase (instance config old_id) = "failed");
    let second_retry = Eio.Stream.take sleeps in
    ignore (inspect config);
    check int "persisted cleanup failure retries once on the virtual beat" 2 (requests ());
    check bool "a second failure schedules another future beat" true
      (second_retry > Eio.Time.now clock);
    check int "unverified historical ownership prevents replacement" 1 (List.length (starts state));
    state.cleanup_available := true;
    Eio_mock.Clock.set_time manual second_retry;
    await_yield (fun () -> List.mem (Recovery_completed (old_id, cid)) !(state.events));
    await_yield (fun () -> List.length (starts state) = 2);
    check int "cleanup was attempted only at startup and two virtual beats" 3 (requests ());
    let id = declared_instance config "observer" |> text "instance_id" in
    check bool "confirmed historical cleanup permits a fresh owner" true (id <> old_id);
    await_ready real_clock config id;
    check string "recovery preserves unchanged desired TOML" bytes
      (In_channel.with_open_bin path In_channel.input_all);
    detach real_clock config id)

(* An image that is not on the host is looked for before any worker exists.
   Each beat reports it on the declaration and creates nothing: no instance,
   no startup failure, no binding (#37897). The same declaration attaches on
   the first beat after the image appears, without a TOML rewrite. *)
let test_missing_image_creates_nothing_until_it_is_built () =
  with_fixture (fun env _sw config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    state.image_available := false;
    let reports = List.init 3 (fun _ -> reconcile config directory) in
    check int "a missing image starts no worker" 0 (List.length (starts state));
    check int "a missing image records no startup failure" 0 (List.length (failures state));
    check int "a missing image leaves no instance behind" 0 (List.length (instances config));
    List.iter (fun report ->
      check bool "every beat reports the missing image" true (values "issues" report <> []))
      reports;
    state.image_available := true;
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    check int "the built image attaches on the next beat" 1 (List.length (starts state));
    check string "attaching needed no TOML rewrite" bytes
      (In_channel.with_open_bin path In_channel.input_all);
    detach clock config id)

let test_inventory_reads_live_manual_without_effects () =
  with_fixture (fun env _sw config _directory packages state ->
    let manifest = package packages "ready" in
    let attached = dispatch config Runtime.Attach ["manifest_path",`String manifest;
      "run_id",`String "manual-world";"binding",`Assoc ["sources",`List []]] in
    let id = text "instance_id" attached in
    await_ready (Eio.Stdenv.clock env) config id;
    let events = !(state.events) and observations = !(state.observations) in
    let inventory = Runtime.inventory ~config in
    check bool "existing manager observed" true inventory.owner_present;
    let current = List.find (fun (i : Runtime.inventory_instance) -> i.instance_id=id) inventory.instances in
    check bool "manual identity and live presence retained" true
      (current.incarnation=id && current.configuration=None && current.presence=Runtime.Live);
    check bool "metadata never starts or stops a worker" true (events = !(state.events));
    check bool "metadata never requests an observation" true (observations = !(state.observations));
    detach (Eio.Stdenv.clock env) config id)

let test_disable_keeps_configuration_evidence_and_manual_workers () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let source = declaration ~id:"observer" ~manifest () in
    write path source;
    let initial = Lane_addon_config.load_file ~path |> unwrap in
    check bool "accepting deployment keeps omitted enabled on" true initial.enabled;
    check bool "nonboolean activity is rejected" true
      (Result.is_error (Lane_addon_config.load_source ~source_path:path
        ~source_text:("enabled = \"false\"\n" ^ source)));
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let row = inspect config |> values "rows" |> List.hd |> text "id" in
    write path (declaration ~enabled:true ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    check string "explicit true keeps the existing worker" id
      (declared_instance config "observer" |> text "instance_id");
    let manual = dispatch config Runtime.Attach ["manifest_path",`String manifest;
      "run_id",`String "manual-world";"binding",`Assoc ["sources",`List []]] |> text "instance_id" in
    await_ready clock config manual;
    state.image_available := false;
    let off = declaration ~enabled:false ~id:"observer" ~manifest () in
    write path off;
    let disabled = Lane_addon_config.load_file ~path |> unwrap in
    check string "activity flag does not invalidate worker inputs" initial.revision disabled.revision;
    check bool "activity changes exact source identity" true (initial.source_revision <> disabled.source_revision);
    ignore (reconcile config directory);
    await_detached clock config id;
    check string "off keeps exact declaration bytes" off (In_channel.with_open_bin path In_channel.input_all);
    ignore (reconcile config directory);
    check int "repeated off never starts another worker" 2 (List.length (starts state));
    check_application config "observer" "inactive";
    let observed = inspect config |> member "configuration" |> values "declarations" |> List.hd in
    check string "observation names exact off bytes" disabled.source_revision (text "source_revision" observed);
    check bool "manual attachment is untouched" false (List.mem manual (stops state));
    let retained = dispatch config Runtime.Slice ["run_id",`String "declared-world"] in
    check bool "off preserves existing evidence" true
      (values "rows" retained |> List.exists (fun value -> text "id" value = row));
    state.image_available := true;
    write path (declaration ~enabled:true ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let replacement = declared_instance config "observer" |> text "instance_id" in
    check bool "on starts a new worker after cleanup" true (replacement <> id);
    await_ready clock config replacement;
    detach clock config replacement;
    detach clock config manual)

let test_disabled_cleanup_failure_remains_owned_until_retry () =
  with_fixture (fun env sw config directory packages state ->
    let real_clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~enabled:true ~id:"observer" ~manifest ());
    let clock, manual, sleeps = service_clock () in
    Runtime.start_configuration_service ~config ~sw ~clock;
    await_yield (fun () -> starts state <> []);
    let id = List.hd (starts state) in
    await_ready real_clock config id;
    let next = Eio.Stream.take sleeps in
    state.cleanup_available := false;
    write path (declaration ~enabled:false ~id:"observer" ~manifest ());
    Eio_mock.Clock.set_time manual next;
    await_yield (fun () -> phase (instance config id) = "failed");
    check bool "failed cleanup keeps TOML" true (Sys.file_exists path);
    check_application config "observer" "failed";
    write path (declaration ~enabled:true ~id:"observer" ~manifest ());
    let rec advance_until predicate =
      if not (predicate ()) then (
        let next = Eio.Stream.take sleeps in
        Eio_mock.Clock.set_time manual next;
        advance_until predicate) in
    advance_until (fun () -> List.length (stop_requests state) >= 2);
    check int "reenable cannot overlap unconfirmed cleanup" 1 (List.length (starts state));
    state.cleanup_available := true;
    advance_until (fun () -> List.length (starts state) = 2);
    await_detached real_clock config id;
    let replacement = declared_instance config "observer" |> text "instance_id" in
    await_ready real_clock config replacement;
    check int "one replacement after confirmed cleanup" 2 (List.length (starts state));
    check_application config "observer" "applied";
    detach real_clock config replacement)

let test_disabled_intent_does_not_override_incomplete_inventory () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    write path (declaration ~enabled:false ~id:"observer" ~manifest ());
    let unreadable = Filename.concat directory "unreadable.toml" in
    Unix.mkdir unreadable 0o700;
    let status = reconcile config directory in
    check bool "partial read remains explicit" false (member "complete" status |> Yojson.Safe.Util.to_bool);
    check bool "desired off is still visible" false
      (values "declarations" status |> List.hd |> member "enabled" |> Yojson.Safe.Util.to_bool);
    check int "incomplete inventory cannot authorize cleanup" 0 (List.length (stops state));
    check_application config "observer" "unknown";
    Unix.rmdir unreadable;
    ignore (reconcile config directory);
    await_detached clock config id;
    check bool "successful retry keeps declaration" true (Sys.file_exists path))

let test_created_container_waits_for_start_acceptance () =
  with_fixture (fun env _ config directory packages state ->
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let waiting,release = Eio.Promise.create () in
    state.startup_barrier := Some waiting;
    Fun.protect ~finally:(fun () ->
      if not (Eio.Promise.is_resolved waiting) then Eio.Promise.resolve release ()) (fun () ->
      write path (declaration ~id:"observer" ~manifest ());
      ignore (reconcile config directory);
      await_yield (fun () -> starts state <> []);
      let id = List.hd (starts state) in
      check_application config "observer" "starting";
      Eio.Promise.resolve release ();
      await_ready (Eio.Stdenv.clock env) config id;
      (* Inspect reads current runtime facts without another reconciliation. *)
      check_application config "observer" "applied";
      check string "accepted exact worker" id (application config "observer" |> text "instance_id");
      detach (Eio.Stdenv.clock env) config id))

let test_historical_publication_is_not_completion ~never_started ~cold_recovery () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    state.startup_available := not never_started;
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    if never_started then await clock (fun () -> phase (instance config id) = "failed")
    else await_ready clock config id;
    let captured = instance config id in
    ignore (dispatch config Runtime.Detach ["instance_id",`String id]);
    if never_started then await clock (fun () -> not (List.exists (fun item -> text "instance_id" item=id) (instances config)))
    else await_detached clock config id;
    Runtime.For_testing.reset ();
    state.events := [];
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:id captured);
    let off = declaration ~enabled:false ~id:"observer" ~manifest () in
    write path off;
    let mutex = Mutex.create () and condition = Condition.create () in
    let released = ref false and staged = Atomic.make false and first = Atomic.make true in
    let release () =
      Mutex.lock mutex; released := true; Condition.broadcast condition; Mutex.unlock mutex in
    let writer ~store ~instance_id terminal =
      if Atomic.exchange first false then (
        let result = match terminal with
          | Some json ->
              Result.bind (Store.save_binding store ~instance_id json) (fun () ->
                Error "injected terminal publication uncertainty after replacement")
          | None -> Store.For_testing.remove_binding
              ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync","fixture parent"))) store ~instance_id in
        Atomic.set staged true;
        Mutex.lock mutex;
        while not !released do Condition.wait condition mutex done;
        Mutex.unlock mutex;
        result)
      else match terminal with
        | Some json -> Store.save_binding store ~instance_id json
        | None -> Store.remove_binding store ~instance_id in
    Fun.protect ~finally:release (fun () ->
      Runtime.For_testing.with_cleanup_writer writer (fun () ->
        ignore (reconcile config directory);
        await_yield (fun () -> Atomic.get staged);
        check_application config "observer" "cleaning";
        let observed = inspect config |> member "configuration" |> values "declarations" |> List.hd in
        check bool "no live worker is not completion" true (member "instance_id" observed = `Null);
        release ();
        await clock (fun () -> text "kind" (application config "observer") = "failed");
        let requests () = List.filter (function Recovery_requested _ -> true | _ -> false) !(state.events) |> List.length in
        (* A worker that never reached its engine has none on record, so its
           cleanup asks no engine; any other cleanup asks the recorded one once. *)
        check int "resource cleanup happened once" (if never_started then 0 else 1) (requests ());
        let root = Store.root store in
        let unreadable = Store.For_testing.binding_inventory ~root
          ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync","cold read parent"))) in
        check bool "uncertain parent cannot authorize complete inventory" false unreadable.complete;
        if cold_recovery then (
          Runtime.For_testing.reset ();
          let synced = ref false in
          let confirmed = Store.For_testing.binding_inventory ~root ~sync_parent:(fun directory ->
            let fd = Unix.openfile directory [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
            Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
            synced := true) in
          check bool "cold read establishes publication durability" true (!synced && confirmed.complete));
        ignore (reconcile config directory);
        await clock (fun () -> text "kind" (application config "observer") = "inactive");
        check int "publication retry never repeats successful cleanup"
          (if never_started then 0 else 1) (requests ());
        check string "publication does not alter desired bytes" off (In_channel.with_open_bin path In_channel.input_all))))

(* Three real retained records that carry neither visibility nor
   source_access, so none names a reader: two producers of installation
   dos-counter and one consumer of it, which owns installation
   dos-output-statistics. All three are detached. *)
let retained_without_read_authority = ["producer-a.json"; "producer-b.json"; "consumer.json"]
let fixture_directory = Filename.concat "fixtures" "lane_addon_bindings_without_read_authority"
let fixture_bytes name =
  In_channel.with_open_bin (Filename.concat fixture_directory name) In_channel.input_all
let fixture_record name = Yojson.Safe.from_string (fixture_bytes name)
let retained_store config =
  Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons")
let bindings_directory config =
  Filename.concat (Filename.concat (Workspace.masc_dir config) "lane-addons") "bindings"
let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "a retained record is an object"
let still_attached json =
  replace_field "lifecycle" (Lane_addon_lifecycle.state_to_json Lane_addon_lifecycle.Attached)
    (replace_field "phase" (Types.phase_to_json Types.Attached) json)
let fixture_records ?(transform = Fun.id) () =
  List.map (fun name -> transform (fixture_record name)) retained_without_read_authority
let seed_records config records =
  List.map (fun json ->
    let id = text "instance_id" json in
    unwrap (Store.save_binding (retained_store config) ~instance_id:id json);
    id) records
let remove_seeded_files config =
  let bindings = bindings_directory config in
  Array.iter (fun name -> Sys.remove (Filename.concat bindings name)) (Sys.readdir bindings)
let issues_of id result =
  values "issues" result |> List.filter (fun issue -> member "id" issue = `String id)
let check_unchanged config records =
  List.iter (fun json ->
    let id = text "instance_id" json in
    let stored = unwrap (Store.bindings (retained_store config))
      |> List.find (fun stored -> text "instance_id" stored = id) in
    check bool "an unreadable record is neither rewritten nor cleaned up" true
      (Yojson.Safe.sort stored = Yojson.Safe.sort json)) records

let test_detached_unreadable_history_does_not_hold_its_declaration () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let records = fixture_records () in
    ignore (seed_records config records);
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
    let result = reconcile config directory in
    let observer = declared_instance config "observer" |> text "instance_id" in
    let counter = declared_instance config "dos-counter" |> text "instance_id" in
    await_ready clock config observer;
    await_ready clock config counter;
    check (list string) "a detached unreadable record of dos-counter holds no worker, so both start"
      (List.sort String.compare [observer; counter]) (List.sort String.compare (starts state));
    check_application config "observer" "applied";
    check_application config "dos-counter" "applied";
    check int "each detached record of dos-counter is still listed for the operator" 2
      (List.length (issues_of "dos-counter" result));
    check int "the consumer record is listed under its own installation id" 1
      (List.length (issues_of "dos-output-statistics" result));
    check_unchanged config records;
    detach clock config observer;
    detach clock config counter)

let test_documented_manual_repair_values_make_records_readable () =
  let visibilities = [
    {|{"kind": "shared"}|};
    {|{"kind": "operator"}|};
    {|{"kind": "keeper", "keeper": "keeper-a"}|} ] in
  let accesses = [
    {|{"kind": "operator_configuration"}|};
    {|{"kind": "keeper", "keeper": "keeper-a"}|};
    {|{"kind": "unauthenticated"}|} ] in
  List.iter (fun visibility ->
    List.iter (fun access ->
      with_fixture (fun env _ config directory packages _ ->
        let clock = Eio.Stdenv.clock env in
        let manifest = package packages "ready" in
        let repair json =
          json
          |> replace_field "visibility" (Yojson.Safe.from_string visibility)
          |> replace_field "source_access" (Yojson.Safe.from_string access) in
        ignore (seed_records config (fixture_records ~transform:repair ()));
        write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
        let result = reconcile config directory in
        let label = visibility ^ " with " ^ access in
        check int (label ^ ": no issue names dos-counter") 0
          (List.length (issues_of "dos-counter" result));
        check int (label ^ ": no issue names dos-output-statistics") 0
          (List.length (issues_of "dos-output-statistics" result));
        let id = declared_instance config "dos-counter" |> text "instance_id" in
        await_ready clock config id;
        check_application config "dos-counter" "applied";
        detach clock config id)) accesses) visibilities

let test_unreadable_records_hold_only_the_declaration_they_name () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let records = fixture_records ~transform:still_attached () in
    let seeded = seed_records config records in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
    let result = reconcile config directory in
    let observer = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config observer;
    check_application config "observer" "applied";
    check (list string) "only the declaration without an unreadable record starts a worker"
      [observer] (starts state);
    check_application config "dos-counter" "failed";
    check int "each unreadable record of dos-counter is listed once, plus the refusal to apply" 3
      (List.length (issues_of "dos-counter" result));
    check int "the consumer record is listed under its own installation id" 1
      (List.length (issues_of "dos-output-statistics" result));
    check int "no issue names the unrelated declaration" 0 (List.length (issues_of "observer" result));
    check_unchanged config records;
    check bool "a record that may hold a worker cannot be detached through its unreadable form" true
      (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Detach
        (`Assoc ["instance_id", `String (List.hd seeded)])));
    let slice = dispatch config Runtime.Slice [] in
    check bool "a slice that skipped unreadable records is not complete" false
      (member "complete" slice = `Bool true);
    detach clock config observer)

let test_declaration_waits_for_its_unreadable_records_then_applies () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    ignore (seed_records config (fixture_records ~transform:still_attached ()));
    write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
    ignore (reconcile config directory);
    check (list string) "the declaration with unreadable records waits" [] (starts state);
    remove_seeded_files config;
    ignore (reconcile config directory);
    let id = declared_instance config "dos-counter" |> text "instance_id" in
    await_ready clock config id;
    check_application config "dos-counter" "applied";
    detach clock config id)

(* An unreadable record that names the declaration and carries a broken read
   authority may hold its privacy owner, detached or not: the retention
   decision waits for the record instead of deciding shared and revoking the
   owner the record may name. *)
let test_detached_unreadable_record_keeps_the_document_owner () =
  with_fixture (fun _ _ config directory packages state ->
    let manifest = package packages "ready" in
    let broken_visibility = replace_field "visibility" (`String "unreadable") in
    let path = Filename.concat directory "dos-counter.toml" in
    let source = declaration ~id:"dos-counter" ~manifest () in
    write path source;
    (* The hold is for records that name this declaration: same id, source
       file and revision. The fixture's own owner names a file elsewhere, so
       seeded as it is the records would belong to no declaration here. *)
    let declared = Lane_addon_config.load_file ~path |> unwrap in
    let owned_by_declaration = replace_field "configuration"
      (`Assoc [ "id", `String declared.id; "source_path", `String declared.source_path;
                "revision", `String declared.revision ]) in
    ignore (seed_records config
      (fixture_records ~transform:(fun record -> owned_by_declaration (broken_visibility record)) ()));
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    unwrap (Lane_addon_document_owner.prepare ~root ~source_path:path ~keeper:"owner"
      ~prior_revision:None ~proposed_revision:(Store.digest source));
    let result = reconcile config directory in
    check bool "the declaration is refused for its unreadable visibility" true
      (List.exists (fun issue ->
         String_util.contains_substring (text "message" issue)
           "declaration retains a binding whose read visibility cannot be read")
         (issues_of "dos-counter" result));
    check (list string) "a held declaration starts no worker" [] (starts state);
    check bool "the document owner is not revoked" true
      (Result.is_ok (Lane_addon_document_owner.read ~root ~source_path:path));
    remove_seeded_files config)

(* A disabled declaration with its own unreadable record leaves the privacy
   owner untouched -- the retention decision cannot be made, so nothing is
   revoked -- while the records stay listed and no worker runs. *)
let test_disabled_declaration_with_unreadable_record_keeps_the_document_owner () =
  with_fixture (fun _ _ config directory packages state ->
    let manifest = package packages "ready" in
    let unreadable_attached json =
      replace_field "visibility" (`String "unreadable") (still_attached json) in
    ignore (seed_records config (fixture_records ~transform:unreadable_attached ()));
    let path = Filename.concat directory "dos-counter.toml" in
    let source = declaration ~enabled:false ~id:"dos-counter" ~manifest () in
    write path source;
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    unwrap (Lane_addon_document_owner.prepare ~root ~source_path:path ~keeper:"owner"
      ~prior_revision:None ~proposed_revision:(Store.digest source));
    let result = reconcile config directory in
    check (list string) "a disabled declaration starts no worker" [] (starts state);
    check bool "the document owner is not revoked" true
      (Result.is_ok (Lane_addon_document_owner.read ~root ~source_path:path));
    check bool "the unreadable records stay listed for the operator" true
      (issues_of "dos-counter" result <> []);
    remove_seeded_files config)

(* A configuration owner that cannot be read leaves the record unattributed,
   so it could hold any declaration's worker. It is not the same as a record
   whose configuration is null, which belongs to no declaration. *)
let test_record_with_unreadable_owner_holds_every_declaration () =
  let shared = `Assoc ["kind", `String "shared"] in
  let access = Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated in
  let owner_without_revision = `Assoc ["id", `String "dos-counter"; "source_path", `String "x"] in
  let variants = [
    "no read authority and a configuration that is not an owner",
      (fun json -> replace_field "configuration" (`Assoc ["id", `Int 5]) json);
    "readable authority and an owner without a revision",
      (fun json -> json |> replace_field "visibility" shared |> replace_field "source_access" access
        |> replace_field "configuration" owner_without_revision) ] in
  List.iter (fun (label, damage) ->
    with_fixture (fun env _ config directory packages state ->
      let clock = Eio.Stdenv.clock env in
      let manifest = package packages "ready" in
      ignore (seed_records config [damage (still_attached (fixture_record "producer-a.json"))]);
      write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
      let result = reconcile config directory in
      check (list string) (label ^ ": no declaration starts beside it") [] (starts state);
      check bool (label ^ ": the refusal is a configuration issue of the declaration") true
        (issues_of "observer" result <> []);
      check string (label ^ ": the declaration's application is unknown") "unknown"
        (application config "observer" |> text "kind");
      remove_seeded_files config;
      ignore (reconcile config directory);
      let id = declared_instance config "observer" |> text "instance_id" in
      await_ready clock config id;
      check_application config "observer" "applied";
      detach clock config id)) variants

(* A record that is valid JSON but has no observation sequence names its
   owner, so it is held against that owner like any other unreadable record. *)
let test_record_without_sequence_is_a_fault_of_its_owner () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let producer = still_attached (fixture_record "producer-a.json") in
    let without_sequence = match producer with
      | `Assoc fields -> `Assoc (List.remove_assoc "observation_seq" fields)
      | _ -> fail "a retained record is an object" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
    Fs_compat.mkdir_p (bindings_directory config);
    write (Filename.concat (bindings_directory config) (Store.digest (text "instance_id" producer) ^ ".json"))
      (Yojson.Safe.to_string without_sequence);
    let result = reconcile config directory in
    let observer = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config observer;
    check (list string) "the record held against dos-counter does not stop observer"
      [observer] (starts state);
    check bool "dos-counter is refused beside the listed record" true
      (List.length (issues_of "dos-counter" result) >= 2);
    detach clock config observer)

let test_unparsable_file_holds_every_declaration_but_not_inspect () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    unwrap (Store.save_binding (retained_store config) ~instance_id:"present"
      (`Assoc ["instance_id", `String "present"; "observation_seq", `Int 0]));
    write (Filename.concat (bindings_directory config) "corrupt.json") "{";
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    check (list string) "a file that is not JSON could belong to any declaration, so none starts" []
      (starts state);
    check bool "Inspect still answers, per record" true
      (Result.is_ok (Runtime.dispatch ~config ~operation:Runtime.Inspect (`Assoc [])));
    Sys.remove (Filename.concat (bindings_directory config) "corrupt.json");
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    detach clock config id)

(* Binding inventory issues name their failure kind so publication contention
   (identity-changed, confirmed-absent) reads apart from real damage (parse,
   non-regular) without opening the store (task-2382). The production path is
   exercised: a corrupt record and a replaced file land in one issues list and
   the two details differ by their bracketed tag. *)
(* A start that fails and a cleanup that then fails are two different causes.
   The second must not erase the first: the operator reads why the worker
   never started, not only that its cleanup was refused. *)
let test_a_failed_start_keeps_its_first_cause_through_a_failed_cleanup () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    state.create_refusal := Some "container name is already in use";
    ignore (reconcile config directory);
    let first_id = declared_instance config "observer" |> text "instance_id" in
    await clock (fun () -> phase (instance config first_id) = "failed");
    state.cleanup_available := false;
    ignore (reconcile config directory);
    await clock (fun () ->
      text "kind" (failed_record (instance config first_id) |> member "cause") = "cleanup_unconfirmed");
    let record = failed_record (instance config first_id) in
    check string "the cleanup failure is the current cause" "cleanup_unconfirmed"
      (member "cause" record |> text "kind");
    check string "the start failure is kept as the first cause" "worker_failed"
      (member "first" record |> text "kind");
    check string "the first cause names why the worker did not start"
      "container name is already in use" (member "first" record |> text "detail");
    state.cleanup_available := true;
    state.create_refusal := None;
    ignore (reconcile config directory);
    await clock (fun () -> List.for_all (fun v -> text "instance_id" v <> first_id) (instances config));
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    detach clock config id)

(* An unreachable engine is a cause that only the engine can remove. Beats
   read the one condition and do nothing else: no new start, no cleanup, no
   event. When the engine answers, the same beat retires the failed attempt
   and the next one attaches. *)
let test_a_waiting_failure_is_probed_and_not_retried () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    Fake.set_up state.home false;
    ignore (reconcile config directory);
    let failed_id = declared_instance config "observer" |> text "instance_id" in
    await clock (fun () -> phase (instance config failed_id) = "failed");
    check string "the failure says the engine is unreachable" "engine_unreachable"
      (failed_record (instance config failed_id) |> member "cause" |> text "kind");
    check int "one attempt so far" 1 (attempts state);
    let probes_before = !(state.condition_checks) in
    for _ = 1 to 5 do ignore (reconcile config directory) done;
    check int "five beats start nothing" 1 (attempts state);
    check int "five beats clean up nothing" 0 (recovery_requests state);
    check int "each beat read the condition once" (probes_before + 5) !(state.condition_checks);
    check string "the failed attempt is still the one on record" failed_id
      (declared_instance config "observer" |> text "instance_id");
    Fake.set_up state.home true;
    ignore (reconcile config directory);
    await clock (fun () -> List.for_all (fun v -> text "instance_id" v <> failed_id) (instances config));
    check int "no engine was recorded, so no create was issued and nothing is asked of any engine" 0
      (recovery_requests state);
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    check int "the next attempt is the second start" 2 (attempts state);
    detach clock config id)

(* A record written by an earlier shape carries a phase but no lifecycle. It
   is not read as detached, so it cannot be mistaken for a confirmed release:
   it is an unreadable record that holds the declaration it names. *)
let test_a_record_without_the_current_lifecycle_is_unreadable () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    (* Readable authority is present, so the only fault is the lifecycle. *)
    let readable_without_lifecycle json =
      match json
        |> replace_field "visibility" (`Assoc ["kind", `String "shared"])
        |> replace_field "source_access" (Lane_addon_sources.access_to_json Lane_addon_sources.Operator_configuration) with
      | `Assoc fields -> `Assoc (List.remove_assoc "lifecycle" fields)
      | _ -> fail "a retained record is an object" in
    let records = fixture_records ~transform:readable_without_lifecycle () in
    ignore (seed_records config records);
    write (Filename.concat directory "dos-counter.toml") (declaration ~id:"dos-counter" ~manifest ());
    let result = reconcile config directory in
    check (list string) "a record that is only a bare detached phase holds the declaration" [] (starts state);
    check bool "the declaration is refused beside its unreadable records" true
      (issues_of "dos-counter" result <> []);
    check_unchanged config records;
    remove_seeded_files config;
    ignore (reconcile config directory);
    let id = declared_instance config "dos-counter" |> text "instance_id" in
    await_ready clock config id;
    detach clock config id)

(* The incident: the CLI is pointed at another engine, which holds none of this
   worker's containers. Its "nothing here" is not a release. The record stays
   failed, with the recorded engine as the condition for the next attempt,
   and the container is released once that engine answers again. *)
let test_another_engine_does_not_release_a_worker () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let container = Store.digest id in
    check bool "the container is on the first engine" true (Fake.holds state.home container);
    check string "the first engine is on record" "engine-a"
      (instance config id |> member "execution_authority" |> member "engine" |> text "id");
    Fake.point_at state.world (Fake.docker "engine-b");
    write path (declaration ~enabled:false ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    await clock (fun () -> phase (instance config id) = "failed");
    let cause = failed_record (instance config id) |> member "cause" in
    check string "the refusal is a mismatch" "engine_mismatch" (text "kind" cause);
    check string "it names the recorded engine" "engine-a" (member "recorded" cause |> text "id");
    check string "and the engine that answered" "engine-b"
      (member "observed" cause |> member "engine" |> text "id");
    check bool "the container was not released" true (Fake.holds state.home container);
    let probes = !(state.condition_checks) in
    for _ = 1 to 4 do ignore (reconcile config directory) done;
    check int "four more beats stop nothing" 1 (List.length (stop_requests state));
    check int "each beat reads the condition once" (probes + 4) !(state.condition_checks);
    Fake.point_at state.world state.home;
    ignore (reconcile config directory);
    await_detached clock config id;
    check bool "the recorded engine released the container" false (Fake.holds state.home container);
    let release = lifecycle (instance config id) |> member "release" in
    check string "the release names the engine" "engine-a" (member "engine" release |> text "id");
    check string "the release names the container" container (text "container_id" release))

let test_an_unreachable_engine_waits_and_then_releases () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    Fake.set_up state.home false;
    write path (declaration ~enabled:false ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    await clock (fun () -> phase (instance config id) = "failed");
    check string "an engine that does not answer is its own cause" "engine_unreachable"
      (failed_record (instance config id) |> member "cause" |> text "kind");
    check bool "the container is kept" true (Fake.holds state.home (Store.digest id));
    for _ = 1 to 3 do ignore (reconcile config directory) done;
    check int "waiting beats stop nothing" 1 (List.length (stop_requests state));
    Fake.set_up state.home true;
    ignore (reconcile config directory);
    await_detached clock config id;
    check bool "released once the engine answers" false (Fake.holds state.home (Store.digest id)))

let persistent_package packages id =
  let manifest = package packages id in
  write manifest (In_channel.with_open_bin manifest In_channel.input_all ^ "\n[world.state]\nmode = \"persistent\"\n");
  manifest

(* Install and release one persistent worker, and return the shared writer
   container it held: its name and labels are the slot every later incarnation
   of the installation needs. *)
let released_writer_slot env config directory packages state =
  let clock = Eio.Stdenv.clock env in
  let manifest = persistent_package packages "ready" in
  let path = Filename.concat directory "observer.toml" in
  write path (declaration ~id:"observer" ~manifest ());
  ignore (reconcile config directory);
  let first = declared_instance config "observer" |> text "instance_id" in
  await_ready clock config first;
  let slot = match Fake.find state.home (Store.digest first) with
    | Some container -> container | None -> fail "the worker's container is on its engine" in
  write path (declaration ~enabled:false ~id:"observer" ~manifest ());
  ignore (reconcile config directory);
  await_detached clock config first;
  check bool "the first incarnation's container is released" false (Fake.holds state.home slot.id);
  manifest, path, first, slot

let other_instance (slot : Fake.container) instance =
  ("masc.lane.instance", instance) :: List.remove_assoc "masc.lane.instance" slot.labels

(* The incident: a server died and left an exited container holding the
   installation's writer name, while its record already says released. A new
   incarnation must not trust that record. It reads the slot, clears the dead
   predecessor and starts. *)
let test_a_dead_predecessor_holding_the_slot_does_not_block_a_new_instance () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest, path, first, slot = released_writer_slot env config directory packages state in
    check bool "the released record carries its evidence" true
      (member "release" (lifecycle (instance config first)) <> `Null);
    ignore (Fake.add state.home ~id:"dead-writer-container" ~name:slot.name
      ~labels:(other_instance slot "dead-writer") ());
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let second = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config second;
    check bool "the dead predecessor was removed" false (Fake.holds state.home "dead-writer-container");
    check bool "the new incarnation holds the slot" true (Fake.holds state.home (Store.digest second));
    check int "two incarnations were started" 2 (List.length (starts state));
    detach clock config second)

(* A container under the slot's name that is not a dead predecessor is never
   removed. The attempt says who holds the slot and then waits for that
   container to change; beats read it and do nothing else. *)
let test_a_foreign_holder_makes_the_attempt_wait_for_the_holder_to_change () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest, path, _first, slot = released_writer_slot env config directory packages state in
    ignore (Fake.add state.home ~id:"foreign-container" ~name:slot.name
      ~labels:["masc.lane.instance", "someone"] ());
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let failed_id = declared_instance config "observer" |> text "instance_id" in
    await clock (fun () -> phase (instance config failed_id) = "failed");
    let cause = failed_record (instance config failed_id) |> member "cause" in
    check string "the cause is a foreign slot holder" "slot_foreign" (text "kind" cause);
    check string "it names the container" "foreign-container"
      (member "holder" cause |> text "container_id");
    check bool "it names the holder's labels" true
      (member "holder" cause |> member "instance" = `String "someone"
       && member "holder" cause |> member "state_owner" = `Null);
    check bool "the foreign container was not touched" true (Fake.holds state.home "foreign-container");
    let attempts_before = attempts state and probes = !(state.condition_checks) in
    for _ = 1 to 4 do ignore (reconcile config directory) done;
    check int "four beats start nothing" attempts_before (attempts state);
    check int "four beats clean up nothing" 0 (recovery_requests state);
    check int "each beat reads the holder once" (probes + 4) !(state.condition_checks);
    Fake.remove state.world "foreign-container";
    ignore (reconcile config directory);
    await clock (fun () -> List.for_all (fun v -> text "instance_id" v <> failed_id) (instances config));
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    check bool "the new incarnation holds the freed slot" true (Fake.holds state.home (Store.digest id));
    detach clock config id)

(* Removing the declaration is what stops the observer from being applied
   again. If it were removed before the worker's container was confirmed gone,
   a cleanup that failed would leave a running container that nothing desires
   and nothing retries. The declaration goes only after the release. *)
let test_detach_keeps_the_declaration_when_cleanup_fails () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    state.cleanup_available := false;
    let refused = Runtime.dispatch ~config ~operation:Runtime.Detach (`Assoc ["instance_id", `String id]) in
    (match refused with
     | Error _ -> ()
     | Ok _ -> fail "a Detach whose cleanup failed must not report success");
    check bool "the declaration is still there" true (Sys.file_exists path);
    check string "the worker is failed with its cleanup cause" "cleanup_unconfirmed"
      (failed_record (instance config id) |> member "cause" |> text "kind");
    state.cleanup_available := true;
    detach clock config id;
    check bool "once the container is confirmed gone the declaration is removed" false (Sys.file_exists path);
    check bool "the container is released" false (Fake.holds state.home (Store.digest id)))

let test_detach_of_a_retained_record_keeps_the_declaration_when_cleanup_fails () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    write path (declaration ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let captured = instance config id in
    (* A host restart: the record says running and no live worker exists. The
       container the first worker made is still on its engine. *)
    write path (declaration ~enabled:false ~id:"observer" ~manifest ());
    ignore (reconcile config directory);
    await_detached clock config id;
    ignore (Fake.add state.home ~id:(Store.digest id) ~name:(container_name id)
      ~labels:["masc.lane.instance", id] ());
    Runtime.For_testing.reset ();
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:id (still_attached captured));
    write path (declaration ~id:"observer" ~manifest ());
    state.cleanup_available := false;
    check bool "a failed historical cleanup is reported" true
      (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Detach (`Assoc ["instance_id", `String id])));
    check bool "the declaration is still there" true (Sys.file_exists path);
    check bool "the container is still there" true (Fake.holds state.home (Store.digest id));
    state.cleanup_available := true;
    ignore (dispatch config Runtime.Detach ["instance_id", `String id]);
    check bool "after the confirmed release the declaration is removed" false (Sys.file_exists path);
    check bool "the container is released" false (Fake.holds state.home (Store.digest id)))

(* After an abnormal exit nothing but the engine knows which containers the
   dead server made. The first beat that finds the engine answering removes
   the dead ones of this base path, once; until then the declaration is
   reported, not retried in the log. *)
let test_a_dead_servers_containers_are_swept_once_the_engine_answers () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    let dead_name = Lane_addon_engine.owned_name Types.Docker "dead-server-instance" in
    ignore (Fake.add state.home ~id:"dead-server-container" ~name:dead_name
      ~labels:["masc.lane.instance", "dead-server-instance"; Lane_addon_engine.scope_label, Fake.scope_of_world] ());
    ignore (Fake.add state.home ~id:"other-servers-container" ~name:"masc-lane-elsewhere"
      ~labels:["masc.lane.instance", "elsewhere"; Lane_addon_engine.scope_label, "another base path"] ());
    Fake.set_up state.home false;
    let result = reconcile config directory in
    let refused_attempt = declared_instance config "observer" |> text "instance_id" in
    check int "the sweep was asked once, while the engine was down" 1 !(state.sweeps);
    check bool "the unreachable engine is reported as an issue of this beat" true
      (values "issues" result <> []);
    check bool "nothing was removed" true (Fake.holds state.home "dead-server-container");
    Fake.set_up state.home true;
    ignore (reconcile config directory);
    check bool "the dead server's container is removed" false (Fake.holds state.home "dead-server-container");
    check bool "another base path's container is not" true (Fake.holds state.home "other-servers-container");
    check bool "the report names the removal" true
      (List.exists (fun (item : Lane_addon_slot.sweep_item) ->
         item.container_id = "dead-server-container" && item.verdict = Lane_addon_slot.Removed) !(state.swept));
    (* The attempt made while the engine was down is retired once it answers;
       the next beat attaches. *)
    await clock (fun () -> List.for_all (fun v -> text "instance_id" v <> refused_attempt) (instances config));
    ignore (reconcile config directory);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    let sweeps = !(state.sweeps) in
    ignore (reconcile config directory);
    check int "the sweep runs once per runtime" sweeps !(state.sweeps);
    check bool "the live worker's container is untouched" true (Fake.holds state.home (Store.digest id));
    detach clock config id)

(* Whether a refused container is looked at again is [Lifecycle.heal]'s call
   on the refusal. A removal the engine refused can succeed later; a holder
   that is not this server's predecessor stays what it is. *)
let test_a_sweep_that_could_not_remove_is_run_again () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    let dead_name = Lane_addon_engine.owned_name Types.Docker "dead-server-instance" in
    ignore (Fake.add state.home ~id:"dead-server-container" ~name:dead_name
      ~labels:["masc.lane.instance", "dead-server-instance"; Lane_addon_engine.scope_label, Fake.scope_of_world] ());
    Fake.refuse_removal state.home "dead-server-container";
    let sweep_logs ~since_seq level =
      Log.Ring.recent ~module_filter:"Misc" ~since_seq ()
      |> List.filter (fun (e : Log.Ring.entry) ->
           e.level = level
           && String_util.contains_substring e.message "dead-server-container")
    in
    let seq0 = (Log.Ring.bounds ()).total - 1 in
    let first_report = reconcile config directory in
    let seq1 = (Log.Ring.bounds ()).total - 1 in
    check int "the first beat sweeps" 1 !(state.sweeps);
    check bool "the refused container is still there" true (Fake.holds state.home "dead-server-container");
    let first_issues = values "issues" first_report |> List.map (text "message") in
    check int "retrying sweep refusal is surfaced in configuration status" 1
      (List.length first_issues);
    let first_issue_msg = List.hd first_issues in
    check bool "issue names the retrying container and first refused timestamp" true
      (String_util.contains_substring first_issue_msg "dead-server-container"
       && String_util.contains_substring first_issue_msg "first refused at ");
    check (list string) "inspect configuration status matches reconcile report"
      first_issues
      (inspect config |> member "configuration" |> values "issues" |> List.map (text "message"));
    check int "first refusal logs one WARN" 1 (List.length (sweep_logs ~since_seq:seq0 Log.Warn));
    let second_report = reconcile config directory in
    let seq2 = (Log.Ring.bounds ()).total - 1 in
    check int "a removal that failed is swept again on the next beat" 2 !(state.sweeps);
    check (list string) "the same retrying refusal keeps its first refused timestamp"
      first_issues
      (values "issues" second_report |> List.map (text "message"));
    check int "unchanged refusal does not repeat WARN on the next beat" 0
      (List.length (sweep_logs ~since_seq:seq1 Log.Warn));
    Fake.allow_removal state.home "dead-server-container";
    let third_report = reconcile config directory in
    let seq3 = (Log.Ring.bounds ()).total - 1 in
    check int "and again once more" 3 !(state.sweeps);
    check bool "the container is removed when the engine allows it" false
      (Fake.holds state.home "dead-server-container");
    check (list string) "resolved sweep retry clears configuration issues" []
      (values "issues" third_report |> List.map (text "message"));
    let info_logs = sweep_logs ~since_seq:seq2 Log.Info in
    check int "resolution logs one INFO" 1 (List.length info_logs);
    check bool "resolution log mentions retry resolution" true
      (String_util.contains_substring (List.hd info_logs).message "resolved after retry since ");
    ignore seq3;
    ignore (reconcile config directory);
    ignore (reconcile config directory);
    check int "a sweep with nothing left to retry is not repeated" 3 !(state.sweeps);
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    detach clock config id)

let test_a_sweep_that_refused_a_foreign_container_is_not_repeated () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    (* In this server's scope but not named for any incarnation of its own. *)
    ignore (Fake.add state.home ~id:"foreign-container" ~name:"someone-elses-name"
      ~labels:[Lane_addon_engine.scope_label, Fake.scope_of_world] ());
    ignore (reconcile config directory);
    check int "the first beat sweeps" 1 !(state.sweeps);
    for _ = 1 to 4 do ignore (reconcile config directory) done;
    check int "four more beats do not sweep again" 1 !(state.sweeps);
    check bool "the foreign container is untouched" true (Fake.holds state.home "foreign-container");
    check bool "the refusal was a foreign holder" true
      (List.exists (fun (item : Lane_addon_slot.sweep_item) -> match item.verdict with
         | Lane_addon_slot.Refused (Lifecycle.Slot_foreign _) -> item.container_id = "foreign-container"
         | Lane_addon_slot.Refused _ | Lane_addon_slot.Removed | Lane_addon_slot.Live -> false) !(state.swept));
    let id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config id;
    detach clock config id)

(* The runtime hands the backend one question, whether an incarnation is still
   alive in this process. A worker answers it, and so does a cleanup that is
   still running for a record of an earlier process; a container of such an
   incarnation must not be taken for a dead server's. *)
let test_an_incarnation_is_live_while_it_has_a_worker_or_a_cleanup () =
  with_fixture (fun env _ config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    let live id = match !(state.liveness) with
      | Some is_live -> is_live id
      | None -> fail "the sweep has not asked yet" in
    check bool "an incarnation with a worker is live" true (live old_id);
    check bool "an incarnation nothing holds is not live" false (live "nobody");
    let captured = instance config old_id in
    let container_id = member "resource" captured |> text "id" in
    detach clock config old_id;
    Runtime.For_testing.reset ();
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id captured);
    write path bytes;
    let recovered, release_recovery = Eio.Promise.create () in
    state.recovery_barrier := Some recovered;
    ignore (reconcile config directory);
    await clock (fun () -> List.mem (Recovery_requested (old_id, Some container_id)) !(state.events));
    check bool "an incarnation whose cleanup is running is live, with no worker" true (live old_id);
    Eio.Promise.resolve release_recovery ();
    await clock (fun () -> not (live old_id));
    ignore (reconcile config directory);
    let replacement = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config replacement;
    detach clock config replacement)

(* The slot procedures are exercised over a port that answers a name lookup
   with a container of another name, as an engine's pattern filter could. The
   containers carry labels that would make them removable if the name were not
   checked. *)
let test_a_container_under_another_name_is_never_the_slot () =
  let world = Fake.create (Fake.docker "engine-a") in
  let owner = "owner-label" in
  ignore (Fake.add (Fake.current world) ~id:"dead-predecessor" ~name:"somewhere-else"
    ~labels:[Lane_addon_engine.instance_label, "dead"; Lane_addon_engine.state_owner_label, owner] ());
  ignore (Fake.add (Fake.current world) ~id:"own-leftover" ~name:"also-elsewhere"
    ~labels:[Lane_addon_engine.instance_label, "new"; Lane_addon_engine.state_owner_label, owner] ());
  let answering id = { (Fake.port world) with Lane_addon_slot.find = (fun _ -> Ok (Some id)) } in
  (match Lane_addon_slot.claim (answering "dead-predecessor") ~name:"the-slot" ~instance_id:"new"
           ~mine:(Some owner) ~is_live_instance:(fun _ -> false) with
   | Error (Lifecycle.Worker_failed _) -> ()
   | Ok () | Error _ -> fail "a container under another name must stop the claim as unreadable");
  check bool "the would-be predecessor survives the claim" true (Fake.holds (Fake.current world) "dead-predecessor");
  (match Lane_addon_slot.release (answering "own-leftover") ~lookup:(Lane_addon_engine.Name "the-slot")
           ~instance_id:"new" ~mine:(Some owner) with
   | Error (Lifecycle.Cleanup_unconfirmed _) -> ()
   | Ok () | Error _ -> fail "a release by name must not be confirmed by a container of another name");
  check bool "the would-be own container survives the release" true (Fake.holds (Fake.current world) "own-leftover")

(* A container left under the slot by this very incarnation is its own,
   whatever the process thinks of the incarnation: it is removed, and a failed
   removal is a cleanup the caller must see, not a predecessor it can ignore. *)
let test_a_worker_clears_its_own_leftover_from_the_slot () =
  let world = Fake.create (Fake.docker "engine-a") in
  let owner = "owner-label" in
  let labels = [Lane_addon_engine.instance_label, "new"; Lane_addon_engine.state_owner_label, owner] in
  ignore (Fake.add (Fake.current world) ~id:"own-leftover" ~name:"the-slot" ~labels ());
  let claim () = Lane_addon_slot.claim (Fake.port world) ~name:"the-slot" ~instance_id:"new"
    ~mine:(Some owner) ~is_live_instance:(fun _ -> true) in
  Fake.refuse_removal (Fake.current world) "own-leftover";
  (match claim () with
   | Error (Lifecycle.Cleanup_unconfirmed _) -> ()
   | Ok () | Error _ -> fail "a leftover of this incarnation that cannot be removed is an unconfirmed cleanup");
  Fake.allow_removal (Fake.current world) "own-leftover";
  (match claim () with
   | Ok () -> ()
   | Error _ -> fail "a leftover of this incarnation is removed even though the incarnation is live");
  check bool "the leftover is gone" false (Fake.holds (Fake.current world) "own-leftover")

let test_binding_inventory_issues_carry_failure_kind_tags () =
  with_fixture (fun _ _ config _directory _packages _state ->
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    Fs_compat.mkdir_p (Filename.concat root "bindings");
    write (Filename.concat (bindings_directory config) "corrupt.json") "{not json";
    let replaced = Filename.concat (bindings_directory config) "replaced.json" in
    write replaced "{}";
    Unix.unlink replaced;
    Fs_compat.mkdir_p replaced;
    let inventory = Store.binding_inventory ~root in
    check bool "tagged issues still make the inventory incomplete" false inventory.complete;
    check int "both damaged records are reported" 2 (List.length inventory.issues);
    let detail_of name =
      List.find (fun (path, _) -> Filename.basename path = name) inventory.issues |> snd in
    let parse = detail_of "corrupt.json" in
    let non_regular = detail_of "replaced.json" in
    check bool "a stable corrupt record is tagged parse"
      true (String.starts_with ~prefix:"[parse] " parse);
    check bool "a replaced file is tagged non-regular"
      true (String.starts_with ~prefix:"[non-regular directory] " non_regular);
    check bool "parse damage and non-regular damage read apart"
      true (parse <> non_regular);
    let identity = Store.For_testing.issue_detail
        { Fs_compat.failure =
            Fs_compat.Filesystem_identity_changed { path = "unused" }
        ; close_failure = None } in
    check bool "identity-changed carries its own tag"
      true (String.starts_with ~prefix:"[identity-changed] " identity))

let test_unlistable_binding_store_stops_reconciliation () =
  with_fixture (fun _ _ config directory packages state ->
    let manifest = package packages "ready" in
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    Fs_compat.mkdir_p root;
    write (Filename.concat root "bindings") "not a directory";
    write (Filename.concat directory "observer.toml") (declaration ~id:"observer" ~manifest ());
    let result = reconcile config directory in
    check (list string) "a store that cannot be listed starts no declaration" [] (starts state);
    check bool "the store failure is a configuration issue" true (values "issues" result <> []);
    check bool "Inspect refuses a store that cannot be listed" true
      (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Inspect (`Assoc []))))

let () = run "Lane Add-on TOML reconciliation" ["declarative optional extension", [
  test_case "persistent runtime switch preserves old state and requires new installation" `Quick
    test_persistent_runtime_switch_requires_new_installation;
  test_case "created container waits for accepted startup" `Quick test_created_container_waits_for_start_acceptance;
  test_case "historical replacement commit remains pending and retries publication only" `Quick
    (test_historical_publication_is_not_completion ~never_started:false ~cold_recovery:false);
  test_case "historical unlink sync failure retains owner and retries publication only" `Quick
    (test_historical_publication_is_not_completion ~never_started:true ~cold_recovery:false);
  test_case "cold read reestablishes terminal replacement durability" `Quick
    (test_historical_publication_is_not_completion ~never_started:false ~cold_recovery:true);
  test_case "cold read reestablishes missing binding durability" `Quick
    (test_historical_publication_is_not_completion ~never_started:true ~cold_recovery:true);
  test_case "off preserves configuration, evidence and manual workers" `Quick test_disable_keeps_configuration_evidence_and_manual_workers;
  test_case "reenable waits for confirmed disabled cleanup" `Quick test_disabled_cleanup_failure_remains_owned_until_retry;
  test_case "disabled intent remains visible during incomplete inventory" `Quick test_disabled_intent_does_not_override_incomplete_inventory;
  test_case "live manual inventory reads no worker effects" `Quick test_inventory_reads_live_manual_without_effects;
  test_case "duplicate TOML keys preserve applied owners and report issues" `Quick
    test_duplicate_toml_keys_preserve_applied_workers;
  test_case "historical cleanup failures wait for virtual maintenance beats" `Quick
    test_historical_recovery_failure_waits_for_maintenance;
  test_case "explicit removal preserves newer and malformed desired files" `Quick
    test_detach_preserves_newer_or_malformed_declaration;
  test_case "startup dependency recovery uses unchanged TOML" `Quick
    test_startup_dependency_recovers_without_editing_toml;
  test_case "a missing image creates nothing until it is built" `Quick
    test_missing_image_creates_nothing_until_it_is_built;
  test_case "historical missing container identity is recovered" `Quick
    test_historical_missing_container_identity_is_recovered;
  test_case "historical never-started binding leaves no file" `Quick
    test_historical_never_started_leaves_no_binding;
  test_case "cleanup failures wait for maintenance rather than hotloop" `Quick
    test_cleanup_failure_retries_on_maintenance_without_hotloop;
  test_case "install, idempotence, rename, and explicit removal" `Quick
    test_install_idempotence_rename_and_public_detach;
  test_case "changed binding retires before replacement" `Quick
    test_changed_binding_retires_before_replacement;
  test_case "malformed and duplicate declarations preserve activity" `Quick
    test_invalid_inventory_preserves_existing_activity;
  test_case "deleted declaration retains queryable history" `Quick
    test_deleted_declaration_retains_history;
  test_case "restart recovers persisted exact owner before replacement" `Quick
    (test_restart_recovers_exact_owner_before_replacement ~runtime:Types.Docker);
  test_case "microVM restart recovers using the retained engine and state owner" `Quick
    (test_restart_recovers_exact_owner_before_replacement ~runtime:Types.Apple_container);
  test_case "held observation preserves primary and other declaration progress" `Quick
    test_held_observer_does_not_block_other_declarations;
  test_case "a detached unreadable record does not hold its declaration" `Quick
    test_detached_unreadable_history_does_not_hold_its_declaration;
  test_case "unreadable records hold only the declaration they name" `Quick
    test_unreadable_records_hold_only_the_declaration_they_name;
  test_case "a declaration waits for its unreadable records and applies once they are gone" `Quick
    test_declaration_waits_for_its_unreadable_records_then_applies;
  test_case "the documented manual repair values make records readable" `Quick
    test_documented_manual_repair_values_make_records_readable;
  test_case "an unreadable record keeps the document owner it may name" `Quick
    test_detached_unreadable_record_keeps_the_document_owner;
  test_case "a disabled declaration with unreadable records keeps its document owner" `Quick
    test_disabled_declaration_with_unreadable_record_keeps_the_document_owner;
  test_case "a record with an unreadable owner holds every declaration" `Quick
    test_record_with_unreadable_owner_holds_every_declaration;
  test_case "a record without a sequence is a fault of its owner" `Quick
    test_record_without_sequence_is_a_fault_of_its_owner;
  test_case "a file that is not JSON holds every declaration but not Inspect" `Quick
    test_unparsable_file_holds_every_declaration_but_not_inspect;
  test_case "a binding store that cannot be listed stops reconciliation" `Quick
    test_unlistable_binding_store_stops_reconciliation;
  test_case "binding inventory issues carry failure-kind tags" `Quick
    test_binding_inventory_issues_carry_failure_kind_tags;
  test_case "a failed start keeps its first cause through a failed cleanup" `Quick
    test_a_failed_start_keeps_its_first_cause_through_a_failed_cleanup;
  test_case "a waiting failure is probed and not retried" `Quick
    test_a_waiting_failure_is_probed_and_not_retried;
  test_case "a record without the current lifecycle is unreadable" `Quick
    test_a_record_without_the_current_lifecycle_is_unreadable;
  test_case "another engine does not release a worker" `Quick
    test_another_engine_does_not_release_a_worker;
  test_case "an unreachable engine waits and then releases" `Quick
    test_an_unreachable_engine_waits_and_then_releases;
  test_case "a dead predecessor holding the slot does not block a new instance" `Quick
    test_a_dead_predecessor_holding_the_slot_does_not_block_a_new_instance;
  test_case "a foreign holder makes the attempt wait for the holder to change" `Quick
    test_a_foreign_holder_makes_the_attempt_wait_for_the_holder_to_change;
  test_case "a dead server's containers are swept once the engine answers" `Quick
    test_a_dead_servers_containers_are_swept_once_the_engine_answers;
  test_case "a sweep that could not remove is run again" `Quick
    test_a_sweep_that_could_not_remove_is_run_again;
  test_case "a sweep that refused a foreign container is not repeated" `Quick
    test_a_sweep_that_refused_a_foreign_container_is_not_repeated;
  test_case "an incarnation is live while it has a worker or a cleanup" `Quick
    test_an_incarnation_is_live_while_it_has_a_worker_or_a_cleanup;
  test_case "a container under another name is never the slot" `Quick
    test_a_container_under_another_name_is_never_the_slot;
  test_case "a worker clears its own leftover from the slot" `Quick
    test_a_worker_clears_its_own_leftover_from_the_slot;
  test_case "Detach keeps the declaration when cleanup fails" `Quick
    test_detach_keeps_the_declaration_when_cleanup_fails;
  test_case "Detach of a retained record keeps the declaration when cleanup fails" `Quick
    test_detach_of_a_retained_record_keeps_the_declaration_when_cleanup_fails;
]]
