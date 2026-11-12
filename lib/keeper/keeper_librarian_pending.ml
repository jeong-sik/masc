open Result.Syntax

type worker_wait =
  | Capacity
  | Processing
  | Outcome_unknown
  | Unreachable
  | Missing_after_dispatch
  | Journal_recheck

type worker = { installation_id : string; request_id : string; wait : worker_wait }

type t =
  | Worker of worker
  | Publication of { request_id : string; detail : string }
  | Basis_changed of { request_id : string }
  | Message_floor of { request_id : string; detail : string }
  | Local_failure of string

type admission =
  | Admission_waiting of worker
  | Admission_failed of string

let admission_pending = function
  | Admission_waiting worker -> Worker worker
  | Admission_failed detail -> Local_failure detail

let admission_of_pending = function
  | Worker worker -> Ok (Admission_waiting worker)
  | Local_failure detail -> Ok (Admission_failed detail)
  | Publication _ | Basis_changed _ | Message_floor _ ->
    Error "admission observation must be a worker wait or a failed pass"

let of_worker_wait ~installation_id ~request_id wait =
  let wait = match wait with
    | Lane_addon_submit_once.Capacity -> Capacity
    | Worker_pending -> Processing
    | Worker_unknown -> Outcome_unknown
    | Worker_unreachable -> Unreachable
    | Missing_after_dispatch -> Missing_after_dispatch
    | Journal_recheck -> Journal_recheck in
  { installation_id; request_id; wait }

let worker_word = function
  | Capacity -> "capacity"
  | Processing -> "processing"
  | Outcome_unknown -> "outcome_unknown"
  | Unreachable -> "unreachable"
  | Missing_after_dispatch -> "missing_after_dispatch"
  | Journal_recheck -> "journal_recheck"

let worker_of_word = function
  | "capacity" -> Ok Capacity
  | "processing" -> Ok Processing
  | "outcome_unknown" -> Ok Outcome_unknown
  | "unreachable" -> Ok Unreachable
  | "missing_after_dispatch" -> Ok Missing_after_dispatch
  | "journal_recheck" -> Ok Journal_recheck
  | value -> Error ("unknown Librarian worker wait: " ^ value)

let to_json = function
  | Worker { installation_id; request_id; wait } ->
    `Assoc ["kind", `String "worker"; "request_id", `String request_id;
      "installation_id", `String installation_id; "wait", `String (worker_word wait)]
  | Publication { request_id; detail } ->
    `Assoc ["kind", `String "publication"; "request_id", `String request_id;
      "detail", `String detail]
  | Basis_changed { request_id } ->
    `Assoc ["kind", `String "basis_changed"; "request_id", `String request_id]
  | Message_floor { request_id; detail } ->
    `Assoc ["kind", `String "message_floor"; "request_id", `String request_id;
      "detail", `String detail]
  | Local_failure detail ->
    `Assoc ["kind", `String "local_failure"; "detail", `String detail]

let of_json json =
  let context = "Librarian pending observation" in
  let* fields = Candle_json.object_fields ~context json in
  let* kind, fields = Candle_json.field ~context "kind" Candle_json.as_string fields in
  let request fields = Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
  let detail fields = Candle_json.field ~context "detail" Candle_json.as_string fields in
  let* value, fields = match kind with
    | "worker" ->
      let* request_id, fields = request fields in
      let* installation_id, fields = Candle_json.field ~context "installation_id"
        Candle_json.as_non_blank fields in
      let* word, fields = Candle_json.field ~context "wait" Candle_json.as_string fields in
      let+ wait = worker_of_word word in Worker { installation_id; request_id; wait }, fields
    | "publication" ->
      let* request_id, fields = request fields in
      let+ detail, fields = detail fields in Publication { request_id; detail }, fields
    | "basis_changed" ->
      let+ request_id, fields = request fields in Basis_changed { request_id }, fields
    | "message_floor" ->
      let* request_id, fields = request fields in
      let+ detail, fields = detail fields in Message_floor { request_id; detail }, fields
    | "local_failure" ->
      let+ detail, fields = detail fields in Local_failure detail, fields
    | value -> Error ("unknown Librarian pending kind: " ^ value) in
  let+ () = Candle_json.finish ~context fields in value

let description = function
  | Worker { wait = Capacity; _ } ->
    "Worker request listing is full; waiting for admitted requests to finish"
  | Worker { wait = Processing; _ } -> "Waiting for the original worker result"
  | Worker { wait = Outcome_unknown; _ } ->
    "Original dispatch outcome is unconfirmed; reobserve the same request"
  | Worker { wait = Unreachable; _ } -> "Original worker is unavailable"
  | Worker { wait = Missing_after_dispatch; _ } ->
    "Worker has no record after dispatch; outcome review is required before any replay"
  | Worker { wait = Journal_recheck; _ } -> "Rechecking the original dispatch journal"
  | Publication { detail; _ } -> "Original publication is unfinished: " ^ detail
  | Basis_changed _ -> "Memory changed; waiting for the next source selection"
  | Message_floor { detail; _ } -> "Original message-floor work is unfinished: " ^ detail
  | Local_failure detail -> "Local recovery failed: " ^ detail

let needs_attention = function
  | Worker { wait = (Outcome_unknown | Missing_after_dispatch); _ }
  | Local_failure _ -> true
  | Worker { wait = (Capacity | Processing | Unreachable | Journal_recheck); _ }
  | Publication _ | Basis_changed _ | Message_floor _ -> false

let admission_description = function
  | Admission_waiting worker -> description (Worker worker)
  | Admission_failed detail -> "Explicit admission pass failed: " ^ detail

let attention_required ~durable ~admission =
  Option.exists needs_attention durable
  || Option.exists (fun admission -> needs_attention (admission_pending admission)) admission
