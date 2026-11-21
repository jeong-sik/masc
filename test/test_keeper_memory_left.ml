(* The facts keeper_memory_search shows for source=absorbed and
   source=dropped, read from a Keeper's commit log
   (RFC librarian-call-only-proposes §11.5). The store writes the log of
   every case through the writes a Keeper makes. One case appends a line an
   answer would commit, since a merge comes only from an answer. *)

open Alcotest
module Left = Masc.Keeper_memory_left
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log = Masc.Librarian_log
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

let booted place =
  Machine.booted place ~at:100.0 ~lane:None ~last_ask:0 (Machine.boot place ~at:100.0)
;;

let memory (value : Machine.t) =
  match value.state with
  | Idle { store; seen_length = (_ : int option) } -> (Store.memory store).facts
  | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ ->
    fail "the store of the fixture is not idle"
;;

(* A write that has to commit a line, with the line it committed. *)
let write place state ~at w =
  match Machine.write place state ~at ~by:Effects.Keeper ~trace:"turn" w with
  | state, Written commit -> state, commit
  | ( (_ : Machine.t)
    , (Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _)
    ) -> fail "the write of the fixture was not committed"
;;

let id = Types.memory_id_of_claim
let transcript = Types.Observed Types.Transcript
let remember claim = Direct.Remember { claim; category = Types.Constraint; basis = transcript }

let supersede ~old claim =
  Direct.Supersede { old = id old; claim; category = Types.Constraint; basis = transcript }
;;

let retract claim reason = Direct.Retract { id = id claim; reason }

let read place ~current =
  match Left.read ~keepers_dir:place.Machine.memory_dir ~keeper_id ~current with
  | Ok left -> left
  | Error detail -> fail detail
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let how_text : Left.how -> string = function
  | Merged -> "merged"
  | Revised -> "revised"
  | Superseded -> "superseded"
;;

(* Ids are hashes of claims, so a case names them by their claims. *)
let absorbed_text ~claims (absorbed : Left.absorbed) =
  let claim_of memory_id =
    match List.find_opt (fun claim -> String.equal (id claim) memory_id) claims with
    | Some claim -> claim
    | None -> memory_id
  in
  Printf.sprintf
    "%s: %s into %s%s"
    absorbed.left.fact.claim
    (how_text absorbed.how)
    (claim_of absorbed.into)
    (if absorbed.into_current then ", current" else "")
;;

let why_text : Left.why -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
  | Molted { reason } -> "molted: " ^ reason
;;

let dropped_text (dropped : Left.dropped) = dropped.left.fact.claim ^ ": " ^ why_text dropped.why

let window_mon = "the window is monday"
let window_tue = "the window is tuesday"
let window_wed = "the window is wednesday"

let test_a_superseded_fact_reaches_the_claim_current_now () =
  let place = started_place () in
  let state = booted place in
  let state, (_ : Log.commit) = write place state ~at:201.0 (remember window_mon) in
  let state, (_ : Log.commit) = write place state ~at:202.0 (supersede ~old:window_mon window_tue) in
  let state, (_ : Log.commit) = write place state ~at:203.0 (supersede ~old:window_tue window_wed) in
  let left = read place ~current:(memory state) in
  let claims = [ window_mon; window_tue; window_wed ] in
  check
    (list string)
    "each fact that left names where it went, followed to the current claim"
    [ window_mon ^ ": superseded into " ^ window_wed ^ ", current"
    ; window_tue ^ ": superseded into " ^ window_wed ^ ", current"
    ]
    (List.map (absorbed_text ~claims) left.absorbed);
  check (list string) "nothing left with nothing in its place" [] (List.map dropped_text left.dropped);
  check int "every line decodes" 0 left.unreadable;
  match left.absorbed with
  | first :: _ ->
    check (float 0.0) "when the line that removed it was committed" 202.0 first.left.at
  | [] -> fail "no absorbed fact"
;;

let port = "the port is 8935"
let rests = "requests go to 8935"

let test_a_retracted_fact_ends_the_walk () =
  let place = started_place () in
  let state = booted place in
  let state, (_ : Log.commit) = write place state ~at:201.0 (remember window_mon) in
  let state, (_ : Log.commit) = write place state ~at:202.0 (supersede ~old:window_mon window_tue) in
  let state, (_ : Log.commit) = write place state ~at:203.0 (remember port) in
  let state, (_ : Log.commit) =
    write place state ~at:204.0
      (Direct.Remember
         { claim = rests
         ; category = Types.Lesson
         ; basis = Types.Derived [ { rule_id = "rule"; premise_ids = [ id port ] } ]
         })
  in
  let state, (_ : Log.commit) = write place state ~at:205.0 (retract window_tue "the window closed") in
  let state, (_ : Log.commit) = write place state ~at:206.0 (retract port "the port moved") in
  let left = read place ~current:(memory state) in
  let claims = [ window_mon; window_tue ] in
  check
    (list string)
    "the walk stops at a fact that left with nothing in its place"
    [ window_mon ^ ": superseded into " ^ window_tue ]
    (List.map (absorbed_text ~claims) left.absorbed);
  check
    (list string)
    "a retracted fact and the derived fact that lost its premise left with nothing in their place"
    [ window_tue ^ ": retracted by the keeper: the window closed"
    ; port ^ ": retracted by the keeper: the port moved"
    ; rests ^ ": support lost: " ^ id port
    ]
    (List.map dropped_text left.dropped)
;;

let alpha = "alpha deploys on monday"
let beta = "beta deploys on monday"
let gamma = "gamma is deprecated"

(* An answer can merge two facts into each other's ids across one line. The
   walk does not come back to a fact it passed. *)
let test_a_merge_loop_stops_before_a_fact_it_passed () =
  let place = started_place () in
  let state = booted place in
  let state, (_ : Log.commit) = write place state ~at:201.0 (remember alpha) in
  let state, (_ : Log.commit) = write place state ~at:202.0 (remember beta) in
  let state, last = write place state ~at:203.0 (remember gamma) in
  let fact_of claim =
    match List.find_opt (fun (fact : Types.fact) -> String.equal fact.claim claim) (memory state) with
    | Some fact -> fact
    | None -> fail ("the fixture does not hold " ^ claim)
  in
  let line =
    Log.Committed
      { last with
        seq = last.seq + 1
      ; at = 204.0
      ; effects =
          { Effects.empty with
            removed =
              [ fact_of alpha, Effects.Merged_into (id beta)
              ; fact_of beta, Effects.Revised_into (id alpha)
              ; fact_of gamma, Effects.Dropped { reason = "nothing uses it" }
              ]
          }
      }
  in
  let path = log_path place in
  (match Log_store.append ~path ~at_end:(Unix.stat path).st_size line with
   | Ok (_ : Log_store.appended) -> ()
   | Error (_ : Log_store.append_error) -> fail "the answer line of the fixture was not written");
  let left = read place ~current:[] in
  let claims = [ alpha; beta ] in
  check
    (list string)
    "each stops at the other, not at itself"
    [ alpha ^ ": merged into " ^ beta; beta ^ ": revised into " ^ alpha ]
    (List.map (absorbed_text ~claims) left.absorbed);
  check
    (list string)
    "a fact an answer dropped"
    [ gamma ^ ": dropped: nothing uses it" ]
    (List.map dropped_text left.dropped)
;;

let test_no_log_is_no_fact () =
  let place = started_place () in
  let left = read place ~current:[] in
  check (pair int int) "nothing left" (0, 0) (List.length left.absorbed, List.length left.dropped);
  check int "and no line to count" 0 left.unreadable
;;

let test_lines_that_do_not_decode_are_counted () =
  let place = started_place () in
  let state = booted place in
  let state, (_ : Log.commit) = write place state ~at:201.0 (remember port) in
  let state, (_ : Log.commit) = write place state ~at:202.0 (retract port "the port moved") in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 (log_path place)
    (fun channel -> Out_channel.output_string channel "not json\n");
  let left = read place ~current:(memory state) in
  check
    (list string)
    "the rest is read"
    [ port ^ ": retracted by the keeper: the port moved" ]
    (List.map dropped_text left.dropped);
  check int "and the count says one line is not known" 1 left.unreadable
;;

let member key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> fail ("no field " ^ key))
  | _ -> fail "not an object"
;;

let test_the_search_rows () =
  let place = started_place () in
  let state = booted place in
  let state, (_ : Log.commit) = write place state ~at:201.0 (remember window_mon) in
  let state, (_ : Log.commit) = write place state ~at:202.0 (supersede ~old:window_mon window_tue) in
  let state, (_ : Log.commit) = write place state ~at:203.0 (remember port) in
  let state, (_ : Log.commit) =
    write place state ~at:204.0
      (Direct.Remember
         { claim = rests
         ; category = Types.Lesson
         ; basis = Types.Derived [ { rule_id = "rule"; premise_ids = [ id port ] } ]
         })
  in
  let state, (_ : Log.commit) = write place state ~at:205.0 (retract port "the port moved") in
  let left = read place ~current:(memory state) in
  (match left.absorbed with
   | [ absorbed ] ->
     let row = Left.absorbed_to_json absorbed in
     check string "store" "absorbed_memory" (Yojson.Safe.Util.to_string (member "store" row));
     check string "how" "superseded" (Yojson.Safe.Util.to_string (member "how" row));
     check string "into" (id window_tue) (Yojson.Safe.Util.to_string (member "into" row));
     check bool "into_current" true (Yojson.Safe.Util.to_bool (member "into_current" row));
     check string "memory_id" (id window_mon) (Yojson.Safe.Util.to_string (member "memory_id" row));
     check string "basis as Memory held it"
       (Yojson.Safe.to_string (Types.basis_to_json transcript))
       (Yojson.Safe.to_string (member "basis" row))
   | _ -> fail "expected one absorbed fact");
  match left.dropped with
  | [ retracted; lost ] ->
    let retracted = Left.dropped_to_json retracted in
    check string "store" "dropped_memory" (Yojson.Safe.Util.to_string (member "store" retracted));
    check bool "not current" false (Yojson.Safe.Util.to_bool (member "current" retracted));
    check string "removal" "retracted" (Yojson.Safe.Util.to_string (member "removal" retracted));
    check string "removed_by" "keeper" (Yojson.Safe.Util.to_string (member "removed_by" retracted));
    check string "reason" "the port moved" (Yojson.Safe.Util.to_string (member "reason" retracted));
    let lost = Left.dropped_to_json lost in
    check string "removal" "support_lost" (Yojson.Safe.Util.to_string (member "removal" lost));
    check
      (list string)
      "missing_premises"
      [ id port ]
      (Yojson.Safe.Util.convert_each Yojson.Safe.Util.to_string (member "missing_premises" lost))
  | _ -> fail "expected two dropped facts"
;;

let () =
  run "keeper_memory_left"
    [ ( "left"
      , [ test_case "a superseded fact reaches the claim current now" `Quick
            test_a_superseded_fact_reaches_the_claim_current_now
        ; test_case "a retracted fact ends the walk" `Quick test_a_retracted_fact_ends_the_walk
        ; test_case "a merge loop stops before a fact it passed" `Quick
            test_a_merge_loop_stops_before_a_fact_it_passed
        ; test_case "no log is no fact" `Quick test_no_log_is_no_fact
        ; test_case "lines that do not decode" `Quick test_lines_that_do_not_decode_are_counted
        ; test_case "the search rows" `Quick test_the_search_rows
        ] )
    ]
;;
