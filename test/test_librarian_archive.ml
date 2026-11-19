(* The facts that left a Keeper's Memory, read from its commit log
   (RFC librarian-call-only-proposes §11.5). The log of every case is written
   by the store itself, through the writes a Keeper makes. *)

open Alcotest
module Archive = Masc.Librarian_archive
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store

let keeper_id = "keeper-a"

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

(* A place whose Keeper has a turn log and nothing else. *)
let started_place () : Machine.place =
  let place : Machine.place =
    { memory_dir = Filename.temp_dir "memory" ""
    ; turns_dir = Filename.temp_dir "turns" ""
    ; keeper_id
    }
  in
  match
    Turn_store.append
      ~path:(Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> place
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let memory (value : Machine.t) =
  match value.state with
  | Idle { store; seen_length = (_ : int option) } -> (Store.memory store).facts
  | Asking _ | Resting _ | Stopped _ -> fail "the store of the fixture is not idle"
;;

(* A write that has to commit a line. *)
let write state ~at w =
  match Machine.write state ~at ~by:Effects.Keeper ~trace:"turn" w with
  | state, Written (_ : Masc.Librarian_log.commit) -> state
  | ( (_ : Machine.t)
    , (Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _)
    ) -> fail "the write of the fixture was not committed"
;;

let id_of_claim = Types.memory_id_of_claim
let transcript = Types.Observed Types.Transcript
let remember claim = Direct.Remember { claim; category = Types.Constraint; basis = transcript }
let port = "the port is 8935"
let owner = "the owner is the release team"
let new_owner = "the owner is the platform team"
let rests = "requests go to 8935"

let removal_text : Effects.removal -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Merged_into successor -> "merged into " ^ successor
  | Revised_into successor -> "revised into " ^ successor
  | Superseded_by successor -> "superseded by " ^ successor
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
;;

let archive_text place ~current =
  match Archive.read (log_path place) ~current with
  | Error error -> [ Masc.Private_jsonl_scan.error_to_string error ], 0
  | Ok { left; unreadable } ->
    ( List.map
        (fun (left : Archive.left) -> left.fact.claim ^ " -> " ^ removal_text left.removal)
        left
    , unreadable )
;;

(* Three facts, the third derived from the first. Then the first is
   retracted and the second superseded. *)
let after_two_removals place =
  let state =
    Machine.booted place ~at:100.0 ~lane:None ~last_ask:0 (Machine.boot place ~at:100.0)
  in
  let state = write state ~at:201.0 (remember port) in
  let state = write state ~at:202.0 (remember owner) in
  let state =
    write state ~at:203.0
      (Direct.Remember
         { claim = rests
         ; category = Types.Lesson
         ; basis = Types.Derived [ { rule_id = "rule"; premise_ids = [ id_of_claim port ] } ]
         })
  in
  let state =
    write state ~at:204.0 (Direct.Retract { id = id_of_claim port; reason = "the port moved" })
  in
  write state ~at:205.0
    (Direct.Supersede
       { old = id_of_claim owner; claim = new_owner; category = Types.Constraint; basis = transcript })
;;

let all_three =
  [ port ^ " -> retracted by the keeper: the port moved"
  ; rests ^ " -> support lost: " ^ id_of_claim port
  ; owner ^ " -> superseded by " ^ id_of_claim new_owner
  ]
;;

let test_what_left_and_why () =
  let place = started_place () in
  check (pair (list string) int) "no log is no fact" ([], 0) (archive_text place ~current:[]);
  let state = after_two_removals place in
  check (pair (list string) int) "in the order they left, each with what removed it"
    (all_three, 0)
    (archive_text place ~current:(memory state));
  match Archive.read (log_path place) ~current:(memory state) with
  | Ok { left = first :: _; _ } ->
    check (float 0.0) "when the line that removed it was committed" 204.0 first.at;
    check bool "the fact as Memory held it" true (Float.equal first.fact.first_seen 201.0)
  | Ok { left = []; _ } | Error _ -> fail "the first fact that left is not there"
;;

let test_a_fact_added_again_is_not_left () =
  let place = started_place () in
  let state = after_two_removals place in
  let state = write state ~at:206.0 (remember port) in
  check (pair (list string) int) "the port is held again"
    ( [ rests ^ " -> support lost: " ^ id_of_claim port
      ; owner ^ " -> superseded by " ^ id_of_claim new_owner
      ]
    , 0 )
    (archive_text place ~current:(memory state))
;;

(* A snapshot an operator adopted can hold a fact the log last saw leaving. *)
let test_a_fact_the_snapshot_holds_is_not_left () =
  let place = started_place () in
  let state = after_two_removals place in
  let adopted =
    match Archive.read (log_path place) ~current:[] with
    | Ok { left; _ } ->
      List.filter_map
        (fun (left : Archive.left) ->
           if String.equal left.fact.claim owner then Some left.fact else None)
        left
    | Error _ -> fail "the archive of the fixture was not read"
  in
  check int "the fixture found the fact" 1 (List.length adopted);
  check (pair (list string) int) "what Memory holds now has not left"
    ( [ port ^ " -> retracted by the keeper: the port moved"
      ; rests ^ " -> support lost: " ^ id_of_claim port
      ]
    , 0 )
    (archive_text place ~current:(memory state @ adopted))
;;

let test_lines_that_do_not_decode_are_counted () =
  let place = started_place () in
  let state = after_two_removals place in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 (log_path place)
    (fun channel -> Out_channel.output_string channel "not json\n");
  check (pair (list string) int) "the rest is read, and the count says one line is not known"
    (all_three, 1)
    (archive_text place ~current:(memory state))
;;

let () =
  run "librarian_archive"
    [ ( "left"
      , [ test_case "what left and why" `Quick test_what_left_and_why
        ; test_case "a fact added again" `Quick test_a_fact_added_again_is_not_left
        ; test_case "a fact the snapshot holds" `Quick test_a_fact_the_snapshot_holds_is_not_left
        ; test_case "lines that do not decode" `Quick test_lines_that_do_not_decode_are_counted
        ] )
    ]
;;
