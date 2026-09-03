(* The composer row: what it says before a key is pressed, and which keys it
   claims. *)

module Composer = Masc_tui_composer

let make ?(target = Composer.Ready "analyst") ?(focus = Composer.Unfocused)
    ?(draft = "") ?(staged_images = 0) () : Composer.t =
  { target; focus; draft; staged_images }

(* An attachment the prompt does not name is an attachment the operator forgets
   before pressing enter. The count is the only place it shows. *)
let test_prompt_names_staged_images () =
  Alcotest.(check string)
    "no marker with nothing staged"
    "to analyst"
    (Composer.prompt (make ()));
  Alcotest.(check string)
    "marker with an image staged"
    "to analyst [1 image]"
    (Composer.prompt (make ~staged_images:1 ()))
;;

let outcome_testable =
  Alcotest.testable
    (fun fmt outcome ->
       Format.pp_print_string fmt
         (match outcome with
          | Composer.Take_focus -> "take_focus"
          | Composer.Release_focus -> "release_focus"
          | Composer.Send -> "send"
          | Composer.Start_listening -> "start_listening"
          | Composer.Edit -> "edit"
          | Composer.Pass_to_surface -> "pass"))
    ( = )

let check_key ?(label = "key") composer key expected =
  Alcotest.(check outcome_testable) label expected
    (Composer.classify_key composer key)

(* The row exists to answer this before anything is typed. An operator who
   cannot see the recipient finds out which keeper got the message by sending
   it. *)
let test_prompt_names_the_recipient () =
  Alcotest.(check string) "the target keeper" "to analyst"
    (Composer.prompt (make ()));
  Alcotest.(check string) "nothing selected" "no keeper selected"
    (Composer.prompt (make ~target:Composer.No_target ()))

(* A keeper that went away keeps its name in the row. Blanking it loses the one
   thing that explains why the draft cannot go anywhere. *)
let test_unreachable_target_keeps_its_name_and_reason () =
  let composer =
    make
      ~target:
        (Composer.Unreachable
           { keeper = "beta"; reason = "no longer in the roster" })
      ()
  in
  Alcotest.(check string) "name and reason" "beta — no longer in the roster"
    (Composer.prompt composer);
  Alcotest.(check bool) "cannot send" false (Composer.can_send composer)

(* Every surface binds single letters. A row that took every printable key
   while idle would take [p] from pause and [q] from quit. *)
let test_idle_composer_claims_only_its_focus_key () =
  let composer = make () in
  check_key ~label:"the focus key" composer Composer.focus_key
    Composer.Take_focus;
  List.iter
    (fun key -> check_key ~label:key composer key Composer.Pass_to_surface)
    [ "p"; "s"; "w"; "q"; "j"; "k"; "l"; "c"; "r"; "\r"; "\t"; "esc"; "2" ]

(* Focus that leads nowhere is a trap: the surface keys stop working and the
   draft still cannot be sent. *)
let test_focus_is_refused_without_a_reachable_target () =
  List.iter
    (fun target ->
       let composer = make ~target () in
       check_key composer Composer.focus_key Composer.Pass_to_surface)
    [ Composer.No_target
    ; Composer.Unreachable { keeper = "beta"; reason = "gone" }
    ]

let test_focused_composer_takes_the_printable_keys () =
  let composer = make ~focus:Composer.Focused () in
  List.iter
    (fun key -> check_key ~label:key composer key Composer.Edit)
    [ "p"; "s"; "w"; "q"; "j"; "2"; "가"; " "; "\127" ]

let test_focused_composer_releases_and_sends () =
  let empty = make ~focus:Composer.Focused () in
  check_key ~label:"release" empty Composer.release_key Composer.Release_focus;
  (* Enter on an empty draft must not send: an empty message is not a message,
     and the keypress should read as a no-op rather than a dispatch. *)
  check_key ~label:"enter on empty" empty "\r" Composer.Edit;
  let typed = make ~focus:Composer.Focused ~draft:"안녕" () in
  check_key ~label:"enter on a draft" typed "\r" Composer.Send;
  let blank = make ~focus:Composer.Focused ~draft:"   \n  " () in
  check_key ~label:"enter on whitespace" blank "\r" Composer.Edit

let test_input_is_refused_without_a_recipient () =
  Alcotest.(check bool) "focused and ready" true
    (Composer.accepts_input (make ~focus:Composer.Focused ()));
  Alcotest.(check bool) "focused with nothing to send to" false
    (Composer.accepts_input
       (make ~focus:Composer.Focused ~target:Composer.No_target ()));
  Alcotest.(check bool) "unfocused" false
    (Composer.accepts_input (make ~focus:Composer.Unfocused ()))

(* The cursor has to sit after the draft and inside the row; past the last
   column it wraps the terminal and the frame scrolls. *)
let test_cursor_stays_inside_the_row () =
  Alcotest.(check int) "after the draft" 12
    (Composer.cursor_column ~prompt_cells:8 ~draft_cells:3 ~terminal_cols:80);
  Alcotest.(check int) "clamped at the last column" 40
    (Composer.cursor_column ~prompt_cells:30 ~draft_cells:200
       ~terminal_cols:40);
  Alcotest.(check int) "never left of the first" 1
    (Composer.cursor_column ~prompt_cells:0 ~draft_cells:0 ~terminal_cols:0)

let test_send_requires_a_reachable_target () =
  Alcotest.(check bool) "ready with text" true
    (Composer.can_send (make ~draft:"hi" ()));
  Alcotest.(check bool) "ready without text" false
    (Composer.can_send (make ~draft:"" ()));
  Alcotest.(check bool) "unreachable with text" false
    (Composer.can_send
       (make ~draft:"hi"
          ~target:(Composer.Unreachable { keeper = "beta"; reason = "gone" })
          ()))


(* Ctrl-Y asks for a capture. It has to be a control code: in a focused row
   every printable key is draft text, so a letter binding would take that
   letter from typing. *)
let test_focused_composer_claims_the_listen_key () =
  check_key
    ~label:"ctrl-y starts a capture"
    (make ~focus:Composer.Focused ())
    Composer.listen_key
    Composer.Start_listening
;;

(* A transcript needs somewhere to go. Capturing into a row with no recipient
   leaves the operator holding speech that cannot be sent. *)
let test_listen_key_needs_a_recipient () =
  check_key
    ~label:"no keeper, no capture"
    (make ~target:Composer.No_target ~focus:Composer.Focused ())
    Composer.listen_key
    Composer.Edit
;;

(* Unfocused the row claims one key and no more; the surfaces bind letters to
   lifecycle and navigation, and a second claim here would take one. *)
let test_unfocused_composer_does_not_claim_the_listen_key () =
  check_key
    ~label:"the surface still gets ctrl-y while the row is idle"
    (make ~focus:Composer.Unfocused ())
    Composer.listen_key
    Composer.Pass_to_surface
;;

(* The binding is a control code rather than a letter, which is what keeps
   typing whole. A single printable character here would be a regression that
   the two tests above still pass. *)
let test_the_listen_key_is_not_typable () =
  let byte = Composer.listen_key.[0] in
  Alcotest.(check bool)
    "listen_key is one control byte"
    true
    (String.length Composer.listen_key = 1 && Char.code byte < 32)
;;

let () =
  Alcotest.run "tui-composer"
    [ ( "what the row says"
      , [ Alcotest.test_case "the prompt names the recipient" `Quick
            test_prompt_names_the_recipient
        ; Alcotest.test_case "an unreachable target keeps its name" `Quick
            test_unreachable_target_keeps_its_name_and_reason
        ; Alcotest.test_case "send needs a reachable target" `Quick
            test_send_requires_a_reachable_target
        ] )
    ; ( "which keys it claims"
      , [ Alcotest.test_case "idle it claims only its focus key" `Quick
            test_idle_composer_claims_only_its_focus_key
        ; Alcotest.test_case "focus is refused with nowhere to send" `Quick
            test_focus_is_refused_without_a_reachable_target
        ; Alcotest.test_case "focused it takes the printable keys" `Quick
            test_focused_composer_takes_the_printable_keys
        ; Alcotest.test_case "focused it releases and sends" `Quick
            test_focused_composer_releases_and_sends
        ; Alcotest.test_case "prompt names staged images" `Quick
            test_prompt_names_staged_images
        ; Alcotest.test_case "input needs a recipient" `Quick
            test_input_is_refused_without_a_recipient
        ] )
    ; ( "voice"
      , [ Alcotest.test_case "focused it claims the listen key" `Quick
            test_focused_composer_claims_the_listen_key
        ; Alcotest.test_case "the listen key needs a recipient" `Quick
            test_listen_key_needs_a_recipient
        ; Alcotest.test_case "unfocused it does not claim the listen key" `Quick
            test_unfocused_composer_does_not_claim_the_listen_key
        ; Alcotest.test_case "the listen key is not typable" `Quick
            test_the_listen_key_is_not_typable
        ] )
    ; ( "layout"
      , [ Alcotest.test_case "the cursor stays inside the row" `Quick
            test_cursor_stays_inside_the_row
        ] )
    ]
