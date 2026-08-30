(** Naming a schema's repeated shapes must not change what the schema says.

    The saving is real but small and lands in one tool, so the risk that
    matters is not the byte count — it is a transform that quietly alters what
    the model is allowed to send. These tests expand every reference back and
    require the original, then check that the one tool this was built for
    actually shrinks. *)

open Alcotest

module Defs = Json_schema_shared_defs

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map (fun (key, value) -> key, sorted value) fields
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* Put every [$ref] back, so the result can be compared against the input. A
   definition may itself hold references, so this recurses through what it
   substitutes rather than expanding one level. *)
let expand (collapsed : Yojson.Safe.t) : Yojson.Safe.t =
  let definitions =
    match collapsed with
    | `Assoc fields ->
      (match List.assoc_opt "$defs" fields with
       | Some (`Assoc defs) -> defs
       | _ -> [])
    | _ -> []
  in
  let rec go (json : Yojson.Safe.t) : Yojson.Safe.t =
    match json with
    | `Assoc [ ("$ref", `String reference) ] ->
      let name =
        match String.rindex_opt reference '/' with
        | Some index -> String.sub reference (index + 1) (String.length reference - index - 1)
        | None -> reference
      in
      (match List.assoc_opt name definitions with
       | Some body -> go body
       | None -> failf "dangling reference %s" reference)
    | `Assoc fields ->
      `Assoc
        (List.filter_map
           (fun (key, value) ->
              if String.equal key "$defs" then None else Some (key, go value))
           fields)
    | `List items -> `List (List.map go items)
    | other -> other
  in
  go collapsed
;;

let stage_properties =
  [ ( "argv"
    , `Assoc
        [ "type", `String "array"
        ; "items", `Assoc [ "type", `String "string" ]
        ; ( "description"
          , `String
              "Program and arguments, already split. No shell parsing happens here, so \
               a pipe or a redirect arrives as a literal token." )
        ] )
  ; ( "cwd"
    , `Assoc
        [ "type", `String "string"
        ; "description", `String "Absolute working directory for this stage."
        ] )
  ; ( "fd"
    , `Assoc
        [ "type", `String "integer"
        ; "description", `String "File descriptor this stage writes its output to."
        ] )
  ]
;;

let stage =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc stage_properties
    ; "required", `List [ `String "argv"; `String "cwd"; `String "fd" ]
    ]
;;

let repeated_schema =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc [ "stage", stage; "then", stage ]
    ; "required", `List [ `String "stage"; `String "then" ]
    ]
;;

let test_a_repeated_shape_is_named_once () =
  let collapsed = Defs.collapse repeated_schema in
  let text = Yojson.Safe.to_string collapsed in
  check bool "the schema now carries a definition table" true
    (match collapsed with
     | `Assoc fields -> List.mem_assoc "$defs" fields
     | _ -> false);
  check
    int
    "the shape appears once as a body, and the copies became references"
    2
    (let rec count acc index =
       match String.index_from_opt text index '#' with
       | None -> acc
       | Some at ->
         let tail = String.length text - at in
         let is_ref = tail >= 8 && String.equal (String.sub text at 8) "#/$defs/" in
         count (if is_ref then acc + 1 else acc) (at + 1)
     in
     count 0 0);
  check
    bool
    "and it is smaller than what it replaced"
    true
    (String.length text < String.length (Yojson.Safe.to_string repeated_schema))
;;

let test_expanding_the_references_returns_the_original () =
  let collapsed = Defs.collapse repeated_schema in
  check
    string
    "every reference expands back to the shape it replaced"
    (Yojson.Safe.to_string (sorted repeated_schema))
    (Yojson.Safe.to_string (sorted (expand collapsed)))
;;

let test_a_shape_nested_in_another_is_stored_once () =
  let inner = stage in
  let outer =
    `Assoc
      [ "type", `String "object"
      ; "additionalProperties", `Bool false
      ; "properties", `Assoc [ "first", inner; "second", inner ]
      ; "required", `List [ `String "first" ]
      ]
  in
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "left", outer; "right", outer ]
      ]
  in
  let collapsed = Defs.collapse schema in
  check
    string
    "a shape inside a named shape expands back too"
    (Yojson.Safe.to_string (sorted schema))
    (Yojson.Safe.to_string (sorted (expand collapsed)))
;;

let test_nothing_to_name_is_left_alone () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc [ "only", `Assoc [ "type", `String "string" ] ]
      ]
  in
  check
    string
    "a schema that repeats nothing is returned unchanged"
    (Yojson.Safe.to_string schema)
    (Yojson.Safe.to_string (Defs.collapse schema));
  (* Two copies of a tiny shape cost more in references than they save. *)
  let tiny = `Assoc [ "type", `String "object"; "properties", `Assoc [] ] in
  let small =
    `Assoc
      [ "type", `String "object"; "properties", `Assoc [ "a", tiny; "b", tiny ] ]
  in
  check
    string
    "a repeat too small to pay for its references is left alone"
    (Yojson.Safe.to_string small)
    (Yojson.Safe.to_string (Defs.collapse small))
;;

let test_a_schema_that_already_names_shapes_is_not_rewritten () =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; "$defs", `Assoc [ "existing", stage ]
      ; "properties", `Assoc [ "stage", `Assoc [ "$ref", `String "#/$defs/existing" ] ]
      ]
  in
  check
    string
    "an existing definition table is left as its author wrote it"
    (Yojson.Safe.to_string schema)
    (Yojson.Safe.to_string (Defs.collapse schema))
;;

(* The transform exists for Execute. If the live schema stops shrinking, either
   Execute was rewritten or the transform stopped finding what it is for, and
   both are worth stopping on. *)
let test_the_live_execute_schema_shrinks () =
  let execute =
    Masc.Keeper_tool_descriptor.model_visible_schemas ()
    |> List.find_opt (fun (schema : Masc_domain.tool_schema) ->
      String.equal schema.name "Execute")
  in
  match execute with
  | None -> fail "Execute is absent from the model-visible surface"
  | Some execute ->
    let before = String.length (Yojson.Safe.to_string execute.input_schema) in
    let after =
      String.length (Yojson.Safe.to_string (Defs.collapse execute.input_schema))
    in
    check bool (Printf.sprintf "Execute shrinks: %d -> %d" before after) true
      (after < before);
    check
      string
      "and says the same thing afterwards"
      (Yojson.Safe.to_string (sorted execute.input_schema))
      (Yojson.Safe.to_string (sorted (expand (Defs.collapse execute.input_schema))))
;;

let () =
  run
    "json schema shared defs"
    [ ( "naming repeats"
      , [ test_case "names a repeated shape once" `Quick test_a_repeated_shape_is_named_once
        ; test_case
            "stores a shape nested in another once"
            `Quick
            test_a_shape_nested_in_another_is_stored_once
        ] )
    ; ( "meaning is preserved"
      , [ test_case
            "expanding the references returns the original"
            `Quick
            test_expanding_the_references_returns_the_original
        ; test_case
            "leaves a schema with nothing to name alone"
            `Quick
            test_nothing_to_name_is_left_alone
        ; test_case
            "does not rewrite a schema that already names shapes"
            `Quick
            test_a_schema_that_already_names_shapes_is_not_rewritten
        ] )
    ; ( "the tool it was built for"
      , [ test_case
            "the live Execute schema shrinks and still says the same thing"
            `Quick
            test_the_live_execute_schema_shrinks
        ] )
    ]
;;
