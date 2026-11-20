(* The writers of a process (RFC librarian-call-only-proposes §8.6, §9.5,
   §11.1): a registered Keeper gets its one writer when it is first asked
   about, a Keeper that is not registered gets none, and a Keeper that was
   taken out and put back is written to again. *)

open Alcotest
module Writers = Masc.Librarian_writers
module Writer = Masc.Librarian_writer
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Envelope = Masc.Librarian_envelope
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Digest = Agent_core.Checkpoint_objects

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

let start_turn_log (place : Machine.place) =
  match
    Turn_store.append
      ~path:
        (Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id:place.keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

(* Every line gets the next second. *)
let ticking () =
  let clock = ref 200.0 in
  fun () ->
    clock := !clock +. 1.0;
    !clock
;;

type fixture =
  { writers : Writers.t
  ; registered : string list ref
  ; memory_dir : string
  ; place : string -> Machine.place
  }

(* [keepers] are registered. Each has a turn log unless it is named in
   [without_turn_log]. *)
let fixture ?(without_turn_log = []) ~sw keepers =
  let memory_dir = Filename.temp_dir "memory" "" in
  let turns_dir = Filename.temp_dir "turns" "" in
  let place keeper_id : Machine.place = { memory_dir; turns_dir; keeper_id } in
  List.iter
    (fun keeper -> if not (List.mem keeper without_turn_log) then start_turn_log (place keeper))
    keepers;
  let registered = ref keepers in
  { writers =
      Writers.create ~sw ~now:(ticking ())
        ~registered:(fun keeper -> List.mem keeper !registered)
        ~place
        ~stores:(fun keeper -> Masc_test_deps.stores_of_place (place keeper))
        ~ask:Masc_test_deps.never_asks ~ask_room:Masc_test_deps.never_makes_room
        ~start_turn_log:(fun (_ : string) -> Ok ())
  ; registered
  ; memory_dir
  ; place
  }
;;

let with_switch body = Eio_main.run (fun (_ : Eio_unix.Stdenv.base) -> Eio.Switch.run body)

let stop_text : Store.stop -> string = function
  | Log_diverged _ -> "diverged"
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
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

let status_text : Writer.status -> string = function
  | Booting -> "booting"
  | Open (Started _) -> "open at its start"
  | Open (Committed { seq; _ }) -> Printf.sprintf "open at commit %d" seq
  | Stopped stop -> "stopped: " ^ stop_text stop
  | Retired -> "retired"
;;

let statuses f =
  List.map (fun (keeper, status) -> keeper ^ ": " ^ status_text status) (Writers.statuses f.writers)
;;

(* What each writer holds, by the state of its machine (§12). *)
let held f =
  List.map
    (fun (keeper, (held : Writer.held)) ->
       keeper
       ^ ": "
       ^
       match held with
       | Held_booting -> "booting"
       | Held { state = Idle _; _ } -> "idle"
       | Held { state = Asking _; _ } -> "asking"
       | Held { state = Resting _; _ } -> "resting"
       | Held { state = Refused_at_bottom _; _ } -> "refused at the bottom"
       | Held { state = Stopped stop; _ } -> "stopped: " ^ stop_text stop
       | Held_retired -> "retired")
    (Writers.held f.writers)
;;

let view_text f keeper =
  match Writers.view f.writers keeper with
  | Error `Booting -> "booting"
  | Error (`Stopped stop) -> "stopped: " ^ stop_text stop
  | Error `No_writer -> "no writer"
  | Ok view ->
    Printf.sprintf "%s, from message %d"
      (match view.covers_through with
       | Before_first -> "nothing read"
       | Through _ -> "read")
      view.covered.closed_messages
;;

let remember claim =
  Direct.Remember
    { claim; category = Types.Constraint; basis = Types.Observed Types.Transcript }
;;

let write f keeper claim =
  write_text (Writers.write f.writers keeper ~by:Effects.Keeper ~trace:"turn" (remember claim))
;;

let port = "the port is 8935"
let owner = "the owner is the release team"
let probe = "the probe runs every minute"

let test_first_answer_is_booting () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    check (list string) "no writer before anyone asks" [] (statuses f);
    check string "the first reading makes the writer and does not wait for it" "booting"
      (view_text f "keeper-a");
    check (list string) "the table holds it" [ "keeper-a: booting" ] (statuses f);
    check string "a write waits for the boot" "written as commit 1" (write f "keeper-a" port);
    check string "the view is the line that write committed" "nothing read, from message 4"
      (view_text f "keeper-a"))
;;

let test_unregistered_keeper_has_no_writer () =
  with_switch (fun sw ->
    let f = fixture ~sw [] in
    (* It has a turn log: the writer is missing because of the registry. *)
    start_turn_log (f.place "keeper-a");
    check string "its view" "no writer" (view_text f "keeper-a");
    check string "a write" "the keeper is retired" (write f "keeper-a" port);
    check string "a resume" "the keeper is retired"
      (act_text (Writers.resume f.writers "keeper-a"));
    check string "an adoption" "the keeper is retired"
      (act_text
         (Writers.adopt f.writers "keeper-a" ~by:"operator-1"
            ~observed:(Digest.digest_of_bytes "anything")));
    check (list string) "no writer was made" [] (statuses f);
    check int "and no file of its Memory" 0 (Array.length (Sys.readdir f.memory_dir)))
;;

(* A second writer for the same Keeper would not get the lock, and its write
   would be refused as unwritable. *)
let test_one_writer_per_keeper () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a"; "keeper-b" ] in
    let first, second =
      Eio.Fiber.pair (fun () -> write f "keeper-a" port) (fun () -> write f "keeper-a" owner)
    in
    check string "the write that asked first" "written as commit 1" first;
    check string "the write that asked while the writer was booting" "written as commit 2" second;
    check string "another Keeper has its own writer and log" "written as commit 1"
      (write f "keeper-b" port);
    check (list string) "one writer each"
      [ "keeper-a: open at commit 2"; "keeper-b: open at commit 1" ]
      (statuses f))
;;

let test_stopped_and_resumed () =
  with_switch (fun sw ->
    let f = fixture ~without_turn_log:[ "keeper-a" ] ~sw [ "keeper-a" ] in
    check string "a Keeper without a turn log" "the store is stopped: store unwritable"
      (write f "keeper-a" port);
    check string "its view says why" "stopped: store unwritable" (view_text f "keeper-a");
    check (list string) "and what it holds is the stopped machine"
      [ "keeper-a: stopped: store unwritable" ] (held f);
    start_turn_log (f.place "keeper-a");
    check string "a resume" "done" (act_text (Writers.resume f.writers "keeper-a"));
    check string "opens it" "nothing read, from message 4" (view_text f "keeper-a");
    check (list string) "and it holds the open one" [ "keeper-a: idle" ] (held f);
    check string "an open store has nothing to resume" "nothing to resume"
      (act_text (Writers.resume f.writers "keeper-a")))
;;

let test_off_and_on_again () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    check string "while registered" "written as commit 1" (write f "keeper-a" port);
    f.registered := [];
    Writers.pulse f.writers [];
    check (list string) "the pulse retires the writer of a Keeper that is gone" [] (statuses f);
    check string "its Memory takes no write" "the keeper is retired" (write f "keeper-a" owner);
    check string "and has no view" "no writer" (view_text f "keeper-a");
    f.registered := [ "keeper-a" ];
    check string "registered again, its write is not refused" "written as commit 2"
      (write f "keeper-a" owner);
    check (list string) "by a new writer that read the log the first one left"
      [ "keeper-a: open at commit 2" ]
      (statuses f))
;;

let test_retire_before_the_files_go () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a" ] in
    let retire () = retirement_text (Writers.retire f.writers "keeper-a") in
    check string "a Keeper that has no writer" "retired" (retire ());
    check string "its first write" "written as commit 1" (write f "keeper-a" port);
    check string "a registered Keeper's writer is not retired" "still registered" (retire ());
    check string "and goes on" "written as commit 2" (write f "keeper-a" owner);
    f.registered := [];
    check string "out of the registry, it is" "retired" (retire ());
    check (list string) "and leaves the table" [] (statuses f);
    (* Nothing holds the files: a writer outside the table takes the lock. *)
    let bare =
      Writer.create ~now:(ticking ()) ~registered:(fun () -> true) ~declared:(fun () -> None)
        ~stores:(Masc_test_deps.stores_of_place (f.place "keeper-a")) ~ask:Masc_test_deps.never_asks ~ask_room:Masc_test_deps.never_makes_room
        ~start_turn_log:(fun () -> Ok ())
        (f.place "keeper-a")
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Writer.run bare;
      `Stop_daemon);
    check string "the lock is free" "written as commit 3"
      (match Writer.write bare ~by:Effects.Keeper ~trace:"turn" (remember probe) with
       | Answered answer -> write_text answer
       | Ended -> "the writer ended"))
;;

let test_pulse_gives_every_registered_keeper_its_writer () =
  with_switch (fun sw ->
    let f = fixture ~sw [ "keeper-a"; "keeper-b" ] in
    Writers.pulse f.writers [ "keeper-a"; "keeper-b"; "keeper-c" ];
    check (list string) "before anyone asks, and none for the one that is not registered"
      [ "keeper-a: booting"; "keeper-b: booting" ]
      (statuses f);
    check string "the writer the pulse made takes the write" "written as commit 1"
      (write f "keeper-a" port))
;;

let () =
  run "librarian_writers"
    [ ( "a registered Keeper"
      , [ test_case "the first answer is booting" `Quick test_first_answer_is_booting
        ; test_case "has one writer" `Quick test_one_writer_per_keeper
        ; test_case "stopped and resumed" `Quick test_stopped_and_resumed
        ] )
    ; ( "the registry"
      , [ test_case "a Keeper that is not registered has no writer" `Quick
            test_unregistered_keeper_has_no_writer
        ; test_case "off and on again" `Quick test_off_and_on_again
        ; test_case "retire before the files go" `Quick test_retire_before_the_files_go
        ; test_case "the pulse" `Quick test_pulse_gives_every_registered_keeper_its_writer
        ] )
    ]
;;
