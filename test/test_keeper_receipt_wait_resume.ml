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

(* The task waits for [request_id]. The first claim records the wait with its
   checkpoint and ends; the second claim is the resumed run. [attempts] counts
   the claims, and [finished] resolves when the resumed run settled. *)
type waiting_task =
  { attempts : int ref
  ; finished : unit Eio.Promise.t
  ; scope : Keeper_execution_scope_id.t
  }

let start_waiting_task ~sw ~clock (config : Workspace.config) ~request_id =
  let base_path = config.base_path in
  let id = operation_id "kmsg-receipt-resume" in
  let attempts = ref 0 in
  let deferred, deferred_resolver = Eio.Promise.create () in
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
  let wait =
    Keeper_semantic_execution.receipt_obligation
      ~request_id
      ~state:Keeper_semantic_execution.Pending
    |> Result.get_ok
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
              ~receipt_wait:(Some wait)));
      Eio.Promise.resolve deferred_resolver ();
      Owner.Operation_deferred
    | 2 ->
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
  { attempts; finished; scope }
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
    let task = start_waiting_task ~sw ~clock config ~request_id in
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
    let task = start_waiting_task ~sw ~clock config ~request_id in
    get (Outbox.retain ~base_path:config.base_path ~keeper_name (receipt_for ~request_id));
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name);
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "two notices resumed the task once" 2 !(task.attempts);
    get (Keeper_receipt_wait_resolution.arrived ~base_path:config.base_path ~keeper_name))
;;

(* A wait whose run is gone is settled by state: the request has ended, or
   never existed, and no receipt is in the outbox. *)
let test_run_without_worker_or_receipt_is_settled () =
  with_workspace (fun ~sw ~clock config ->
    let request_id = "kmsg-never-recorded" in
    let task = start_waiting_task ~sw ~clock config ~request_id in
    check bool "no receipt before the sweep" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    await ~clock task.finished;
    check int "the task resumed" 2 !(task.attempts);
    check bool "the sweep wrote an unfinished receipt for the resumed run" true
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "a second pass resumes nothing more" 2 !(task.attempts))
;;

(* A request a worker may still own is not lost. The sweep reads the request
   record, never a clock. *)
let test_run_with_a_worker_is_left_waiting () =
  with_workspace (fun ~sw ~clock config ->
    let release, resolve_release = Eio.Promise.create () in
    let request_id =
      match
        Keeper_msg_async.submit_with_request_id
          ~request_context:
            [ ( "execute_background"
              , `Assoc [ "arguments", `Assoc [ "command", `String "sleep 30" ] ] )
            ]
          ~background_sw:sw
          ~base_path:config.base_path
          ~caller:keeper_name
          ~f:(fun ~request_id:_ _ ->
            Eio.Promise.await release;
            Keeper_types_profile.tool_result_ok "done")
          ~keeper_name
          ()
      with
      | Ok { acceptance = Keeper_msg_async.Durably_accepted; request_id } -> request_id
      | Ok _ | Error _ -> fail "the request was not accepted"
    in
    let task = start_waiting_task ~sw ~clock config ~request_id in
    get (Keeper_receipt_wait_sweep.settle_lost ~base_path:config.base_path ~keeper_name);
    check int "the sweep left the wait alone" 1 !(task.attempts);
    check bool "and wrote no receipt" false
      (outbox_has config ~viewer:Outbox.Every_receipt request_id);
    Eio.Promise.resolve resolve_release ())
;;

let () =
  run
    "keeper receipt wait resume"
    [ ( "arrival"
      , [ test_case "notify resumes the waiting task" `Quick
            test_notify_resumes_the_waiting_task
        ; test_case "a repeated notice changes nothing" `Quick test_arrived_is_safe_to_repeat
        ] )
    ; ( "lost run"
      , [ test_case "a run without worker or receipt is settled" `Quick
            test_run_without_worker_or_receipt_is_settled
        ; test_case "a run with a worker is left waiting" `Quick
            test_run_with_a_worker_is_left_waiting
        ] )
    ]
;;
