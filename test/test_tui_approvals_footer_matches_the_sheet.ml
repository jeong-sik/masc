(* The Approvals footer is projected from the same key records as Help, with
   a mode-specific selection and order. A previous literal named [a] while
   Help did not. Compare the rendered keys as atoms so spacing in [ / ] does
   not create a false mismatch. *)

let documented_atoms =
  Masc_tui_keys.for_surface Masc_tui_types.Approvals
  |> List.concat_map (fun (b : Masc_tui_keys.binding) ->
       Masc_tui_footer.key_atoms b.Masc_tui_keys.key)

(* The footer joins its items with two spaces, the same separator the fitter
   splits them on. *)
let footer_items row =
  let len = String.length row in
  let rec split acc start i =
    if i + 1 >= len then List.rev (String.sub row start (len - start) :: acc)
    else if row.[i] = ' ' && row.[i + 1] = ' ' then
      split (String.sub row start (i - start) :: acc) (i + 2) (i + 2)
    else split acc start (i + 1)
  in
  split [] 0 0 |> List.map String.trim
  |> List.filter (fun item -> not (String.equal item ""))

let key_of_item item =
  match String.index_opt item ':' with
  | None -> None
  | Some i -> Some (String.sub item 0 i)

let check_row label row =
  let named = List.filter_map key_of_item (footer_items row) in
  Alcotest.(check bool)
    (Printf.sprintf "the %s row names keys at all" label) true (named <> []);
  List.iter
    (fun key ->
      List.iter
        (fun atom ->
          Alcotest.(check bool)
            (Printf.sprintf "%s (from %s, %s row) is in the sheet" atom key
               label)
            true
            (List.mem atom documented_atoms))
        (Masc_tui_footer.key_atoms key))
    named

let approvals_state () =
  let state =
    Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
  in
  state.Masc_tui_types.view <- Masc_tui_types.Approvals;
  state

(* One ask holding one question that both lists choices and welcomes free
   text, which is the answering row at its longest: the choice digits and the
   editor key are drawn only when the selected question has them. *)
let ask_id = "ask-1"

let with_one_answerable_ask state =
  state.Masc_tui_types.asks_snapshot <-
    Some
      { Masc.Tui_decode_asks.asn_keeper = None
      ; asn_open_count = 1
      ; asn_rows =
          [ { Masc.Tui_decode_asks.ar_keeper = "jazz-developer"
            ; ar_id = ask_id
            ; ar_asked_at = 0.0
            ; ar_context = None
            ; ar_questions =
                [ { Masc.Tui_decode_asks.aq_id = "q1"
                  ; aq_header = "post or wait"
                  ; aq_prompt = "post the comment as is?"
                  ; aq_mode = Masc.Tui_decode_asks.Ask_single
                  ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
                  ; aq_choices =
                      [ { Masc.Tui_decode_asks.ac_id = "post_as_is"
                        ; ac_label = "post as is"
                        ; ac_description = None
                        }
                      ]
                  }
                ]
            ; ar_resolution = Masc.Tui_decode_asks.Ask_open
            }
          ]
      };
  state

let test_every_key_the_footer_names_is_in_the_sheet () =
  check_row "browsing"
    (Masc_tui_render_prim.question_hints (approvals_state ()))

(* The answering mode chooses a different set of bindings. Read the actual
   row in each mode so the projection cannot name a key absent from Help. *)
let test_the_answering_rows_are_in_the_sheet_too () =
  let answering () =
    let state = with_one_answerable_ask (approvals_state ()) in
    state.Masc_tui_types.ask_answer_mode <-
      Masc_tui_types.Ask_answering { aam_ask_id = ask_id };
    state
  in
  check_row "answering" (Masc_tui_render_prim.question_hints (answering ()));
  let armed = answering () in
  armed.Masc_tui_types.pending_ask_submit <- Some ask_id;
  check_row "armed" (Masc_tui_render_prim.question_hints armed)

let contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec scan i =
    i + n <= h
    && (String.equal (String.sub haystack i n) needle || scan (i + 1))
  in
  scan 0

let test_modal_footer_shows_only_keys_that_act () =
  let open Masc_tui_keys in
  let browsing = footer_hints_approvals Approval_browsing in
  Alcotest.(check bool) "browsing names the ask opener" true
    (contains browsing "a:answer a question");
  Alcotest.(check bool) "browsing keeps the approval decision together" true
    (contains browsing "y / n:decide");
  let answering =
    footer_hints_approvals
      (Approval_answering { has_choices = true; takes_text = true })
  in
  Alcotest.(check bool) "answering names its own Enter action" true
    (contains answering "Enter:answer");
  Alcotest.(check bool) "choices expose digit keys" true
    (contains answering "1-9:pick");
  Alcotest.(check bool) "free text exposes the editor" true
    (contains answering "t:write");
  let no_choices =
    footer_hints_approvals
      (Approval_answering { has_choices = false; takes_text = true })
  in
  Alcotest.(check bool) "no choices hide digit keys" false
    (contains no_choices "1-9:pick");
  let no_text =
    footer_hints_approvals
      (Approval_answering { has_choices = true; takes_text = false })
  in
  Alcotest.(check bool) "no text entry hides the editor" false
    (contains no_text "t:write");
  Alcotest.(check string) "writing takes the keyboard"
    "Enter:save  Esc:cancel"
    (footer_hints_approvals Approval_writing);
  Alcotest.(check bool) "armed state tells when Enter sends" true
    (contains (footer_hints_approvals Approval_armed)
       "Press Enter again to send")

let () =
  Alcotest.run "tui_approvals_footer_matches_the_sheet"
    [ ( "approvals footer"
      , [ Alcotest.test_case "every key the footer names is in the sheet" `Quick
            test_every_key_the_footer_names_is_in_the_sheet
        ; Alcotest.test_case "the answering rows are in the sheet too" `Quick
            test_the_answering_rows_are_in_the_sheet_too
        ; Alcotest.test_case "modal footer shows only keys that act" `Quick
            test_modal_footer_shows_only_keys_that_act
        ] )
    ]
