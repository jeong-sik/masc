open Keeper_cache_outcome

let schema = "masc.keeper-cache-outcome.v1"

(* The JSON names of a reading. [to_json] writes them and [of_json] reads
   them back. *)
let schema_key = "schema"
let keeper_key = "keeper"
let turn_ref_key = "turn_ref"
let unattributed_rows_key = "unattributed_rows"
let outcome_key = "outcome"
let kind_key = "kind"
let request_key = "request"
let detail_key = "detail"
let runtime_id_key = "runtime_id"
let scope_key = "scope"
let ended_at_key = "ended_at"
let latency_ms_key = "latency_ms"
let cache_read_tokens_key = "cache_read_tokens"
let cache_creation_tokens_key = "cache_creation_tokens"
let cache_write_lifetime_key = "cache_write_lifetime"
let other_runtime_since_key = "other_runtime_since"
let earlier_key = "earlier"
let horizon_s_key = "horizon_s"
let idle_key = "idle"
let idle_s_key = "idle_s"
let lifetime_key = "lifetime"
let lifetime_s_key = "lifetime_s"
let check_key = "check"
let reason_key = "reason"
let prefix_key = "prefix"
let system_changed_key = "system_changed"
let tools_changed_key = "tools_changed"
let messages_key = "messages"
let runtime_profile_key = "runtime_profile"

(* A tagged object names its constructor under [kind_key]. Each variant has
   a closed list of kinds, so a new constructor does not compile until the
   writer and the reader below both name it. *)

type outcome_kind =
  | Turn_not_in_ledger_kind
  | Ledger_row_unreadable_kind
  | Not_per_request_kind
  | First_request_kind
[@@deriving enumerate]

let kind_of_outcome = function
  | Turn_not_in_ledger -> Turn_not_in_ledger_kind
  | Ledger_row_unreadable _ -> Ledger_row_unreadable_kind
  | Not_per_request _ -> Not_per_request_kind
  | First_request _ -> First_request_kind
;;

let outcome_kind_label = function
  | Turn_not_in_ledger_kind -> "turn_not_in_ledger"
  | Ledger_row_unreadable_kind -> "ledger_row_unreadable"
  | Not_per_request_kind -> "not_per_request"
  | First_request_kind -> "first_request"
;;

type earlier_kind =
  | None_within_kind
  | Earlier_kind
[@@deriving enumerate]

let kind_of_earlier = function
  | No_earlier_request _ -> None_within_kind
  | Earlier _ -> Earlier_kind
;;

let earlier_kind_label = function
  | None_within_kind -> "none_within"
  | Earlier_kind -> "earlier"
;;

type idle_kind =
  | Start_unrecorded_kind
  | Idle_kind
[@@deriving enumerate]

let kind_of_idle = function
  | Start_unrecorded -> Start_unrecorded_kind
  | Idle _ -> Idle_kind
;;

let idle_kind_label = function
  | Start_unrecorded_kind -> "start_unrecorded"
  | Idle_kind -> "idle"
;;

type lifetime_kind =
  | Unrecorded_kind
  | Provider_default_unknown_kind
  | Declared_kind
[@@deriving enumerate]

let kind_of_lifetime = function
  | Lifetime_unrecorded -> Unrecorded_kind
  | Provider_default_unknown _ -> Provider_default_unknown_kind
  | Lifetime_declared _ -> Declared_kind
;;

let lifetime_kind_label = function
  | Unrecorded_kind -> "unrecorded"
  | Provider_default_unknown_kind -> "provider_default_unknown"
  | Declared_kind -> "declared"
;;

type prefix_kind =
  | Compared_kind
  | Not_compared_kind
[@@deriving enumerate]

let kind_of_prefix = function
  | Compared _ -> Compared_kind
  | Not_compared _ -> Not_compared_kind
;;

let prefix_kind_label = function
  | Compared_kind -> "compared"
  | Not_compared_kind -> "not_compared"
;;

type not_compared_kind =
  | Earlier_turn_not_settled_kind
  | Snapshot_unread_kind
  | Snapshot_of_other_runtime_kind
[@@deriving enumerate]

let kind_of_not_compared = function
  | Earlier_turn_not_settled -> Earlier_turn_not_settled_kind
  | Snapshot_unread _ -> Snapshot_unread_kind
  | Snapshot_of_other_runtime _ -> Snapshot_of_other_runtime_kind
;;

let not_compared_kind_label = function
  | Earlier_turn_not_settled_kind -> "earlier_turn_not_settled"
  | Snapshot_unread_kind -> "snapshot_unread"
  | Snapshot_of_other_runtime_kind -> "snapshot_of_other_runtime"
;;

let lifetime_check_label = function
  | Outlived -> "outlived"
  | Within -> "within"
  | Undecided -> "undecided"
;;

let default_unknown_label = function
  | Default_undeclared -> "undeclared"
  | Runtime_inactive -> "runtime_inactive"
;;

let tagged label kind (fields : (string * Yojson.Safe.t) list) : Yojson.Safe.t =
  `Assoc ((kind_key, `String (label kind)) :: fields)
;;

let turn_ref_json turn_ref : Yojson.Safe.t = `String (Ids.Turn_ref.to_string turn_ref)

let optional (to_json : 'a -> Yojson.Safe.t) : 'a option -> Yojson.Safe.t = function
  | Some value -> to_json value
  | None -> `Null
;;

let request_to_json (request : request) : Yojson.Safe.t =
  `Assoc
    [ turn_ref_key, turn_ref_json request.turn_ref
    ; runtime_id_key, `String request.runtime_id
    ; scope_key, `String (Runtime_usage_scope.to_string request.scope)
    ; ended_at_key, `Float request.ended_at
    ; latency_ms_key, optional (fun ms -> `Int ms) request.latency_ms
    ; cache_read_tokens_key, optional (fun count -> `Int count) request.cache_read_tokens
    ; ( cache_creation_tokens_key
      , optional (fun count -> `Int count) request.cache_creation_tokens )
    ; ( cache_write_lifetime_key
      , optional
          (fun lifetime ->
             `String (Agent_core.Types.cache_write_lifetime_to_string lifetime))
          request.lifetime )
    ]
;;

let lifetime_to_json lifetime =
  tagged
    lifetime_kind_label
    (kind_of_lifetime lifetime)
    (match lifetime with
     | Lifetime_unrecorded -> []
     | Provider_default_unknown unknown ->
       [ reason_key, `String (default_unknown_label unknown) ]
     | Lifetime_declared { lifetime_s; check } ->
       [ lifetime_s_key, `Float lifetime_s
       ; check_key, `String (lifetime_check_label check)
       ])
;;

let idle_to_json idle =
  tagged
    idle_kind_label
    (kind_of_idle idle)
    (match idle with
     | Start_unrecorded -> []
     | Idle { idle_s; lifetime } ->
       [ idle_s_key, `Float idle_s; lifetime_key, lifetime_to_json lifetime ])
;;

let not_compared_to_json reason =
  tagged
    not_compared_kind_label
    (kind_of_not_compared reason)
    (match reason with
     | Earlier_turn_not_settled -> []
     | Snapshot_unread { turn_ref; detail } ->
       [ turn_ref_key, turn_ref_json turn_ref; detail_key, `String detail ]
     | Snapshot_of_other_runtime { turn_ref; runtime_profile } ->
       [ turn_ref_key, turn_ref_json turn_ref
       ; runtime_profile_key, `String runtime_profile
       ])
;;

let prefix_to_json prefix =
  tagged
    prefix_kind_label
    (kind_of_prefix prefix)
    (match prefix with
     | Compared { system_changed; tools_changed; messages } ->
       [ system_changed_key, `Bool system_changed
       ; tools_changed_key, `Bool tools_changed
       ; messages_key, Keeper_projection_change.message_change_to_json messages
       ]
     | Not_compared reason -> [ reason_key, not_compared_to_json reason ])
;;

let earlier_to_json earlier =
  tagged
    earlier_kind_label
    (kind_of_earlier earlier)
    (match earlier with
     | No_earlier_request { horizon_s } -> [ horizon_s_key, `Float horizon_s ]
     | Earlier { request; idle; prefix } ->
       [ request_key, request_to_json request
       ; idle_key, idle_to_json idle
       ; prefix_key, prefix_to_json prefix
       ])
;;

let outcome_to_json outcome =
  tagged
    outcome_kind_label
    (kind_of_outcome outcome)
    (match outcome with
     | Turn_not_in_ledger -> []
     | Ledger_row_unreadable detail -> [ detail_key, `String detail ]
     | Not_per_request request -> [ request_key, request_to_json request ]
     | First_request { request; other_runtime_since; earlier } ->
       [ request_key, request_to_json request
       ; ( other_runtime_since_key
         , optional (fun runtime_id -> `String runtime_id) other_runtime_since )
       ; earlier_key, earlier_to_json earlier
       ])
;;

let to_json (reading : reading) : Yojson.Safe.t =
  `Assoc
    [ schema_key, `String schema
    ; keeper_key, `String reading.keeper
    ; turn_ref_key, turn_ref_json reading.turn_ref
    ; unattributed_rows_key, `Int reading.unattributed_rows
    ; outcome_key, outcome_to_json reading.outcome
    ]
;;

let ( let* ) = Result.bind

let invalid key expected =
  Error (Printf.sprintf "cache outcome field %s must be %s" key expected)
;;

let object_fields key : Yojson.Safe.t -> ((string * Yojson.Safe.t) list, string) result
  = function
  | `Assoc fields -> Ok fields
  | _ -> invalid key "a JSON object"
;;

let member fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "cache outcome has no %s field" key)
;;

let string_member fields key =
  let* value = member fields key in
  match value with
  | `String text -> Ok text
  | _ -> invalid key "a string"
;;

let float_member fields key =
  let* value = member fields key in
  match value with
  | `Float number -> Ok number
  | _ -> invalid key "a number"
;;

let bool_member fields key =
  let* value = member fields key in
  match value with
  | `Bool flag -> Ok flag
  | _ -> invalid key "a boolean"
;;

let count_member fields key =
  let* value = member fields key in
  match value with
  | `Int count when count >= 0 -> Ok count
  | _ -> invalid key "a non-negative integer"
;;

let optional_member fields key read =
  let* value = member fields key in
  match value with
  | `Null -> Ok None
  | value -> Result.map Option.some (read value)
;;

let turn_ref_member fields key =
  let* text = string_member fields key in
  match Ids.Turn_ref.of_string text with
  | Some turn_ref -> Ok turn_ref
  | None -> invalid key "a turn reference"
;;

(* The one of [values] that [label] writes as the field's text. *)
let label_member fields key ~label values =
  let* text = string_member fields key in
  match List.find_opt (fun value -> String.equal (label value) text) values with
  | Some value -> Ok value
  | None -> invalid key (Printf.sprintf "a known label, not %S" text)
;;

(* Reads the object under [key]: its kind, then [read kind] its fields. *)
let tagged_member fields key ~label kinds read =
  let* value = member fields key in
  let* tagged_fields = object_fields key value in
  let* kind = label_member tagged_fields kind_key ~label kinds in
  read kind tagged_fields
;;

let request_member fields key =
  let* value = member fields key in
  let* fields = object_fields key value in
  let* turn_ref = turn_ref_member fields turn_ref_key in
  let* runtime_id = string_member fields runtime_id_key in
  let* scope =
    let* label = string_member fields scope_key in
    match Runtime_usage_scope.of_string label with
    | Some scope -> Ok scope
    | None -> invalid scope_key "a usage scope"
  in
  let* ended_at = float_member fields ended_at_key in
  let* latency_ms =
    optional_member fields latency_ms_key (function
      | `Int latency_ms when latency_ms > 0 -> Ok latency_ms
      | _ -> invalid latency_ms_key "a positive integer or null")
  in
  let count key =
    optional_member fields key (function
      | `Int count when count >= 0 -> Ok count
      | _ -> invalid key "a non-negative integer or null")
  in
  let* cache_read_tokens = count cache_read_tokens_key in
  let* cache_creation_tokens = count cache_creation_tokens_key in
  let* lifetime =
    optional_member fields cache_write_lifetime_key (function
      | `String label ->
        (match Agent_core.Types.cache_write_lifetime_of_string label with
         | Some lifetime -> Ok lifetime
         | None -> invalid cache_write_lifetime_key "a known lifetime label or null")
      | _ -> invalid cache_write_lifetime_key "a string or null")
  in
  Ok
    ({ turn_ref
     ; runtime_id
     ; scope
     ; ended_at
     ; latency_ms
     ; cache_read_tokens
     ; cache_creation_tokens
     ; lifetime
     }
     : request)
;;

let lifetime_member fields key =
  tagged_member
    fields
    key
    ~label:lifetime_kind_label
    all_of_lifetime_kind
    (fun kind fields ->
       match kind with
       | Unrecorded_kind -> Ok Lifetime_unrecorded
       | Provider_default_unknown_kind ->
         let* unknown =
           label_member
             fields
             reason_key
             ~label:default_unknown_label
             all_of_default_unknown
         in
         Ok (Provider_default_unknown unknown)
       | Declared_kind ->
         let* lifetime_s = float_member fields lifetime_s_key in
         let* check =
           label_member fields check_key ~label:lifetime_check_label all_of_lifetime_check
         in
         Ok (Lifetime_declared { lifetime_s; check }))
;;

let idle_member fields key =
  tagged_member
    fields
    key
    ~label:idle_kind_label
    all_of_idle_kind
    (fun kind fields ->
       match kind with
       | Start_unrecorded_kind -> Ok Start_unrecorded
       | Idle_kind ->
         let* idle_s = float_member fields idle_s_key in
         let* lifetime = lifetime_member fields lifetime_key in
         Ok (Idle { idle_s; lifetime }))
;;

let not_compared_member fields key =
  tagged_member
    fields
    key
    ~label:not_compared_kind_label
    all_of_not_compared_kind
    (fun kind fields ->
       match kind with
       | Earlier_turn_not_settled_kind -> Ok Earlier_turn_not_settled
       | Snapshot_unread_kind ->
         let* turn_ref = turn_ref_member fields turn_ref_key in
         let* detail = string_member fields detail_key in
         Ok (Snapshot_unread { turn_ref; detail })
       | Snapshot_of_other_runtime_kind ->
         let* turn_ref = turn_ref_member fields turn_ref_key in
         let* runtime_profile = string_member fields runtime_profile_key in
         Ok (Snapshot_of_other_runtime { turn_ref; runtime_profile }))
;;

let prefix_member fields key =
  tagged_member
    fields
    key
    ~label:prefix_kind_label
    all_of_prefix_kind
    (fun kind fields ->
       match kind with
       | Compared_kind ->
         let* system_changed = bool_member fields system_changed_key in
         let* tools_changed = bool_member fields tools_changed_key in
         let* messages =
           let* value = member fields messages_key in
           Keeper_projection_change.message_change_of_json value
         in
         Ok (Compared { system_changed; tools_changed; messages })
       | Not_compared_kind ->
         let* reason = not_compared_member fields reason_key in
         Ok (Not_compared reason))
;;

let earlier_member fields key =
  tagged_member
    fields
    key
    ~label:earlier_kind_label
    all_of_earlier_kind
    (fun kind fields ->
       match kind with
       | None_within_kind ->
         let* horizon_s = float_member fields horizon_s_key in
         Ok (No_earlier_request { horizon_s })
       | Earlier_kind ->
         let* request = request_member fields request_key in
         let* idle = idle_member fields idle_key in
         let* prefix = prefix_member fields prefix_key in
         Ok (Earlier { request; idle; prefix }))
;;

let outcome_member fields key =
  tagged_member
    fields
    key
    ~label:outcome_kind_label
    all_of_outcome_kind
    (fun kind fields ->
       match kind with
       | Turn_not_in_ledger_kind -> Ok Turn_not_in_ledger
       | Ledger_row_unreadable_kind ->
         let* detail = string_member fields detail_key in
         Ok (Ledger_row_unreadable detail)
       | Not_per_request_kind ->
         let* request = request_member fields request_key in
         Ok (Not_per_request request)
       | First_request_kind ->
         let* request = request_member fields request_key in
         let* other_runtime_since =
           optional_member fields other_runtime_since_key (function
             | `String runtime_id -> Ok runtime_id
             | _ -> invalid other_runtime_since_key "a string or null")
         in
         let* earlier = earlier_member fields earlier_key in
         Ok (First_request { request; other_runtime_since; earlier }))
;;

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let* written_schema = string_member fields schema_key in
    if not (String.equal written_schema schema)
    then invalid schema_key schema
    else (
      let* keeper = string_member fields keeper_key in
      let* turn_ref = turn_ref_member fields turn_ref_key in
      let* unattributed_rows = count_member fields unattributed_rows_key in
      let* outcome = outcome_member fields outcome_key in
      Ok { keeper; turn_ref; unattributed_rows; outcome })
  | _ -> Error "a cache outcome must be a JSON object"
;;
