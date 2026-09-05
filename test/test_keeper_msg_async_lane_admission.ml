(** Tests for masc#25398 (RFC-0348 PR-1): keeper_msg lane admission is bounded.

    Before the fix, [with_lane_gate] fell back to an unbounded
    [Eio.Mutex.lock] when the lane was contended, so one hung durable write
    leaked the per-keeper submission/persistence lane permanently and every
    later submit for that keeper hung behind it.

    The lane gate is now a one-token [Eio.Semaphore]; the submit path races
    each acquisition against a shared per-submit budget
    ([MASC_KEEPER_LANE_ADMISSION_WAIT_BUDGET_SEC]) and fails with
    [Submit_lane_unavailable] instead of waiting forever. Status-settlement
    acquisitions stay unbounded so a committed write can always settle.

    These tests hold a lane by blocking inside the [before_durable_write]
    hook (which runs while the persistence lane is held) and assert:
    1. without an ambient monotonic clock, a contended bounded acquisition
       refuses immediately instead of hanging (honest refusal);
    2. a contended submit fails fast with [Submit_lane_unavailable], and the
       lane is usable again once the stuck write finishes (no starvation);
    3. a persistence-lane timeout cleans up the fresh reservation;
    4. the settlement path (cancel) is never rejected — it waits unbounded;
    5. contended submitters are admitted FIFO. *)

open Alcotest
module Keeper_msg_async = Masc.Keeper_msg_async
module Keeper_types_profile = Masc.Keeper_types_profile

let () = Mirage_crypto_rng_unix.use_default ()
let caller = "lane-admission-test-caller"
let budget_env_key = "MASC_KEEPER_LANE_ADMISSION_WAIT_BUDGET_SEC"

let set_budget sec = Unix.putenv budget_env_key (Printf.sprintf "%.3f" sec)

exception Synthetic_background_switch_closed

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-25398-lane-admission-%d-%06x"
         (Unix.getpid ())
         (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  let base = try Unix.realpath base with Unix.Unix_error _ -> base in
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
;;

(** A [before_durable_write] hook that, while [armed] is set, signals
    [write_started] and then blocks until [release] is resolved — the
    minimal reproduction of a durable write that hangs while holding the
    per-keeper persistence lane. *)
let make_blocking_hook ~armed ~write_started ~release =
  fun _stage ->
    if !armed
    then (
      (match write_started with
       | Some resolve -> Eio.Promise.resolve resolve ()
       | None -> ());
      Eio.Promise.await release)
;;

let submit_ok ops ~background_sw ~base_path ~keeper_name =
  match
    Keeper_msg_async.For_testing.submit
      ops
      ~background_sw
      ~base_path
      ~caller
      ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "done")
      ~keeper_name
      ()
  with
  | Ok { Keeper_msg_async.request_id; acceptance = Keeper_msg_async.Durably_accepted } ->
    request_id
  | Ok outcome ->
    fail
      (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
  | Error error ->
    fail
      (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
;;

let expect_lane_unavailable = function
  | Error
      (Keeper_msg_async.Submit_lane_unavailable { lane; wait_budget_sec }) ->
    lane, wait_budget_sec
  | Ok outcome ->
    fail
      ("expected Submit_lane_unavailable, got accepted: "
       ^ (Keeper_msg_async.submit_outcome_to_json outcome
          |> Yojson.Safe.to_string))
  | Error error ->
    fail
      ("expected Submit_lane_unavailable, got: "
       ^ (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string))
;;

(** 1. Pre-boot honest refusal: with no ambient monotonic clock installed, a
    contended bounded acquisition fails fast instead of hanging. This case
    must run before any case that installs the clock (the context is
    process-global), which Alcotest's declaration order guarantees. *)
let test_contended_submit_without_clock_refuses_fast () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        (* Deliberately do NOT call [Eio_context.set_mono_clock]. *)
        set_budget 30.0;
        let armed = ref true in
        let write_started_p, write_started = Eio.Promise.create () in
        let release_p, release = Eio.Promise.create () in
        let blocking_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:
              (make_blocking_hook
                 ~armed
                 ~write_started:(Some write_started)
                 ~release:release_p)
            ()
        in
        let stuck =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.submit
              blocking_ops
              ~background_sw:sw
              ~base_path
              ~caller
              ~f:(fun _request_sw ->
                Keeper_types_profile.tool_result_ok "stuck-write")
              ~keeper_name:"lane-no-clock"
              ())
        in
        Eio.Promise.await write_started_p;
        let started = Unix.gettimeofday () in
        let lane, _ =
          Keeper_msg_async.For_testing.submit
            (Keeper_msg_async.For_testing.make_request_ops ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "second")
            ~keeper_name:"lane-no-clock"
            ()
          |> expect_lane_unavailable
        in
        let elapsed = Unix.gettimeofday () -. started in
        check string "refused on the submission lane" "submission" lane;
        check
          bool
          "refusal was immediate, not a 30s wait"
          true
          (elapsed < 5.0);
        armed := false;
        Eio.Promise.resolve release ();
        (match Eio.Promise.await_exn stuck with
         | Ok ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted; _ } : Keeper_msg_async.submit_outcome) ->
           ()
         | Ok outcome ->
           fail
             (Keeper_msg_async.submit_outcome_to_json outcome
              |> Yojson.Safe.to_string)
         | Error error ->
           fail
             (Keeper_msg_async.submit_error_to_json error
              |> Yojson.Safe.to_string));
        Keeper_msg_async.For_testing.clear ())))
;;

(** 2. Bounded expiry fails fast with [Submit_lane_unavailable]; once the
    stuck write finishes, the same lane accepts again (no starvation, no
    leak). *)
let test_contended_submit_times_out_and_lane_recovers () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Eio.Switch.run (fun sw ->
        set_budget 0.3;
        let armed = ref true in
        let write_started_p, write_started = Eio.Promise.create () in
        let release_p, release = Eio.Promise.create () in
        let blocking_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:
              (make_blocking_hook
                 ~armed
                 ~write_started:(Some write_started)
                 ~release:release_p)
            ()
        in
        let stuck =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.submit
              blocking_ops
              ~background_sw:sw
              ~base_path
              ~caller
              ~f:(fun _request_sw ->
                Keeper_types_profile.tool_result_ok "stuck-write")
              ~keeper_name:"lane-timeout"
              ())
        in
        Eio.Promise.await write_started_p;
        let started = Unix.gettimeofday () in
        let lane, budget =
          Keeper_msg_async.For_testing.submit
            (Keeper_msg_async.For_testing.make_request_ops ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "second")
            ~keeper_name:"lane-timeout"
            ()
          |> expect_lane_unavailable
        in
        let elapsed = Unix.gettimeofday () -. started in
        check string "timed out on the submission lane" "submission" lane;
        check bool "budget is the configured one" true (budget > 0.2 && budget < 0.4);
        check bool "failed near the budget, did not hang" true (elapsed < 5.0);
        armed := false;
        Eio.Promise.resolve release ();
        (match Eio.Promise.await_exn stuck with
         | Ok ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted; _ } : Keeper_msg_async.submit_outcome) ->
           ()
         | Ok outcome ->
           fail
             (Keeper_msg_async.submit_outcome_to_json outcome
              |> Yojson.Safe.to_string)
         | Error error ->
           fail
             (Keeper_msg_async.submit_error_to_json error
              |> Yojson.Safe.to_string));
        (* The lane survived: a fresh submit on the same keeper is accepted. *)
        ignore
          (submit_ok
             (Keeper_msg_async.For_testing.make_request_ops ())
             ~background_sw:sw
             ~base_path
             ~keeper_name:"lane-timeout");
        Keeper_msg_async.For_testing.clear ())))
;;

(** 3. A persistence-lane timeout drops the fresh reservation: the reserved
    request-id count returns to its baseline. *)
let test_persistence_lane_timeout_cleans_reservation () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Eio.Switch.run (fun sw ->
        set_budget 0.3;
        (* A running request whose later status write will block inside the
           persistence lane. *)
        let never_p, _never = Eio.Promise.create () in
        let request_id =
          match
            Keeper_msg_async.For_testing.submit
              (Keeper_msg_async.For_testing.make_request_ops ())
              ~background_sw:sw
              ~base_path
              ~caller
              ~f:(fun _request_sw ->
                Eio.Promise.await never_p;
                Keeper_types_profile.tool_result_ok "unreachable")
              ~keeper_name:"lane-persist"
              ()
          with
          | Ok { Keeper_msg_async.request_id; _ } -> request_id
          | Error error ->
            fail
              (Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string)
        in
        let armed = ref true in
        let write_started_p, write_started = Eio.Promise.create () in
        let release_p, release = Eio.Promise.create () in
        let blocking_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:
              (make_blocking_hook
                 ~armed
                 ~write_started:(Some write_started)
                 ~release:release_p)
            ()
        in
        (* The cancel's Cancelling-intent write blocks holding the
           persistence lane only; the submission lane stays free. *)
        let cancel_fiber =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.cancel
              blocking_ops
              ~base_path
              ~caller
              request_id)
        in
        Eio.Promise.await write_started_p;
        let baseline = Keeper_msg_async.For_testing.reserved_request_id_count () in
        let lane, _ =
          Keeper_msg_async.For_testing.submit
            (Keeper_msg_async.For_testing.make_request_ops ())
            ~background_sw:sw
            ~base_path
            ~caller
            ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "second")
            ~keeper_name:"lane-persist"
            ()
          |> expect_lane_unavailable
        in
        check string "timed out on the persistence lane" "persistence" lane;
        check
          int
          "reservation cleaned up after persistence-lane timeout"
          baseline
          (Keeper_msg_async.For_testing.reserved_request_id_count ());
        armed := false;
        Eio.Promise.resolve release ();
        ignore (Eio.Promise.await_exn cancel_fiber);
        Keeper_msg_async.For_testing.clear ())))
;;

(** 4. The settlement path is never lane-rejected: a second cancel issued
    while the persistence lane is stuck waits (unbounded) and completes once
    the lane frees. *)
let test_settlement_path_waits_without_rejection () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        set_budget 0.3;
        let never_p, _never = Eio.Promise.create () in
        let request_id =
          match
            Keeper_msg_async.For_testing.submit
              (Keeper_msg_async.For_testing.make_request_ops ())
              ~background_sw:sw
              ~base_path
              ~caller
              ~f:(fun _request_sw ->
                Eio.Promise.await never_p;
                Keeper_types_profile.tool_result_ok "unreachable")
              ~keeper_name:"lane-settle"
              ()
          with
          | Ok { Keeper_msg_async.request_id; _ } -> request_id
          | Error error ->
            fail
              (Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string)
        in
        let armed = ref true in
        let write_started_p, write_started = Eio.Promise.create () in
        let release_p, release = Eio.Promise.create () in
        let blocking_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:
              (make_blocking_hook
                 ~armed
                 ~write_started:(Some write_started)
                 ~release:release_p)
            ()
        in
        let first_cancel =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.cancel
              blocking_ops
              ~base_path
              ~caller
              request_id)
        in
        Eio.Promise.await write_started_p;
        (* A settlement-path caller (cancel) arrives while the persistence
           lane is stuck. It must wait, not fail. *)
        let second_cancel =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.cancel
              (Keeper_msg_async.For_testing.make_request_ops ())
              ~base_path
              ~caller
              request_id)
        in
        Eio.Time.sleep clock 0.5;
        check
          bool
          "settlement-path cancel still waiting, not rejected"
          false
          (Eio.Promise.peek second_cancel |> Option.is_some);
        armed := false;
        Eio.Promise.resolve release ();
        ignore (Eio.Promise.await_exn first_cancel);
        ignore (Eio.Promise.await_exn second_cancel);
        Keeper_msg_async.For_testing.clear ())))
;;

(** 5. Contended submitters are admitted FIFO: the first queued submit
    completes before the second once the stuck write releases. *)
let test_contended_submitters_admitted_fifo () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        set_budget 5.0;
        let armed = ref true in
        let write_started_p, write_started = Eio.Promise.create () in
        let release_p, release = Eio.Promise.create () in
        let blocking_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:
              (make_blocking_hook
                 ~armed
                 ~write_started:(Some write_started)
                 ~release:release_p)
            ()
        in
        let stuck =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Keeper_msg_async.For_testing.submit
              blocking_ops
              ~background_sw:sw
              ~base_path
              ~caller
              ~f:(fun _request_sw ->
                Keeper_types_profile.tool_result_ok "stuck-write")
              ~keeper_name:"lane-fifo"
              ())
        in
        Eio.Promise.await write_started_p;
        let completion_order = ref [] in
        let record name = completion_order := name :: !completion_order in
        let waiting_ops = Keeper_msg_async.For_testing.make_request_ops () in
        let first =
          Eio.Fiber.fork_promise ~sw (fun () ->
            let result =
              Keeper_msg_async.For_testing.submit
                waiting_ops
                ~background_sw:sw
                ~base_path
                ~caller
                ~f:(fun _request_sw ->
                  Keeper_types_profile.tool_result_ok "first")
                ~keeper_name:"lane-fifo"
                ()
            in
            record "first";
            result)
        in
        Eio.Time.sleep clock 0.15;
        let second =
          Eio.Fiber.fork_promise ~sw (fun () ->
            let result =
              Keeper_msg_async.For_testing.submit
                waiting_ops
                ~background_sw:sw
                ~base_path
                ~caller
                ~f:(fun _request_sw ->
                  Keeper_types_profile.tool_result_ok "second")
                ~keeper_name:"lane-fifo"
                ()
            in
            record "second";
            result)
        in
        Eio.Time.sleep clock 0.15;
        armed := false;
        Eio.Promise.resolve release ();
        ignore (Eio.Promise.await_exn stuck);
        (match Eio.Promise.await_exn first, Eio.Promise.await_exn second with
         | Ok ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted; _ } : Keeper_msg_async.submit_outcome),
           Ok ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted; _ } : Keeper_msg_async.submit_outcome) ->
           ()
         | first_result, second_result ->
           let render = function
             | Ok outcome ->
               Keeper_msg_async.submit_outcome_to_json outcome
               |> Yojson.Safe.to_string
             | Error error ->
               Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string
           in
           failf
             "both queued submits must be accepted; first=%s second=%s"
             (render first_result)
             (render second_result));
        (match List.rev !completion_order with
         | [ "first"; "second" ] -> ()
         | order ->
           failf
             "expected FIFO completion [first; second], got [%s]"
             (String.concat "; " order));
        Keeper_msg_async.For_testing.clear ())))
;;

(** 6. Reservation cleanup is finally-guaranteed: a durable write that
    *raises* (not times out) still drops the fresh reservation. *)
let test_raising_durable_write_cleans_reservation () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
      Eio.Switch.run (fun sw ->
        set_budget 5.0;
        let baseline = Keeper_msg_async.For_testing.reserved_request_id_count () in
        let raising_ops =
          Keeper_msg_async.For_testing.make_request_ops
            ~before_durable_write:(fun _stage -> failwith "synthetic write crash")
            ()
        in
        (match
           Keeper_msg_async.For_testing.submit
             raising_ops
             ~background_sw:sw
             ~base_path
             ~caller
             ~f:(fun _request_sw -> Keeper_types_profile.tool_result_ok "x")
             ~keeper_name:"lane-raise"
             ()
         with
         | Ok outcome ->
           (* A caught write failure is also acceptable — the point is the
              reservation must not leak either way. *)
           Printf.eprintf
             "note: raising hook was caught into %s\n%!"
             (Keeper_msg_async.submit_outcome_to_json outcome
              |> Yojson.Safe.to_string)
         | Error error ->
           Printf.eprintf
             "note: raising hook surfaced as %s\n%!"
             (Keeper_msg_async.submit_error_to_json error
              |> Yojson.Safe.to_string)
         | exception Failure _ -> ());
        check
          int
          "reservation cleaned up even when the write raises"
          baseline
          (Keeper_msg_async.For_testing.reserved_request_id_count ());
        Keeper_msg_async.For_testing.clear ())))
;;

let () =
  Alcotest.run
    "keeper_msg_async_lane_admission"
    [ ( "lane admission"
      , [ test_case "no clock: contended submit refuses fast" `Quick
            test_contended_submit_without_clock_refuses_fast
        ; test_case "contended submit times out, lane recovers" `Quick
            test_contended_submit_times_out_and_lane_recovers
        ; test_case "persistence-lane timeout cleans reservation" `Quick
            test_persistence_lane_timeout_cleans_reservation
        ; test_case "settlement path waits without rejection" `Quick
            test_settlement_path_waits_without_rejection
        ; test_case "contended submitters admitted FIFO" `Quick
            test_contended_submitters_admitted_fifo
        ; test_case "raising durable write cleans reservation" `Quick
            test_raising_durable_write_cleans_reservation
        ] )
    ]
;;
