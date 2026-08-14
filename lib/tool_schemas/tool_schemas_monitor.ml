(** Tool schemas for RFC-0379 keeper monitors. *)

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

let object_schema ~properties ~required =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

let create_schema =
  object_schema
    ~properties:
      [ string_prop
          ~description:
            "Which condition transition wakes you. port_up fires when the \
             host:port becomes reachable, port_down when it stops being \
             reachable, file_changed when the file's mtime/inode pair changes \
             (including appearing or disappearing)."
          ~enum:[ "port_up"; "port_down"; "file_changed" ]
          "trigger_kind"
      ; string_prop
          ~description:"Host for port_up/port_down, e.g. 127.0.0.1."
          "host"
      ; integer_prop ~description:"TCP port for port_up/port_down (1-65535)." "port"
      ; string_prop ~description:"Absolute file path for file_changed." "path"
      ; string_prop
          ~description:
            "Delivered back verbatim in the wake: write the instruction your \
             future turn should act on."
          "payload"
      ; number_prop
          ~description:
            "Seconds from now until the monitor expires unfired. Expiry \
             deletes it silently."
          "expires_in_sec"
      ; integer_prop
          ~description:
            "Fires before the monitor is consumed. Omitted means 1: the \
             monitor is one-shot and its record is deleted on the first fire."
          "max_fires"
      ]
    ~required:[ "trigger_kind"; "payload"; "expires_in_sec" ]
;;

let list_schema = object_schema ~properties:[] ~required:[]

let cancel_schema =
  object_schema
    ~properties:
      [ string_prop ~description:"The monitor id returned by masc_monitor_create." "monitor_id" ]
    ~required:[ "monitor_id" ]
;;

type action =
  | Create_monitor
  | List_monitors
  | Cancel_monitor

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
  [ definition ~action:Create_monitor ~id:"create" ~name:"masc_monitor_create"
      ~description:
        "Register an edge-triggered condition monitor (RFC-0379). The server \
         observes the condition; when it transitions (never on the first \
         observation), you receive a monitor_fired wake carrying your payload. \
         One-shot by default: the record is deleted when it fires. A server \
         restart re-baselines monitors instead of firing transitions that \
         happened while it was down."
      ~input_schema:create_schema ~read_only:false
  ; definition ~action:List_monitors ~id:"list" ~name:"masc_monitor_list"
      ~description:"List your own active monitors."
      ~input_schema:list_schema ~read_only:true
  ; definition ~action:Cancel_monitor ~id:"cancel" ~name:"masc_monitor_cancel"
      ~description:"Cancel one of your own monitors before it fires or expires."
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
