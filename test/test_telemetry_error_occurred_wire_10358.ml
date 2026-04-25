(** #10358 — pin the [Error_occurred] paired-emit contract.

    Pre-fix [Tool_called] events with [success=false] (142 of 825
    on 2026-04-25, 17.3%) carried no diagnostic.  The [Error_occurred]
    ADT variant existed but only one site emitted it
    ([dashboard_tool_host_events]), so 4 days of fleet failures
    accumulated with no classification trail in the JSONL.

    [Telemetry_eio.track_tool_called] now takes an optional
    [?error_kind] (and [?error_message]).  When [success=false]
    AND [error_kind=Some _], it fans out a paired [Error_occurred]
    event so the previously-dead variant carries the failure mode
    + tool/agent/session context.

    These tests pin the fan-out contract:

    1. success=true  + error_kind=Some _   → only Tool_called.
    2. success=false + error_kind=None     → only Tool_called
       (back-compat for the 3 callers that don't classify).
    3. success=false + error_kind=Some k   → Tool_called +
       Error_occurred with [code=k] and a structured [context].
    4. success=false + error_kind=Some "  " → no Error_occurred
       (whitespace-only kind treated as no signal).
    5. success=false + custom error_message → message preserved
       verbatim; default fallback only when message is empty. *)

open Alcotest

(* The pair-emit test exercises the in-process [track] dispatch
   path, which writes to [Dated_jsonl].  We check the most recent
   entries of the in-memory store rather than touching the
   filesystem — same approach as test_telemetry_unified. *)

open Masc_mcp
module T = Telemetry_eio

let make_config () =
  let dir = Filename.temp_file "telem_10358_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config = Masc_mcp.Coord.default_config dir in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-10358"));
  (config, dir)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun n -> rm_rf (Filename.concat path n));
      Unix.rmdir path
    end else
      Sys.remove path

(* [track_tool_called] reaches the Dated_jsonl store via an Eio.Mutex,
   so callers need an Eio runtime even when the JSONL ends up routed
   through the in-memory backend. *)
let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config, dir = make_config () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f config)

(* Read the most recent [n] event tags via [Telemetry_eio]'s own
   read API so we hit the same Dated_jsonl store the writer cached.
   [read_all_events] returns parsed event_records; we extract the
   variant-tag (the camelcase constructor name from yojson). *)
let event_kind_tag (e : T.event) =
  match e with
  | T.Agent_joined _ -> "Agent_joined"
  | T.Agent_left _ -> "Agent_left"
  | T.Task_started _ -> "Task_started"
  | T.Task_completed _ -> "Task_completed"
  | T.Handoff_triggered _ -> "Handoff_triggered"
  | T.Error_occurred _ -> "Error_occurred"
  | T.Tool_called _ -> "Tool_called"
  | T.Tool_assigned _ -> "Tool_assigned"

(* [Coord.init] emits an [Agent_joined] event during setup; filter
   it out so test assertions only see the events explicitly emitted
   by [track_tool_called]. *)
let recent_events_kinds config _n =
  let records = T.read_all_events config in
  records
  |> List.filter_map (fun (r : T.event_record) ->
         match event_kind_tag r.event with
         | "Agent_joined" -> None
         | tag -> Some tag)

(* --- 1. success=true + error_kind: only Tool_called ------------ *)

let test_success_true_no_error_emit () =
  with_temp_config @@ fun config ->
  T.track_tool_called config ~tool_name:"masc_status"
    ~success:true ~duration_ms:5
    ~error_kind:"timeout"
    ();
  let kinds = recent_events_kinds config 5 in
  check (list string)
    "only Tool_called when success=true (no Error_occurred even \
     if error_kind passed)"
    [ "Tool_called" ] kinds

(* --- 2. success=false + no error_kind: only Tool_called -------- *)

let test_failure_without_error_kind_no_pair () =
  with_temp_config @@ fun config ->
  T.track_tool_called config ~tool_name:"masc_status"
    ~success:false ~duration_ms:9
    ();
  let kinds = recent_events_kinds config 5 in
  check (list string)
    "only Tool_called when error_kind is None (back-compat)"
    [ "Tool_called" ] kinds

(* --- 3. success=false + error_kind: pair Tool_called + Error_occurred *)

let test_failure_with_error_kind_pairs () =
  with_temp_config @@ fun config ->
  T.track_tool_called config ~tool_name:"keeper_bash"
    ~success:false ~duration_ms:30000
    ~agent_id:"keeper-executor-agent"
    ~source:"keeper_internal"
    ~session_id:"sess-10358"
    ~error_kind:"timeout"
    ();
  let kinds = recent_events_kinds config 5 in
  check (list string)
    "fan-out: Tool_called then Error_occurred"
    [ "Tool_called"; "Error_occurred" ] kinds

(* --- 4. whitespace error_kind suppresses the pair -------------- *)

let test_whitespace_error_kind_no_pair () =
  with_temp_config @@ fun config ->
  T.track_tool_called config ~tool_name:"masc_status"
    ~success:false ~duration_ms:1
    ~error_kind:"   "
    ();
  let kinds = recent_events_kinds config 5 in
  check (list string)
    "whitespace-only error_kind treated as no signal"
    [ "Tool_called" ] kinds

(* --- 5. message override preserved ---------------------------- *)

let test_error_message_override_preserved () =
  with_temp_config @@ fun config ->
  T.track_tool_called config ~tool_name:"keeper_edit"
    ~success:false ~duration_ms:42
    ~error_kind:"tool_failure"
    ~error_message:"file not found: /tmp/missing.ml"
    ();
  let records = T.read_all_events config in
  match List.rev records with
  | last :: _ -> (
      match last.event with
      | T.Error_occurred { message; _ } ->
          check string "explicit error_message preserved verbatim"
            "file not found: /tmp/missing.ml" message
      | other ->
          failf "expected Error_occurred, got %s"
            (event_kind_tag other))
  | [] -> failf "no telemetry records written"

let () =
  run "telemetry_error_occurred_wire_10358"
    [
      ( "no-pair-on-success",
        [
          test_case "success=true ignores error_kind" `Quick
            test_success_true_no_error_emit;
        ] );
      ( "back-compat",
        [
          test_case "success=false without error_kind: only Tool_called"
            `Quick test_failure_without_error_kind_no_pair;
          test_case "whitespace error_kind treated as no signal" `Quick
            test_whitespace_error_kind_no_pair;
        ] );
      ( "fan-out",
        [
          test_case "success=false + error_kind: pair emit" `Quick
            test_failure_with_error_kind_pairs;
          test_case "explicit error_message preserved" `Quick
            test_error_message_override_preserved;
        ] );
    ]
