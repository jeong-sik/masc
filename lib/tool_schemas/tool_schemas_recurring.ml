(** MCP tool schemas for keeper recurring task management.
    RFC-0314 — Keeper Recurring Producer. *)

open Masc_domain

let string_prop ?description name =
  let fields =
    [ "type", `String "string" ]
    @ (match description with
       | None -> []
       | Some value -> [ "description", `String value ])
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

(* ---------------------------------------------------------------- *)
(* masc_recurring_list                                               *)
(* ---------------------------------------------------------------- *)

let list_schema =
  object_schema
    []
    [ string_prop
        ~description:"Filter by keeper name (defaults to calling keeper)."
        "keeper_name"
    ]
;;

let list_definition =
  let description =
    "List recurring tasks registered by the calling keeper. Returns task id, \
     label, interval_sec, enabled status, last_run_ts, run_count, and \
     failure_count for each task."
  in
  {|
  {
    "name": "masc_recurring_list",
    "description": "|description|",
    "inputSchema": |list_schema|
  }|} description list_schema
;;

(* ---------------------------------------------------------------- *)
(* masc_recurring_remove                                             *)
(* ---------------------------------------------------------------- *)

let remove_schema =
  object_schema
    ~required:[ "id" ]
    [ string_prop
        ~description:"Task ID to remove (e.g. \"loop-12345-1\")."
        "id"
    ]
;;

let remove_definition =
  let description =
    "Remove a recurring task by its ID. Only tasks belonging to the calling \
     keeper can be removed. Returns success or not_found error."
  in
  {|
  {
    "name": "masc_recurring_remove",
    "description": "|description|",
    "inputSchema": |remove_schema|
  }|} description remove_schema
;;

(* ---------------------------------------------------------------- *)
(* Aggregation                                                       *)
(* ---------------------------------------------------------------- *)

type action = List_tasks | Remove_task

type definition = {
  action : action;
  id : string;
  name : string;
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

let definitions : definition list = [
  definition ~action:List_tasks ~id:"list" ~name:"masc_recurring_list"
    ~description:"List recurring tasks registered by the calling keeper."
    ~input_schema:list_schema ~read_only:true;
  definition ~action:Remove_task ~id:"remove" ~name:"masc_recurring_remove"
    ~description:"Remove a recurring task by ID. Only the owning keeper can remove."
    ~input_schema:remove_schema ~read_only:false;
]

let all_definitions = definitions

let schemas : Masc_domain.tool_schema list =
  List.map (fun d -> d.schema) definitions

let find_definition name =
  List.find_opt (fun d -> d.name = name) definitions
;;