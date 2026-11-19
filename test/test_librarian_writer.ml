(* One Keeper's writer (RFC librarian-call-only-proposes §8.6, §9): the fiber
   that boots the store, answers what arrives in the order it arrived, holds
   the lock for as long as it lives, and ends when its Keeper is gone. *)

open Alcotest
module Writer = Masc.Librarian_writer
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log = Masc.Librarian_log
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Envelope = Masc.Librarian_envelope
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Digest = Agent_core.Checkpoint_objects

let keeper_id = "keeper-a"

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let new_place () : Machine.place =
  { memory_dir = Filename.temp_dir "memory" ""
  ; turns_dir = Filename.temp_dir "turns" ""
  ; keeper_id
  }
;;

let start_turn_log (place : Machine.place) =
  match
    Turn_store.append
      ~path:(Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

let started_place () =
  let place = new_place () in
  start_turn_log place;
  place
;;

let stop_text : Store.stop -> string = function
  | Log_diverged _ -> "diverged"
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
;;

let status_text writer =
  match Writer.status writer with
  | Booting -> "booting"
  | Open (Started _) -> "open at its start"
  | Open (Committed { seq; _ }) -> Printf.sprintf "open at commit %d" seq
  | Stopped stop -> "stopped: " ^ stop_text stop
  | Retired -> "retired"
;;

let unavailable_text : Machine.unavailable -> string = function
  | Store_stopped stop -> "the store is stopped: " ^ stop_text stop
  | Keeper_retired -> "the keeper is retired"
;;

let write_text : Machine.write_answer -> string = function
  | Written line -> Printf.sprintf "written as commit %d" line.seq
  | Already_held -> "already held"
  | Already_done -> "already done"
  | Already_absent -> "already absent"
  | Refused refusal -> "refused: " ^ Direct.refusal_kind refusal
  | Not_a_snapshot (_ : Envelope.refusal) -> "not a snapshot"
  | Unavailable why -> unavailable_text why
;;

let act_text : Machine.act_answer -> string = function
  | Done -> "done"
  | Not_done Nothing_to_resume -> "nothing to resume"
  | Not_done Not_stopped -> "not stopped"
  | Not_done Snapshot_mismatch -> "snapshot mismatch"
  | Not_done Snapshot_unreadable -> "snapshot unreadable"
  | Not_done (Act_unavailable why) -> unavailable_text why
;;

let retirement_text : Writer.retirement -> string = function
  | Retired_now -> "retired"
  | Still_registered -> "still registered"
;;

let remember claim =
  Direct.Remember
    { claim; category = Types.Constraint; basis = Types.Observed Types.Transcript }
;;

let write writer claim =
  write_text (Writer.write writer ~by:Effects.Keeper ~trace:"turn" (remember claim))
;;

(* Every line gets the next second. *)
let ticking () =
  let clock = ref 200.0 in
  fun () ->
    clock := !clock +. 1.0;
    !clock
;;

let with_switch body = Eio_main.run (fun (_ : Eio_unix.Stdenv.base) -> Eio.Switch.run body)

let start ?(registered = fun () -> true) ~sw place =
  Writer.start ~sw ~now:(ticking ()) ~registered place
;;

let test_write_waits_for_the_boot () =
  with_switch (fun sw ->
    let writer = start ~sw (started_place ()) in
    check string "a write sent before the store is open is answered once it is"
      "written as commit 1" (write writer "the port is 8935");
    check string "the status is the line that write committed" "open at commit 1"
      (status_text writer);
    match Writer.status writer with
    | Open line ->
      let view = Writer.view line in
      check bool "nothing is read yet" true
        (match view.covers_through with
         | Before_first -> true
         | Through _ -> false);
      check int "reading starts at the mark the turn log started with" 4
        view.covered.closed_messages;
      check (option string) "no working state yet" None view.working_state
    | Booting | Stopped _ | Retired -> fail "the store is not open")
;;

let test_writes_are_answered_in_the_order_they_came () =
  with_switch (fun sw ->
    let writer = start ~sw (started_place ()) in
    let first, second =
      Eio.Fiber.pair
        (fun () -> write writer "the port is 8935")
        (fun () -> write writer "the owner is the release team")
    in
    check string "the one that came first" "written as commit 1" first;
    check string "the one that came second" "written as commit 2" second)
;;

let test_stopped_until_resumed () =
  with_switch (fun sw ->
    let place = new_place () in
    let writer = start ~sw place in
    check string "a Keeper without a turn log" "the store is stopped: store unwritable"
      (write writer "the port is 8935");
    check string "the status says so" "stopped: store unwritable" (status_text writer);
    check string "a resume runs the boot" "done" (act_text (Writer.resume writer));
    check string "which stops the same way" "stopped: store unwritable" (status_text writer);
    start_turn_log place;
    check string "with a turn log" "done" (act_text (Writer.resume writer));
    check string "the store opens" "open at its start" (status_text writer);
    check string "and takes the write" "written as commit 1" (write writer "the port is 8935");
    check string "an open store has nothing to resume" "nothing to resume"
      (act_text (Writer.resume writer)))
;;

let test_one_writer_holds_the_lock () =
  with_switch (fun sw ->
    let place = started_place () in
    let registered = ref true in
    let first = start ~registered:(fun () -> !registered) ~sw place in
    check string "the first writer" "written as commit 1" (write first "the port is 8935");
    let second = start ~sw place in
    check string "a second writer for the same Keeper does not get the lock"
      "the store is stopped: store unwritable"
      (write second "the owner is the release team");
    check string "a retirement while the Keeper is registered is dropped" "still registered"
      (retirement_text (Writer.retire first));
    check string "and the writer goes on" "written as commit 2"
      (write first "the owner is the release team");
    registered := false;
    check string "once the Keeper is gone the writer ends" "retired"
      (retirement_text (Writer.retire first));
    check string "its status says so" "retired" (status_text first);
    check string "it takes no write" "the keeper is retired" (write first "the probe runs");
    check string "nor an act" "the keeper is retired" (act_text (Writer.resume first));
    check string "a second retirement finds it ended" "retired"
      (retirement_text (Writer.retire first));
    check string "the lock is free: the second writer boots" "done"
      (act_text (Writer.resume second));
    check string "from the line the first one left" "open at commit 2" (status_text second);
    check string "and commits after it" "written as commit 3" (write second "the probe runs"))
;;

let () =
  run "librarian_writer"
    [ ( "writer"
      , [ test_case "a write waits for the boot" `Quick test_write_waits_for_the_boot
        ; test_case "writes are answered in the order they came" `Quick
            test_writes_are_answered_in_the_order_they_came
        ; test_case "stopped until resumed" `Quick test_stopped_until_resumed
        ; test_case "one writer holds the lock" `Quick test_one_writer_holds_the_lock
        ] )
    ]
;;
