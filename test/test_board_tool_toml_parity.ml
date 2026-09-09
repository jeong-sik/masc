(** What the board surface publishes: which rows, in what order, which of them
    carry a keeper projection, and which identity fields the runtime fills in.

    Until now this file also carried every board schema as an OCaml literal --
    1,300 lines of them. Their own comments say what they were: the rows
    "byte-equal the deleted literals", the projections "return the deleted
    projection literals". They were the migration pin that proved
    [config/tools/*.toml] said what the OCaml it replaced had said. The
    declarations live in the TOML now and [Masc.Config.raw_all_tool_schemas]
    is those files decoded, so comparing them against a snapshot of themselves
    could only report that someone edited a description.

    [declared_identity_fields] stays. It is an exhaustive match on
    [Tool_name.Board_name.t], so a new board tool does not compile until
    someone says which fields the runtime fills in for it -- the compiler
    carries that claim, not the literal. *)

open Alcotest

let board_prefix = "masc_board"

let is_board_row (schema : Masc_domain.tool_schema) =
  String.starts_with ~prefix:board_prefix schema.name
;;

let published_order =
  [ Tool_name.Board_name.Board_post
  ; Tool_name.Board_name.Board_post_update
  ; Tool_name.Board_name.Board_list
  ; Tool_name.Board_name.Board_post_get
  ; Tool_name.Board_name.Board_comment
  ; Tool_name.Board_name.Board_vote
  ; Tool_name.Board_name.Board_stats
  ; Tool_name.Board_name.Board_search
  ; Tool_name.Board_name.Board_comment_vote
  ; Tool_name.Board_name.Board_reaction
  ; Tool_name.Board_name.Board_profile
  ; Tool_name.Board_name.Board_hearths
  ; Tool_name.Board_name.Board_curation_read
  ; Tool_name.Board_name.Board_curation_submit
  ; Tool_name.Board_name.Board_delete
  ; Tool_name.Board_name.Board_cleanup
  ; Tool_name.Board_name.Board_sub_board_create
  ; Tool_name.Board_name.Board_sub_board_list
  ; Tool_name.Board_name.Board_sub_board_get
  ; Tool_name.Board_name.Board_sub_board_update
  ; Tool_name.Board_name.Board_sub_board_delete
  ]
  |> List.map Tool_name.Board_name.to_string
;;

let curated_projections =
  [ "masc_board_post"
  ; "masc_board_list"
  ; "masc_board_comment"
  ; "masc_board_vote"
  ; "masc_board_stats"
  ; "masc_board_search"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ]
;;

let test_the_published_board_rows_are_unchanged () =
  check
    (list string)
    "board rows of raw_all_tool_schemas, in order"
    published_order
    (Masc.Config.raw_all_tool_schemas
     |> List.filter is_board_row
     |> List.map (fun (s : Masc_domain.tool_schema) -> s.name))
;;

let test_exactly_the_curated_names_carry_a_projection () =
  check
    (list string)
    "board names with a keeper projection"
    (List.sort String.compare curated_projections)
    (Tool_name.Board_name.all
     |> List.filter (fun name ->
       Option.is_some (Tool_shard_types.keeper_board_schema name))
     |> List.map Tool_name.Board_name.to_string
     |> List.sort String.compare)
;;

let test_the_projections_reach_the_model_surface () =
  let visible =
    Masc.Keeper_tool_descriptor.model_visible_schemas ()
    |> List.filter is_board_row
    |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)
  in
  List.iter
    (fun name ->
       check bool (name ^ " reaches the model surface") true (List.mem name visible))
    curated_projections
;;

let declared_identity_fields : Tool_name.Board_name.t -> string list = function
  | Tool_name.Board_name.Board_post -> [ "author" ]
  | Tool_name.Board_name.Board_post_update -> [ "author" ]
  | Tool_name.Board_name.Board_list -> []
  | Tool_name.Board_name.Board_post_get -> []
  | Tool_name.Board_name.Board_comment -> [ "author" ]
  | Tool_name.Board_name.Board_vote -> [ "voter" ]
  | Tool_name.Board_name.Board_stats -> []
  | Tool_name.Board_name.Board_search -> []
  | Tool_name.Board_name.Board_comment_vote -> [ "voter" ]
  | Tool_name.Board_name.Board_reaction -> [ "user_id" ]
  | Tool_name.Board_name.Board_profile -> []
  | Tool_name.Board_name.Board_hearths -> []
  | Tool_name.Board_name.Board_curation_read -> []
  | Tool_name.Board_name.Board_curation_submit -> [ "submitted_by" ]
  | Tool_name.Board_name.Board_delete -> [ "author" ]
  | Tool_name.Board_name.Board_cleanup -> []
  | Tool_name.Board_name.Board_sub_board_create -> [ "owner" ]
  | Tool_name.Board_name.Board_sub_board_list -> []
  | Tool_name.Board_name.Board_sub_board_get -> []
  | Tool_name.Board_name.Board_sub_board_update -> [ "owner" ]
  | Tool_name.Board_name.Board_sub_board_delete -> [ "owner" ]
;;

let test_identity_fields_are_the_declared_literals () =
  check int "every board tool is pinned" 21 (List.length Tool_name.Board_name.all);
  List.iter
    (fun board ->
      check
        (list string)
        (Tool_name.Board_name.to_string board)
        (declared_identity_fields board)
        (Board_tool_registry.identity_fields_for_board_name board))
    Tool_name.Board_name.all
;;

let () =
  run "board_tool_toml_parity"
    [ ( "surface"
      , [ test_case "published board rows are unchanged" `Quick
            test_the_published_board_rows_are_unchanged
        ; test_case "exactly the curated names carry a projection" `Quick
            test_exactly_the_curated_names_carry_a_projection
        ; test_case "the projections reach the model surface" `Quick
            test_the_projections_reach_the_model_surface
        ; test_case "identity fields are the declared literals" `Quick
            test_identity_fields_are_the_declared_literals
        ] )
    ]
;;
