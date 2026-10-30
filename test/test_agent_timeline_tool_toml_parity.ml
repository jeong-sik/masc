(** Structural pins for the agent-timeline tool declaration in
    [config/tools/masc_agent_timeline.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    The schema used to be an inline OCaml record in [Tool_agent_timeline];
    the TOML is now the only source. What is pinned is the shape a model
    reads: which fields exist and in what order, which parameter is required,
    and the default-as-prose phrasing each optional parameter carries
    (the loader declares no [default] for number/integer/boolean params that
    never had one — the defaults live in the description text and in the
    handler's [get_float]/[get_int]/[get_bool] fallbacks). *)

module Lib = Masc

open Alcotest

let published = Lib.Tool_agent_timeline.schemas

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "%s missing under %s" key (Yojson.Safe.to_string json))
  | other -> failf "%s looked up on non-object %s" key (Yojson.Safe.to_string other)
;;

let schema : Masc_domain.tool_schema =
  match published with
  | [ schema ] -> schema
  | schemas ->
    failf
      "expected exactly one published schema, got %d"
      (List.length schemas)
;;

let test_the_published_list_is_the_one_timeline_tool () =
  check
    (list string)
    "Tool_agent_timeline.schemas"
    [ "masc_agent_timeline" ]
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* Properties are serialized in [[params]] file order, and that order is the
   order a model reads them in. *)
let test_properties_are_the_six_fields_in_order () =
  let properties =
    match member schema.input_schema "properties" with
    | `Assoc fields -> List.map fst fields
    | other -> failf "properties is not an object: %s" (Yojson.Safe.to_string other)
  in
  check
    (list string)
    "properties in order"
    [ "agent_name"
    ; "since_hours"
    ; "limit"
    ; "include_tasks"
    ; "include_board"
    ; "include_tool_calls"
    ]
    properties;
  check
    (list string)
    "required is agent_name only"
    [ "agent_name" ]
    (match member schema.input_schema "required" with
     | `List items ->
       List.map
         (function
           | `String s -> s
           | other -> failf "expected string, got %s" (Yojson.Safe.to_string other))
         items
     | other -> failf "required is not a list: %s" (Yojson.Safe.to_string other))
;;

let test_property_types_and_default_prose () =
  let properties = member schema.input_schema "properties" in
  List.iter
    (fun (name, ty, phrase) ->
       let property = member properties name in
       (match member property "type" with
        | `String actual -> check string (name ^ " type") ty actual
        | other ->
          failf "%s type is not a string: %s" name (Yojson.Safe.to_string other));
       match member property "description" with
       | `String text ->
         check
           bool
           (name ^ " description keeps its default phrasing")
           true
           (Astring.String.is_infix ~affix:phrase text)
       | other ->
         failf
           "%s description is not a string: %s"
           name
           (Yojson.Safe.to_string other))
    [ "agent_name", "string", "Agent name to query"
    ; "since_hours", "number", "(default: 24)"
    ; "limit", "integer", "(default: 50)"
    ; "include_tasks", "boolean", "(default: true)"
    ; "include_board", "boolean", "(default: false, reserved)"
    ; "include_tool_calls", "boolean", "(default: true)"
    ]
;;

let test_description_is_the_moved_sentence () =
  check
    string
    "description"
    "Unified timeline of an agent's activity in the currently selected workspace \
     across tasks, messages, and joins."
    schema.description
;;

let () =
  run
    "agent_timeline_tool_toml_parity"
    [ ( "structure"
      , [ test_case
            "published list is the one timeline tool"
            `Quick
            test_the_published_list_is_the_one_timeline_tool
        ; test_case
            "properties are the six fields in order"
            `Quick
            test_properties_are_the_six_fields_in_order
        ; test_case
            "property types and default prose"
            `Quick
            test_property_types_and_default_prose
        ; test_case
            "description is the moved sentence"
            `Quick
            test_description_is_the_moved_sentence
        ] )
    ]
;;
