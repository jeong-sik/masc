(** Public action workflow with real manifests, runtime queues and durable
    receipts. Only the external worker is replaced by explicit barriers. *)
open Alcotest
open Masc
module Runtime = struct
  include Lane_addon_runtime
  let dispatch ?caller ~config ~operation args =
    let access = match caller with
      | None -> Lane_addon_sources.Operator_configuration
      | Some keeper -> Lane_addon_sources.Keeper keeper in
    Lane_addon_runtime.dispatch ?caller ~access ~config ~operation args
    |> Result.map_error Lane_addon_runtime.error_to_string
end
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
type fixture = {config:Workspace.config; root:string; calls:int ref; observes:int ref;
  outcome:outcome ref; barrier:unit Eio.Promise.t option ref}
let backend fixture : Runtime.For_testing.backend = {
  start=(fun ~sw:_ ~instance_id ~(package:Types.package) ~on_created ->
    let connection : Runtime.For_testing.connection = {
      container_id=Store.digest instance_id;
      action_schema=(fun () -> Option.map (fun _ -> schema) package.action_tool);
      observe=(fun ~binding:_ ~sources:_ -> incr fixture.observes; Ok output);
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
  image_ready=(fun ~package:_ -> Ok ());
  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
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
              let fixture = {config=Workspace.default_config root;root;calls=ref 0;observes=ref 0;
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
    let retained = await_state clock fixture id request_id expected in
    (match outcome with
     | Lost_reply -> check bool "unknown outcome permits no received result" true
         (member "result" retained = `Null)
     | Confirm | Refuse | Unknown -> ());
    ignore (act fixture id request_id (`Int 1) |> unwrap))
    ["refused",Refuse,"failed_before_effect";
     "unknown",Unknown,"outcome_unknown";"lost-reply",Lost_reply,"outcome_unknown"];
  check int "ambiguous replies are never automatically retried" 3 !(fixture.calls);
  detach clock fixture id)

(* An action's package result carries its own output. Before this test the
   worker loop re-woke itself with an observation request after every action,
   so a confirmed DOS increment committed the same capture twice and a derived
   value-difference layer reported "0 · unchanged" right after the +1. *)
let test_action_commits_its_output_once () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  check int "attach observed once" 1 (number "observation_seq" (inspect fixture id));
  let observed = !(fixture.observes) in
  ignore (act fixture id "once" (`Int 1) |> unwrap);
  ignore (await_state clock fixture id "once" "confirmed");
  await clock (fun () -> number "observation_seq" (inspect fixture id) = 2);
  (* A forced follow-up observation would run on the same worker loop
     right after the receipt; give it the chance and then require its absence. *)
  Eio.Time.sleep clock 0.05;
  let after = inspect fixture id in
  check int "the action output is the only new commit" 2 (number "observation_seq" after);
  check int "no observation ran for the action" observed !(fixture.observes);
  check bool "nothing is pending after the action" false
    (member "observation_pending" after |> Yojson.Safe.Util.to_bool);
  detach clock fixture id)

(* An observation requested while actions are queued is carried past every
   queued action and served once after the last one; it is neither dropped
   nor repeated per action. *)
let test_observation_requested_beside_queued_actions_runs_once_after_them () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let barrier, release = Eio.Promise.create () in fixture.barrier := Some barrier;
  ignore (act fixture id "held" (`Int 1) |> unwrap);
  await clock (fun () -> !(fixture.calls) = 1);
  ignore (act fixture id "queued-behind" (`Int 1) |> unwrap);
  let observed = !(fixture.observes) in
  ignore (dispatch fixture Runtime.Observe ["instance_id",str id] |> unwrap);
  check int "the held action still owns the loop" 1 (number "observation_seq" (inspect fixture id));
  Eio.Promise.resolve release ();
  ignore (await_state clock fixture id "held" "confirmed");
  ignore (await_state clock fixture id "queued-behind" "confirmed");
  await clock (fun () -> number "observation_seq" (inspect fixture id) = 4);
  Eio.Time.sleep clock 0.05;
  check int "two action outputs then one observation" 4 (number "observation_seq" (inspect fixture id));
  check int "exactly one observation served the request" (observed + 1) !(fixture.observes);
  check int "each action ran once" 2 !(fixture.calls);
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
    let recovered = status fixture id request_id in
    check string "retained state recovers without another worker" expected (text "state" recovered);
    check bool "pre-effect failure and abandoned dispatch may have no result" true
      (member "result" recovered = `Null);
    check string "recovery itself is persisted" expected
      (Store.load_action store ~instance_id:id ~request_id |> unwrap |> Option.get |> text "state"))
    ["was-running",Action.Running,"outcome_unknown";
     "was-queued",Action.Queued,"failed_before_effect"];
  check int "recovery sends no input" 0 !(fixture.calls))

let test_result_survives_failed_parent_sync () = with_fixture (fun clock fixture ->
  let inject = Atomic.make true in
  let renamed_result = Atomic.make None in
  let after_rename = Atomic.make false in
  let failed_path = Atomic.make None in
  let publication_error = Atomic.make None in
  let release_mutex = Stdlib.Mutex.create () in
  let release_condition = Condition.create () in
  let released = ref false in
  let release_writer () = Stdlib.Mutex.protect release_mutex (fun () ->
    released := true;
    Condition.broadcast release_condition) in
  let writer ~store ~instance_id ~request_id json =
    let receipt = Action.of_json json |> unwrap in
    if receipt.state = Action.Confirmed && Atomic.compare_and_set inject true false then (
      (* The queued/running receipts already created this directory. Pin the
         real durable path solely to inject the strict writer's parent fsync. *)
      let path = Filename.concat (Store.root store)
        (Filename.concat "actions" (Filename.concat (Store.digest instance_id) (Store.digest request_id ^ ".json"))) in
      Atomic.set failed_path (Some path);
      let result = Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
        ~sync_parent:(fun parent -> raise (Unix.Unix_error (Unix.EIO, "fsync", parent)))
        path (Yojson.Safe.to_string json) in
      (match result with
       | Ok () -> Error "fault fixture unexpectedly confirmed parent sync"
       | Error failure ->
           Atomic.set after_rename (failure.stage = Fs_compat.After_rename);
           Atomic.set renamed_result (Some (Yojson.Safe.from_file path));
           let message = Fs_compat.atomic_replace_failure_to_string failure in
           Atomic.set publication_error (Some message);
           (* Hold the real failed write until a status reader is waiting on
              its serializer. This forces the original false-confirmed race. *)
           Stdlib.Mutex.lock release_mutex;
           while not !released do Condition.wait release_condition release_mutex done;
           Stdlib.Mutex.unlock release_mutex;
           Error message))
    else Store.save_action store ~instance_id ~request_id json in
  Runtime.For_testing.with_action_writer writer (fun () ->
    (* This finalizer only signals a synchronous OS condition. It must also run
       when the test fails before its reader releases the non-cancellable writer. *)
    Fun.protect ~finally:release_writer (fun () ->
    let id = attach clock fixture ~acting:true in
    let request_id = "result-sync-failure" in
    ignore (act fixture id request_id (`Int 1) |> unwrap);
    await clock (fun () -> Atomic.get after_rename);
    let uncertain = Eio.Switch.run (fun sw ->
      let started, signal = Eio.Promise.create () in
      let reader = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Promise.resolve signal ();
        status fixture id request_id) in
      Eio.Promise.await started;
      release_writer ();
      Eio.Promise.await_exn reader) in
    check string "first reader after failed publication never sees confirmed" "outcome_unknown"
      (text "state" uncertain);
    check bool "fault happened after the terminal JSON became visible" true (Atomic.get after_rename);
    let visible = match Atomic.get renamed_result with Some json -> json | None -> fail "missing renamed receipt" in
    check string "package confirmation was visible before fsync failed" "confirmed" (text "state" visible);
    check int "finalization retains the package result" 1 (member "result" uncertain |> number "calls");
    let path = match Atomic.get failed_path with Some path -> path | None -> fail "missing failed receipt path" in
    let retained = Yojson.Safe.from_file path in
    check string "durable fallback reports uncertainty" "outcome_unknown" (text "state" retained);
    check string "received result bytes survive fallback publication"
      (member "result" visible |> Yojson.Safe.to_string) (member "result" retained |> Yojson.Safe.to_string);
    let error = match Atomic.get publication_error with Some message -> message | None -> fail "missing fsync error" in
    let failed_detail = text "detail" visible ^ "; action result persistence failed: " ^ error in
    check bool "package interpretation and exact fsync error both remain explicit" true
      (List.mem (text "detail" retained)
        [failed_detail; failed_detail ^ "; worker lifetime ended before a durable action result; no automatic retry"]);
    let rows = dispatch fixture Runtime.Slice ["run_id",str "action-world"] |> unwrap |> values "rows" in
    check bool "committed package evidence survives receipt sync failure" true
      (List.exists (fun row -> member "fields" row |> member "action_request" = str request_id) rows);
    ignore (act fixture id request_id (`Int 1) |> unwrap);
    check int "uncertain durable publication never repeats the action" 1 !(fixture.calls);
    detach clock fixture id)))

let test_observation_publication_keeps_sequence_and_action_uncertainty () =
  List.iter (fun (before,unreadable) -> with_fixture (fun clock fixture ->
    let armed=ref false in
    let injected=ref false in
    let hidden=ref None in
    let replaced_bytes=ref None in
    let writer ~store ~instance_id ~seq ~sources output =
      let replace_file path bytes =
        if !armed && not !injected then (
          injected:=true;
          let result=Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
            ~sync_file:(fun path ->
              if before then raise (Unix.Unix_error (Unix.EIO,"fsync",path))
              else let fd=Unix.openfile path [Unix.O_RDONLY] 0 in
                Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd))
            ~sync_parent:(fun path -> raise (Unix.Unix_error (Unix.EIO,"fsync",path))) path bytes in
          (match result with
           | Error {Fs_compat.stage=Fs_compat.After_rename;_} ->
             replaced_bytes:=Some (path,Fs_compat.load_file path);
             if unreadable then (let held=path ^ ".held" in Unix.rename path held;hidden:=Some (path,held))
           | Ok () | Error {Fs_compat.stage=Fs_compat.Before_rename;_} -> ());
          result)
        else Fs_compat.save_file_atomic_strict_staged path bytes in
      Store.For_testing.append_observation ~replace_file store ~instance_id ~seq ~sources output in
    Runtime.For_testing.with_observation_writer writer (fun () ->
      let id=attach clock fixture ~acting:true in
      let initial=number "observation_seq" (inspect fixture id) in
      armed:=true;
      ignore (act fixture id "uncertain-observation" (`Int 1) |> unwrap);
      let unknown=await_state clock fixture id "uncertain-observation" "outcome_unknown" in
      check int "the actual action ran once" 1 !(fixture.calls);
      check int "the received result is retained despite evidence uncertainty" 1
        (member "result" unknown |> number "calls");
      let expected=if before then initial else initial+1 in
      check int "published sequence converges only after actual rename" expected
        (number "observation_seq" (inspect fixture id));
      if not before then (
        let phase=member "phase" (inspect fixture id) in
        check string "published observation remains failed until recovery" "failed" (text "kind" phase);
        let live=dispatch fixture Runtime.Inspect ["instance_id",str id] |> unwrap in
        check bool "visible output never claims complete producer durability" true
          (values "coverage" live |> List.exists (fun coverage -> member "complete" coverage=`Bool false)));
      (match !hidden with None -> () | Some (path,held) -> Unix.rename held path);
      (match !replaced_bytes with
       | None -> check bool "before-rename produced no target" true before
       | Some (path,bytes) ->
         check string "the failed published record is retained exactly" bytes (Fs_compat.load_file path);
         let store=Store.create ~root:(Filename.concat (Workspace.masc_dir fixture.config) "lane-addons") in
         check bool "visible observation cannot be accepted while directory sync fails" true
           (Result.is_error (Store.For_testing.read_observation ~sync_file:Unix.fsync
             ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",Filename.dirname path)))
             ~instance_id:id ~seq:expected ~max_bytes:65536 store));
         check string "failed read leaves the exact retained bytes" bytes (Fs_compat.load_file path);
         let recovered=Store.read_observation ~instance_id:id ~seq:expected ~max_bytes:65536 store |> unwrap in
         check bool "strict resync recovers the actual action evidence" true
           (List.exists (fun (row:Types.row) -> List.assoc_opt "action_request" row.fields=Some (str "uncertain-observation")) recovered.rows));
      ignore (act fixture id "uncertain-observation" (`Int 1) |> unwrap);
      check int "unknown outcome never replays the action" 1 !(fixture.calls);
      ignore (dispatch fixture Runtime.Observe ["instance_id",str id] |> unwrap);
      await clock (fun () -> number "observation_seq" (inspect fixture id)>expected);
      check int "explicit retry commits the next available sequence" (expected+1)
        (number "observation_seq" (inspect fixture id));
      check int "observation recovery is not action replay" 1 !(fixture.calls);
      ignore (act fixture id "next-action" (`Int 1) |> unwrap);
      ignore (await_state clock fixture id "next-action" "confirmed");
      check int "a later distinct request still works" 2 !(fixture.calls);
      check string "recovery never upgrades the original unknown outcome" "outcome_unknown"
        (text "state" (status fixture id "uncertain-observation"));
      (match !replaced_bytes with None -> () | Some (path,bytes) ->
        check string "later retries never overwrite the failed published record" bytes (Fs_compat.load_file path));
      detach clock fixture id))) [true,false;false,false;false,true]

let test_confirmed_receipt_requires_result () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let request_id = "retained-confirmation" in
  let _accepted = act fixture id request_id (`Int 1) |> unwrap in
  let confirmed = await_state clock fixture id request_id "confirmed" in
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir fixture.config) "lane-addons") in
  let path = Filename.concat (Store.root store)
    (Filename.concat "actions" (Filename.concat (Store.digest id) (Store.digest request_id ^ ".json"))) in
  let saved_receipt = Fs_compat.load_file path in
  let corrupt = match confirmed with
    | `Assoc fields -> obj (("result",`Null)::List.remove_assoc "result" fields)
    | _ -> fail "expected confirmed receipt object" in
  Store.save_action store ~instance_id:id ~request_id corrupt |> unwrap;
  let corrupt_bytes = Fs_compat.load_file path in
  rejects "confirmed receipt without its result" (dispatch fixture Runtime.Action_status
    ["instance_id",str id;"request_id",str request_id]);
  rejects "duplicate request with an unreadable confirmation" (act fixture id request_id (`Int 1));
  check int "receipt corruption does not replay the effect" 1 !(fixture.calls);
  check string "receipt corruption is preserved for repair" corrupt_bytes (Fs_compat.load_file path);
  Fs_compat.save_file_atomic_strict path saved_receipt |> unwrap;
  let repaired = status fixture id request_id in
  check string "restored confirmation retains its received result"
    (member "result" confirmed |> Yojson.Safe.to_string)
    (member "result" repaired |> Yojson.Safe.to_string);
  let _duplicate = act fixture id request_id (`Int 1) |> unwrap in
  check int "restoring exact receipt bytes does not replay the effect" 1 !(fixture.calls);
  detach clock fixture id)

let test_failed_terminal_and_fallback_keep_hot_uncertainty () = with_fixture (fun clock fixture ->
  let armed = Atomic.make true in
  let terminal_failures = Atomic.make 0 in
  let fallback_failures = Atomic.make 0 in
  let path_seen = Atomic.make None in
  let writer ~store ~instance_id ~request_id json =
    let receipt = Action.of_json json |> unwrap in
    if Atomic.get armed &&
       (receipt.state = Action.Confirmed || receipt.state = Action.Outcome_unknown) then (
      let path = Filename.concat (Store.root store)
        (Filename.concat "actions" (Filename.concat (Store.digest instance_id)
          (Store.digest request_id ^ ".json"))) in
      Atomic.set path_seen (Some path);
      let result =
        if receipt.state = Action.Confirmed then (
          ignore (Atomic.fetch_and_add terminal_failures 1 : int);
          Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
            ~sync_parent:(fun parent -> raise (Unix.Unix_error (Unix.EIO,"fsync",parent)))
            path (Yojson.Safe.to_string json))
        else (
          ignore (Atomic.fetch_and_add fallback_failures 1 : int);
          Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
            ~sync_file:(fun file -> raise (Unix.Unix_error (Unix.EIO,"fsync",file)))
            ~sync_parent:(fun _ -> fail "pre-rename file sync failure must not reach parent sync")
            path (Yojson.Safe.to_string json)) in
      match result with
      | Ok () -> Error "fault fixture unexpectedly completed receipt persistence"
      | Error failure ->
        let expected = if receipt.state = Action.Confirmed then Fs_compat.After_rename
          else Fs_compat.Before_rename in
        if failure.stage <> expected then fail "receipt fault crossed the wrong publication boundary";
        Error (Fs_compat.atomic_replace_failure_to_string failure))
    else Store.save_action store ~instance_id ~request_id json in
  Runtime.For_testing.with_action_writer writer (fun () ->
    let id = attach clock fixture ~acting:true in
    let request_id = "terminal-and-fallback-sync-failure" in
    ignore (act fixture id request_id (`Int 1) |> unwrap);
    await clock (fun () -> Atomic.get fallback_failures > 0 &&
      text "kind" (member "phase" (inspect fixture id)) = "failed");
    check int "package action ran exactly once" 1 !(fixture.calls);
    check int "terminal write reached its failed parent fsync" 1 (Atomic.get terminal_failures);
    let path = match Atomic.get path_seen with Some path -> path | None -> fail "receipt path was not captured" in
    let visible = Fs_compat.load_file path in
    check string "failed finalizer left the visible terminal file" "confirmed"
      (text "state" (Yojson.Safe.from_string visible));
    List.iter (fun () ->
      let before = Atomic.get fallback_failures in
      rejects "hot status cannot expose an unconfirmed terminal receipt"
        (dispatch fixture Runtime.Action_status ["instance_id",str id;"request_id",str request_id]);
      check bool "status retries uncertainty publication, not package execution" true
        (Atomic.get fallback_failures > before);
      check string "failed fallback preserves the visible bytes for repair" visible (Fs_compat.load_file path);
      check int "status never retries the external action" 1 !(fixture.calls)) [(); ()];
    rejects "duplicate request cannot reuse unconfirmed terminal publication"
      (act fixture id request_id (`Int 1));
    check int "a duplicate during failed persistence has no effect" 1 !(fixture.calls);
    Atomic.set armed false;
    let recovered = status fixture id request_id in
    check string "repair retains uncertainty instead of upgrading confirmation" "outcome_unknown"
      (text "state" recovered);
    check int "repair keeps the received package result" 1 (number "calls" (member "result" recovered));
    check string "repaired uncertainty is durable" "outcome_unknown"
      (text "state" (Yojson.Safe.from_string (Fs_compat.load_file path)));
    ignore (act fixture id request_id (`Int 1) |> unwrap);
    check int "a repaired receipt never replays the external action" 1 !(fixture.calls);
    detach clock fixture id))

let test_first_action_requires_durable_directory () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir fixture.config) "lane-addons") in
  let actions = Filename.concat (Store.root store) "actions" in
  let writer ~store ~instance_id ~request_id json =
    Store.For_testing.save_action store ~instance_id ~request_id json
      ~sync_parent:(fun parent ->
        if parent = actions then raise (Unix.Unix_error (Unix.EIO,"fsync",parent))
        else
          let fd = Unix.openfile parent [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)) in
  Runtime.For_testing.with_action_writer writer (fun () ->
    List.iter (fun () ->
      rejects "unsynced first action directory refuses dispatch"
        (act fixture id "first-directory" (`Int 1));
      check int "directory failure performs no external action" 0 !(fixture.calls);
      check bool "failed directory publication creates no queued receipt" true
        (Store.load_action store ~instance_id:id ~request_id:"first-directory" = Ok None)) [(); ()]);
  ignore (act fixture id "first-directory" (`Int 1) |> unwrap);
  ignore (await_state clock fixture id "first-directory" "confirmed");
  ignore (act fixture id "first-directory" (`Int 1) |> unwrap);
  check int "directory repair permits exactly one action" 1 !(fixture.calls);
  detach clock fixture id)

let test_cold_receipt_requires_sync_and_same_file_identity () = with_fixture (fun clock fixture ->
  let id = attach clock fixture ~acting:true in
  let request_id = "cold-terminal-reconfirmation" in
  ignore (act fixture id request_id (`Int 1) |> unwrap);
  ignore (await_state clock fixture id request_id "confirmed");
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir fixture.config) "lane-addons") in
  let path = Filename.concat (Store.root store)
    (Filename.concat "actions" (Filename.concat (Store.digest id) (Store.digest request_id ^ ".json"))) in
  let bytes = Fs_compat.load_file path in
  let load ~sync_file ~sync_parent =
    Store.For_testing.load_action ~sync_file ~sync_parent store ~instance_id:id ~request_id in
  let refused label result = match result with
    | Error _ -> ()
    | Ok _ -> fail (label ^ " exposed an unconfirmed terminal receipt") in
  List.iter (fun () ->
    let parent_calls = ref 0 in
    refused "failed opened-file fsync" (load
      ~sync_file:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",path)))
      ~sync_parent:(fun fd -> incr parent_calls;Unix.fsync fd));
    check int "file failure cannot reconfirm the parent" 0 !parent_calls;
    refused "failed parent fsync" (load ~sync_file:Unix.fsync
      ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",Filename.dirname path))));
    check string "repeated failed reads never rewrite receipt bytes" bytes (Fs_compat.load_file path);
    check int "cold receipt reads do not dispatch the action" 1 !(fixture.calls)) [(); ()];
  let healthy = load ~sync_file:Unix.fsync ~sync_parent:Unix.fsync |> unwrap |> Option.get in
  check string "healthy reconfirmation recovers the stored package result" "confirmed" (text "state" healthy);
  check int "healthy receipt carries its original result" 1 (number "calls" (member "result" healthy));
  check string "healthy reconfirmation leaves original bytes exact" bytes (Fs_compat.load_file path);
  let held = path ^ ".original" in
  let replaced = ref false in
  Fun.protect
    ~finally:(fun () -> if !replaced then (Unix.unlink path;Unix.rename held path))
    (fun () ->
      refused "identical-byte file replacement during fsync" (load
        ~sync_file:(fun fd ->
          Unix.fsync fd;
          Unix.rename path held;
          replaced := true;
          Out_channel.with_open_bin path (fun channel -> output_string channel bytes))
        ~sync_parent:Unix.fsync);
      check bool "replacement seam actually ran" true !replaced;
      check string "the replacement even has identical payload bytes" bytes (Fs_compat.load_file path));
  let restored = load ~sync_file:Unix.fsync ~sync_parent:Unix.fsync |> unwrap |> Option.get in
  check string "restored original identity reconfirms without effects" "confirmed" (text "state" restored);
  check string "original bytes survive identity repair" bytes (Fs_compat.load_file path);
  check int "all strict reads and repair retain one external action" 1 !(fixture.calls);
  detach clock fixture id)

let () = run "Lane action workflow" ["optional world actions",[
  test_case "first action directory must be durable before dispatch and on retry" `Quick test_first_action_requires_durable_directory;
  test_case "terminal and fallback publication failures keep hot uncertainty without replay" `Quick test_failed_terminal_and_fallback_keep_hot_uncertainty;
  test_case "cold terminal receipt requires file and parent sync and exact identity" `Quick test_cold_receipt_requires_sync_and_same_file_identity;
  test_case "observation rename failure preserves sequence and unknown action without replay" `Quick test_observation_publication_keeps_sequence_and_action_uncertainty;
  test_case "persisted confirmation requires its received result without replay" `Quick test_confirmed_receipt_requires_result;
  test_case "queued receipt, normalized dedup and retained output" `Quick test_one_request_one_effect;
  test_case "identity, schema and actor before effect" `Quick test_validation_precedes_effect;
  test_case "held action preserves another observer and Slice" `Quick test_held_action_preserves_other_activity;
  test_case "package outcomes and lost replies stay distinct" `Quick test_outcomes_are_not_inferred;
  test_case "an action commits its output once" `Quick test_action_commits_its_output_once;
  test_case "an observation beside queued actions runs once after them" `Quick test_observation_requested_beside_queued_actions_runs_once_after_them;
  test_case "orphan receipts recover without replay" `Quick test_orphan_receipts_are_not_replayed;
  test_case "post-rename sync failure preserves observed result" `Quick test_result_survives_failed_parent_sync]]
