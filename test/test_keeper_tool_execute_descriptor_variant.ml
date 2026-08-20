(** tool_execute descriptor tests.

    Pins the single typed schema so raw [cmd] strings cannot return to the
    public tool descriptor. *)

open Masc

let pp_json = Yojson.Safe.to_string

let find_execute_schema tools =
  List.find
    (fun (t : Masc_domain.tool_schema) -> String.equal t.name "tool_execute")
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
           List.map (function `String s -> s | _ -> "<non-string>") names
           |> String.concat ","
         | _ -> "<no-required>")
      branches
  | _ -> Alcotest.failf "oneOf missing or wrong shape: %s" (pp_json input_schema)
;;

let top_level_required (input_schema : Yojson.Safe.t) =
  match assoc_field_opt input_schema "required" with
  | Some (`List names) ->
    Some
      (List.map (function `String s -> s | _ -> "<non-string>") names
       |> String.concat ",")
  | _ -> None
;;

let bool_field (input_schema : Yojson.Safe.t) key =
  match assoc_field_opt input_schema key with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let test_descriptor_is_typed_only () =
  let execute_schema =
    Tool_shard_types.typed_execute_tools
    |> find_execute_schema
  in
  let props = property_names execute_schema.input_schema in
  Alcotest.(check bool)
    "cmd absent from properties"
    false
    (List.mem "cmd" props);
  Alcotest.(check bool)
    "argv present in properties"
    true
    (List.mem "argv" props);
  Alcotest.(check bool)
    "retired executable absent from properties"
    false
    (List.mem "executable" props);
  Alcotest.(check bool)
    "pipeline present in properties"
    true
    (List.mem "pipeline" props);
  Alcotest.(check bool)
    "stages absent from properties"
    false
    (List.mem "stages" props);
  let branches = one_of_required_names execute_schema.input_schema in
  Alcotest.(check int) "2 oneOf branches" 2 (List.length branches);
  Alcotest.(check bool) "cmd branch absent" false (List.mem "cmd" branches);
  Alcotest.(check (option string))
    "no top-level required; oneOf owns branch selection"
    None
    (top_level_required execute_schema.input_schema)
  ;
  Alcotest.(check (option bool))
    "unknown top-level fields rejected"
    (Some false)
    (bool_field execute_schema.input_schema "additionalProperties")
;;

let test_description_does_not_advertise_cmd () =
  let execute_schema =
    Tool_shard_types.typed_execute_tools
    |> find_execute_schema
  in
  Alcotest.(check bool)
    "description names the non-empty argv process vector"
    true
    (Astring.String.is_infix
       ~affix:"non-empty argv process vector"
       execute_schema.description);
  Alcotest.(check bool)
    "description says cmd and command are rejected"
    true
    (Astring.String.is_infix
       ~affix:"cmd and command string fields are rejected"
       execute_schema.description);
  Alcotest.(check bool)
    "description does not advertise cmd examples"
    false
    (Astring.String.is_infix ~affix:"cmd=" execute_schema.description)
;;

let test_descriptions_do_not_advertise_raw_search_scans () =
  let execute_schema =
    Tool_shard_types.typed_execute_tools
    |> find_execute_schema
  in
  let combined =
    String.concat
      "\n"
      [ execute_schema.description; pp_json execute_schema.input_schema ]
  in
  List.iter
    (fun forbidden ->
       Alcotest.(check bool)
         ("descriptor omits " ^ forbidden)
         false
         (Astring.String.is_infix ~affix:forbidden combined))
    [ "rg pattern lib/"; "executable='rg'"; "{executable='rg'" ];
  Alcotest.(check bool)
    "descriptor points read-only search to structured tools"
    true
    (Astring.String.is_infix ~affix:"Grep" combined)
;;

let () =
  Alcotest.run
    "tool_execute_descriptor"
    [ ( "typed_schema"
      , [ Alcotest.test_case
            "descriptor is typed only"
            `Quick
            test_descriptor_is_typed_only
        ; Alcotest.test_case
            "description does not advertise cmd"
            `Quick
            test_description_does_not_advertise_cmd
        ; Alcotest.test_case
            "descriptions avoid raw search scans"
            `Quick
            test_descriptions_do_not_advertise_raw_search_scans
        ] )
    ]
;;
