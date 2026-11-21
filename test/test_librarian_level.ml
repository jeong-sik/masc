(* Each alarm of a Keeper's writer, and the level the alarms give (RFC
   librarian-call-only-proposes §12.2). The writer's value is made here over
   one opened store, so each case names the state and the last asks the
   alarm reads, and nothing else. *)

open Alcotest
module Level = Masc.Librarian_level
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log = Masc.Librarian_log
module Lane = Masc.Librarian_memory_lane
module Last = Masc.Librarian_last
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Registry = Runtime_exact_output_registry
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

(* A store opened on a turn log that has started and holds nothing else. *)
let store =
  lazy
    (let place : Machine.place =
       { memory_dir = Filename.temp_dir "memory" ""
       ; turns_dir = Filename.temp_dir "turns" ""
       ; keeper_id
       }
     in
     let path = Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id in
     (match
        Turn_store.append ~path ~at_end:0
          (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
      with
      | Ok (_ : Turn_store.appended) -> ()
      | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written");
     match Machine.boot place ~at:100.0 with
     | Ok store -> store
     | Error (_ : Store.stop) -> fail "the store of the fixture did not open")
;;

let now () = Log.snapshot_after (Store.tail (Lazy.force store))
let another_snapshot = Digest.digest_of_bytes "another snapshot"

let declared ?(prompt = "memory prompt") () : Machine.declared =
  { value =
      { question =
          { prompt
          ; answer_schemas =
              { Lane.range = `Assoc [ "type", `String "object" ]
              ; item_alone = `Assoc [ "type", `String "object" ]
              ; room = `Assoc [ "type", `String "object" ]
              }
          ; max_output_tokens = 4096
          ; thinking = None
          }
      ; http = []
      ; cli =
          [ { id = "claude_code.fast"
            ; target = Cli { runtime_id = "claude_code.fast"; api_name = "claude-sonnet-5" }
            ; window = 200_000
            }
          ]
      ; unadmitted = []
      }
  ; resolved = { Registry.selected_slots = []; cli_slots = [] }
  }
;;

let machine ?(lane = Some (declared ())) ?last_read ?last_room ?(read_alone = false) state
  : Machine.t
  =
  { state
  ; lane
  ; last_ask = 1
  ; narrowing = Masc.Librarian_width.empty
  ; bottom = Masc.Librarian_bottom.empty
  ; last_read
  ; last_room
  ; read_alone
  }
;;

let resting () = Machine.Resting (Lazy.force store)
let idle () = Machine.Idle { store = Lazy.force store; seen_length = None }

(* A reading ask that is out. The one a pulse starts from a rest asks for
   the unread range, with Memory. *)
let asking ?(asked = Masc.Librarian_read_result.Read_range Masc.Librarian_width.All) () =
  Machine.Asking
    { store = Lazy.force store
    ; asking =
        { Machine.ask = 1
        ; since = 100.0
        ; lane = declared ()
        ; removed_since = []
        ; asked = Machine.Read asked
        ; bottom = Masc.Librarian_bottom.empty
        }
    }
;;

let one_item ?(silent = false) basis =
  Last.Lane { one_item = true; silent; basis; slots = [] }
;;

(* The one-item refusal E4 reads: every slot of [lane] refused, not every
   one with a size. *)
let not_all_sized ?(lane = (declared ()).value) basis =
  Last.Refused_not_all_sized { basis; lane; slots = [] }
;;

let alarm_text : Level.alarm -> string = function
  | E1 -> "E1"
  | E2 -> "E2"
  | E3 -> "E3"
  | E4 -> "E4"
  | E5 -> "E5"
  | W1 -> "W1"
  | W2 -> "W2"
  | W3 -> "W3"
;;

let level_text : Level.level -> string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Error -> "error"
;;

let check_alarms label expected writer =
  check (list string) label expected (List.map alarm_text (Level.alarms writer))
;;

let running ?(unread = true) ?(request_behind = false) value =
  Level.Running { machine = value; unread; request_behind }
;;

let test_e1_a_stopped_store () =
  check_alarms "a stopped store" [ "E1" ] (running ~unread:false (machine (Stopped Store_unwritable)))
;;

(* At the bottom the last read is the lane's, so W1 is on beside E2. *)
let test_e2_refused_at_the_bottom () =
  check_alarms "refused at the bottom" [ "E2"; "W1" ]
    (running
       (machine ~last_read:(one_item (now ())) (Refused_at_bottom (Lazy.force store))))
;;

let test_e3_a_fault_with_something_unread () =
  let fault : Last.read = Input_fault (Line_unreadable { offset = 0 }) in
  check_alarms "an input fault" [ "E3" ] (running (machine ~last_read:fault (resting ())));
  check_alarms "a failed ask" [ "E3" ]
    (running (machine ~last_read:(Ask_failed Flow_stopped) (resting ())));
  check_alarms "nothing unread" [] (running ~unread:false (machine ~last_read:fault (idle ())))
;;

(* E4 stands on the refusal the last ask left, while something is unread and
   the refusal is about the snapshot and the lane value held now. The
   writer's state is not read, so the ask a pulse starts from the rest
   leaves it on. A write since, another lane value and every other one-item
   end leave only W1 ([E4Rule = "held_now"]). *)
let test_e4_a_refusal_about_the_snapshot_and_the_lane_now () =
  let refusal = not_all_sized (now ()) in
  check_alarms "every slot refused it, not every one with a size" [ "E4"; "W1" ]
    (running (machine ~last_read:refusal (resting ())));
  check_alarms "the next pulse is asking it again" [ "E4"; "W1" ]
    (running (machine ~last_read:refusal (asking ())));
  check_alarms "nothing unread" []
    (running ~unread:false (machine ~last_read:refusal (resting ())));
  check_alarms "Memory changed since" [ "W1" ]
    (running (machine ~last_read:(not_all_sized another_snapshot) (asking ())));
  check_alarms "the lane value changed since" [ "W1" ]
    (running
       (machine
          ~last_read:(not_all_sized ~lane:(declared ~prompt:"another prompt" ()).value (now ()))
          (asking ())));
  check_alarms "no lane value" [ "W1" ] (running (machine ~lane:None ~last_read:refusal (idle ())));
  check_alarms "every slot sized it for its input: the item is asked alone" [ "W1" ]
    (running
       (machine ~last_read:(one_item (now ()))
          (asking ~asked:Masc.Librarian_read_result.Read_item_alone ())));
  check_alarms "the item alone was skipped for its size: the next one is asked" [ "W1" ]
    (running (machine ~last_read:(one_item (now ())) (asking ())));
  check_alarms "a slot was silent" [ "W1" ]
    (running (machine ~last_read:(one_item ~silent:true (now ())) (resting ())));
  check_alarms "a wider question" [ "W1" ]
    (running
       (machine
          ~last_read:(Lane { one_item = false; silent = false; basis = now (); slots = [] })
          (resting ())))
;;

(* E5 stands only on the Memory and the lane value held now. A room is asked
   only after an item read alone, so W3 is on beside it. *)
let test_e5_a_room_that_fits_no_slot_now () =
  let fits_none ?(memory = now ()) ?(lane = (declared ()).value) () =
    machine ~last_read:Committed ~last_room:(Fits_none { memory; lane }) ~read_alone:true (idle ())
  in
  check_alarms "about Memory now" [ "E5"; "W3" ] (running ~unread:false (fits_none ()));
  check_alarms "Memory changed since" [ "W3" ]
    (running ~unread:false (fits_none ~memory:another_snapshot ()));
  check_alarms "the lane value changed since" [ "W3" ]
    (running ~unread:false (fits_none ~lane:(declared ~prompt:"another prompt" ()).value ()))
;;

let test_w1_booting_and_an_unread_turn_not_judged () =
  check_alarms "booting" [ "W1" ] Booting;
  check_alarms "no lane value" [ "W1" ] (running (machine ~lane:None ~last_read:Committed (idle ())));
  check_alarms "no ask ended since the boot" [ "W1" ] (running (machine (idle ())));
  check_alarms "a read committed" [] (running (machine ~last_read:Committed (idle ())))
;;

(* W2 is the caller's to read (§11.3): on exactly when it says the latest
   request starts past the read end, and before W3 in the order of the alarms. *)
let test_w2_a_request_past_the_read_end () =
  check_alarms "a request past the read end" [ "W2"; "W3" ]
    (running ~unread:false ~request_behind:true
       (machine ~last_read:Committed ~read_alone:true (idle ())))
;;

let test_w3_an_item_read_alone () =
  check_alarms "read alone" [ "W3" ]
    (running ~unread:false (machine ~last_read:Committed ~read_alone:true (idle ())))
;;

let test_a_retired_writer_has_no_alarm () = check_alarms "retired" [] Retired

let test_the_level () =
  let level alarms = level_text (Level.level alarms) in
  check string "no alarm" "ok" (level []);
  check string "only warnings" "warn" (level [ W1; W2; W3 ]);
  List.iter
    (fun alarm ->
       check string (alarm_text alarm ^ " beside a warning") "error" (level [ alarm; W1 ]))
    [ Level.E1; E2; E3; E4; E5 ]
;;

let () =
  run "librarian_level"
    [ ( "alarms"
      , [ test_case "E1, a stopped store" `Quick test_e1_a_stopped_store
        ; test_case "E2, refused at the bottom" `Quick test_e2_refused_at_the_bottom
        ; test_case "E3, a fault with something unread" `Quick
            test_e3_a_fault_with_something_unread
        ; test_case "E4, a refusal about the snapshot and the lane now" `Quick
            test_e4_a_refusal_about_the_snapshot_and_the_lane_now
        ; test_case "E5, a room that fits no slot now" `Quick test_e5_a_room_that_fits_no_slot_now
        ; test_case "W1, booting and an unread turn not judged" `Quick
            test_w1_booting_and_an_unread_turn_not_judged
        ; test_case "W2, a request past the read end" `Quick test_w2_a_request_past_the_read_end
        ; test_case "W3, an item read alone" `Quick test_w3_an_item_read_alone
        ; test_case "a retired writer has none" `Quick test_a_retired_writer_has_no_alarm
        ] )
    ; "level", [ test_case "of the alarms" `Quick test_the_level ]
    ]
;;
