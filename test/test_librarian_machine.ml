(* What one event does to a Keeper's writer (RFC librarian-call-only-proposes
   §9.3): a direct write and an operator's act, in each state the writer has
   before it asks a model. *)

open Alcotest
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log = Masc.Librarian_log
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Envelope = Masc.Librarian_envelope
module Snapshot_codec = Masc.Keeper_memory_os_snapshot_codec
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

(* A place whose Keeper has a turn log and nothing else. *)
let started_place () =
  let place = new_place () in
  (match
     Turn_store.append
       ~path:(Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id)
       ~at_end:0
       (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
   with
   | Ok (_ : Turn_store.appended) -> ()
   | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written");
  place
;;

let snapshot_path (place : Machine.place) =
  Masc.Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:place.memory_dir
    ~keeper_id
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let file_bytes path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let hex (digest : Digest.digest) = (digest :> string)

let stop_text : Store.stop -> string = function
  | Log_diverged { expected; observed } ->
    Printf.sprintf "diverged: the log names %s and the file is %s" (hex expected) (hex observed)
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
;;

let state_text : Machine.state -> string = function
  | Idle store ->
    "idle, holding: "
    ^ String.concat "; "
        (List.map (fun (fact : Types.fact) -> fact.claim) (Store.memory store).facts)
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

let transcript = Types.Observed Types.Transcript
let remember ?(category = Types.Constraint) claim = Direct.Remember { claim; category; basis = transcript }

let write ?(trace = "turn") state ~at w =
  Machine.write state ~at ~by:Effects.Keeper ~trace w
;;

let resume place state ~at = Machine.resume ~boot:(fun () -> Machine.boot place ~at) state

let port = "the port is 8935"
let owner = "the owner is the release team"

(* An open store that holds [port]. *)
let holding_port () =
  let place = started_place () in
  let state, answer = write (Machine.boot place ~at:100.0) ~at:201.0 (remember port) in
  check string "the fixture's write" "written as commit 1" (write_text answer);
  place, state
;;

(* The same store after its snapshot was replaced from outside. The first
   write finds it and stops the store. *)
let diverged () =
  let place, state = holding_port () in
  let named = Digest.digest_of_bytes (file_bytes (snapshot_path place)) in
  let other = Snapshot_codec.snapshot_bytes (Envelope.empty ~at:999.0 ~turn_log) in
  write_file (snapshot_path place) other;
  let stop : Store.stop =
    Log_diverged { expected = named; observed = Digest.digest_of_bytes other }
  in
  let state, answer = write state ~at:202.0 (remember owner) in
  check string "the write that finds the other snapshot"
    ("the store is stopped: " ^ stop_text stop)
    (write_text answer);
  check string "stops the store" ("stopped: " ^ stop_text stop) (state_text state);
  place, state, stop, other
;;

let test_boot () =
  check string "a Keeper with a turn log" "idle, holding: "
    (state_text (Machine.boot (started_place ()) ~at:100.0));
  check string "a Keeper without one" "stopped: store unwritable"
    (state_text (Machine.boot (new_place ()) ~at:100.0))
;;

let test_write_when_idle () =
  let place, state = holding_port () in
  check string "the store holds the claim" ("idle, holding: " ^ port) (state_text state);
  let state, again = write state ~at:202.0 (remember port) in
  check string "the same claim again moves its last_seen, so it is a commit"
    "written as commit 2" (write_text again);
  let log = file_bytes (log_path place) in
  let unchanged label w expected =
    let next, answer = write state ~at:203.0 w in
    check string label expected (write_text answer);
    check string (label ^ ": the state is as it was") (state_text state) (state_text next);
    check string (label ^ ": no line is written") log (file_bytes (log_path place))
  in
  unchanged "the claim said another way" (remember ~category:Types.Lesson port) "already held";
  unchanged "a fact that is not held"
    (Direct.Retract { id = Types.memory_id_of_claim "never written"; reason = "wrong" })
    "already absent";
  unchanged "a claim that replaces a fact that is not held"
    (Direct.Supersede
       { old = Types.memory_id_of_claim "never written"
       ; claim = "the port is 9000"
       ; category = Types.Constraint
       ; basis = transcript
       })
    "refused: unknown_fact";
  let next, answer = write ~trace:" " state ~at:203.0 (remember owner) in
  check string "a write on no trace" "refused: blank_trace" (write_text answer);
  check string "leaves the state" (state_text state) (state_text next)
;;

let test_write_when_stopped () =
  let place, state, stop, (_ : string) = diverged () in
  let log = file_bytes (log_path place) in
  let next, answer = write state ~at:203.0 (remember owner) in
  check string "a write to a stopped store"
    ("the store is stopped: " ^ stop_text stop)
    (write_text answer);
  check string "leaves it stopped" (state_text state) (state_text next);
  check string "and writes no line" log (file_bytes (log_path place))
;;

let test_resume () =
  let place, idle = holding_port () in
  let held = file_bytes (snapshot_path place) in
  let same, answer = resume place idle ~at:300.0 in
  check string "a store that is open" "nothing to resume" (act_text answer);
  check string "stays as it was" (state_text idle) (state_text same);
  let other = Snapshot_codec.snapshot_bytes (Envelope.empty ~at:999.0 ~turn_log) in
  write_file (snapshot_path place) other;
  let stopped, (_ : Machine.write_answer) = write idle ~at:202.0 (remember owner) in
  let still, answer = resume place stopped ~at:300.0 in
  check string "the boot ran" "done" (act_text answer);
  check string "and stopped the same way" (state_text stopped) (state_text still);
  write_file (snapshot_path place) held;
  let opened, answer = resume place still ~at:301.0 in
  check string "the boot ran again" "done" (act_text answer);
  check string "with the snapshot back, the store opens" ("idle, holding: " ^ port)
    (state_text opened)
;;

let test_adopt () =
  let place, stopped, (_ : Store.stop), other = diverged () in
  let log = file_bytes (log_path place) in
  let adopt state observed = Machine.adopt place state ~at:400.0 ~by:"operator-1" ~observed in
  let refused, answer = adopt stopped (Digest.digest_of_bytes "another snapshot") in
  check string "bytes the file does not hold" "snapshot mismatch" (act_text answer);
  check string "leave the store stopped" (state_text stopped) (state_text refused);
  check string "and the log as it was" log (file_bytes (log_path place));
  let opened, answer = adopt stopped (Digest.digest_of_bytes other) in
  check string "the bytes the file holds" "done" (act_text answer);
  check string "open the store with them" "idle, holding: " (state_text opened);
  let again, answer = adopt opened (Digest.digest_of_bytes other) in
  check string "a store that is open" "not stopped" (act_text answer);
  check string "stays as it was" (state_text opened) (state_text again);
  let state, answer = write opened ~at:401.0 (remember owner) in
  check string "the next write follows the adoption" "written as commit 3" (write_text answer);
  check string "and is held" ("idle, holding: " ^ owner) (state_text state)
;;

let test_adopt_is_not_the_way_out_of_every_stop () =
  let place, (_ : Machine.state) = holding_port () in
  Sys.remove (snapshot_path place);
  let stopped = Machine.boot place ~at:300.0 in
  check string "a store without its snapshot" "stopped: memory unreadable" (state_text stopped);
  let same, answer =
    Machine.adopt place stopped ~at:400.0 ~by:"operator-1"
      ~observed:(Digest.digest_of_bytes "anything")
  in
  check string "is not adopted" "the store is stopped: memory unreadable" (act_text answer);
  check string "and stays stopped" (state_text stopped) (state_text same)
;;

let test_retired () =
  let place = started_place () in
  let retired = Machine.Retired in
  let state, answer = write retired ~at:201.0 (remember port) in
  check string "a write" "the keeper is retired" (write_text answer);
  check string "leaves it retired" "retired" (state_text state);
  check string "a resume" "the keeper is retired"
    (act_text (snd (resume place retired ~at:300.0)));
  check string "an adoption" "the keeper is retired"
    (act_text
       (snd
          (Machine.adopt place retired ~at:400.0 ~by:"operator-1"
             ~observed:(Digest.digest_of_bytes "anything"))));
  check bool "nothing was written for it" false (Sys.file_exists (log_path place))
;;

let () =
  run "librarian_machine"
    [ "boot", [ test_case "opens or stops" `Quick test_boot ]
    ; ( "write"
      , [ test_case "when idle" `Quick test_write_when_idle
        ; test_case "when stopped" `Quick test_write_when_stopped
        ] )
    ; ( "operator"
      , [ test_case "resume" `Quick test_resume
        ; test_case "adopt" `Quick test_adopt
        ; test_case "adopt is not the way out of every stop" `Quick
            test_adopt_is_not_the_way_out_of_every_stop
        ] )
    ; "retired", [ test_case "takes nothing" `Quick test_retired ]
    ]
;;
