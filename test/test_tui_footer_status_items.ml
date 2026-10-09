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

let test_working_footer_keeps_attention_without_background_activity () =
  let module Footer = Masc_tui_footer in
  let state = Masc_tui_types.create_state ~workspace:"" ~port:8935 ~refresh_interval:2. () in
  state.keeper_turns <-
    [{ Masc.Tui_decode.ktr_chat_control_token = None;
       ktr_keeper_name = "background-keeper";
       ktr_state = Keeper_turn_running
         {lane = Turn_lane_autonomous; started_at_unix = 1.;
          interrupt_token = "fixture"; turn_ref = None; preview = None} }];
  state.keeper_turn_finishes <- ["finished-keeper", Unix.gettimeofday ()];
  let passive = [Footer.Refresh_interval 2.;
    Footer.Server_build {version="0.49.0";commit="abcdef123"};
    Footer.Server_base_path "/fixture/workspace";
    Footer.Keeper_answering {names=["background-keeper"];lead_elapsed_s=Some 12};
    Footer.Keeper_answered {name="finished-keeper";seconds_ago=1;more=0};
    Footer.Port 8935] in
  List.iter (fun view ->
    state.view <- view;
    let draw status = Masc_tui_render_prim.footer_line state ~max_cells:200
      ~status ~hints:"Enter:open  q:quit  ?:help" |> Masc_tui_theme.strip_sgr in
    let quiet = draw passive in
    List.iter (fun text -> check_bool ("not in a working footer: " ^ text) false
      (contains ~needle:text quiet))
      ["background-keeper"; "finished-keeper"; "Refresh:"; "Port:";
       "abcdef"; "/fixture/workspace"];
    List.iter (fun warning ->
      let row = draw (warning :: passive) in
      let expected = Option.get (Footer.status_item_projection warning) in
      check_bool "actionable status remains on the same surface" true
        (contains ~needle:expected.text row))
      [Footer.Workspace_mismatch "/other-workspace";
       Footer.Server_worktree_binary;
       Footer.Keeper_action_armed {key="d";action="delete";keeper="alpha"};
       Footer.Keeper_action_running {gerund="Stopping";keeper="alpha"}])
    [Masc_tui_types.Overview; Keepers Keeper_message; Board;
     Repositories; Config]

let test_inflight_action_survives_navigation () =
  let state = Masc_tui_types.create_state ~workspace:"" ~port:8935 ~refresh_interval:2. () in
  state.keeper_action_inflight <- Some ("alpha", Masc_tui_keeper_control.Shutdown);
  state.last_action <- None;
  List.iter (fun view ->
    state.view <- view;
    check_bool "inflight action is shared across surfaces" true
      (contains ~needle:"alpha" (render_action state 200)))
    [Masc_tui_types.Overview; Board; Repositories; Config]

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
let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "working footer keeps only attention" `Quick
          test_working_footer_keeps_attention_without_background_activity
      ; Alcotest.test_case "action text is not dropped as a key" `Quick
          test_action_text_is_not_dropped_as_a_key
      ; Alcotest.test_case "build mismatch names the older side" `Quick
          test_build_mismatch_names_the_older_side
      ; Alcotest.test_case "build mismatch is silent without testimony" `Quick
          test_build_mismatch_is_silent_without_testimony
      ;] )
  ; ( "voice meter"
    , [] )
  ]

let () = Alcotest.run "tui_footer_status_items"
  (("inflight navigation", [Alcotest.test_case "global action survives navigation" `Quick test_inflight_action_survives_navigation]) :: tests)
