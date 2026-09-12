(** TOML installation lifecycle through the real configuration reader and
    runtime reconciler. Only the external worker and source acquisition are
    replaced by observable barriers; no Docker daemon or model is required. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Types = Lane_addon_types
module Store = Lane_addon_store

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

type fake = {
  events : worker_event list ref;
  observations : (string * Yojson.Safe.t) list ref;
  recovery_barrier : unit Eio.Promise.t option ref;
  startup_available : bool ref;
  cleanup_available : bool ref;
}

let output : Types.output = {
  rows = [{ id = "observed-row"; lane_id = "fixture/observations"; kind = Types.Event;
    title = "Package observation"; observed_at = 1.; subject_id = "fixture-target";
    clock = None; actor = None; fields = []; evidence = []; related_ids = [] }];
  coverage = [{ source_id = "fixture"; incarnation = "fixture-incarnation";
    cursor = Some "1"; complete = true; detail = None }];
}

let make_backend () =
  let state = { events = ref []; observations = ref []; recovery_barrier = ref None;
                startup_available = ref true; cleanup_available = ref true } in
  let record event = state.events := event :: !(state.events) in
  let backend : Runtime.For_testing.backend = {
    start = (fun ~sw:_ ~instance_id ~(package : Types.package) ~on_created ->
      let stopped, release_stop = Eio.Promise.create () in
      let stop_sent = ref false in
      let connection : Runtime.For_testing.connection = {
        container_id = Store.digest instance_id;
        observe = (fun ~binding ~sources:_ ->
          state.observations := (instance_id, binding) :: !(state.observations);
          match package.id with
          | "held" -> Eio.Promise.await stopped; Error "owned observer stopped"
          | _ -> Ok output);
        stop = (fun () ->
          record (Stop_requested instance_id);
          if not !(state.cleanup_available) then Error "cleanup dependency unavailable"
          else begin
          if not !stop_sent then begin
            stop_sent := true;
            record (Stopped instance_id);
            Eio.Promise.resolve release_stop ()
          end;
          Ok ()
          end);
      } in
      if not !(state.startup_available) then begin
        record (Startup_failed instance_id);
        Error "worker dependency unavailable"
      end else begin
        record (Started instance_id);
        on_created connection;
        Ok connection
      end);
    acquire = (fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
    recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes:_ ->
      if Option.exists (fun id -> id <> Store.digest instance_id) container_id
      then Error "persisted container does not belong to instance"
      else begin
        record (Recovery_requested (instance_id, container_id));
        if not !(state.cleanup_available) then Error "historical cleanup dependency unavailable"
        else begin
          Option.iter Eio.Promise.await !(state.recovery_barrier);
          record (Recovery_completed (instance_id, container_id));
          Ok ()
        end
      end);
  } in
  state, backend

let package directory id =
  let path = Filename.concat directory (id ^ "-package.toml") in
  write path (Printf.sprintf {|id = %S
revision = "fixture-1"
title = "Declared observer"
image = "fixture/observer"
command = ["observer"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
|} id);
  path

let declaration ?(setting = "initial") ~id ~manifest () =
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
  active config |> List.find (fun value -> configuration_id value = id)
let starts state = List.filter_map (function Started id -> Some id | _ -> None) !(state.events)
let stops state = List.filter_map (function Stopped id -> Some id | _ -> None) !(state.events)
let reconcile config directory = unwrap (Runtime.reconcile_configuration ~config ~directory)
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
    check string "replacement receives changed binding" "changed"
      (List.assoc new_id !(state.observations) |> text "setting");
    check int "only one current owner" 1 (List.length (active config));
    check bool "old evidence survives replacement" true
      (dispatch config Runtime.Slice [] |> values "rows"
       |> List.exists (fun row -> text "id" row = old_row));
    detach clock config new_id)

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

let test_restart_recovers_exact_owner_before_replacement () =
  with_fixture (fun env sw config directory packages state ->
    let clock = Eio.Stdenv.clock env in
    let manifest = package packages "ready" in
    let path = Filename.concat directory "observer.toml" in
    let bytes = declaration ~id:"observer" ~manifest () in
    write path bytes;
    ignore (reconcile config directory);
    let old_id = declared_instance config "observer" |> text "instance_id" in
    await_ready clock config old_id;
    let captured = instance config old_id in
    let container_id = text "container_id" captured in
    detach clock config old_id;
    (* All live fake work is stopped before replaying the captured persistent
       binding. Reset alone is never used to abandon an active worker. *)
    Runtime.For_testing.reset ();
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    unwrap (Store.save_binding store ~instance_id:old_id captured);
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
    Runtime.notify_activity ~config;
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
    let without_id = `Assoc (("container_id", `Null) :: List.remove_assoc "container_id" fields) in
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
    let cid = Some (text "container_id" captured) in
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

let () = run "Lane Add-on TOML reconciliation" ["declarative optional extension", [
  test_case "historical cleanup failures wait for virtual maintenance beats" `Quick
    test_historical_recovery_failure_waits_for_maintenance;
  test_case "explicit removal preserves newer and malformed desired files" `Quick
    test_detach_preserves_newer_or_malformed_declaration;
  test_case "startup dependency recovery uses unchanged TOML" `Quick
    test_startup_dependency_recovers_without_editing_toml;
  test_case "historical missing container identity is recovered" `Quick
    test_historical_missing_container_identity_is_recovered;
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
    test_restart_recovers_exact_owner_before_replacement;
  test_case "held observation preserves primary and other declaration progress" `Quick
    test_held_observer_does_not_block_other_declarations;
]]
