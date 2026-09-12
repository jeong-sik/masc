(** Optional observer lifecycle through the public dispatch surface. The fake
    package supplies barriers; no model response or Docker daemon is involved. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Types = Lane_addon_types
module Store = Lane_addon_store

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
        action_schema = (fun () -> None);
        act = (fun ~arguments:_ -> Error "read-only fixture");
        observe = (fun ~binding:_ ~sources:_ ->
          Hashtbl.replace state.calls instance_id
            (1 + Option.value ~default:0 (Hashtbl.find_opt state.calls instance_id));
          match package.id with
          | "hang" -> Eio.Promise.await released; Error "observer stopped"
          | "error" -> Error "observation unavailable"
          | _ -> Ok fake_output);
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
        if package.id = "start-hang" then
          (Eio.Promise.await released; Error "initialization stopped")
        else Ok connection
      end);
    acquire = (fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ ->
      Ok (`List [`Assoc ["original_bytes", `String "captured source before rotation"]]));
    recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes:_ ->
      match container_id with
      | Some id when id = Store.digest instance_id ->
          state.recovery := (instance_id, id) :: !(state.recovery); Ok ()
      | Some _ | None -> Error "owner mismatch")
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
let with_fixture f =
  let dir = Filename.temp_file "lane-runtime-" ".fixture" in
  Sys.remove dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15. (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Runtime.For_testing.reset ();
              let state, backend = make_backend () in
              Runtime.For_testing.with_backend backend (fun () ->
                f env sw (Workspace.default_config dir) dir state))))))

let test_hang_error_coalescing_and_primary_progress () = with_fixture (fun env sw config dir state ->
  let clock = Eio.Stdenv.clock env in
  let blocked = attach config dir "hang" in
  await clock (fun () -> Hashtbl.mem state.calls blocked);
  let good = attach config dir "good" in
  await clock (fun () -> int "observation_seq" (instance config good) = 1);
  let failed = attach config dir "error" in
  await_phase clock config failed "failed";
  let primary = Eio.Fiber.fork_promise ~sw (fun () -> "primary action completed") in
  check string "primary work completes before observer release"
    "primary action completed" (Eio.Promise.await_exn primary);
  check Alcotest.int "blocked observation has not been released" 0
    (Option.value ~default:0 (Hashtbl.find_opt state.stops blocked));
  Runtime.notify_activity ~config;
  Runtime.notify_activity ~config;
  Runtime.notify_activity ~config;
  check bool "coalesced notifications are visible" true
    (int "coalesced_wakes" (instance config blocked) >= 2);
  detach config blocked;
  await_phase clock config blocked "detached";
  ignore (unwrap (dispatch config Runtime.Observe ["instance_id", `String good]));
  await clock (fun () -> int "observation_seq" (instance config good) >= 2);
  detach config good; detach config failed;
  await_phase clock config good "detached";
  await_phase clock config failed "detached")

let test_start_and_cleanup_failures_remain_optional () = with_fixture (fun env _ config dir state ->
  let clock = Eio.Stdenv.clock env in
  let initializing = attach config dir "start-hang" in
  await clock (fun () -> Hashtbl.mem state.modes initializing);
  detach config initializing;
  await_phase clock config initializing "detached";
  let startup_error = attach config dir "start-error" in
  await_phase clock config startup_error "failed";
  (* Its worker fiber may still be closing the independent switch. *)
  await clock (fun () -> Result.is_error
    (dispatch config Runtime.Observe ["instance_id", `String startup_error]));
  let retry = attach config dir "stop-retry" in
  await clock (fun () -> int "observation_seq" (instance config retry) = 1);
  detach config retry;
  await_phase clock config retry "failed";
  detach config retry;
  await_phase clock config retry "detached")

let test_evidence_is_optional_retained_and_delivery_is_only_acceptance () =
  with_fixture (fun env _ config dir state ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let selected = inspect config |> member "rows" |> Yojson.Safe.Util.to_list |> List.hd
      |> text "id" in
    let args = ["instance_id", `String id; "row_ids", `List [`String selected]] in
    let frozen = unwrap (dispatch config Runtime.Evidence args) in
    let evidence = member "evidence" frozen in
    let bytes = In_channel.with_open_bin (text "path" evidence) In_channel.input_all in
    check string "frozen bytes match evidence digest" (text "sha256" evidence) (Store.digest bytes);
    let bundle = Yojson.Safe.from_string bytes in
    check string "package revision pinned in bundle" "fixture-1"
      (bundle |> member "binding" |> member "package" |> text "revision");
    check bool "raw source bytes retained" true
      (bundle |> member "observations" |> Yojson.Safe.Util.to_list <> []);
    (* Merely selecting or ignoring evidence creates no confirmation gate. *)
    ignore (unwrap (dispatch config Runtime.Observe ["instance_id", `String id]));
    await clock (fun () -> int "observation_seq" (instance config id) = 2);
    let unavailable = unwrap (Runtime.dispatch ~caller:"operator" ~config ~operation:Runtime.Evidence
      (`Assoc (("keeper_name", `String "keeper") :: args))) in
    check string "unavailable delivery stays explicit" "failed"
      (unavailable |> member "delivery" |> text "status");
    check bool "failed delivery retains evidence" true
      (Sys.file_exists (unavailable |> member "evidence" |> text "path"));
    let delivered = ref [] in
    Runtime.register_delivery_handler (fun ~config:_ ~caller ~keeper_name ~prompt ->
      delivered := (caller, keeper_name, prompt) :: !delivered;
      Ok (`Assoc ["request_id", `String "keeper-request"; "status", `String "deferred"]));
    let accepted = unwrap (Runtime.dispatch ~caller:"operator" ~config ~operation:Runtime.Evidence
      (`Assoc (("keeper_name", `String "keeper") :: args))) in
    check Alcotest.int "one explicitly requested delivery" 1 (List.length !delivered);
    check string "acceptance keeps deferred receipt" "deferred"
      (accepted |> member "delivery" |> member "receipt" |> text "status");
    let sender, keeper, prompt = List.hd !delivered in
    check string "original authenticated sender preserved" "operator" sender;
    check string "explicitly selected Keeper preserved" "keeper" keeper;
    (match Tool_output.decode_from_agent_core prompt with
     | Tool_output.Decoded reference ->
         check string "message preserves the exact retention marker"
           (Tool_output.encode_for_agent_core (Tool_output.Stored reference)) prompt;
         check string "message names a traversable evidence manifest"
           Tool_output.artifact_manifest_mime reference.mime;
         check bool "result preserves the same normalized manifest reference" true
           (member "keeper_artifact" accepted = Tool_output.normalized_artifact_ref_to_json reference)
     | _ -> fail "Keeper evidence was not delivered as a readable artifact");
    detach config id; await_phase clock config id "detached";
    await clock (fun () ->
      inspect config |> member "rows" |> Yojson.Safe.Util.to_list = []);
    let historical_slice = unwrap (dispatch config Runtime.Slice []) in
    check bool "detached rows leave active memory but remain queryable" true
      (historical_slice |> member "rows" |> Yojson.Safe.Util.to_list
       |> List.exists (fun row -> text "id" row = selected));
    let captured = instance config id in
    Runtime.For_testing.reset ();
    check string "confirmed detach survives process restart" "detached" (phase (instance config id));
    let retained = unwrap (dispatch config Runtime.Evidence args) in
    check bool "historical evidence can still be opened" true
      (Sys.file_exists (retained |> member "evidence" |> text "path"));
    (* Replay a persisted running binding to model a host restart. No live
       worker exists; recovery must use its persisted exact ownership. *)
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    let fields = Yojson.Safe.Util.to_assoc captured in
    unwrap (Store.save_binding store ~instance_id:id
      (`Assoc (("phase", Types.phase_to_json Types.Attached) :: List.remove_assoc "phase" fields)));
    detach config id; await_phase clock config id "detached";
    check Alcotest.int "one exact persisted-container recovery" 1 (List.length !(state.recovery)))

let () = run "Lane Add-on runtime" ["optional extension", [
  test_case "hung and failed observers preserve primary progress" `Quick test_hang_error_coalescing_and_primary_progress;
  test_case "startup and cleanup failures stay local" `Quick test_start_and_cleanup_failures_remain_optional;
  test_case "evidence remains optional and durable across detach" `Quick test_evidence_is_optional_retained_and_delivery_is_only_acceptance;
]]
