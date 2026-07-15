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

let statuses =
  [ "scheduled"
  ; "due"
  ; "running"
  ; "succeeded"
  ; "failed"
  ; "cancelled"
  ; "expired"
  ]
;;

let actor_kinds = [ "human_operator"; "automated_actor"; "system" ]

let sources = [ "operator_request"; "automated_request"; "system_request" ]
let recurrence_kinds = [ "one_shot"; "interval"; "daily"; "cron" ]

let create_schema =
  object_schema
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
    ; string_prop
        ~description:
          "Payload kind used when payload is omitted. The server consumer accepts masc.keeper_wake."
        "payload_kind"
    ; integer_prop
        ~description:"Payload schema version used when payload is omitted."
        "payload_schema_version"
    ; object_prop
        ~description:
          "Payload body used when payload is omitted. For masc.keeper_wake use {keeper_name, message, optional title, optional urgency}."
        "payload_body"
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

type action =
  | Create_request
  | List_requests
  | Get_request
  | Cancel_request

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
        "Create a durable Keeper wake request. For 'every day at 09:00 KST', use recurrence_kind=daily, recurrence_hour=9, recurrence_minute=0, recurrence_timezone=Asia/Seoul. For compact calendar rules, use recurrence_kind=cron with a 5-field recurrence_cron such as '0 9 * * 1-5'. The due request wakes its Keeper lane; it does not authorize later effects."
      ~input_schema:create_schema ~read_only:false
  ; definition ~action:List_requests ~id:"list" ~name:"masc_schedule_list"
      ~description:"List durable scheduled internal automation requests."
      ~input_schema:list_schema ~read_only:true
  ; definition ~action:Get_request ~id:"get" ~name:"masc_schedule_get"
      ~description:"Read one durable scheduled internal automation request."
      ~input_schema:get_schema ~read_only:true
  ; definition ~action:Cancel_request ~id:"cancel" ~name:"masc_schedule_cancel"
      ~description:
        "Cancel a scheduled or due request before execution."
      ~input_schema:cancel_schema ~read_only:false
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
