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

let test_listing_footers_share_one_shape () =
  let canonical = "j/k:scroll  Esc:overview  r:refresh  Tab:next  q:quit" in
  List.iter
    (fun surface ->
      check str "the plain listings share one footer" canonical
        (Masc_tui_keys.footer_hints surface))
    [ Lanes; Harness; System_logs ]

(* Tools left the plain group when it grew a per-Keeper axis: the pane now
   shows one Keeper's effective tool surface, so it needs a key to change
   which Keeper that is. Pinned on its own rather than dropped from the list
   above -- a surface removed from the shared shape and named nowhere else
   can drift to any footer at all without a test noticing. *)
let test_tools_footer_carries_the_keeper_axis () =
  check str "tools names the effective Keeper switch"
    "j/k:scroll  [/]:Keeper  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Tools)

let test_repositories_footer_offers_the_code_tree () =
  check str "repositories names the Enter jump"
    "j/k:scroll  Enter:browse  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Repositories)

let test_verification_footer_carries_the_verdict_keys () =
  (* Verification left the plain listings when the verdict keys landed: the
     approve is the two-press arm, the reject is the $EDITOR reason form. *)
  check str "verification names approve and reject"
    "j/k:scroll  a:approve  x:reject  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Verification)

let test_fusion_footer_pins_the_shared_list_projection () =
  (* Pin the shared list footer as display data. The PTY scenario separately
     exercises j, r, Enter, PgDn, and detail Esc through the real dispatch. *)
  check str "fusion names its list keys"
    "j/k:move  PgUp / PgDn:page  Right / Enter:detail  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Fusion)

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
  let logs = List.map fst (section "Logs") in
  Alcotest.(check bool) "Logs documents only what is bound" false
    (List.mem "g / G" logs)

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
      , [ Alcotest.test_case "plain listings share one footer" `Quick
            test_listing_footers_share_one_shape
        ; Alcotest.test_case "Tools carries the Keeper axis" `Quick
            test_tools_footer_carries_the_keeper_axis
        ; Alcotest.test_case "Repositories offers the Code tree" `Quick
            test_repositories_footer_offers_the_code_tree
        ; Alcotest.test_case "Verification carries the verdict keys" `Quick
            test_verification_footer_carries_the_verdict_keys
        ; Alcotest.test_case "Fusion pins the shared list projection" `Quick
            test_fusion_footer_pins_the_shared_list_projection
        ; Alcotest.test_case "Overview footer projects by focus" `Quick
            test_overview_footer_projects_by_focus
        ; Alcotest.test_case "System logs lost the keys it never had" `Quick
            test_system_logs_lost_the_keys_it_never_had
        ; Alcotest.test_case "help documents what was missing" `Quick
            test_help_documents_what_was_missing
        ] )
    ]
