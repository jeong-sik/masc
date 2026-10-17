open Alcotest
open Masc
module Details = Masc_tui_preparation_details
module Log = Masc_tui_keeper_chat_log
module Live = Masc_tui_keeper_chat_live
module Transcript = Masc_tui_keeper_chat_transcript
module Preview = Keeper_turn_preview
module Observation = Keeper_preparation_runtime_observation

let ok = function Ok value -> value | Error detail -> fail detail
let replace key value = function
  | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
  | _ -> fail "object expected"

let journal ~keeper_name ~source ~execution_id ~turn_ref =
  let log = Log.create_for_source ~keeper_name ~source ~started_at:0. in
  let events = [Live.Run_started]
      @ (match source with Log.Operation operation_id ->
          [Live.Batch_bound {operation_id; execution_id}]
        | Autonomous_turn _ -> [])
      @ [Live.Reply_details {reply="result"; turn_outcome=Keeper_turn_outcome.Visible_reply;
          turn_ref=Ids.Turn_ref.to_string turn_ref; terminal_stream_scope=None}] in
  List.iteri (fun seq delta -> ignore (Log.add ~at:1. log ~seq:(Some seq) delta)) events;
  log

let target log =
  let transcript = Transcript.of_log ~now:2. log in
  Details.target ~journal:log ~execution_id:(Transcript.execution_id transcript)
    ~reply_turn_ref:(Option.map (fun reply -> reply.Transcript.reply_turn_ref) (Transcript.reply transcript))
  |> ok

let with_source f =
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Sys.rmdir path)
    else Sys.remove path in
  let base = Filename.temp_dir "tui-preparation-details-" "" in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> Eio_main.run (fun _ ->
    let config = Workspace.default_config base in
    let keeper_name = "selected-preparation" in
    let turn_ref = Ids.Turn_ref.make ~trace_id:"original#trace" ~absolute_turn:7 in
    let execution_id = "batch-execution" in
    let operation = Keeper_operation_id.of_string execution_id |> ok in
    let preview = Preview.reset ~keeper_name ~turn_ref:(Some turn_ref)
        ~execution_scope:(Some (Keeper_execution_scope_id.direct_operation operation))
        ~now:0. ~redaction:Keeper_secret_redaction.empty in
    ignore (Observation.with_turn ~config ~keeper_name ~preview (fun () ->
      Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some turn_ref)
        ~phase:Preview.World_preparation (fun () ->
          Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some turn_ref)
            ~phase:Preview.Workspace_memory_preparation (fun () -> Error "source unavailable"))));
    ignore (Preview.reset ~keeper_name ~turn_ref:None ~execution_scope:None ~now:3.
      ~redaction:Keeper_secret_redaction.empty);
    let log = journal ~keeper_name ~source:(Log.Operation "batch-member") ~execution_id ~turn_ref in
    let selected = target log in
    let status, response = Server_dashboard_http_keeper_api.keeper_runtime_trace_json config keeper_name
        ~trace_id:(Ids.Turn_ref.trace_id turn_ref) ~turn_id:(Ids.Turn_ref.absolute_turn turn_ref) () in
    check bool "actual selected runtime API answered" true (status=`OK);
    f config keeper_name turn_ref log selected response))

let actual_source_to_selected_read () = with_source (fun config keeper_name turn_ref _ selected response ->
  let snapshot = Details.decode ~target:selected response |> ok in
  check int "original durable report survives successor and actual API projection" 1 (List.length snapshot.reports);
  check bool "complete returned window has no invented gaps" true (snapshot.issues=[]);
  let report = List.hd snapshot.reports in
  check bool "returned error remains observed, not converted to success" true
    (report.boundary=Observation.Returned && List.for_all (fun (span : Preview.preparation_span) ->
      match span.preparation.state with
      | Preview.Preparation_finished {outcome=Preview.Rejected; _} -> true
      | Preparation_finished _ | Preparation_active -> false) (Preview.preparation_spans report.timeline));
  check (option string) "request retains exact trace containing a delimiter"
    (Some (Ids.Turn_ref.trace_id turn_ref)) (Uri.get_query_param (Uri.of_string (Details.path selected)) "trace_id");
  let other = journal ~keeper_name ~source:(Log.Operation "different-operation")
      ~execution_id:"different-operation" ~turn_ref |> target in
  check int "same Keeper and turn counter cannot join another operation" 0
    (List.length (Details.decode ~target:other response |> ok).reports);
  let unlinked = Log.create ~keeper_name ~request_id:"failed-without-reply-link" ~started_at:0. in
  check bool "a missing direct turn link is not guessed" true
    (Result.is_error (Details.target ~journal:unlinked ~execution_id:"failed-without-reply-link" ~reply_turn_ref:None));
  let autonomous_ref = Ids.Turn_ref.make ~trace_id:(Ids.Turn_ref.trace_id turn_ref) ~absolute_turn:8 in
  let preview = Preview.reset ~keeper_name ~turn_ref:(Some autonomous_ref) ~execution_scope:None
      ~now:4. ~redaction:Keeper_secret_redaction.empty in
  let entered, enter = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () -> Observation.with_turn ~config ~keeper_name ~preview (fun () ->
      Preview.with_preparation ~writer:(Some preview) ~turn_ref:(Some autonomous_ref)
        ~phase:Preview.Context_preparation (fun () -> Eio.Promise.resolve enter (); Eio.Promise.await never)))
    (fun () -> Eio.Promise.await entered);
  let log = Log.create_for_source ~keeper_name ~source:(Log.Autonomous_turn autonomous_ref) ~started_at:4. in
  let selected = Details.target ~journal:log ~execution_id:(Ids.Turn_ref.to_string autonomous_ref)
      ~reply_turn_ref:None |> ok in
  let _, response = Server_dashboard_http_keeper_api.keeper_runtime_trace_json config keeper_name
      ~trace_id:(Ids.Turn_ref.trace_id autonomous_ref) ~turn_id:8 () in
  let reports = (Details.decode ~target:selected response |> ok).reports in
  check bool "cancelled autonomous evidence survives without a reply receipt" true
    (match reports with [report] -> report.boundary=Observation.Cancelled | _ -> false))

let protocol_gaps_are_not_absence () = with_source (fun _ _ _ _ selected response ->
  let rows = Yojson.Safe.Util.(member "manifest_rows" response |> to_list) in
  let duplicated = response |> replace "manifest_rows" (`List (rows@rows))
      |> replace "manifest_returned_rows" (`Int (2*List.length rows))
      |> replace "manifest_total_rows" (`Int (2*List.length rows)) in
  let snapshot = Details.decode ~target:selected duplicated |> ok in
  check int "duplicate identities never select one report" 0 (List.length snapshot.reports);
  check bool "duplicate evidence stays explicit" true
    (List.exists (function Details.Duplicate_report _ -> true
      | Partial_scan | Partial_return | Missing_manifest | Unsupported_rows _
      | Invalid_rows _ | Invalid_report _ | Unlinked_report -> false) snapshot.issues);
  let partial = response |> replace "manifest_total_rows_exact" (`Bool false)
      |> replace "manifest_total_rows" (`Int (List.length rows+1)) in
  let snapshot = Details.decode ~target:selected partial |> ok in
  check bool "scan and return truncation remain separate" true
    (List.mem Details.Partial_scan snapshot.issues && List.mem Details.Partial_return snapshot.issues);
  check int "partial coverage preserves actual reports" 1 (List.length snapshot.reports);
  let diagnostics = Yojson.Safe.Util.member "manifest_scan_diagnostics" response
      |> replace "unsupported_event_count" (`Int 1) in
  let unsupported = Details.decode ~target:selected
      (replace "manifest_scan_diagnostics" diagnostics response) |> ok in
  check bool "unsupported evidence is retained" true (List.mem (Details.Unsupported_rows 1) unsupported.issues);
  check bool "a foreign response is rejected before reports are projected" true
    (Result.is_error (Details.decode ~target:selected (replace "keeper" (`String "foreign") response)));
  let missing = response |> replace "manifest_rows" (`List []) |> replace "manifest_returned_rows" (`Int 0)
      |> replace "manifest_total_rows" (`Int 0) |> replace "manifest_path_present" (`Bool false) in
  let snapshot = Details.decode ~target:selected missing |> ok in
  check bool "an absent journal stays a coverage gap" true
    (snapshot.reports=[] && List.mem Details.Missing_manifest snapshot.issues))

let selected_read_ownership () = with_source (fun _ keeper_name turn_ref log selected response ->
  let snapshot = Details.decode ~target:selected response |> ok in
  let state, request = Details.select (Some selected) Details.empty in
  let request = Option.get request in
  let same, again = Details.select (Some selected) state in
  check bool "an unchanged frame neither launches nor mutates read state" true (same==state && again=None);
  let cached = Details.receive request (Ok snapshot) state in
  let same, again = Details.select (Some selected) cached in
  check bool "an exact completed read is reused without redraw churn" true (same==cached && again=None);
  let other_log = journal ~keeper_name ~source:(Log.Operation "other") ~execution_id:"other" ~turn_ref in
  let other = target other_log in
  let moved, next = Details.select (Some other) state in
  check bool "a late prior selection cannot settle the new read" true
    (Details.receive request (Ok snapshot) moved == moved);
  let wrong = Details.receive (Option.get next) (Ok snapshot) moved in
  check bool "a response bound to another target is rejected" true
    (match Details.view other wrong with Details.Failed _ -> true
     | Not_loaded | Loading | Loaded _ -> false);
  let closed, _ = Details.select None state in
  let _, duplicate = Details.select (Some selected) closed in
  check bool "folding and reopening do not duplicate the owned read" true (duplicate=None);
  let hidden = Details.receive request (Ok snapshot) closed in
  check bool "hidden completion is cached without being presented" true
    (match Details.view selected hidden with Details.Not_loaded -> true | Loading | Failed _ | Loaded _ -> false);
  let _, duplicate = Details.select (Some selected) hidden in
  check bool "reopening reuses the hidden completion" true (duplicate=None);
  let reopened, fresh = Details.select (Some selected) moved in
  check bool "returning from another execution creates a fresh request capability" true (Option.is_some fresh);
  check bool "a retired request cannot land after returning to its old execution" true
    (Details.receive request (Ok snapshot) reopened == reopened);
  check bool "workspace retirement rejects the old result" true
    (Details.receive request (Ok snapshot) Details.empty == Details.empty);
  ignore (Log.add ~at:4. log ~seq:(Some 3) (Live.Run_failed {message="new recorded boundary"}));
  let revised = target log in
  let _, refresh = Details.select (Some revised) cached in
  check bool "new journal evidence invalidates the completed read" true (Option.is_some refresh))

let () = run "selected-preparation-details"
  ["source and protocol", [test_case "original writer through actual runtime API" `Quick actual_source_to_selected_read;
    test_case "partial, missing and ambiguous evidence" `Quick protocol_gaps_are_not_absence];
   "read ownership", [test_case "selected revision and retired requests" `Quick selected_read_ownership]]
