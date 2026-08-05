type outcome =
  | Approved
  | Rejected of { reason : string }
  | Contract_rejected of { detail : string }
  | Not_reviewed of
      { gate : string
      ; detail : string
      }
  | Commit_failed of { detail : string }
  | Raised of { detail : string }

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
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

let outcome_label = function
  | Approved -> "approved"
  | Rejected _ -> "rejected"
  | Contract_rejected _ -> "contract_rejected"
  | Not_reviewed _ -> "not_reviewed"
  | Commit_failed _ -> "commit_failed"
  | Raised _ -> "raised"
;;

module Payload = struct
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
    }

  let name = "verification_run_registry"
  let running_noun = "review(s)"
  let restart_reason = "review fibers do not survive server restart"

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
    | Approved -> []
    | Rejected { reason } -> [ "reason", `String reason ]
    | Contract_rejected { detail } | Commit_failed { detail } | Raised { detail } ->
      [ "detail", `String detail ]
    | Not_reviewed { gate; detail } ->
      [ "gate", `String gate; "detail", `String detail ]
  ;;

  let completion_to_yojson completion =
    let fields =
      [ "outcome", `String (outcome_label completion.outcome)
      ; "elapsed_s", `Float completion.elapsed_s
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
      | "approved" -> Ok []
      | "rejected" -> Ok [ "reason" ]
      | "contract_rejected" | "commit_failed" | "raised" -> Ok [ "detail" ]
      | "not_reviewed" -> Ok [ "gate"; "detail" ]
      | other -> Error (Printf.sprintf "unknown verification outcome %S" other)
    in
    let* required_detail_fields = required_detail_fields in
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:([ "outcome"; "elapsed_s" ] @ required_detail_fields)
        ~optional:[ "evaluator_runtime" ]
        fields
    in
    let* elapsed_s = Run_registry_core.Json.float_field "elapsed_s" fields in
    let* evaluator_runtime =
      Run_registry_core.Json.optional_string_field "evaluator_runtime" fields
    in
    let* outcome =
      match label with
      | "approved" -> Ok Approved
      | "rejected" ->
        let* reason = Run_registry_core.Json.string_field "reason" fields in
        Ok (Rejected { reason })
      | "contract_rejected" ->
        let* detail = Run_registry_core.Json.string_field "detail" fields in
        Ok (Contract_rejected { detail })
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
      | other -> Error (Printf.sprintf "unknown verification outcome %S" other)
    in
    Ok { outcome; evaluator_runtime; elapsed_s }
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t = Store.t

let create = Store.create
let replay = Store.replay
let max_completed_retained = Store.max_completed_retained

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
    ~registration:{ Payload.task_id; producer; authority_kind; authority_actor }
;;

let mark_completed t ~verification_id ~outcome ?evaluator_runtime ~elapsed_s () =
  let completion = { Payload.outcome; evaluator_runtime; elapsed_s } in
  ignore
    (Store.complete t ~id:verification_id ~completion
      : [ `Completed | `Unknown ])
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
  | Approved -> []
  | Rejected { reason } -> [ "reason", `String reason ]
  | Contract_rejected { detail } | Commit_failed { detail } | Raised { detail } ->
    [ "detail", `String detail ]
  | Not_reviewed { gate; detail } ->
    [ "gate", `String gate; "detail", `String detail ]
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
    | Completed { outcome; evaluator_runtime; elapsed_s } ->
      [ "elapsed_s", `Float elapsed_s ]
      @ outcome_detail_fields outcome
      @
      (match evaluator_runtime with
       | None -> []
       | Some runtime -> [ "evaluator_runtime", `String runtime ])
  in
  `Assoc (base @ completion_fields)
;;

let global_atomic : t Atomic.t = Atomic.make (create ())
let global () = Atomic.get global_atomic
let set_global registry = Atomic.set global_atomic registry
