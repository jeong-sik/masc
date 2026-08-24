(* The tool inventory as rows: domain headings, family headings, tool rows.
   Spelling alone scattered the task tools across five families and two
   family-less names; the domain layer groups by purpose. *)

open Alcotest

module Tree = Masc_tui_tool_tree
module Decode = Masc.Tui_decode

let tool ?(surfaces = [ "mcp" ]) ?(direct = false) name : Decode.tool_entry =
  { tl_name = name
  ; tl_description = ""
  ; tl_surfaces = surfaces
  ; tl_direct_call = direct
  }

let shape rows =
  List.map
    (function
      | Tree.Domain { name; count } -> Printf.sprintf "{%s %d}" name count
      | Tree.Family { name; count } -> Printf.sprintf "[%s %d]" name count
      | Tree.Tool t -> t.Decode.tl_name)
    rows

let test_a_shared_prefix_becomes_a_heading_under_its_domain () =
  check (list string) "domain, family, then the tools"
    [ "{board 2}"; "[masc_board 2]"; "masc_board_list"; "masc_board_post" ]
    (shape (Tree.rows [ tool "masc_board_list"; tool "masc_board_post" ]))
;;

(* The reason the domain layer exists: the task tools spell five different
   families (masc_add, masc_batch, masc_task, masc_goal, masc_plan) and two
   family-less names (masc_tasks, masc_transition). One domain heading
   absorbs the fragments that spelling produced. *)
let test_the_task_fragments_share_one_domain () =
  check (list string) "five spellings, one heading, name order inside"
    [ "{work 5}"
    ; "[masc_add 1]"
    ; "masc_add_task"
    ; "[masc_batch 1]"
    ; "masc_batch_add_tasks"
    ; "[masc_task 1]"
    ; "masc_task_history"
    ; "masc_tasks"
    ; "masc_transition"
    ]
    (shape
       (Tree.rows
          [ tool "masc_task_history"
          ; tool "masc_add_task"
          ; tool "masc_tasks"
          ; tool "masc_transition"
          ; tool "masc_batch_add_tasks"
          ]))
;;

(* A name no rule claims is shown as unsorted rather than silently filed
   under a neighbour: an operator reading the surface can see the gap and
   add the rule. *)
let test_an_unclaimed_name_lands_in_unsorted () =
  (* Unsorted is the last section, not the first: the fixed domain order is
     about the operator's reading order, and the known domains stay ahead of
     whatever the rules have not met yet. *)
  check (list string) "no rule, no borrowed domain"
    [ "{board 2}"; "[masc_board 2]"; "masc_board_list"; "masc_board_post"
    ; "{unsorted 1}"; "[masc_agent 1]"; "masc_agent_card" ]
    (shape
       (Tree.rows
          [ tool "masc_agent_card"; tool "masc_board_list"; tool "masc_board_post" ]))
;;

let test_domain_rules () =
  let check_domain label expected name =
    check (option string) label expected (Tree.domain_of_tool name)
  in
  check_domain "board tools are board" (Some "board") "masc_board_post";
  check_domain "exact two-segment name still matches" (Some "run") "masc_fusion";
  check_domain "the family-less task list is work" (Some "work") "masc_tasks";
  check_domain "keeper voice is keeper self" (Some "keeper self")
    "keeper_voice_speak";
  check_domain "config is system" (Some "system") "masc_config";
  check_domain "keeper lifecycle is keeper ops" (Some "keeper ops")
    "masc_keeper_up";
  check_domain "unknown prefix claims nothing" None "masc_future_thing"
;;

(* The surface reads top to bottom in the fixed domain order whatever order
   the inventory arrived in. *)
let test_the_display_order_is_fixed () =
  check (list string) "keeper ops sorts before board only in name order"
    [ "{board 2}"; "[masc_board 2]"; "masc_board_list"; "masc_board_post"
    ; "{keeper ops 2}"; "[masc_keeper 2]"; "masc_keeper_down"; "masc_keeper_up"
    ]
    (shape
       (Tree.rows
          [ tool "masc_keeper_up"
          ; tool "masc_keeper_down"
          ; tool "masc_board_post"
          ; tool "masc_board_list"
          ]))
;;

let test_the_count_says_tools_not_rows () =
  let rows = Tree.rows [ tool "masc_board_list"; tool "masc_board_post" ] in
  check int "four rows, two of them tools" 4 (List.length rows);
  check int "the header should say two" 2 (Tree.tool_count rows)
;;

let () =
  run
    "tui_tool_tree"
    [ ( "domains"
      , [ test_case "a shared prefix becomes a heading under its domain" `Quick
            test_a_shared_prefix_becomes_a_heading_under_its_domain
        ; test_case "the task fragments share one domain" `Quick
            test_the_task_fragments_share_one_domain
        ; test_case "an unclaimed name lands in unsorted" `Quick
            test_an_unclaimed_name_lands_in_unsorted
        ; test_case "domain rules" `Quick test_domain_rules
        ; test_case "the display order is fixed" `Quick
            test_the_display_order_is_fixed
        ; test_case "the count says tools, not rows" `Quick
            test_the_count_says_tools_not_rows
        ] )
    ]
;;
