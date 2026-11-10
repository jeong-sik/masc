(* Checks for the judgments of the external high-water mark: what the store says
   against what a few records of the log say. The store states are built with
   [Authz_external_store.apply] and the logs are real chains of records. Each
   case names the answers it expects as text, and the naming functions list
   every constructor, so a new one fails to compile until the cases have decided
   what it means for them. Two cases at the end feed the probe from a real file
   through [Authz_log.open_at_start], as the interface says to. *)

open Authz_types
open Authz_records
module R = Authz_record
module S = Authz_external_store
module C = S.Change
module H = Authz_high_water
module L = Authz_log

(* ---- fixtures ---- *)

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let author = Author.Authenticated (Principal.Human (get (User_id.of_string "alice")))

let body_of n =
  match Authz_body.of_yojson (`Assoc [ "n", `Int n ]) with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let make_exn ~head ~n =
  match
    R.make ~head ~at_ms:(1000 + n) ~author ~kind:R.Kind.Runtime_grant ~body:(body_of n)
  with
  | Ok record -> record
  | Error (R.Author_not_admitted _) -> Alcotest.fail "fixture author not admitted"
;;

(* [count] records chained from the genesis; the body of each holds its seq. *)
let chain_from_genesis ~count =
  let rec go head built remaining =
    if remaining = 0
    then List.rev built
    else (
      let record = make_exn ~head ~n:(R.next_seq head) in
      go (R.head_after record) (record :: built) (remaining - 1))
  in
  go R.genesis [] count
;;

let chain = chain_from_genesis ~count:5
let record n = List.nth chain (n - 1)
let hash_of_record n = (record n).R.hash

(* The first [count] records of the chain. *)
let log count = List.filteri (fun index _ -> index < count) chain

let head_before n = if n = 1 then R.genesis else R.head_after (record (n - 1))

(* A record in the place of record [n], with another hash. *)
let other_record n = make_exn ~head:(head_before n) ~n:(900 + n)

(* The hash that the genesis stands for, and one that no record has. *)
let genesis = R.Hash.genesis

let nowhere =
  match R.Hash.of_hex (String.make 64 'e') with
  | Some hash -> hash
  | None -> Alcotest.fail "fixture hash rejected"
;;

let label_of hash =
  let known =
    (genesis, "genesis")
    :: (nowhere, "nowhere")
    :: List.mapi (fun index (r : R.t) -> r.R.hash, Printf.sprintf "r%d" (index + 1)) chain
    @ List.map (fun n -> (other_record n).R.hash, Printf.sprintf "other%d" n) [ 1; 2; 3; 4 ]
  in
  match List.find_opt (fun (known_hash, _) -> R.Hash.equal known_hash hash) known with
  | Some (_, name) -> name
  | None -> String.sub (R.Hash.to_hex hash) 0 6
;;

(* ---- entries and states ---- *)

let workspace_text = "workspace-1"
let workspace = get (Workspace_id.of_string workspace_text)
let bootstrap = C.Mode { event = C.Fresh_bootstrap; workspace_id = workspace }
let revoke = C.Authz { event = C.Revoke; subject = Subject.Grant (get (Grant_id.of_string "grant-1")) }

let intent ~previous ~digest change : S.intent =
  { S.previous_record_hash = previous; intended_next_record_digest = digest; change }
;;

let pending ~previous ~digest change = S.Intent_pending (intent ~previous ~digest change)
let aborted ~previous ~digest change = S.Aborted_intent (intent ~previous ~digest change)
let committed record_hash = S.Committed { record_hash }

let apply_exn state entry =
  match S.apply state entry with
  | Ok state -> state
  | Error violation ->
    Alcotest.failf "the fixture breaks a rule of the store: %s" (S.violation_to_string violation)
;;

let state_of entries = List.fold_left apply_exn S.State.empty entries

(* The first intent of a store: the bootstrap that record 1 is. *)
let bootstrap_intent = pending ~previous:genesis ~digest:(hash_of_record 1) bootstrap

(* A store whose bootstrap was answered with record 1. *)
let booted = [ bootstrap_intent; committed (hash_of_record 1) ]

(* The intent for the event that record [m] is, after record [n]. *)
let intent_after n m = pending ~previous:(hash_of_record n) ~digest:(hash_of_record m) revoke

(* [booted], then the events that records 2 to [n] are, each answered in order,
   so the last answered record is record [n]. *)
let answered_to n =
  booted
  @ List.concat_map
      (fun m -> [ intent_after (m - 1) m; committed (hash_of_record m) ])
      (List.init (n - 1) (fun index -> index + 2))
;;

(* ---- the names of the answers ---- *)

let intent_name (intent : S.intent) =
  Printf.sprintf
    "%s>%s"
    (label_of intent.S.previous_record_hash)
    (label_of intent.S.intended_next_record_digest)
;;

let settlement_name : H.settlement -> string = function
  | H.Nothing_to_settle -> "nothing to settle"
  | H.Promote intent -> "promote " ^ intent_name intent
  | H.Abort intent -> "abort " ^ intent_name intent
;;

let reason_name : H.reason -> string = function
  | H.Digest_differs { intent; found } ->
    Printf.sprintf "digest differs %s found %s" (intent_name intent) (label_of found)
  | H.Commit_not_in_log hash -> "commit not in log " ^ label_of hash
  | H.Intent_unplaced intent -> "intent unplaced " ^ intent_name intent
  | H.Answers_differ { asked; answered } ->
    Printf.sprintf "answers differ, %d asked and %d answered" asked answered
;;

let value_name : H.t -> string = function
  | H.Absent -> "absent"
  | H.Matches -> "matches"
  | H.Mismatch (first, rest) ->
    "mismatch: " ^ String.concat "; " (List.map reason_name (first :: rest))
;;

let settle_name : (H.settlement, H.reason) result -> string = function
  | Ok settlement -> settlement_name settlement
  | Error reason -> "stays pending, " ^ reason_name reason
;;

(* ---- which records take an intent ---- *)

(* The probe is told, for each record, the change it takes an intent for.
   [Authz_state.apply] says so for the records of a real log. The records of
   these fixtures mean nothing to it, so a case says it. *)
type events =
  | Named_by_the_store
      (* A record is the record of an event exactly when an intent of the store
         names it, as in the files of a writer that never wrote outside its
         zone. Every other record is one that only the log holds. *)
  | Listed of R.t list
      (* These records are the records of events, whatever the store names. *)

let named_change entries (record : R.t) =
  List.find_map
    (function
      | S.Intent_pending (intent : S.intent)
        when R.Hash.equal intent.S.intended_next_record_digest record.R.hash ->
        Some intent.S.change
      | S.Intent_pending _ | S.Committed _ | S.Aborted_intent _ -> None)
    entries
;;

(* The probe counts the changes and does not read them, so a listed record
   takes the same change as any other. *)
let high_water_of events entries (record : R.t) =
  match events with
  | Named_by_the_store -> named_change entries record
  | Listed listed ->
    if List.exists (fun (event : R.t) -> R.Hash.equal event.R.hash record.R.hash) listed
    then Some revoke
    else None
;;

let feed events entries probe record =
  H.Probe.add probe record ~high_water:(high_water_of events entries record)
;;

(* ---- the judgments ---- *)

let probe_of events entries records =
  List.fold_left (feed events entries) (H.Probe.create (state_of entries)) records
;;

type case =
  { label : string
  ; store : S.entry list
  ; records : R.t list
  ; events : events
  ; value : string
  ; settle : string
  }

let case label store records value settle =
  { label; store; records; events = Named_by_the_store; value; settle }
;;

(* A case whose log holds the records of events that the store did not take an
   intent for, or holds fewer than the store answered. *)
let case_of_events label store records events value settle =
  { label; store; records; events = Listed events; value; settle }
;;

let probe_of_case c = probe_of c.events c.store c.records

(* What a probe says, against what a case expects. *)
let check_probe label expected probe =
  Alcotest.(check string) (label ^ ": the value") expected.value (value_name (H.judge probe));
  Alcotest.(check string)
    (label ^ ": what closes the intent")
    expected.settle
    (settle_name (H.settle probe));
  (* A writer that enters its zone gets the reasons of a mismatch, and
     otherwise whether the store holds an answer and, when it does, the
     settlement. *)
  match H.settle_on_entry probe with
  | Error (first, rest) ->
    Alcotest.(check string)
      (label ^ ": on entry to a zone")
      expected.value
      (value_name (H.Mismatch (first, rest)))
  | Ok H.Nothing_answered ->
    Alcotest.(check string) (label ^ ": on entry to a zone") expected.value (value_name H.Absent)
  | Ok (H.Answered settlement) ->
    Alcotest.(check string) (label ^ ": on entry to a zone") expected.value (value_name H.Matches);
    Alcotest.(check string)
      (label ^ ": what closes the intent on entry")
      expected.settle
      (settlement_name settlement)
;;

(* A writer that installs a log judges the store over a log with no record. It
   gets what a writer that enters a zone over that log gets, and never an
   answer. *)
let check_over_empty_log label expected state =
  match H.settle_over_empty_log state with
  | Error (first, rest) ->
    Alcotest.(check string)
      (label ^ ": before the first record")
      expected.value
      (value_name (H.Mismatch (first, rest)))
  | Ok abort ->
    Alcotest.(check string)
      (label ^ ": before the first record")
      expected.value
      (value_name H.Absent);
    Alcotest.(check string)
      (label ^ ": what closes the intent before the first record")
      expected.settle
      (settlement_name
         (match abort with
          | None -> H.Nothing_to_settle
          | Some intent -> H.Abort intent))
;;

(* Each case: what the store holds, what the log holds, the value, and what
   closes the intent. The record numbers are places in the chain, and [r1>r2] is
   an intent that follows record 1 and names record 2. *)
let cases =
  let other n = (other_record n).R.hash in
  let differs intent_text found = Printf.sprintf "digest differs %s found %s" intent_text found in
  [ case "an empty store over an empty log" [] [] "absent" "nothing to settle"
  ; case
      "an empty store says nothing about a log that has records"
      []
      (log 3)
      "absent"
      "nothing to settle"
  ; case
      "a bootstrap that the log never got is given up"
      [ bootstrap_intent ]
      []
      "absent"
      "abort genesis>r1"
  ; case
      "a bootstrap that the log got is promoted"
      [ bootstrap_intent ]
      (log 1)
      "matches"
      "promote genesis>r1"
  ; case
      "a bootstrap with another record in its place"
      [ bootstrap_intent ]
      [ other_record 1 ]
      ("mismatch: " ^ differs "genesis>r1" "other1")
      ("stays pending, " ^ differs "genesis>r1" "other1")
  ; case
      "a bootstrap that was given up leaves the store absent"
      [ bootstrap_intent; aborted ~previous:genesis ~digest:(hash_of_record 1) bootstrap ]
      []
      "absent"
      "nothing to settle"
  ; case
      "a bootstrap that was given up is not judged again when the log has records"
      [ bootstrap_intent; aborted ~previous:genesis ~digest:(hash_of_record 1) bootstrap ]
      (log 2)
      "absent"
      "nothing to settle"
  ; case
      "a bootstrap that is run again after it was given up is judged by itself"
      [ bootstrap_intent
      ; aborted ~previous:genesis ~digest:(hash_of_record 1) bootstrap
      ; pending ~previous:genesis ~digest:(other 1) bootstrap
      ]
      []
      "absent"
      "abort genesis>other1"
  ; case
      "a bootstrap whose place is not the end of an empty log"
      [ pending ~previous:nowhere ~digest:(hash_of_record 1) bootstrap ]
      []
      "mismatch: intent unplaced nowhere>r1"
      "stays pending, intent unplaced nowhere>r1"
  ; case "an answered bootstrap over the same log" booted (log 1) "matches" "nothing to settle"
  ; case
      "an answered bootstrap over a log that grew by records that only the log holds"
      booted
      (log 4)
      "matches"
      "nothing to settle"
  ; case
      "an answered bootstrap over an empty log"
      booted
      []
      "mismatch: commit not in log r1"
      "nothing to settle"
  ; case
      "an answered event over a log that went back before it"
      (answered_to 2)
      (log 1)
      "mismatch: commit not in log r2"
      "nothing to settle"
  ; case
      "an answered event over a log that holds it"
      (answered_to 3)
      (log 5)
      "matches"
      "nothing to settle"
  ; case
      "the last answered event is gone from a log that still holds the one before"
      (answered_to 3)
      (log 2)
      "mismatch: commit not in log r3"
      "nothing to settle"
  ; case
      "an intent while the log ends where it began"
      (booted @ [ intent_after 1 2 ])
      (log 1)
      "matches"
      "abort r1>r2"
  ; case
      "an intent whose record is in the log"
      (booted @ [ intent_after 1 2 ])
      (log 2)
      "matches"
      "promote r1>r2"
  ; case
      "an intent whose record is in the log, though the log has grown since"
      (booted @ [ intent_after 1 2 ])
      (log 4)
      "matches"
      "promote r1>r2"
  ; case
      "an intent with another record in its place"
      (booted @ [ intent_after 1 2 ])
      (log 1 @ [ other_record 2 ])
      ("mismatch: " ^ differs "r1>r2" "other2")
      ("stays pending, " ^ differs "r1>r2" "other2")
  ; case
      "an intent whose digest is the hash of a record that stands in another place"
      (booted @ [ intent_after 1 3 ])
      (log 3)
      ("mismatch: " ^ differs "r1>r3" "r2")
      ("stays pending, " ^ differs "r1>r3" "r2")
  ; case
      "an intent that follows a record that is not in the log"
      (booted @ [ intent_after 2 3 ])
      (log 1)
      "mismatch: intent unplaced r2>r3"
      "stays pending, intent unplaced r2>r3"
  ; case
      "an answered event and an intent over an empty log"
      (answered_to 2 @ [ intent_after 2 3 ])
      []
      "mismatch: commit not in log r2; intent unplaced r2>r3"
      "stays pending, intent unplaced r2>r3"
  ; case
      "an answered event and an intent over a log that went back before both"
      (answered_to 2 @ [ intent_after 2 3 ])
      (log 1)
      "mismatch: commit not in log r2; intent unplaced r2>r3"
      "stays pending, intent unplaced r2>r3"
  ; case
      "an intent after an answered event, with the log at the end of the event"
      (answered_to 2 @ [ intent_after 2 3 ])
      (log 2)
      "matches"
      "abort r2>r3"
  ; case
      "an intent that was given up is not judged against the log"
      (booted
       @ [ intent_after 1 2
         ; aborted ~previous:(hash_of_record 1) ~digest:(hash_of_record 2) revoke
         ])
      (log 1 @ [ other_record 2 ])
      "matches"
      "nothing to settle"
  ; (* The last answered event is gone, and an intent has begun from where the
       log is now. The value is a mismatch, and the intent is still settled:
       design 8.2-3 stands the block of 8.3 as soon as the judgment is made. *)
    case
      "the last answered event is gone and the intent never got its record"
      (answered_to 2 @ [ intent_after 1 3 ])
      (log 1)
      "mismatch: commit not in log r2"
      "abort r1>r3"
  ; case
      "the last answered event is gone and the intent got its record"
      (booted
       @ [ pending ~previous:(hash_of_record 1) ~digest:(other 2) revoke
         ; committed (other 2)
         ; intent_after 1 2
         ])
      (log 2)
      "mismatch: commit not in log other2"
      "promote r1>r2"
  ; case
      "the last answered event is gone and the intent has another record in its place"
      (answered_to 2 @ [ intent_after 1 3 ])
      (log 1 @ [ other_record 2 ])
      ("mismatch: commit not in log r2; " ^ differs "r1>r3" "other2")
      ("stays pending, " ^ differs "r1>r3" "other2")
  ; (* The epochs (design 5.1): the log holds as many records of events as the
       store answers. A mode event or a revocation that was appended outside
       the zone is a record of an event that no intent names. *)
    case_of_events
      "an event that the store never took an intent for, after the last answered one"
      booted
      (log 2)
      [ record 1; record 2 ]
      "mismatch: answers differ, 2 asked and 1 answered"
      "nothing to settle"
  ; case_of_events
      "an event that the store never took an intent for, with answered events built on it"
      (booted @ [ intent_after 2 3; committed (hash_of_record 3) ])
      (log 3)
      [ record 1; record 2; record 3 ]
      "mismatch: answers differ, 3 asked and 2 answered"
      "nothing to settle"
  ; case_of_events
      "a promoted intent is an answer, and an event with no intent before it is not"
      (booted @ [ intent_after 2 3 ])
      (log 3)
      [ record 1; record 2; record 3 ]
      "mismatch: answers differ, 3 asked and 2 answered"
      "promote r2>r3"
  ; case_of_events
      "an event with no intent, behind an intent that is given up"
      (booted @ [ intent_after 2 3 ])
      (log 2)
      [ record 1; record 2 ]
      "mismatch: answers differ, 2 asked and 1 answered"
      "abort r2>r3"
  ; case_of_events
      "the store answered more events than the log holds"
      (answered_to 2)
      (log 2)
      [ record 1 ]
      "mismatch: answers differ, 1 asked and 2 answered"
      "nothing to settle"
  ; case_of_events
      "an event with no intent is not counted while the store holds no answer"
      []
      (log 2)
      [ record 1; record 2 ]
      "absent"
      "nothing to settle"
  ]
;;

(* The names of the cases tell them apart in a failure, so no two share one. *)
let cases_have_distinct_labels () =
  let labels = List.map (fun c -> c.label) cases in
  Alcotest.(check int)
    "labels"
    (List.length labels)
    (List.length (List.sort_uniq String.compare labels))
;;

(* ---- what closes an intent ---- *)

let intent_lines intents = List.map (fun intent -> S.to_line (S.Intent_pending intent)) intents

let check_intents label expected actual =
  Alcotest.(check (list string)) label (intent_lines expected) (intent_lines actual)
;;

let hash_text = function
  | None -> "none"
  | Some hash -> R.Hash.to_hex hash
;;

let workspace_name state = Option.map Workspace_id.to_string (S.State.workspace_id state)

(* Every settlement is an entry that the store takes as its next entry, and no
   intent is pending after it. A promotion gives the commit that the intent
   named, an abort adds the intent to the given-up ones. *)
let a_settlement_is_an_entry_that_closes_the_intent () =
  let promoted = ref 0
  and aborted_count = ref 0 in
  List.iter
    (fun c ->
      match H.settle (probe_of_case c) with
      | Error _ -> ()
      | Ok settlement ->
        let state = state_of c.store in
        (match settlement, H.settlement_entry settlement with
         | H.Nothing_to_settle, None ->
           check_intents (c.label ^ ": nothing is pending") [] (Option.to_list (S.State.pending state))
         | H.Promote intent, Some entry ->
           incr promoted;
           let after = apply_exn state entry in
           check_intents (c.label ^ ": no intent after the commit") [] (Option.to_list (S.State.pending after));
           Alcotest.(check string)
             (c.label ^ ": the commit names the record")
             (hash_text (Some intent.S.intended_next_record_digest))
             (hash_text (S.State.last_committed after))
         | H.Abort intent, Some entry ->
           incr aborted_count;
           let after = apply_exn state entry in
           check_intents (c.label ^ ": no intent after the abort") [] (Option.to_list (S.State.pending after));
           check_intents
             (c.label ^ ": the intent is given up")
             (S.State.aborted state @ [ intent ])
             (S.State.aborted after)
         | H.Nothing_to_settle, Some _ | (H.Promote _ | H.Abort _), None ->
           Alcotest.failf "%s: the settlement and its entry do not go together" c.label))
    cases;
  Alcotest.(check bool) "a case promotes" true (!promoted > 0);
  Alcotest.(check bool) "a case aborts" true (!aborted_count > 0)
;;

(* A bootstrap that the log got and the store has not answered: the state that
   holds the answer knows the workspace, and the state before it does not. *)
let a_promoted_bootstrap_gives_its_workspace () =
  let entries = [ bootstrap_intent ] in
  let state = state_of entries in
  match H.settle (probe_of Named_by_the_store entries (log 1)) with
  | Error error -> Alcotest.failf "the bootstrap is not settled: %s" (reason_name error)
  | Ok settlement ->
    (match H.settlement_entry settlement with
     | None -> Alcotest.fail "a promoted bootstrap has an entry"
     | Some entry ->
       Alcotest.(check (option string)) "before the answer" None (workspace_name state);
       Alcotest.(check (option string))
         "after the answer"
         (Some workspace_text)
         (workspace_name (apply_exn state entry)))
;;

(* ---- a real file feeds the probe ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* Every file is in a fresh base path, inside an Eio event loop because the zone
   of the log is an [Eio.Mutex]. *)
let in_event_loop f = Eio_main.run (fun _env -> f ())

(* The probe that [Authz_log.open_at_start] builds over a file that holds
   [text], for a store that holds [entries], and what the open found at the
   end of it. *)
let probe_of_text events entries text =
  let base = Filename.temp_dir "authz-high-water-" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
      let path = L.path_of_base_path ~base_path:base in
      Fs_compat.mkdir_p (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text);
      match
        L.open_at_start
          ~path
          ~init:(H.Probe.create (state_of entries))
          ~step:(fun probe record -> Ok (feed events entries probe record))
      with
      | Ok (_log, probe, recovered) -> probe, recovered
      | Error error ->
        Alcotest.failf "open refused: %s" (L.open_error_to_string (fun () -> "") error))
;;

let text_of_records records = String.concat "" (List.map (fun r -> R.to_line r ^ "\n") records)

(* The records reach the probe through the file as they do through a list: the
   same answers for every case. *)
let a_file_gives_the_probe_the_records_of_a_list () =
  in_event_loop (fun () ->
    List.iter
      (fun c ->
        let probe, _recovered = probe_of_text c.events c.store (text_of_records c.records) in
        check_probe (c.label ^ " (from a file)") c probe)
      cases)
;;

(* The open cuts a last line that never ended before the probe sees it, so an
   intent whose record was being written when the process died has no record,
   and the log ends where the intent began. *)
let a_last_line_that_never_ended_is_not_seen () =
  in_event_loop (fun () ->
    let entries = booted @ [ intent_after 1 2 ] in
    let complete = text_of_records (log 1) in
    let second = R.to_line (record 2) in
    let torn = complete ^ String.sub second 0 (String.length second / 2) in
    let probe, recovered = probe_of_text Named_by_the_store entries torn in
    (match recovered.L.tail with
     | L.Cut _ -> ()
     | L.Complete -> Alcotest.fail "the open did not report the cut");
    Alcotest.(check string) "the value" "matches" (value_name (H.judge probe));
    Alcotest.(check string) "the record is not there" "abort r1>r2" (settle_name (H.settle probe));
    let probe, recovered =
      probe_of_text Named_by_the_store entries (complete ^ second ^ "\n")
    in
    (match recovered.L.tail with
     | L.Complete -> ()
     | L.Cut _ -> Alcotest.fail "a finished line was cut");
    Alcotest.(check string) "the finished line is there" "promote r1>r2" (settle_name (H.settle probe)))
;;

(* ---- the texts ---- *)

let contains ~sub text =
  let sub_length = String.length sub
  and length = String.length text in
  let rec at index =
    index + sub_length <= length && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

(* A reason names the records and the event that it is about, so that the one
   who reads a refusal can find them in the files. *)
let reasons_name_the_records () =
  let first = intent ~previous:(hash_of_record 1) ~digest:(hash_of_record 2) revoke in
  let texts =
    [ ( H.reason_to_string (H.Digest_differs { intent = first; found = (other_record 2).R.hash })
      , [ R.Hash.to_hex (other_record 2).R.hash
        ; R.Hash.to_hex (hash_of_record 2)
        ; C.to_string first.S.change
        ] )
    ; ( H.reason_to_string (H.Commit_not_in_log (hash_of_record 3))
      , [ R.Hash.to_hex (hash_of_record 3) ] )
    ; ( H.reason_to_string (H.Intent_unplaced first)
      , [ R.Hash.to_hex (hash_of_record 1); C.to_string first.S.change ] )
    ; H.reason_to_string (H.Answers_differ { asked = 31; answered = 29 }), [ "31"; "29" ]
    ]
  in
  List.iter
    (fun (text, needles) ->
      List.iter
        (fun needle -> Alcotest.(check bool) ("the text holds " ^ needle) true (contains ~sub:needle text))
        needles)
    texts;
  let distinct = List.sort_uniq String.compare (List.map fst texts) in
  Alcotest.(check int) "each reason has its own text" (List.length texts) (List.length distinct)
;;

(* ---- a probe that a writer moves ---- *)

type move =
  | Entry of S.entry
  | Record of R.t

let entries_of moves =
  List.filter_map
    (function
      | Entry entry -> Some entry
      | Record _ -> None)
    moves
;;

let moved_probe moves =
  let entries = entries_of moves in
  List.fold_left
    (fun probe move ->
      match move with
      | Record record -> feed Named_by_the_store entries probe record
      | Entry entry ->
        (match H.Probe.store_moved probe entry with
         | Ok probe -> probe
         | Error violation ->
           Alcotest.failf "the probe refused an entry: %s" (S.violation_to_string violation)))
    (H.Probe.create S.State.empty)
    moves
;;

(* The probe built from the whole files, the way a start builds it. *)
let probe_from_scratch moves =
  probe_of
    Named_by_the_store
    (entries_of moves)
    (List.filter_map
       (function
         | Record record -> Some record
         | Entry _ -> None)
       moves)
;;

let wrote_bootstrap = [ Entry bootstrap_intent; Record (record 1); Entry (committed (hash_of_record 1)) ]

(* A writer that puts each intent at the head: the probe it moves says what a
   probe built from the files says. *)
let a_moved_probe_agrees_with_the_files () =
  List.iter
    (fun (label, moves) ->
      let moved = moved_probe moves in
      let built = probe_from_scratch moves in
      Alcotest.(check string)
        (label ^ ": the value")
        (value_name (H.judge built))
        (value_name (H.judge moved));
      Alcotest.(check string)
        (label ^ ": what closes the intent")
        (settle_name (H.settle built))
        (settle_name (H.settle moved)))
    [ "the bootstrap", wrote_bootstrap
    ; "an intent at the head", wrote_bootstrap @ [ Entry (intent_after 1 2) ]
    ; "the record of the intent", wrote_bootstrap @ [ Entry (intent_after 1 2); Record (record 2) ]
    ; ( "its answer"
      , wrote_bootstrap
        @ [ Entry (intent_after 1 2); Record (record 2); Entry (committed (hash_of_record 2)) ] )
    ; ( "an aborted intent"
      , wrote_bootstrap
        @ [ Entry (intent_after 1 2)
          ; Entry (aborted ~previous:(hash_of_record 1) ~digest:(hash_of_record 2) revoke)
          ] )
    ; ( "an answer for a record that is not in the log"
      , wrote_bootstrap @ [ Entry (intent_after 1 2); Entry (committed (hash_of_record 2)) ] )
    ; ( "another record after the intent"
      , wrote_bootstrap @ [ Entry (intent_after 1 2); Record (other_record 2) ] )
    ; "a record without an intent", wrote_bootstrap @ [ Record (record 2) ]
    ]
;;

(* An intent that a writer did not put at the head: the moved probe cannot see
   what follows it, and reads it as unplaced. It never aborts it. *)
let an_intent_behind_the_head_is_not_aborted () =
  let moves = wrote_bootstrap @ [ Record (record 2); Entry (intent_after 1 3) ] in
  Alcotest.(check string)
    "the moved probe"
    "stays pending, intent unplaced r1>r3"
    (settle_name (H.settle (moved_probe moves)));
  Alcotest.(check string)
    "the files"
    "stays pending, digest differs r1>r3 found r2"
    (settle_name (H.settle (probe_from_scratch moves)))
;;

let a_moved_probe_refuses_what_the_store_refuses () =
  match H.Probe.store_moved (H.Probe.create S.State.empty) (committed (hash_of_record 1)) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a commit with no intent was taken"
;;

let () =
  Alcotest.run
    "authz_high_water"
    [ ( "judgments"
      , Alcotest.test_case "distinct labels" `Quick cases_have_distinct_labels
        :: List.map
             (fun c ->
               Alcotest.test_case c.label `Quick (fun () ->
                 check_probe c.label c (probe_of_case c);
                 match c.records with
                 | [] -> check_over_empty_log c.label c (state_of c.store)
                 | (_ : R.t) :: _ -> ()))
             cases )
    ; ( "settlement"
      , [ Alcotest.test_case
            "an entry that closes the intent"
            `Quick
            a_settlement_is_an_entry_that_closes_the_intent
        ; Alcotest.test_case
            "a promoted bootstrap gives its workspace"
            `Quick
            a_promoted_bootstrap_gives_its_workspace
        ] )
    ; ( "moved"
      , [ Alcotest.test_case "agrees with the files" `Quick a_moved_probe_agrees_with_the_files
        ; Alcotest.test_case
            "an intent behind the head is not aborted"
            `Quick
            an_intent_behind_the_head_is_not_aborted
        ; Alcotest.test_case
            "refuses what the store refuses"
            `Quick
            a_moved_probe_refuses_what_the_store_refuses
        ] )
    ; ( "file"
      , [ Alcotest.test_case
            "a file gives the probe the records of a list"
            `Quick
            a_file_gives_the_probe_the_records_of_a_list
        ; Alcotest.test_case
            "a last line that never ended"
            `Quick
            a_last_line_that_never_ended_is_not_seen
        ] )
    ; "texts", [ Alcotest.test_case "reasons name the records" `Quick reasons_name_the_records ]
    ]
;;
