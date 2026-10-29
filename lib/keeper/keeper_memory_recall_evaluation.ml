module Client = Typesafeai_client
module Types = Typesafeai_types
module Codec = Keeper_memory_recall_jev_codec
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment

let journal_file_name = "memory-recall-evaluations.jsonl"
let http_status_ok = 200
let http_status_too_many_requests = 429

type t =
  { judgment_id : string
  ; keeper_id : string
  ; path : string
  ; turn_ref : Ids.Turn_ref.t
  ; destinations : Typesafeai_config.destinations
  ; rotation : unit Eio.Lazy.t
  }

let create ~config ~keeper_id ~turn_ref ~destinations =
  let directory = Filename.concat (Workspace.keepers_runtime_dir config) keeper_id in
  let path = Filename.concat directory journal_file_name in
  { judgment_id = Random_id.prefixed ~prefix:"memory-recall-" ~bytes:16
  ; keeper_id
  ; path
  ; turn_ref
  ; destinations
  ; rotation =
      (* A rotation renames several files, and running it again after a cut one
         can drop an older file. It runs to its end, whoever forces it. *)
      Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Keeper_types_support.maybe_rotate_file path))
  }

let judgment_id t = t.judgment_id
let journal_path t = t.path

(* ---- from the client's failure to the flow's ---- *)

let refusal_status (attempt : Client.attempt) =
  match attempt.refusal with
  | Client.Http_response_failure { status; destination_uri = _; body = _; detail = _ } -> Some status
  | Client.Transport_failure _ -> None

let attempt_failure_of_client_failure failure : Flow.attempt_failure =
  match Client.failure_kind failure with
  | Client.Capacity_refused -> Flow.Capacity_refused
  | Client.Other_refusal ->
    let statuses = List.map refusal_status (Client.attempts failure) in
    let every status = List.for_all (Option.equal Int.equal (Some status)) statuses in
    if every http_status_too_many_requests then Flow.Rate_limited
    else if every http_status_ok then Flow.Invalid_response
    else Flow.Failed

(* ---- metrics ---- *)

(* Histogram schema, not a limit on a request: the client's own timeout decides
   when a request ends. A request takes 0.2 to 1 second in the measures of the
   RFC (section 4.8) and at most the timeout of each destination in turn. *)
let request_seconds_upper_bounds = [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 20.0; 40.0 ]

let () =
  Otel_metric_store.register_histogram_buckets
    Keeper_metrics.(to_string MemoryRecallRequestSeconds)
    request_seconds_upper_bounds

(* How one request ended, as the [result] label says it. *)
type request_result =
  | Answered
  | Attempt_failed of Flow.attempt_failure
  | Cancelled_request

let request_result_token = function
  | Answered -> "answered"
  | Attempt_failed failure -> Flow.attempt_failure_token failure
  | Cancelled_request -> "cancelled"

let record_request t ~kind result =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryRecallRequests)
    ~labels:
      [ "keeper", t.keeper_id
      ; "kind", Codec.request_kind_token kind
      ; "result", request_result_token result
      ]
    ()

let record_request_seconds t ~kind seconds =
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string MemoryRecallRequestSeconds)
    ~labels:[ "keeper", t.keeper_id; "kind", Codec.request_kind_token kind ]
    seconds

let record_input_bytes t bytes =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryRecallInputBytes)
    ~labels:[ "keeper", t.keeper_id ]
    ~delta:(Float.of_int bytes)
    ()

(* ---- the journal ---- *)

let append_unprotected t row =
  let payload = Yojson.Safe.to_string row ^ "\n" in
  let written = String.length payload in
  match Fs_compat.append_private_jsonl_durable_locked_result t.path payload with
  | Fs_compat.Private_file_succeeded () -> Ok written
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
    Log.Keeper.warn "memory recall record committed; descriptor cleanup failed: %s"
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    Ok written
  | Fs_compat.Private_file_failed error ->
    Error (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf "%s; descriptor cleanup failed: %s"
         (Fs_compat.private_jsonl_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))

(* The rotation check runs once for a judgment, before its first row, so the
   rows of one judgment never split across two files and no rotation overlaps
   another append of the same judgment. *)
let append t row =
  try
    Eio.Lazy.force t.rotation;
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> append_unprotected t row)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, path) ->
    Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code))

let judgment_fields t =
  [ "judgment_id", `String t.judgment_id
  ; "turn_ref", Ids.Turn_ref.to_yojson t.turn_ref
  ; "recorded_at", `Float (Time_compat.now ())
  ]

let request_row t ~request_id ~kind fields =
  `Assoc
    (judgment_fields t
     @ [ "request_id", `String request_id
       ; "kind", `String (Codec.request_kind_token kind)
       ]
     @ fields)

let response_json (evaluated : Client.evaluated) =
  `Assoc
    [ "destination", Client.destination_id_to_yojson evaluated.destination
    ; "request_body_sha256", `String evaluated.request_body_sha256
    ; "passed_over", `List (List.map Client.attempt_to_yojson evaluated.passed_over)
    ; "model", `String evaluated.response.model
    ; "answers"
      , `Assoc
          (List.map
             (fun (id, answer) -> id, Types.answer_to_yojson answer)
             evaluated.response.answers)
    ; "usage"
      , (match evaluated.response.usage with
         | None -> `Null
         | Some usage ->
           `Assoc
             [ "input_tokens", `Int usage.input_tokens
             ; "output_tokens", `Int usage.output_tokens
             ])
    ]

(* ---- one request ---- *)

let evaluate_with ~call t (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
  let request_id = Random_id.prefixed ~prefix:"memory-recall-request-" ~bytes:16 in
  let kind = request.kind in
  let row fields = request_row t ~request_id ~kind fields in
  let first, rest = t.destinations in
  let started =
    row
      [ "status", `String "started"
      ; "destinations"
        , `List
            (List.map
               (fun destination -> Client.destination_id_to_yojson (Client.identify destination))
               (first :: rest))
      ; "state", request.state
      ; "questions"
        , `Assoc
            (List.map
               (fun (id, question) -> id, Types.question_to_yojson question)
               request.questions)
      ]
  in
  match append t started with
  | Error detail ->
    Log.Keeper.warn "memory recall input record unavailable request=%s: %s" request_id detail;
    record_request t ~kind (Attempt_failed Flow.Not_recorded);
    Error Flow.Not_recorded
  | Ok started_bytes ->
    record_input_bytes t started_bytes;
    let began = Time_compat.now () in
    let result =
      try call ~destinations:t.destinations ~state:request.state ~questions:request.questions () with
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Eio.Cancel.protect (fun () ->
          match append t (row [ "status", `String "cancelled" ]) with
          | Ok _ -> ()
          | Error _ ->
            Log.Keeper.warn "memory recall cancellation record unavailable request=%s" request_id);
        record_request t ~kind Cancelled_request;
        Printexc.raise_with_backtrace exn backtrace
    in
    record_request_seconds t ~kind (Time_compat.now () -. began);
    let completion =
      match result with
      | Error failure ->
        row [ "status", `String "provider_failed"; "failure", Client.failure_to_yojson failure ]
      | Ok evaluated ->
        row [ "status", `String "response_received"; "response", response_json evaluated ]
    in
    let used =
      match append t completion with
      | Error detail ->
        Log.Keeper.warn "memory recall response record unavailable request=%s: %s" request_id detail;
        Error Flow.Not_recorded
      | Ok _ ->
        result
        |> Result.map (fun (evaluated : Client.evaluated) -> evaluated.response)
        |> Result.map_error attempt_failure_of_client_failure
    in
    record_request t ~kind
      (match used with
       | Ok _ -> Answered
       | Error failure -> Attempt_failed failure);
    used

let evaluate ?clock t request =
  evaluate_with
    ~call:(fun ~destinations ~state ~questions () ->
      Client.evaluate ?clock ~destinations ~state ~questions ())
    t request

(* ---- the outcome ---- *)

let result_json = function
  | J.Decided { id; decision } ->
    `Assoc [ "id", `String id; "decision", `String (J.candidate_decision_label decision) ]
  | J.Undecided { id; reason } ->
    `Assoc [ "id", `String id; "reason", `String (J.unjudged_reason_token reason) ]

let mark_json (id, mark) =
  let token =
    match mark with
    | J.Marked nature -> J.time_nature_label nature
    | J.Time_unjudged -> "unjudged"
  in
  `Assoc [ "id", `String id; "mark", `String token ]

let turn_json = function
  | J.Turn_answered need -> `String (J.turn_need_label need)
  | J.Turn_question_failed -> `String "failed"

let status_json status =
  let coverage = J.status_coverage status in
  let common =
    [ "status", `String (J.status_token status)
    ; "judged", `Int (J.coverage_judged coverage)
    ; "total", `Int (J.coverage_total coverage)
    ]
  in
  match status with
  | J.Selected { selection; coverage = _; turn_question_contradicted } ->
    common
    @ [ "selected", `List (List.map (fun id -> `String id) (J.selection_ids selection))
      ; "turn_question_contradicted", `Bool turn_question_contradicted
      ]
  | J.None_found _ | J.None_needed _ -> common
  | J.Unavailable unavailable ->
    common @ [ "reason", `String (J.unavailable_reason_token unavailable) ]

let outcome_json (judged : Flow.judged) =
  `Assoc
    (status_json judged.status
     @ [ "turn", turn_json judged.turn
       ; "results", `List (List.map result_json judged.results)
       ; "marks", `List (List.map mark_json judged.marks)
       ])

let retain_outcome t (judged : Flow.judged) =
  let row =
    `Assoc
      (judgment_fields t
       @ [ "status", `String "judgment_completed"; "outcome", outcome_json judged ])
  in
  match append t row with
  | Ok _ -> judged
  | Error detail ->
    Log.Keeper.warn "memory recall outcome record unavailable judgment=%s: %s" t.judgment_id detail;
    Flow.not_recorded judged
