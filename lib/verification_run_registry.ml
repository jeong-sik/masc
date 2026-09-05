type infrastructure_stage =
  | Review_preparation
  | Lookup_surface

type outcome =
  | Approved of { reason : string }
  | Rejected of { reason : string }
  | Infrastructure_unavailable of
      { stage : infrastructure_stage
      ; detail : string
      }
  | Not_reviewed of
      { gate : string
      ; detail : string
      }
  | Commit_failed of { detail : string }
  | Raised of { detail : string }
  | Review_cancelled of { detail : string }
  | Operator_routed

type tool_observation =
  { tool_name : string
  ; input : Yojson.Safe.t
  ; disposition : (unit, unit, unit) Tool_result.disposition
  ; output_excerpt : string
  ; output_truncated : bool
  ; duration_ms : float
  ; finished_at : float
  }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      ; tools : tool_observation list
      }

type run =
  { verification_id : string
  ; task_id : string
  ; producer : string
  ; authority_kind : string
  ; authority_actor : string
  ; started_at : float
  ; status : run_status
  }

let tool_observation_to_yojson tool =
  `Assoc
    [ "tool_name", `String tool.tool_name
    ; "input", tool.input
    ; "disposition", `String (Tool_result.string_of_disposition tool.disposition)
    ; "output_excerpt", `String tool.output_excerpt
    ; "output_truncated", `Bool tool.output_truncated
    ; "duration_ms", `Float tool.duration_ms
    ; "finished_at", `Float tool.finished_at
    ]
;;

let tool_observation_of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = Run_registry_core.Json.object_fields json in
  let* () =
    Run_registry_core.Json.exact_fields
      ~required:
        [ "tool_name"
        ; "input"
        ; "disposition"
        ; "output_excerpt"
        ; "output_truncated"
        ; "duration_ms"
        ; "finished_at"
        ]
      fields
  in
  let* tool_name = Run_registry_core.Json.string_field "tool_name" fields in
  let* input =
    match List.assoc_opt "input" fields with
    | Some value -> Ok value
    | None -> Error "missing field input"
  in
  let* disposition_wire =
    Run_registry_core.Json.string_field "disposition" fields
  in
  let* disposition = Tool_result.unit_disposition_of_string disposition_wire in
  let* output_excerpt =
    Run_registry_core.Json.string_field "output_excerpt" fields
  in
  let* output_truncated =
    match List.assoc_opt "output_truncated" fields with
    | Some (`Bool value) -> Ok value
    | Some _ -> Error "field output_truncated must be a boolean"
    | None -> Error "missing field output_truncated"
  in
  let* duration_ms = Run_registry_core.Json.float_field "duration_ms" fields in
  let* finished_at = Run_registry_core.Json.float_field "finished_at" fields in
  Ok
    { tool_name
    ; input
    ; disposition
    ; output_excerpt
    ; output_truncated
    ; duration_ms
    ; finished_at
    }
;;

let outcome_label = function
  | Approved _ -> "approved"
  | Rejected _ -> "rejected"
  | Infrastructure_unavailable _ -> "infrastructure_unavailable"
  | Not_reviewed _ -> "not_reviewed"
  | Commit_failed _ -> "commit_failed"
  | Raised _ -> "raised"
  | Review_cancelled _ -> "review_cancelled"
  | Operator_routed -> "operator_routed"
;;

module Payload = struct
  let infrastructure_stage_to_string = function
    | Review_preparation -> "review_preparation"
    | Lookup_surface -> "lookup_surface"
  ;;

  let infrastructure_stage_of_string = function
    | "review_preparation" -> Ok Review_preparation
    | "lookup_surface" -> Ok Lookup_surface
    | value -> Error (Printf.sprintf "unknown infrastructure stage %S" value)
  ;;

  type registration =
    { task_id : string
    ; producer : string
    ; authority_kind : string
    ; authority_actor : string
    }

  type completion =
    { outcome : outcome
    ; evaluator_runtime : string option
    ; elapsed_s : float
    ; tools : tool_observation list
    }

  let name = "verification_run_registry"
  let running_noun = "review(s)"
  let restart_reason = "review fibers do not survive server restart"
  let replayed_running_completion = None
  (* Nothing here is large enough to be worth re-reading from disk: this
     registry's live share is under a megabyte. *)
  let shed_registration r = r
  let shed_completion c = c
  let completed_retention = `Latest 64
  let retention_group = None

  let registration_to_yojson registration =
    `Assoc
      [ "task_id", `String registration.task_id
      ; "producer", `String registration.producer
      ; "authority_kind", `String registration.authority_kind
      ; "authority_actor", `String registration.authority_actor
      ]
  ;;

  let registration_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:[ "task_id"; "producer"; "authority_kind"; "authority_actor" ]
        fields
    in
    let* task_id = Run_registry_core.Json.string_field "task_id" fields in
    let* producer = Run_registry_core.Json.string_field "producer" fields in
    let* authority_kind =
      Run_registry_core.Json.string_field "authority_kind" fields
    in
    let* authority_actor =
      Run_registry_core.Json.string_field "authority_actor" fields
    in
    Ok { task_id; producer; authority_kind; authority_actor }
  ;;

  let outcome_fields = function
    | Approved { reason } | Rejected { reason } -> [ "reason", `String reason ]
    | Commit_failed { detail }
    | Raised { detail }
    | Review_cancelled { detail } ->
      [ "detail", `String detail ]
    | Infrastructure_unavailable { stage; detail } ->
      [ "stage", `String (infrastructure_stage_to_string stage)
      ; "detail", `String detail
      ]
    | Not_reviewed { gate; detail } ->
      [ "gate", `String gate; "detail", `String detail ]
    | Operator_routed -> []
  ;;

  let completion_to_yojson completion =
    let fields =
      [ "outcome", `String (outcome_label completion.outcome)
      ; "elapsed_s", `Float completion.elapsed_s
      ; "tools", `List (List.map tool_observation_to_yojson completion.tools)
      ]
      @ outcome_fields completion.outcome
      @
      match completion.evaluator_runtime with
      | None -> []
      | Some runtime -> [ "evaluator_runtime", `String runtime ]
    in
    `Assoc fields
  ;;

  let completion_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* label = Run_registry_core.Json.string_field "outcome" fields in
    let required_detail_fields =
      match label with
      (* [reason] is optional here, not required: rows written before an
         approval carried one have no such field and must still read back. *)
      | "approved" -> Ok []
      | "rejected" -> Ok [ "reason" ]
      | "infrastructure_unavailable" -> Ok [ "stage"; "detail" ]
      | "commit_failed" | "raised" | "review_cancelled" -> Ok [ "detail" ]
      | "not_reviewed" -> Ok [ "gate"; "detail" ]
      | "operator_routed" -> Ok []
      | other -> Error (Printf.sprintf "unknown verification outcome %S" other)
    in
    let* required_detail_fields = required_detail_fields in
    let optional_detail_fields =
      match label with
      | "approved" -> [ "reason" ]
      | _ -> []
    in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:([ "outcome"; "elapsed_s"; "tools" ] @ required_detail_fields)
        ~optional:("evaluator_runtime" :: optional_detail_fields)
        fields
    in
    let* elapsed_s = Run_registry_core.Json.float_field "elapsed_s" fields in
    let* evaluator_runtime =
      Run_registry_core.Json.optional_string_field "evaluator_runtime" fields
    in
    let* tools_json =
      match List.assoc_opt "tools" fields with
      | Some (`List tools) -> Ok tools
      | Some _ -> Error "field tools must be an array"
      | None -> Error "missing field tools"
    in
    let rec parse_tools acc = function
      | [] -> Ok (List.rev acc)
      | tool :: rest ->
        let* tool = tool_observation_of_yojson tool in
        parse_tools (tool :: acc) rest
    in
    let* tools = parse_tools [] tools_json in
    let* outcome =
      match label with
      | "approved" ->
        let* reason =
          Run_registry_core.Json.optional_string_field "reason" fields
        in
        Ok (Approved { reason = Option.value reason ~default:"" })
      | "rejected" ->
        let* reason = Run_registry_core.Json.string_field "reason" fields in
        Ok (Rejected { reason })
      | "infrastructure_unavailable" ->
        let* stage = Run_registry_core.Json.string_field "stage" fields in
        let* stage = infrastructure_stage_of_string stage in
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Infrastructure_unavailable { stage; detail })
      | "not_reviewed" ->
        let* gate = Run_registry_core.Json.string_field "gate" fields in
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Not_reviewed { gate; detail })
      | "commit_failed" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Commit_failed { detail })
      | "raised" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Raised { detail })
      | "review_cancelled" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Review_cancelled { detail })
      | "operator_routed" -> Ok Operator_routed
      | other -> Error (Printf.sprintf "unknown verification outcome %S" other)
    in
    Ok { outcome; evaluator_runtime; elapsed_s; tools }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t = Store.t

let storage_filename = "verification-runs.jsonl"
let create = Store.create
let replay = Store.replay
let max_completed_retained = Store.max_completed_retained
let cut_replay_log = Store.cut_replay_log

let change_observer_fn : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let notify_changed () =
  try (Atomic.get change_observer_fn) () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Task.warn
      "verification_run_registry change observer failed: %s"
      (Printexc.to_string exn)
;;

let register_running
      t
      ~verification_id
      ~task_id
      ~producer
      ~authority_kind
      ~authority_actor
      ~started_at
  =
  Store.register
    t
    ~id:verification_id
    ~started_at
    ~registration:{ Payload.task_id; producer; authority_kind; authority_actor };
  notify_changed ()
;;

let mark_completed t ~verification_id ~outcome ~tools ?evaluator_runtime ~elapsed_s () =
  let completion = { Payload.outcome; evaluator_runtime; elapsed_s; tools } in
  match Store.complete t ~id:verification_id ~completion with
  | `Completed -> notify_changed ()
  | `Unknown -> ()
  | `Persistence_failed failure -> raise (Sys_error failure.detail)
;;

let observe_tool_result ~input ~finished_at (result : Tool_result.result) =
  let disposition =
    match result with
    | Tool_result.Completed _ -> Tool_result.Completed ()
    | Tool_result.Deferred _ -> Tool_result.Deferred ()
    | Tool_result.Failed _ -> Tool_result.Failed ()
  in
  let output_excerpt, output_truncated =
    let redacted = Tool_result.message result |> Observability_redact.redact_text in
    Keeper_text_processing.truncate_utf8_prefix
      ~max_bytes:1024
      redacted
  in
  { tool_name = Tool_result.tool_name result
  ; input =
      (input
       |> Observability_redact.redact_json_value
       |> Observability_redact.preview_json_strings ~max_len:512)
  ; disposition
  ; output_excerpt
  ; output_truncated
  ; duration_ms = Tool_result.duration_ms result
  ; finished_at
  }
;;

let run_of_entry (entry : Store.entry) =
  let status =
    match entry.status with
    | Store.Running -> Running
    | Store.Completed completion ->
      Completed
        { outcome = completion.outcome
        ; evaluator_runtime = completion.evaluator_runtime
        ; elapsed_s = completion.elapsed_s
        ; tools = completion.tools
        }
  in
  { verification_id = entry.id
  ; task_id = entry.registration.task_id
  ; producer = entry.registration.producer
  ; authority_kind = entry.registration.authority_kind
  ; authority_actor = entry.registration.authority_actor
  ; started_at = entry.started_at
  ; status
  }
;;

let list_runs t = List.map run_of_entry (Store.list_entries t)
let get t ~verification_id = Option.map run_of_entry (Store.get t ~id:verification_id)

let status_label = function
  | Running -> "running"
  | Completed { outcome; _ } -> outcome_label outcome
;;

let outcome_detail_fields = function
  | Approved { reason } | Rejected { reason } -> [ "reason", `String reason ]
  | Commit_failed { detail }
  | Raised { detail }
  | Review_cancelled { detail } ->
    [ "detail", `String detail ]
  | Infrastructure_unavailable { stage; detail } ->
    [ "stage", `String (Payload.infrastructure_stage_to_string stage)
    ; "detail", `String detail
    ]
  | Not_reviewed { gate; detail } ->
    [ "gate", `String gate; "detail", `String detail ]
  | Operator_routed -> []
;;

let run_to_yojson run =
  let base =
    [ "verification_id", `String run.verification_id
    ; "task_id", `String run.task_id
    ; "producer", `String run.producer
    ; "authority_kind", `String run.authority_kind
    ; "authority_actor", `String run.authority_actor
    ; "started_at", `Float run.started_at
    ; "status", `String (status_label run.status)
    ]
  in
  let completion_fields =
    match run.status with
    | Running -> []
    | Completed { outcome; evaluator_runtime; elapsed_s; tools } ->
      let tool_to_yojson tool =
        `Assoc
          [ "tool_name", `String tool.tool_name
          ; "input", tool.input
          ; "disposition", `String (Tool_result.string_of_disposition tool.disposition)
          ; "output_excerpt", `String tool.output_excerpt
          ; "output_truncated", `Bool tool.output_truncated
          ; "duration_ms", `Float tool.duration_ms
          ; "finished_at", `Float tool.finished_at
          ]
      in
      [ "elapsed_s", `Float elapsed_s
      ; "tools", `List (List.map tool_to_yojson tools)
      ]
      @ outcome_detail_fields outcome
      @
      (match evaluator_runtime with
       | None -> []
       | Some runtime -> [ "evaluator_runtime", `String runtime ])
  in
  `Assoc (base @ completion_fields)
;;

type global_install_error = Already_installed

module Global = Run_registry_core.Global (struct
    type nonrec t = t

    let initial = create ()
  end)

let global = Global.current

let install_global registry =
  match Global.install registry with
  | Ok () -> Ok ()
  | Error Global.Already_installed -> Error Already_installed
;;
