(** Which tool_type labels the real tool surface actually produces.

    [tool_type_of_name] carried five arms that could not match anything
    [Keeper_tool_policy.keeper_model_tool_names] returns: the [mcp__masc__],
    [board_], [memory_], [library_] and [surface_] prefixes. Counting matches
    over those 99 names gives masc_ 67, Board_name 21, and one each for grep,
    read, write, edit and execute.

    The last three arms were aimed at tools that exist under other names.
    keeper_memory_search, keeper_memory_retract, keeper_memory_write,
    keeper_library_search,
    keeper_library_read, keeper_surface_read and keeper_surface_post carry a
    keeper_ prefix, so they land in "other". These cases pin that as the
    current answer rather than leaving it to be rediscovered — changing it
    moves six tools to a different metric dimension value. *)

open Alcotest

module T = Masc.Tool_telemetry

let keeper_tools () = Masc.Keeper_tool_policy.keeper_model_tool_names ()

(* A guard over an empty surface passes by testing nothing. *)
let test_surface_is_populated () =
  let names = keeper_tools () in
  check bool "the keeper tool surface is non-empty" true (names <> []);
  check bool "and includes a board tool" true
    (List.exists (fun n -> n = "masc_board_post") names)
;;

let label_counts names =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun n ->
      let l = T.tool_type_of_name n in
      Hashtbl.replace tbl l (1 + Option.value ~default:0 (Hashtbl.find_opt tbl l)))
    names;
  tbl
;;

(* No name on the surface earns these; the arms that produced them are gone. *)
let test_no_surface_tool_is_labelled_memory () =
  let counts = label_counts (keeper_tools ()) in
  check (option int) "memory is not produced" None (Hashtbl.find_opt counts "memory")
;;

let test_board_and_mcp_are_produced () =
  let counts = label_counts (keeper_tools ()) in
  List.iter
    (fun label ->
      match Hashtbl.find_opt counts label with
      | Some n when n > 0 -> ()
      | _ -> failf "%s is no longer produced by any tool on the surface" label)
    [ "mcp"; "board" ]
;;

(* Board tools must keep their own label: the Board_name test runs before the
   masc_ prefix, and losing that order would relabel 21 tools as mcp. *)
let test_board_tools_are_not_labelled_mcp () =
  check string "masc_board_post" "board" (T.tool_type_of_name "masc_board_post");
  check string "masc_board_list" "board" (T.tool_type_of_name "masc_board_list")
;;

(* The six the removed arms were aiming at. This is the mislabelling, pinned. *)
let test_keeper_prefixed_tools_fall_to_other () =
  List.iter
    (fun name -> check string name "other" (T.tool_type_of_name name))
    [ "keeper_memory_search"
    ; "keeper_memory_retract"
    ; "keeper_memory_write"
    ; "keeper_library_search"
    ; "keeper_library_read"
    ; "keeper_surface_read"
    ; "keeper_surface_post"
    ]
;;

(* The catalog is the first authority: where a tool declares [readonly], that
   declaration decides read-vs-write instead of the name. keeper_tasks_list is
   28% of recorded calls and read-only; the name chain labelled it "other". *)
let test_catalog_declaration_beats_the_name_chain () =
  List.iter
    (fun (name, expected) -> check string name expected (T.tool_type_of_name name))
    [ "keeper_tasks_list", "read"
    ; "keeper_tools_list", "read"
    ; "keeper_capability_search", "read"
    ; "keeper_task_claim", "write"
    ; "keeper_task_done", "write"
    ]
;;

let test_external_tool_names_keep_their_labels () =
  List.iter
    (fun (name, expected) -> check string name expected (T.tool_type_of_name name))
    [ "Grep", "read"; "Read", "read"; "Write", "write"; "Edit", "write"
    ; "Execute", "execute"; "WebSearch", "other"
    ]
;;

let () =
  Alcotest.run
    "Tool type label"
    [ ( "surface"
      , [ test_case "is populated" `Quick test_surface_is_populated
        ; test_case "produces mcp and board" `Quick test_board_and_mcp_are_produced
        ; test_case "produces no memory label" `Quick
            test_no_surface_tool_is_labelled_memory
        ] )
    ; ( "labels"
      , [ test_case "board tools are not mcp" `Quick test_board_tools_are_not_labelled_mcp
        ; test_case "keeper-prefixed tools fall to other" `Quick
            test_keeper_prefixed_tools_fall_to_other
        ; test_case "catalog declaration beats the name chain" `Quick
            test_catalog_declaration_beats_the_name_chain
        ; test_case "external tool names keep their labels" `Quick
            test_external_tool_names_keep_their_labels
        ] )
    ]
;;
