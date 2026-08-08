(** Sessions type definitions — pure data structures with no logic.

    Separated from sessions.ml to reduce file size and clarify the
    boundary between data definitions and operations. All types here
    carry [@@deriving yojson, show] for serialisation round-tripping. *)

type trace_capability =
  | Raw [@name "raw"]
  | Summary_only [@name "summary_only"]
  | No_trace [@name "none"]
[@@deriving yojson, show]

type session_info =
  { session_id : string
  ; title : string option
  ; tag : string option
  ; goal : string
  ; updated_at : float
  ; phase : Runtime.phase
  ; participant_count : int
  ; path : string
  }
[@@deriving yojson, show]

type telemetry_event_count =
  { name : string
  ; count : int
  }
[@@deriving yojson, show]

type telemetry_step =
  { seq : int
  ; ts : float
  ; kind : string
  ; participant : string option
  ; detail : string option
  }
[@@deriving yojson, show]

type telemetry =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : telemetry_event_count list
  ; steps : telemetry_step list
  }
[@@deriving yojson, show]

type structured_event_count =
  { event_name : string
  ; count : int
  }
[@@deriving yojson, show]

type structured_telemetry_step =
  { seq : int
  ; ts : float
  ; event_name : string
  ; participant : string option
  ; detail : string option
  ; actor : string option
  ; role : string option
  ; provider : string option
  ; model : string option
  ; raw_trace_run_id : string option
  ; stop_reason : string option
  ; artifact_id : string option
  ; artifact_name : string option
  ; artifact_kind : string option
  ; checkpoint_label : string option
  ; outcome : string option
  ; dropped_output_deltas : int option
  ; persistence_failure_phase : string option
  }
[@@deriving yojson, show]

type structured_telemetry =
  { session_id : string
  ; generated_at : float
  ; step_count : int
  ; event_counts : structured_event_count list
  ; steps : structured_telemetry_step list
  }
[@@deriving yojson, show]

type evidence_file =
  { label : string
  ; path : string
  ; size_bytes : int
  ; md5 : string
  }
[@@deriving yojson, show]

type missing_file =
  { label : string
  ; path : string
  }
[@@deriving yojson, show]

type evidence =
  { session_id : string
  ; generated_at : float
  ; files : evidence_file list
  ; missing_files : missing_file list
  }
[@@deriving yojson, show]

type hook_summary =
  { hook_name : string
  ; count : int
  ; latest_decision : string option
  ; latest_detail : string option
  ; latest_ts : float option
  }
[@@deriving yojson, show]

type tool_contract =
  { name : string
  ; description : string
  ; origin : string option
  ; execution_mode : Tool_contract.execution_mode
  ; completion : Tool_contract.completion
  }
[@@deriving show]

let tool_contract_to_yojson contract =
  `Assoc
    [ "name", `String contract.name
    ; "description", `String contract.description
    ; ( "origin"
      , match contract.origin with
        | Some origin -> `String origin
        | None -> `Null )
    ; "execution_mode", Tool_contract.execution_mode_to_yojson contract.execution_mode
    ; "completion", Tool_contract.completion_to_yojson contract.completion
    ]
;;

let tool_contract_of_yojson json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let allowed = [ "name"; "description"; "origin"; "execution_mode"; "completion" ] in
    let rec validate_names seen = function
      | [] -> Ok ()
      | (name, _) :: _ when not (List.mem name allowed) ->
        Error (Printf.sprintf "tool contract field %S is not supported" name)
      | (name, _) :: _ when List.mem name seen ->
        Error (Printf.sprintf "tool contract field %S is duplicated" name)
      | (name, _) :: rest -> validate_names (name :: seen) rest
    in
    let required_string name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Ok value
      | Some value ->
        Error
          (Printf.sprintf
             "tool contract field %S must be a string, got %s"
             name
             (Yojson.Safe.to_string value))
      | None -> Error (Printf.sprintf "tool contract field %S is required" name)
    in
    let* () = validate_names [] fields in
    let* name = required_string "name" in
    let* description = required_string "description" in
    let* origin =
      match List.assoc_opt "origin" fields with
      | Some (`String value) -> Ok (Some value)
      | Some `Null -> Ok None
      | Some value ->
        Error
          (Printf.sprintf
             "tool contract field %S must be a string or null, got %s"
             "origin"
             (Yojson.Safe.to_string value))
      | None -> Error "tool contract field \"origin\" is required"
    in
    let* execution_mode =
      match List.assoc_opt "execution_mode" fields with
      | Some value -> Tool_contract.execution_mode_of_yojson value
      | None -> Error "tool contract field \"execution_mode\" is required"
    in
    let* completion =
      match List.assoc_opt "completion" fields with
      | Some value -> Tool_contract.completion_of_yojson value
      | None -> Error "tool contract field \"completion\" is required"
    in
    Ok { name; description; origin; execution_mode; completion }
  | value ->
    Error
      (Printf.sprintf
         "tool contract must be an object, got %s"
         (Yojson.Safe.to_string value))
;;

type raw_trace_run = Raw_trace.run_ref [@@deriving yojson, show]
type raw_trace_summary = Raw_trace.run_summary [@@deriving yojson, show]
type raw_trace_validation = Raw_trace.run_validation [@@deriving yojson, show]

type raw_trace_manifest =
  { session_id : string
  ; generated_at : float
  ; latest_raw_trace_run : raw_trace_run option
  ; raw_trace_runs : raw_trace_run list
  ; raw_trace_summaries : raw_trace_summary list
  ; raw_trace_validations : raw_trace_validation list
  }
[@@deriving yojson, show]

type worker_status =
  | Planned [@name "planned"]
  | Accepted [@name "accepted"]
  | Ready [@name "ready"]
  | Running [@name "running"]
  | Completed [@name "completed"]
  | Failed [@name "failed"]
[@@deriving yojson, show]

type worker_run =
  { worker_run_id : string
  ; worker_id : string option
  ; agent_name : string
  ; runtime_actor : string option
  ; role : string option
  ; aliases : string list
  ; primary_alias : string option
  ; provider : string option
  ; model : string option
  ; requested_provider : string option
  ; requested_model : string option
  ; resolved_provider : string option
  ; resolved_model : string option
  ; status : worker_status
  ; trace_capability : trace_capability
  ; validated : bool
  ; tool_names : string list
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  ; failure_reason : string option
  ; accepted_at : float option
  ; ready_at : float option
  ; first_progress_at : float option
  ; started_at : float option
  ; finished_at : float option
  ; last_progress_at : float option
  ; paired_tool_result_count : int
  }
[@@deriving yojson, show]

type evidence_capabilities =
  { raw_trace : bool
  ; validated_summary : bool
  ; proof_bundle : bool
  }
[@@deriving yojson, show]

type proof_bundle =
  { session : Runtime.session
  ; report : Runtime.report
  ; proof : Runtime.proof
  ; telemetry : telemetry
  ; structured_telemetry : structured_telemetry
  ; evidence : evidence
  ; hook_summary : hook_summary list
  ; tool_catalog : tool_contract list
  ; latest_raw_trace_run : raw_trace_run option
  ; raw_trace_runs : raw_trace_run list
  ; raw_trace_summaries : raw_trace_summary list
  ; raw_trace_validations : raw_trace_validation list
  ; worker_runs : worker_run list
  ; latest_accepted_worker_run : worker_run option
  ; latest_ready_worker_run : worker_run option
  ; latest_running_worker_run : worker_run option
  ; latest_worker_run : worker_run option
  ; latest_completed_worker_run : worker_run option
  ; latest_validated_worker_run : worker_run option
  ; latest_failed_worker_run : worker_run option
  ; validated_worker_runs : worker_run list
  ; raw_trace_run_count : int
  ; validated_worker_run_count : int
  ; trace_capabilities : trace_capability list
  ; capabilities : evidence_capabilities
  }
[@@deriving yojson, show]

[@@@coverage off]
(* === Inline tests === *)

(* -- trace_capability round-trip -- *)
let%test "trace_capability Raw round-trip" =
  trace_capability_of_yojson (trace_capability_to_yojson Raw) = Ok Raw
;;

let%test "trace_capability Summary_only round-trip" =
  trace_capability_of_yojson (trace_capability_to_yojson Summary_only) = Ok Summary_only
;;

let%test "trace_capability No_trace round-trip" =
  trace_capability_of_yojson (trace_capability_to_yojson No_trace) = Ok No_trace
;;

let%test "trace_capability invalid string" =
  match trace_capability_of_yojson (`String "invalid_value") with
  | Error _ -> true
  | Ok _ -> false
;;

(* -- worker_status round-trip -- *)
let%test "worker_status Planned round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Planned) = Ok Planned
;;

let%test "worker_status Accepted round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Accepted) = Ok Accepted
;;

let%test "worker_status Ready round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Ready) = Ok Ready
;;

let%test "worker_status Running round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Running) = Ok Running
;;

let%test "worker_status Completed round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Completed) = Ok Completed
;;

let%test "worker_status Failed round-trip" =
  worker_status_of_yojson (worker_status_to_yojson Failed) = Ok Failed
;;

let%test "worker_status invalid string" =
  match worker_status_of_yojson (`String "bogus") with
  | Error _ -> true
  | Ok _ -> false
;;

(* -- session_info round-trip -- *)
let%test "session_info yojson round-trip" =
  let v : session_info =
    { session_id = "sid"
    ; title = Some "t"
    ; tag = Some "tg"
    ; goal = "g"
    ; updated_at = 1.0
    ; phase = Runtime.Running
    ; participant_count = 2
    ; path = "/p"
    }
  in
  session_info_of_yojson (session_info_to_yojson v) = Ok v
;;

let%test "session_info with None optionals" =
  let v : session_info =
    { session_id = "s"
    ; title = None
    ; tag = None
    ; goal = "g"
    ; updated_at = 0.0
    ; phase = Runtime.Completed
    ; participant_count = 0
    ; path = "/x"
    }
  in
  session_info_of_yojson (session_info_to_yojson v) = Ok v
;;

(* -- telemetry_event_count round-trip -- *)
let%test "telemetry_event_count round-trip" =
  let v : telemetry_event_count = { name = "evt"; count = 5 } in
  telemetry_event_count_of_yojson (telemetry_event_count_to_yojson v) = Ok v
;;

(* -- telemetry_step round-trip -- *)
let%test "telemetry_step round-trip" =
  let v : telemetry_step =
    { seq = 1; ts = 2.0; kind = "k"; participant = Some "p"; detail = None }
  in
  telemetry_step_of_yojson (telemetry_step_to_yojson v) = Ok v
;;

(* -- structured_event_count round-trip -- *)
let%test "structured_event_count round-trip" =
  let v : structured_event_count = { event_name = "e"; count = 3 } in
  structured_event_count_of_yojson (structured_event_count_to_yojson v) = Ok v
;;

(* -- structured_telemetry_step round-trip -- *)
let%test "structured_telemetry_step round-trip" =
  let v : structured_telemetry_step =
    { seq = 1
    ; ts = 1.0
    ; event_name = "en"
    ; participant = None
    ; detail = None
    ; actor = None
    ; role = None
    ; provider = None
    ; model = None
    ; raw_trace_run_id = None
    ; stop_reason = None
    ; artifact_id = None
    ; artifact_name = None
    ; artifact_kind = None
    ; checkpoint_label = None
    ; outcome = None
    ; dropped_output_deltas = None
    ; persistence_failure_phase = None
    }
  in
  structured_telemetry_step_of_yojson (structured_telemetry_step_to_yojson v) = Ok v
;;

(* -- evidence_file round-trip -- *)
let%test "evidence_file round-trip" =
  let v : evidence_file = { label = "l"; path = "/p"; size_bytes = 42; md5 = "abc" } in
  evidence_file_of_yojson (evidence_file_to_yojson v) = Ok v
;;

(* -- missing_file round-trip -- *)
let%test "missing_file round-trip" =
  let v : missing_file = { label = "l"; path = "/m" } in
  missing_file_of_yojson (missing_file_to_yojson v) = Ok v
;;

(* -- hook_summary round-trip -- *)
let%test "hook_summary round-trip" =
  let v : hook_summary =
    { hook_name = "h"
    ; count = 1
    ; latest_decision = Some "d"
    ; latest_detail = None
    ; latest_ts = Some 1.5
    }
  in
  hook_summary_of_yojson (hook_summary_to_yojson v) = Ok v
;;

(* -- evidence_capabilities round-trip -- *)
let%test "evidence_capabilities round-trip" =
  let v : evidence_capabilities =
    { raw_trace = true; validated_summary = false; proof_bundle = true }
  in
  evidence_capabilities_of_yojson (evidence_capabilities_to_yojson v) = Ok v
;;

(* -- show functions produce non-empty strings -- *)
let%test "show_trace_capability non-empty" = String.length (show_trace_capability Raw) > 0
let%test "show_worker_status non-empty" = String.length (show_worker_status Completed) > 0

let%test "show_session_info non-empty" =
  let v : session_info =
    { session_id = "s"
    ; title = None
    ; tag = None
    ; goal = "g"
    ; updated_at = 0.0
    ; phase = Runtime.Bootstrapping
    ; participant_count = 0
    ; path = "/"
    }
  in
  String.length (show_session_info v) > 0
;;

let%test "show_telemetry_event_count non-empty" =
  String.length (show_telemetry_event_count { name = "x"; count = 0 }) > 0
;;

let%test "show_evidence_file non-empty" =
  String.length (show_evidence_file { label = "l"; path = "p"; size_bytes = 0; md5 = "" })
  > 0
;;

let%test "show_missing_file non-empty" =
  String.length (show_missing_file { label = "l"; path = "p" }) > 0
;;

(* -- tool_contract round-trip -- *)
let%test "tool_contract round-trip" =
  let v : tool_contract =
    { name = "t"
    ; description = "d"
    ; origin = Some "o"
    ; execution_mode = Tool_contract.Concurrent
    ; completion = Tool_contract.Continue_after_success
    }
  in
  tool_contract_of_yojson (tool_contract_to_yojson v) = Ok v
;;

(* -- worker_run round-trip -- *)
let%test "worker_run minimal round-trip" =
  let v : worker_run =
    { worker_run_id = "wid"
    ; worker_id = None
    ; agent_name = "a"
    ; runtime_actor = None
    ; role = None
    ; aliases = []
    ; primary_alias = None
    ; provider = None
    ; model = None
    ; requested_provider = None
    ; requested_model = None
    ; resolved_provider = None
    ; resolved_model = None
    ; status = Planned
    ; trace_capability = No_trace
    ; validated = false
    ; tool_names = []
    ; final_text = None
    ; stop_reason = None
    ; error = None
    ; failure_reason = None
    ; accepted_at = None
    ; ready_at = None
    ; first_progress_at = None
    ; started_at = None
    ; finished_at = None
    ; last_progress_at = None
    ; paired_tool_result_count = 0
    }
  in
  worker_run_of_yojson (worker_run_to_yojson v) = Ok v
;;
