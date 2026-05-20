(** test_keeper_bash_typed_descriptor — keeper_bash typed descriptor.

    The model-facing [keeper_bash] schema exposes typed argv/pipeline input only.
    This test prevents the removed command-string field or selector gate from
    returning to the active tool surface. *)

open Masc_mcp

let pp_json = Yojson.Safe.to_string

let find_bash_schema tools =
  List.find
    (fun (t : Masc_domain.tool_schema) -> String.equal t.name "keeper_bash")
    tools
;;

let assoc_field_opt (json : Yojson.Safe.t) key =
  match json with
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None
;;

let property_names (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "properties" with
  | Some (`Assoc props) -> List.map fst props
  | _ -> Alcotest.failf "properties missing or wrong shape: %s" (pp_json input_schema)
;;

let one_of_required_names (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "oneOf" with
  | Some (`List branches) ->
    List.map
      (fun branch ->
        match assoc_field_opt branch "required" with
        | Some (`List names) ->
          List.map
            (function
              | `String s -> s
              | _ -> "<non-string>")
            names
          |> String.concat ","
        | _ -> "<no-required>")
      branches
  | _ -> Alcotest.failf "oneOf missing or wrong shape: %s" (pp_json input_schema)
;;

let top_level_required (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "required" with
  | Some (`List names) ->
    Some
      (List.map
         (function
           | `String s -> s
           | _ -> "<non-string>")
         names
       |> String.concat ",")
  | _ -> None
;;

let additional_properties_closed (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "additionalProperties" with
  | Some (`Bool false) -> true
  | _ -> false
;;

let test_keeper_bash_schema_is_typed_only () =
  let bash =
    Tool_shard_types_schemas_bash.coding_keeper_bridge_tools
    |> find_bash_schema
  in
  let props = property_names bash.input_schema in
  Alcotest.(check bool) "cmd absent from properties" false (List.mem "cmd" props);
  Alcotest.(check bool) "executable present in properties" true
    (List.mem "executable" props);
  Alcotest.(check bool) "pipeline present in properties" true
    (List.mem "pipeline" props);
  Alcotest.(check bool) "stages present in properties" true
    (List.mem "stages" props);
  let branches = one_of_required_names bash.input_schema in
  Alcotest.(check int) "3 oneOf branches" 3 (List.length branches);
  Alcotest.(check bool) "cmd branch absent" false (List.mem "cmd" branches);
  Alcotest.(check (option string))
    "no top-level required; oneOf selects exec/pipeline/stages"
    None
    (top_level_required bash.input_schema);
  Alcotest.(check bool)
    "additional properties closed"
    true
    (additional_properties_closed bash.input_schema);
  Alcotest.(check bool) "description does not advertise cmd" false
    (Astring.String.is_infix ~affix:"cmd=" bash.description)
;;

let test_sibling_schemas_present () =
  let tools = Tool_shard_types_schemas_bash.coding_keeper_bridge_tools in
  let by_name name =
    List.find_opt
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name name)
      tools
  in
  List.iter
    (fun name ->
      match by_name name with
      | Some _ -> ()
      | None -> Alcotest.failf "missing sibling schema: %s" name)
    [ "keeper_bash_output"; "keeper_bash_kill" ]
;;

let () =
  Alcotest.run
    "keeper_bash_typed_descriptor"
    [ ( "typed_descriptor"
      , [ Alcotest.test_case "keeper_bash is typed-only" `Quick
            test_keeper_bash_schema_is_typed_only
        ; Alcotest.test_case "sibling schemas present" `Quick
            test_sibling_schemas_present
        ] )
    ]
;;
