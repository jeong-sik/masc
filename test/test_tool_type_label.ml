(** Which tool_type labels the real tool surface actually produces.

    [tool_type_of_name] carried five arms that could not match anything
    [Keeper_tool_policy.keeper_model_tool_names] returns: the [mcp__masc__],
    [board_], [memory_], [library_] and [surface_] prefixes. Counting matches
    over those 99 names gives masc_ 67, Board_name 21, and one each for grep,
    read, write, edit and execute.

    The last three arms were aimed at tools that exist under other names.
    keeper_memory_search, keeper_memory_retract, keeper_memory_write,
    keeper_wiki_search,
    keeper_wiki_read, keeper_surface_read and keeper_surface_post carry a
    keeper_ prefix, so no prefix arm ever matched them. Each one declares
    whether it reads or writes, and that declaration is its label.

    Since #49742 the remaining name chain (read/write/edit/execute prefixes
    and the "grep" literal) is gone too: a label comes from the catalog's
    [readonly] or the descriptor's [policy.readonly_hint] / [executor], and a
    name that declares nothing is "other" however it is spelled. *)

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

(* The tools the removed arms were aiming at. Since #49742 each takes the
   label its own declaration gives, read or write, not "other". *)
let test_keeper_prefixed_tools_take_their_declared_label () =
  List.iter
    (fun (name, expected) -> check string name expected (T.tool_type_of_name name))
    [ "keeper_memory_search", "read"
    ; "keeper_memory_retract", "write"
    ; "keeper_memory_write", "write"
    ; "keeper_wiki_search", "read"
    ; "keeper_wiki_read", "read"
    ; "keeper_surface_read", "read"
    ; "keeper_surface_post", "write"
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

(* The keeper's own tools are descriptors, not catalog rows; their labels come
   from the descriptor's closed fields — [policy.readonly_hint] for read and
   write, [executor = Shell_ir] without a read-only declaration for execute —
   never from the verb their names happen to be. *)
let test_descriptor_declarations_label_the_keeper_tools () =
  List.iter
    (fun (name, expected) -> check string name expected (T.tool_type_of_name name))
    [ "Grep", "read"; "Read", "read"; "Write", "write"; "Edit", "write"
    ; "Execute", "execute"
    ; (* the same tools under their internal names, as the MCP surface sees them *)
      "tool_read_file", "read"; "tool_write_file", "write"; "tool_execute", "execute"
    ]
;;

(* #49742: the name chain is gone. A name that only looks like a verb — an
   attached service's read_file, a tool nobody declared — is "other", and a
   catalog-declared read-only tool stays "read" whatever it is called. *)
let test_undeclared_names_are_other_whatever_they_spell () =
  List.iter
    (fun name -> check string name "other" (T.tool_type_of_name name))
    [ "read_file"; "write_notes"; "edit_page"; "execute_plan"; "grep"; "readme_fetch" ]
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
        ; test_case "keeper-prefixed tools take their declared label" `Quick
            test_keeper_prefixed_tools_take_their_declared_label
        ; test_case "catalog declaration beats the name chain" `Quick
            test_catalog_declaration_beats_the_name_chain
        ; test_case "descriptor declarations label the keeper tools" `Quick
            test_descriptor_declarations_label_the_keeper_tools
        ; test_case "undeclared names are other whatever they spell" `Quick
            test_undeclared_names_are_other_whatever_they_spell
        ] )
    ]
;;
