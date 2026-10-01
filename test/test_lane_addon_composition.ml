(** TOML edges deliver one installed package's completed output to another
    through the real source adapter. Only external worker processes are fake. *)
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
let unwrap = function Ok value -> value | Error message -> fail message
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let list key json = member key json |> Yojson.Safe.Util.to_list
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name)); Unix.rmdir path
  | _ -> Unix.unlink path
let output : Types.output = {
  rows=[{id="row";lane_id="arbitrary-domain";kind=Types.Value;title="Actual supplied value";
    observed_at=10.;subject_id="subject";clock=Some {domain="frame/history-a";value="7"};
    actor=Some "fixture-observer";fields=["value",`Int 7];evidence=[];related_ids=[]}];
  coverage=[{source_id="fixture";incarnation="history-a";cursor=Some "7";complete=true;detail=None}]
}
let dispatch config operation fields = Runtime.dispatch ~config ~operation (`Assoc fields) |> unwrap
let inspect config = dispatch config Runtime.Inspect []
let instance config id = inspect config |> list "instances" |> List.find (fun json -> text "instance_id" json = id)
let active config name = inspect config |> list "instances" |> List.find (fun json ->
  text "kind" (member "phase" json) <> "detached" && text "id" (member "configuration" json) = name)
let await clock f = let rec loop () = if f () then () else (Eio.Time.sleep clock 0.001; loop ()) in loop ()
(* The resolver trims empty environment values. Restore the previous value
   after Eio has stopped, and never reuse an inherited runtime config root. *)
let with_environment name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f
let with_fixture ?produce_package ?(produce=(fun ~binding:_ ~sources:_ -> output)) ?(allow_stop=ref true)
    ?(stop_attempts=ref []) f =
  let root = Filename.temp_dir "lane-composition-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let masc = Filename.concat root ".masc" in
    let config_root = Filename.concat masc "config" in
    let directory = Filename.concat config_root "lane-addons" in
    Unix.mkdir masc 0o700; Unix.mkdir config_root 0o700; Unix.mkdir directory 0o700;
    with_environment "MASC_CONFIG_DIR" config_root (fun () ->
      with_environment "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          let clock = Eio.Stdenv.clock env in
          Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
            Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
              ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Runtime.For_testing.reset ();
              Runtime.register_fleet_backend {snapshot=(fun ~config:_ ~caller:_ -> Ok (Masc.Lane_addon_broadcast_delivery.External_sender,[]));
                project=(fun ~config:_ ~sender_authority:_ ~delivery:_ ~recipient:_ -> Error "empty fixture fleet has no recipient")};
              let config = Workspace.default_config root in
              check string "configuration resolves only to this owned fixture"
                directory (Runtime.configuration_directory config);
              let received = Hashtbl.create 4 and stopped = ref [] in
              let backend : Runtime.For_testing.backend = {
                start=(fun ~sw:_ ~instance_id ~package ~on_created ->
                  let connection : Runtime.For_testing.connection = {
                    container_id=Store.digest instance_id;
                    action_schema = (fun () -> None);
                    act = (fun ~arguments:_ -> Error "read-only fixture");
                    observe=(fun ~binding ~sources ->
                      Hashtbl.replace received instance_id sources;
                      Ok (match produce_package with
                        | Some produce_package -> produce_package package ~binding ~sources
                        | None -> produce ~binding ~sources));
                    stop=(fun () ->
                      stop_attempts := instance_id :: !stop_attempts;
                      if not !allow_stop then Error "fixture cleanup unavailable"
                      else (stopped := instance_id :: !stopped; Ok ()))} in
                  on_created connection; Ok connection);
                image_ready=(fun ~package:_ -> Ok ());
                acquire=Lane_addon_sources.acquire;
                recover_stop=(fun ~instance_id:_ ~container_id:_ ~max_reply_bytes:_ -> Ok ())} in
              Runtime.For_testing.with_backend backend (fun () ->
                (* Exceptional exits cancel the Eio switch before the outer
                   cleanup removes this fresh directory. Normal exits retire
                   only TOML files in our independently computed owned path. *)
                let result = f clock config root directory received stopped in
                allow_stop := true;
                Sys.readdir directory |> Array.iter (fun name ->
                  if Filename.check_suffix name ".toml" then Unix.unlink (Filename.concat directory name));
                ignore (unwrap (Runtime.reconcile_configuration ~config ~directory));
                await clock (fun () -> inspect config |> list "instances" |> List.for_all (fun json ->
                  text "kind" (member "phase" json) = "detached"));
                result))))))))
let manifest ?(name="package") ?(outputs="") ?(max_reply_bytes=16384) root =
  let path = Filename.concat root (name ^ ".toml") in
  write path (Printf.sprintf {|id="generic-package"
revision="1"
title="Generic output"
image="not-executed"
command=["not-executed"]
contributions=["observe"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=%d
|} max_reply_bytes ^ outputs); path
let declare ?(run="world") ?(value="initial") directory manifest id sources =
  let path = Filename.concat directory (id ^ ".toml") in
  write path (Printf.sprintf {|id=%S
run_id=%S
manifest_path=%S
[binding]
value=%S
sources=%s
|} id run manifest value sources); path
let edge ?output_id id = Printf.sprintf {|[{source_id="upstream",kind="lane_output",installation_id=%S,selection="latest_completed"%s}]|}
  id (Option.fold ~none:"" ~some:(Printf.sprintf ",output_id=%S") output_id)
let reconcile config directory = let _status = unwrap (Runtime.reconcile_configuration ~config ~directory) in ()
let source received id = match Hashtbl.find_opt received id with
  | Some (`List [value]) -> Some value | _ -> None
let require_some label = function Some value -> value | None -> fail label
let completed received id = Option.bind (source received id) (fun source ->
  match list "observations" source with [observation] -> Some observation | _ -> None)

let test_namespace_overhead_does_not_consume_package_capacity () =
  let original = List.hd output.rows in
  let related_ids = List.init 1024 string_of_int in
  let local_row = {original with Types.related_ids;
    fields=["body", `String (String.make 4096 'x')]} in
  let supplied = ref {output with rows=[local_row]} in
  let cap = String.length (Yojson.Safe.to_string (Types.output_to_json !supplied)) in
  with_fixture ~produce:(fun ~binding:_ ~sources:_ -> !supplied)
    (fun clock config root directory _received _stopped ->
      let manifest = manifest ~max_reply_bytes:cap root in
      let _path = declare directory manifest "near-limit" "[]" in
      reconcile config directory;
      let id = active config "near-limit" |> text "instance_id" in
      await clock (fun () -> member "observation_seq" (instance config id) = `Int 1);
      let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      let observed = unwrap (Store.read_observation ~instance_id:id ~seq:1 ~max_bytes:cap store)
        |> Types.output_to_json in
      check bool "host prefixes exceed package wire cap" true
        (String.length (Yojson.Safe.to_string observed) > 2 * cap);
      let row = List.hd (list "rows" observed) in
      check string "row remains namespaced" (id ^ "/1/row") (text "id" row);
      check string "lane remains namespaced" (id ^ "/arbitrary-domain") (text "lane_id" row);
      check (Alcotest.list string) "all relations remain namespaced"
        (List.map (fun related -> id ^ "/1/" ^ related) related_ids)
        (list "related_ids" row |> List.map Yojson.Safe.Util.to_string);
      supplied := {output with rows=[{local_row with fields=["body", `String (String.make (cap + 1) 'x')]}]};
      ignore (dispatch config Runtime.Observe ["instance_id", `String id]);
      await clock (fun () -> text "kind" (member "phase" (instance config id)) = "failed");
      check bool "oversized package data was not committed" true
        (member "observation_seq" (instance config id) = `Int 1))

let test_toml_output_connection_and_retained_provenance () = with_fixture (fun clock config root directory received stopped ->
  let manifest = manifest root in
  let consumer_path = declare directory manifest "a-consumer" (edge "z-producer") in
  let _producer_path = declare directory manifest "z-producer" "[]" in
  reconcile config directory;
  let consumer = active config "a-consumer" |> text "instance_id" in
  let producer = active config "z-producer" |> text "instance_id" in
  await clock (fun () -> Option.is_some (completed received consumer));
  let observed = require_some "consumer has no completed upstream input" (completed received consumer) in
  check string "edge resolved the installed producer" producer (text "instance_id" (member "producer" observed));
  let rows = member "output" observed |> list "rows" in
  let row = List.hd rows in
  check string "upstream row identity survives crossing" (producer ^ "/1/row") (text "id" row);
  check string "frame clock stays in its original domain" "frame/history-a" (member "clock" row |> text "domain");
  check string "actual observer is not consumer runtime" "fixture-observer" (text "actor" row);
  let reference = list "evidence" observed |> List.hd in
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let bytes = unwrap (Store.read_blob store {Types.uri=text "uri" reference;sha256=Some (text "sha256" reference)}) in
  check string "frozen output evidence matches returned hash" (Store.digest bytes) (text "sha256" reference);
  check string "frozen output has original row identity" (producer ^ "/1/row")
    (Yojson.Safe.from_string bytes |> member "output" |> list "rows" |> List.hd |> text "id");
  let _queued = dispatch config Runtime.Observe ["instance_id",`String producer] in
  await clock (fun () -> match completed received consumer with
    | Some observation -> member "observation_seq" (member "producer" observation) = `Int 2
    | None -> false);
  check bool "producer completion automatically wakes its consumer" true
    (Option.is_some (completed received consumer));
  Sys.remove consumer_path; reconcile config directory;
  await clock (fun () -> List.mem consumer !stopped);
  check bool "consumer removal preserves upstream owner" false (List.mem producer !stopped);
  let _queued = dispatch config Runtime.Observe ["instance_id",`String producer] in
  await clock (fun () -> member "observation_seq" (instance config producer) = `Int 3))

let test_cycle_and_cross_run_are_local_to_connections () = with_fixture (fun clock config root directory received _ ->
  let manifest = manifest root in
  let _producer_path = declare directory manifest "producer" "[]" in
  let _other_path = declare ~run:"other-world" directory manifest "other-consumer" (edge "producer") in
  let _loop_path = declare directory manifest "loop" (edge "loop") in
  reconcile config directory;
  let producer = active config "producer" |> text "instance_id" in
  let consumer = active config "other-consumer" |> text "instance_id" in
  await clock (fun () -> Hashtbl.mem received producer && Hashtbl.mem received consumer
    && (member "observation_seq" (instance config producer) |> Yojson.Safe.Util.to_int) > 0);
  let source = require_some "consumer received no source envelope" (source received consumer) in
  check bool "another world is not silently joined" false (member "complete" source |> Yojson.Safe.Util.to_bool);
  check int "different-run input has no fabricated output" 0 (list "observations" source |> List.length);
  let issues = inspect config |> member "configuration" |> list "issues" in
  check bool "self-dependent installation reports its own error" true
    (List.exists (fun issue -> member "id" issue = `String "loop") issues);
  check bool "invalid edge does not suppress ordinary producer output" true
    (member "observation_seq" (instance config producer) <> `Int 0))

let test_invalid_cycle_edit_preserves_applied_producer_and_consumer () =
  with_fixture (fun clock config root directory received stopped ->
    let manifest = manifest root in
    let _a = declare directory manifest "A" "[]" in
    let _b = declare directory manifest "B" (edge "A") in
    reconcile config directory;
    let a = active config "A" |> text "instance_id" in
    let b = active config "B" |> text "instance_id" in
    await clock (fun () -> Option.is_some (completed received b));
    let before = instance config a in
    let seq = member "observation_seq" before |> Yojson.Safe.Util.to_int in
    let row_ids () = inspect config |> list "rows" |> List.filter (fun row ->
      text "lane_id" row = a ^ "/arbitrary-domain") |> List.map (text "id") in
    let retained_ids = row_ids () in
    let _edited_a = declare directory manifest "A" (edge "B") in
    reconcile config directory;
    reconcile config directory;
    let issues = inspect config |> member "configuration" |> list "issues" in
    check bool "cyclic desired edit is reported on A" true
      (List.exists (fun issue -> member "id" issue = `String "A") issues);
    check string "invalid desired cycle keeps applied A identity" a (active config "A" |> text "instance_id");
    check string "invalid desired cycle keeps B identity" b (active config "B" |> text "instance_id");
    check bool "preflight does not retire the healthy producer" false (List.mem a !stopped);
    check bool "preflight does not retire its working consumer" false (List.mem b !stopped);
    check (Alcotest.list string) "existing A rows survive the rejected edit" retained_ids (row_ids ());
    check bool "applied binding was not replaced by invalid desired inputs" true
      (member "binding" (instance config a) = member "binding" before);
    let _queued = dispatch config Runtime.Observe ["instance_id", `String a] in
    await clock (fun () -> match completed received b with
      | Some observed -> member "observation_seq" (member "producer" observed) = `Int (seq + 1)
      | None -> false);
    check string "B continues receiving A's applied output" a
      (require_some "B lost its completed input" (completed received b) |> member "producer" |> text "instance_id"))

let test_partial_input_recovers_and_replacement_keeps_exact_coordinates () =
  let partial = ref false in
  let produce ~binding ~sources:_ =
    let replacing = member "value" binding = `String "replacement" in
    let history, value = if replacing then "history-b", "2" else "history-a", "7" in
    { Types.rows = List.map (fun (row : Types.row) ->
        {row with clock=Some {domain="frame/" ^ history; value}}) output.rows;
      coverage = [{source_id="fixture";incarnation=history;cursor=Some value;
        complete=not !partial;detail=(if !partial then Some "fixture input incomplete" else None)}] }
  in
  with_fixture ~produce (fun clock config root directory received _ ->
    let manifest = manifest root in
    let _producer_path = declare directory manifest "producer" "[]" in
    let _consumer_path = declare directory manifest "consumer" (edge "producer") in
    reconcile config directory;
    let producer = active config "producer" |> text "instance_id" in
    let consumer = active config "consumer" |> text "instance_id" in
    await clock (fun () -> Option.is_some (completed received consumer));
    let old_revision = instance config producer |> member "configuration" |> text "revision" in
    partial := true;
    let _queued = dispatch config Runtime.Observe ["instance_id", `String producer] in
    await clock (fun () -> match completed received consumer, source received consumer with
      | Some observed, Some envelope ->
          member "observation_seq" (member "producer" observed) = `Int 2
          && member "complete" envelope = `Bool false
      | _ -> false);
    let partial_input = require_some "partial output was discarded" (completed received consumer) in
    check int "partial coverage preserves the actual supplied row" 1
      (partial_input |> member "output" |> list "rows" |> List.length);
    check bool "producer source coverage remains partial" true
      (partial_input |> member "output" |> list "coverage" |> List.exists (fun value -> member "complete" value = `Bool false));
    check string "partial output retains original producer identity" producer
      (partial_input |> member "producer" |> text "instance_id");
    partial := false;
    let _queued = dispatch config Runtime.Observe ["instance_id", `String producer] in
    await clock (fun () -> match completed received consumer, source received consumer with
      | Some observed, Some envelope ->
          member "observation_seq" (member "producer" observed) = `Int 3
          && member "complete" envelope = `Bool true
      | _ -> false);
    let _replacement = declare ~value:"replacement" directory manifest "producer" "[]" in
    reconcile config directory;
    await clock (fun () ->
      text "kind" (member "phase" (instance config producer)) = "detached"
      && (inspect config |> list "rows" |> List.for_all (fun row ->
        text "lane_id" row <> producer ^ "/arbitrary-domain")));
    reconcile config directory;
    let replacement = active config "producer" |> text "instance_id" in
    check bool "producer replacement has a new instance" true (replacement <> producer);
    await clock (fun () -> match completed received consumer with
      | Some observed -> text "instance_id" (member "producer" observed) = replacement
      | None -> false);
    let observed = require_some "replacement output missing" (completed received consumer) in
    let coordinates = member "producer" observed in
    let row = observed |> member "output" |> list "rows" |> List.hd in
    check string "consumer is preserved across producer replacement" consumer (active config "consumer" |> text "instance_id");
    check string "stable installation is explicit" "producer" (text "installation_id" coordinates);
    check string "run identity survives crossing" "world" (text "run_id" coordinates);
    check string "package revision remains explicit" "1" (text "package_revision" coordinates);
    check int "new instance starts its own output sequence" 1 (member "observation_seq" coordinates |> Yojson.Safe.Util.to_int);
    check bool "configuration revision changes with the producer binding" true
      (text "configuration_revision" coordinates <> old_revision);
    check string "observed configuration revision equals the applied producer"
      (instance config replacement |> member "configuration" |> text "revision")
      (text "configuration_revision" coordinates);
    check string "source envelope uses replacement incarnation" replacement
      (require_some "replacement source envelope missing" (source received consumer) |> text "incarnation");
    check string "upstream row reference belongs to replacement sequence" (replacement ^ "/1/row") (text "id" row);
    check string "replacement clock retains its own domain" "frame/history-b" (member "clock" row |> text "domain");
    check string "replacement clock is not confused with old progress" "2" (member "clock" row |> text "value"))

let test_refused_cleanup_invalidates_downstream_input_without_stopping_it () =
  let allow_stop = ref true and attempts = ref [] in
  with_fixture ~allow_stop ~stop_attempts:attempts (fun clock config root directory received stopped ->
    let manifest = manifest root in
    let producer_path = declare directory manifest "producer" "[]" in
    let _consumer_path = declare directory manifest "consumer" (edge "producer") in
    reconcile config directory;
    let producer = active config "producer" |> text "instance_id" in
    let consumer = active config "consumer" |> text "instance_id" in
    await clock (fun () -> Option.is_some (completed received consumer));
    allow_stop := false;
    Sys.remove producer_path;
    reconcile config directory;
    await clock (fun () -> List.mem producer !attempts
      && text "kind" (member "phase" (instance config producer)) = "failed");
    await clock (fun () -> match source received consumer with
      | Some envelope -> member "complete" envelope = `Bool false && list "observations" envelope = []
      | None -> false);
    check bool "producer cleanup has not been confirmed" false (List.mem producer !stopped);
    check bool "downstream owner was not stopped by upstream cleanup failure" false (List.mem consumer !stopped);
    check string "downstream instance remains available" consumer (active config "consumer" |> text "instance_id");
    let seq = instance config consumer |> member "observation_seq" |> Yojson.Safe.Util.to_int in
    let _queued = dispatch config Runtime.Observe ["instance_id", `String consumer] in
    await clock (fun () -> (member "observation_seq" (instance config consumer) |> Yojson.Safe.Util.to_int) > seq);
    let unavailable = require_some "missing unavailable source envelope" (source received consumer) in
    check bool "re-reading unresolved ownership remains explicitly unavailable" true
      (member "complete" unavailable = `Bool false && list "observations" unavailable = []);
    allow_stop := true;
    reconcile config directory;
    await clock (fun () -> List.mem producer !stopped);
    check string "successful upstream cleanup still preserves consumer" consumer (active config "consumer" |> text "instance_id"))

(* Run the shipped generic statistics implementation on host-acquired sources.
   The process is a test-owned calculator; it does not start an emulator or model. *)
let statistics sources =
  let package = match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root "addons/output-statistics/server.py"
    | None -> Filename.concat (Filename.dirname Sys.executable_name) "../addons/output-statistics/server.py" in
  let script = {|import json, runpy, sys
module = runpy.run_path(sys.argv[1])
from protocol import sources_from_json
print(json.dumps(module["observe"]({}, sources_from_json(json.loads(sys.argv[2])))))
|} in
  Eio_unix.run_in_systhread (fun () ->
    let channel = Unix.open_process_args_in "python3"
      [|"python3"; "-c"; script; package; Yojson.Safe.to_string sources|] in
    let bytes = match In_channel.input_all channel with
      | bytes -> bytes
      | exception exn -> ignore (Unix.close_process_in channel); raise exn in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> unwrap (Types.output_of_json (Yojson.Safe.from_string bytes))
    | status -> failf "statistics fixture process failed: %s"
        (match status with Unix.WEXITED n -> "exit " ^ string_of_int n
         | Unix.WSIGNALED n -> "signal " ^ string_of_int n | Unix.WSTOPPED n -> "stopped " ^ string_of_int n))

let test_named_output_flows_to_statistics_and_mapping_revision () =
  let partial = ref false in
  let produce ~binding ~sources =
    if member "value" binding = `String "statistics" then statistics sources
    else { Types.rows = [
      { (List.hd output.rows) with id="frame";lane_id="msx/frame" };
      { (List.hd output.rows) with id="state";lane_id="msx/state";kind=Types.Event }];
      coverage=List.map (fun (c : Types.coverage) -> {c with complete=not !partial;
        detail=(if !partial then Some "unselected state input incomplete" else None)}) output.coverage } in
  with_fixture ~produce (fun clock config root directory received _ ->
    let ports lane = Printf.sprintf "\n[world.outputs.frames]\nlanes=[%S]\n" lane in
    let producer_manifest = manifest ~name:"producer" ~outputs:(ports "msx/frame") root in
    let consumer_manifest = manifest ~name:"consumer" root in
    let _producer_file = declare directory producer_manifest "producer" "[]" in
    let _consumer_file = declare ~value:"statistics" directory consumer_manifest "consumer" (edge ~output_id:"frames" "producer") in
    reconcile config directory;
    let producer = active config "producer" |> text "instance_id" in
    let consumer = active config "consumer" |> text "instance_id" in
    let stats () = inspect config |> list "rows" |> List.find_opt (fun row ->
      text "lane_id" row = consumer ^ "/outputs/producer/statistics") in
    await clock (fun () -> Option.is_some (stats ()));
    let fields () = require_some "statistics row missing" (stats ()) |> member "fields" in
    check int "only selected lane reaches real generic statistics" 1
      (fields () |> member "observed_row_count" |> Yojson.Safe.Util.to_int);
    check string "the selected producer lane is retained" (producer ^ "/msx/frame")
      (fields () |> list "upstream_rows" |> List.hd |> text "lane_id");
    check string "statistics retains the selected public port" "frames"
      (fields () |> member "producer" |> text "output_id");
    let before = require_some "captured port input missing" (completed received consumer) in
    let reference = list "evidence" before |> List.hd in
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    let read_evidence () = unwrap (Store.read_blob store
      {Types.uri=text "uri" reference;sha256=Some (text "sha256" reference)}) in
    let frozen = read_evidence () in
    let old_revision = before |> member "producer" |> text "configuration_revision" in
    partial := true;
    let _queued = dispatch config Runtime.Observe ["instance_id",`String producer] in
    await clock (fun () -> match stats () with Some row ->
      let fields = member "fields" row in
      (fields |> member "producer" |> member "observation_seq") = `Int 2
      && member "input_complete" fields = `Bool false | None -> false);
    check int "partial upstream does not fabricate zero or hide supplied rows" 1
      (fields () |> member "observed_row_count" |> Yojson.Safe.Util.to_int);
    partial := false;
    let _updated_manifest = manifest ~name:"producer" ~outputs:(ports "msx/state") root in
    reconcile config directory;
    await clock (fun () -> text "kind" (member "phase" (instance config producer)) = "detached");
    reconcile config directory;
    let replacement = active config "producer" |> text "instance_id" in
    await clock (fun () -> match stats () with Some row ->
      (row |> member "fields" |> member "producer" |> text "instance_id") = replacement
      | None -> false);
    check bool "changed mapping replaces only the producer instance" true (replacement <> producer);
    check string "consumer does not restart for a changed upstream port mapping" consumer
      (active config "consumer" |> text "instance_id");
    check string "new applied mapping selects the other exact lane" (replacement ^ "/msx/state")
      (fields () |> list "upstream_rows" |> List.hd |> text "lane_id");
    check bool "same package revision with different mapping has a new semantic revision" true
      ((fields () |> member "producer" |> text "configuration_revision") <> old_revision);
    check string "previous selected evidence survives producer replacement" frozen (read_evidence ());
    check bool "frozen evidence retains original mapping" true
      ((Yojson.Safe.from_string frozen |> member "producer" |> member "output_selection")
        = `Assoc ["lanes",`List [`String "msx/frame"]]);
    check string "inspection reports applied public port mapping" "msx/state"
      (instance config replacement |> member "package" |> member "outputs" |> member "frames"
        |> list "lanes" |> List.hd |> Yojson.Safe.Util.to_string))

(* The native capture enters the actual shipped observer over MCP stdio. Only
   container ownership is the fixture backend; no Docker isolation is claimed. *)
let msx_observer ~binding ~sources =
  let tests = match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root "addons/tests"
    | None -> Filename.concat (Filename.dirname Sys.executable_name) "../addons/tests" in
  let script = {|import json, sys
sys.path.insert(0, sys.argv[1])
from test_packages import ProtocolCase
print(json.dumps(ProtocolCase().call("msx-observer", json.loads(sys.argv[2]), json.loads(sys.argv[3]))))
|} in
  Eio_unix.run_in_systhread (fun () ->
    let channel = Unix.open_process_args_in "python3"
      [|"python3"; "-c"; script; tests; Yojson.Safe.to_string binding; Yojson.Safe.to_string sources|] in
    let bytes = match In_channel.input_all channel with
      | bytes -> bytes
      | exception exn -> ignore (Unix.close_process_in channel); raise exn in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> unwrap (Types.output_of_json (Yojson.Safe.from_string bytes))
    | _ -> fail "MSX observer stdio process failed")

let test_native_msx_history_crosses_worker_freeze_and_detach () =
  with_fixture ~produce:msx_observer (fun clock config root _directory _received _stopped ->
    let msx = function Ok value -> value | Error error -> fail (Msx_lane.error_to_string error) in
    let ledger_dir = Filename.concat root "native-machine" in
    ignore (msx (Msx_lane.load ~ledger_dir ~roms_dir:None ~cart_path:None ~disk_path:None));
    Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
      let press who name =
        let key = unwrap (Msx_lane.key_of_string name) in
        ignore (msx (Msx_lane.press ~who ~keys:[key] ~hold_frames:1 ~step_frames:2 ~sequence:false)) in
      press "keeper-A" "space";
      let before = msx (Msx_lane.capture_with_identity ()) in
      let expected = List.rev before.input_ledger
        |> List.map (fun entry -> Yojson.Safe.to_string (Msx_lane.entry_json entry) ^ "\n")
        |> String.concat "" in
      let id = dispatch config Runtime.Attach ["manifest_path", `String (manifest root);
        "run_id", `String "native-history"; "binding", `Assoc ["machine_id", `String "workspace-msx";
          "sources", `List [`Assoc ["kind", `String "msx_capture"; "source_id", `String "native"]]]]
        |> text "instance_id" in
      await clock (fun () -> member "observation_seq" (instance config id) = `Int 1);
      let row = inspect config |> list "rows" |> List.hd in
      let reference = unwrap (Types.evidence_of_json (row |> member "fields" |> member "input_ledger" |> member "evidence")) in
      check string "worker preserves exact machine incarnation" before.incarnation
        (row |> member "fields" |> text "machine_incarnation");
      let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      check string "native input records survive the worker" expected (unwrap (Store.read_jsonl store reference));
      let selected = text "id" row in
      let args = ["instance_id", `String id; "row_ids", `List [`String selected]] in
      let frozen = dispatch config Runtime.Evidence args in
      press "keeper-B" "up";
      ignore (dispatch config Runtime.Observe ["instance_id", `String id]);
      await clock (fun () -> member "observation_seq" (instance config id) = `Int 2);
      ignore (dispatch config Runtime.Detach ["instance_id", `String id]);
      await clock (fun () -> text "kind" (member "phase" (instance config id)) = "detached");
      Runtime.For_testing.reset ();
      ignore (dispatch config Runtime.Evidence args);
      let published = unwrap (Store.publish_for_keeper ~base_path:root store frozen) in
      let artifact = match Tool_output.normalized_artifact_ref_of_json (member "keeper_artifact" published) with
        | Tool_output.Decoded_normalized_artifact_ref artifact -> artifact
        | _ -> fail "missing Keeper-readable artifact" in
      let read sha =
        let _, page = Keeper_artifact_read.handle_with_page ~base_path:root
          ~args:(`Assoc ["sha256", `String sha]) in
        match page with Some page when page.eof -> page.content
        | _ -> fail "published sequence node is not readable by the Keeper" in
      let artifacts = match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string (read artifact.sha256)) with
        | Tool_output.Decoded_artifact_manifest {structured_content; _} -> list "artifacts" structured_content
        | _ -> fail "invalid artifact manifest" in
      (* Remove the Lane store: publication must have carried every node, not
         just the captured root whose predecessor still lived in that store. *)
      remove (Store.root store);
      let rec reconstruct count reference records =
        let artifact = List.find (fun item -> text "lane_uri" item = reference.Types.uri) artifacts
          |> member "artifact" in
        let artifact = match Tool_output.normalized_artifact_ref_of_json artifact with
          | Tool_output.Decoded_normalized_artifact_ref reference -> reference
          | Tool_output.Not_normalized_artifact_ref
          | Tool_output.Invalid_normalized_artifact_ref _ ->
              fail "sequence publication has an invalid artifact reference" in
        let node = Yojson.Safe.from_string (read artifact.sha256) in
        check int "published sequence count" count (member "entry_count" node |> Yojson.Safe.Util.to_int);
        if count = 0 then String.concat "" records
        else reconstruct (count - 1) (unwrap (Types.evidence_of_json (member "previous" node)))
            (text "record" node :: records) in
      check string "full original history remains readable after Detach and Lane-store removal"
        expected (reconstruct before.input_count reference [])))

let fusion_package (package : Types.package) ~binding ~sources =
  let tests = Filename.concat package.directory "../tests" in
  let script = {|import json, sys
sys.path.insert(0, sys.argv[1])
from test_packages import ProtocolCase
summaries = {
    "fusion-results": "Fusion status and retained Board evidence are available in structuredContent with exact run identity.",
    "fusion-report": "Fusion reports are retained in structuredContent with exact upstream coordinates and evidence.",
}
output = ProtocolCase().call(sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]),
                             expected_summary=summaries[sys.argv[2]])
assert "rows" in output, output
print(json.dumps(output))
|} in
  Eio_unix.run_in_systhread (fun () ->
    let channel = Unix.open_process_args_in "python3"
      [|"python3"; "-c"; script; tests; package.id;
        Yojson.Safe.to_string binding; Yojson.Safe.to_string sources|] in
    let bytes = match In_channel.input_all channel with
      | bytes -> bytes
      | exception exn -> ignore (Unix.close_process_in channel); raise exn in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> unwrap (Types.output_of_json (Yojson.Safe.from_string bytes))
    | _ -> fail "Fusion package MCP stdio observation failed")

let test_native_fusion_report_is_readable_after_detach () =
  let produce_package (package : Types.package) ~binding ~sources =
    (* The generic manifest names its file separately from its package id. *)
    if package.id = "generic-package" then output
    else fusion_package package ~binding ~sources in
  with_fixture ~produce_package (fun clock config root directory received _stopped ->
    with_environment "MASC_BASE_PATH" root (fun () ->
      let reset_board () = Board_dispatch.reset_for_test (); Board.reset_global_for_test () in
      reset_board ();
      Fun.protect ~finally:reset_board (fun () ->
        ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
        let registry = Fusion_run_registry.global () in
        let run_id = "fusion-chain-" ^ Store.digest root in
        Fusion_run_registry.register_running registry ~run_id ~keeper:"fixture-producer"
          ~preset:"default" ~roster:Fusion_types.preset_roster
          ~topology:Fusion_types.Simple ~started_at:1.;
        let body = "Measured alternative A preserves the original evidence." in
        let synthesis : Fusion_types.judge_synthesis = {
          consensus=[];contradictions=[];partial_coverage=[];unique_insights=[];
          blind_spots=[];resolved_answer=body;decision=Fusion_types.Answer "Alternative A"} in
        let origin : Board.post_origin = {turn_ref=None; source=Some "fusion";
          fusion_run_id=Some run_id; fusion_producer=Some "fixture-producer"} in
        ignore (unwrap (Board_dispatch.create_post_once_by_fusion_run_id ~fusion_run_id:run_id
          ~author:"fixture-producer" ~content:"Fusion deliberation: Alternative A"
          ~meta_json:(`Assoc ["judge",Fusion_sink.judge_meta (Ok synthesis)])
          ~post_kind:Board.System_post ~visibility:Board.Unlisted ~ttl_hours:0 ~origin ()
          |> Result.map_error Board.show_board_error));
        Fusion_run_registry.mark_completed registry ~run_id ~outcome:Fusion_run_registry.Succeeded;
        let addons = match Sys.getenv_opt "DUNE_SOURCEROOT" with
          | Some source_root -> Filename.concat source_root "addons"
          | None -> Filename.concat (Filename.dirname Sys.executable_name) "../addons" in
        let declaration id sources =
          let path = Filename.concat directory (id ^ ".toml") in
          write path (Printf.sprintf "id=%S\nrun_id=\"fusion-chain\"\nmanifest_path=%S\n[binding]\nsources=%s\n"
            id (Filename.concat addons (id ^ "/lane.toml")) sources);
          path in
        let producer_path = declaration "fusion-results" (Printf.sprintf
          {|[{source_id="fusion",kind="fusion_run",run_id=%S}]|} run_id) in
        let report_path = declaration "fusion-report" (edge "fusion-results") in
        let reader_manifest = manifest ~name:"report-reader" root in
        let reader_path = declare ~run:"fusion-chain" directory reader_manifest "report-reader"
          (edge ~output_id:"report" "fusion-report") in
        reconcile config directory;
        let producer = active config "fusion-results" |> text "instance_id" in
        let consumer = active config "fusion-report" |> text "instance_id" in
        let reader = active config "report-reader" |> text "instance_id" in
        let selected_rows () = match completed received reader with
          | Some observation -> member "output" observation |> list "rows"
          | None -> [] in
        let report () = selected_rows () |> List.find_opt (fun row ->
          member "lane_id" row = `String (consumer ^ "/fusion/report")
          && member "input_complete" (member "fields" row) = `Bool true) in
        await clock (fun () -> Option.is_some (report ()));
        let row = require_some "complete Fusion report missing" (report ()) in
        let context_id = match list "related_ids" row with
          | [`String id] -> id
          | _ -> fail "report must name its exact shared input context" in
        let context = selected_rows () |> List.find_opt (fun item -> text "id" item = context_id)
          |> require_some "named report port omitted the related context" in
        check string "named report port retains the context lane"
          (consumer ^ "/fusion/report-context") (text "lane_id" context);
        let selected = require_some "named report output is missing" (completed received reader) in
        check string "reader selected the declared report output" "report"
          (member "producer" selected |> text "output_id");
        let fields = member "fields" row in
        check string "exact native Fusion run crosses both packages" run_id (text "fusion_run_id" fields);
        check string "upstream installation survives composition" producer
          (member "fields" context |> member "producer" |> text "instance_id");
        check string "report does not claim delivery from observation" "not_attempted"
          (text "delivery_status" fields);
        check bool "report retains the Board analysis body" true
          (String.split_on_char '\n' (text "body" fields) |> List.mem body);
        let delivery = ref None in
        Runtime.register_delivery_handler (fun ~config:_ ~caller ~keeper_name ~prompt ->
          delivery := Some (caller, keeper_name, prompt);
          Ok (`Assoc ["request_id",`String "fixture-request";"status",`String "deferred"]));
        let frozen = Runtime.dispatch ~caller:"fixture-operator" ~access:Lane_addon_sources.Operator_configuration
          ~config ~operation:Runtime.Evidence
          (`Assoc ["instance_id",`String consumer;"row_ids",`List [`String (text "id" row)];
            "keeper_name",`String "fixture-keeper"]) |> unwrap in
        check string "delivery acceptance remains deferred, not read" "deferred"
          (member "delivery" frozen |> member "receipt" |> text "status");
        let caller, keeper, prompt = require_some "delivery callback missing" !delivery in
        check string "delivery preserves authenticated caller" "fixture-operator" caller;
        check string "delivery targets the selected Keeper" "fixture-keeper" keeper;
        let artifact = match Tool_output.decode_from_agent_core prompt with
          | Tool_output.Decoded artifact -> artifact
          | _ -> fail "delivery has no readable artifact marker" in
        let broadcast = Runtime.dispatch ~caller:"fixture-operator" ~access:Lane_addon_sources.Operator_configuration
          ~config ~operation:Runtime.Evidence
          (`Assoc ["instance_id",`String consumer;"row_ids",`List [`String (text "id" row)];
            "broadcast",`Bool true;"request_id",`String "composition-broadcast"]) |> unwrap in
        let broadcast_delivery = member "delivery" broadcast in
        check string "explicit Broadcast commits independently of Keeper acceptance" "committed"
          (text "status" broadcast_delivery);
        let receipt = member "receipt" broadcast_delivery in
        let path = Filename.concat (Workspace_utils_paths_backend.messages_dir config)
          (Printf.sprintf "%09d_%s_%s_broadcast.json"
            (member "seq" receipt |> Yojson.Safe.Util.to_int)
            (Common.safe_filename (text "from_agent" receipt)) (text "request_id" receipt)) in
        let committed = In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string in
        check string "durable Broadcast request matches the returned receipt"
          (text "request_id" receipt) (text "request_id" committed);
        check string "Broadcast content is the frozen artifact marker, not untrusted body"
          prompt (text "content" committed);
        check bool "Broadcast and Keeper delivery publish identical immutable evidence" true
          (member "keeper_artifact" frozen = member "keeper_artifact" broadcast);
        let read sha =
          let buffer = Buffer.create 1024 in
          let rec pages offset =
            let _, page = Keeper_artifact_read.handle_with_page ~base_path:root
              ~args:(`Assoc ["sha256",`String sha;"offset",`Int offset]) in
            match page with
            | Some page when page.encoding = Keeper_artifact_read.Utf_8 ->
                Buffer.add_string buffer page.content;
                if not page.eof then (
                  check bool "artifact pagination advances" true (page.next_offset > offset);
                  pages page.next_offset)
            | _ -> fail "Keeper cannot read the published UTF-8 report evidence" in
          pages 0; Buffer.contents buffer in
        let artifacts = match Tool_output.artifact_manifest_of_json
            (Yojson.Safe.from_string (read artifact.sha256)) with
          | Tool_output.Decoded_artifact_manifest {structured_content; _} ->
              list "artifacts" structured_content
          | _ -> fail "invalid report evidence manifest" in
        let retained = List.map (fun item ->
          let reference = match Tool_output.normalized_artifact_ref_of_json (member "artifact" item) with
            | Tool_output.Decoded_normalized_artifact_ref reference -> reference
            | _ -> fail "invalid published evidence reference" in
          reference.sha256, read reference.sha256) artifacts in
        check bool "publication carries the exact report and its related context" true
          (List.exists (fun (_, bytes) ->
            let record = Yojson.Safe.from_string bytes in
            match member "output" record with
            | `Assoc output -> (match List.assoc_opt "rows" output with
                | Some (`List rows) -> List.mem row rows && List.mem context rows
                | Some _ | None -> false)
            | _ -> false) retained);
        Sys.remove producer_path; Sys.remove report_path; Sys.remove reader_path;
        reconcile config directory;
        await clock (fun () ->
          text "kind" (member "phase" (instance config producer)) = "detached"
          && text "kind" (member "phase" (instance config consumer)) = "detached"
          && text "kind" (member "phase" (instance config reader)) = "detached");
        let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
        remove (Store.root store);
        List.iter (fun (sha, expected) ->
          check string "Keeper artifact bytes survive Detach and Lane-store removal" expected (read sha)) retained)))

let fusion_source run_id = Printf.sprintf
  {|[{source_id="fusion",kind="fusion_run",run_id=%S}]|} run_id
let register_private_run root owner =
  let run_id = "privacy-" ^ Store.digest root in
  Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
    ~keeper:owner ~preset:"default" ~roster:Fusion_types.preset_roster
    ~topology:Fusion_types.Simple ~started_at:1.; run_id
let test_private_visibility_crosses_declared_output_graph () = with_fixture (fun clock config root directory received _ ->
  let owner = "fusion-owner" in
  let run_id = register_private_run root owner in
  let package = manifest root in
  let source_path = declare directory package "z-private" (fusion_source run_id) in
  ignore (declare directory package "a-consumer" (edge "z-private"));
  ignore (declare directory package "b-consumer" (edge "a-consumer"));
  reconcile config directory;
  let ids = List.map (fun name -> active config name |> text "instance_id")
    ["z-private";"a-consumer";"b-consumer"] in
  List.iter (fun id -> await clock (fun () -> Option.is_some (completed received id))) (List.tl ids);
  let view caller = Runtime.dispatch ~caller ~config ~operation:Runtime.Inspect (`Assoc []) |> unwrap in
  check int "authoritative source owner sees all configured derivatives" 3 (view owner |> list "instances" |> List.length);
  check int "foreign reader sees no private derivatives" 0 (view "foreign" |> list "instances" |> List.length);
  check int "foreign inventory omits private declaration identity" 0
    (view "foreign" |> member "configuration" |> list "declarations" |> List.length);
  List.iter (fun id ->
    let stored = view owner |> list "instances" |> List.find (fun row -> text "instance_id" row = id) in
    check string "durable policy retains authoritative Fusion owner through graph" owner
      (stored |> member "visibility" |> text "keeper")) ids;
  let document caller access = Lane_addon_runtime.read_declaration ~caller ~access ~config
    (`Assoc ["source_path",`String source_path]) in
  check bool "owner can read own saved declaration" true
    (Result.is_ok (document owner (Lane_addon_sources.Keeper owner)));
  check bool "foreign declaration read is refused" true
    (Result.is_error (document "foreign" (Lane_addon_sources.Keeper "foreign")));
  let new_source = Printf.sprintf {|id="keeper-saved"
run_id="world"
manifest_path=%S
[binding]
sources=%s
|} package (fusion_source run_id) in
  let save caller access = Lane_addon_runtime.save_declaration ~caller ~access ~config
    (`Assoc ["mode",`String "create";"file_name",`String "keeper-saved.toml";"source_text",`String new_source]) in
  check bool "unverified attribution cannot save an owned-looking Fusion declaration" true
    (Result.is_error (save owner Lane_addon_sources.Unauthenticated));
  check bool "foreign Keeper cannot persist a private declaration" true
    (Result.is_error (save "foreign" (Lane_addon_sources.Keeper "foreign")));
  check bool "actual owner can save the configuration" true
    (Result.is_ok (save owner (Lane_addon_sources.Keeper owner)));
  reconcile config directory;
  let saved = active config "keeper-saved" |> text "instance_id" in
  check bool "operator reconciliation preserves saving Keeper read access" true
    (Result.is_ok (Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Inspect
      (`Assoc ["instance_id",`String saved])));
  let saved_path = Filename.concat directory "keeper-saved.toml" in
  write saved_path "id = [";
  reconcile config directory;
  let saved_document caller access = Lane_addon_runtime.read_declaration ~caller ~access ~config
    (`Assoc ["source_path",`String saved_path]) in
  let broken = saved_document owner (Lane_addon_sources.Keeper owner) in
  let current_revision = match broken with
    | Ok json -> text "source_revision" json
    | Error error -> fail error.Lane_addon_declaration.message in
  check bool "private owner reads malformed current bytes using applied ownership" true
    (Result.is_ok broken);
  check bool "foreign Keeper cannot read malformed private bytes" true
    (Result.is_error (saved_document "foreign" (Lane_addon_sources.Keeper "foreign")));
  let repair caller access = Lane_addon_runtime.save_declaration ~caller ~access ~config
    (`Assoc ["mode",`String "save";"file_name",`String "keeper-saved.toml";
      "expected_source_revision",`String current_revision;
      "source_text",`String new_source]) in
  check bool "foreign Keeper cannot repair another owner's malformed declaration" true
    (Result.is_error (repair "foreign" (Lane_addon_sources.Keeper "foreign")));
  let unowned_path = Filename.concat directory "unowned.toml" in
  write unowned_path "id = [";
  check bool "malformed file without an applied owner grants no raw read" true
    (Result.is_error (Lane_addon_runtime.read_declaration ~caller:owner
      ~access:(Lane_addon_sources.Keeper owner) ~config
      (`Assoc ["source_path",`String unowned_path])));
  check bool "malformed file without an applied owner grants no replacement" true
    (Result.is_error (Lane_addon_runtime.save_declaration ~caller:owner
      ~access:(Lane_addon_sources.Keeper owner) ~config
      (`Assoc ["mode",`String "save";"file_name",`String "unowned.toml";
        "expected_source_revision",`String (Lane_addon_store.digest "id = [");
        "source_text",`String new_source])));
  check bool "applied owner can commit corrected declaration with exact CAS" true
    (Result.is_ok (repair owner (Lane_addon_sources.Keeper owner)));
  check string "repair wrote the authorized bytes" new_source
    (In_channel.with_open_bin saved_path In_channel.input_all))

let test_configured_fusion_rechecks_owner_before_capture () = with_fixture (fun clock config root directory received _ ->
  let owner = "initial-owner" in
  let run_id = register_private_run root owner in
  ignore (declare directory (manifest root) "private-source" (fusion_source run_id));
  reconcile config directory;
  let id = active config "private-source" |> text "instance_id" in
  await clock (fun () -> member "observation_seq" (instance config id) <> `Int 0);
  let before = instance config id in
  let sequence = member "observation_seq" before in
  check string "configured capture is bound to retained private owner" owner
    (before |> member "source_access" |> text "keeper");
  Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
    ~keeper:"replacement-owner" ~preset:"default" ~roster:Fusion_types.preset_roster
    ~topology:Fusion_types.Simple ~started_at:2.;
  Runtime.notify_fusion_run ~run_id;
  await clock (fun () -> member "observation_seq" (instance config id) <> sequence);
  let denied = require_some "missing refused source envelope" (source received id) in
  check bool "changed owner becomes explicitly incomplete input" false
    (member "complete" denied |> Yojson.Safe.Util.to_bool);
  check int "worker receives no replacement owner's observations" 0
    (list "observations" denied |> List.length);
  check string "the source reports its actual ownership refusal"
    "Fusion run is unavailable to this caller" (text "detail" denied))

let test_operator_attached_private_fusion_rechecks_owner () = with_fixture (fun clock config root _directory received _ ->
  let owner = "dynamic-owner" in
  let run_id = register_private_run root owner in
  let binding = `Assoc ["sources",`List [`Assoc [
    "source_id",`String "fusion";"kind",`String "fusion_run";
    "run_id",`String run_id]]] in
  let attached = Runtime.dispatch ~caller:"operator" ~access:Lane_addon_sources.Operator_configuration
    ~config ~operation:Runtime.Attach (`Assoc [
      "manifest_path",`String (manifest root);"run_id",`String "world";
      "binding",binding]) |> unwrap in
  let id = text "instance_id" attached in
  await clock (fun () -> member "observation_seq" (instance config id) <> `Int 0);
  let before = instance config id in
  check string "operator attach retains private source owner" owner
    (before |> member "source_access" |> text "keeper");
  let sequence = member "observation_seq" before in
  Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
    ~keeper:"replacement-owner" ~preset:"default" ~roster:Fusion_types.preset_roster
    ~topology:Fusion_types.Simple ~started_at:2.;
  Runtime.notify_fusion_run ~run_id;
  await clock (fun () -> member "observation_seq" (instance config id) <> sequence);
  let denied = require_some "missing dynamic refusal envelope" (source received id) in
  let retained = Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Inspect
    (`Assoc ["instance_id",`String id]) |> unwrap in
  check bool "original owner retains access to old private evidence" true
    (list "instances" retained <> []);
  check bool "replacement owner is not captured by old private attachment" false
    (member "complete" denied |> Yojson.Safe.Util.to_bool);
  check int "replacement owner's observations stay private" 0
    (list "observations" denied |> List.length);
  check string "dynamic worker names ownership refusal"
    "Fusion run is unavailable to this caller" (text "detail" denied))

let test_saved_document_keeps_repair_authority_after_source_eviction () =
  with_fixture (fun clock config root directory _received _ ->
    let owner = "repair-owner" in
    let old_run = register_private_run root owner in
    let package = manifest root in
    let source run = Printf.sprintf {|id="owned-document"
run_id="world"
manifest_path=%S
[binding]
sources=%s
|} package (fusion_source run) in
    let save ?revision bytes = Lane_addon_runtime.save_declaration ~caller:owner
      ~access:(Lane_addon_sources.Keeper owner) ~config (`Assoc ([
        "mode",`String (if Option.is_none revision then "create" else "save");
        "file_name",`String "owned.toml"; "source_text",`String bytes] @
        Option.fold ~none:[] ~some:(fun value -> ["expected_source_revision",`String value]) revision)) in
    let require_document = function Ok value -> value | Error error -> fail error.Lane_addon_declaration.message in
    ignore (save (source old_run) |> require_document);
    let path = Filename.concat directory "owned.toml" in
    let read keeper = Lane_addon_runtime.read_declaration ~caller:keeper
      ~access:(Lane_addon_sources.Keeper keeper) ~config (`Assoc ["source_path",`String path]) in
    let operator_path = declare directory package "operator-created" (fusion_source old_run) in
    reconcile config directory;
    let registry = Fusion_run_registry.global () in
    Fusion_run_registry.mark_completed registry ~run_id:old_run ~outcome:Fusion_run_registry.Succeeded;
    for index = 1 to Fusion_run_registry.max_completed_retained do
      Eio.Time.sleep clock 0.001;
      let run_id = old_run ^ "/newer/" ^ string_of_int index in
      Fusion_run_registry.register_running registry ~run_id ~keeper:owner ~preset:"default"
        ~roster:Fusion_types.preset_roster ~topology:Fusion_types.Simple ~started_at:(float_of_int index +. 100.);
      Fusion_run_registry.mark_completed registry ~run_id ~outcome:Fusion_run_registry.Succeeded
    done;
    check bool "original source has left bounded registry" true
      (Option.is_none (Fusion_run_registry.get registry ~run_id:old_run));
    check string "durable owner can read after source eviction" (source old_run)
      (read owner |> require_document |> text "source_text");
    check bool "foreign Keeper cannot read an owned document" true (Result.is_error (read "foreign"));
    let malformed = "id = \"unfinished" in
    write operator_path malformed;
    let operator_document = Lane_addon_runtime.read_declaration ~caller:owner
      ~access:(Lane_addon_sources.Keeper owner) ~config
      (`Assoc ["source_path",`String operator_path]) |> require_document in
    check string "operator-created private document retains its verified owner" malformed
      (text "source_text" operator_document);
    write path malformed;
    let damaged = read owner |> require_document in
    check string "invalid source is available for authorized repair" malformed (text "source_text" damaged);
    let next_run = register_private_run (root ^ "/replacement") owner in
    ignore (save ~revision:(text "source_revision" damaged) (source next_run) |> require_document);
    check string "repair can replace a pruned source" (source next_run)
      (read owner |> require_document |> text "source_text"))

let test_pending_document_owner_rejects_replaced_source () =
  with_fixture (fun _clock config root directory _received _ ->
    let package = manifest root in
    let path = declare directory package "pending-owner" "[]" in
    let bytes = Fs_compat.load_file path in
    let store_root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    unwrap (Lane_addon_document_owner.prepare ~root:store_root ~source_path:path ~keeper:"owner"
      ~prior_revision:None ~proposed_revision:(Store.digest bytes));
    let read () = Lane_addon_runtime.read_declaration ~caller:"owner"
      ~access:(Lane_addon_sources.Keeper "owner") ~config (`Assoc ["source_path",`String path]) in
    check bool "pending admission authorizes only exact proposed bytes" true (Result.is_ok (read ()));
    write path (bytes ^ "\nforeign = true\n");
    check bool "uncommitted ownership cannot adopt replacement bytes" true (Result.is_error (read ()));
    write path bytes;
    let journal = Filename.concat store_root (Filename.concat "declaration-owners" (Store.digest path ^ ".jsonl")) in
    Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 journal (fun out -> output_string out "{");
    check bool "incomplete ownership journal fails closed" true (Result.is_error (read ())))

let test_shared_consumer_refuses_new_private_producer () = with_fixture (fun clock config root directory received _ ->
  let package = manifest root in
  ignore (declare directory package "a-consumer" (edge "z-producer"));
  ignore (declare directory package "z-producer" "[]");
  reconcile config directory;
  let consumer = active config "a-consumer" |> text "instance_id" in
  await clock (fun () -> Option.is_some (completed received consumer));
  let old = require_some "no initial shared producer" (completed received consumer) in
  let old_instance = text "instance_id" (member "producer" old) in
  let run_id = register_private_run root "new-private-owner" in
  ignore (declare directory package "z-producer" (fusion_source run_id));
  reconcile config directory;
  await clock (fun () -> text "kind" (member "phase" (instance config old_instance)) = "detached");
  reconcile config directory;
  let replacement = active config "z-producer" |> text "instance_id" in
  await clock (fun () -> Option.is_some (source received replacement));
  Runtime.notify_fusion_run ~run_id;
  ignore (Runtime.dispatch ~config ~operation:Runtime.Observe (`Assoc ["instance_id",`String consumer]) |> unwrap);
  await clock (fun () -> match source received consumer with
    | Some source -> member "complete" source = `Bool false && list "observations" source = []
    | None -> false);
  check string "consumer stays the exact original instance" consumer
    (active config "a-consumer" |> text "instance_id");
  check string "old shared input remains an immutable producer snapshot" old_instance
    (text "instance_id" (member "producer" old));
  check bool "ordinary consumer retains Shared visibility while refusing new private bytes" true
    (member "visibility" (instance config consumer) = `Assoc ["kind",`String "shared"]))

let () = run "TOML cross-Lane composition" ["world inputs",[
  test_case "native Fusion report crosses packages and remains Keeper-readable" `Quick
    test_native_fusion_report_is_readable_after_detach;
  test_case "owned declarations survive source eviction and malformed edits" `Quick
    test_saved_document_keeps_repair_authority_after_source_eviction;
  test_case "pending document owner cannot adopt replacement bytes" `Quick
    test_pending_document_owner_rejects_replaced_source;
  test_case "private visibility survives declared output graph" `Quick test_private_visibility_crosses_declared_output_graph;
  test_case "shared consumer refuses replacement with private producer" `Quick test_shared_consumer_refuses_new_private_producer;
  test_case "host namespace overhead preserves package reply capacity" `Quick
    test_namespace_overhead_does_not_consume_package_capacity;
  test_case "configured Fusion capture rechecks its retained owner" `Quick test_configured_fusion_rechecks_owner_before_capture;
  test_case "operator-attached private Fusion rechecks owner" `Quick test_operator_attached_private_fusion_rechecks_owner;
  test_case "native input history crosses worker and survives Detach" `Quick
    test_native_msx_history_crosses_worker_freeze_and_detach;
  test_case "named output feeds statistics and preserves mapping revisions" `Quick
    test_named_output_flows_to_statistics_and_mapping_revision;
  test_case "invalid edited cycle preserves existing owners and progress" `Quick
    test_invalid_cycle_edit_preserves_applied_producer_and_consumer;
  test_case "partial input and replacement preserve exact producer coordinates" `Quick
    test_partial_input_recovers_and_replacement_keeps_exact_coordinates;
  test_case "unresolved cleanup invalidates input without stopping its consumer" `Quick
    test_refused_cleanup_invalidates_downstream_input_without_stopping_it;
  test_case "installed output crosses with exact provenance" `Quick test_toml_output_connection_and_retained_provenance;
  test_case "cycles and other runs do not poison unrelated activity" `Quick test_cycle_and_cross_run_are_local_to_connections]]
