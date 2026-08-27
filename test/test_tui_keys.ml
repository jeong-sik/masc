(* The display contracts of the key table.

   The table exists so footers and the help overlay stop drifting; these
   tests pin the conventions (one spelling per key, one order per screen)
   and the specific drifts the table was written to close. *)

open Masc_tui_types

let check = Alcotest.check
let str = Alcotest.string

let every_surface =
  [ Overview; Acting; Keepers Keeper_list; Keepers Keeper_detail
  ; Keepers Keeper_logs; Keepers Keeper_calls; Keepers Keeper_message
  ; Keepers Keeper_runtime_pick; Lanes; Board; Approvals; Planning
  ; Schedules; Verification; Harness; Fusion; Repositories; Changes
  ; Connectors; Runtime; Config; Resources; Tools; System_logs
  ]

let test_every_surface_answers () =
  List.iter
    (fun surface ->
      Alcotest.(check bool)
        "a surface with no bindings has no footer and no help row" true
        (Masc_tui_keys.for_surface surface <> []))
    every_surface

let test_no_surface_repeats_a_key () =
  List.iter
    (fun surface ->
      let keys =
        List.map
          (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
          (Masc_tui_keys.for_surface surface)
      in
      Alcotest.(check int)
        "each key appears once per surface"
        (List.length keys)
        (List.length (List.sort_uniq compare keys)))
    every_surface

let test_one_spelling_per_key () =
  (* The old footers wrote Esc, esc, and enter for the same keys. *)
  List.iter
    (fun surface ->
      List.iter
        (fun (b : Masc_tui_keys.binding) ->
          let k = b.Masc_tui_keys.key in
          Alcotest.(check bool)
            (Printf.sprintf "%S spells its key canonically" k)
            false
            (List.mem k [ "esc"; "enter"; "tab"; "ESC"; "Return" ]))
        (Masc_tui_keys.for_surface surface))
    every_surface

let test_plain_listing_footer_shape () =
  let canonical = "j/k:scroll  Esc:overview  r:refresh  Tab:next  q:quit" in
  check str "the plain listing keeps its footer" canonical
    (Masc_tui_keys.footer_hints System_logs)

let test_lanes_footer_opens_the_selected_keeper () =
  check str "Lanes names its Keeper detail and chat jumps"
    "j/k:move  Right / Enter:detail  c / m:chat  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Lanes)

let test_lanes_scroll_reserves_standalone_matrix_rows () =
  check Alcotest.int
    "loading row plus title and divider"
    3
    (standalone_lanes_chrome ~row_count:None ~error:None ~truncated:false);
  check Alcotest.int
    "five lane rows plus title and divider"
    7
    (standalone_lanes_chrome
       ~row_count:(Some 5)
       ~error:None
       ~truncated:false);
  check Alcotest.int
    "retained rows plus explicit stale warning"
    8
    (standalone_lanes_chrome
       ~row_count:(Some 5)
       ~error:(Some "offline")
       ~truncated:false);
  check Alcotest.int
    "bounded-window warning spends one row"
    8
    (standalone_lanes_chrome
       ~row_count:(Some 5)
       ~error:None
       ~truncated:true)
;;

let test_harness_footer_links_to_overview_task () =
  check str "Harness names its task link"
    "j/k:move  PgUp/PgDn:page  Right / Enter:verdict  Left / Esc:back  Y:copy task  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Harness)

(* Tools left the plain group when it grew a per-Keeper axis: the pane now
   shows one Keeper's effective tool surface, so it needs a key to change
   which Keeper that is. Pinned on its own rather than dropped from the list
   above -- a surface removed from the shared shape and named nowhere else
   can drift to any footer at all without a test noticing. *)
let test_tools_footer_carries_the_keeper_axis () =
  check str "tools names the effective Keeper switch"
    "j/k:scroll  J/K:Skill  [/]:Keeper  e:edit Skill  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Tools)

let test_repositories_footer_offers_the_code_tree () =
  check str "repositories names the Enter jump"
    "j/k:scroll  Enter:browse  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Repositories)

let test_verification_footer_carries_the_verdict_keys () =
  (* Verification is a list/detail surface: Enter explains the request before
     the two-press approve or the $EDITOR reject reason changes it. *)
  check str "verification names detail, approve, and reject"
    "j/k:move  Right / Enter:details  Left / Esc:back  a:approve  x:reject  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Verification)

let test_fusion_footer_pins_the_shared_list_projection () =
  (* Pin the shared list footer as display data. The PTY scenario separately
     exercises j, r, Enter, PgDn, and detail Esc through the real dispatch. *)
  check str "fusion names its list keys"
    "j/k:move  PgUp/PgDn:page  Enter:detail  Y:copy  Esc:back  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Fusion)

let test_lanes_run_list_footer_names_the_drill_down () =
  check str "the standalone lane run list names open and back"
    "j/k:move  Right / Enter:prompt  Left / Esc:back  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_lanes_run_list

let test_lanes_run_detail_footer_appends_the_scroll_position () =
  check str "the run detail footer carries its live scroll position"
    "j/k:scroll  PgUp/PgDn:page  Left / Esc:back  r:refresh  Tab:next  q:quit  (3/40)"
    (Masc_tui_keys.footer_hints_lanes_run_detail ~scroll:3 ~max_scroll:40)

let test_overview_footer_projects_by_focus () =
  (* The retired literal said "j/k:events  t:tasks  q:quit  r:refresh
     Tab:next  2:keepers" (and "j/k:tasks  Enter:detail  esc:events …").
     The projection keeps every pair, relabels j/k by focus, and drops the
     keys that are dead in the other mode: t only leaves the event list,
     Right/Enter and Left/Esc only act on a focused task. h/l stays visible
     because it selects either pane directly. *)
  check str "events mode keeps t and drops the task keys"
    "j/k:events  h/l:pane  t:tasks  2:keepers  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints_overview ~task_focus:false);
  check str "tasks mode keeps arrow/Enter/Esc and drops t"
    "j/k:tasks  h/l:pane  Right / Enter:open  Left / Esc:back  2:keepers  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints_overview ~task_focus:true)

let test_planning_footer_carries_filter_and_sort () =
  check str "planning names filter and sort"
    "j/k:move  f:filter  s:sort  Right / Enter:detail  Left / Esc:back  c:complete  x:drop  o:reopen  Y:copy link  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Planning)

let test_system_logs_lost_the_keys_it_never_had () =
  (* The old help table documented g, G, and f on System logs; the dispatch
     binds them on Acting only. *)
  let keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface System_logs)
  in
  Alcotest.(check bool) "no g/G on System logs" false (List.mem "g / G" keys);
  Alcotest.(check bool) "no f on System logs" false (List.mem "f" keys);
  let acting =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Acting)
  in
  Alcotest.(check bool) "g/G stays on Acting" true (List.mem "g / G" acting);
  Alcotest.(check bool) "f stays on Acting" true (List.mem "f" acting)

let section name =
  match List.assoc_opt name (Masc_tui_keys.help_sections ()) with
  | Some entries -> entries
  | None -> Alcotest.failf "help has no %S section" name

let test_help_documents_what_was_missing () =
  (* Changes shipped Enter/d/o with no help section; the palette had no row
     anywhere. *)
  let changes = List.map fst (section "Changes") in
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf "Changes documents %S" key)
        true (List.mem key changes))
    [ "[ / ]"; "Right / Enter"; "Left / Esc"; "d"; "o" ];
  let global = List.map fst (section "Global") in
  Alcotest.(check bool) "the palette has a row" true (List.mem ":" global);
  Alcotest.(check bool) "the cross-surface Keepers jump has a row" true
    (List.mem "2" global);
  let logs = List.map fst (section "Logs") in
  Alcotest.(check bool) "Logs documents only what is bound" false
    (List.mem "g / G" logs)

let test_keepers_jump_uses_one_binding_for_dispatch_and_help () =
  let global_twos =
    List.filter
      (fun (binding : Masc_tui_keys.binding) -> String.equal binding.key "2")
      Masc_tui_keys.global
  in
  Alcotest.(check int) "Global declares 2 once" 1 (List.length global_twos);
  Alcotest.(check bool) "2 opens Keepers after local input declines it" true
    (Masc_tui_keys.opens_keepers ~message_mode:false "2");
  Alcotest.(check bool) "message input keeps printable 2" false
    (Masc_tui_keys.opens_keepers ~message_mode:true "2");
  Alcotest.(check bool) "another key does not open Keepers" false
    (Masc_tui_keys.opens_keepers ~message_mode:false "x");
  Alcotest.(check string) "Help states the local-owner boundary"
    "jump to Keepers when the active field or panel does not use 2"
    (List.assoc "2" (section "Global"));
  let overview_keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface Overview)
  in
  Alcotest.(check bool) "2 is not an Overview-only binding" false
    (List.mem "2" overview_keys)

(* The sheet opens on the reader's own surface. Without this the answer to
   "what can I do here" sat behind nineteen other surfaces, in strip order,
   and the reader had to search a reference for it. *)
let test_the_sheet_opens_on_the_current_surface () =
  List.iter
    (fun (name, surface, expected) ->
       match Masc_tui_keys.help_sections ~current:surface () with
       | (title, keys) :: _ ->
           Alcotest.(check bool)
             (name ^ ": names the surface first")
             true
             (String.length title >= String.length expected
              && String.equal (String.sub title 0 (String.length expected))
                   expected);
           (* The section has to be that surface's, not just titled like it. *)
           Alcotest.(check (list (pair string string)))
             (name ^ ": and carries its keys")
             (List.map
                (fun (b : Masc_tui_keys.binding) ->
                   (b.key, Option.value b.help ~default:b.label))
                (Masc_tui_keys.for_surface surface))
             keys
       | [] -> Alcotest.fail (name ^ ": no sections at all"))
    [ ("Overview", Overview, "Overview")
    ; ("Keepers", Keepers Keeper_list, "Keepers")
    ; ("Chat", Keepers Keeper_message, "Chat")
    ; ("Config", Config, "Config")
    ]

(* The Keepers sub-modes are one entry on the strip and three sections here.
   Matching by ring position would hand a reader in the chat the roster's
   keys, which is the drift this argument exists to prevent. *)
let test_the_keeper_sub_modes_do_not_share_a_section () =
  let first surface =
    match Masc_tui_keys.help_sections ~current:surface () with
    | (title, _) :: _ -> title
    | [] -> "none"
  in
  Alcotest.(check bool)
    "the roster and the chat open on different sections" false
    (String.equal (first (Keepers Keeper_list)) (first (Keepers Keeper_message)))

(* Asked without a surface, the sheet reads as it did before it knew where the
   reader was: Global, then the strip's order. *)
let test_without_a_surface_the_order_is_the_strips () =
  match Masc_tui_keys.help_sections () with
  | (title, _) :: (second, _) :: _ ->
      Alcotest.(check string) "Global first" "Global" title;
      Alcotest.(check string) "then the strip's first surface" "Overview" second
  | _ -> Alcotest.fail "expected at least two sections"

let () =
  Alcotest.run "masc_tui_keys"
    [ ( "table"
      , [ Alcotest.test_case "every surface answers" `Quick
            test_every_surface_answers
        ; Alcotest.test_case "no surface repeats a key" `Quick
            test_no_surface_repeats_a_key
        ; Alcotest.test_case "one spelling per key" `Quick
            test_one_spelling_per_key
        ] )
    ; ( "projections"
      , [ Alcotest.test_case "plain listing footer shape" `Quick
            test_plain_listing_footer_shape
        ; Alcotest.test_case "Tools carries the Keeper axis" `Quick
            test_tools_footer_carries_the_keeper_axis
        ; Alcotest.test_case "Lanes opens the selected Keeper" `Quick
            test_lanes_footer_opens_the_selected_keeper
        ; Alcotest.test_case "Lanes reserves standalone matrix rows" `Quick
            test_lanes_scroll_reserves_standalone_matrix_rows
        ; Alcotest.test_case "Harness links to Overview task" `Quick
            test_harness_footer_links_to_overview_task
        ; Alcotest.test_case "Repositories offers the Code tree" `Quick
            test_repositories_footer_offers_the_code_tree
        ; Alcotest.test_case "Verification carries the verdict keys" `Quick
            test_verification_footer_carries_the_verdict_keys
        ; Alcotest.test_case "Fusion pins the shared list projection" `Quick
            test_fusion_footer_pins_the_shared_list_projection
        ; Alcotest.test_case "Lanes run list names the drill-down" `Quick
            test_lanes_run_list_footer_names_the_drill_down
        ; Alcotest.test_case "Lanes run detail appends the scroll position" `Quick
            test_lanes_run_detail_footer_appends_the_scroll_position
        ; Alcotest.test_case "Overview footer projects by focus" `Quick
            test_overview_footer_projects_by_focus
        ; Alcotest.test_case "System logs lost the keys it never had" `Quick
            test_system_logs_lost_the_keys_it_never_had
        ; Alcotest.test_case "Planning carries filter and sort" `Quick
            test_planning_footer_carries_filter_and_sort
        ; Alcotest.test_case "help documents what was missing" `Quick
            test_help_documents_what_was_missing
        ; Alcotest.test_case "Keepers jump shares dispatch and help" `Quick
            test_keepers_jump_uses_one_binding_for_dispatch_and_help
        ; Alcotest.test_case "the sheet opens on the current surface" `Quick
            test_the_sheet_opens_on_the_current_surface
        ; Alcotest.test_case "keeper sub-modes do not share a section" `Quick
            test_the_keeper_sub_modes_do_not_share_a_section
        ; Alcotest.test_case "without a surface the order is the strip's" `Quick
            test_without_a_surface_the_order_is_the_strips
        ] )
    ]
