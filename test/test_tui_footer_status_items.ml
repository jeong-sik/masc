(** Working footers keep decisions and warnings. Explicit diagnostic callers
    may still project connection facts through the same bounded fitter. *)

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

let action_message =
  "skill \"reviewed-skill\": composition name \"new-skill\" must equal the skill name"

let action_state view =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- view;
  state.last_action <- Some (action_message, Unix.gettimeofday ());
  state

let render_action state width =
  Masc_tui_render_prim.footer_line state ~max_cells:width
    ~hints:(Masc_tui_keys.footer_hints state.Masc_tui_types.view)
  |> Masc_tui_theme.strip_sgr

let test_action_text_is_not_dropped_as_a_key () =
  List.iter (fun view ->
    let state = action_state view in
    let row = render_action state 98 in
    check_bool "the action diagnosis survives the 100-column surface footer" true
      (contains ~needle:"skill \"reviewed-skill\": composition name \"new-skill\"" row);
    List.iter (fun key ->
      check_bool ("the diagnosis preserves " ^ key) true
        (contains ~needle:(Masc_tui_theme.strip_sgr key) row))
      (Masc_tui_footer.undroppable_keys
         (Masc_tui_footer.prepare_hints (Masc_tui_keys.footer_hints view)));
    check_bool "a clipped diagnosis is explicit" true (contains ~needle:"…" row);
    check_string "rendering keeps the complete outcome in state" action_message
      (Option.get state.last_action |> fst);
    check_at_most_cells "the action respects the existing cell budget" 98 (String.trim row);
    check_one_line "action footer stays one line" row;
    let narrow = render_action state 60 in
    check_bool "a narrower row retains the start of the actual action" true
      (contains ~needle:"skill " narrow);
    List.iter (fun key ->
      check_bool ("the narrow diagnosis preserves " ^ key) true
        (contains ~needle:(Masc_tui_theme.strip_sgr key) narrow))
      (Masc_tui_footer.undroppable_keys
         (Masc_tui_footer.prepare_hints (Masc_tui_keys.footer_hints view)));
    check_bool "a narrower row marks the cut" true (contains ~needle:"…" narrow);
    check_at_most_cells "narrow action footer remains bounded" 60 (String.trim narrow))
    [ Masc_tui_types.Tools; Masc_tui_types.Repositories ]

let test_build_mismatch_names_the_older_side () =
  let item =
    Masc_tui_footer.build_mismatch_item
      ~tui_commit:(Some "aaaaaaa1111111") ~tui_age_s:(Some 5000.)
      ~server_commit:"bbbbbbb2222222" ~server_age_s:(Some 100.)
  in
  (match item with
   | Some item ->
     check_string "an older TUI is told to restart, ahead of the keys"
       "<dim>  TUI aaaaaaa \xe2\x89\xa0 server bbbbbbb (restart masc)  q:quit  | Port: 8935<reset>\n"
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

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* When even the hints do not fit, the footer says where the rest of them
   are. […] alone reports a cut and stops; a reader cannot tell whether one
   key is hidden or six, and the keys past the cut have no other way of being
   found on that surface.

   [?] opens the sheet, and it puts the reader's own surface first, so what
   was cut is the first thing on the next screen. *)
(* A row may lose what the reader can look up. It does not lose the way out.

   Measured at 160 usable cells against the real key tables: the chat pane
   lost [Esc] -- which is also how a running turn is interrupted -- and
   [/approve /deny], which answers the approval a Keeper is waiting on. Config lost
   the [Esc] that leaves it. Dropping from the back was written for the
   [r] / [Tab] / [q] tail, which every surface shares and the sheet holds;
   it kept going once the row was full enough. *)
(* The help door (task-2361). An operator reading footers in 2026-10 could
   not learn [?] existed: only the composer's rows named it. Every key row
   [?] answers now names it, and a row too full for the item ends in the cut
   marker, which names the same key. *)
let plain_surface_state view =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- view;
  state

let surface_row state view width =
  Masc_tui_render_prim.footer_line state ~max_cells:width
    ~hints:(Masc_tui_keys.footer_hints view)
  |> Masc_tui_theme.strip_sgr

let test_help_item_is_stamped_on_every_surface_row () =
  (* A surface row with room spells the item out; one too full for it ends
     in the cut marker, which names the same key. Either way the door is
     named -- the state an operator could not find it in, before task-2361. *)
  List.iter (fun view ->
    List.iter (fun width ->
      let row = surface_row (plain_surface_state view) view width in
      check_bool "a row of any width names ?" true (contains ~needle:"?" row);
      check_bool "the row names help or marks the cut" true
        (contains ~needle:"?:help" row || contains ~needle:"…" row))
      [ 60; 98; 140; 200 ])
    [ Masc_tui_types.Tools; Masc_tui_types.Repositories; Masc_tui_types.Board
    ; Masc_tui_types.Planning; Masc_tui_types.Clients ];
  (* A row with room carries the item itself rather than only the marker. *)
  let state = plain_surface_state Masc_tui_types.Tools in
  let roomy =
    Masc_tui_render_prim.footer_line state ~max_cells:120
      ~hints:"r:refresh  q:quit"
    |> Masc_tui_theme.strip_sgr
  in
  check_bool "a row with room spells the item out" true
    (contains ~needle:"?:help" roomy)

let test_help_item_yields_to_a_full_row_but_the_door_stays () =
  let state = plain_surface_state Masc_tui_types.Tools in
  List.iter (fun width ->
    let row =
      Masc_tui_render_prim.footer_line state ~max_cells:width
        ~hints:"j/k:move  Enter:open  r:refresh"
      |> Masc_tui_theme.strip_sgr
    in
    check_bool "a row of any width names ?" true (contains ~needle:"?" row);
    if not (contains ~needle:"?:help" row) then
      check_bool "a row that dropped the item marks the cut" true
        (contains ~needle:"…" row))
    [ 30; 45; 60; 80; 120 ]

let test_help_item_waits_when_keys_are_claimed () =
  (* The chat composer owns its footer: its minimal rows already carry the
     item and its typing rows rightly omit it. *)
  let chat =
    plain_surface_state (Masc_tui_types.Keepers Masc_tui_types.Keeper_message)
  in
  let chat_row =
    Masc_tui_render_prim.footer_line chat ~max_cells:140
      ~hints:"Enter:send  PgUp:history"
    |> Masc_tui_theme.strip_sgr
  in
  check_bool "the chat row is not stamped from outside" false
    (contains ~needle:"?:help" chat_row);
  (* A text field holding printable keys takes [?] as a character. *)
  let typing = plain_surface_state Masc_tui_types.Config in
  typing.config_pane <- Masc_tui_types.Config_presets;
  typing.preset_save_draft <- Some "name";
  let typing_row =
    Masc_tui_render_prim.footer_line typing ~max_cells:140
      ~hints:(Masc_tui_keys.footer_hints Masc_tui_types.Config)
    |> Masc_tui_theme.strip_sgr
  in
  check_bool "a row whose keys a field holds is not stamped" false
    (contains ~needle:"?:help" typing_row);
  (* A modal owns its own row. *)
  let modal = plain_surface_state Masc_tui_types.Tools in
  modal.about_open <- true;
  let modal_row = surface_row modal Masc_tui_types.Tools 140 in
  check_bool "a modal row is not stamped" false
    (contains ~needle:"?:help" modal_row)

(* The overlays that answer [?] in their own dispatch arms: the stamp on
   their rows is true, and it has to stay true -- an overlay moved into the
   exclusion lists instead would hide a door that works. *)
let test_overlays_that_answer_keep_the_stamped_door () =
  List.iter
    (fun open_overlay ->
      let state = plain_surface_state Masc_tui_types.Tools in
      open_overlay state;
      (* A row with room spells the item even under the overlay -- these
         three are not in the exclusion lists, unlike the modals that
         swallow the key. *)
      let roomy =
        Masc_tui_render_prim.footer_line state ~max_cells:140
          ~hints:"r:refresh  q:quit"
        |> Masc_tui_theme.strip_sgr
      in
      check_bool "an overlay that answers ? keeps the stamped door" true
        (contains ~needle:"?:help" roomy))
    [ (fun s -> s.Masc_tui_types.answering_open <- true)
    ; (fun s -> s.Masc_tui_types.link_modal_open <- true)
    ; (fun s -> s.Masc_tui_types.keeper_navigation_open <- true) ]

(* The chat's wide and compact rows carry the door exactly while the empty
   draft lets [?] answer; the caller passes the item, so both spellings have
   to ride the row without breaking their separators. *)
let test_chat_rows_carry_the_door_only_while_the_draft_is_empty () =
  let wide = Masc_tui_footer.chat_hints ~enter_hint:"Enter:send" ~scroll_hint:""
      ~switch_hint:"" ~escape_hint:"" ~leave_hint:"" ~help_hint:"  ?:help" in
  check_bool "an empty draft's wide row names the door" true
    (contains ~needle:"?:help" wide);
  check_bool "the item keeps its two-space separation" true
    (contains ~needle:"Ctrl-W:word  ?:help" wide);
  check_bool "a typing wide row names no door" false
    (contains ~needle:"?:help"
       (Masc_tui_footer.chat_hints ~enter_hint:"Enter:send" ~scroll_hint:""
          ~switch_hint:"" ~escape_hint:"" ~leave_hint:"" ~help_hint:""));
  let compact =
    Masc_tui_footer.compact_chat_hints ~enter_hint:"Enter:send"
      ~scroll_hint:"PgUp:history" ~escape_hint:"Esc:quiet" ~help_hint:"  ?:help"
  in
  check_bool "an empty draft's compact row names the door" true
    (contains ~needle:"?:help" compact);
  check_bool "a typing compact row names no door" false
    (contains ~needle:"?:help"
       (Masc_tui_footer.compact_chat_hints ~enter_hint:"Enter:send"
          ~scroll_hint:"PgUp:history" ~escape_hint:"Esc:quiet" ~help_hint:""))

let test_ensure_help_item_appends_once () =
  check_string "a row with no help item gains one at the end"
    "j/k:move  q:quit  ?:help"
    (Masc_tui_footer.ensure_help_item "j/k:move  q:quit");
  check_string "a row that already names help keeps its own spelling"
    "?:help  q:quit"
    (Masc_tui_footer.ensure_help_item "?:help  q:quit")

let test_armed_ask_submit_notice_retires_when_answering_is_cleared () =
  let state = plain_surface_state Masc_tui_types.Approvals in
  let notice = Masc_tui_types.armed_ask_submit_notice "alpha" in
  state.ask_answer_mode <- Masc_tui_types.Ask_answering { aam_ask_id = "ask-1" };
  state.pending_ask_submit <- Some "ask-1";
  state.last_action <- Some (notice, Unix.gettimeofday ());
  check_bool "armed confirmation notice renders while ask submit is armed" true
    (contains ~needle:notice (render_action state 140));
  Masc_tui_home.clear_ask_answering state;
  check_bool "clearing ask answering retires the armed notice from state" true
    (Option.is_none state.last_action);
  check_bool "withdrawn ask answering no longer draws confirmation hint" false
    (contains ~needle:notice (render_action state 140));
  (* Even if a caller leaves the notice tuple in last_action while ask submit
     is disarmed, footer_line must not draw the obsolete confirmation hint. *)
  state.last_action <- Some (notice, Unix.gettimeofday ());
  check_bool "disarmed state suppresses stale ask confirmation notice" false
    (contains ~needle:notice (render_action state 140));
  let unrelated = "Cannot answer: workspace identity is unverified; draft retained" in
  state.last_action <- Some (unrelated, Unix.gettimeofday ());
  Masc_tui_home.clear_ask_answering state;
  check_bool "clearing ask answering preserves unrelated action notices" true
    (contains ~needle:unrelated (render_action state 140))

(* The frames that draw no agenda row -- the chat, the Board composer, the
   narrow Keeper navigation -- carry the count of open questions in their
   footer, in front of the keys, since the tail goes before a single key. *)
let test_open_questions_lead_the_footer_row () =
  let item = Masc_tui_footer.Questions_waiting 2 in
  check_bool "a question waits on the operator" true
    (Masc_tui_footer.needs_operator item);
  (match Masc_tui_footer.status_item_projection item with
   | None -> Alcotest.fail "two open questions projected nothing"
   | Some projected ->
     check_bool "it leads the row" true (Masc_tui_footer.leads_the_row projected);
     Alcotest.(check int) "and survives the conflict ordering" 1
       (List.length (Masc_tui_footer.ordered_conflicts [ projected ])));
  check_bool "no open question says nothing" true
    (Option.is_none
       (Masc_tui_footer.status_item_projection (Masc_tui_footer.Questions_waiting 0)))

(* The wrong-workspace read decides whether anything on screen can be
   answered, so it outranks the question; the question outranks the build
   provenance, which describes the binary rather than work waiting. *)
let test_open_questions_rank_between_workspace_and_build () =
  let projected =
    List.filter_map Masc_tui_footer.status_item_projection
      [ Masc_tui_footer.Tui_build_mismatch
          { tui = "aaaaaaa"; server = "bbbbbbb"; older = `Tui }
      ; Masc_tui_footer.Questions_waiting 1
      ; Masc_tui_footer.Workspace_mismatch "/elsewhere"
      ]
  in
  check_bool "workspace, then the question, then the build" true
    (List.map
       (fun (item : Masc_tui_footer.projected_status) -> item.retention)
       (Masc_tui_footer.ordered_conflicts projected)
     = [ Masc_tui_footer.Workspace_conflict
       ; Masc_tui_footer.Operator_question
       ; Masc_tui_footer.Build_conflict
       ])

let ask_row ?(questions = 1) ?(resolution = Masc.Tui_decode_asks.Ask_open) ask_id
    : Masc.Tui_decode_asks.ask_row =
  { ar_keeper = "edgar.a.poe"
  ; ar_id = ask_id
  ; ar_asked_at = 0.
  ; ar_source_turn_ref = None
  ; ar_context = None
  ; ar_questions =
      List.init questions (fun index ->
        { Masc.Tui_decode_asks.aq_id = Printf.sprintf "q%d" (index + 1)
        ; aq_header = "Release"
        ; aq_prompt = "Ship tonight?"
        ; aq_mode = Masc.Tui_decode_asks.Ask_single
        ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
        ; aq_choices = []
        })
  ; ar_resolution = resolution
  }

(* What those frames select: one count per open ask, from the same agenda the
   strip counts, and nothing at all while no ask is open. *)
let test_frames_without_the_agenda_select_the_question_count () =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let set rows =
    state.asks_snapshot <-
      Some { asn_keeper = None; asn_open_count = List.length rows; asn_rows = rows }
  in
  check_bool "nothing read, nothing said" true
    (Masc_tui_render_prim.questions_waiting_status state = []);
  set
    [ ask_row ~questions:2 "ask-1"
    ; ask_row "ask-2"
    ; ask_row
        ~resolution:
          (Masc.Tui_decode_asks.Ask_answered { aa_answered_at = 1.; aa_question_ids = [ "q1" ] })
        "ask-3"
    ];
  check_bool "two open asks are two, however many questions they hold" true
    (Masc_tui_render_prim.questions_waiting_status state
     = [ Masc_tui_footer.Questions_waiting 2 ]);
  set [];
  check_bool "an empty list says nothing" true
    (Masc_tui_render_prim.questions_waiting_status state = [])

let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "action text is not dropped as a key" `Quick
          test_action_text_is_not_dropped_as_a_key
      ; Alcotest.test_case "build mismatch names the older side" `Quick
          test_build_mismatch_names_the_older_side
      ; Alcotest.test_case "build mismatch is silent without testimony" `Quick
          test_build_mismatch_is_silent_without_testimony
      ; Alcotest.test_case "help item is stamped on every surface row" `Quick
          test_help_item_is_stamped_on_every_surface_row
      ; Alcotest.test_case "help item yields to a full row but the door stays" `Quick
          test_help_item_yields_to_a_full_row_but_the_door_stays
      ; Alcotest.test_case "help item waits when keys are claimed" `Quick
          test_help_item_waits_when_keys_are_claimed
      ; Alcotest.test_case "overlays that answer keep the stamped door" `Quick
          test_overlays_that_answer_keep_the_stamped_door
      ; Alcotest.test_case "chat rows carry the door only while the draft is empty" `Quick
          test_chat_rows_carry_the_door_only_while_the_draft_is_empty
      ; Alcotest.test_case "ensure_help_item appends once" `Quick
          test_ensure_help_item_appends_once
      ; Alcotest.test_case "armed ask submit notice retires when answering is cleared" `Quick
          test_armed_ask_submit_notice_retires_when_answering_is_cleared
      ; Alcotest.test_case "open questions lead the footer row" `Quick
          test_open_questions_lead_the_footer_row
      ; Alcotest.test_case "open questions rank between workspace and build" `Quick
          test_open_questions_rank_between_workspace_and_build
      ; Alcotest.test_case "frames without the agenda select the question count" `Quick
          test_frames_without_the_agenda_select_the_question_count
      ;] )
  ; ( "voice meter"
    , [] )
  ]

let () = Alcotest.run "tui_footer_status_items" tests
