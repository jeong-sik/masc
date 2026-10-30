(** The publication order of [Tool_schemas_wiki.schemas], and which of
    those tools declare a [keeper_projection].

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone. The projection case keeps which tools carry a table and
    drops the copy of its prose.

    Order is not in the TOML. It is the order of the OCaml list, and #34379 is
    the open question about what changed it, so it stays. *)

open Alcotest


let expected =
  [ "masc_wiki_list"
  ; "masc_wiki_read"
  ; "masc_wiki_create"
  ; "masc_wiki_update"
  ; "masc_wiki_search"
  ; "masc_wiki_lint"
  ]
;;

let published = Tool_schemas_wiki.schemas




(* What a Keeper reads when the file declares a [keeper_projection] table:
   masc_wiki_list names its siblings by the keeper_* names a Keeper can
   call (keeper_tool_descriptor projects masc_wiki_read/search under
   them), the other five carry no table and reach the Keeper as their row.
   Read off the descriptor's literal before the sentence moved into the
   file, so this passing is what proves the file says the same thing. *)
let expected_keeper_projections =
  [ "masc_wiki_list", true
  ; "masc_wiki_read", false
  ; "masc_wiki_create", false
  ; "masc_wiki_update", false
  ; "masc_wiki_search", false
  ; "masc_wiki_lint", false
  ]
;;

let test_keeper_projections_are_declared_where_expected () =
  List.iter
    (fun (name, declares_projection) ->
       let definition =
         match
           List.find_opt
             (fun (definition : Tool_schemas_wiki.definition) ->
                String.equal definition.schema.name name)
             Tool_schemas_wiki.definitions
         with
         | Some definition -> definition
         | None -> failwith (name ^ " is absent from Tool_schemas_wiki.definitions")
       in
       check
         bool
         (name ^ " declares a keeper_projection")
         declares_projection
         (Option.is_some definition.keeper_projection))
    expected_keeper_projections
;;

let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_wiki.schemas in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "wiki_tool_toml_parity"
    [ ( "surface"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case
            "keeper projections"
            `Quick
            test_keeper_projections_are_declared_where_expected
        ] )
    ]
;;
