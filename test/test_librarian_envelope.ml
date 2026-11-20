(* The snapshot a commit leaves (RFC librarian-call-only-proposes §8.2
   step 3). Every snapshot made here is also read back with the snapshot
   codec: that reader checks the support of every derived fact and the
   relation between the facts and the recorded change. *)

open Alcotest
module Envelope = Masc.Librarian_envelope
module Log = Masc.Librarian_log
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Current = Masc.Keeper_memory_os_current_types
module Snapshot_codec = Masc.Keeper_memory_os_snapshot_codec
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let covered : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let empty = Envelope.empty ~at:100.0 ~turn_log
let id_of_claim = Types.memory_id_of_claim
let transcript = Types.Observed Types.Transcript
let remember claim = Direct.Remember { claim; category = Types.Constraint; basis = transcript }

let commit ?revision ~(previous : Current.t) ~at cause effects : Log.commit =
  { seq = previous.revision
  ; at
  ; basis = Envelope.digest previous
  ; after = Envelope.digest previous
  ; revision = Option.value revision ~default:(previous.revision + 1)
  ; cause
  ; effects
  ; turn_log
  ; turn_log_offset = 0
  ; covers_through = Before_first
  ; covered
  ; working_state = None
  }
;;

let refusal_text : Envelope.refusal -> string = function
  | Revision_not_next { snapshot; line } ->
    Printf.sprintf "the snapshot is at %d and the line says %d" snapshot line
  | Facts_inconsistent (_ : string) -> "facts inconsistent"
;;

(* The line a direct write commits against [previous]. *)
let line_of ~(previous : Current.t) ~at write =
  match Direct.plan ~by:Effects.Keeper ~at ~trace_id:"turn" previous.facts write with
  | Writes { effects; facts = (_ : Types.fact list) } ->
    commit ~previous ~at (Log.Direct { by = Keeper; trace = "turn"; write }) effects
  | Already_held | Already_done | Already_absent | Refused _ ->
    fail "the write of the fixture does not write"
;;

(* The snapshot is what the snapshot codec reads back from its own bytes. *)
let reads_back label (snapshot : Current.t) =
  let bytes = Snapshot_codec.snapshot_bytes snapshot in
  match Snapshot_codec.of_json (Yojson.Safe.from_string bytes) with
  | Error rejection ->
    failf "%s: the snapshot codec refuses it: %s" label
      (Snapshot_codec.snapshot_rejection_to_string rejection)
  | Ok read ->
    check string (label ^ ": the same bytes again") bytes (Snapshot_codec.snapshot_bytes read)
;;

let rewritten label ~previous line =
  match Envelope.after ~previous line with
  | Ok (Rewritten snapshot) ->
    reads_back label snapshot;
    snapshot
  | Ok Unchanged -> failf "%s: the snapshot was left as it was" label
  | Error refusal -> failf "%s: %s" label (refusal_text refusal)
;;

let written label ~previous ~at write = rewritten label ~previous (line_of ~previous ~at write)
let claims facts = List.map (fun (fact : Types.fact) -> fact.claim) facts

let source_text (source : Current.source) =
  Snapshot_codec.source_kind_to_string source.kind ^ " on " ^ source.trace_id
;;

let port = "the port is 8935"
let owner = "the owner is the release team"
let rests = "requests go to 8935"

(* Three facts, the third derived from the first. *)
let held () =
  let one = written "port" ~previous:empty ~at:201.0 (remember port) in
  let two = written "owner" ~previous:one ~at:202.0 (remember owner) in
  written "rests" ~previous:two ~at:203.0
    (Direct.Remember
       { claim = rests
       ; category = Types.Lesson
       ; basis = Types.Derived [ { rule_id = "rule"; premise_ids = [ id_of_claim port ] } ]
       })
;;

let test_empty () =
  check int "the first revision" 1 empty.revision;
  check (list string) "no fact" [] (claims empty.facts);
  check string "the turn log is its trace"
    ("librarian on " ^ String.make 32 'a')
    (source_text empty.source);
  reads_back "empty" empty
;;

let test_a_write () =
  let snapshot = written "port" ~previous:empty ~at:201.0 (remember port) in
  check int "the revision after the snapshot's" 2 snapshot.revision;
  check (float 0.0) "updated when the line was written" 201.0 snapshot.updated_at;
  check string "the write, on its trace" "explicit_write on turn" (source_text snapshot.source);
  check (list string) "the facts" [ port ] (claims snapshot.facts);
  check (list string) "what the revision added" [ port ] (claims snapshot.change.added);
  check int "nothing was held before" 0 snapshot.change.retained
;;

let test_a_retraction_and_what_rested_on_it () =
  let before = held () in
  check (list string) "three facts" [ port; owner; rests ] (claims before.facts);
  let snapshot =
    written "retract" ~previous:before ~at:204.0
      (Direct.Retract { id = id_of_claim port; reason = "the port moved" })
  in
  check string "the retraction, on its trace" "explicit_retract on turn"
    (source_text snapshot.source);
  check (list string) "the facts" [ owner ] (claims snapshot.facts);
  check (list string) "what the revision removed" [ port; rests ] (claims snapshot.change.removed);
  check int "what stayed" 1 snapshot.change.retained;
  check
    (list (pair string (list string)))
    "the fact that lost its support, with what it lacks"
    [ rests, [ id_of_claim port ] ]
    (List.map
       (fun (lost : Current.support_invalidation) -> lost.fact.claim, lost.missing_premise_ids)
       snapshot.change.invalidated)
;;

let test_a_claim_seen_again () =
  let before = held () in
  let snapshot = written "seen again" ~previous:before ~at:204.0 (remember port) in
  check (list string) "the same facts in the same order" [ port; owner; rests ]
    (claims snapshot.facts);
  check (list (float 0.0)) "only its last_seen moved" [ 204.0; 202.0; 203.0 ]
    (List.map (fun (fact : Types.fact) -> fact.last_seen) snapshot.facts);
  check int "the other two are retained" 2 snapshot.change.retained
;;

let test_an_adoption_changes_no_byte () =
  let before = held () in
  let line =
    commit ~previous:before ~at:204.0
      (Log.Adopt { by = "operator-1"; observed = Envelope.digest before })
      Effects.empty
  in
  match Envelope.after ~previous:before line with
  | Ok Unchanged -> ()
  | Ok (Rewritten (_ : Current.t)) -> fail "an adoption rewrote the snapshot"
  | Error refusal -> fail (refusal_text refusal)
;;

let test_the_line_alone_gives_the_bytes () =
  let before = held () in
  let line =
    line_of ~previous:before ~at:204.0
      (Direct.Retract { id = id_of_claim port; reason = "the port moved" })
  in
  let first = rewritten "first" ~previous:before line in
  let again = rewritten "again" ~previous:before line in
  check string "written again from the line it has the same bytes"
    (Snapshot_codec.snapshot_bytes first)
    (Snapshot_codec.snapshot_bytes again);
  check bool "and the same digest" true (Envelope.digest first = Envelope.digest again)
;;

let test_refusals () =
  let before = held () in
  let skipped =
    commit ~revision:(before.revision + 2) ~previous:before ~at:204.0
      (Log.Direct { by = Keeper; trace = "turn"; write = remember "the probe runs every minute" })
      Effects.empty
  in
  (match Envelope.after ~previous:before skipped with
   | Error refusal ->
     check string "a line of another revision"
       (Printf.sprintf "the snapshot is at %d and the line says %d" before.revision
          (before.revision + 2))
       (refusal_text refusal)
   | Ok (Unchanged | Rewritten _) -> fail "a line that is not the next revision was applied");
  let held_fact = List.hd before.facts in
  let twice =
    commit ~previous:before ~at:204.0
      (Log.Direct { by = Keeper; trace = "turn"; write = remember port })
      { Effects.empty with added = [ held_fact ] }
  in
  match Envelope.after ~previous:before twice with
  | Error refusal ->
    check string "effects that hold one fact twice" "facts inconsistent" (refusal_text refusal)
  | Ok (Unchanged | Rewritten _) -> fail "a snapshot that holds one fact twice was made"
;;

let () =
  run "librarian_envelope"
    [ ( "snapshot"
      , [ test_case "of a Keeper that has none" `Quick test_empty
        ; test_case "after a write" `Quick test_a_write
        ; test_case "after a retraction" `Quick test_a_retraction_and_what_rested_on_it
        ; test_case "after a claim is seen again" `Quick test_a_claim_seen_again
        ; test_case "after an adoption" `Quick test_an_adoption_changes_no_byte
        ; test_case "from the line alone" `Quick test_the_line_alone_gives_the_bytes
        ; test_case "what is refused" `Quick test_refusals
        ] )
    ]
;;
