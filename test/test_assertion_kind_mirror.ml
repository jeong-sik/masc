(** The assertion-kind mirror, compared against its owner.

    [Tool_schemas_workspace_core] lives in masc_tool_schemas and the handler
    lives in masc, so the schema library cannot reach the owner and hand-copies
    the vocabulary:

      let assertion_kind_enum_strings = [ "task_claimed"; "current_task_set" ]

    Its header says [test_types.ml :: assertion_kind_ssot] keeps that in sync.
    There is no test_types.ml. Adding a kind breaks compilation in
    [assertion_kind_to_string], which forces the owner's list to grow, and
    nothing then makes the copy grow with it — [masc_check] would keep
    advertising the old set while the handler accepted the new one.

    The copy is a plain list in another library, so this compares the
    observable end: the [enum] array [masc_check] publishes, against
    [Workspace_assertions.valid_assertion_strings]. *)

open Alcotest

(* Every enum array anywhere in a schema, at any nesting depth. The assertion
   enum sits under items of an array property, not at the top level. *)
let rec enum_arrays (json : Yojson.Safe.t) : string list list =
  match json with
  | `Assoc fields ->
    List.concat_map
      (fun (key, value) ->
        match key, value with
        | "enum", `List items ->
          let strings =
            List.filter_map (function `String s -> Some s | _ -> None) items
          in
          if strings = [] then [] else [ strings ]
        | _ -> enum_arrays value)
      fields
  | `List items -> List.concat_map enum_arrays items
  | _ -> []
;;

let check_schema () =
  match
    List.find_opt
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name "masc_check")
      Tool_schemas_workspace_core.schemas
  with
  | Some schema -> schema
  | None -> failf "masc_check is not among Tool_schemas_workspace_core.schemas"
;;

let owner = Masc.Workspace_assertions.valid_assertion_strings

(* A guard that finds no enum passes for the wrong reason. *)
let test_schema_publishes_an_enum () =
  let enums = enum_arrays (check_schema ()).input_schema in
  check bool "masc_check publishes at least one enum" true (enums <> []);
  check bool "the owner list is non-empty" true (owner <> [])
;;

let test_published_enum_matches_the_owner () =
  let enums = enum_arrays (check_schema ()).input_schema in
  if not (List.exists (fun e -> e = owner) enums)
  then
    failf
      "no enum in masc_check equals Workspace_assertions.valid_assertion_strings \
       (%s).\n\
       The hand-copied assertion_kind_enum_strings has drifted.\n\
       Published enums: %s"
      (String.concat "|" owner)
      (String.concat "  /  " (List.map (String.concat "|") enums))
;;

(* Every advertised kind must be one the handler's parser recognises, so a copy
   that grows a value the handler rejects fails here too. *)
let test_every_advertised_kind_parses () =
  List.iter
    (fun kind ->
      match Masc.Workspace_assertions.assertion_kind_of_string_lenient kind with
      | Some _ -> ()
      | None -> failf "advertised assertion %S is not one the handler accepts" kind)
    owner
;;

let () =
  Alcotest.run
    "Assertion kind mirror"
    [ ( "mirror"
      , [ test_case "the schema publishes an enum" `Quick test_schema_publishes_an_enum
        ; test_case "the published enum matches the owner" `Quick
            test_published_enum_matches_the_owner
        ; test_case "every advertised kind parses" `Quick
            test_every_advertised_kind_parses
        ] )
    ]
;;
