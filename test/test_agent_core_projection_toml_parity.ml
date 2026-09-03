(** Structural pins for the agent-core projections declared in the
    [agent_core_projection] tables of [config/tools/masc_batch_add_tasks.toml],
    [masc_broadcast.toml] and [masc_heartbeat.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    These three bindings used to carry their deliberately narrower
    agent-core wording and schemas as OCaml literals in
    [Agent_core_tool_contract]; the TOML tables are now the only source.
    What is pinned is the shape an agent-core model reads: the moved
    descriptions byte-for-byte, which fields exist and in what order, the
    narrowed parameter sets (no caller-controlled [agent_name]), and the
    [arg_bindings] projection the resolver applies. *)

open Alcotest

module Contract = Masc.Agent_core_tool_contract

let binding name =
  match Contract.agent_core_binding_by_name name with
  | Some binding -> binding
  | None -> failf "%s agent-core binding missing" name
;;

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "%s missing under %s" key (Yojson.Safe.to_string json))
  | other -> failf "%s looked up on non-object %s" key (Yojson.Safe.to_string other)
;;

let property_names (json : Yojson.Safe.t) =
  match member json "properties" with
  | `Assoc fields -> List.map fst fields
  | other -> failf "properties is not an object: %s" (Yojson.Safe.to_string other)
;;

let required_names (json : Yojson.Safe.t) =
  match member json "required" with
  | `List items ->
    List.map
      (function
        | `String s -> s
        | other -> failf "expected string, got %s" (Yojson.Safe.to_string other))
      items
  | other -> failf "required is not a list: %s" (Yojson.Safe.to_string other)
;;

let additional_properties_false (json : Yojson.Safe.t) =
  check
    (option bool)
    "additionalProperties is false"
    (Some false)
    (match member json "additionalProperties" with
     | `Bool flag -> Some flag
     | _ -> None)
;;

let string_field (json : Yojson.Safe.t) key =
  match member json key with
  | `String text -> text
  | other -> failf "%s is not a string: %s" key (Yojson.Safe.to_string other)
;;

let test_batch_add_tasks_projection () =
  let binding = binding "masc_batch_add_tasks" in
  check
    string
    "description moved byte-for-byte"
    "Create multiple tasks at once for planner-driven decomposition."
    binding.Contract.description;
  check (list string) "properties" [ "tasks" ] (property_names binding.input_schema);
  check (list string) "required" [ "tasks" ] (required_names binding.input_schema);
  additional_properties_false binding.input_schema;
  let tasks = member (member binding.input_schema "properties") "tasks" in
  check string "tasks type" "array" (string_field tasks "type");
  check
    string
    "tasks description moved byte-for-byte"
    "Array of {title, description} task objects"
    (string_field tasks "description");
  check
    (option int)
    "tasks minItems"
    (Some 1)
    (match member tasks "minItems" with
     | `Int v -> Some v
     | _ -> None);
  let items = member tasks "items" in
  check string "items type" "object" (string_field items "type");
  check (list string) "items properties" [ "title"; "description" ] (property_names items);
  check (list string) "items required" [ "title"; "description" ] (required_names items);
  additional_properties_false items;
  let item_properties = member items "properties" in
  check
    string
    "items.title description"
    "Task title"
    (string_field (member item_properties "title") "description");
  check
    string
    "items.description description"
    "Task description"
    (string_field (member item_properties "description") "description");
  match binding.Contract.arg_bindings with
  | [ ("tasks", Contract.Input_field "tasks") ] -> ()
  | other ->
    failf
      "batch arg_bindings narrowed: %d entries"
      (List.length other)
;;

let test_broadcast_projection () =
  let binding = binding "masc_broadcast" in
  check
    string
    "description moved byte-for-byte"
    "Broadcast a message to all active agents. Use when sharing status updates, \
     workspace signals, or requesting help from any available agent."
    binding.Contract.description;
  check
    (list string)
    "properties omit the injected agent_name"
    [ "content"; "task_cache_subject_agent"; "task_cache_task_id" ]
    (property_names binding.input_schema);
  check (list string) "required" [ "content" ] (required_names binding.input_schema);
  additional_properties_false binding.input_schema;
  let properties = member binding.input_schema "properties" in
  List.iter
    (fun (name, expected) ->
       check
         string
         (name ^ " description moved byte-for-byte")
         expected
         (string_field (member properties name) "description"))
    [ "content", "Broadcast body text"
    ; ( "task_cache_subject_agent"
      , "Agent whose current-task cache was observed; supply together with \
         task_cache_task_id" )
    ; ( "task_cache_task_id"
      , "Task ID observed in the subject agent cache; supply together with \
         task_cache_subject_agent" )
    ];
  match binding.Contract.arg_bindings with
  | ("agent_name", Contract.Agent_name)
    :: [ ("content", Contract.Input_field "content")
       ; ("task_cache_subject_agent", Contract.Input_field "task_cache_subject_agent")
       ; ("task_cache_task_id", Contract.Input_field "task_cache_task_id")
       ] ->
    ()
  | other ->
    failf
      "broadcast arg_bindings changed: %d entries"
      (List.length other)
;;

let test_heartbeat_projection () =
  let binding = binding "masc_heartbeat" in
  check
    string
    "description moved byte-for-byte"
    "Send an immediate heartbeat so this agent stays fresh in MASC visibility."
    binding.Contract.description;
  check (list string) "no properties" [] (property_names binding.input_schema);
  additional_properties_false binding.input_schema;
  (match binding.Contract.arg_bindings with
   | [ ("agent_name", Contract.Agent_name) ] -> ()
   | other ->
     failf "heartbeat arg_bindings changed: %d entries" (List.length other));
  (* The resolver still injects the caller identity over the empty schema. *)
  match
    Contract.resolve_requested_tool_call
      ~agent_name:"keeper-one"
      ~requested_name:"masc_heartbeat"
      ~arguments:(`Assoc [])
  with
  | Ok ("masc_heartbeat", `Assoc [ ("agent_name", `String "keeper-one") ]) -> ()
  | Ok other ->
    failf "heartbeat resolution changed: %s" (Yojson.Safe.to_string (snd other))
  | Error detail -> failf "heartbeat resolution failed: %s" detail
;;

(* The published agent-core surface is the same three narrowed shapes. *)
let test_published_schemas_match_the_bindings () =
  let published =
    List.map
      (fun (schema : Masc_domain.tool_schema) ->
         schema.name, Yojson.Safe.to_string schema.input_schema)
      Contract.agent_core_tool_schemas
  in
  List.iter
    (fun name ->
       let binding = binding name in
       match List.assoc_opt name published with
       | Some serialized ->
         check
           string
           (name ^ " published input_schema")
           (Yojson.Safe.to_string binding.input_schema)
           serialized
       | None -> failf "%s missing from agent_core_tool_schemas" name)
    [ "masc_batch_add_tasks"; "masc_broadcast"; "masc_heartbeat" ]
;;

let () =
  run
    "agent_core_projection_toml_parity"
    [ ( "projections"
      , [ test_case "masc_batch_add_tasks" `Quick test_batch_add_tasks_projection
        ; test_case "masc_broadcast" `Quick test_broadcast_projection
        ; test_case "masc_heartbeat" `Quick test_heartbeat_projection
        ; test_case
            "published schemas match the bindings"
            `Quick
            test_published_schemas_match_the_bindings
        ] )
    ]
;;
