(** The agent-card action mirror, compared against its owner.

    [Tool_schemas_agent] cannot depend on [Tool_agent] — masc_tool_schemas
    only links masc_types — so it hand-copies the action vocabulary:

      let agent_card_action_enum_strings = [ "get"; "refresh" ]

    Its header says a sync regression test named
    [test_types.ml :: keeper_tool_variants_ssot] catches drift. There is no
    test_types.ml. Adding a third action breaks compilation in
    [agent_card_action_to_string], which forces the owner's list to grow, and
    then nothing makes the copy grow with it — the tool schema would keep
    advertising two while the handler accepted three.

    The copy is private to its library, so this compares the observable end:
    the [enum] array in the published [masc_agent_card] schema against
    [Tool_agent.valid_agent_card_action_strings]. *)

open Alcotest

(* Every enum array anywhere in a schema, at any nesting depth. *)
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

let agent_card_schema () =
  match
    List.find_opt
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name "masc_agent_card")
      Tool_schemas_agent.schemas
  with
  | Some schema -> schema
  | None -> failf "masc_agent_card is not among Tool_schemas_agent.schemas"
;;

let owner = Masc.Tool_agent.valid_agent_card_action_strings

(* A guard that finds no enum passes for the wrong reason. *)
let test_schema_publishes_an_enum () =
  let enums = enum_arrays (agent_card_schema ()).input_schema in
  check bool "masc_agent_card publishes at least one enum" true (enums <> []);
  check bool "the owner list is non-empty" true (owner <> [])
;;

let test_published_enum_matches_the_owner () =
  let enums = enum_arrays (agent_card_schema ()).input_schema in
  if not (List.exists (fun e -> e = owner) enums)
  then
    failf
      "no enum in masc_agent_card equals Tool_agent.valid_agent_card_action_strings \
       (%s).\n\
       The hand-copied agent_card_action_enum_strings has drifted.\n\
       Published enums: %s"
      (String.concat "|" owner)
      (String.concat "  /  " (List.map (String.concat "|") enums))
;;

let () =
  Alcotest.run
    "Agent card action mirror"
    [ ( "mirror"
      , [ test_case "the schema publishes an enum" `Quick test_schema_publishes_an_enum
        ; test_case "the published enum matches the owner" `Quick
            test_published_enum_matches_the_owner
        ] )
    ]
;;
