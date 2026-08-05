(* JSONL event type for verification run registry persistence (RFC-0361 D4).
   Each [register_running] / [mark_completed] appends one line so review history
   survives server restart.

   The outcome is a closed sum, not [ok : bool] + free text: RFC-0284 §E records
   that a judge which burned tokens must leave its cost in the observation
   record even when it failed, and a boolean cannot distinguish "the judge
   rejected" from "the judge never ran". Decoding is exhaustive — an unknown
   event kind or outcome label is [Error], never a permissive default. *)

type outcome =
  | Approved
  | Rejected of { reason : string }
  | Contract_rejected of { detail : string }
  | Not_reviewed of { gate : string; detail : string }
  | Commit_failed of { detail : string }
  | Raised of { detail : string }

type t =
  | Register of
      { verification_id : string
      ; task_id : string
      ; producer : string
      ; authority_kind : string
      ; authority_actor : string
      ; started_at : float
      }
  | Complete of
      { verification_id : string
      ; outcome : outcome
      ; evaluator_runtime : string option
      ; elapsed_s : float
      }

let outcome_label = function
  | Approved -> "approved"
  | Rejected _ -> "rejected"
  | Contract_rejected _ -> "contract_rejected"
  | Not_reviewed _ -> "not_reviewed"
  | Commit_failed _ -> "commit_failed"
  | Raised _ -> "raised"
;;

(* Per-constructor payload. [Approved] carries none; every failure shape carries
   the operator-readable detail that produced it, so a surface never shows a
   bare label with no cause. *)
let outcome_fields = function
  | Approved -> []
  | Rejected { reason } -> [ ("reason", `String reason) ]
  | Contract_rejected { detail } | Commit_failed { detail } | Raised { detail } ->
    [ ("detail", `String detail) ]
  | Not_reviewed { gate; detail } ->
    [ ("gate", `String gate); ("detail", `String detail) ]
;;

let to_yojson = function
  | Register
      { verification_id; task_id; producer; authority_kind; authority_actor; started_at }
    ->
    `Assoc
      [ ("event", `String "register")
      ; ("verification_id", `String verification_id)
      ; ("task_id", `String task_id)
      ; ("producer", `String producer)
      ; ("authority_kind", `String authority_kind)
      ; ("authority_actor", `String authority_actor)
      ; ("started_at", `Float started_at)
      ]
  | Complete { verification_id; outcome; evaluator_runtime; elapsed_s } ->
    let evaluator_fields =
      match evaluator_runtime with
      | None -> []
      | Some runtime -> [ ("evaluator_runtime", `String runtime) ]
    in
    `Assoc
      ([ ("event", `String "complete")
       ; ("verification_id", `String verification_id)
       ; ("outcome", `String (outcome_label outcome))
       ; ("elapsed_s", `Float elapsed_s)
       ]
       @ outcome_fields outcome
       @ evaluator_fields)
;;

let object_fields = function
  | `Assoc fields -> Ok fields
  | json -> Error (Printf.sprintf "expected object, got %s" (Yojson.Safe.to_string json))
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some json -> Ok json
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let string_field name fields =
  match field name fields with
  | Error _ as err -> err
  | Ok (`String value) -> Ok value
  | Ok json ->
    Error
      (Printf.sprintf
         "field %s expected string, got %s"
         name
         (Yojson.Safe.to_string json))
;;

let float_field name fields =
  match field name fields with
  | Error _ as err -> err
  | Ok (`Float value) -> Ok value
  | Ok (`Int value) -> Ok (float_of_int value)
  | Ok json ->
    Error
      (Printf.sprintf "field %s expected float, got %s" name (Yojson.Safe.to_string json))
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some json ->
    Error
      (Printf.sprintf
         "field %s expected optional string, got %s"
         name
         (Yojson.Safe.to_string json))
;;

let ( let* ) = Result.bind

let outcome_of_fields fields =
  let* label = string_field "outcome" fields in
  match label with
  | "approved" -> Ok Approved
  | "rejected" ->
    let* reason = string_field "reason" fields in
    Ok (Rejected { reason })
  | "contract_rejected" ->
    let* detail = string_field "detail" fields in
    Ok (Contract_rejected { detail })
  | "not_reviewed" ->
    let* gate = string_field "gate" fields in
    let* detail = string_field "detail" fields in
    Ok (Not_reviewed { gate; detail })
  | "commit_failed" ->
    let* detail = string_field "detail" fields in
    Ok (Commit_failed { detail })
  | "raised" ->
    let* detail = string_field "detail" fields in
    Ok (Raised { detail })
  | other -> Error (Printf.sprintf "unknown verification run outcome %S" other)
;;

let of_yojson json =
  let* fields = object_fields json in
  let* event = string_field "event" fields in
  match event with
  | "register" ->
    let* verification_id = string_field "verification_id" fields in
    let* task_id = string_field "task_id" fields in
    let* producer = string_field "producer" fields in
    let* authority_kind = string_field "authority_kind" fields in
    let* authority_actor = string_field "authority_actor" fields in
    let* started_at = float_field "started_at" fields in
    Ok
      (Register
         { verification_id
         ; task_id
         ; producer
         ; authority_kind
         ; authority_actor
         ; started_at
         })
  | "complete" ->
    let* verification_id = string_field "verification_id" fields in
    let* outcome = outcome_of_fields fields in
    let* evaluator_runtime = optional_string_field "evaluator_runtime" fields in
    let* elapsed_s = float_field "elapsed_s" fields in
    Ok (Complete { verification_id; outcome; evaluator_runtime; elapsed_s })
  | other -> Error (Printf.sprintf "unknown verification registry event %S" other)
;;

let to_jsonl t = Yojson.Safe.to_string (to_yojson t) ^ "\n"
