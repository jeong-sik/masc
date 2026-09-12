(** TOML edges deliver one installed package's completed output to another
    through the real source adapter. Only external worker processes are fake. *)
open Alcotest
open Masc
module Runtime = struct
  include Lane_addon_runtime
  let dispatch ?caller ~config ~operation args =
    Lane_addon_runtime.dispatch ?caller ~config ~operation args
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
let with_fixture ?(produce=(fun ~binding:_ ~sources:_ -> output)) ?(allow_stop=ref true)
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
              let config = Workspace.default_config root in
              check string "configuration resolves only to this owned fixture"
                directory (Runtime.configuration_directory config);
              let received = Hashtbl.create 4 and stopped = ref [] in
              let backend : Runtime.For_testing.backend = {
                start=(fun ~sw:_ ~instance_id ~package:_ ~on_created ->
                  let connection : Runtime.For_testing.connection = {
                    container_id=Store.digest instance_id;
                    action_schema = (fun () -> None);
                    act = (fun ~arguments:_ -> Error "read-only fixture");
                    observe=(fun ~binding ~sources ->
                      Hashtbl.replace received instance_id sources; Ok (produce ~binding ~sources));
                    stop=(fun () ->
                      stop_attempts := instance_id :: !stop_attempts;
                      if not !allow_stop then Error "fixture cleanup unavailable"
                      else (stopped := instance_id :: !stopped; Ok ()))} in
                  on_created connection; Ok connection);
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
let manifest ?(name="package") ?(outputs="") root =
  let path = Filename.concat root (name ^ ".toml") in
  write path ({|id="generic-package"
revision="1"
title="Generic output"
image="not-executed"
command=["not-executed"]
contributions=["observe"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=16384
|} ^ outputs); path
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

let () = run "TOML cross-Lane composition" ["world inputs",[
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
