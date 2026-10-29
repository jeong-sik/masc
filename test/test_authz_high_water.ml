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

(* ---- the judgments ---- *)

let probe_of entries records =
  List.fold_left H.Probe.add (H.Probe.create (state_of entries)) records
;;

type case =
  { label : string
  ; store : S.entry list
  ; records : R.t list
  ; value : string
  ; settle : string
  }

let case label store records value settle = { label; store; records; value; settle }

(* What a probe says, against what a case expects. *)
let check_probe label expected probe =
  Alcotest.(check string) (label ^ ": the value") expected.value (value_name (H.judge probe));
  Alcotest.(check string)
    (label ^ ": what closes the intent")
    expected.settle
    (settle_name (H.settle probe))
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
      match H.settle (probe_of c.store c.records) with
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
  match H.settle (probe_of entries (log 1)) with
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
   [text], for a store in [state], and what the open found at the end of it. *)
let probe_of_text text state =
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
          ~init:(H.Probe.create state)
          ~step:(fun probe record -> Ok (H.Probe.add probe record))
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
        let probe, _recovered = probe_of_text (text_of_records c.records) (state_of c.store) in
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
    let probe, recovered = probe_of_text torn (state_of entries) in
    (match recovered.L.tail with
     | L.Cut _ -> ()
     | L.Complete -> Alcotest.fail "the open did not report the cut");
    Alcotest.(check string) "the value" "matches" (value_name (H.judge probe));
    Alcotest.(check string) "the record is not there" "abort r1>r2" (settle_name (H.settle probe));
    let probe, recovered = probe_of_text (complete ^ second ^ "\n") (state_of entries) in
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

let () =
  Alcotest.run
    "authz_high_water"
    [ ( "judgments"
      , Alcotest.test_case "distinct labels" `Quick cases_have_distinct_labels
        :: List.map
             (fun c ->
               Alcotest.test_case c.label `Quick (fun () ->
                 check_probe c.label c (probe_of c.store c.records)))
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
