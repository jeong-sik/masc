(** A conversation that ended its turn on a background receipt resumes when
    the receipt arrives, or when its run is gone.

    Each case runs the Owner of a Keeper with a real chat operation store: the
    first claim ends with [keeper_receipt_wait]'s wait recorded, the second
    claim is the resumed run. What the cases drive is what production drives:
    [Keeper_client_tool_outbox_wake.notify] for an arrived receipt and
    [Keeper_receipt_wait_sweep] for a run that left neither worker nor
    receipt. *)

open Alcotest
open Masc

module Owner = Keeper_owner
module Registry = Keeper_owner_registry
module Chat_operation = Owner.Chat_operation
module Outbox = Keeper_client_tool_outbox
module Background = Keeper_execute_background.For_testing

let () = Mirage_crypto_rng_unix.use_default ()
let get = function Ok value -> value | Error detail -> fail detail

let owner_ok = function
  | Ok value -> value
  | Error error -> fail (Owner.error_to_string error)
;;

let command_ok = function
  | Ok value -> value
  | Error error -> fail (Registry.command_error_to_string error)
;;

let keeper_name = "wait-resume-keeper"

let with_workspace f =
  let base_path = Filename.temp_file "masc_receipt_wait_resume_" "" in
  Unix.unlink base_path;
  let base_path = (Unix.mkdir base_path 0o700; try Unix.realpath base_path with Unix.Unix_error _ -> base_path) in
  let config = Workspace.default_config base_path in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  let path = Filename.concat base_path "runtime.toml" in
  let toml = {|[providers.codex]
protocol = "codex-app-server"
command = "/bin/false"
is-non-interactive = true
[models.codex]
api-name = "gpt-fixture"
max-context = 400000
[codex.codex]
[runtime]
default = "codex.codex"
|} in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Llm_provider.Catalog_snapshot.publish catalog_snapshot;
      Keeper_registry.For_testing.unregister ~base_path keeper_name;
      ignore (Workspace.reset config))
    (fun () ->
       Eio_main.run (fun env ->
         Eio.Switch.run (fun sw ->
           Masc_test_deps.init_eio_clock ~sw env;
           Fs_compat.set_fs (Eio.Stdenv.fs env);
           Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
             Fs_compat.save_file path toml;
             get (Runtime.init_default ~config_path:path);
             Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_image:"base"
               ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper_name;
             let meta =
               get (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ]))
             in
             let meta = get (Keeper_meta_contract.effective_meta_result ~base_path meta) in
             ignore (get (Keeper_meta_store.replace_snapshot config meta));
             ignore (Keeper_registry.register_offline ~base_path keeper_name meta);
             f ~sw ~clock:(Eio.Stdenv.clock env) config))))
;;

let operation_id value =
  match Chat_operation.Operation_id.of_string value with
  | Ok id -> id
  | Error detail -> fail detail
;;

let await ~clock promise =
  Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Promise.await promise)
;;

(* The task waits for [request_ids]. The first claim records the waits with its
   checkpoint and ends; the second claim is the resumed run. [attempts] counts
   the claims, [resumed] resolves when the resumed run has started, and
   [finished] when it settled. [hold_resume] keeps the resumed run from going
   on until it resolves. *)
type waiting_task =
  { attempts : int ref
  ; resumed : unit Eio.Promise.t
  ; finished : unit Eio.Promise.t
  ; scope : Keeper_execution_scope_id.t
  }

let start_waiting_task ?hold_resume ~sw ~clock (config : Workspace.config) ~request_ids =
  let base_path = config.base_path in
  let id = operation_id "kmsg-receipt-resume" in
  let attempts = ref 0 in
  let deferred, deferred_resolver = Eio.Promise.create () in
  let resumed, resumed_resolver = Eio.Promise.create () in
  let finished, finished_resolver = Eio.Promise.create () in
  let scope = Keeper_execution_scope_id.direct_operation id in
  let frame =
    Keeper_repetition_snapshot.admit
      Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh scope)
    |> Result.get_ok
  in
  let checkpoint =
    Keeper_semantic_execution.Official_client
      { client_kind = Muse
      ; runtime_id = "muse.resume"
      ; session_id = "resume-session"
      ; turn_id = "resume-turn"
      ; tool_surface_sha256 = Keeper_checkpoint_ref.sha256_of_canonical_bytes "resume tools"
      ; frame
      }
  in
  let waits =
    List.map
      (fun request_id ->
         Keeper_semantic_execution.receipt_obligation
           ~request_id
           ~state:Keeper_semantic_execution.Pending
         |> Result.get_ok)
      request_ids
  in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    let operation : Chat_operation.t = claim () |> owner_ok |> Option.get in
    incr attempts;
    match !attempts with
    | 1 ->
      ignore
        (command_ok
           (Registry.defer_direct_checkpoint
              ~base_path
              ~keeper_name
              ~operation_id:id
              ~execution_digest:operation.execution_digest
              ~checkpoint
              ~receipt_waits:waits));
      Eio.Promise.resolve deferred_resolver ();
      Owner.Operation_deferred
    | 2 ->
      Eio.Promise.resolve resumed_resolver ();
      Option.iter Eio.Promise.await hold_resume;
      let owner = Registry.get ~base_path ~keeper_name |> Result.get_ok in
      Owner.resume_direct_checkpoint owner ~operation_id:id ~observed:checkpoint |> owner_ok;
      Owner.enter_direct_preparation
        owner
        ~operation_id:id
        ~execution_digest:operation.execution_digest
      |> owner_ok;
      Owner.Operation_succeeded { outcome_ref = "resumed with its receipt" }
    | _ -> fail "the task was claimed a third time"
  in
  let runner =
    Owner.
      { ready = (fun ~keeper_name:_ -> true)
      ; execute
      ; on_execution_settled =
          (fun ~keeper_name:_ ~claimed_operation_id ~operations:_ ~execution:_ ->
             match claimed_operation_id with
             | Some current
               when Chat_operation.Operation_id.equal current id && !attempts = 2 ->
               Eio.Promise.resolve finished_resolver ()
             | Some _ | None -> ())
      }
  in
  ignore
    (Registry.install_from_store
       ~sw
       ~operation_runner:(Some runner)
       ~on_turn_slot_released:None
       config
     |> Result.map_error Registry.install_error_to_string
     |> get);
  let owner = Registry.get ~base_path ~keeper_name |> Result.get_ok in
  Owner.submit_operation
    owner
    ~operation_id:id
    ~source:(`Assoc [ "kind", `String "dashboard" ])
    ~input:(`Assoc [ "message", `String "Wait for the background run" ])
  |> owner_ok
  |> ignore;
  await ~clock deferred;
  { attempts; resumed; finished; scope }
;;

let receipt_for ~request_id =
  Background.receipt_of_unfinished
    ~request_id
    ~arguments:(`Assoc [ "command", `String "sleep 30" ])
    ~cause:Background.restart_cause
;;

let outbox_has config ~viewer request_id =
  Outbox.contains_call
    (get (Outbox.load ~base_path:config.Workspace.base_path ~keeper_name ~viewer))
    ~call_id:request_id
;;

let queued_receipt_hints config =
  get
    (Keeper_registry_event_queue.pending_selections_result
       ~base_path:config.Workspace.base_path
       keeper_name)
;;

(* The receipt is in the outbox, so the wait arrives. The owned receipt gets no
   stimulus, because a stimulus asks any run to read it and no other run may. *)
let test_notify_resumes_the_waiting_task () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-arrived" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    check int "no receipt yet: nothing resumed" 1 !(task.attempts);
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id));
    check bool "the owner's run reads it" true
      (outbox_has config ~viewer:(Outbox.Owner_and_unowned task.scope) request_id);
    check bool "another run does not" false
      (outbox_has config ~viewer:Outbox.Unowned_only request_id);
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the task was claimed again after its receipt arrived" 2 !(task.attempts);
    check int "the owned receipt got no stimulus" 0 (List.length (queued_receipt_hints config)))
;;

let test_arrived_is_safe_to_repeat () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-repeated" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id));
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name);
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "two notices resumed the task once" 2 !(task.attempts);
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name))
;;

let pending_requests config =
  List.sort
    String.compare
    (get
       (Keeper_receipt_wait_resolution.pending_requests
          ~base_path:config.Workspace.base_path
          ~keeper_name))
;;

(* A turn that waited for two requests owns both from the moment it ends, and
   it resumes only when the last receipt has arrived. *)
let test_a_task_waits_for_every_request () =
  with_workspace (fun ~sw ~clock config ->
    let first = "kmsg-first" in
    let second = "kmsg-second" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ first; second ] in
    check (list string) "both requests are owned and pending" [ first; second ]
      (pending_requests config);
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id:first));
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    check int "one receipt is not enough" 1 !(task.attempts);
    check (list string) "the other request is still pending" [ second ]
      (pending_requests config);
    check bool "the first receipt is hidden from other runs" false
      (outbox_has config ~viewer:Outbox.Unowned_only first);
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id:second));
    check bool "the second receipt is hidden from other runs" false
      (outbox_has config ~viewer:Outbox.Unowned_only second);
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the last receipt resumed the task" 2 !(task.attempts);
    check bool "the resumed run reads the first receipt" true
      (outbox_has config ~viewer:(Outbox.Owner_and_unowned task.scope) first);
    check bool "and the second" true
      (outbox_has config ~viewer:(Outbox.Owner_and_unowned task.scope) second))
;;

(* The receipt as it lies in the outbox: the arguments it carries and the text
   the model reads. *)
let receipt_arguments config ~request_id =
  let directory =
    get (Keeper_official_client_paths.outbox_dir ~base_path:config.Workspace.base_path ~keeper_name)
  in
  let carrying =
    List.filter_map
      (fun name ->
         if not (Filename.check_suffix name ".json")
         then None
         else (
           let json =
             Yojson.Safe.from_string
               (In_channel.with_open_bin (Filename.concat directory name) In_channel.input_all)
           in
           match Yojson.Safe.Util.member "call_id" json with
           | `String call_id when String.equal call_id request_id ->
             Some (Yojson.Safe.Util.member "arguments" json)
           | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
             None))
      (Array.to_list (Sys.readdir directory))
  in
  match carrying with
  | [ field ] -> get (Keeper_client_tool_outbox_codec.arguments_of_json field)
  | [] -> fail "no receipt carries the request"
  | _ :: _ :: _ -> fail "two receipts carry the request"
;;

(* A background Execute request as the Keeper records it: the arguments are in
   its request record. [settled] resolves when the worker has finished and the
   request has its final status. *)
let recorded_command = `Assoc [ "command", `String "sleep 30" ]

let submit_background_request ~sw (config : Workspace.config) ~f =
  let settled, resolve_settled = Eio.Promise.create () in
  let request_id =
    match
      Keeper_msg_async.submit_with_request_id
        ~request_context:[ "execute_background", `Assoc [ "arguments", recorded_command ] ]
        ~on_worker_settled:(fun _ ->
          if not (Eio.Promise.is_resolved settled) then Eio.Promise.resolve resolve_settled ())
        ~background_sw:sw
        ~base_path:config.base_path
        ~caller:keeper_name
        ~f
        ~keeper_name
        ()
    with
    | Ok { acceptance = Keeper_msg_async.Durably_accepted; request_id } -> request_id
    | Ok _ | Error _ -> fail "the request was not accepted"
  in
  request_id, settled
;;

(* A run that ended and left no receipt is settled by state. The receipt it
   gets echoes the arguments its request record kept. *)
let test_run_without_worker_or_receipt_is_settled () =
  with_workspace (fun ~sw ~clock config ->
    let request_id, settled =
      submit_background_request ~sw config ~f:(fun ~request_id:_ _ ->
        Keeper_types_profile.tool_result_ok "done")
    in
    await ~clock settled;
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    check bool "no receipt before the sweep" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the task resumed" 2 !(task.attempts);
    let receipt_text =
      String.concat ""
        (Outbox.developer_context
           (get
              (Outbox.load
                 ~base_path:config.base_path
                 ~keeper_name
                 ~viewer:Outbox.Every_receipt)))
    in
    check bool "the unfinished receipt shows the recorded command" true
      (Astring.String.is_infix ~affix:"sleep 30" receipt_text);
    check bool "and carries it as known arguments" true
      (receipt_arguments config ~request_id
       = Keeper_client_tool_outbox_codec.Known recorded_command);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "a second pass resumes nothing more" 2 !(task.attempts))
;;

(* No record of the request means no arguments to echo. The receipt says
   [Unknown]: no value stands in for them, and the text the model reads has no
   empty arguments. *)
let test_run_without_a_record_is_settled_with_unknown_arguments () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-never-recorded" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the task resumed" 2 !(task.attempts);
    check bool "the receipt carries unknown arguments" true
      (receipt_arguments config ~request_id = Keeper_client_tool_outbox_codec.Unknown);
    let text =
      String.concat ""
        (Outbox.developer_context
           (get
              (Outbox.load
                 ~base_path:config.base_path
                 ~keeper_name
                 ~viewer:Outbox.Every_receipt)))
    in
    check bool "the model reads that they are unknown" true
      (Astring.String.is_infix ~affix:{|"arguments":{"unknown":true}|} text);
    check bool "and the message says why" true
      (Astring.String.is_infix ~affix:"does not hold its command" text);
    check bool "no empty arguments reach the model" false
      (Astring.String.is_infix ~affix:{|"arguments":{}|} text
       || Astring.String.is_infix ~affix:{|"known":{}|} text);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "a second pass resumes nothing more" 2 !(task.attempts))
;;

(* The sweep reads the wait, the request record and the outbox, and some time
   later asks the Owner to write the receipt. Meanwhile the wait can arrive
   and the run that waited can read and acknowledge its receipt. The Owner
   writes only while the wait is still pending, so that late sweep writes
   nothing: a second receipt would reach a run that never asked for it. *)
let settle_lost config ~request_id ~writes =
  command_ok
    (Registry.settle_lost_receipt
       ~base_path:config.Workspace.base_path
       ~keeper_name
       ~request_id
       ~retain:(fun () ->
         incr writes;
         Keeper_execute_background.retain_source_lost_receipt
           ~base_path:config.base_path
           ~keeper_name
           ~request_id
           ~arguments:Outbox.Unknown))
;;

let test_a_late_sweep_after_the_receipt_was_consumed_writes_nothing () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-consumed" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id));
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    get
      (Outbox.acknowledge
         (get
            (Outbox.load
               ~base_path:config.base_path
               ~keeper_name
               ~viewer:(Outbox.Owner_and_unowned task.scope))));
    check bool "the run consumed the receipt" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    let writes = ref 0 in
    (match settle_lost config ~request_id ~writes with
     | Keeper_chat_operation_store.Receipt_without_owner -> ()
     | Keeper_chat_operation_store.Receipt_resolved
     | Keeper_chat_operation_store.Receipt_already_arrived ->
       fail "a settled execution still owned the request");
    check int "the late sweep wrote nothing" 0 !writes;
    check bool "so no receipt is left for an unrelated run" false
      (outbox_has config ~viewer:Outbox.Unowned_only request_id))
;;

let test_a_late_sweep_while_the_resumed_run_works_writes_nothing () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-in-use" in
    let release, resolve_release = Eio.Promise.create () in
    let task =
      start_waiting_task ~hold_resume:release ~sw ~clock config ~request_ids:[ request_id ]
    in
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id));
    get (Keeper_client_tool_outbox_wake.notify ~base_path:config.base_path ~keeper_name);
    await ~clock task.resumed;
    get
      (Outbox.acknowledge
         (get
            (Outbox.load
               ~base_path:config.base_path
               ~keeper_name
               ~viewer:(Outbox.Owner_and_unowned task.scope))));
    let writes = ref 0 in
    (match settle_lost config ~request_id ~writes with
     | Keeper_chat_operation_store.Receipt_already_arrived -> ()
     | Keeper_chat_operation_store.Receipt_resolved
     | Keeper_chat_operation_store.Receipt_without_owner ->
       fail "the arrived wait was not reported as arrived");
    check int "the late sweep wrote nothing" 0 !writes;
    check bool "so no receipt is left for an unrelated run" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    Eio.Promise.resolve resolve_release ();
    await ~clock task.finished)
;;

(* Two sweeps that overlap, the one a turn starts when it ends and the one the
   maintenance tick starts, ask for the same receipt. One of them writes it. *)
let test_overlapping_sweeps_write_one_receipt () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-overlap" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    let writes = ref 0 in
    let resolved = ref 0 in
    let sweep () =
      match settle_lost config ~request_id ~writes with
      | Keeper_chat_operation_store.Receipt_resolved -> incr resolved
      | Keeper_chat_operation_store.Receipt_already_arrived
      | Keeper_chat_operation_store.Receipt_without_owner -> ()
    in
    Eio.Fiber.both sweep sweep;
    await ~clock task.finished;
    check int "one sweep wrote the receipt" 1 !writes;
    check int "and one resolved the wait" 1 !resolved)
;;

(* A receipt that cannot be written, by an error or an exception, leaves the
   wait pending and the Owner answering. A later sweep settles it. *)
let test_a_failed_receipt_write_leaves_the_wait_pending () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-write-fails" in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    let settle retain =
      Registry.settle_lost_receipt
        ~base_path:config.Workspace.base_path
        ~keeper_name
        ~request_id
        ~retain
    in
    (match settle (fun () -> Error "disk full") with
     | Error _ -> ()
     | Ok _ -> fail "a write that failed was reported as settled");
    (match settle (fun () -> failwith "boom") with
     | Error _ -> ()
     | Ok _ -> fail "a write that raised was reported as settled");
    check (list string) "the wait is still pending" [ request_id ] (pending_requests config);
    check int "the task did not resume" 1 !(task.attempts);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "a sweep that can write settled it" 2 !(task.attempts))
;;

(* The tool reads who owns the request before it answers. A request another
   conversation already waits for is refused with a message the model reads,
   and the owner's record stays as it was. The execution that owns it can call
   again, and a request nobody waits for is accepted. *)
let wait_call config ~execution_scope request_id =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper_name ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  Keeper_tool_receipt_wait.handle
    ~config
    ~meta
    ~execution_scope:(Some execution_scope)
    ~args:(`Assoc [ "request_id", `String request_id ])
;;

let expect_completed label (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ ->
    fail (label ^ ": the call did not complete: " ^ execution.raw_output)
;;

let test_a_request_another_conversation_waits_for_is_refused () =
  with_workspace (fun ~sw ~clock config ->
    let release, resolve_release = Eio.Promise.create () in
    let owned, _ =
      submit_background_request ~sw config ~f:(fun ~request_id:_ _ ->
        Eio.Promise.await release;
        Keeper_types_profile.tool_result_ok "done")
    in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ owned ] in
    let other = Keeper_execution_scope_id.direct_operation (operation_id "kmsg-other-chat") in
    let owner_of request_id =
      get
        (Keeper_receipt_wait_resolution.request_owner
           ~base_path:config.Workspace.base_path
           ~keeper_name
           ~request_id)
    in
    let refused = wait_call config ~execution_scope:other owned in
    (match refused.disposition with
     | Tool_result.Failed Tool_result.Workflow_rejection -> ()
     | Tool_result.Failed _ | Tool_result.Completed () | Tool_result.Deferred () ->
       fail "another conversation's wait was not refused as a workflow rejection");
    check bool "the model reads that another conversation waits" true
      (Astring.String.is_infix ~affix:"Another conversation" refused.raw_output);
    check bool "the refusal records no wait" true
      (Option.is_none refused.terminal_effect_receipt);
    check bool "the owner's record is unchanged" true
      (owner_of owned = Some task.scope);
    check (list string) "and still pending" [ owned ] (pending_requests config);
    expect_completed "the owning execution calls again"
      (wait_call config ~execution_scope:task.scope owned);
    check bool "the repeat does not move the owner" true (owner_of owned = Some task.scope);
    let free, _ =
      submit_background_request ~sw config ~f:(fun ~request_id:_ _ ->
        Eio.Promise.await release;
        Keeper_types_profile.tool_result_ok "done")
    in
    expect_completed "a request nobody waits for"
      (wait_call config ~execution_scope:other free);
    check bool "accepting it records nothing yet" true (owner_of free = None);
    Eio.Promise.resolve resolve_release ())
;;

(* A request a worker may still own is not lost. The sweep reads the request
   record, never a clock. *)
let test_run_with_a_worker_is_left_waiting () =
  with_workspace (fun ~sw ~clock config ->
    let release, resolve_release = Eio.Promise.create () in
    let request_id, _ =
      submit_background_request ~sw config ~f:(fun ~request_id:_ _ ->
        Eio.Promise.await release;
        Keeper_types_profile.tool_result_ok "done")
    in
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ request_id ] in
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "the sweep left the wait alone" 1 !(task.attempts);
    check bool "and wrote no receipt" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    Eio.Promise.resolve resolve_release ())
;;

(* A schedule is waited for under its schedule id. The sweep reads its row,
   never a clock: a receipt wake that has not ended is left alone, and one that
   ended without its receipt is settled like a run that left neither worker nor
   receipt. *)
let actor kind id : Schedule_domain.actor = { id; kind; display_name = None }

let create_receipt_schedule config ~schedule_id =
  match
    Schedule_service.create
      config
      ~now:100.0
      ~runner_tick_sec:1.0
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(actor Schedule_domain.Human_operator "operator")
      ~scheduled_by:(actor Schedule_domain.Automated_actor keeper_name)
      ~due_at:10_000.0
      ~payload:
        (`Assoc
          [ "kind", `String "masc.keeper_wake"
          ; ( "body"
            , `Assoc
                [ "keeper_name", `String keeper_name
                ; "title", `String "Run result"
                ; "message", `String "check the run"
                ; "delivery", `String "receipt"
                ] )
          ])
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok _ -> ()
  | Error err -> fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let cancel_schedule config ~schedule_id =
  match
    Schedule_service.cancel
      config
      ~authority:Schedule_store.Operator_authority
      ~schedule_id
      ~cancelled_by:(actor Schedule_domain.Human_operator "operator")
      ~reason:"fixture"
      ~withdraw_queued_wakes:(fun _ _ -> Ok ())
  with
  | Ok _ -> ()
  | Error err -> fail ("cancel failed: " ^ Schedule_service.service_error_to_string err)
;;

let test_a_schedule_that_ended_without_a_receipt_is_settled () =
  with_workspace (fun ~sw ~clock config ->
    let schedule_id = "sched-ended-without-receipt" in
    create_receipt_schedule config ~schedule_id;
    cancel_schedule config ~schedule_id;
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ schedule_id ] in
    check bool "no receipt before the sweep" false
      (outbox_has config ~viewer:Outbox.Every_receipt schedule_id);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the task resumed" 2 !(task.attempts);
    let text =
      String.concat ""
        (Outbox.developer_context
           (get
              (Outbox.load
                 ~base_path:config.base_path
                 ~keeper_name
                 ~viewer:Outbox.Every_receipt)))
    in
    check bool "the receipt says the schedule ended without one" true
      (Astring.String.is_infix ~affix:"ended before its receipt was written" text);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "a second pass resumes nothing more" 2 !(task.attempts))
;;

let test_a_schedule_that_has_not_ended_is_left_waiting () =
  with_workspace (fun ~sw ~clock config ->
    let schedule_id = "sched-still-waiting" in
    create_receipt_schedule config ~schedule_id;
    let task = start_waiting_task ~sw ~clock config ~request_ids:[ schedule_id ] in
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "the sweep left the wait alone" 1 !(task.attempts);
    check bool "and wrote no receipt" false
      (outbox_has config ~viewer:Outbox.Every_receipt schedule_id))
;;

let () =
  run
    "keeper receipt wait resume"
    [ ( "arrival"
      , [ test_case "notify resumes the waiting task" `Quick
            test_notify_resumes_the_waiting_task
        ; test_case "a repeated notice changes nothing" `Quick test_arrived_is_safe_to_repeat
        ; test_case "a task waits for every request it named" `Quick
            test_a_task_waits_for_every_request
        ] )
    ; ( "late sweep"
      , [ test_case "a sweep after the receipt was consumed writes nothing" `Quick
            test_a_late_sweep_after_the_receipt_was_consumed_writes_nothing
        ; test_case "a sweep while the resumed run works writes nothing" `Quick
            test_a_late_sweep_while_the_resumed_run_works_writes_nothing
        ; test_case "overlapping sweeps write one receipt" `Quick
            test_overlapping_sweeps_write_one_receipt
        ; test_case "a failed receipt write leaves the wait pending" `Quick
            test_a_failed_receipt_write_leaves_the_wait_pending
        ] )
    ; ( "lost run"
      , [ test_case "a run without worker or receipt is settled" `Quick
            test_run_without_worker_or_receipt_is_settled
        ; test_case "a run without a record is settled with unknown arguments" `Quick
            test_run_without_a_record_is_settled_with_unknown_arguments
        ; test_case "a run with a worker is left waiting" `Quick
            test_run_with_a_worker_is_left_waiting
        ; test_case "a schedule that ended without a receipt is settled" `Quick
            test_a_schedule_that_ended_without_a_receipt_is_settled
        ; test_case "a schedule that has not ended is left waiting" `Quick
            test_a_schedule_that_has_not_ended_is_left_waiting
        ; test_case "a request another conversation waits for is refused" `Quick
            test_a_request_another_conversation_waits_for_is_refused
        ] )
    ]
;;
