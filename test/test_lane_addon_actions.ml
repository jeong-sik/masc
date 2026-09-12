(** Public action workflow with real manifests, runtime queues and durable
    receipts. Only the external worker is replaced by explicit barriers. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Action = Lane_addon_action
module Types = Lane_addon_types
module Store = Lane_addon_store

let unwrap = function Ok value -> value | Error message -> fail message
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let number key json = member key json |> Yojson.Safe.Util.to_int
let values key json = member key json |> Yojson.Safe.Util.to_list
let obj fields = `Assoc fields
let str value = `String value
let strings values = `List (List.map str values)
let object_schema properties = obj ["type",str "object"; "properties",obj properties;
  "required",strings (List.map fst properties); "additionalProperties",`Bool false]
let string_schema = obj ["type",str "string"]
let schema = object_schema [
  "context",object_schema ["instance_id",string_schema;"incarnation",string_schema];
  "request_id",string_schema;
  "action",object_schema ["steps",obj ["type",str "integer";"minimum",`Int 1;"maximum",`Int 2]]]
let output : Types.output = {rows=[{id="state";lane_id="state";kind=Types.Event;
  title="Observed state";observed_at=1.;subject_id="owned-fixture";clock=None;
  actor=None;fields=[];evidence=[];related_ids=[]}];coverage=[]}
type outcome = Confirm | Refuse | Unknown | Lost_reply
type fixture = {config:Workspace.config; root:string; calls:int ref;
  outcome:outcome ref; barrier:unit Eio.Promise.t option ref}
let backend fixture : Runtime.For_testing.backend = {
  start=(fun ~sw:_ ~instance_id ~(package:Types.package) ~on_created ->
    let connection : Runtime.For_testing.connection = {
      container_id=Store.digest instance_id;
      action_schema=(fun () -> Option.map (fun _ -> schema) package.action_tool);
      observe=(fun ~binding:_ ~sources:_ -> Ok output);
      act=(fun ~arguments ->
        incr fixture.calls;
        Option.iter Eio.Promise.await !(fixture.barrier);
        match !(fixture.outcome) with
        | Lost_reply -> Error "transport closed after dispatch"
        | Confirm | Refuse | Unknown as outcome ->
            let status = match outcome with Confirm -> Action.Package_confirmed
              | Refuse -> Action.Package_failed_before_effect
              | Unknown -> Action.Package_outcome_unknown | Lost_reply -> assert false in
            let output = {output with rows=List.map (fun (row:Types.row) ->
              {row with fields=["action_request",str (text "request_id" arguments)]}) output.rows} in
            Ok {Action.status;result=obj ["calls",`Int !(fixture.calls)];output});
      stop=(fun () -> Ok ())} in
    on_created connection; Ok connection);
  acquire=(fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop=(fun ~instance_id:_ ~container_id:_ ~max_reply_bytes:_ -> Ok ())}
let dispatch fixture operation fields =
  Runtime.dispatch ~caller:"authenticated-tester" ~config:fixture.config ~operation (obj fields)
let inspect fixture id = dispatch fixture Runtime.Inspect ["instance_id",str id] |> unwrap
  |> values "instances" |> List.hd
let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001;loop ()) in loop ()
let attach clock fixture ~acting =
  let name = if acting then "actor" else "observer" in
  let path = Filename.concat fixture.root (name ^ ".toml") in
  let manifest = Printf.sprintf {|id = %S
revision = "fixture-1"
title = "Owned fixture"
image = "fixture/worker"
command = ["worker"]
contributions = %s
%s
[resources]
cpus = 0.5
memory_bytes = 67108864
pids = 16
max_reply_bytes = 65536
|} name (if acting then "[\"observe\",\"act\"]" else "[\"observe\"]")
    (if acting then "[world.actions]\ntool = \"lane_act\"" else "") in
  Out_channel.with_open_bin path (fun channel -> output_string channel manifest);
  let instance = dispatch fixture Runtime.Attach ["manifest_path",str path;
    "run_id",str "action-world";"binding",obj ["sources",`List []]] |> unwrap in
  let id = text "instance_id" instance in
  await clock (fun () -> number "observation_seq" (inspect fixture id) > 0);
  id
let request ?incarnation id request_id steps = ["instance_id",str id;
  "expected_incarnation",str (Option.value ~default:id incarnation);
  "request_id",str request_id;"action",obj ["steps",steps]]
let act fixture id request_id steps = dispatch fixture Runtime.Act (request id request_id steps)
let status fixture id request_id = dispatch fixture Runtime.Action_status
  ["instance_id",str id;"request_id",str request_id] |> unwrap
let await_state clock fixture id request_id expected =
  await clock (fun () -> text "state" (status fixture id request_id) = expected);
  status fixture id request_id
let detach clock fixture id =
  ignore (dispatch fixture Runtime.Detach ["instance_id",str id] |> unwrap);
  await clock (fun () -> inspect fixture id |> member "phase" |> text "kind" = "detached")
let rec remove_tree path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()
let with_fixture f =
  let root = Filename.temp_dir "lane-action-workflow-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 15. (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
            ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Runtime.For_testing.reset ();
              let fixture = {config=Workspace.default_config root;root;calls=ref 0;
                outcome=ref Confirm;barrier=ref None} in
              Runtime.For_testing.with_backend (backend fixture) (fun () -> f clock fixture))))))
let rejects label = function Error _ -> () | Ok value -> failf "%s accepted: %s" label (Yojson.Safe.to_string value)

let test_one_request_one_effect () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let barrier, release = Eio.Promise.create () in fixture.barrier := Some barrier;
  let accepted = act fixture id "same-request" (`Int 1) |> unwrap in
  check string "acceptance does not wait for effect" "queued" (text "state" accepted);
  await clock (fun () -> !(fixture.calls) = 1);
  let repeated = act fixture id "same-request" (`Float 1.) |> unwrap in
  check string "equivalent numeric encoding keeps original digest"
    (text "input_sha256" accepted) (text "input_sha256" repeated);
  rejects "different input for same request" (act fixture id "same-request" (`Int 2));
  Eio.Promise.resolve release ();
  let confirmed = await_state clock fixture id "same-request" "confirmed" in
  check string "authenticated requester retained" "authenticated-tester" (text "requester" confirmed);
  check string "executor is actual worker container" (Store.digest id) (text "executor" confirmed);
  ignore (act fixture id "same-request" (`Int 1) |> unwrap);
  check int "one worker invocation after duplicate requests" 1 !(fixture.calls);
  let rows = dispatch fixture Runtime.Slice ["run_id",str "action-world"] |> unwrap |> values "rows" in
  check bool "this action's output is available through existing Slice" true
    (List.exists (fun row -> member "fields" row |> member "action_request" = str "same-request") rows);
  detach clock fixture id;
  check string "detachment keeps completed receipt" "confirmed" (text "state" (status fixture id "same-request")))

let test_validation_precedes_effect () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let observer = attach clock fixture ~acting:false in
  rejects "old incarnation" (dispatch fixture Runtime.Act (request ~incarnation:"old-worker" id "old" (`Int 1)));
  rejects "out of advertised range" (act fixture id "out-of-range" (`Int 3));
  rejects "read-only package" (act fixture observer "observe-only" (`Int 1));
  rejects "missing authenticated requester" (Runtime.dispatch ~config:fixture.config ~operation:Runtime.Act
    (obj (request id "anonymous" (`Int 1))));
  check int "rejected requests never invoke worker" 0 !(fixture.calls);
  ignore (act fixture id "valid" (`Int 1) |> unwrap);
  ignore (await_state clock fixture id "valid" "confirmed");
  detach clock fixture id; detach clock fixture observer)

let test_held_action_preserves_other_activity () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let observer = attach clock fixture ~acting:false in
  let barrier, _release = Eio.Promise.create () in fixture.barrier := Some barrier;
  ignore (act fixture id "held" (`Int 1) |> unwrap);
  await clock (fun () -> !(fixture.calls) = 1);
  ignore (act fixture id "queued-behind" (`Int 1) |> unwrap);
  let before = number "observation_seq" (inspect fixture observer) in
  ignore (dispatch fixture Runtime.Observe ["instance_id",str observer] |> unwrap);
  await clock (fun () -> number "observation_seq" (inspect fixture observer) > before);
  ignore (dispatch fixture Runtime.Slice ["run_id",str "action-world"] |> unwrap);
  detach clock fixture id;
  ignore (await_state clock fixture id "held" "outcome_unknown");
  ignore (await_state clock fixture id "queued-behind" "failed_before_effect");
  check int "undispatched queued request has no effect" 1 !(fixture.calls);
  detach clock fixture observer)

let test_outcomes_are_not_inferred () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  List.iter (fun (request_id,outcome,expected) ->
    fixture.outcome := outcome;
    ignore (act fixture id request_id (`Int 1) |> unwrap);
    ignore (await_state clock fixture id request_id expected);
    ignore (act fixture id request_id (`Int 1) |> unwrap))
    ["refused",Refuse,"failed_before_effect";
     "unknown",Unknown,"outcome_unknown";"lost-reply",Lost_reply,"outcome_unknown"];
  check int "ambiguous replies are never automatically retried" 3 !(fixture.calls);
  detach clock fixture id)

let test_orphan_receipts_are_not_replayed () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  detach clock fixture id;
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir fixture.config) "lane-addons") in
  List.iter (fun (request_id,state,expected) ->
    let action = obj ["steps",`Int 1] in
    let arguments = Action.arguments ~instance_id:id ~request_id ~action |> Action.canonical |> unwrap in
    let receipt : Action.receipt = {instance_id=id;incarnation=id;request_id;requester="previous-requester";
      executor=Some (Store.digest id);input_sha256=Action.input_digest arguments;
      action;state;result=None;detail=None} in
    Store.save_action store ~instance_id:id ~request_id (Action.to_json receipt) |> unwrap;
    check string "retained state recovers without another worker" expected
      (text "state" (status fixture id request_id));
    check string "recovery itself is persisted" expected
      (Store.load_action store ~instance_id:id ~request_id |> unwrap |> Option.get |> text "state"))
    ["was-running",Action.Running,"outcome_unknown";
     "was-queued",Action.Queued,"failed_before_effect"];
  check int "recovery sends no input" 0 !(fixture.calls))

let () = run "Lane action workflow" ["optional world actions",[
  test_case "queued receipt, normalized dedup and retained output" `Quick test_one_request_one_effect;
  test_case "identity, schema and actor before effect" `Quick test_validation_precedes_effect;
  test_case "held action preserves another observer and Slice" `Quick test_held_action_preserves_other_activity;
  test_case "package outcomes and lost replies stay distinct" `Quick test_outcomes_are_not_inferred;
  test_case "orphan receipts recover without replay" `Quick test_orphan_receipts_are_not_replayed]]
