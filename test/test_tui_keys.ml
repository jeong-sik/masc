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
    "six lane rows plus title and divider"
    8
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:None
       ~truncated:false);
  check Alcotest.int
    "retained rows plus explicit stale warning"
    9
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:(Some "offline")
       ~truncated:false);
  check Alcotest.int
    "bounded-window warning spends one row"
    9
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:None
       ~truncated:true)
;;

let test_harness_footer_links_to_overview_task () =
  check str "Harness names its task link"
    "j/k:move  PgUp/PgDn:page  Right / Enter:verdict  Left / Esc:back  y:agree  n:overrule  Y:copy task  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Harness)

(* Tools left the plain group when it grew a per-Keeper axis: the pane now
   shows one Keeper's effective tool surface, so it needs a key to change
   which Keeper that is. Pinned on its own rather than dropped from the list
   above -- a surface removed from the shared shape and named nowhere else
   can drift to any footer at all without a test noticing. *)
let test_tools_footer_carries_the_keeper_axis () =
  check str "tools names the effective Keeper switch"
    "j/k:scroll  Home/End:top/bottom  p:section  J/K:Skill  [/]:Keeper  e:edit Skill  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Tools)

let test_repositories_footer_offers_the_code_tree () =
  check str "repositories names the Enter jump"
    "j/k:scroll  Enter:browse  Esc:overview  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Repositories)

let test_verification_footer_carries_the_verdict_keys () =
  (* Verification is a list/detail surface: Enter explains the request before
     the two-press approve or the $EDITOR reject reason changes it. *)
  check str "verification names detail, approve, and reject"
    "j/k:move  v:Goals  Right / Enter:details  Left / Esc:back  a:approve  x:reject  r:refresh  Tab:next  q:quit"
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
    "j/k:move  v:Task Review  f:filter  s:sort  Right / Enter:detail  Left / Esc:back  c:complete  x:drop  o:reopen  Y:copy link  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Planning)

let test_task_review_is_a_planning_child () =
  Alcotest.(check bool) "Task Review is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Verification) surface_ring);
  Alcotest.(check int) "Task Review highlights Planning"
    (surface_ring_index Planning)
    (surface_ring_index Verification)

(* Changes reads one keeper's file writes and binds to the roster cursor on
   entry, so it opens with [f] from the roster instead of holding a Tab stop
   of its own. *)
let test_changes_is_a_keeper_child () =
  Alcotest.(check bool) "Changes is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Changes) surface_ring);
  Alcotest.(check int) "Changes highlights Keepers"
    (surface_ring_index (Keepers Keeper_list))
    (surface_ring_index Changes)

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

(* --- Lanes drill-down: the lane notice, the combined "/" search list, and
   the click geometry of the overview frame. --- *)

let standalone_lane ~lane_id ~label : Tui_decode.standalone_lane =
  { Tui_decode.sl_lane_id = lane_id
  ; sl_label = label
  ; sl_required = false
  ; sl_status = Tui_decode.Standalone_idle
  ; sl_configuration_state = "ready"
  ; sl_admitted_slots = []
  ; sl_cli_slots = []
  ; sl_dropped_slots = []
  ; sl_admission_error = None
  ; sl_retained_run_count = 0
  ; sl_running_count = 0
  ; sl_succeeded_count = 0
  ; sl_failed_count = 0
  ; sl_cancelled_count = 0
  ; sl_last_started_at = None
  ; sl_last_terminal_at = None
  ; sl_last_outcome = None
  ; sl_p50_elapsed_s = None
  ; sl_selected_slots = []
  }

(* The four lanes the projection fixes, in its order
   (server_standalone_lane_projection.ml). *)
let four_standalone_lanes =
  [ standalone_lane ~lane_id:"board_attention_exact" ~label:"Board Attention"
  ; standalone_lane ~lane_id:"hitl_auto_judge" ~label:"HITL Auto Judge"
  ; standalone_lane ~lane_id:"librarian_exact" ~label:"Librarian"
  ; standalone_lane ~lane_id:"verifier_exact" ~label:"Verifier"
  ]

let standalone_snapshot lanes : Tui_decode.standalone_lanes_snapshot =
  { Tui_decode.sls_observed_at_unix = 0.
  ; sls_exact_run_projection_count = 0
  ; sls_exact_run_source_total = 0
  ; sls_exact_run_projection_truncated = false
  ; sls_lanes = lanes
  }

let keeper_lane name : Tui_decode.keeper_lane =
  { Tui_decode.kl_keeper = name
  ; kl_phase = Tui_decode.Lane_phase_running
  ; kl_turn_phase = Tui_decode.Lane_turn_idle
  ; kl_idle_seconds = 0
  ; kl_last_outcome = None
  ; kl_diagnosis = None
  }

let keeper_snapshot lanes : Tui_decode.keeper_lanes_snapshot =
  { Tui_decode.kls_generated_at = 0.
  ; kls_count = List.length lanes
  ; kls_lanes = lanes
  }

let lanes_state ?(keepers = [ "alpha"; "beta" ]) () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Lanes;
  state.standalone_lanes <- Some (standalone_snapshot four_standalone_lanes);
  state.lanes <- Some (keeper_snapshot (List.map keeper_lane keepers));
  state

let test_lane_notice_footer_names_the_way_back () =
  (* The notice is static: no j/k, no Enter -- only the way back and the
     shared tail. *)
  check str "the lane notice keeps only the way back"
    "Left / Esc:back  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_lane_notice

let test_lane_notice_says_what_is_recorded () =
  let rendered =
    List.map
      (function
        | Lane_notice_heading text -> "H" ^ text
        | Lane_notice_text text -> "T" ^ text
        | Lane_notice_dim text -> "D" ^ text)
      verifier_lane_notice_lines
  in
  Alcotest.(check (list string))
    "the notice names the boundary and where to read runs"
    [ "H  This lane records no LLM prompt/output"
    ; "T"
    ; "T  Verifier runs are kept by the verification registries, not the"
    ; "T  exact-lane run store. A run records its outcome, elapsed time, and"
    ; "T  tool observations with output excerpts -- never a prompt."
    ; "T"
    ; "D  Read them in Planning > Task Review: press v from Planning, or :"
    ; "D  and type \"go Task Review\"."
    ]
    rendered

let test_lanes_search_texts_lead_with_the_standalone_labels () =
  let state = lanes_state () in
  Alcotest.(check (option (list string)))
    "standalone labels first, then Keeper names"
    (Some
       [ "Board Attention"; "HITL Auto Judge"; "Librarian"
       ; "Verifier"; "alpha"; "beta" ])
    (surface_row_texts state Lanes)

let test_lanes_sub_modes_stay_unsearchable () =
  let state = lanes_state () in
  state.lanes_mode <- Lanes_run_list "librarian_exact";
  Alcotest.(check (option (list string))) "run list keeps / closed" None
    (surface_row_texts state Lanes);
  state.lanes_mode <- Lanes_lane_notice "verifier_exact";
  Alcotest.(check (option (list string))) "lane notice keeps / closed" None
    (surface_row_texts state Lanes)

let hit_to_string = function
  | Lanes_hit_standalone index -> Printf.sprintf "standalone %d" index
  | Lanes_hit_keeper index -> Printf.sprintf "keeper %d" index
  | Lanes_hit_none -> "none"

let check_hit state ~terminal_rows ~row expected =
  check str (Printf.sprintf "row %d" row) expected
    (hit_to_string (lanes_overview_hit state ~terminal_rows ~row))

(* The overview frame, row by row: 1 strip, 2 box top, 3 header, 4 divider,
   5 matrix heading, 6-9 the four standalone rows, 10 divider, 11 Keeper
   column header, 12 divider, 13 on the Keeper rows. *)
let test_overview_hit_reads_the_frame_rows () =
  let state = lanes_state () in
  check_hit state ~terminal_rows:40 ~row:5 "none";
  check_hit state ~terminal_rows:40 ~row:6 "standalone 0";
  check_hit state ~terminal_rows:40 ~row:9 "standalone 3";
  check_hit state ~terminal_rows:40 ~row:10 "none";
  check_hit state ~terminal_rows:40 ~row:12 "none";
  check_hit state ~terminal_rows:40 ~row:13 "keeper 0";
  check_hit state ~terminal_rows:40 ~row:14 "keeper 1";
  check_hit state ~terminal_rows:40 ~row:15 "none"

let test_overview_hit_pays_for_the_error_rows () =
  let state = lanes_state () in
  state.lanes_error <- Some "lane fixture failed";
  (* One load error spends a row and a divider before the first Keeper row. *)
  check_hit state ~terminal_rows:40 ~row:14 "none";
  check_hit state ~terminal_rows:40 ~row:15 "keeper 0";
  state.lanes_action_error <- Some "Cannot open detail: no lane is selected";
  check_hit state ~terminal_rows:40 ~row:16 "none";
  check_hit state ~terminal_rows:40 ~row:17 "keeper 0"

let test_overview_hit_waits_for_the_matrix () =
  (* The matrix's single loading note is not a lane row. *)
  let state = lanes_state () in
  state.standalone_lanes <- None;
  check_hit state ~terminal_rows:40 ~row:6 "none";
  check_hit state ~terminal_rows:40 ~row:9 "none";
  check_hit state ~terminal_rows:40 ~row:10 "keeper 0"

let test_overview_hit_follows_the_window () =
  (* A scrolled window: content height 1, scroll 1, so the one visible Keeper
     row names the second Keeper. *)
  let state = lanes_state ~keepers:[ "alpha"; "beta"; "gamma" ] () in
  state.lanes_scroll <- 1;
  check_hit state ~terminal_rows:16 ~row:13 "keeper 1";
  check_hit state ~terminal_rows:16 ~row:14 "none"

(* The detail tabs used to draw a hand-written hint string in the renderer,
   a second key list this module did not own. The strip must project the
   table, and the sheet must carry the same keys -- otherwise the two can
   name different things again, which is how [T] ended up documented
   nowhere. *)
let has_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let test_detail_tab_hint_projects_the_table () =
  List.iter
    (fun tab ->
       let hint = Masc_tui_keys.keeper_detail_tab_hint tab in
       Alcotest.(check bool)
         ("the tab switch leads on " ^ keeper_detail_tab_label tab)
         true
         (String.length hint >= 7 && String.sub hint 0 7 = "[ ]:tab");
       List.iter
         (fun (binding : Masc_tui_keys.binding) ->
            Alcotest.(check bool)
              (binding.Masc_tui_keys.key ^ " reaches the strip")
              true
              (has_substring hint
                 (binding.Masc_tui_keys.key ^ ":" ^ binding.Masc_tui_keys.label)))
         (Masc_tui_keys.keeper_detail_tab_bindings tab))
    keeper_detail_tabs

(* The keys each tab's dispatcher arms actually handle, pinned. The earlier
   pair of assertions only checked that whatever the table held reached the
   strip and the sheet, so dropping a binding passed both -- the same shape
   as the drift they were written to close. This list is the contract:
   changing it is a decision, not a slip. Sources are the guarded arms in
   masc_tui.ml (T/A// at Detail_identity, R at Detail_identity, L on the
   GitHub tab, e for the settings form). *)
let live_tab_keys : (Masc_tui_types.keeper_detail_tab * string list) list =
  [ Detail_info, []
  ; Detail_sandbox, [ "R" ]
  ; Detail_instructions, [ "e" ]
  ; Detail_secrets, []
  ; Detail_github, [ "L" ]
  ; Detail_identity, [ "arrows+enter"; "T"; "A"; "/"; "R" ]
  ]

let test_detail_tab_bindings_cover_the_live_keys () =
  List.iter
    (fun (tab, expected) ->
       let actual =
         List.map
           (fun (binding : Masc_tui_keys.binding) -> binding.Masc_tui_keys.key)
           (Masc_tui_keys.keeper_detail_tab_bindings tab)
       in
       Alcotest.(check (list string))
         (keeper_detail_tab_label tab ^ " tab keys")
         expected actual)
    live_tab_keys

let test_detail_tab_keys_reach_the_help_sheet () =
  let sheet = Masc_tui_keys.help_sections ~current:(Keepers Keeper_detail) () in
  let detail_keys =
    List.concat_map
      (fun (title, keys) ->
         if has_substring title "Keeper detail" then List.map fst keys else [])
      sheet
  in
  List.iter
    (fun (binding : Masc_tui_keys.binding) ->
       Alcotest.(check bool)
         (binding.Masc_tui_keys.key ^ " is documented in the sheet")
         true
         (List.exists (String.equal binding.Masc_tui_keys.key) detail_keys))
    (List.concat_map Masc_tui_keys.keeper_detail_tab_bindings keeper_detail_tabs)

let () =
  Alcotest.run "masc_tui_keys"
    [ ( "table"
      , [ Alcotest.test_case "detail tab bindings cover the live keys" `Quick
            test_detail_tab_bindings_cover_the_live_keys
        ; Alcotest.test_case "detail tab strip projects the table" `Quick
            test_detail_tab_hint_projects_the_table
        ; Alcotest.test_case "detail tab keys reach the help sheet" `Quick
            test_detail_tab_keys_reach_the_help_sheet
        ; Alcotest.test_case "every surface answers" `Quick
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
        ; Alcotest.test_case "lane notice footer names the way back" `Quick
            test_lane_notice_footer_names_the_way_back
        ; Alcotest.test_case "lane notice says what is recorded" `Quick
            test_lane_notice_says_what_is_recorded
        ; Alcotest.test_case "Overview footer projects by focus" `Quick
            test_overview_footer_projects_by_focus
        ; Alcotest.test_case "System logs lost the keys it never had" `Quick
            test_system_logs_lost_the_keys_it_never_had
        ; Alcotest.test_case "Planning carries filter and sort" `Quick
            test_planning_footer_carries_filter_and_sort
        ; Alcotest.test_case "Task Review is a Planning child" `Quick
            test_task_review_is_a_planning_child
        ; Alcotest.test_case "Changes is a Keepers child" `Quick
            test_changes_is_a_keeper_child
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
    ; ( "lanes rows"
      , [ Alcotest.test_case "search leads with the standalone labels" `Quick
            test_lanes_search_texts_lead_with_the_standalone_labels
        ; Alcotest.test_case "sub-modes stay unsearchable" `Quick
            test_lanes_sub_modes_stay_unsearchable
        ; Alcotest.test_case "a click reads the frame rows" `Quick
            test_overview_hit_reads_the_frame_rows
        ; Alcotest.test_case "a click pays for the error rows" `Quick
            test_overview_hit_pays_for_the_error_rows
        ; Alcotest.test_case "a click waits for the matrix" `Quick
            test_overview_hit_waits_for_the_matrix
        ; Alcotest.test_case "a click follows the window" `Quick
            test_overview_hit_follows_the_window
        ] )
    ]
