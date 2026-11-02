(** The shared submit-once machine over a real original journal. Only the
    Runtime call edge and the owner's pre-send check are supplied. *)
open Masc
module Submit = Lane_addon_submit_once
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Store = Lane_addon_store
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let scope = "submit-once-fixture"
let request_id = "original-submit-once-request"
let installation_id = Owner.installation_id (Owner.Configuration "submit-once-declaration")
let schema = `Assoc ["type",`String "object";
  "properties",`Assoc ["answer",`Assoc ["type",`String "string"]];
  "required",`List [`String "answer"];"additionalProperties",`Bool false]
let request = get (Exact.request_of_json (`Assoc ["kind",`String "exact_output";
  "request_id",`String request_id;"output",`String "answer";
  "messages",`List [`Assoc ["role",`String "user";"text",`String "Original whole input"]];
  "schema",schema]))
let with_store f =
  let parent = Filename.temp_dir "addon-submit-once" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    Eio_main.run (fun _ ->
      let store = Store.create ~root:(Filename.concat parent "store") in
      owned (Owner.retain ~store ~scope ~request_id ~installation_id ~package_id:"fixture"
        ~tool:"admit" ~summary:`Null ~request:(Exact.request_to_json request));
      f store))
let load store = match owned (Owner.load ~store ~scope ~request_id) with
  | Some record -> record | None -> Alcotest.fail "original request disappeared"
let events store = Progress.to_json (load store).progress
let event_names store = match events store with
  | `List events -> List.map (fun event -> Yojson.Safe.Util.(member "event" event |> to_string)) events
  | _ -> Alcotest.fail "progress history is not a list"
let reply state = Ok { (Mcp_protocol.Mcp_types.tool_result_of_text "fixture worker state") with
  structured_content = Some (`Assoc ["request_id",`String request_id;"state",`String state]) }
let kind arguments = Yojson.Safe.Util.(member "kind" arguments |> to_string)
let resume ?(prepare = fun () -> Ok ()) store call =
  Submit.resume ~store ~label:"Fixture" ~original:(load store) ~request ~schema
    ~decode_final:(Exact.final_of_json ~schema) ~prepare ~call
    ~terminal:(fun _ final -> Ok final)
let names = Alcotest.(list string)

let test_unsent_submit_is_declined_and_submitted_on_the_next_pass () = with_store (fun store ->
  let submits = ref 0 in
  let restarting ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | "submit" -> incr submits; Error (Submit.Not_sent (Submit.Unavailable "Add-on tool connection is unavailable"))
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  (match resume store restarting with
   | Error (Submit.Unavailable _) -> ()
   | Error (Submit.Rejected _ | Submit.Uncertain _) | Ok _ ->
     Alcotest.fail "a submit the host refused before sending must report that refusal");
  (match Progress.phase (load store).progress with
   | Progress.Admission_wait _ -> ()
   | Progress.Captured | Progress.Dispatch_pending _ | Progress.Judged _ | Progress.Committing _
   | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _
   | Progress.Subdividing _ | Progress.Subdivided _ ->
     Alcotest.fail "an unsent submit must not leave a pending dispatch");
  let attached ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | "submit" -> incr submits; reply "pending"
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  (match resume store attached with
   | Ok (Submit.Awaiting (Submit.Worker_pending, _)) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) | Error _ ->
     Alcotest.fail "the reattached worker must receive the same original request");
  Alcotest.(check int) "one refused and one sent submission" 2 !submits;
  Alcotest.check names "the refused intent is declined before the second admission"
    ["dispatch_intended";"admission_declined";"dispatch_intended";"waiting"] (event_names store))

let test_pre_send_unavailable_writes_no_intent () = with_store (fun store ->
  let gone () = Error (Submit.Unavailable "Original admission Add-on export is unavailable") in
  let call ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | other -> Alcotest.fail ("a refused pre-send check reached " ^ other) in
  (match resume ~prepare:gone store call with
   | Ok (Submit.Awaiting (Submit.Worker_unreachable, _)) -> ()
   | Error _ | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
     Alcotest.fail "the unavailable pre-send destination must retain the original waiting");
  Alcotest.check names "no dispatch intent was written" [] (event_names store))

let test_sent_unknown_never_submits_again () = with_store (fun store ->
  let submits = ref 0 in
  let lost ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | "submit" -> incr submits; Error (Submit.Sent_unknown "original admission reply was lost")
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  (match resume store lost with
   | Ok (Submit.Awaiting (Submit.Worker_unknown, _)) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) | Error _ ->
     Alcotest.fail "a lost reply must remain uncertain");
  (match resume store lost with
   | Ok (Submit.Awaiting (Submit.Missing_after_dispatch, _)) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) | Error _ ->
     Alcotest.fail "absence after a possible admission cannot clear it");
  Alcotest.(check int) "the possibly admitted request is never sent twice" 1 !submits)

let test_unsent_read_leaves_a_pending_dispatch_unchanged () = with_store (fun store ->
  let lost ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | "submit" -> Error (Submit.Sent_unknown "original admission reply was lost")
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  ignore (resume store lost);
  let before = events store in
  let detached ~arguments = match kind arguments with
    | "read" -> Error (Submit.Not_sent (Submit.Unavailable "Add-on tool installation is no longer available"))
    | other -> Alcotest.fail ("a pending dispatch reached " ^ other) in
  (match resume store detached with
   | Ok (Submit.Awaiting (Submit.Worker_unreachable, _)) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) | Error _ ->
     Alcotest.fail "an unreachable worker leaves the dispatched original waiting");
  Alcotest.check json "an unsent read is not an execution observation" before (events store);
  let refused ~arguments = match kind arguments with
    | "read" -> Error (Submit.Not_sent (Submit.Rejected "Fresh admission destination differs"))
    | other -> Alcotest.fail ("a pending dispatch reached " ^ other) in
  (match resume store refused with
   | Error (Submit.Rejected _) -> ()
   | Error (Submit.Unavailable _ | Submit.Uncertain _) | Ok _ ->
     Alcotest.fail "a refused destination must be returned, not waited on");
  Alcotest.check json "a refused read writes nothing either" before (events store))

type original_phase = Fresh_capture | Capacity_declined
type unavailable_boundary = Worker_read | Admission_preparation
let journal_path store = Filename.concat (Store.root store)
  (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest scope) (Store.digest request_id ^ ".json")))
let test_pre_admission_unavailable_preserves_and_resumes_original phase boundary () = with_store (fun store ->
  (match phase with
   | Fresh_capture -> ()
   | Capacity_declined ->
     let capacity ~arguments = match kind arguments with
       | "read" -> reply "absent"
       | "submit" -> reply "capacity_wait"
       | other -> Alcotest.fail ("unexpected capacity setup command " ^ other) in
     (match resume store capacity with
      | Ok (Submit.Awaiting (Submit.Capacity, _)) -> ()
      | Error _ | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
        Alcotest.fail "actual pre-admission capacity reply was not retained"));
  let original=load store in
  let path=journal_path store in
  let bytes=Fs_compat.load_file path and identity=Unix.stat path in
  let reads=ref 0 and prepares=ref 0 and submissions=ref 0 in
  let prepare ()=incr prepares;match boundary with
    | Worker_read -> Alcotest.fail "an unavailable read reached admission preparation"
    | Admission_preparation -> Error (Submit.Unavailable "destination disappeared after authoritative absence") in
  let detached ~arguments = match kind arguments with
    | "read" ->
      incr reads;
      Alcotest.(check string) "read addresses exact retained ID" original.request_id
        Yojson.Safe.Util.(member "request_id" arguments |> to_string);
      (match boundary with
       | Worker_read -> Error (Submit.Not_sent (Submit.Unavailable "configured Add-on is Off"))
       | Admission_preparation -> reply "absent")
    | "submit" -> incr submissions;Alcotest.fail "unavailable pre-admission work dispatched"
    | other -> Alcotest.fail ("unexpected detached command " ^ other) in
  let check_wait ()=match resume ~prepare store detached with
    | Ok (Submit.Awaiting (Submit.Worker_unreachable, retained)) ->
      Alcotest.(check bool) "wait keeps full immutable request and exact prior progress" true
        (retained.request_id=original.request_id && retained.request_digest=original.request_digest
         && retained.request=original.request && Progress.events retained.progress=Progress.events original.progress)
    | Error error -> Alcotest.fail (Submit.error_to_string error)
    | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
      Alcotest.fail "pre-admission unavailability was not retained as a wait" in
  check_wait ();check_wait ();
  let current=Unix.stat path in
  Alcotest.(check bool) "repeated Off wakes preserve actual journal bytes and inode" true
    (bytes=Fs_compat.load_file path && identity.st_dev=current.st_dev && identity.st_ino=current.st_ino);
  Alcotest.(check int) "each wake only reads this original" 2 !reads;
  Alcotest.(check int) "preparation runs only after authoritative absence"
    (match boundary with Worker_read -> 0 | Admission_preparation -> 2) !prepares;
  Alcotest.(check int) "neither unavailable boundary sends a submission" 0 !submissions;
  let attached ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | "submit" ->
      incr submissions;
      Alcotest.check json "reattachment sends the complete exact same original request"
        (Exact.request_to_json request) Yojson.Safe.Util.(member "request" arguments);
      reply "pending"
    | other -> Alcotest.fail ("unexpected reattached command " ^ other) in
  let reopened=Store.create ~root:(Store.root store) in
  (match resume reopened attached with
   | Ok (Submit.Awaiting (Submit.Worker_pending, admitted)) ->
     Alcotest.(check string) "actual admission keeps original ID across handle reopen" original.request_id admitted.request_id
   | Error error -> Alcotest.fail (Submit.error_to_string error)
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
     Alcotest.fail "the reattached exact original was not admitted");
  Alcotest.(check int) "only reattachment submits this original once" 1 !submissions;
  let waiting ~arguments = match kind arguments with
    | "read" -> reply "pending"
    | other -> Alcotest.fail ("an already admitted original reached " ^ other) in
  ignore (resume reopened waiting);
  Alcotest.(check int) "later reads cannot redispatch admitted work" 1 !submissions)

let test_pre_admission_nonavailability_errors_are_not_waits () = with_store (fun store ->
  let bytes=Fs_compat.load_file (journal_path store) in
  List.iter (fun error ->
    let assert_error = function
      | Error actual -> Alcotest.(check bool) "original typed refusal remains its exact error" true (actual=error)
      | Ok _ -> Alcotest.fail "a definite refusal or unconfirmed authority was turned into an unavailable wait" in
    let refused ~arguments = match kind arguments with
      | "read" -> Error (Submit.Not_sent error)
      | other -> Alcotest.fail ("refused original reached " ^ other) in
    assert_error (resume store refused);
    let absent ~arguments = match kind arguments with
      | "read" -> reply "absent"
      | other -> Alcotest.fail ("refused prepare reached " ^ other) in
    assert_error (resume ~prepare:(fun () -> Error error) store absent);
    Alcotest.(check string) "refused authority writes no progress" bytes
      (Fs_compat.load_file (journal_path store)))
    [Submit.Rejected "original owner changed";Submit.Uncertain "authority check is unconfirmed"])

let worker_finished final = Ok {
  (Mcp_protocol.Mcp_types.tool_result_of_text "retained worker terminal") with
  structured_content = Some (`Assoc ["request_id",`String request_id;
    "state",`String "finished";"result",Exact.final_to_json final]) }
let host_record store ~attempt ~final =
  get (Store.save_exact_request store ~declaration_id:"submit-once-declaration" ~request_id
    (`Assoc ["declaration_id",`String "submit-once-declaration";"request_id",`String request_id;
      "digest",`String (Exact.digest request);"request",Exact.request_to_json request;
      "attempts",`List [attempt];"final",final]))
let test_worker_unknown_keeps_the_authoritative_host_cause cause = with_store (fun store ->
  let retained=Exact.Retained_unknown cause in
  let evidence=Exact.retained_final_to_json retained in
  let attempt=match cause,evidence with
    | Exact.Raised,`Assoc fields -> `Assoc (("exception",`String "fixture exception")::fields)
    | (Exact.Interrupted | Exact.Cut),_ -> evidence
    | Exact.Raised,_ -> Alcotest.fail "unknown evidence must be an object" in
  let calls=ref 0 in
  let call ~arguments=match kind arguments with
    | "read" -> reply "absent"
    | "submit" ->
      incr calls;
      (* As during synchronous dispatch, the host terminal becomes durable
         only after the consumer's initial observation and before delivery. *)
      host_record store ~attempt ~final:(Exact.final_to_json Exact.Outcome_unknown);
      worker_finished Exact.Outcome_unknown
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  (match resume store call with
   | Ok (Submit.Final Exact.Outcome_unknown) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
     Alcotest.fail "host-confirmed unknown did not retain the original refusal"
   | Error error -> Alcotest.fail (Submit.error_to_string error));
  (match Progress.phase (load store).progress with
   | Progress.Rejected {stage=Progress.Execution;evidence=actual} ->
     Alcotest.check json "host cause survives the worker's cause-free echo" evidence actual
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
   | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Alcotest.fail "unknown refusal was not retained");
  let never_call ~arguments:_ = Alcotest.fail "a retained refusal called an unavailable worker" in
  (match resume store never_call with
   | Ok (Submit.Final Exact.Outcome_unknown) -> ()
   | Ok (Submit.Awaiting _ | Submit.Final _ | Submit.Commit_pending _ | Submit.Settled _) ->
     Alcotest.fail "retained cause changed its delivered result"
   | Error error -> Alcotest.fail (Submit.error_to_string error));
  Alcotest.(check int) "this original was submitted once" 1 !calls)
type contradictory_host = Absent_host | Open_host | Different_host
let test_worker_unknown_refuses_a_contradictory_host host = with_store (fun store ->
  let call ~arguments=match kind arguments with
    | "read" -> reply "absent"
    | "submit" ->
      (match host with
       | Absent_host -> ()
       | Open_host -> host_record store
         ~attempt:(`Assoc ["started",`String (String.make 32 '0')]) ~final:`Null
       | Different_host ->
         let denied=Exact.final_to_json (Exact.Not_allowed {reason="original host refusal"}) in
         host_record store ~attempt:denied ~final:denied);
      worker_finished Exact.Outcome_unknown
    | other -> Alcotest.fail ("unexpected worker command " ^ other) in
  (match resume store call with
   | Error (Submit.Rejected _) -> ()
   | Error (Submit.Unavailable _ | Submit.Uncertain _) | Ok _ ->
     Alcotest.fail "worker unknown cannot replace contradictory host authority");
  (match Progress.phase (load store).progress with
   | Progress.Dispatch_pending _ -> ()
   | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
   | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
     Alcotest.fail "contradictory worker echo was retained as an authoritative refusal"))
let test_unknown_refusal_without_a_host_cause_is_not_replayed () = with_store (fun store ->
  let advance original event=match get (Result.map_error Owner.update_error_to_string
      (Owner.advance ~store ~expected:original ~event)) with
    | Owner.Stored record | Owner.Already_stored record -> record
    | Owner.Unconfirmed detail -> Alcotest.fail detail in
  let dispatched=advance (load store) Progress.Dispatch_intended in
  ignore (advance dispatched (Progress.Refused {stage=Progress.Execution;
    evidence=Exact.final_to_json Exact.Outcome_unknown}));
  let never_call ~arguments:_ = Alcotest.fail "old refusal must not cause another RPC" in
  match resume store never_call with
  | Error (Submit.Rejected _) -> ()
  | Error (Submit.Unavailable _ | Submit.Uncertain _) | Ok _ -> Alcotest.fail "cause-free old refusal was accepted")

let () =
  Alcotest.run "Lane_addon_submit_once" [
    "admission", [
      Alcotest.test_case "worker unknown retains Interrupted host cause" `Quick
        (fun () -> test_worker_unknown_keeps_the_authoritative_host_cause Exact.Interrupted);
      Alcotest.test_case "worker unknown retains Cut host cause" `Quick
        (fun () -> test_worker_unknown_keeps_the_authoritative_host_cause Exact.Cut);
      Alcotest.test_case "worker unknown retains Raised host cause" `Quick
        (fun () -> test_worker_unknown_keeps_the_authoritative_host_cause Exact.Raised);
      Alcotest.test_case "worker unknown cannot invent an absent host terminal" `Quick
        (fun () -> test_worker_unknown_refuses_a_contradictory_host Absent_host);
      Alcotest.test_case "worker unknown cannot replace an open host call" `Quick
        (fun () -> test_worker_unknown_refuses_a_contradictory_host Open_host);
      Alcotest.test_case "worker unknown cannot replace a different host terminal" `Quick
        (fun () -> test_worker_unknown_refuses_a_contradictory_host Different_host);
      Alcotest.test_case "old cause-free refusal is rejected without another RPC" `Quick
        test_unknown_refusal_without_a_host_cause_is_not_replayed;
      Alcotest.test_case "Captured Off read waits unchanged then resumes the exact original" `Quick
        (test_pre_admission_unavailable_preserves_and_resumes_original Fresh_capture Worker_read);
      Alcotest.test_case "Capacity-declined Off read waits unchanged then resumes the exact original" `Quick
        (test_pre_admission_unavailable_preserves_and_resumes_original Capacity_declined Worker_read);
      Alcotest.test_case "Captured prepare unavailability after absence waits without dispatch" `Quick
        (test_pre_admission_unavailable_preserves_and_resumes_original Fresh_capture Admission_preparation);
      Alcotest.test_case "Capacity-declined prepare unavailability waits without dispatch" `Quick
        (test_pre_admission_unavailable_preserves_and_resumes_original Capacity_declined Admission_preparation);
      Alcotest.test_case "nonavailability read and prepare refusals preserve typed errors" `Quick
        test_pre_admission_nonavailability_errors_are_not_waits;
      Alcotest.test_case "unsent submit is declined and submitted on the next pass" `Quick
        test_unsent_submit_is_declined_and_submitted_on_the_next_pass;
      Alcotest.test_case "pre-send unavailability waits without an intent" `Quick test_pre_send_unavailable_writes_no_intent;
      Alcotest.test_case "sent unknown never submits again" `Quick test_sent_unknown_never_submits_again;
      Alcotest.test_case "unsent read leaves a pending dispatch unchanged" `Quick
        test_unsent_read_leaves_a_pending_dispatch_unchanged;
    ];
  ]
