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
    second fiber precisely while the first is suspended inside the lock. *)

open Alcotest

module R = Masc.Verification_run_registry

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
    ~producer:"keeper-rondo-agent"
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
              ~outcome:R.Approved
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
    ]
