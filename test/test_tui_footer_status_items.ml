(** Every surface footer ends with the same status facts.

    Before Masc_tui_footer each of the 21 footers spelled [Port: %d] into its
    own format string, so a screen could carry a different spelling, a
    different separator, or no port at all and nothing would say so. These
    tests pin the shared tail. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let contains ~needle text =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let check_at_most_cells label max_cells text =
  Alcotest.(check bool) label true
    (Masc_tui_message_layout.display_width text <= max_cells)

let check_one_line label text =
  let newlines =
    String.fold_left
      (fun count char -> if Char.equal char '\n' then count + 1 else count)
      0 text
  in
  Alcotest.(check int) label 1 newlines

let test_port_closes_every_footer () =
  check_string "port closes a plain footer"
    "<dim>  j/k:move  Tab:next  | Port: 8935<reset>\n"
    (Masc_tui_footer.line ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120
       ~port:8935 ~hints:"j/k:move  Tab:next" ())

let test_extra_facts_precede_port () =
  check_string "a surface's own fact reads before the port"
    "<dim>  q:quit  | Refresh: 5s | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Refresh_interval 5.0 ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_hints_do_not_change_the_tail () =
  (* Two surfaces with nothing in common still end identically. *)
  let tail line =
    let marker = "  | " in
    let index = Str.search_forward (Str.regexp_string marker) line 0 in
    String.sub line index (String.length line - index)
  in
  let overview =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:120 ~port:8935
      ~hints:"j/k:events  t:tasks  q:quit" ()
  in
  let help =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:120 ~port:8935
      ~hints:"j/k:scroll  Esc:close" ()
  in
  check_string "same tail" (tail overview) (tail help)

(* The tail said [Port: 8935] and nothing else, so two checkouts serving that
   port read identically from the screen -- and a binary older than the tree
   it was built from looked exactly like a current one. *)
let test_build_reads_before_the_port () =
  check_string "version and commit precede the port"
    "<dim>  q:quit  | v0.24.0 030fa90 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build
             { version = "0.24.0"; commit = "030fa9043aafc5c2003f830c86720afff8e8e2ff" }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_a_short_commit_is_not_padded () =
  check_string "a commit shorter than the prefix reads whole"
    "<dim>  q:quit  | v0.24.0 abc | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build { version = "0.24.0"; commit = "abc" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_a_half_read_build_still_says_what_it_knows () =
  check_string "a version with no commit still reads"
    "<dim>  q:quit  | v0.24.0 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_build { version = "0.24.0"; commit = "" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "neither half read is omitted rather than invented"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_build { version = ""; commit = "" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_base_path_reads_between_build_and_port () =
  check_string "base path follows the build and precedes the endpoint"
    "<dim>  q:quit  | v0.24.0 030fa90 | Base: /Users/dancer/me | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build
             { version = "0.24.0"; commit = "030fa9043aafc" }
         ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "path characters are not trimmed into another authority"
    "<dim>  q:quit  | Base:  /work/masc | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_base_path " /work/masc" ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:80 ~port:8935
       ~hints:"q:quit" ())

let test_width_omits_whole_status_items () =
  let status =
    [ Masc_tui_footer.Refresh_interval 5.0
    ; Masc_tui_footer.Server_build
        { version = "0.24.0"; commit = "030fa9043aafc5c2003f830c86720afff8e8e2ff" }
    ; Masc_tui_footer.Server_base_path "/work/masc"
    ]
  in
  let hints = "j/k:move  Enter:detail  r:refresh  Tab:next" in
  let render max_cells =
    Masc_tui_footer.line ~status ~dim:"\x1b[2m" ~reset:"\x1b[0m"
      ~max_cells ~port:8935 ~hints ()
  in
  let wide = render 120 in
  check_at_most_cells "120 cells" 120 wide;
  check_bool "wide keeps refresh" true (contains ~needle:"Refresh: 5s" wide);
  check_bool "wide keeps build" true (contains ~needle:"v0.24.0 030fa90" wide);
  check_bool "wide keeps base path" true
    (contains ~needle:"Base: /work/masc" wide);
  check_bool "wide keeps port" true (contains ~needle:"Port: 8935" wide);
  let medium = render 80 in
  check_at_most_cells "80 cells" 80 medium;
  check_bool "medium omits the whole refresh item" false
    (contains ~needle:"Refresh:" medium);
  check_bool "medium omits build before workspace" false
    (contains ~needle:"v0.24.0 030fa90" medium);
  check_bool "medium keeps the whole base-path item" true
    (contains ~needle:"Base: /work/masc" medium);
  check_bool "medium keeps the whole port item" true
    (contains ~needle:"Port: 8935" medium);
  let compact = render 60 in
  check_at_most_cells "60 cells" 60 compact;
  check_bool "compact omits refresh" false
    (contains ~needle:"Refresh:" compact);
  check_bool "compact omits build before endpoint" false
    (contains ~needle:"v0.24.0" compact);
  check_bool "compact omits workspace before endpoint" false
    (contains ~needle:"Base:" compact);
  check_bool "compact retains endpoint last" true
    (contains ~needle:"Port: 8935" compact);
  let narrow = render 40 in
  check_at_most_cells "40 cells" 40 narrow;
  check_bool "narrow never leaves a partial status item" false
    (contains ~needle:"Refresh:" narrow || contains ~needle:"v0.24" narrow
     || contains ~needle:"Base:" narrow || contains ~needle:"Port:" narrow)

let test_chat_hint_widths_keep_one_row_and_whole_items () =
  let status =
    [ Masc_tui_footer.Server_build
        { version = "0.24.0"; commit = "030fa9043aafc" }
    ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
    ]
  in
  (* Built through the same function the chat pane uses, so the widths
     checked here are the widths drawn there. The hand-copied strings this
     replaces drifted twice: Ctrl-F/Ctrl-O never reached them, then Ctrl-N
     (#32367) did not either, and the guarantee was proven ~40 cells short. *)
  let idle_hints =
    Masc_tui_footer.chat_hints ~enter_hint:"Enter:send"
      ~scroll_hint:
        (Masc_tui_message_layout.scroll_hint ~scrolled_back:0
           ~older_exist:true)
      ~switch_hint:"" ~escape_hint:"Esc:list"
      (* The quiet leave shares the row only while the draft is empty, so that
         is the shape whose width has to fit. *)
      ~leave_hint:"  Q:leave"
  in
  let render hints max_cells =
    Masc_tui_footer.line ~status ~dim:"\x1b[2m" ~reset:"\x1b[0m"
      ~max_cells ~port:8935 ~hints ()
  in
  List.iter
    (fun width ->
      let line = render idle_hints width in
      check_at_most_cells (Printf.sprintf "idle footer fits %d cells" width)
        width line;
      check_one_line (Printf.sprintf "idle footer stays one row at %d" width)
        line)
    [ 240; 200; 160; 120; 80 ];
  (* Ctrl-W:word grew the idle hints past what 200 cells can show next to a
     base path: hints come before facts (#30465), so at 200 columns and
     narrower the Base item now yields (201-218 keeps Base and drops the
     build instead). The budget check renders where the path still fits. *)
  let wide = render idle_hints 220 in
  check_bool "ordinary wide chat keeps its base path" true
    (contains ~needle:"Base: /Users/dancer/me" wide);
  check_bool "ordinary wide chat keeps one endpoint" true
    (contains ~needle:"Port: 8935" wide);
  let narrow = render idle_hints 120 in
  check_bool "narrow chat never shows a partial base-path item" false
    (contains ~needle:"Base:" narrow || contains ~needle:"/Users/dancer" narrow);
  (* This is the real active-chat shape: queue controls, transcript paging,
     Keeper switching, and interrupt status can all be present together. Its
     hints exceed 200 cells; #30465 deliberately keeps hints before facts.
     Every hole carries its widest live value, through the same producers the
     pane reads. *)
  let active_hints =
    Masc_tui_footer.chat_hints
      ~enter_hint:
        "Enter:queue (12 waiting)  Ctrl-K:cancel last  Ctrl-P:edit last"
      ~scroll_hint:
        (Masc_tui_message_layout.scroll_hint ~scrolled_back:999
           ~older_exist:true)
      ~switch_hint:"  Ctrl-G:next Keeper" ~escape_hint:"Esc:interrupt turn"
      ~leave_hint:"  Q:leave"
  in
  let active = render active_hints 240 in
  check_at_most_cells "worst-case active footer fits 240 cells" 240 active;
  check_one_line "worst-case active footer stays one row" active;
  check_bool "worst-case active footer omits the whole path" false
    (contains ~needle:"Base:" active || contains ~needle:"/Users/dancer" active)

let test_korean_base_path_is_measured_by_cells () =
  let render max_cells =
    Masc_tui_footer.line
      ~status:[ Masc_tui_footer.Server_base_path "/작업/마스" ]
      ~dim:"" ~reset:"" ~max_cells ~port:8935 ~hints:"q" ()
  in
  let exact = render 36 in
  check_at_most_cells "Korean path fits its exact cell width" 36 exact;
  check_bool "cell measurement retains the whole Korean path" true
    (contains ~needle:"Base: /작업/마스" exact);
  let compact = render 35 in
  check_at_most_cells "compact Korean footer stays in bounds" 35 compact;
  check_bool "one fewer cell omits the whole Korean path" false
    (contains ~needle:"Base:" compact || contains ~needle:"/작업" compact);
  check_bool "endpoint survives Korean path omission" true
    (contains ~needle:"Port: 8935" compact)

let test_unavailable_status_is_omitted () =
  check_string "zero and unread facts are absent"
    "<dim>  q:quit<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Refresh_interval 0.
         ; Masc_tui_footer.Server_build { version = ""; commit = "" }
         ; Masc_tui_footer.Server_base_path ""
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:80 ~port:0 ~hints:"q:quit"
       ())

let test_ansi_korean_hint_truncates_by_cells () =
  (* Ten cells fit the first item whole (with the ellipsis marking the cut);
     the second drops entirely — measured in cells through the SGR bytes. *)
  let line =
    Masc_tui_footer.line ~dim:"\x1b[2m" ~reset:"\x1b[0m" ~max_cells:10
      ~port:8935 ~hints:"\x1b[1m확인\x1b[0m  Tab:다음" ()
  in
  check_at_most_cells "ANSI and Korean stay within ten cells" 10 line;
  check_bool "the first item survives whole" true (contains ~needle:"확인" line);
  check_bool "the dropped tail is marked" true
    (contains ~needle:"\xe2\x80\xa6" line);
  (* When not even one item fits, the last resort is still the explicit
     cell-safe cut — never an overflowing row. *)
  let hopeless =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:4 ~port:8935
      ~hints:"가나다라마바" ()
  in
  check_at_most_cells "four cells hold" 4 hopeless;
  check_bool "and the cut is explicit" true (contains ~needle:"~" hopeless)

(* A workspace disagreement used to replace the whole screen and swallow every
   key but r. The reads it protects are refused where they happen, so the
   notice rides the footer instead -- and it is the last fact a narrow footer
   gives up, after the port. *)
let test_a_workspace_mismatch_outlives_the_port () =
  check_string "the local path reads beside the server's own"
    "<dim>  q:quit  | Base: /me | MISMATCH local /work/masc (r:retry) | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_base_path "/me"
         ; Masc_tui_footer.Workspace_mismatch "/work/masc"
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  let narrow =
    Masc_tui_footer.line
      ~status:
        [ Masc_tui_footer.Refresh_interval 5.0
        ; Masc_tui_footer.Server_build { version = "0.24.0"; commit = "030fa90" }
        ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
        ; Masc_tui_footer.Workspace_mismatch "/work/masc"
        ]
      ~dim:"<dim>" ~reset:"<reset>" ~max_cells:48 ~port:8935 ~hints:"q:quit" ()
  in
  check_bool "the notice outlives the port" true
    (contains ~needle:"MISMATCH local /work/masc" narrow);
  check_bool "the port went first" false (contains ~needle:"Port:" narrow);
  check_string "a workspace that agrees says nothing"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Workspace_mismatch "" ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_answering_names_the_first_keeper () =
  check_string "one keeper answering reads by name"
    "<dim>  q:quit  | \xe2\x97\x8c answering echo | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Keeper_answering { names = [ "echo" ]; lead_elapsed_s = None } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "more keepers ride as a count behind the first"
    "<dim>  q:quit  | \xe2\x97\x8c answering echo +2 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answering
             { names = [ "echo"; "analyst"; "delta" ]; lead_elapsed_s = None } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "nobody answering says nothing"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Keeper_answering { names = []; lead_elapsed_s = Some 3 } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_narrow_width_drops_whole_hint_items () =
  (* The board-list footer at 60 cells: statuses all dropped, the hint list
     still too wide. Items must drop from the back with an ellipsis — no
     half-word cell cut. *)
  let hints =
    "j/k:move  right/Enter:read  s:sort  Y:copy link  v/V:vote  w:write  \
     r:refresh  Tab:next"
  in
  let narrow =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:60 ~port:8935 ~hints ()
  in
  check_at_most_cells "60 cells" 60 narrow;
  check_bool "leading items survive whole" true
    (contains ~needle:"j/k:move" narrow
     && contains ~needle:"right/Enter:read" narrow);
  check_bool "the cut is marked, not implied" true
    (contains ~needle:"\xe2\x80\xa6" narrow);
  check_bool "no half item survives the cut" false
    (contains ~needle:"Tab:nex" narrow && not (contains ~needle:"Tab:next" narrow))

let test_answering_carries_the_lead_elapsed_time () =
  check_string "the lead keeper's runtime rides the badge"
    "<dim>  q:quit  | \xe2\x97\x8c answering echo 14m +1 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answering
             { names = [ "echo"; "analyst" ]; lead_elapsed_s = Some 850 }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_answered_glow_reads_by_name () =
  check_string "one finish reads by name with its age"
    "<dim>  q:quit  | \xe2\x9c\x93 echo answered 12s ago | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answered
             { name = "echo"; seconds_ago = 12; more = 0 }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "older finishes fold behind the newest"
    "<dim>  q:quit  | \xe2\x9c\x93 echo answered 3m ago +2 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answered
             { name = "echo"; seconds_ago = 200; more = 2 }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_worktree_server_warning_survives_narrow_widths () =
  check_string "the worktree warning reads in full"
    "<dim>  q:quit  | WORKTREE server (not the root build) | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_worktree_binary ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  (* Same retention as the workspace mismatch: at a width that drops the
     port, the warning is still on the row. *)
  let narrow =
    Masc_tui_footer.line
      ~status:
        [ Masc_tui_footer.Server_build
            { version = "9.9.9"; commit = "abcdef0123456" }
        ; Masc_tui_footer.Server_worktree_binary
        ]
      ~dim:"" ~reset:"" ~max_cells:52 ~port:8935 ~hints:"q:quit" ()
  in
  check_at_most_cells "narrow footer fits" 52 narrow;
  check_bool "the build fact went first" false (contains ~needle:"9.9.9" narrow);
  check_bool "the warning stayed" true (contains ~needle:"WORKTREE" narrow)

let test_build_mismatch_names_the_older_side () =
  let item =
    Masc_tui_footer.build_mismatch_item
      ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:(Some 5000.)
      ~server_commit:"bbbbbbb2222222" ~server_age_s:(Some 100.)
  in
  (match item with
   | Some item ->
     check_string "an older TUI is told to restart"
       "<dim>  q:quit  | TUI aaaaaaa \xe2\x89\xa0 server bbbbbbb (restart masc) | Port: 8935<reset>\n"
       (Masc_tui_footer.line ~status:[ item ] ~dim:"<dim>" ~reset:"<reset>"
          ~max_cells:120 ~port:8935 ~hints:"q:quit" ())
   | None -> Alcotest.fail "a differing pair produced no item");
  (match
     Masc_tui_footer.build_mismatch_item
       ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:(Some 100.)
       ~server_commit:"bbbbbbb2222222" ~server_age_s:(Some 5000.)
   with
   | Some item ->
     check_bool "an older server is told to redeploy" true
       (contains ~needle:"server is older"
          (Masc_tui_footer.line ~status:[ item ] ~dim:"" ~reset:""
             ~max_cells:120 ~port:8935 ~hints:"q" ()))
   | None -> Alcotest.fail "a differing pair produced no item");
  match
    Masc_tui_footer.build_mismatch_item
      ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:None
      ~server_commit:"bbbbbbb2222222" ~server_age_s:(Some 5000.)
  with
  | Some item ->
    check_bool "one unknown age blames neither lane" true
      (contains ~needle:"generations differ"
         (Masc_tui_footer.line ~status:[ item ] ~dim:"" ~reset:""
            ~max_cells:120 ~port:8935 ~hints:"q" ()))
  | None -> Alcotest.fail "a differing pair produced no item"

let test_build_mismatch_is_silent_without_testimony () =
  check_bool "matching commits say nothing" true
    (Masc_tui_footer.build_mismatch_item
       ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:(Some 1.)
       ~server_commit:"aaaaaaa1111111" ~server_age_s:(Some 2.)
     = None);
  check_bool "a TUI with no embedded commit says nothing" true
    (Masc_tui_footer.build_mismatch_item ~tui_commit:None ~tui_age_s:None
       ~server_commit:"bbbbbbb2222222" ~server_age_s:None
     = None);
  check_bool "a server that sent no commit says nothing" true
    (Masc_tui_footer.build_mismatch_item
       ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:None ~server_commit:""
       ~server_age_s:None
     = None)

let test_answering_outlives_the_build_fact () =
  (* At a width with no room for everything, the live-activity fact stays on
     the row after refresh and build have been dropped. *)
  let narrow =
    Masc_tui_footer.line
      ~status:
        [ Masc_tui_footer.Refresh_interval 2.0
        ; Masc_tui_footer.Server_build
            { version = "9.9.9"; commit = "abcdef0123456" }
        ; Masc_tui_footer.Keeper_answering { names = [ "echo" ]; lead_elapsed_s = None }
        ]
      ~dim:"" ~reset:"" ~max_cells:46 ~port:8935 ~hints:"q:quit" ()
  in
  check_at_most_cells "narrow footer fits" 46 narrow;
  check_bool "the build fact went first" false (contains ~needle:"9.9.9" narrow);
  check_bool "answering stayed" true (contains ~needle:"answering" narrow)

(* A substring test without a new library dependency for one check. *)
let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* When even the hints do not fit, the footer says where the rest of them
   are. [~] alone reports a cut and stops; a reader cannot tell whether one
   key is hidden or six, and the keys past the cut have no other way of being
   found on that surface.

   [?] opens the sheet, and it puts the reader's own surface first, so what
   was cut is the first thing on the next screen. *)
(* A row may lose what the reader can look up. It does not lose the way out.

   Measured at 160 usable cells against the real key tables: the chat pane
   lost [Esc] -- which is also how a running turn is interrupted -- and
   [y / n], which answers the approval a Keeper is waiting on. Config lost
   the [Esc] that leaves it. Dropping from the back was written for the
   [r] / [Tab] / [q] tail, which every surface shares and the sheet holds;
   it kept going once the row was full enough. *)
let test_the_cut_keeps_the_way_out () =
  let hints =
    "j/k:roster move  Enter:send / open  Ctrl-J:newline  Ctrl-G:next keeper  \
     Ctrl-U:clear  Ctrl-R:reasoning  Ctrl-D:tool detail  Ctrl-N:memory detail  \
     y / n:approval  Esc:back"
  in
  let line =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:70 ~port:8935 ~hints ()
  in
  Alcotest.(check bool) "the row was cut" true
    (contains ~needle:"\xe2\x80\xa6" line);
  Alcotest.(check bool) "the way out survives it" true
    (contains ~needle:"Esc:back" line);
  Alcotest.(check bool) "so does the answer to a pending ask" true
    (contains ~needle:"y / n:approval" line);
  Alcotest.(check bool) "and something did give way" false
    (contains ~needle:"Ctrl-R:reasoning" line)

let test_a_compound_leave_key_is_the_same_door () =
  (* Surfaces spell it [Left / Esc] or [Right / Esc] where an arrow does the
     same thing. It is one key under two spellings, not two keys. *)
  let hints =
    "j/k:move  Right / Enter:open  d:tree diff  v:view code  o:editor  \
     [ / ]:keeper  Left / Esc:back  r:refresh  Tab:next  q:quit"
  in
  let line =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:60 ~port:8935 ~hints ()
  in
  Alcotest.(check bool) "the row was cut" true
    (contains ~needle:"\xe2\x80\xa6" line);
  Alcotest.(check bool) "the compound leave survives" true
    (contains ~needle:"Left / Esc:back" line);
  Alcotest.(check bool) "and quit does too" true
    (contains ~needle:"q:quit" line)

let test_a_label_holding_a_colon_still_reads_its_key () =
  (* [Enter:edit / use] is a label with a separator in it. Only the first
     colon ends the key, or an item like this would read as an unpinned one
     whose key is the whole string. *)
  let hints =
    "j/k:select / scroll  p:runtime.toml / models / params  s:resources  \
     t:tools  e:edit  E:advanced JSON  Enter:edit / use  x:default / clear  \
     Esc:overview  r:reload  Tab:next"
  in
  let line =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:70 ~port:8935 ~hints ()
  in
  Alcotest.(check bool) "the row was cut" true
    (contains ~needle:"\xe2\x80\xa6" line);
  Alcotest.(check bool) "the way out survives" true
    (contains ~needle:"Esc:overview" line)

let test_cut_hints_name_the_key_that_shows_them () =
  let hints =
    "j/k:move  right/Enter:read  s:sort  Y:copy link  v/V:vote  w:write  \
     r:refresh  Tab:next  q:quit"
  in
  let line =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:40 ~port:8935 ~hints ()
  in
  let body = String.trim line in
  Alcotest.(check bool)
    "the cut is still marked" true
    (contains ~needle:"\xe2\x80\xa6" body);
  Alcotest.(check bool)
    "and it names the key that shows the rest" true
    (String.length body > 0 && body.[String.length body - 1] = '?');
  check_at_most_cells "the pointer stays inside the width" 40 body
;;

(* A footer wide enough for its hints gains nothing and must not pay for it:
   the pointer exists to answer a question a full line does not raise. *)
let test_hints_that_fit_are_left_alone () =
  let hints = "j/k:move  q:quit" in
  let line =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:120 ~port:8935 ~hints ()
  in
  Alcotest.(check bool)
    "no cut mark" false
    (contains ~needle:"\xe2\x80\xa6" line);
  Alcotest.(check bool)
    "and no pointer" false
    (String.contains line '?')
;;


(* The capture bar. It stands in for the hint line while a capture runs, so it
   answers to the same one-row budget — and it is the only meter that reaches
   the chat surface, which draws its own input row rather than the composer's. *)
let test_the_voice_bar_is_the_width_it_claims () =
  List.iter
    (fun db ->
       Alcotest.(check int)
         "bar occupies the cells it was given"
         Masc_tui_footer.voice_bar_width
         (Masc_tui_message_layout.display_width
            (Masc_tui_footer.voice_bar
               ~width:Masc_tui_footer.voice_bar_width
               ~db)))
    [ None; Some Float.neg_infinity; Some (-60.); Some (-37.); Some (-6.); Some 0. ]
;;

(* Silence and "nothing reported yet" draw the same empty bar, and both are
   honest: the operator has not been heard in either case. *)
let test_silence_draws_an_empty_bar () =
  Alcotest.(check string)
    "no reading yet is the same as silence"
    (Masc_tui_footer.voice_bar ~width:8 ~db:None)
    (Masc_tui_footer.voice_bar ~width:8 ~db:(Some Float.neg_infinity))
;;

(* A room reads about -37 dB on this hardware and a voice about -20. Drawing
   those the same would answer nothing an operator asked the meter. *)
let test_a_room_and_a_voice_do_not_draw_the_same_bar () =
  Alcotest.(check bool)
    "they differ"
    true
    (not
       (String.equal
          (Masc_tui_footer.voice_bar ~width:16 ~db:(Some (-37.)))
          (Masc_tui_footer.voice_bar ~width:16 ~db:(Some (-20.)))))
;;

let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "port closes every footer" `Quick
          test_port_closes_every_footer
      ; Alcotest.test_case "extra facts precede port" `Quick
          test_extra_facts_precede_port
      ; Alcotest.test_case "build reads before the port" `Quick
          test_build_reads_before_the_port
      ; Alcotest.test_case "a short commit is not padded" `Quick
          test_a_short_commit_is_not_padded
      ; Alcotest.test_case "a half-read build still says what it knows" `Quick
          test_a_half_read_build_still_says_what_it_knows
      ; Alcotest.test_case "base path reads between build and port" `Quick
          test_base_path_reads_between_build_and_port
      ; Alcotest.test_case "hints do not change the tail" `Quick
          test_hints_do_not_change_the_tail
      ; Alcotest.test_case "40/80/120 omit whole status items" `Quick
          test_width_omits_whole_status_items
      ; Alcotest.test_case "chat widths keep one row and whole items" `Quick
          test_chat_hint_widths_keep_one_row_and_whole_items
      ; Alcotest.test_case "Korean base path is measured by cells" `Quick
          test_korean_base_path_is_measured_by_cells
      ; Alcotest.test_case "unavailable status is omitted" `Quick
          test_unavailable_status_is_omitted
      ; Alcotest.test_case "ANSI Korean hint truncates by cells" `Quick
          test_ansi_korean_hint_truncates_by_cells
      ; Alcotest.test_case "a workspace mismatch outlives the port" `Quick
          test_a_workspace_mismatch_outlives_the_port
      ; Alcotest.test_case "answering names the first keeper" `Quick
          test_answering_names_the_first_keeper
      ; Alcotest.test_case "answered glow reads by name" `Quick
          test_answered_glow_reads_by_name
      ; Alcotest.test_case "answering carries the lead elapsed time" `Quick
          test_answering_carries_the_lead_elapsed_time
      ; Alcotest.test_case "narrow width drops whole hint items" `Quick
          test_narrow_width_drops_whole_hint_items
      ; Alcotest.test_case "worktree server warning survives narrow widths"
          `Quick test_worktree_server_warning_survives_narrow_widths
      ; Alcotest.test_case "build mismatch names the older side" `Quick
          test_build_mismatch_names_the_older_side
      ; Alcotest.test_case "build mismatch is silent without testimony" `Quick
          test_build_mismatch_is_silent_without_testimony
      ; Alcotest.test_case "answering outlives the build fact" `Quick
          test_answering_outlives_the_build_fact
      ; Alcotest.test_case "cut hints name the key that shows them" `Quick
          test_cut_hints_name_the_key_that_shows_them
      ; Alcotest.test_case "the cut keeps the way out" `Quick
          test_the_cut_keeps_the_way_out
      ; Alcotest.test_case "a compound leave key is the same door" `Quick
          test_a_compound_leave_key_is_the_same_door
      ; Alcotest.test_case "a label holding a colon still reads its key" `Quick
          test_a_label_holding_a_colon_still_reads_its_key
      ; Alcotest.test_case "hints that fit are left alone" `Quick
          test_hints_that_fit_are_left_alone
      ] )
  ; ( "voice meter"
    , [ Alcotest.test_case "the bar is the width it claims" `Quick
          test_the_voice_bar_is_the_width_it_claims
      ; Alcotest.test_case "silence draws an empty bar" `Quick
          test_silence_draws_an_empty_bar
      ; Alcotest.test_case "a room and a voice differ" `Quick
          test_a_room_and_a_voice_do_not_draw_the_same_bar
      ] )
  ]



let () = Alcotest.run "tui_footer_status_items" tests
