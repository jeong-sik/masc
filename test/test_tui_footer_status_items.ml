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
let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "action text is not dropped as a key" `Quick
          test_action_text_is_not_dropped_as_a_key
      ; Alcotest.test_case "build mismatch names the older side" `Quick
          test_build_mismatch_names_the_older_side
      ; Alcotest.test_case "build mismatch is silent without testimony" `Quick
          test_build_mismatch_is_silent_without_testimony
      ;] )
  ; ( "voice meter"
    , [] )
  ]




let test_minimal_context_preserves_send_controls () =
  let context_hints = ["Enter:update"; "^T:queue"; "^K:cancel"; "^P:edit"] in
  let shown = Masc_tui_footer.minimal_context_chat_hints ~max_cells:76
      ~context_hints ~escape_hint:"Esc:detail" in
  List.iter (fun hint -> check_bool ("contextual key remains visible: " ^ hint) true
    (contains ~needle:hint shown)) (context_hints @ ["/:commands"; "?:help"])

let test_minimal_footer_preserves_discovery () =
  List.iter (fun width ->
    let shown = Masc_tui_footer.minimal_chat_hints ~max_cells:(width - 4)
      ~enter_hint:"Enter:send" ~escape_hint:"Esc:detail" in
    Alcotest.(check bool) "commands remain whole" true
      (contains ~needle:"/:commands" shown);
    Alcotest.(check bool) "help remains whole" true
      (contains ~needle:"?:help" shown);
    Alcotest.(check bool) "fits framed row" true
      (Masc_tui_message_layout.display_width shown <= width - 4)) [24; 32; 41; 59; 80]

let () = Alcotest.run "tui_footer_status_items"
  (("minimal chat", [Alcotest.test_case "contextual send controls remain visible" `Quick test_minimal_context_preserves_send_controls; Alcotest.test_case "discovery survives narrow rows" `Quick test_minimal_footer_preserves_discovery]) :: tests)
