(** Two fibers mutating one persisted run registry on the same domain.

    The registry serializes "append the JSONL event, then publish the row" so a
    completion cannot overtake its own registration in the replay log. That
    critical section performs a durable append, which suspends the fiber.

    A raw [Stdlib.Mutex] held across that suspension is still held by the same
    OS thread when the scheduler runs the next fiber on this domain, so the
    second fiber's acquisition is recursive and pthreads rejects it:
    [Sys_error "Mutex.lock: Resource deadlock avoided"].

    Measured on the live fleet before the fix: 218 occurrences on 2026-08-11,
    37 on 2026-08-10, and one fatal in
    [Completion_authority_agent.process_task_once] that took the server down
    at 2026-08-12 20:55:29 KST. Most other occurrences were swallowed by
    worker exception handlers, so the crash count understates the reach.

    These cases run the interleaving directly: [Eio.Fiber.both] resumes the
    second fiber precisely while the first is suspended inside the lock.

    The shared [Run_registry_core] is not the whole surface: a consumer that
    wraps [Store.register] in its own raw mutex reproduces the same recursion
    one layer up. [Exact_lane_run_registry] did, and the board attention
    worker drove 231 of the measured occurrences through it, so every
    instantiation is covered here rather than only the one the fatal
    backtrace named. *)

open Alcotest

module R = Masc.Verification_run_registry
module Ex = Masc.Exact_lane_run_registry

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let fresh_path suffix =
  let path = Filename.temp_file "run-registry-concurrent-" suffix in
  remove_if_exists path;
  path
;;

let register t ~verification_id ~started_at =
  R.register_running
    t
    ~verification_id
    ~task_id:"task-concurrent"
    ~producer:"keeper-beta-agent"
    ~authority_kind:"system_llm_agent"
    ~authority_actor:("system-llm-agent-" ^ verification_id)
    ~started_at
;;

let ids_of t =
  R.list_runs t
  |> List.map (fun (run : R.run) -> run.verification_id)
  |> List.sort String.compare
;;

let test_concurrent_registrations_both_land () =
  let path = fresh_path ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists path)
    (fun () ->
      let t = R.create ~path () in
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () -> register t ~verification_id:"vrf-a" ~started_at:100.0)
          (fun () -> register t ~verification_id:"vrf-b" ~started_at:101.0));
      check
        (list string)
        "both concurrent registrations are tracked"
        [ "vrf-a"; "vrf-b" ]
        (ids_of t))
;;

let test_concurrent_register_and_complete_both_land () =
  let path = fresh_path ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists path)
    (fun () ->
      let t = R.create ~path () in
      register t ~verification_id:"vrf-first" ~started_at:100.0;
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () ->
            R.mark_completed
              t
              ~verification_id:"vrf-first"
              ~outcome:(R.Approved { reason = "" })
              ~tools:[]
              ~elapsed_s:1.0
              ())
          (fun () -> register t ~verification_id:"vrf-second" ~started_at:102.0));
      check
        (list string)
        "a completion and a registration interleave without losing either"
        [ "vrf-first"; "vrf-second" ]
        (ids_of t))
;;

(* The append-only log is the durability contract: a row that only reached
   memory is lost on restart. Replay itself drops never-completed Running rows
   by design ("review fibers do not survive server restart"), so the fact to
   assert is that both appends reached the file. *)
let register_events_in path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let rec count acc =
        match input_line ic with
        | exception End_of_file -> acc
        | line ->
          let is_register =
            match Yojson.Safe.from_string line with
            | `Assoc fields ->
              (match List.assoc_opt "event" fields with
               | Some (`String "register") -> true
               | _ -> false)
            | _ -> false
            | exception _ -> false
          in
          count (if is_register then acc + 1 else acc)
      in
      count 0)
;;

let test_both_appends_reach_the_log () =
  let path = fresh_path ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists path)
    (fun () ->
      let t = R.create ~path () in
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () -> register t ~verification_id:"vrf-x" ~started_at:100.0)
          (fun () -> register t ~verification_id:"vrf-y" ~started_at:101.0));
      check int "both registrations were appended" 2 (register_events_in path))
;;

(* The board attention worker's path. It reaches the shared core through a
   second lock of its own, which is why fixing only the core left this lane
   raising in production. *)
let register_exact t ~run_id =
  Ex.register_running
    t
    ~run_id
    ~lane:Ex.Board_attention
    ~actor:"keeper-beta-agent"
    ~started_at:100.0
    ~input:(Ex.Exact_input (`Assoc []))
;;

let exact_ids t =
  Ex.list_runs t |> List.map (fun (run : Ex.run) -> run.run_id) |> List.sort String.compare
;;

let test_exact_lane_concurrent_registrations () =
  let path = fresh_path ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists path)
    (fun () ->
      let t = Ex.create ~path () in
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () -> register_exact t ~run_id:"exact-a")
          (fun () -> register_exact t ~run_id:"exact-b"));
      check
        (list string)
        "both exact-lane registrations are tracked"
        [ "exact-a"; "exact-b" ]
        (exact_ids t))
;;

let test_exact_lane_completion_against_registration () =
  let path = fresh_path ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists path)
    (fun () ->
      let t = Ex.create ~path () in
      register_exact t ~run_id:"exact-first";
      Eio_main.run (fun _env ->
        Eio.Fiber.both
          (fun () ->
            ignore
              (Ex.mark_completed
                 t
                 ~run_id:"exact-first"
                 ~outcome:Ex.Succeeded
                 ~elapsed_s:1.0
                 ~selected_slot:None
                 ~output:(`Assoc [])))
          (fun () -> register_exact t ~run_id:"exact-second"));
      check
        (list string)
        "an exact-lane completion and registration interleave without loss"
        [ "exact-first"; "exact-second" ]
        (exact_ids t))
;;

let () =
  run
    "run_registry_concurrent_mutation"
    [ ( "same-domain fibers"
      , [ test_case
            "two registrations"
            `Quick
            test_concurrent_registrations_both_land
        ; test_case
            "completion against registration"
            `Quick
            test_concurrent_register_and_complete_both_land
        ; test_case
            "both appends reach the log"
            `Quick
            test_both_appends_reach_the_log
        ] )
    ; ( "exact lane (own outer lock)"
      , [ test_case
            "two registrations"
            `Quick
            test_exact_lane_concurrent_registrations
        ; test_case
            "completion against registration"
            `Quick
            test_exact_lane_completion_against_registration
        ] )
    ]
