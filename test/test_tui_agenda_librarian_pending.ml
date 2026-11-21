(** What the strip above the composer says, and whether it takes a row at all.

    The rows here are the ones the live workspace was carrying when this was
    written: an [edgar.a.poe] check on cron ["45 8-23 * * *"], the hourly
    board sweeps behind it, and the settled rows that outnumber them 37 to 13
    in the same store.

    Two properties matter more than any one rendering. The first is that
    [rows_taken] and [strip] answer the same question -- the frame draws the
    row that the keypress bound subtracts, or neither does. The second is
    that a status nobody recognised does not reach the strip: the wire is
    strings, and a string that means nothing to us must not mean "due". *)

open Alcotest

(* Refresh the same mutable workspace fields the loader replaces. Selection
   is the identity from the earlier displayed projection; renderer lookup and
   Enter lookup must agree even though that projection's row numbers moved. *)
let agenda_state () =
  Masc_tui_types.create_state ~workspace:"" ~port:0 ()

let test_home_operator_target_keeps_original_request () =
  let module A = Masc.Operator_action_reason in
  let module P = Masc.Keeper_librarian_pending in
  let state = agenda_state () in
  let action request = A.memory_attention ~keeper:"keeper-a" ~durable:(Some (P.Worker
      {installation_id="original";request_id=request;wait=P.Missing_after_dispatch}))
      ~admission:None ~measured_at:(Some 123.) in
  let install item =
    match Masc.Tui_decode.decode_server_identity (`Assoc
      ["operator_action_required",`Bool true;
       "operator_action_reasons",`List [`String (A.diagnostic item)];
       "operator_actions",`List [A.to_json item]]) with
    | Ok identity -> state.server_identity <- Some identity
    | Error error -> Alcotest.fail error in
  let original = action "request-one" in
  install original;
  let target = match Masc_tui_home.home_operator_rows (Masc_tui_home.prepare state) with
    | [(target,_)] -> target
    | _ -> Alcotest.fail "one original observation is required" in
  state.home_selected <- Some target;
  check bool "the selected target retains the original request and scope" true
    (match target with
     | Masc_tui_types.Home_operator_action (authority,_,item) ->
         authority=state.workspace_authority && A.equal original item
     | Home_request _ | Home_approvals | Home_agenda | Home_resume _
     | Home_read_last _ | Home_choose_keeper | Home_create_keeper -> false);
  install (action "request-two");
  check bool "the same array index cannot retarget to another original" true
    (Option.is_none (Masc_tui_home.home_selected_action (Masc_tui_home.prepare state)))

let () =
  run
    "tui_agenda_librarian_pending"
    [ ( "the frame and the bound"
      , [

        ] )
    ; ( "how it reads"
      , [] )
    ; ( "questions waiting on the operator"
      , [ test_case "operator target keeps the original request" `Quick
            test_home_operator_target_keeps_original_request
        ] )
    ]
;;
