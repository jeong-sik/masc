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
        ~tool:"admit" ~request:(Exact.request_to_json request));
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
  Submit.resume ~store ~label:"Fixture" ~original:(load store) ~request ~schema ~prepare ~call
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

let test_pre_send_refusal_writes_no_intent () = with_store (fun store ->
  let gone () = Error (Submit.Unavailable "Original admission Add-on export is unavailable") in
  let call ~arguments = match kind arguments with
    | "read" -> reply "absent"
    | other -> Alcotest.fail ("a refused pre-send check reached " ^ other) in
  (match resume ~prepare:gone store call with
   | Error (Submit.Unavailable _) -> ()
   | Error (Submit.Rejected _ | Submit.Uncertain _) | Ok _ -> Alcotest.fail "the pre-send refusal must be returned");
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

let () =
  Alcotest.run "Lane_addon_submit_once" [
    "admission", [
      Alcotest.test_case "unsent submit is declined and submitted on the next pass" `Quick
        test_unsent_submit_is_declined_and_submitted_on_the_next_pass;
      Alcotest.test_case "pre-send refusal writes no intent" `Quick test_pre_send_refusal_writes_no_intent;
      Alcotest.test_case "sent unknown never submits again" `Quick test_sent_unknown_never_submits_again;
      Alcotest.test_case "unsent read leaves a pending dispatch unchanged" `Quick
        test_unsent_read_leaves_a_pending_dispatch_unchanged;
    ];
  ]
