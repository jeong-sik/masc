(** A [masc.lane_act] schedule (RFC operator-quiz §4.7) through the real
    schedule runner, the production consumer and a declared installation:
    TOML declaration, reconcile, action queue and receipts are real. Only the
    worker is replaced, and its action can be held on a barrier. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Consumers = Server_schedule_consumers

let () = Mirage_crypto_rng_unix.use_default ()

let unwrap = function Ok value -> value | Error message -> fail message
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let with_env name value f =
  let previous = Sys.getenv_opt name in Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f

let obj fields = `Assoc fields
let str value = `String value
let object_schema properties =
  obj [ "type", str "object"; "properties", obj properties
      ; "required", `List (List.map (fun (name, _) -> str name) properties)
      ; "additionalProperties", `Bool false ]
let string_schema = obj [ "type", str "string" ]
let action_schema =
  object_schema
    [ "context", object_schema [ "instance_id", string_schema; "incarnation", string_schema ]
    ; "request_id", string_schema
    ; "action", object_schema [ "kind", obj [ "type", str "string"; "enum", `List [ str "compose" ] ] ] ]
let compose = obj [ "kind", str "compose" ]

let manifest = {|id="quiz-package"
revision="1"
title="Scheduled act fixture"
contributions=["observe","act"]
image="fixture/image"
command=["fixture"]
[world.actions]
tool="lane_act"
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=65536
|}
let declaration ?(enabled = true) ?(id = "quiz") ?(manifest = "../../package.toml") () =
  Printf.sprintf "id=%S\nenabled=%b\nrun_id=\"quiz-world\"\nmanifest_path=%S\n[binding]\nsources=[]\n"
    id enabled manifest

(* The worker: how many actions it ran, and a barrier its action waits on. *)
type worker = { calls : string list ref; barrier : unit Eio.Promise.t option ref }

let output : Lane_addon_types.output = { rows = []; coverage = [] }

let backend worker : Runtime.For_testing.backend = {
  start = (fun ~sw:_ ~state_owner:_ ~instance_id ~package:_ ~binding:_ ~on_engine ~is_live_instance:_ ~on_created ->
    let connection : Runtime.For_testing.connection = {
      observe = (fun ~binding:_ ~sources:_ -> Ok output);
      exported_tools = (fun () -> []);
      call_exported_tool = (fun ~on_result:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ ->
        Error (Lane_addon_call_context.Transport_error "no exported tools"));
      action_schema = (fun () -> Some action_schema);
      act = (fun ~arguments ->
        worker.calls := text "request_id" arguments :: !(worker.calls);
        Option.iter Eio.Promise.await !(worker.barrier);
        Ok { Lane_addon_action.status = Package_confirmed; result = obj [ "composed", `Bool true ]; output });
      stop = (fun () -> Ok ()); container_id = instance_id; host = None } in
    ignore (on_engine (Lane_addon_lifecycle.Docker_engine "fixture-engine"));
    on_created connection; Ok connection);
  (* A package whose image is not ready never gets a worker: declared and
     enabled, with no live instance. *)
  image_ready = (fun ~(package : Lane_addon_types.package) ->
    if String.equal package.id "broken-package" then Error "image is not loaded" else Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~runtime:_ ~state_owner:_ ~instance_id:_ ~engine:_ ~container_id:_ -> Ok ());
  condition_met = (fun ~runtime:_ _ -> true);
  sweep = (fun ~runtime:_ ~is_live_instance:_ -> Ok []) }

let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001; loop ()) in loop ()

let live_instance config =
  let inventory = Runtime.inventory ~config in
  List.find_map (fun (instance : Runtime.inventory_instance) ->
    match instance.presence, instance.configuration with
    | Runtime.Live, Some owner when String.equal owner.id "quiz" -> Some instance.instance_id
    | (Runtime.Live | Runtime.Retained), (Some _ | None) -> None) inventory.instances

let operator : Schedule_domain.actor = { id = "operator"; kind = Schedule_domain.Human_operator; display_name = None }

let lane_act_payload ?(installation_id = "quiz") () =
  obj [ "kind", str Schedule_supported_kinds.lane_act
      ; "body", obj [ "installation_id", str installation_id; "action", compose ] ]

let create_schedule ?installation_id ?(recurrence = Schedule_domain.Interval { interval_sec = 60 })
      ~schedule_id config =
  Schedule_service.create config ~now:100. ~runner_tick_sec:1. ~schedule_id ~requested_at:100.
    ~requested_by:operator ~scheduled_by:operator ~due_at:200.
    ~payload:(lane_act_payload ?installation_id ()) ~source:Schedule_domain.Operator_request ~recurrence ()
  |> Result.map_error Schedule_service.service_error_to_string |> unwrap

let tick config ~now =
  Schedule_runner.tick ~consumer:Consumers.consumer config ~now
    ~retention_days:Schedule_store.terminal_schedule_retention_days
  |> Result.map_error Schedule_runner.runner_error_to_string |> unwrap

(* The one dispatch of [schedule_id] in a tick. *)
let dispatch_of (result : Schedule_runner.tick_result) schedule_id =
  match List.filter (fun (d : Schedule_runner.dispatch_result) -> String.equal d.schedule_id schedule_id)
          result.dispatches with
  | [ dispatch ] -> dispatch
  | dispatches -> failf "expected one dispatch of %s, got %d" schedule_id (List.length dispatches)

let handed_over (dispatch : Schedule_runner.dispatch_result) =
  match dispatch.status, Option.map Consumers.dispatch_receipt_of_detail dispatch.detail with
  | Schedule_runner.Dispatch_succeeded, Some (Ok (Consumers.Lane_act_handed_over receipt)) ->
    receipt.instance_id, receipt.request_id
  | _, _ -> failf "expected a handed-over action, got %s %s"
              (Schedule_runner.dispatch_status_to_string dispatch.status)
              (Option.value ~default:"" dispatch.error)

let failure_of (dispatch : Schedule_runner.dispatch_result) =
  match dispatch.status, dispatch.error with
  | Schedule_runner.Dispatch_failed, Some error -> error
  | _, _ -> failf "expected a failed dispatch, got %s" (Schedule_runner.dispatch_status_to_string dispatch.status)

let receipt config ~instance_id ~request_id =
  Runtime.dispatch ~access:Lane_addon_sources.Operator_configuration ~config ~operation:Runtime.Action_status
    (obj [ "instance_id", str instance_id; "request_id", str request_id ])
  |> Result.map_error Runtime.error_to_string |> unwrap

let state config ~instance_id ~request_id = text "state" (receipt config ~instance_id ~request_id)

(* A declared installation [quiz] with a live worker, and [reconcile] to apply
   a rewritten declaration. [fail_writes] makes every receipt write fail, as a
   process that dies before it writes would leave the receipt. *)
let with_installation f =
  let root = Filename.temp_dir "lane-scheduled-act-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let directory = Filename.concat config_root "lane-addons" in
    write (Filename.concat root ".masc/package.toml") manifest;
    write (Filename.concat directory "quiz.toml") (declaration ());
    with_env "MASC_BASE_PATH" root (fun () ->
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
    with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let clock = Eio.Stdenv.clock env in
        Eio.Time.with_timeout_exn clock 20. (fun () -> Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
            ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              Runtime.For_testing.reset ();
              let config = Workspace.default_config root in
              ignore (Workspace.init config ~agent_name:(Some "test"));
              let worker = { calls = ref []; barrier = ref None } in
              let fail_writes = ref false in
              let writer ~store ~instance_id ~request_id json =
                if !fail_writes then Error "the process died before this write"
                else Lane_addon_store.save_action store ~instance_id ~request_id json in
              let reconcile () = ignore (Runtime.reconcile_configuration ~config ~directory |> unwrap) in
              Runtime.For_testing.with_action_writer writer (fun () ->
              Runtime.For_testing.with_backend (backend worker) (fun () ->
                reconcile ();
                await clock (fun () -> Option.is_some (live_instance config));
                f ~clock ~config ~worker ~fail_writes
                  ~declare:(fun ?enabled ?id ?manifest name ->
                    write (Filename.concat directory name) (declaration ?enabled ?id ?manifest ());
                    reconcile ());
                List.iter (fun name -> Sys.remove (Filename.concat directory name))
                  (Array.to_list (Sys.readdir directory));
                reconcile ()))))))))))

let test_a_due_occurrence_hands_its_action_to_the_live_worker () =
  with_installation (fun ~clock ~config ~worker ~fail_writes:_ ~declare:_ ->
    let request = create_schedule ~schedule_id:"quiz-morning" config in
    let instance_id, request_id = handed_over (dispatch_of (tick config ~now:201.) "quiz-morning") in
    check (option string) "the live instance" (live_instance config) (Some instance_id);
    await clock (fun () -> state config ~instance_id ~request_id = "confirmed");
    check (list string) "the worker ran it once" [ request_id ] !(worker.calls);
    check string "requested by the schedule's scheduler"
      ("schedule:" ^ request.schedule_id ^ ":operator")
      (text "requester" (receipt config ~instance_id ~request_id)))

let test_every_due_occurrence_dispatches_with_no_hold () =
  with_installation (fun ~clock ~config ~worker ~fail_writes:_ ~declare:_ ->
    let release, resolve = Eio.Promise.create () in
    worker.barrier := Some release;
    ignore (create_schedule ~schedule_id:"quiz-twice" config);
    let instance_id, first = handed_over (dispatch_of (tick config ~now:201.) "quiz-twice") in
    await clock (fun () -> !(worker.calls) = [ first ]);
    let same_instance, second = handed_over (dispatch_of (tick config ~now:261.) "quiz-twice") in
    check string "the same worker" instance_id same_instance;
    check bool "its own receipt" true (first <> second);
    check string "the second waits behind the first" "queued" (state config ~instance_id ~request_id:second);
    Eio.Promise.resolve resolve ();
    await clock (fun () -> state config ~instance_id ~request_id:second = "confirmed");
    check (list string) "both ran, in order" [ second; first ] !(worker.calls))

let test_a_worker_that_exits_ends_the_scheduled_receipts_it_held () =
  with_installation (fun ~clock ~config ~worker ~fail_writes:_ ~declare ->
    let hold, _ = Eio.Promise.create () in
    worker.barrier := Some hold;
    ignore (create_schedule ~schedule_id:"quiz-exit" config);
    let instance_id, running = handed_over (dispatch_of (tick config ~now:201.) "quiz-exit") in
    await clock (fun () -> !(worker.calls) = [ running ]);
    let _, queued = handed_over (dispatch_of (tick config ~now:261.) "quiz-exit") in
    declare ~enabled:false "quiz.toml";
    await clock (fun () -> Option.is_none (live_instance config));
    check string "the one it was running" "outcome_unknown" (state config ~instance_id ~request_id:running);
    check string "the one still queued" "failed_before_effect" (state config ~instance_id ~request_id:queued);
    check string "a disabled declaration fails the next occurrence" "lane_act declaration_disabled"
      (failure_of (dispatch_of (tick config ~now:321.) "quiz-exit"));
    check (list string) "nothing was replayed" [ running ] !(worker.calls))

let test_a_receipt_a_dead_process_left_ends_on_its_first_read () =
  with_installation (fun ~clock ~config ~worker ~fail_writes ~declare ->
    let hold, _ = Eio.Promise.create () in
    worker.barrier := Some hold;
    ignore (create_schedule ~schedule_id:"quiz-death" config);
    let old_instance, running = handed_over (dispatch_of (tick config ~now:201.) "quiz-death") in
    await clock (fun () -> !(worker.calls) = [ running ]);
    let _, queued = handed_over (dispatch_of (tick config ~now:261.) "quiz-death") in
    fail_writes := true;
    declare ~enabled:false "quiz.toml";
    await clock (fun () -> Option.is_none (live_instance config));
    fail_writes := false;
    declare ~enabled:true "quiz.toml";
    await clock (fun () -> Option.is_some (live_instance config));
    check bool "a new worker" true (live_instance config <> Some old_instance);
    (* The occurrence the dead process accepted comes again. *)
    match Runtime.scheduled_act ~config ~access:Lane_addon_sources.Operator_configuration
            ~requester:"schedule:quiz-death:operator" ~declaration_id:"quiz" ~request_id:queued ~action:compose with
    | Ok (receipt : Lane_addon_action.receipt) ->
      check string "the same receipt" old_instance receipt.instance_id;
      check bool "ended on that read" true (receipt.state = Lane_addon_action.Failed_before_effect);
      check string "and written down" "failed_before_effect" (state config ~instance_id:old_instance ~request_id:queued);
      check (list string) "never run on the new worker" [ running ] !(worker.calls)
    | Error _ -> fail "the redelivered occurrence must return its receipt")

let test_a_missing_declaration_or_absent_worker_fails_the_occurrence () =
  with_installation (fun ~clock:_ ~config ~worker ~fail_writes:_ ~declare ->
    ignore (create_schedule ~installation_id:"nobody" ~schedule_id:"quiz-missing" config);
    check string "no declaration" "lane_act declaration_missing"
      (failure_of (dispatch_of (tick config ~now:201.) "quiz-missing"));
    write (Filename.concat (Sys.getenv "MASC_BASE_PATH") ".masc/broken.toml")
      (Str.global_replace (Str.regexp_string "quiz-package") "broken-package" manifest);
    declare ~id:"broken" ~manifest:"../../broken.toml" "broken.toml";
    ignore (create_schedule ~installation_id:"broken" ~schedule_id:"quiz-broken" config);
    check string "no live worker" "lane_act no_live_instance"
      (failure_of (dispatch_of (tick config ~now:201.) "quiz-broken"));
    check (list string) "nothing ran" [] !(worker.calls))

(* The runner sends an occurrence again when its acceptance did not commit.
   Here every acceptance fails, so the consumer is asked twice. *)
let test_a_redelivered_occurrence_returns_the_same_receipt () =
  with_installation (fun ~clock ~config ~worker ~fail_writes:_ ~declare:_ ->
    let request = create_schedule ~recurrence:Schedule_domain.One_shot ~schedule_id:"quiz-again" config in
    let payload = lane_act_payload () in
    let signal : Schedule_runner.wake_signal = {
      occurrence_id = Schedule_occurrence_id.make ~schedule_instance_id:request.schedule_instance_id
          ~schedule_id:request.schedule_id ~due_at:200. ~payload_digest:"fixture";
      kind = Schedule_runner.Due_candidate; schedule_instance_id = request.schedule_instance_id;
      schedule_id = request.schedule_id; emitted_at = 201.; due_at = 200.; payload_digest = "fixture"; payload } in
    let deliver () =
      let committed = ref None in
      (match Consumers.consumer.dispatch config ~now:201. signal request ~commit_acceptance:(fun detail ->
         committed := Some detail;
         Error (Schedule_runner.Retryable_dispatch_failure "the acceptance did not commit")) with
       | Error (Schedule_runner.Retryable_dispatch_failure _) -> ()
       | Error (Schedule_runner.Occurrence_dispatch_rejection detail | Schedule_runner.Terminal_dispatch_rejection detail) ->
         fail detail
       | Ok _ -> fail "the fixture acceptance never commits");
      match !committed with Some detail -> detail | None -> fail "nothing was offered for acceptance" in
    let first = deliver () in
    await clock (fun () -> List.length !(worker.calls) = 1);
    let second = deliver () in
    check bool "the same receipt" true (Yojson.Safe.equal first second);
    check int "run once" 1 (List.length !(worker.calls)))

let () =
  run "Lane_addon_scheduled_act"
    [ ( "masc.lane_act",
        [ test_case "a due occurrence hands its action to the live worker" `Quick
            test_a_due_occurrence_hands_its_action_to_the_live_worker
        ; test_case "every due occurrence dispatches, with no hold" `Quick
            test_every_due_occurrence_dispatches_with_no_hold
        ; test_case "a worker that exits ends the scheduled receipts it held" `Quick
            test_a_worker_that_exits_ends_the_scheduled_receipts_it_held
        ; test_case "a receipt a dead process left ends on its first read" `Quick
            test_a_receipt_a_dead_process_left_ends_on_its_first_read
        ; test_case "a missing declaration or an absent worker fails the occurrence" `Quick
            test_a_missing_declaration_or_absent_worker_fails_the_occurrence
        ; test_case "a redelivered occurrence returns the same receipt" `Quick
            test_a_redelivered_occurrence_returns_the_same_receipt ] ) ]
