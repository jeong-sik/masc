open Masc_domain

let string_prop ?description ?enum name =
  let fields =
    [ "type", `String "string" ]
    @ (match description with
       | None -> []
       | Some value -> [ "description", `String value ])
    @ (match enum with
       | None -> []
       | Some values -> [ "enum", `List (List.map (fun value -> `String value) values) ])
  in
  name, `Assoc fields
;;

let number_prop ?description name =
  let fields =
    [ "type", `String "number" ]
    @
    match description with
    | None -> []
    | Some value -> [ "description", `String value ]
  in
  name, `Assoc fields
;;

let integer_prop ?description name =
  let fields =
    [ "type", `String "integer" ]
    @
    match description with
    | None -> []
    | Some value -> [ "description", `String value ]
  in
  name, `Assoc fields
;;

let bool_prop ?description name =
  let fields =
    [ "type", `String "boolean" ]
    @
    match description with
    | None -> []
    | Some value -> [ "description", `String value ]
  in
  name, `Assoc fields
;;

let object_prop ?description ?(additional_properties = true) name =
  let fields =
    [ "type", `String "object"; "additionalProperties", `Bool additional_properties ]
    @
    match description with
    | None -> []
    | Some value -> [ "description", `String value ]
  in
  name, `Assoc fields
;;

let object_schema ?(required = []) properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

let risk_classes =
  [ "reminder_only"
  ; "read_only"
  ; "workspace_write"
  ; "external_write"
  ; "destructive"
  ; "cost_bearing"
  ]
;;

let statuses =
  [ "pending_approval"
  ; "scheduled"
  ; "due"
  ; "running"
  ; "succeeded"
  ; "failed"
  ; "rejected"
  ; "cancelled"
  ; "expired"
  ]
;;

let actor_kinds = [ "human_operator"; "automated_actor"; "system" ]

let sources = [ "operator_request"; "automated_request"; "system_request" ]
let recurrence_kinds = [ "one_shot"; "interval"; "daily"; "cron" ]

let create_schema =
  object_schema
    ~required:[ "risk_class" ]
    [ number_prop
        ~description:
          "Unix timestamp in seconds. Provide this, due_at_iso, or a calendar recurrence (daily/cron) that can derive the first due time."
        "due_at_unix"
    ; string_prop
        ~description:
          "ISO-8601 timestamp. Provide this, due_at_unix, or a calendar recurrence (daily/cron) that can derive the first due time."
        "due_at_iso"
    ; object_prop
        ~description:
          "Typed schedule payload envelope: {kind:string, schema_version:int, body:object}."
        "payload"
    ; string_prop ~description:"Payload kind used when payload is omitted." "payload_kind"
    ; integer_prop ~description:"Payload schema version used when payload is omitted." "payload_schema_version"
    ; object_prop ~description:"Payload body used when payload is omitted." "payload_body"
    ; string_prop ~enum:risk_classes "risk_class"
    ; bool_prop
        ~description:
          "Force a separate human grant even for reminder_only or read_only requests."
        "approval_required"
    ; string_prop ~description:"Optional stable schedule id." "schedule_id"
    ; number_prop ~description:"Optional request timestamp for replay/tests." "requested_at_unix"
    ; number_prop ~description:"Optional expiry timestamp." "expires_at_unix"
    ; string_prop
        ~description:"Recurrence kind. Defaults to one_shot."
        ~enum:recurrence_kinds
        "recurrence_kind"
    ; integer_prop
        ~description:"Required when recurrence_kind is interval; seconds between runs."
        "recurrence_interval_sec"
    ; integer_prop
        ~description:"Required when recurrence_kind is daily; local hour in 0..23."
        "recurrence_hour"
    ; integer_prop
        ~description:"Required when recurrence_kind is daily; local minute in 0..59."
        "recurrence_minute"
    ; integer_prop
        ~description:"Optional when recurrence_kind is daily; local second in 0..59."
        "recurrence_second"
    ; string_prop
        ~description:
          "Required when recurrence_kind is cron. Standard 5-field cron expression: minute hour day-of-month month day-of-week. Supports wildcards, comma lists, numeric ranges, and steps such as */15 or 1-5/2."
        "recurrence_cron"
    ; string_prop
        ~description:
          "Required when recurrence_kind is daily or cron. Fixed-offset only: UTC, Asia/Seoul/KST as +09:00 aliases, or offsets like +09:00/UTC+09:00. DST-aware IANA zones are not supported."
        "recurrence_timezone"
    ; string_prop ~description:"Requester actor id. Defaults to operator." "requested_by_id"
    ; string_prop ~enum:actor_kinds "requested_by_kind"
    ; string_prop ~description:"Requester display name." "requested_by_display_name"
    ; string_prop ~description:"Scheduler actor id. Defaults to caller agent name." "scheduled_by_id"
    ; string_prop ~enum:actor_kinds "scheduled_by_kind"
    ; string_prop ~description:"Scheduler display name." "scheduled_by_display_name"
    ; string_prop ~enum:sources "source"
    ]
;;

let list_schema =
  object_schema
    [ string_prop ~enum:statuses "status"
    ; integer_prop ~description:"Maximum rows to return. Defaults to 50, capped at 200." "limit"
    ]
;;

let get_schema =
  object_schema ~required:[ "schedule_id" ]
    [ string_prop ~description:"Schedule id to read." "schedule_id" ]
;;

let cancel_schema =
  object_schema ~required:[ "schedule_id"; "cancelled_by_id"; "reason" ]
    [ string_prop ~description:"Schedule id to cancel." "schedule_id"
    ; string_prop ~description:"Human or system actor id cancelling the schedule." "cancelled_by_id"
    ; string_prop ~enum:actor_kinds "cancelled_by_kind"
    ; string_prop ~description:"Reason for operator-visible cancellation." "reason"
    ]
;;

let approve_schema =
  object_schema ~required:[ "schedule_id"; "approved_by_id" ]
    [ string_prop ~description:"Pending or due schedule id to approve." "schedule_id"
    ; string_prop ~description:"Human approver id; cannot equal requester or scheduler." "approved_by_id"
    ; string_prop ~description:"Approver display name." "approved_by_display_name"
    ; string_prop ~description:"Optional stable grant id." "grant_id"
    ; number_prop ~description:"Optional approval timestamp for replay/tests." "approved_at_unix"
    ]
;;

let reject_schema =
  object_schema ~required:[ "schedule_id"; "approved_by_id"; "reason" ]
    [ string_prop ~description:"Pending or due schedule id to reject." "schedule_id"
    ; string_prop ~description:"Human approver id; cannot equal requester or scheduler." "approved_by_id"
    ; string_prop ~description:"Approver display name." "approved_by_display_name"
    ; string_prop ~description:"Optional stable grant id." "grant_id"
    ; number_prop ~description:"Optional decision timestamp for replay/tests." "approved_at_unix"
    ; string_prop ~description:"Human-readable rejection reason." "reason"
    ]
;;

type action =
  | Create_request
  | List_requests
  | Get_request
  | Cancel_request
  | Approve_request
  | Reject_request

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let definition ~action ~id ~name ~description ~input_schema ~read_only =
  { action; id; schema = { name; description; input_schema }; read_only }
;;

let definitions : definition list =
  [ definition ~action:Create_request ~id:"create" ~name:"masc_schedule_create"
      ~description:
        "Create a durable scheduled internal automation request. Side-effecting requests start pending approval and require a later separate human grant."
      ~input_schema:create_schema ~read_only:false
  ; definition ~action:List_requests ~id:"list" ~name:"masc_schedule_list"
      ~description:"List durable scheduled internal automation requests."
      ~input_schema:list_schema ~read_only:true
  ; definition ~action:Get_request ~id:"get" ~name:"masc_schedule_get"
      ~description:"Read one durable scheduled internal automation request."
      ~input_schema:get_schema ~read_only:true
  ; definition ~action:Cancel_request ~id:"cancel" ~name:"masc_schedule_cancel"
      ~description:
        "Cancel a pending, scheduled, or due scheduled request before execution."
      ~input_schema:cancel_schema ~read_only:false
  ; definition ~action:Approve_request ~id:"approve" ~name:"masc_schedule_approve"
      ~description:
        "Record a separate human execution grant for a pending or due scheduled request. Recurring side-effecting requests need a fresh grant for each due occurrence."
      ~input_schema:approve_schema ~read_only:false
  ; definition ~action:Reject_request ~id:"reject" ~name:"masc_schedule_reject"
      ~description:"Reject a pending or due scheduled request with a human decision."
      ~input_schema:reject_schema ~read_only:false
  ]
;;

let schemas : Masc_domain.tool_schema list =
  List.map (fun definition -> definition.schema) definitions
;;

let find_definition name =
  List.find_opt
    (fun definition ->
      let schema : Masc_domain.tool_schema = definition.schema in
      String.equal schema.name name)
    definitions
;;
