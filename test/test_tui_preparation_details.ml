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

let workspace_admission_preserves_selected_preparation () =
  with_source (fun config keeper_name turn_ref _ selected response ->
    let original = Details.decode ~target:selected response |> ok in
    let original_report = List.hd original.reports in
    let foreign_base = Filename.concat config.base_path "other-workspace" in
    Unix.mkdir foreign_base 0o700;
    let foreign = Workspace.default_config foreign_base in
    let preview = Preview.reset ~keeper_name ~turn_ref:(Some turn_ref)
        ~execution_scope:original_report.execution_scope ~now:10.
        ~redaction:Keeper_secret_redaction.empty in
    ignore (Observation.with_turn ~config:foreign ~keeper_name ~preview (fun () ->
      Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some turn_ref)
        ~phase:Preview.Context_preparation (fun () -> Error "foreign source failure")));
    let _, foreign_response = Server_dashboard_http_keeper_api.keeper_runtime_trace_json
        foreign keeper_name ~trace_id:(Ids.Turn_ref.trace_id turn_ref)
        ~turn_id:(Ids.Turn_ref.absolute_turn turn_ref) () in
    let foreign_snapshot = Details.decode ~target:selected foreign_response |> ok in
    check bool "matching execution IDs alone can decode another workspace's evidence" true
      (List.exists (fun (report : Observation.report) -> report.report_id<>original_report.report_id)
         foreign_snapshot.reports);
    let expected : Tui_decode.server_identity =
      { sid_version="0.24.0"; sid_binary_commit="preparation-source"
      ; sid_binary_commit_age_s=None; sid_base_path=Unix.realpath config.base_path
      ; sid_masc_root=Unix.realpath (Workspace.masc_dir config)
      ; sid_executable_in_worktree=None; sid_state_ready=Some true
      ; sid_uptime=None; sid_sse_clients=None; sid_gc=None; sid_scheduler=None } in
    let served = ref config and conditional = ref false in
    let receipt = Workspace.read_precondition_admission_header in
    let receipts = ref [receipt] in
    let kept_reads = Masc_tui_kept_reads.create () in
    let host = "127.0.0.1" and port = 8935 in
    let send ~path ~headers =
      let request = Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET path in
      match Server_auth.validate_read_workspace_precondition ~config:!served request with
      | Ok Server_auth.Workspace_read_matched ->
          let status, body = if !conditional then 304, "" else
            let trace_id = Server_utils.query_param request "trace_id" in
            let turn_id = Option.bind (Server_utils.query_param request "turn_id") int_of_string_opt in
            let status, json = Server_dashboard_http_keeper_api.keeper_runtime_trace_json
                !served keeper_name ?trace_id ?turn_id () in
            (match status with `OK -> 200 | `Not_found -> 404), Yojson.Safe.to_string json in
          Ok { Masc_http_client.status; headers=("ETag", "\"preparation-original\"")::!receipts; body }
      | Ok Server_auth.Workspace_read_unbound
      | Error (Workspace.Invalid_workspace_precondition | Workspace.Workspace_precondition_failed) ->
          Ok { Masc_http_client.status=409; headers=[]; body="{\"error\":\"workspace_precondition_failed\"}" }
    in
    let read () =
      Masc_tui_workspace_read.with_binding ~host ~port ~expected
        ~proof:Masc_tui_workspace_read.Request_precondition (fun () ->
          let ( let* ) = Result.bind in
          let* json = Masc_tui_workspace_read.read_json ~kept_reads
              ~address_of:(fun ~path -> Printf.sprintf "http://%s:%d%s" host port path)
              ~send ~decode:Tui_decode.decode_json_response_body ~host ~port
              ~path:(Details.path selected) in
          Details.decode ~target:selected json) in
    let begin_read () =
      let state, request = Details.select (Some selected) Details.empty in
      match request with Some request -> state, request | None -> fail "no preparation read owner" in
    let expect_original state =
      match Details.view selected state with
      | Details.Loaded snapshot ->
          check bool "selected original report and failure survive admission/cache reuse" true
            (List.exists (fun (report : Observation.report) ->
               report.report_id=original_report.report_id && report.boundary=Observation.Returned
               && List.for_all (fun (span : Preview.preparation_span) ->
                    match span.preparation.state with
                    | Preview.Preparation_finished {outcome=Preview.Rejected;_} -> true
                    | Preparation_finished _ | Preparation_active -> false)
                  (Preview.preparation_spans report.timeline)) snapshot.reports)
      | Not_loaded | Loading | Failed _ | Retained _ -> fail "admitted original preparation did not settle its selection" in
    let expect_failed state =
      match Details.view selected state with
      | Details.Failed _ -> ()
      | Not_loaded | Loading | Loaded _ | Retained _ -> fail "unadmitted evidence became loaded or left its owner pending" in
    let initial, initial_request = begin_read () in
    let first = read () in
    expect_original (Details.receive initial_request first initial);
    conditional := true;
    receipts := [];
    let pending, request = begin_read () in
    expect_failed (Details.receive request (read ()) pending);
    receipts := [receipt];
    let pending, request = begin_read () in
    check bool "old completion cannot settle explicit retry" true
      (Details.receive initial_request first pending==pending);
    expect_original (Details.receive request (read ()) pending);
    conditional := false;
    served := foreign;
    let pending, refused_request = begin_read () in
    expect_failed (Details.receive refused_request (read ()) pending);
    served := config;
    let pending, recovered_request = begin_read () in
    check bool "a retired foreign-attempt owner cannot settle recovered selection" true
      (Details.receive refused_request first pending==pending);
    expect_original (Details.receive recovered_request (read ()) pending))

let protocol_gaps_are_not_absence () = with_source (fun config keeper_name turn_ref _ selected response ->
  let rows = Yojson.Safe.Util.(member "manifest_rows" response |> to_list) in
  let duplicated = response |> replace "manifest_rows" (`List (rows@rows))
      |> replace "manifest_returned_rows" (`Int (2*List.length rows))
      |> replace "manifest_total_rows" (`Int (2*List.length rows)) in
  let snapshot = Details.decode ~target:selected duplicated |> ok in
  check int "duplicate identities never select one report" 0 (List.length snapshot.reports);
  check bool "duplicate evidence stays explicit" true
    (List.exists (function Details.Duplicate_report _ -> true
      | Partial_scan | Partial_return | Missing_manifest | Unsupported_rows _
      | Scan_unsupported_events _ | Scan_invalid_manifest_rows _ | Scan_invalid_json_rows _
      | Invalid_rows _ | Invalid_report _ | Unlinked_report -> false) snapshot.issues);
  let partial = response |> replace "manifest_total_rows_exact" (`Bool false)
      |> replace "manifest_total_rows" (`Int (List.length rows+1)) in
  let snapshot = Details.decode ~target:selected partial |> ok in
  check bool "scan and return truncation remain separate" true
    (List.mem Details.Partial_scan snapshot.issues && List.mem Details.Partial_return snapshot.issues);
  check int "partial coverage preserves actual reports" 1 (List.length snapshot.reports);
  let diagnostics = Yojson.Safe.Util.member "manifest_scan_diagnostics" response
      |> replace "unsupported_event_count" (`Int 1)
      |> replace "invalid_manifest_row_count" (`Int 2)
      |> replace "invalid_json_row_count" (`Int 3) in
  let unsupported = Details.decode ~target:selected
      (replace "manifest_scan_diagnostics" diagnostics response) |> ok in
  check bool "scan diagnostics retain their source scopes" true
    (List.mem (Details.Scan_unsupported_events 1) unsupported.issues
     && List.mem (Details.Scan_invalid_manifest_rows 2) unsupported.issues
     && List.mem (Details.Scan_invalid_json_rows 3) unsupported.issues
     && not (List.exists (function Details.Unsupported_rows _ | Invalid_rows _ -> true
       | Partial_scan | Partial_return | Missing_manifest | Scan_unsupported_events _
       | Scan_invalid_manifest_rows _ | Scan_invalid_json_rows _ | Invalid_report _
       | Duplicate_report _ | Unlinked_report -> false) unsupported.issues));
  check int "scan problems do not erase the original valid report" 1 (List.length unsupported.reports);
  let path = Keeper_runtime_manifest.path_for_trace config ~keeper_name
      ~trace_id:(Ids.Turn_ref.trace_id turn_ref) in
  let channel = open_out_gen [Open_wronly; Open_append; Open_binary] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    output_string channel "{}\n{not-json}\n");
  let status, damaged = Server_dashboard_http_keeper_api.keeper_runtime_trace_json config keeper_name
      ~trace_id:(Ids.Turn_ref.trace_id turn_ref) ~turn_id:(Ids.Turn_ref.absolute_turn turn_ref) () in
  check bool "actual trace still returns the original turn through damaged scan rows" true (status=`OK);
  let damaged = Details.decode ~target:selected damaged |> ok in
  check bool "actual scan preserves distinct malformed JSON and manifest evidence" true
    (List.mem (Details.Scan_invalid_manifest_rows 1) damaged.issues
     && List.mem (Details.Scan_invalid_json_rows 1) damaged.issues
     && not (List.mem (Details.Invalid_rows 1) damaged.issues));
  check int "actual damaged scan preserves the durable original preparation report" 1
    (List.length damaged.reports);
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
  let unrelated = Details.refresh ~keeper_name:(keeper_name ^ "-other") cached in
  check bool "another Keeper's history refresh does not invalidate original evidence" true
    (match Details.view selected unrelated with Details.Loaded value -> value==snapshot
     | Not_loaded | Loading | Failed _ | Retained _ -> false);
  let waiting = Details.refresh ~keeper_name cached in
  check bool "explicit refresh retains original evidence without claiming a running request" true
    (match Details.view selected waiting with
     | Details.Retained {snapshot=value;recheck=Details.Recheck_pending} -> value==snapshot
     | Not_loaded | Loading | Failed _ | Loaded _ | Retained _ -> false);
  let refreshing, first_refresh = Details.select (Some selected) waiting in
  let first_refresh = Option.get first_refresh in
  let restarting = Details.refresh ~keeper_name refreshing in
  let refreshing, next_refresh = Details.select (Some selected) restarting in
  let next_refresh = Option.get next_refresh in
  let late = Details.receive first_refresh (Ok snapshot) refreshing in
  check bool "refresh retires the older read capability while retaining only unconfirmed original evidence" true
    (match Details.view selected late with
     | Details.Retained {snapshot=value;recheck=Details.Recheck_loading} -> value==snapshot
     | Not_loaded | Loading | Failed _ | Loaded _ | Retained _ -> false);
  let failed_refresh = Details.receive next_refresh (Error "fresh read failed") late in
  check bool "failed reread preserves original reports with explicit failed freshness" true
    (match Details.view selected failed_refresh with
     | Details.Retained {snapshot=value;recheck=Details.Recheck_failed _} -> value==snapshot
     | Not_loaded | Loading | Failed _ | Loaded _ | Retained _ -> false);
  let retrying = Details.refresh ~keeper_name failed_refresh in
  let retrying, retry = Details.select (Some selected) retrying in
  let unaffected = Details.refresh ~keeper_name:(keeper_name ^ "-other") retrying in
  let hidden, _ = Details.select None unaffected in
  let refreshed_snapshot = Details.decode ~target:selected response |> ok in
  let hidden = Details.receive (Option.get retry) (Ok refreshed_snapshot) hidden in
  let visible, _ = Details.select (Some selected) hidden in
  check bool "an unrelated refresh preserves the owned read and hidden success confirms its original source" true
    (match Details.view selected visible with Details.Loaded value -> value==refreshed_snapshot
     | Not_loaded | Loading | Failed _ | Retained _ -> false);
  let other_log = journal ~keeper_name ~source:(Log.Operation "other") ~execution_id:"other" ~turn_ref in
  let other = target other_log in
  let moved, next = Details.select (Some other) state in
  check bool "a late prior selection cannot settle the new read" true
    (Details.receive request (Ok snapshot) moved == moved);
  let wrong = Details.receive (Option.get next) (Ok snapshot) moved in
  check bool "a response bound to another target is rejected" true
    (match Details.view other wrong with Details.Failed _ -> true
     | Not_loaded | Loading | Loaded _ | Retained _ -> false);
  let moved_retained, _ = Details.select (Some other) failed_refresh in
  check bool "another execution cannot display the retained report" true
    (match Details.view other moved_retained with Details.Loading -> true
     | Not_loaded | Failed _ | Loaded _ | Retained _ -> false);
  let closed, _ = Details.select None state in
  let _, duplicate = Details.select (Some selected) closed in
  check bool "folding and reopening do not duplicate the owned read" true (duplicate=None);
  let hidden = Details.receive request (Ok snapshot) closed in
  check bool "hidden completion is cached without being presented" true
    (match Details.view selected hidden with Details.Not_loaded -> true | Loading | Failed _ | Loaded _ | Retained _ -> false);
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
  check bool "new journal evidence invalidates the completed read" true (Option.is_some refresh);
  let revised_read, _ = Details.select (Some revised) failed_refresh in
  check bool "a newer journal revision cannot display retained evidence for the older revision" true
    (match Details.view revised revised_read with Details.Loading -> true
     | Not_loaded | Failed _ | Loaded _ | Retained _ -> false))

let original_identity_observations_are_owned () =
  Eio_main.run (fun _ ->
    let module Context = Keeper_turn_preview_owner in
    let first = Context.create_turn_observation () and second = Context.create_turn_observation () in
    let original = Ids.Turn_ref.make ~trace_id:"owned-original" ~absolute_turn:1 in
    let other = Ids.Turn_ref.make ~trace_id:"owned-other" ~absolute_turn:1 in
    Context.with_owner ~interrupt_token:(Keeper_interrupt_token.fresh ()) ~observation:first (fun () ->
      Context.note_turn_ref original;
      Context.note_turn_ref original;
      Context.with_owner ~interrupt_token:(Keeper_interrupt_token.fresh ()) ~observation:second (fun () ->
        Context.note_turn_ref other);
      check bool "nested Owner identity does not overwrite its parent" true
        (Context.observed_turn_ref first=Some original && Context.observed_turn_ref second=Some other));
    Context.note_turn_ref other;
    check bool "outside context cannot write a previous Owner" true (Context.observed_turn_ref first=Some original);
    Context.with_owner ~interrupt_token:(Keeper_interrupt_token.fresh ()) ~observation:first (fun () ->
      Context.note_turn_ref other;
      Context.note_turn_ref original);
    check bool "conflicting observations never pick first or last" true (Context.observed_turn_ref first=None))

type observed_failure = Returned_failure | Raised_failure | Cancelled_failure | Unobserved_failure

let failed_owner_to_saved_preparation () =
  List.iter (fun mode -> with_source (fun config keeper_name _ _ _ _ -> Eio.Switch.run (fun sw ->
    let original = Ids.Turn_ref.make ~trace_id:"original-owner-failure" ~absolute_turn:9 in
    let operation_id = Keeper_operation_id.of_string "original-owner-operation" |> ok in
    let entered, enter = Eio.Promise.create () in
    let settled, settle = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let execute ~sw:_ ~keeper_name:_ ~claim =
      let operation = match claim () with
        | Ok (Some operation) -> operation
        | Ok None -> fail "actual Owner did not claim its queued operation"
        | Error error -> fail (Keeper_owner.error_to_string error) in
      check bool "the producer runs the claimed operation" true
        (Keeper_operation_id.equal operation.Keeper_chat_operation.operation_id operation_id);
      match mode with
      | Unobserved_failure ->
        Eio.Promise.resolve enter ();
        Keeper_owner.Operation_failed {kind=Keeper_chat_operation.Turn_exception;
          detail="failure before an original turn exists"; outcome_ref=None}
      | Returned_failure | Raised_failure | Cancelled_failure ->
        Keeper_turn_preview_owner.note_turn_ref original;
        let preview = Preview.reset ~keeper_name ~turn_ref:(Some original)
            ~execution_scope:(Some (Keeper_execution_scope_id.direct_operation operation.Keeper_chat_operation.operation_id))
            ~now:3. ~redaction:Keeper_secret_redaction.empty in
        (* A newer displayed writer cannot replace the invocation's actual identity. *)
        ignore (Preview.reset ~keeper_name ~turn_ref:(Some (Ids.Turn_ref.make
          ~trace_id:"unrelated-display" ~absolute_turn:1)) ~execution_scope:None
          ~now:4. ~redaction:Keeper_secret_redaction.empty);
        ignore (Observation.with_turn ~config ~keeper_name ~preview (fun () ->
          Preview.with_preparation_result ~writer:(Some preview) ~turn_ref:(Some original)
            ~phase:Preview.Prompt_preparation (fun () ->
              Eio.Promise.resolve enter ();
              match mode with
              | Raised_failure -> raise (Failure "original preparation exception")
              | Cancelled_failure -> Eio.Promise.await never; Ok ()
              | Returned_failure | Unobserved_failure -> Error "original preparation refusal")));
        Keeper_owner.Operation_failed {kind=Keeper_chat_operation.Turn_exception;
          detail="original preparation refusal"; outcome_ref=None} in
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;
        "trace_id",`String "owner-meta-trace";"activation_mode",`String "manual"]) |> ok in
    let owner = Keeper_owner.start ~sw
        ~store:{replace=(fun _ -> Ok ()); remove=(fun _ -> Ok ())}
        ~operation_store_path:(Filename.concat config.Workspace.base_path "failure-owner.sqlite3") ~session_root:(Filename.concat (Filename.dirname (Filename.concat config.Workspace.base_path "failure-owner.sqlite3")) "traces")
        ~now:(fun () -> 10.) ~on_turn_slot_released:None ~keeper_name ~initial_meta:(Some meta)
        ~operation_runner:(Some {ready=(fun ~keeper_name:_ -> true); execute;
          on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution -> Eio.Promise.resolve settle execution)})
      |> Result.map_error Keeper_owner.error_to_string |> ok in
    ignore (Keeper_owner.submit_operation owner ~operation_id
      ~source:(`Assoc ["kind",`String "dashboard"])
      ~input:(`Assoc ["message",`String "fail before reply"])
      |> Result.map_error Keeper_owner.error_to_string |> ok);
    Eio.Promise.await entered;
    (match mode with
     | Cancelled_failure -> ()
     | Returned_failure | Raised_failure | Unobserved_failure -> ignore (Eio.Promise.await settled));
    ignore (Keeper_owner.begin_stopping owner |> Result.map_error Keeper_owner.error_to_string |> ok);
    ignore (Eio.Promise.await settled);
    let operation = Keeper_owner.exact_operation owner operation_id
        |> Result.map_error Keeper_owner.error_to_string |> ok |> Option.get in
    let expected_ref = match mode with Unobserved_failure -> None
      | Returned_failure | Raised_failure | Cancelled_failure -> Some (Ids.Turn_ref.to_string original) in
    (match operation.state with
     | Keeper_chat_operation.Failed {failure;_} ->
       check (option string) "canonical failure preserves only its producer-supplied turn" expected_ref failure.outcome_ref;
       check bool "cancellation keeps its original failure class" true
         (failure.kind=(match mode with Cancelled_failure -> Keeper_chat_operation.Turn_cancelled
           | Returned_failure | Raised_failure | Unobserved_failure -> Turn_exception))
     | Queued | Running _ | Succeeded _ | Cancelled _ -> fail "Owner did not persist a failed operation");
    let log = Log.create ~keeper_name ~request_id:(Keeper_operation_id.to_string operation_id) ~started_at:0. in
    ignore (Log.add ~at:1. log ~seq:(Some 0) Live.Run_started);
    ignore (Log.add ~at:2. log ~seq:(Some 1) (Live.Run_failed {message="original failure"}));
    let canonical = Log.decode_operation_state ~operation_id:(Keeper_operation_id.to_string operation_id)
        (Keeper_chat_operation.to_json operation) |> ok in
    Log.observe_operation_state log (Some canonical);
    let linked = Details.target ~journal:log ~execution_id:(Keeper_operation_id.to_string operation_id) ~reply_turn_ref:None in
    match mode with
    | Unobserved_failure ->
      check bool "an early failure does not borrow another stored turn" true (Result.is_error linked)
    | Returned_failure | Raised_failure | Cancelled_failure ->
      let selected = ok linked in
      let _, response = Server_dashboard_http_keeper_api.keeper_runtime_trace_json config keeper_name
          ~trace_id:(Ids.Turn_ref.trace_id original) ~turn_id:9 () in
      let snapshot = Details.decode ~target:selected response |> ok in
      check int "failed original operation finds its actual saved preparation" 1 (List.length snapshot.reports);
      let report = List.hd snapshot.reports in
      check bool "saved report keeps the actual failure boundary" true
        (report.boundary=(match mode with Returned_failure | Unobserved_failure -> Observation.Returned
          | Raised_failure -> Raised | Cancelled_failure -> Cancelled));
      let different = Ids.Turn_ref.make ~trace_id:"different-reply" ~absolute_turn:9 in
      check bool "a conflicting reply cannot replace canonical failure identity" true
        (Result.is_error (Details.target ~journal:log ~execution_id:(Keeper_operation_id.to_string operation_id)
          ~reply_turn_ref:(Some (Ids.Turn_ref.to_string different)))))))
    [Returned_failure; Raised_failure; Cancelled_failure; Unobserved_failure]

let () = run "selected-preparation-details"
  ["source and protocol", [test_case "original writer through actual runtime API" `Quick actual_source_to_selected_read;
    test_case "workspace admission through selected original preparation" `Quick workspace_admission_preserves_selected_preparation;
    test_case "partial, missing and ambiguous evidence" `Quick protocol_gaps_are_not_absence];
   "read ownership", [test_case "selected revision and retired requests" `Quick selected_read_ownership;
     test_case "original Owner identity remains exact" `Quick original_identity_observations_are_owned];
   "failed original work", [test_case "Owner failure through canonical wire and saved preparation" `Quick failed_owner_to_saved_preparation]]
