(** Optional observer lifecycle through the public dispatch surface. The fake
    package supplies barriers; no model response or Docker daemon is involved. *)
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

let make_backend ?observe_step () =
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
          let call = 1 + Option.value ~default:0 (Hashtbl.find_opt state.calls instance_id) in
          Hashtbl.replace state.calls instance_id call;
          Option.iter (fun step -> step call) observe_step;
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
    image_ready = (fun ~package:_ -> Ok ());
    acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ ->
      Ok (`List [`Assoc ["original_bytes", `String "captured source before rotation"]]));
    recover_stop = (fun ~instance_id ~container_id ~max_reply_bytes:_ ->
      match container_id with
      | Some id when id = Store.digest instance_id ->
          state.recovery := (instance_id, id) :: !(state.recovery); Ok ()
      | Some _ | None -> Error "owner mismatch")
  } in state, backend

let manifest ?refresh_policy dir mode =
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
|} mode ^ Option.fold ~none:"" ~some:(fun policy ->
      "\n[interface]\nrefresh_policy = " ^ Printf.sprintf "%S" policy ^ "\n") refresh_policy);
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
let with_fixture ?acquire ?observe_step f =
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
              Runtime.register_fleet_backend {snapshot=(fun ~config:_ ~caller:_ ~access:_ -> Ok (Masc.Lane_addon_broadcast_delivery.External_sender,[]));
                project=(fun ~config:_ ~sender_authority:_ ~delivery:_ ~recipient:_ -> Error "empty fixture fleet has no recipient")};
              let state, backend = make_backend ?observe_step () in
              let backend = match acquire with None -> backend | Some acquire -> {backend with acquire} in
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
  List.iter (fun () -> ignore (unwrap (dispatch config Runtime.Observe
    ["instance_id", `String blocked]))) [();();()];
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

let test_request_refusals_preserve_runtime_failure_distinction () =
  with_fixture (fun _env _sw config dir _state ->
    let dispatch operation fields = Lane_addon_runtime.dispatch
      ~access:Lane_addon_sources.Operator_configuration ~config ~operation (`Assoc fields) in
    let rejected label = function
      | Error (Lane_addon_runtime.Request_rejected _) -> ()
      | Error (Runtime_failed detail) -> failf "%s became runtime failure: %s" label detail
      | Ok _ -> failf "%s was accepted" label in
    rejected "missing active instance" (dispatch Runtime.Observe ["instance_id", `String "absent"]);
    rejected "missing retained instance" (dispatch Runtime.Detach ["instance_id", `String "absent"]);
    rejected "missing evidence instance" (dispatch Runtime.Evidence
      ["instance_id", `String "absent"; "row_ids", `List []]);
    rejected "missing action request" (dispatch Runtime.Action_status
      ["instance_id", `String "absent"; "request_id", `String "absent"]);
    rejected "missing manifest" (dispatch Runtime.Attach
      ["manifest_path", `String (Filename.concat dir "missing.toml");
       "run_id", `String "fixture-run"; "binding", `Assoc []]);
    rejected "missing action fields" (dispatch Runtime.Act []);
    let action_fields = ["instance_id", `String "absent";
      "expected_incarnation", `String "absent"; "request_id", `String "request";
      "action", `Assoc []] in
    rejected "missing action target" (Lane_addon_runtime.dispatch ~caller:"fixture-caller"
      ~access:(Lane_addon_sources.Keeper "fixture-caller")
      ~config ~operation:Runtime.Act (`Assoc action_fields));
    rejected "invalid slice timestamp" (dispatch Runtime.Slice ["since", `String "bad"]);
    rejected "reversed slice range" (dispatch Runtime.Slice ["since", `Int 2; "until", `Int 1]);
    let root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
    Fs_compat.mkdir_p root;
    write (Filename.concat root "bindings") "a file cannot be a binding directory";
    let runtime_failed = function
      | Error (Lane_addon_runtime.Runtime_failed _) -> ()
      | Error (Request_rejected detail) -> failf "unreadable store became input refusal: %s" detail
      | Ok _ -> fail "unreadable store was accepted" in
    runtime_failed (dispatch Runtime.Detach ["instance_id", `String "absent"]);
    runtime_failed (dispatch Runtime.Slice []))

let test_invalid_retained_visibility_is_isolated () = with_fixture (fun env _ config dir _ ->
  let id = attach config dir "good" in
  let clock = Eio.Stdenv.clock env in
  await clock (fun () -> int "observation_seq" (instance config id) = 1);
  let current = instance config id |> Yojson.Safe.Util.to_assoc in
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  List.iteri (fun index visibility ->
    let retained_id = "unreadable-" ^ string_of_int index in
    let fields = ("instance_id",`String retained_id) ::
      List.remove_assoc "instance_id" (List.remove_assoc "visibility" current) in
    let fields = match visibility with None -> fields | Some value -> ("visibility",value)::fields in
    let fields = ("configuration",`Assoc ["id",`String ("invalid-producer-" ^ string_of_int index);
      "source_path",`String (Filename.concat dir "invalid.toml");"revision",`String "fixture"])
      :: List.remove_assoc "configuration" fields in
    unwrap (Store.save_binding store ~instance_id:retained_id (`Assoc fields)))
    [None; Some (`Assoc ["kind",`String "unknown"])];
  let consumer_id = "released-invalid-consumer" in
  let consumer = current
    |> List.filter (fun (key, _) -> not (List.mem key
      ["runtime_presence";"visibility";"source_access";"instance_id";"incarnation";"binding"]))
    |> List.map (function
      | "package", `Assoc fields -> "package", `Assoc (List.remove_assoc "model_access" fields)
      | field -> field) in
  let consumer = `Assoc (("instance_id",`String consumer_id)::("incarnation",`String consumer_id)::
    ("binding",`Assoc ["sources",`List [`Assoc ["source_id",`String "upstream";
      "kind",`String "lane_output";"installation_id",`String "invalid-producer-1";
      "selection",`String "latest_completed"]]])::consumer) in
  let valid_producer = match consumer with
    | `Assoc fields -> `Assoc (("instance_id",`String "released-producer")::
        ("incarnation",`String "released-producer")::("binding",`Assoc ["sources",`List []])::
        ("configuration",`Assoc ["id",`String "invalid-producer-1";
          "source_path",`String (Filename.concat dir "producer.toml");"revision",`String "fixture"])::
        List.filter (fun (key, _) -> not (List.mem key
          ["instance_id";"incarnation";"binding";"configuration"])) fields)
    | _ -> assert false in
  check bool "released consumer shape is valid with a proved shared producer" true
    (Result.is_ok (Runtime.authorize_retained_read ~bindings:[valid_producer;consumer]
      ~access:Lane_addon_sources.Unauthenticated consumer));
  unwrap (Store.save_binding store ~instance_id:consumer_id consumer);
  check Alcotest.int "unreadable retained policy cannot hide a valid live installation" 1
    (inspect config |> member "instances" |> Yojson.Safe.Util.to_list |> List.length);
  check bool "unreadable record still cannot be requested directly" true
    (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Inspect
      (`Assoc ["instance_id",`String "unreadable-0"])));
  check bool "omitting an invalid producer cannot authorize its released consumer" true
    (Result.is_error (Runtime.dispatch ~config ~operation:Runtime.Inspect
      (`Assoc ["instance_id",`String consumer_id])));
  check Alcotest.int "invalid records and dependent consumer remain available for operator repair" 4
    (Store.bindings store |> unwrap |> List.length);
  detach config id; await_phase clock config id "detached")

let test_direct_attach_validates_package_binding () =
  with_fixture (fun env _sw config dir state ->
    let path = manifest dir "binding-contract" in
    write path (Fs_compat.load_file path ^ {|
[interface]
binding_schema = '''{"type":"object","properties":{"sources":{"type":"array","items":{"type":"object","properties":{},"additionalProperties":false}},"limit":{"type":"integer","minimum":1}},"required":["sources","limit"],"additionalProperties":false}'''
|});
    let attach_binding binding = Lane_addon_runtime.dispatch
      ~access:Lane_addon_sources.Operator_configuration ~config
      ~operation:Runtime.Attach (`Assoc ["manifest_path",`String path;
        "run_id",`String "binding-run";"binding",`Assoc binding]) in
    List.iter (fun binding ->
      (match attach_binding binding with
       | Error (Lane_addon_runtime.Request_rejected _) -> ()
       | Error (Runtime_failed detail) -> failf "invalid binding became runtime failure: %s" detail
       | Ok _ -> fail "direct attach bypassed the package binding schema");
      check Alcotest.int "invalid binding starts no worker" 0 (Hashtbl.length state.modes);
      check Alcotest.int "invalid binding creates no instance" 0
        (inspect config |> member "instances" |> Yojson.Safe.Util.to_list |> List.length))
      [["sources",`List []]; ["sources",`List [];"limit",`Int 0];
       ["sources",`List [];"limit",`String "2"]];
    let accepted = attach_binding ["sources",`List [];"limit",`Int 2]
      |> Result.map_error Lane_addon_runtime.error_to_string |> unwrap in
    let id = text "instance_id" accepted in
    let clock = Eio.Stdenv.clock env in
    await clock (fun () -> Hashtbl.mem state.modes id);
    detach config id;
    await_phase clock config id "detached")

let test_file_activity_preserves_explicit_observation () =
  with_fixture ~acquire:Lane_addon_sources.acquire (fun env _sw config dir _state ->
    let clock = Eio.Stdenv.clock env in
    let source_path = Filename.concat dir "source.json" in
    let snapshot cursor = `Assoc ["source_id",`String "file";"incarnation",`String "export";
      "cursor",`String cursor;"complete",`Bool true;"detail",`Null;"observations",`List []] in
    let replace cursor = write source_path (Yojson.Safe.to_string (snapshot cursor)) in
    replace "first";
    let file_id = unwrap (dispatch config Runtime.Attach
      ["manifest_path",`String (manifest ~refresh_policy:"source_changes" dir "file-observer");"run_id",`String "files";
       "binding",`Assoc ["sources",`List [`Assoc ["source_id",`String "file";
         "kind",`String "snapshot_file";"path",`String source_path]]]]) |> text "instance_id" in
    let owned_id = attach config dir "owned-observer" in
    let stateful_id = unwrap (dispatch config Runtime.Attach
      ["manifest_path",`String (manifest dir "stateful-file-observer");"run_id",`String "files";
       "binding",`Assoc ["sources",`List [`Assoc ["source_id",`String "file";
         "kind",`String "snapshot_file";"path",`String source_path]]]]) |> text "instance_id" in
    let sequence id = int "observation_seq" (instance config id) in
    await clock (fun () -> sequence file_id=1 && sequence owned_id=1 && sequence stateful_id=1);
    let refresh () = Runtime.notify_activity ~config ~activity:Lane_addon_sources.Tool_completed in
    refresh ();
    await clock (fun () -> int "unchanged_source_refreshes" (instance config file_id)=1 && sequence stateful_id=2);
    check Alcotest.int "unchanged capture adds no retained output" 1 (sequence file_id);
    check Alcotest.int "unrelated tool completion does not sample an owned environment" 1 (sequence owned_id);
    check Alcotest.int "default file observer still receives equal captures" 2 (sequence stateful_id);
    refresh ();
    ignore (unwrap (dispatch config Runtime.Observe ["instance_id",`String file_id]));
    await clock (fun () -> sequence file_id=2);
    replace "second";
    refresh ();
    await clock (fun () -> sequence file_id=3);
    write source_path "truncated source";
    refresh ();
    await clock (fun () -> sequence file_id=4);
    replace "second";
    refresh ();
    await clock (fun () -> sequence file_id=5);
    (* A recovered source must be observed even when its bytes equal those
       before the intervening unavailable capture. *)
    let retained = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    let records = Store.observations retained ~instance_id:file_id |> unwrap in
    check Alcotest.int "changed, failed and recovered captures are all retained" 5 (List.length records);
    let sources,_ = List.nth records 3 in
    check bool "capture failure reaches the worker as incomplete input" true
      (match sources with `List [`Assoc fields] -> List.assoc_opt "complete" fields=Some (`Bool false) | _ -> false);
    detach config file_id; detach config owned_id; detach config stateful_id;
    await_phase clock config file_id "detached";
    await_phase clock config owned_id "detached";
    await_phase clock config stateful_id "detached")

let test_capture_cannot_rewrite_detach_failure () =
  let entered, enter = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let returned, return = Eio.Promise.create () in
  let captures = ref 0 in
  let acquire ~access ~store ~package ~resolve_lane_output ~binding =
    incr captures;
    if !captures=2 then (Eio.Promise.resolve enter (); Eio.Promise.await released);
    let result = Lane_addon_sources.acquire ~access ~store ~package ~resolve_lane_output ~binding in
    if !captures=2 then Eio.Promise.resolve return ();
    result in
  with_fixture ~acquire (fun env _sw config dir state ->
    let clock = Eio.Stdenv.clock env in
    let source_path = Filename.concat dir "source.json" in
    write source_path {|{"source_id":"file","incarnation":"export","cursor":"1","complete":true,"detail":null,"observations":[]}|};
    let id = unwrap (dispatch config Runtime.Attach
      ["manifest_path",`String (manifest ~refresh_policy:"source_changes" dir "stop-retry");
       "run_id",`String "files";"binding",`Assoc ["sources",`List [`Assoc
         ["source_id",`String "file";"kind",`String "snapshot_file";"path",`String source_path]]]])
      |> text "instance_id" in
    await clock (fun () -> int "observation_seq" (instance config id)=1);
    Runtime.notify_activity ~config ~activity:Lane_addon_sources.Tool_completed;
    Eio.Promise.await entered;
    detach config id;
    await_phase clock config id "failed";
    Eio.Promise.resolve release ();
    Eio.Promise.await returned;
    check string "capture does not overwrite cleanup failure with attached" "failed" (phase (instance config id));
    check Alcotest.int "retired worker receives no additional observation" 1 (Hashtbl.find state.calls id);
    detach config id;
    await_phase clock config id "detached")

(* An observer bound to the workspace machine. The fake backend's capture
   answers without reading the machine; only the wake path is under test. *)
let attach_machine_watcher config dir =
  unwrap (dispatch config Runtime.Attach
    ["manifest_path",`String (manifest dir "machine-observer");"run_id",`String "machine";
     "binding",`Assoc ["sources",`List [`Assoc
       ["kind",`String "msx_capture";"source_id",`String "machine"]]]])
  |> text "instance_id"

(* Hold the second capture after a route wakes the watcher. A second route
   notification must now remain visible as pending or coalesced, with no timing
   guess about how long the worker needs to finish its capture. *)
let with_held_second_observation f =
  let entered, enter = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let release_sent = ref false in
  let release_once () =
    if not !release_sent then (release_sent := true; Eio.Promise.resolve release ())
  in
  let observe_step call =
    if call = 2 then (Eio.Promise.resolve enter (); Eio.Promise.await released)
  in
  with_fixture ~observe_step (fun env sw config dir state ->
    Fun.protect ~finally:release_once (fun () ->
      f env sw config dir state ~entered ~release:release_once))

let check_no_extra_machine_wake config id =
  let current = instance config id in
  check bool "no second observation is pending" false
    (member "observation_pending" current |> Yojson.Safe.Util.to_bool);
  check Alcotest.int "no second wake was coalesced" 0
    (int "coalesced_wakes" current)

let test_human_press_wakes_machine_watchers_once () =
  with_held_second_observation (fun env _sw config dir _state ~entered ~release ->
    let clock = Eio.Stdenv.clock env in
    let msx = function Ok value -> value | Error error -> fail (Msx_lane.error_to_string error) in
    ignore (msx (Msx_lane.load ~ledger_dir:(Filename.concat dir "machine") ~roms_dir:None
      ~cart_path:None ~disk_path:None));
    Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
      let id = attach_machine_watcher config dir in
      let sequence () = int "observation_seq" (instance config id) in
      await clock (fun () -> sequence () = 1);
      let press body =
        fst (Server_routes_http_routes_msx.press_response ~config ~who:"operator" ~body) in
      check bool "a key the machine lacks is refused" true
        (press {|{"keys":["not-a-key"]}|} = `Bad_request);
      check bool "a human press is accepted" true (press {|{"keys":["space"]}|} = `OK);
      Eio.Promise.await entered;
      check_no_extra_machine_wake config id;
      release ();
      await clock (fun () -> sequence () = 2);
      check Alcotest.int "one accepted press is one observation, the refusal none" 2 (sequence ());
      detach config id;
      await_phase clock config id "detached"))

let test_human_load_wakes_machine_watchers_once () =
  with_held_second_observation (fun env _sw config dir _state ~entered ~release ->
    let clock = Eio.Stdenv.clock env in
    ignore (Msx_lane.eject ());
    Fun.protect ~finally:(fun () -> ignore (Msx_lane.eject ())) (fun () ->
      let id = attach_machine_watcher config dir in
      let sequence () = int "observation_seq" (instance config id) in
      await clock (fun () -> sequence () = 1);
      let load body =
        fst (Server_routes_http_routes_msx.load_response ~config
          ~agent_name:"operator" ~body) in
      check bool "a missing cartridge is refused" true
        (load {|{"roms_dir":"","cart":"missing.rom"}|} = `Bad_request);
      check bool "a human BIOS-only load is accepted" true
        (load {|{"roms_dir":""}|} = `OK);
      Eio.Promise.await entered;
      check_no_extra_machine_wake config id;
      release ();
      await clock (fun () -> sequence () = 2);
      check Alcotest.int "one accepted load is one observation, the refusal none" 2
        (sequence ());
      detach config id;
      await_phase clock config id "detached"))

let test_activity_from_another_domain_reaches_the_owner () =
  with_fixture (fun env _sw config dir _state ->
    let clock = Eio.Stdenv.clock env in
    let id = attach_machine_watcher config dir in
    let sequence () = int "observation_seq" (instance config id) in
    await clock (fun () -> sequence () = 1);
    let caller_owned_root =
      Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
        let owned = Eio_context.root_switch_on_current_domain () in
        Runtime.notify_activity ~config ~activity:(Lane_addon_sources.Machine_changed Masc.Machine_lane.Msx);
        owned) in
    check bool "the notification came from off the owner domain" false caller_owned_root;
    await clock (fun () -> sequence () = 2);
    detach config id;
    await_phase clock config id "detached")

let test_mcp_attribution_does_not_authorize_private_lane () =
  with_fixture (fun env sw config dir _state ->
    ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
    Auth.disable_auth config.base_path;
    check bool "fixture has authentication disabled" false (Auth.is_auth_enabled config.base_path);
    let owner = "lane-private-owner" in
    let meta = unwrap (Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name",`String owner;"trace_id",`String "trace-lane-owner"])) in
    let meta_path = Keeper_types_profile.keeper_meta_path config owner in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Fs_compat.save_file meta_path (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json meta));
    let run_id = "mcp-private-" ^ Store.digest dir in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
      ~keeper:owner ~preset:"default" ~roster:Fusion_types.preset_roster
      ~topology:Fusion_types.Simple ~started_at:1.;
    let id = unwrap (Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Attach
      (`Assoc ["manifest_path",`String (manifest dir "good");"run_id",`String "world";
        "binding",`Assoc ["sources",`List [`Assoc ["source_id",`String "fusion";
          "kind",`String "fusion_run";"run_id",`String run_id]]]])) |> text "instance_id" in
    let clock = Eio.Stdenv.clock env in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let owner_view = unwrap (Runtime.dispatch ~caller:owner ~config
      ~operation:Runtime.Inspect (`Assoc ["instance_id",`String id])) in
    let row_id = member "rows" owner_view |> Yojson.Safe.Util.to_list
      |> List.hd |> text "id" in
    let state = Mcp_server_eio.For_testing.create_state ~base_path:config.base_path () in
    let session_id = "untrusted-lane-" ^ Store.digest dir in
    Fun.protect ~finally:(fun () -> Client_registry_eio.unregister_mcp_session session_id)
      (fun () ->
        let mcp ?auth_token name fields = Mcp_server_eio.execute_tool_eio
          ~sw ~clock ~workspace_scope:(Mcp_server.workspace_scope state)
          ~mcp_session_id:session_id ?auth_token state ~name ~arguments:(`Assoc fields) in
        let failed = mcp "masc_lane_observe" ["_agent_name",`String owner] in
        check bool "first attribution-only call fails" false (Tool_result.is_success failed);
        check bool "failed first call cached attribution" true
          (match Client_registry_eio.get_resolved_name session_id with
           | Some (name, false) -> String.equal name owner
           | Some _ | None -> false);
        List.iter (fun (name, fields) ->
          let result = mcp name fields in
          check bool (name ^ " cannot promote cached attribution to authority") false
            (Tool_result.is_success result))
          ["masc_lane_inspect", ["instance_id",`String id];
           "masc_lane_evidence", ["instance_id",`String id;
             "row_ids",`List [`String row_id]];
           "masc_lane_observe", ["instance_id",`String id];
           "masc_lane_detach", ["instance_id",`String id]];
        let token = match Auth.create_token config.base_path ~agent_name:owner ~role:Masc_domain.Worker with
          | Ok (token,_) -> token | Error error -> fail (Masc_domain.masc_error_to_string error) in
        let owned = mcp ~auth_token:token "masc_lane_inspect" ["instance_id",`String id] in
        check bool ("verified owner reads private lane: " ^ Tool_result.message owned) true
          (Tool_result.is_success owned);
        let foreign = match Auth.create_token config.base_path ~agent_name:"foreign-lane-reader" ~role:Masc_domain.Worker with
          | Ok (token,_) -> token | Error error -> fail (Masc_domain.masc_error_to_string error) in
        let denied = mcp ~auth_token:foreign "masc_lane_inspect" ["instance_id",`String id] in
        check bool "foreign bearer cannot borrow cached owner" false (Tool_result.is_success denied);
        detach config id;
        await_phase clock config id "detached"))

let test_fusion_status_hint_wakes_only_its_bound_run () =
  with_fixture (fun env _sw config dir _state ->
    let watcher run_id =
      Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
        ~keeper:"fixture-owner" ~preset:"default" ~roster:Fusion_types.preset_roster
        ~topology:Fusion_types.Simple ~started_at:1.;
      unwrap (Runtime.dispatch ~caller:"fixture-owner" ~config ~operation:Runtime.Attach (`Assoc [
        "manifest_path",`String (manifest dir "good");"run_id",`String "world";
        "binding",`Assoc ["sources",`List [`Assoc [
          "source_id",`String "fusion";"kind",`String "fusion_run";
          "run_id",`String run_id]]]])) |> text "instance_id" in
    let one = watcher "fusion-one" and two = watcher "fusion-two" in
    let clock = Eio.Stdenv.clock env in
    let request caller operation fields = Runtime.dispatch ~caller ~config ~operation (`Assoc fields) in
    let inspect_owned id = unwrap (request "fixture-owner" Runtime.Inspect ["instance_id",`String id])
      |> member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
    let seq id = int "observation_seq" (inspect_owned id) in
    await clock (fun () -> seq one=1 && seq two=1);
    let foreign = unwrap (request "another-keeper" Runtime.Inspect []) in
    check Alcotest.int "foreign inspect enumerates no private instances" 0
      (member "instances" foreign |> Yojson.Safe.Util.to_list |> List.length);
    check Alcotest.int "foreign inspect exposes no private rows" 0
      (member "rows" foreign |> Yojson.Safe.Util.to_list |> List.length);
    let foreign_slice = unwrap (request "another-keeper" Runtime.Slice ["run_id",`String "world"]) in
    check Alcotest.int "foreign retained slice exposes no private rows" 0
      (member "rows" foreign_slice |> Yojson.Safe.Util.to_list |> List.length);
    let denied operation fields =
      match Lane_addon_runtime.dispatch ~caller:"another-keeper"
          ~access:(Lane_addon_sources.Keeper "another-keeper") ~config ~operation
          (`Assoc (("instance_id",`String one)::fields)) with
      | Error (Runtime.Request_rejected detail) ->
          check string "private instance is denied before read or mutation"
            "Lane instance is unavailable to this caller" detail
      | Error (Runtime_failed detail) -> failf "access denial became runtime failure: %s" detail
      | Ok _ -> fail "another Keeper read or mutated private evidence" in
    List.iter (fun (operation,fields) -> denied operation fields)
      [Runtime.Evidence,["row_ids",`List []]; Runtime.Observe,[]; Runtime.Detach,[];
       Runtime.Act,["expected_incarnation",`String one;"request_id",`String "foreign";"action",`Assoc []];
       Runtime.Action_status,["request_id",`String "foreign"]];
    Runtime.notify_fusion_run ~run_id:"fusion-one";
    await clock (fun () -> seq one=2);
    check Alcotest.int "another Fusion binding did not run" 1 (seq two);
    List.iter (fun id -> ignore (unwrap (request "fixture-owner" Runtime.Detach ["instance_id",`String id]))) [one;two];
    List.iter (fun id -> await clock (fun () -> phase (inspect_owned id) = "detached")) [one;two];
    Runtime.For_testing.reset ();
    let owner_slice = unwrap (request "fixture-owner" Runtime.Slice ["run_id",`String "world"]) in
    check bool "owner can read durable evidence after restart" true
      (member "rows" owner_slice |> Yojson.Safe.Util.to_list <> []);
    let foreign_slice = unwrap (request "another-keeper" Runtime.Slice ["run_id",`String "world"]) in
    check Alcotest.int "durable ownership still hides private rows after restart" 0
      (member "rows" foreign_slice |> Yojson.Safe.Util.to_list |> List.length))

let test_private_fusion_reads_survive_retirement () = with_fixture (fun env _sw config dir _state ->
  let owner = "private-owner" and foreign = "private-reader" in
  let run_id = "private-fusion-" ^ Store.digest dir in
  Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
    ~keeper:owner ~preset:"default" ~roster:Fusion_types.preset_roster
    ~topology:Fusion_types.Simple ~started_at:1.;
  let call caller operation fields = Runtime.dispatch ~caller ~config ~operation (`Assoc fields) in
  let id = unwrap (call owner Runtime.Attach ["manifest_path",`String (manifest dir "good");
    "run_id",`String "private-world";"binding",`Assoc ["sources",`List [`Assoc [
      "source_id",`String "fusion";"kind",`String "fusion_run";"run_id",`String run_id]]]])
    |> text "instance_id" in
  let clock = Eio.Stdenv.clock env in
  await clock (fun () -> int "observation_seq" (instance config id) = 1);
  let view = unwrap (call owner Runtime.Inspect ["instance_id",`String id]) in
  let row_id = member "rows" view |> Yojson.Safe.Util.to_list |> List.hd |> text "id" in
  let unverified = Lane_addon_runtime.dispatch ~caller:owner ~config ~operation:Runtime.Inspect (`Assoc [])
    |> Result.map_error Lane_addon_runtime.error_to_string |> unwrap in
  check Alcotest.int "bare caller attribution never grants private access" 0
    (member "instances" unverified |> Yojson.Safe.Util.to_list |> List.length);
  let tool access name fields =
    let ctx : Tool_misc.context = {config;agent_name=owner;help_schemas=[]} in
    match Tool_misc.dispatch ~lane_access:access ctx ~name ~args:(`Assoc fields) with
    | Some result -> result | None -> fail "Lane tool was not dispatched" in
  let unverified_tool = tool Lane_addon_sources.Unauthenticated "masc_lane_inspect" [] in
  check Alcotest.int "MCP claimed Keeper name does not reveal private instances" 0
    (Tool_result.data unverified_tool |> member "instances" |> Yojson.Safe.Util.to_list |> List.length);
  check bool "unverified tool cannot export private evidence" false
    (Tool_result.is_success (tool Lane_addon_sources.Unauthenticated "masc_lane_evidence"
      ["instance_id",`String id;"row_ids",`List [`String row_id]]));
  check Alcotest.int "verified tool authority still sees its private instance" 1
    (tool (Lane_addon_sources.Keeper owner) "masc_lane_inspect" [] |> Tool_result.data
      |> member "instances" |> Yojson.Safe.Util.to_list |> List.length);
  let denied operation fields = match call foreign operation fields with
    | Error detail -> check string "uniform exact-instance denial" "Lane instance is unavailable to this caller" detail
    | Ok _ -> fail "foreign Keeper accessed private instance" in
  List.iter (fun operation -> denied operation ["instance_id",`String id])
    [Runtime.Inspect;Runtime.Observe;Runtime.Detach;Runtime.Act;Runtime.Action_status];
  denied Runtime.Evidence ["instance_id",`String id;"row_ids",`List [`String row_id]];
  let public = unwrap (call foreign Runtime.Inspect []) in
  check Alcotest.int "unfiltered inspection exposes no private instances" 0
    (member "instances" public |> Yojson.Safe.Util.to_list |> List.length);
  check Alcotest.int "unfiltered inspection exposes no private rows" 0
    (member "rows" public |> Yojson.Safe.Util.to_list |> List.length);
  check Alcotest.int "foreign range query excludes private observations" 0
    (unwrap (call foreign Runtime.Slice []) |> member "rows" |> Yojson.Safe.Util.to_list |> List.length);
  check bool "claimed owner with unauthenticated HTTP access is refused" true
    (Result.is_error (Lane_addon_runtime.dispatch ~caller:owner ~access:Lane_addon_sources.Unauthenticated
      ~config ~operation:Runtime.Inspect (`Assoc ["instance_id",`String id])));
  ignore (unwrap (call owner Runtime.Evidence ["instance_id",`String id;"row_ids",`List [`String row_id]]));
  ignore (unwrap (call owner Runtime.Detach ["instance_id",`String id]));
  await_phase clock config id "detached";
  Runtime.For_testing.reset ();
  check Alcotest.int "owner can read durable rows after host manager restart" 1
    (unwrap (call owner Runtime.Slice []) |> member "rows" |> Yojson.Safe.Util.to_list |> List.length);
  denied Runtime.Inspect ["instance_id",`String id];
  denied Runtime.Evidence ["instance_id",`String id;"row_ids",`List [`String row_id]];
  check Alcotest.int "historical inspection excludes private bindings" 0
    (unwrap (call foreign Runtime.Inspect []) |> member "instances" |> Yojson.Safe.Util.to_list |> List.length))

let test_mcp_attributed_name_is_not_private_lane_authority () =
  with_fixture (fun env sw config dir _state ->
    let owner = "mcp-private-owner" and foreign = "mcp-foreign-owner" in
    ignore (Workspace.init config ~agent_name:(Some owner));
    Auth.disable_auth dir;
    let register name =
      let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String name]) with
        | Ok meta -> meta | Error reason -> fail reason in
      let path = Keeper_types_profile.keeper_meta_path config name in
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file path (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json meta)) in
    register owner; register foreign;
    let anonymous_session = "lane-anonymous-" ^ Store.digest dir in
    let owner_session = "lane-owner-" ^ Store.digest dir in
    let foreign_session = "lane-foreign-" ^ Store.digest dir in
    let operator_session = "lane-operator-" ^ Store.digest dir in
    Fun.protect ~finally:(fun () ->
      List.iter Client_registry_eio.unregister_mcp_session
        [anonymous_session; owner_session; foreign_session; operator_session]) (fun () ->
      check bool "fixture runs with workspace auth disabled" false
        (Auth.is_auth_enabled dir);
      let run_id = "mcp-private-" ^ Store.digest dir in
      Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
        ~keeper:owner ~preset:"default" ~roster:Fusion_types.preset_roster
        ~topology:Fusion_types.Simple ~started_at:1.;
      let binding = `Assoc ["sources", `List [`Assoc [
        "source_id", `String "fusion"; "kind", `String "fusion_run";
        "run_id", `String run_id]]] in
      let id = unwrap (Lane_addon_runtime.dispatch ~caller:owner
        ~access:(Lane_addon_sources.Keeper owner) ~config ~operation:Runtime.Attach
        (`Assoc ["manifest_path", `String (manifest dir "good");
          "run_id", `String "mcp-private-world"; "binding", binding])
        |> Result.map_error Lane_addon_runtime.error_to_string)
        |> text "instance_id" in
      let clock = Eio.Stdenv.clock env in
      await clock (fun () -> int "observation_seq" (instance config id) = 1);
      let state = Mcp_server_eio.For_testing.create_state ~base_path:dir () in
      let execute ?auth_token ~session ~name arguments =
        Mcp_server_eio_execute.execute_tool_eio ~sw ~clock
          ~workspace_scope:(Mcp_server.workspace_scope state)
          ~mcp_session_id:session ?auth_token state ~name ~arguments in
      let inspect ?auth_token session arguments =
        execute ?auth_token ~session ~name:"masc_lane_inspect" arguments in
      let empty = `Assoc [] in
      let first = inspect anonymous_session
        (`Assoc ["_agent_name", `String owner]) in
      (* The MCP pre-hook removes transport markers before schema validation;
         attribution still must not authorize private Lane data. *)
      check bool "first attributed call can inspect shared Lane state" true
        (Tool_result.is_success first);
      check Alcotest.int "first attributed call exposes no private instance" 0
        (member "instances" (Tool_result.data first) |> Yojson.Safe.Util.to_list |> List.length);
      check Alcotest.int "first attributed call exposes no private rows" 0
        (member "rows" (Tool_result.data first) |> Yojson.Safe.Util.to_list |> List.length);
      check bool "first call cached only an attributed name" true
        (match Client_registry_eio.get_resolved_name anonymous_session with
         | Some (name, false) -> String.equal name owner
         | Some _ | None -> false);
      let anonymous = inspect anonymous_session empty in
      check bool "cached-name follow-up can inspect shared Lane state" true
        (Tool_result.is_success anonymous);
      check Alcotest.int "cached attribution exposes no private instance" 0
        (member "instances" (Tool_result.data anonymous) |> Yojson.Safe.Util.to_list |> List.length);
      check Alcotest.int "cached attribution exposes no private rows" 0
        (member "rows" (Tool_result.data anonymous) |> Yojson.Safe.Util.to_list |> List.length);
      let token name role = match Auth.create_token dir ~agent_name:name ~role with
        | Ok (value, _) -> value | Error _ -> fail "credential fixture creation failed" in
      let owner_token = token owner Masc_domain.Worker in
      let foreign_token = token foreign Masc_domain.Worker in
      let operator_token = token "lane-operator" Masc_domain.Admin in
      check bool "credential issuance does not enable workspace auth" false
        (Auth.is_auth_enabled dir);
      let owned = inspect ~auth_token:owner_token owner_session empty in
      check bool "valid Keeper credential reads its private instance" true
        (Tool_result.is_success owned);
      let owned_rows = member "rows" (Tool_result.data owned) |> Yojson.Safe.Util.to_list in
      check Alcotest.int "valid owner sees its private instance" 1
        (member "instances" (Tool_result.data owned) |> Yojson.Safe.Util.to_list |> List.length);
      check Alcotest.int "valid owner sees its private row" 1 (List.length owned_rows);
      let row_id = text "id" (List.hd owned_rows) in
      let anonymous_evidence = execute ~session:anonymous_session
        ~name:"masc_lane_evidence"
        (`Assoc ["instance_id", `String id; "row_ids", `List [`String row_id]]) in
      check bool "cached attribution cannot preserve private evidence" false
        (Tool_result.is_success anonymous_evidence);
      let foreign_view = inspect ~auth_token:foreign_token foreign_session empty in
      check bool "foreign valid Keeper can inspect shared Lane state" true
        (Tool_result.is_success foreign_view);
      check Alcotest.int "foreign valid Keeper cannot see another Keeper's instance" 0
        (member "instances" (Tool_result.data foreign_view)
         |> Yojson.Safe.Util.to_list |> List.length);
      let operator_view = inspect ~auth_token:operator_token operator_session empty in
      check bool "valid operator credential retains configuration authority" true
        (Tool_result.is_success operator_view);
      check Alcotest.int "operator sees private instance" 1
        (member "instances" (Tool_result.data operator_view)
         |> Yojson.Safe.Util.to_list |> List.length);
      detach config id;
      await_phase clock config id "detached"))
;;

let test_private_broadcast_retry_uses_saved_visibility () = with_fixture (fun env _ config dir _ ->
  let owner = "private-broadcast-owner" in
  ignore (Workspace.init config ~agent_name:(Some owner));
  let run_id = "private-broadcast-" ^ Store.digest dir in
  Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
    ~keeper:owner ~preset:"default" ~roster:Fusion_types.preset_roster
    ~topology:Fusion_types.Simple ~started_at:1.;
  let id = Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Attach
    (`Assoc ["manifest_path",`String (manifest dir "good");"run_id",`String "private-world";
      "binding",`Assoc ["sources",`List [`Assoc ["source_id",`String "fusion";
        "kind",`String "fusion_run";"run_id",`String run_id]]]]) |> unwrap |> text "instance_id" in
  let clock = Eio.Stdenv.clock env in
  await clock (fun () -> int "observation_seq" (instance config id) = 1);
  let selected = Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Inspect
    (`Assoc ["instance_id",`String id]) |> unwrap |> member "rows"
    |> Yojson.Safe.Util.to_list |> List.hd |> text "id" in
  let args = `Assoc ["instance_id",`String id;"row_ids",`List [`String selected];
    "broadcast",`Bool true;"request_id",`String "private-send"] in
  let send caller access = Lane_addon_runtime.dispatch ~caller ~access ~config
    ~operation:Runtime.Evidence args in
  let original = send owner (Lane_addon_sources.Keeper owner)
    |> Result.map_error Lane_addon_runtime.error_to_string |> unwrap in
  check string "explicit private Broadcast commits" "committed"
    (member "delivery" original |> text "status");
  let alias_context : Tool_misc.context =
    {config;agent_name="bound-session-alias";help_schemas=[]} in
  let alias_args = `Assoc ["instance_id",`String id;"row_ids",`List [`String selected];
    "broadcast",`Bool true;"request_id",`String "verified-alias-send"] in
  let alias_result = match Tool_misc.dispatch
    ~lane_access:(Lane_addon_sources.Keeper owner) alias_context
    ~name:"masc_lane_evidence" ~args:alias_args with
    | Some result -> result | None -> fail "Lane evidence facade was not dispatched" in
  check bool "verified Keeper alias can send as its canonical Lane owner" true
    (Tool_result.is_success alias_result);
  check string "alias Broadcast commits under the verified Keeper" "committed"
    (Tool_result.data alias_result |> member "delivery" |> text "status");
  let store_root = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  let store = Store.create ~root:store_root in
  let broadcast_id = member "delivery" original |> member "receipt" |> text "request_id" in
  let prepared = Store.load_broadcast store ~instance_id:id ~request_id:broadcast_id |> unwrap
    |> (function Some value -> value | None -> fail "prepared Broadcast record missing") in
  check string "prepared operation retains authoritative exact owner" owner
    (prepared |> member "visibility" |> text "keeper");
  ignore (Runtime.dispatch ~caller:owner ~config ~operation:Runtime.Detach
    (`Assoc ["instance_id",`String id]) |> unwrap);
  await_phase clock config id "detached";
  unwrap (Store.remove_binding store ~instance_id:id);
  remove_tree (Filename.concat store_root (Filename.concat "observations" (Store.digest id)));
  Runtime.For_testing.reset ();
  Runtime.register_fleet_backend {
    snapshot=(fun ~config:_ ~caller:_ ~access:_ -> fail "cached private retry must retain its accepted audience");
    project=(fun ~config:_ ~sender_authority:_ ~delivery:_ ~recipient:_ -> Error "private retry does not inline projection")};
  check bool "unverified claimed owner cannot retrieve cached private evidence" true
    (Result.is_error (send owner Lane_addon_sources.Unauthenticated));
  check bool "foreign caller cannot retrieve cached private evidence" true
    (Result.is_error (send "foreign" (Lane_addon_sources.Keeper "foreign")));
  check bool "access principal cannot impersonate saved caller" true
    (Result.is_error (send owner (Lane_addon_sources.Keeper "foreign")));
  let missing = `Assoc (List.remove_assoc "visibility" (Yojson.Safe.Util.to_assoc prepared)) in
  unwrap (Store.save_broadcast store ~instance_id:id ~request_id:broadcast_id missing);
  check bool "missing saved visibility fails closed without original binding" true
    (Result.is_error (send owner (Lane_addon_sources.Keeper owner)));
  unwrap (Store.save_broadcast store ~instance_id:id ~request_id:broadcast_id prepared);
  let recovered = send owner (Lane_addon_sources.Keeper owner)
    |> Result.map_error Lane_addon_runtime.error_to_string |> unwrap in
  check bool "owner recovers exact committed receipt without original binding" true
    (member "delivery" recovered = member "delivery" original);
  check bool "owner recovers exact retained artifact" true
    (member "keeper_artifact" recovered = member "keeper_artifact" original))

let fleet_record config operation =
  let module Ledger = Masc.Lane_addon_broadcast_delivery in
  let ledger=Ledger.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons/fleet-delivery") in
  let operation_id=Ledger.Request_id.of_string operation |> unwrap in
  match Eio_unix.run_in_systhread (fun () -> Ledger.find ledger ~caller:"fixture-operator" ~operation_id) with
  | Ok (Some receipt) -> receipt.record
  | Ok None -> fail "Fleet intention absent"
  | Error _ -> fail "Fleet intention lookup failed"

let fleet_recipient config operation recipient =
  List.assoc recipient (fleet_record config operation).recipients

let fleet_complete config operation =
  Masc.Lane_addon_broadcast_delivery.complete (fleet_record config operation)

let test_broadcast_retry_reconciles_receipt_during_slow_fanout () =
  with_fixture (fun env sw config dir _ ->
    ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let selected = inspect config |> member "rows" |> Yojson.Safe.Util.to_list |> List.hd |> text "id" in
    let args = `Assoc ["instance_id",`String id;"row_ids",`List [`String selected];
      "broadcast",`Bool true;"request_id",`String "slow-send"] in
    let entered, mark_entered = Eio.Promise.create () in
    let release, mark_released = Eio.Promise.create () in
    let before_commit, mark_before_commit = Eio.Promise.create () in
    let allow_commit, mark_allow_commit = Eio.Promise.create () in
    let retry_waiting, mark_retry_waiting = Eio.Promise.create () in
    let cancelled_waiter, mark_cancelled_waiter = Eio.Promise.create () in
    let waiter_context, mark_waiter_context = Eio.Promise.create () in
    let waiters = ref 0 in
    let writes = ref 0 in
    let previous_write = Workspace_broadcast.For_testing.replace_write_json_commit
      (fun config path json ->
        incr writes;
        if !writes=1 then (
          Eio.Promise.resolve mark_before_commit ();
          Eio.Promise.await allow_commit);
        Workspace_utils.write_json_commit_result config path json) in
    let previous_wait = Workspace_broadcast.For_testing.replace_on_exact_request_wait
      (fun _request_id ->
        incr waiters;
        if !waiters=1 then Eio.Promise.resolve mark_cancelled_waiter ()
        else if !waiters=2 then Eio.Promise.resolve mark_retry_waiting ()) in
    let failed = ref true and block = ref true in
    let roster = ref ["keeper-a";"keeper-b"] in
    let sender_authority=ref Masc.Lane_addon_broadcast_delivery.Keeper_sender in
    let projected_authorities=ref [] in
    let calls = ref [] and immediate_calls = ref 0 in
    let install () = Runtime.register_fleet_backend {
      snapshot=(fun ~config:_ ~caller:_ ~access:_ -> Ok (!sender_authority,!roster));
      project=(fun ~config:_ ~sender_authority ~delivery ~recipient ->
        projected_authorities:=sender_authority::!projected_authorities;
        calls := (recipient,delivery.Workspace_broadcast.request_id)::!calls;
        if recipient="keeper-a" && !block then (
          Eio.Promise.resolve mark_entered (); Eio.Promise.await release);
        if recipient="keeper-b" && !failed then Error "fixture recipient store unavailable" else Ok ())} in
    install ();
    let previous=Workspace_broadcast.For_testing.replace_on_broadcast_mention (fun _ ->
      incr immediate_calls; Workspace_broadcast.Passive) in
    Fun.protect ~finally:(fun () ->
      let (_ : Workspace_broadcast.broadcast_delivery -> Workspace_broadcast.mention_delivery) =
        Workspace_broadcast.For_testing.replace_on_broadcast_mention previous in
      let (_ : string -> unit) =
        Workspace_broadcast.For_testing.replace_on_exact_request_wait previous_wait in
      let (_ : Workspace_utils_backend_setup.config -> string -> Yojson.Safe.t ->
        (Workspace_utils.write_json_commit, string) result) =
        Workspace_broadcast.For_testing.replace_write_json_commit previous_write in
      if not (Eio.Promise.is_resolved allow_commit) then Eio.Promise.resolve mark_allow_commit ();
      if not (Eio.Promise.is_resolved release) then Eio.Promise.resolve mark_released ()) (fun () ->
      let send () = Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence args |> unwrap in
      let first = Eio.Fiber.fork_promise ~sw send in
      Eio.Promise.await before_commit;
      let cancelled_retry = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub (fun context ->
          Eio.Promise.resolve mark_waiter_context context;
          send ())) in
      Eio.Promise.await cancelled_waiter;
      Eio.Cancel.cancel (Eio.Promise.await waiter_context) Exit;
      (match Eio.Promise.await cancelled_retry with
       | Error (Eio.Cancel.Cancelled _) -> ()
       | Error error -> raise error
       | Ok _ -> Alcotest.fail "cancelled precommit retry must propagate cancellation");
      check bool "cancelled waiter leaves the original owner waiting" false (Eio.Promise.is_resolved first);
      let retry = Eio.Fiber.fork_promise ~sw send in
      Eio.Promise.await retry_waiting;
      check bool "retry arrived before the authoritative row" false (Eio.Promise.is_resolved retry);
      Eio.Promise.resolve mark_allow_commit ();
      let original=Eio.Promise.await_exn first in
      let precommit_replay=Eio.Promise.await_exn retry in
      check Alcotest.int "precommit retries create one authoritative message" 1 !writes;
      check bool "precommit retry preserves the committed receipt" true
        (member "delivery" original=member "delivery" precommit_replay);
      check string "durable message receipt returns before any recipient projection" "committed"
        (member "delivery" original |> text "status");
      check string "committed receipt transfers recovery to the durable recipient ledger" "durable_admitted"
        (member "delivery" original |> member "receipt" |> text "fanout_state");
      check Alcotest.int "publication does not run synchronous fleet handler" 0 !immediate_calls;
      check Alcotest.int "publication does not inline root recipient work" 0 (List.length !calls);
      unwrap (Runtime.recover_fleet ~config ~sw);
      Eio.Promise.await entered;
      await clock (fun () -> match fleet_recipient config "slow-send" "keeper-b" with
        | Masc.Lane_addon_broadcast_delivery.Pending (Some _) -> true
        | Accepted | Pending None -> false);
      ignore (unwrap (dispatch config Runtime.Observe ["instance_id",`String id]));
      await clock (fun () -> int "observation_seq" (instance config id) = 2);
      let replay=send () in
      check bool "first recipient remains blocked after scheduling returns" false (Eio.Promise.is_resolved release);
      check bool "same-key retry preserves exact committed receipt during drain" true
        (member "delivery" original = member "delivery" replay);
      check bool "retry preserves original artifact despite changed live metadata" true
        (member "keeper_artifact" original = member "keeper_artifact" replay);
      check Alcotest.int "both recipients progress independently without replay" 2 (List.length !calls);
      check bool "ordinary Broadcast still uses its existing synchronous behavior" true
        (Result.is_ok (Workspace_broadcast.broadcast_once config
          ~request_id:("wmsg-" ^ String.make 32 'b') ~from_agent:"fixture-operator" ~content:"independent message"));
      check Alcotest.int "ordinary caller still reaches existing handler" 1 !immediate_calls;
      block:=false; Eio.Promise.resolve mark_released ();
      await clock (fun () -> fleet_recipient config "slow-send" "keeper-a"
        = Masc.Lane_addon_broadcast_delivery.Accepted);
      check bool "partial recipient failure remains durably pending" true
        (match fleet_recipient config "slow-send" "keeper-b" with
         | Masc.Lane_addon_broadcast_delivery.Pending (Some _) -> true
         | Accepted | Pending None -> false);
      let receipt=member "delivery" original |> member "receipt" in
      let request_id=text "request_id" receipt in
      check bool "same identity cannot replace committed content" true
        (Result.is_error (Workspace_broadcast.broadcast_once config
          ~request_id ~from_agent:"fixture-operator" ~content:"different content"));
      detach config id; await_phase clock config id "detached";
      let store_root=Filename.concat (Workspace.masc_dir config) "lane-addons" in
      unwrap (Store.remove_binding (Store.create ~root:store_root) ~instance_id:id);
      remove_tree (Filename.concat store_root (Filename.concat "observations" (Store.digest id)));
      Runtime.For_testing.reset (); sender_authority:=Masc.Lane_addon_broadcast_delivery.External_sender; roster:=["keeper-a";"keeper-b";"new-keeper"]; failed:=false; install ();
      let recovered=send () in
      check bool "restart reconciles receipt after original source disappears" true
        (member "delivery" recovered = member "delivery" original);
      check bool "restart retains original artifact" true
        (member "keeper_artifact" recovered = member "keeper_artifact" original);
      unwrap (Runtime.recover_fleet ~config ~sw);
      await clock (fun () -> fleet_complete config "slow-send");
      let count recipient=List.length (List.filter (fun (name,_) -> name=recipient) !calls) in
      check Alcotest.int "accepted recipient is not projected again after restart" 1 (count "keeper-a");
      check Alcotest.int "failed recipient is retried once using original identity" 2 (count "keeper-b");
      check Alcotest.int "new roster member is outside accepted audience" 0 (count "new-keeper");
      check bool "all recipient attempts share one authoritative message identity" true
        (List.for_all (fun (_,id) -> id=request_id) !calls);
      unwrap (Runtime.recover_fleet ~config ~sw);
      check Alcotest.int "completed drain launches no further recipient work" 3 (List.length !calls);
      check bool "sender authority survives restart and registry change" true
        (List.for_all ((=) Masc.Lane_addon_broadcast_delivery.Keeper_sender) !projected_authorities)))

let test_fleet_service_isolates_blocked_recipient_and_admissions () =
  with_fixture (fun env sw config dir _ ->
    ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
    let clock=Eio.Stdenv.clock env in
    let id=attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let selected=inspect config |> member "rows" |> Yojson.Safe.Util.to_list |> List.hd |> text "id" in
    let send operation=Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
      (`Assoc ["instance_id",`String id;"row_ids",`List [`String selected];
        "broadcast",`Bool true;"request_id",`String operation]) |> unwrap in
    let first_request=ref None and blocked=ref true in
    let entered,mark_entered=Eio.Promise.create () in
    let release,_=Eio.Promise.create () in
    let calls=ref [] in
    Runtime.register_fleet_backend {
      snapshot=(fun ~config:_ ~caller:_ ~access:_ -> Ok (Masc.Lane_addon_broadcast_delivery.Keeper_sender,
        ["keeper-a";"keeper-b"]));
      project=(fun ~config:_ ~sender_authority:_ ~delivery ~recipient ->
        calls:=(delivery.Workspace_broadcast.request_id,recipient)::!calls;
        if Some delivery.request_id = !first_request && recipient="keeper-a" && !blocked then begin
          ignore (Eio.Promise.try_resolve mark_entered ());
          Eio.Promise.await release
        end;
        Ok ())};
    let original=send "blocked-operation" in
    let first_id=member "delivery" original |> member "receipt" |> text "request_id" in
    first_request:=Some first_id;
    let ready,mark_ready=Eio.Promise.create () in
    let stay,_=Eio.Promise.create () in
    let exception Stop_fixture_service in
    let service=Eio.Fiber.fork_promise ~sw (fun () ->
      try Eio.Cancel.sub (fun cancellation ->
        Eio.Switch.run (fun service_sw ->
          Runtime.start_fleet_service ~config ~sw:service_sw ~clock;
          Eio.Promise.resolve mark_ready (service_sw,cancellation);
          Eio.Promise.await stay))
      with Eio.Cancel.Cancelled Stop_fixture_service -> ()) in
    let service_sw,cancellation=Eio.Promise.await ready in
    (* Kick the real service after it owns the root. The admitted replay's
       nudge must dispatch a beat, not an awaited recipient drain. *)
    ignore (send "blocked-operation");
    Eio.Promise.await entered;
    await clock (fun () -> fleet_recipient config "blocked-operation" "keeper-b"
      = Masc.Lane_addon_broadcast_delivery.Accepted);
    check bool "first recipient is still blocked while second settles" true !blocked;
    let count request recipient=List.length (List.filter (fun pair -> pair=(request,recipient)) !calls) in
    (* Overlapping authoritative scans must share a still-owned projection,
       including when their snapshots were read before another acceptance. *)
    unwrap (Runtime.recover_fleet ~config ~sw:service_sw);
    unwrap (Runtime.recover_fleet ~config ~sw:service_sw);
    let later=send "separately-admitted-operation" in
    let later_id=member "delivery" later |> member "receipt" |> text "request_id" in
    (* No manual drain after this send: its production admission nudge must
       be handled even though the older recipient has not returned. *)
    await clock (fun () -> fleet_complete config "separately-admitted-operation");
    check Alcotest.int "duplicate scans launch blocked request/recipient once" 1 (count first_id "keeper-a");
    check Alcotest.int "accepted second recipient is not reprojected" 1 (count first_id "keeper-b");
    check Alcotest.int "separate admission delivers first recipient" 1 (count later_id "keeper-a");
    check Alcotest.int "separate admission delivers second recipient" 1 (count later_id "keeper-b");
    check bool "independent admission did not release blocked work" false (Eio.Promise.is_resolved release);
    Eio.Cancel.cancel cancellation Stop_fixture_service;
    Eio.Promise.await_exn service;
    check bool "cancelled projection retains its pending obligation" true
      (match fleet_recipient config "blocked-operation" "keeper-a" with
       | Masc.Lane_addon_broadcast_delivery.Pending _ -> true | Accepted -> false);
    check bool "independent completed message stays completed" true
      (fleet_complete config "separately-admitted-operation");
    blocked:=false;
    unwrap (Runtime.recover_fleet ~config ~sw);
    await clock (fun () -> fleet_complete config "blocked-operation");
    check Alcotest.int "cancellation releases ownership for one retry" 2 (count first_id "keeper-a");
    check Alcotest.int "retry does not repeat its accepted sibling" 1 (count first_id "keeper-b");
    let replay=send "blocked-operation" in
    check bool "cancellation and retry preserve the original workspace receipt" true
      (member "delivery" original = member "delivery" replay);
    detach config id; await_phase clock config id "detached")

let test_broadcast_pending_commit_recovers_same_identity () =
  with_fixture (fun env sw config dir _ ->
    ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    let selected = inspect config |> member "rows" |> Yojson.Safe.Util.to_list |> List.hd |> text "id" in
    let args = ["instance_id",`String id;"row_ids",`List [`String selected]] in
    let send_id = ["request_id",`String "failed-send"] in
    let attempts = ref 0 in
    let previous = Workspace_broadcast.For_testing.replace_write_json_commit
      (fun _ _ _ -> incr attempts; Error "fixture authoritative write rejected") in
    let result = Fun.protect ~finally:(fun () ->
      let (_ : Workspace_utils_backend_setup.config -> string -> Yojson.Safe.t ->
        (Workspace_utils.write_json_commit, string) result) =
        Workspace_broadcast.For_testing.replace_write_json_commit previous in
      ()) (fun () ->
        check bool "two destinations are refused before publication" true
          (Result.is_error (Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
            (`Assoc (args @ ["broadcast",`Bool true;"keeper_name",`String "someone"]))));
        check bool "nonboolean Broadcast is refused" true
          (Result.is_error (Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
            (`Assoc (args @ ["broadcast",`String "true"]))));
        let unauthenticated = dispatch config Runtime.Evidence (args @ send_id @ ["broadcast",`Bool true]) |> unwrap in
        check string "sharing requires an authenticated caller" "failed"
          (member "delivery" unauthenticated |> text "status");
        check Alcotest.int "invalid requests never reach Broadcast" 0 !attempts;
        Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
          (`Assoc (args @ send_id @ ["broadcast",`Bool true])) |> unwrap) in
    check string "admitted intention remains queued while authoritative commit is rejected" "pending_commit"
      (member "delivery" result |> text "status");
    check bool "rejected workspace commit cannot transfer client retry ownership" true
      (member "delivery" result |> member "receipt" = `Null);
    let evidence = member "evidence" result in
    check bool "failed Broadcast retains the exact selected evidence" true
      (Sys.file_exists (text "path" evidence));
    check Alcotest.int "one explicit request attempts one message write" 1 !attempts;
    ignore (unwrap (dispatch config Runtime.Inspect []));
    ignore (unwrap (dispatch config Runtime.Evidence args));
    check Alcotest.int "inspection and preservation never rebroadcast" 1 !attempts;
    let projections = ref [] in
    Runtime.register_fleet_backend {
      snapshot=(fun ~config:_ ~caller:_ ~access:_ -> fail "recovery must retain the admitted empty audience");
      project=(fun ~config:_ ~sender_authority:_ ~delivery:_ ~recipient -> projections:=recipient::!projections; Ok ())};
    unwrap (Runtime.recover_fleet ~config ~sw);
    await clock (fun () -> fleet_complete config "failed-send");
    let recovered = Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
      (`Assoc (args @ send_id @ ["broadcast",`Bool true])) |> unwrap in
    check string "queued intention becomes committed after storage recovers" "committed"
      (member "delivery" recovered |> text "status");
    check bool "commit recovery retains the exact published artifact" true
      (member "keeper_artifact" recovered = member "keeper_artifact" result);
    let receipt = member "delivery" recovered |> member "receipt" in
    let found = Workspace_broadcast.find_broadcast ~request_id:(text "request_id" receipt)
      config ~from_agent:"fixture-operator" ~content:(text "message" recovered) in
    check bool "recovery finds the authoritative exact request without a new publication" true
      (match found with Ok (Some delivery) -> delivery.seq = int "seq" receipt | _ -> false);
    unwrap (Runtime.recover_fleet ~config ~sw);
    check Alcotest.int "empty accepted audience stays empty despite the later backend" 0
      (List.length !projections);
    Runtime.register_delivery_handler (fun ~config:_ ~caller:_ ~keeper_name:_ ~prompt:_ ->
      failwith "fixture recipient raised after accepting");
    let uncertain = Runtime.dispatch ~caller:"fixture-operator" ~config ~operation:Runtime.Evidence
      (`Assoc (args @ ["keeper_name",`String "fixture-recipient"])) |> unwrap in
    check string "a recipient exception is uncertain, not a proven rejection" "outcome_unknown"
      (member "delivery" uncertain |> text "status");
    check bool "uncertain delivery preserves evidence" true
      (Sys.file_exists (member "evidence" uncertain |> text "path"));
    detach config id; await_phase clock config id "detached")

let test_released_shared_bindings_keep_read_and_cleanup () =
  with_fixture (fun env _sw config dir state ->
    let clock = Eio.Stdenv.clock env in
    let id = attach config dir "good" in
    await clock (fun () -> int "observation_seq" (instance config id) = 1);
    detach config id; await_phase clock config id "detached";
    let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
    (* Inspect adds presentation fields; a published binding is the durable
       record, whose exact shape the released reader must continue to enforce. *)
    let captured = unwrap (Store.bindings store)
      |> List.find (fun value -> text "instance_id" value = id)
      |> Yojson.Safe.Util.to_assoc in
    let released = List.remove_assoc "visibility" (List.remove_assoc "source_access" captured) in
    (* The published package envelope predates host model declarations. *)
    let released = List.map (fun (key, value) ->
      match key, value with
      | "package", `Assoc fields -> key, `Assoc (List.remove_assoc "model_access" fields)
      | _ -> key, value) released in
    let before = `Assoc released in
    unwrap (Store.save_binding store ~instance_id:id before);
    Runtime.For_testing.reset ();
    let observed = instance config id in
    check string "released reads carry no operator acquisition authority" "unauthenticated"
      (observed |> member "source_access" |> text "kind");
    check Alcotest.int "released direct retained rows remain readable" 1
      (unwrap (dispatch config Runtime.Slice []) |> member "rows" |> Yojson.Safe.Util.to_list |> List.length);
    check bool "read recognition leaves durable bytes unchanged" true
      (unwrap (Store.bindings store) = [before]);
    let set fields key value = (key,value)::List.remove_assoc key fields in
    let record name installation sources =
      released |> fun f -> set f "instance_id" (`String name)
      |> fun f -> set f "incarnation" (`String name)
      |> fun f -> set f "configuration" (`Assoc ["id",`String installation;
          "source_path",`String (Filename.concat dir (installation ^ ".toml"));
          "revision",`String (Store.digest installation)])
      |> fun f -> set f "binding" (`Assoc ["sources",`List sources]) |> fun f -> `Assoc f in
    let upstream installation = `Assoc ["source_id",`String "upstream";"kind",`String "lane_output";
      "installation_id",`String installation;"selection",`String "latest_completed"] in
    let producer = record "released-producer" "producer" [] in
    let consumer = record "released-consumer" "consumer" [upstream "producer"] in
    let authorize bindings value = Runtime.authorize_retained_read ~bindings
      ~access:Lane_addon_sources.Unauthenticated value in
    check bool "released composed graph is shared only with its unique producer" true
      (Result.is_ok (authorize [producer;consumer] consumer));
    let refused label bindings value = check bool label true (Result.is_error (authorize bindings value)) in
    let current_producer model_access = match producer with
      | `Assoc f ->
          let package = List.assoc "package" f |> Yojson.Safe.Util.to_assoc in
          `Assoc (("visibility", `Assoc ["kind",`String "shared"]) ::
            ("source_access",Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated) ::
            set f "package" (`Assoc (("model_access",model_access)::package)))
      | _ -> assert false in
    List.iter (fun model_access ->
      check bool "released consumer reads current shared producer without rewriting it" true
        (Result.is_ok (authorize [current_producer (`String model_access);consumer] consumer)))
      ["disabled";"host_sampling"];
    let with_producer_package transform = match current_producer (`String "disabled") with
      | `Assoc f ->
          let package = List.assoc "package" f |> Yojson.Safe.Util.to_assoc in
          `Assoc (set f "package" (`Assoc (transform package)))
      | _ -> assert false in
    let pre_model_producer = with_producer_package (List.remove_assoc "model_access") in
    check bool "released consumer reads authority-bearing pre-model producer" true
      (Result.is_ok (authorize [pre_model_producer;consumer] consumer));
    List.iter (fun model_access ->
      refused "invalid explicit model access fails closed"
        [current_producer model_access;consumer] consumer)
      [`String "unknown"; `Null; `Bool false];
    let duplicate_model = with_producer_package (fun fields ->
      ("model_access",`String "disabled")::fields) in
    refused "duplicate producer model field fails closed" [duplicate_model;consumer] consumer;
    let unknown_pre_model = with_producer_package (fun fields ->
      ("unknown",`Bool true)::List.remove_assoc "model_access" fields) in
    refused "unknown pre-model producer field fails closed" [unknown_pre_model;consumer] consumer;
    let forged_released = match current_producer (`String "disabled") with
      | `Assoc f -> `Assoc (List.remove_assoc "visibility" (List.remove_assoc "source_access" f))
      | _ -> assert false in
    refused "released envelope cannot smuggle current package fields" [forged_released] forged_released;
    refused "missing producer fails closed" [consumer] consumer;
    refused "ambiguous producer incarnation fails closed" [producer;producer;consumer] consumer;
    let cycle = record "released-producer" "producer" [upstream "consumer"] in
    refused "producer cycles fail closed" [cycle;consumer] consumer;
    let private_producer = match producer with `Assoc f -> `Assoc (("visibility",`Assoc ["kind",`String "keeper";"keeper",`String "other"])
      ::("source_access",Lane_addon_sources.access_to_json (Lane_addon_sources.Keeper "other"))::f) | _ -> assert false in
    refused "private producer never becomes shared" [private_producer;consumer] consumer;
    let private_without_authority = record "released-producer" "producer" [`Assoc [
      "source_id",`String "fusion";"kind",`String "fusion_run";"run_id",`String "private-run"]] in
    refused "private source missing both authority fields is refused" [private_without_authority;consumer] consumer;
    let malformed = match producer with `Assoc f -> `Assoc (set f "observation_seq" `Null) | _ -> assert false in
    refused "malformed released record is refused" [malformed] malformed;
    let unknown = match producer with `Assoc f -> `Assoc (("unknown",`Bool true)::f) | _ -> assert false in
    refused "unknown released record field is refused" [unknown] unknown;
    let missing_modern = `Assoc (List.remove_assoc "visibility" captured) in
    refused "current source access without visibility is refused" [missing_modern] missing_modern;
    unwrap (Store.save_binding store ~instance_id:id (`Assoc (set released "phase" (Types.phase_to_json Types.Attached))));
    detach config id; await_phase clock config id "detached";
    check Alcotest.int "released surviving container retains exact cleanup ownership" 1 (List.length !(state.recovery)))

let () = run "Lane Add-on runtime" ["optional extension", [
  test_case "invalid retained visibility is isolated" `Quick test_invalid_retained_visibility_is_isolated;
  test_case "MCP attribution never authorizes private Lane reads" `Quick
    test_mcp_attribution_does_not_authorize_private_lane;
  test_case "Fleet service isolates blocked recipients, later admissions and cancellation" `Quick
    test_fleet_service_isolates_blocked_recipient_and_admissions;
  test_case "private Broadcast retry uses saved visibility after binding removal" `Quick
    test_private_broadcast_retry_uses_saved_visibility;
  test_case "Broadcast retry reconciles the committed receipt during slow fanout" `Quick
    test_broadcast_retry_reconciles_receipt_during_slow_fanout;
  test_case "Broadcast intention and failed commit retain exact evidence" `Quick
    test_broadcast_pending_commit_recovers_same_identity;
  test_case "Fusion read ownership survives retirement and restart" `Quick test_private_fusion_reads_survive_retirement;
  test_case "published shared bindings retain read and exact cleanup authority" `Quick
    test_released_shared_bindings_keep_read_and_cleanup;
  test_case "MCP attribution never grants private Lane authority" `Quick
    test_mcp_attributed_name_is_not_private_lane_authority;
  test_case "Fusion state hint wakes only the exact run binding" `Quick
    test_fusion_status_hint_wakes_only_its_bound_run;
  test_case "a human MSX press wakes machine watchers exactly once" `Quick
    test_human_press_wakes_machine_watchers_once;
  test_case "a human MSX load wakes machine watchers exactly once" `Quick
    test_human_load_wakes_machine_watchers_once;
  test_case "activity from another domain is delivered on the owner domain" `Quick
    test_activity_from_another_domain_reaches_the_owner;
  test_case "a capture yielding to detach preserves cleanup ownership" `Quick
    test_capture_cannot_rewrite_detach_failure;
  test_case "activity probes exact file captures while explicit observes remain stateful" `Quick
    test_file_activity_preserves_explicit_observation;
  test_case "direct attach enforces package binding before worker startup" `Quick
    test_direct_attach_validates_package_binding;
  test_case "missing targets refuse while storage failures remain faults" `Quick
    test_request_refusals_preserve_runtime_failure_distinction;
  test_case "hung and failed observers preserve primary progress" `Quick test_hang_error_coalescing_and_primary_progress;
  test_case "startup and cleanup failures stay local" `Quick test_start_and_cleanup_failures_remain_optional;
  test_case "evidence remains optional and durable across detach" `Quick test_evidence_is_optional_retained_and_delivery_is_only_acceptance;
]]
