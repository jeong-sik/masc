(** Receipts of a background Execute run.

    What the Keeper reads after it starts a command with [run_in_background]
    is the receipt, so these tests pin the fields a receipt carries and that
    the outbox accepts it. The worker that runs the command is not exercised
    here. *)

open Alcotest
open Masc

module Background = Keeper_execute_background.For_testing
module Outbox = Keeper_client_tool_outbox

let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "background-owner"

let member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "%s missing" key)
  | other -> failf "%s looked up on %s" key (Yojson.Safe.to_string other)
;;

let text = function
  | `String value -> value
  | other -> failf "expected a string, got %s" (Yojson.Safe.to_string other)
;;

let fields_of = function
  | `Assoc fields -> fields
  | other -> failf "expected an object, got %s" (Yojson.Safe.to_string other)
;;

let tool_execute_name = "tool_execute"

let arguments =
  `Assoc [ "command", `String "sleep 30; echo done"; "run_in_background", `Bool true ]
;;

let payload =
  `Assoc [ "ok", `Bool true; "status", `Assoc [ "kind", `String "exit"; "code", `Int 0 ] ]
;;

let test_started_result_names_the_request () =
  let json = Background.started_json ~request_id:"req-1" ~elapsed_ms:7 in
  check string "kind" "started" (text (member "kind" (member "status" json)));
  check string "request_id" "req-1" (text (member "request_id" json))
;;

(* A composition plan node that sets [run_in_background] completes with the
   start result, and the executor validates a completed node against the
   schema its descriptor declares. The members that schema requires come from
   the descriptor, so a change to the schema fails here. *)
let test_started_result_has_the_members_the_execute_schema_requires () =
  let descriptor =
    match
      List.find_opt
        (fun descriptor ->
           String.equal descriptor.Keeper_tool_descriptor.internal_name tool_execute_name)
        (Keeper_tool_descriptor.all_descriptors ())
    with
    | Some descriptor -> descriptor
    | None -> failf "no descriptor named %s" tool_execute_name
  in
  let schema =
    match descriptor.Keeper_tool_descriptor.composable_output with
    | Keeper_tool_descriptor.Json_output { schema } -> schema
    | Keeper_tool_descriptor.Opaque_output -> fail "Execute declares no output schema"
  in
  let json = Background.started_json ~request_id:"req-1" ~elapsed_ms:7 in
  (match member "required" schema with
   | `List names ->
     List.iter
       (fun name ->
          let name = text name in
          check bool (name ^ " is present") true (List.mem_assoc name (fields_of json)))
       names
   | other -> failf "required is not a list: %s" (Yojson.Safe.to_string other));
  check
    bool
    "status is an object"
    true
    (match member "status" json with
     | `Assoc _ -> true
     | _ -> false)
;;

(* The request id is all the model holds of the run, so the start result says
   which tools take it and which tool loads them. The names are the constants
   those tools are registered under; a renamed tool changes both sides. *)
let test_started_result_names_the_tools_that_read_and_stop_the_run () =
  let json = Background.started_json ~request_id:"req-1" ~elapsed_ms:7 in
  let delivery = text (member "delivery" json) in
  List.iter
    (fun name ->
       check
         bool
         (name ^ " is named")
         true
         (String_util.contains_substring delivery name))
    [ Keeper_tool_composition_catalog.status_tool_name
    ; Keeper_tool_composition_catalog.cancel_tool_name
    ; Keeper_identity_tool_search.tool_name
    ]
;;

let test_receipt_names_the_producer_and_the_request () =
  let receipt =
    Background.receipt_of_unfinished ~request_id:"req-1" ~arguments ~cause:"stopped"
  in
  check string "thread_id" "execute_background" receipt.Outbox.thread_id;
  check string "turn_id" "req-1" receipt.Outbox.turn_id;
  check string "call_id" "req-1" receipt.Outbox.call_id;
  check string "tool_name" "tool_execute" receipt.Outbox.tool_name;
  check bool "arguments are the call's own" true (receipt.Outbox.arguments = arguments)
;;

let test_finished_run_carries_the_foreground_payload () =
  let receipt =
    Background.receipt_of_execution
      ~request_id:"req-1"
      ~arguments
      (Keeper_tool_execution.success_data payload)
  in
  let response = receipt.Outbox.response in
  check string "request_id" "req-1" (text (member "request_id" response));
  check string "outcome" "completed" (text (member "outcome" response));
  check bool "result is the payload" true (member "result" response = payload)
;;

let test_failed_run_says_failed () =
  let receipt =
    Background.receipt_of_execution
      ~request_id:"req-1"
      ~arguments
      (Keeper_tool_execution.failure
         ~class_:Tool_result.Runtime_failure
         "sandbox start failed")
  in
  let response = receipt.Outbox.response in
  check string "outcome" "failed" (text (member "outcome" response));
  check
    bool
    "result keeps the failure text"
    true
    (String_util.contains_substring
       (Yojson.Safe.to_string (member "result" response))
       "sandbox start failed")
;;

let test_unfinished_run_says_the_status_was_not_recorded () =
  let receipt =
    Background.receipt_of_unfinished
      ~request_id:"req-1"
      ~arguments
      ~cause:Background.restart_cause
  in
  let response = receipt.Outbox.response in
  let result = member "result" response in
  check string "outcome" "unfinished" (text (member "outcome" response));
  check bool "ok is false" true (member "ok" result = `Bool false);
  check string "message" Background.restart_cause (text (member "message" result))
;;

(* [Outbox.retain] refuses a receipt the codec rejects and one that reads back
   different from what was written; both would block the Keeper's requests if
   they were committed. *)
let test_outbox_keeps_the_receipt () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "execute-background-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some keeper_name));
  let finished =
    Background.receipt_of_execution
      ~request_id:"req-1"
      ~arguments
      (Keeper_tool_execution.success_data payload)
  in
  let unfinished =
    Background.receipt_of_unfinished
      ~request_id:"req-2"
      ~arguments
      ~cause:Background.restart_cause
  in
  get (Outbox.retain ~base_path ~keeper_name finished);
  get (Outbox.retain ~base_path ~keeper_name unfinished);
  (* The same receipt again leaves one file: the name is the content digest. *)
  get (Outbox.retain ~base_path ~keeper_name unfinished);
  let snapshot = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt) in
  check int "two receipts" 2 (List.length (Outbox.receipt_ids snapshot));
  let context = String.concat "\n" (Outbox.developer_context snapshot) in
  check bool "first request id is readable" true (String_util.contains_substring context "req-1");
  check bool "second request id is readable" true (String_util.contains_substring context "req-2");
  (* A start after a crash between the end of a run and the settle of its
     request finds the receipt, and writes no [unfinished] one beside it. *)
  check
    bool
    "a written request is held"
    true
    (get (Background.holds_receipt ~base_path ~keeper_name ~request_id:"req-1"));
  check
    bool
    "an unwritten request is not held"
    false
    (get (Background.holds_receipt ~base_path ~keeper_name ~request_id:"req-3"))
;;

(* The arrival line points at a receipt by the SHA-256 of its file. The model
   holds the request id of the run, so [receipt_summary] reads the id and the
   outcome back from the receipt a background run wrote. *)
let test_summary_names_the_request_and_the_outcome () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "execute-background-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some keeper_name));
  let finished =
    Background.receipt_of_execution
      ~request_id:"req-1"
      ~arguments
      (Keeper_tool_execution.success_data payload)
  in
  let failed =
    Background.receipt_of_execution
      ~request_id:"req-2"
      ~arguments
      (Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure "sandbox start failed")
  in
  let unfinished =
    Background.receipt_of_unfinished
      ~request_id:"req-3"
      ~arguments
      ~cause:Background.restart_cause
  in
  List.iter
    (fun receipt -> get (Outbox.retain ~base_path ~keeper_name receipt))
    [ finished; failed; unfinished ];
  let snapshot = get (Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt) in
  let summaries =
    List.filter_map
      (fun receipt_id -> Outbox.receipt_summary snapshot ~receipt_id)
      (Outbox.receipt_ids snapshot)
  in
  check int "every receipt has a summary" 3 (List.length summaries);
  let outcome_of request_id =
    match
      List.find_opt (fun (summary : Outbox.Summary.t) -> String.equal summary.Outbox.Summary.call_id request_id) summaries
    with
    | Some summary -> summary
    | None -> failf "no summary for %s" request_id
  in
  check (option string) "finished" (Some "completed") (outcome_of "req-1").Outbox.Summary.outcome;
  check (option string) "failed" (Some "failed") (outcome_of "req-2").Outbox.Summary.outcome;
  check (option string) "unfinished" (Some "unfinished") (outcome_of "req-3").Outbox.Summary.outcome;
  check string "tool" tool_execute_name (outcome_of "req-1").Outbox.Summary.tool_name;
  check
    bool
    "an identity the outbox does not hold has no summary"
    true
    (Option.is_none (Outbox.receipt_summary snapshot ~receipt_id:"0000"));
  (* The reader answers from one load: a receipt written after the first lookup
     is not in it, and a lookup of an identity it does not hold is [None]. *)
  let unavailable = ref [] in
  let reader =
    Outbox.summary_reader ~base_path ~keeper_name ~viewer:Outbox.Unowned_only ~on_unavailable:(fun detail ->
      unavailable := detail :: !unavailable)
  in
  let first_id =
    match Outbox.receipt_ids snapshot with
    | id :: _ -> id
    | [] -> fail "three receipts were retained"
  in
  check bool "the reader finds a held receipt" true (Option.is_some (reader first_id));
  check bool "and none for another identity" true (Option.is_none (reader "0000"));
  check int "a readable outbox reports nothing" 0 (List.length !unavailable)
;;

(* An outbox that cannot be read is reported once and answers no summary, so a
   line keeps its bare description and the round goes on. *)
let test_summary_reader_reports_an_unreadable_outbox_once () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path = Filename.temp_dir "execute-background-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some keeper_name));
  let outbox = get (Keeper_official_client_paths.outbox_dir ~base_path ~keeper_name) in
  Fs_compat.mkdir_p (Filename.dirname outbox);
  Fs_compat.save_file outbox "a file where the directory belongs";
  let reported = ref [] in
  let reader =
    Outbox.summary_reader ~base_path ~keeper_name ~viewer:Outbox.Unowned_only ~on_unavailable:(fun detail ->
      reported := detail :: !reported)
  in
  check bool "no summary" true (Option.is_none (reader "abc"));
  check bool "still none on the second lookup" true (Option.is_none (reader "def"));
  check int "reported once" 1 (List.length !reported)
;;

let () =
  run
    "keeper_execute_background"
    [ ( "receipt"
      , [ test_case "started result names the request" `Quick test_started_result_names_the_request
        ; test_case
            "started result has the members the Execute schema requires"
            `Quick
            test_started_result_has_the_members_the_execute_schema_requires
        ; test_case
            "started result names the tools that read and stop the run"
            `Quick
            test_started_result_names_the_tools_that_read_and_stop_the_run
        ; test_case
            "receipt names the producer and the request"
            `Quick
            test_receipt_names_the_producer_and_the_request
        ; test_case
            "finished run carries the foreground payload"
            `Quick
            test_finished_run_carries_the_foreground_payload
        ; test_case "failed run says failed" `Quick test_failed_run_says_failed
        ; test_case
            "unfinished run says the status was not recorded"
            `Quick
            test_unfinished_run_says_the_status_was_not_recorded
        ] )
    ; ( "outbox"
      , [ test_case "outbox keeps the receipt" `Quick test_outbox_keeps_the_receipt
        ; test_case
            "summary names the request and the outcome"
            `Quick
            test_summary_names_the_request_and_the_outcome
        ; test_case
            "summary reader reports an unreadable outbox once"
            `Quick
            test_summary_reader_reports_an_unreadable_outbox_once
        ] )
    ]
;;
