(** Container lifecycle events reach the MASC-owned bus. The fake backend
    reuses the lifecycle modes of test_lane_addon; assertions read the
    drained bus stream, not the store. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Types = Lane_addon_types
module Store = Lane_addon_store
module Bus = Agent_core.Event_bus
module Events = Lane_addon_resource_events

let unwrap = function Ok value -> value | Error message -> fail message
let member key json = Yojson.Safe.Util.member key json
let text key json = member key json |> Yojson.Safe.Util.to_string
let int key json = member key json |> Yojson.Safe.Util.to_int
let write path bytes =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel bytes)
let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

type fake = {
  calls : (string, int) Hashtbl.t;
  stops : (string, int) Hashtbl.t;
  modes : (string, string) Hashtbl.t;
  recovery : (string * string) list ref;
}

let fake_output : Types.output = {
  rows = [{ id = "raw-event"; lane_id = "fixture/observation"; kind = Types.Event;
    title = "Actual source bytes retained"; observed_at = 1.; subject_id = "target";
    clock = None; actor = None; fields = []; evidence = []; related_ids = [] }];
  coverage = [{source_id="fixture"; incarnation="run-1"; cursor=Some "1";
               complete=true; detail=None}];
}

let make_backend () =
  let state = { calls=Hashtbl.create 4; stops=Hashtbl.create 4; modes=Hashtbl.create 4;
                recovery=ref [] } in
  let backend : Runtime.For_testing.backend = {
    start = (fun ~sw:_ ~instance_id ~(package : Types.package) ~on_created ->
      let released, release = Eio.Promise.create () in
      let stopped = ref false in
      Hashtbl.add state.modes instance_id package.id;
      let connection : Runtime.For_testing.connection = {
        container_id = Store.digest instance_id;
        observe = (fun ~binding:_ ~sources:_ ->
          Hashtbl.replace state.calls instance_id
            (1 + Option.value ~default:0 (Hashtbl.find_opt state.calls instance_id));
          (match package.id with
           | "error" -> Error "observation unavailable"
           | _ -> Ok fake_output));
        stop = (fun () ->
          let count = 1 + Option.value ~default:0 (Hashtbl.find_opt state.stops instance_id) in
          Hashtbl.replace state.stops instance_id count;
          if package.id = "stop-retry" && count = 1 then Error "cleanup refused"
          else begin
            if not !stopped then (stopped := true; Eio.Promise.resolve release ());
            Ok ()
          end)
      } in
      if package.id = "start-error" then Error "startup unavailable"
      else begin
        on_created connection;
        Ok connection
      end);
    acquire = (fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ ->
      Ok (`List [`Assoc ["original_bytes", `String "captured source before rotation"]]));
    recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes:_ ->
      match container_id with
      | Some id when id = Store.digest instance_id ->
          state.recovery := (instance_id, id) :: !(state.recovery); Ok ()
      | None -> Error "Docker recovery unavailable"
      | Some _ -> Error "owner mismatch")
  } in state, backend

let manifest dir mode =
  let path = Filename.concat dir (mode ^ ".toml") in
  write path (Printf.sprintf {|id = %S
revision = "fixture-1"
title = "Lifecycle fixture"
image = "fixture/image"
command = ["observer"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
|} mode);
  path

let dispatch config operation fields = Runtime.dispatch ~config ~operation (`Assoc fields)
let inspect config = unwrap (dispatch config Runtime.Inspect [])
let instance config id =
  inspect config |> member "instances" |> Yojson.Safe.Util.to_list
  |> List.find (fun value -> text "instance_id" value = id)
let phase value = text "kind" (member "phase" value)
let attach config dir mode =
  unwrap (dispatch config Runtime.Attach ["manifest_path", `String (manifest dir mode);
    "run_id", `String "world"; "binding", `Assoc ["sources", `List []]])
  |> text "instance_id"
let detach config id = ignore (unwrap (dispatch config Runtime.Detach ["instance_id", `String id]))
let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001; loop ()) in loop ()
let await_phase clock config id expected = await clock (fun () -> phase (instance config id) = expected)

let correlation_of (meta : Agent_core.Event_envelope.t) =
  let { Agent_core.Event_envelope.correlation_id; _ } = meta in correlation_id
let resource_events sub =
  Runtime_event_bus.drain sub |> List.filter_map (fun (event : Bus.event) ->
    match event.payload with
    | Bus.Custom (name, payload) when String.starts_with ~prefix:"masc.lane.resource." name ->
      Some (name, payload, correlation_of event.meta)
    | _ -> None)
let names events = List.map (fun (name, _, _) -> name) events
let event_names events = String.concat "," (names events)

let with_fixture f =
  let dir = Filename.temp_file "lane-resource-" ".fixture" in
  Sys.remove dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Runtime.For_testing.reset ();
              let bus = Bus.create () in
              Event_bus_slots.set_masc bus;
              let sub = Runtime_event_bus.subscribe bus ~capacity:64
                ~overflow:Bus.Drop_oldest ~purpose:"lane_resource_events_test" in
              let state, backend = make_backend () in
              Runtime.For_testing.with_backend backend (fun () ->
                f env sw (Workspace.default_config dir) dir state sub))))))

let test_wire_names_are_pinned () =
  check string "acquired" "masc.lane.resource.acquired" (Events.wire_name Events.Acquired);
  check string "acquire_failed" "masc.lane.resource.acquire_failed"
    (Events.wire_name Events.Acquire_failed);
  check string "release_confirmed" "masc.lane.resource.release_confirmed"
    (Events.wire_name Events.Release_confirmed);
  check string "release_incomplete" "masc.lane.resource.release_incomplete"
    (Events.wire_name Events.Release_incomplete)

let test_attach_publishes_acquired_with_observed_identity () =
  with_fixture (fun env _ config dir _ sub ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    (match resource_events sub with
     | [ (name, payload, correlation) ] ->
       check string "acquired announced once" "masc.lane.resource.acquired" name;
       check string "correlation binds the instance lifetime" id correlation;
       check string "container identity is the observed one" (Store.digest id)
         (text "container_id" payload);
       check string "run identifies the observation bundle" "world" (text "run_id" payload);
       check string "package is named" "good" (text "package_id" payload)
     | events -> fail ("unexpected resource events: " ^ event_names events));
    detach config id;
    await_phase clock config id "detached")

let test_start_failure_publishes_acquire_failed_without_identity () =
  with_fixture (fun env _ config dir _ sub ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "start-error" in
    await_phase clock config id "failed";
    (match resource_events sub with
     | [ (name, payload, _) ] ->
       check string "acquire failure announced" "masc.lane.resource.acquire_failed" name;
       check string "no fabricated identity" "null"
         (Yojson.Safe.to_string (member "container_id" payload));
       check string "failure reason retained" "startup unavailable" (text "detail" payload)
     | events -> fail ("unexpected resource events: " ^ event_names events)))

let test_stop_refusal_publishes_incomplete_then_one_confirmation () =
  with_fixture (fun env _ config dir _ sub ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "stop-retry" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    detach config id;
    await_phase clock config id "failed";
    detach config id;
    await_phase clock config id "detached";
    check (list string) "acquired, one incomplete, one confirmation"
      [ "masc.lane.resource.acquired";
        "masc.lane.resource.release_incomplete";
        "masc.lane.resource.release_confirmed" ]
      (names (resource_events sub)))

let test_detach_without_identity_publishes_unverified_cleanup () =
  with_fixture (fun env _ config dir _ sub ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "start-error" in
    await_phase clock config id "failed";
    (* The worker fiber may still be closing its switch; wait until the
       entry reports itself stopped before detaching. *)
    await clock (fun () ->
      Result.is_error (dispatch config Runtime.Observe ["instance_id", `String id]));
    detach config id;
    await_phase clock config id "failed";
    check string "unverified phase recorded" "failed" (phase (instance config id));
    let events = resource_events sub in
    check (list string) "acquire failure then unverified release"
      [ "masc.lane.resource.acquire_failed";
        "masc.lane.resource.release_incomplete" ]
      (names events);
    match events with
    | [ _; (_, payload, _) ] ->
      check string "identity stays null" "null"
        (Yojson.Safe.to_string (member "container_id" payload));
      check string "unverified reason retained"
        "Docker recovery unavailable"
        (text "detail" payload)
    | events -> fail ("unexpected resource events: " ^ event_names events))

let test_recovery_publishes_release_confirmed_for_persisted_identity () =
  with_fixture (fun env _ config dir state sub ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let captured = instance config id in
    (* Release the live worker first, then model a host restart: the
       persisted binding is replayed as Attached and no live worker exists. *)
    detach config id;
    await_phase clock config id "detached";
    Runtime.For_testing.reset ();
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    let fields = Yojson.Safe.Util.to_assoc captured in
    unwrap (Store.save_binding store ~instance_id:id
      (`Assoc (("phase", Types.phase_to_json Types.Attached) :: List.remove_assoc "phase" fields)));
    detach config id;
    await_phase clock config id "detached";
    check Alcotest.int "one exact persisted-container recovery" 1 (List.length !(state.recovery));
    let events = resource_events sub in
    check (list string) "live release then recovery release"
      [ "masc.lane.resource.acquired";
        "masc.lane.resource.release_confirmed";
        "masc.lane.resource.release_confirmed" ]
      (names events);
    match List.rev events with
    | (_, payload, _) :: _ ->
      check string "persisted identity is reused" (Store.digest id)
        (text "container_id" payload)
    | [] -> fail "no resource events")

let () = run "Lane Add-on resource events" [
  "wire names", [
    test_case "the four wire names are pinned" `Quick test_wire_names_are_pinned ];
  "lifecycle", [
    test_case "attach announces the observed container identity" `Quick
      test_attach_publishes_acquired_with_observed_identity;
    test_case "start failure announces no fabricated identity" `Quick
      test_start_failure_publishes_acquire_failed_without_identity;
    test_case "stop refusal announces incomplete then one confirmation" `Quick
      test_stop_refusal_publishes_incomplete_then_one_confirmation;
    test_case "detach without identity announces unverified cleanup" `Quick
      test_detach_without_identity_publishes_unverified_cleanup;
    test_case "recovery confirms the persisted container release" `Quick
      test_recovery_publishes_release_confirmed_for_persisted_identity ]]
