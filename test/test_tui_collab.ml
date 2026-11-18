open Alcotest
module C = Masc_tui_collab

let row name : Masc.Tui_decode.play_invite_row =
  {pi_name = name; pi_expires_at = None; pi_expired = false}

let inventory names : Masc.Tui_decode.play_invites =
  {pis_rows = List.map row names; pis_controller = Masc.Tui_decode.Play_controller_free}

let listed view names =
  let view, read = C.loading view in
  C.listed view read (Ok (inventory names))

let selected view = match snd (C.key view "enter") with
  | C.Open_link name -> Some name
  | C.Stay -> None
  | C.Close | C.Watch _ | C.Game_menu | C.Refresh | C.Issue _ | C.Revoke _ | C.Resolve_unknown _ ->
      fail "a browsing Enter must only inspect its selected link"

let revoke view =
  let view, _ = C.key view "x" in
  match C.key view "enter" with
  | view, C.Revoke (mutation, _) -> view, mutation
  | _ -> fail "a selected invite must support confirmed revocation"

let test_superseded_inventory () =
  let view, older = C.loading (C.create ()) in
  let view, newer = C.loading view in
  let view = C.listed view newer (Ok (inventory ["current"])) in
  let view = C.listed view older (Ok (inventory [])) in
  let view = C.listed view older (Error "old failure") in
  check (option string) "late old inventory and failure cannot replace current rows"
    (Some "current") (selected view);
  let reopened, pending = C.loading (C.create ()) in
  let reopened = C.listed reopened newer (Ok (inventory ["foreign"])) in
  check (option string) "another view's read cannot populate the reopened view" None (selected reopened);
  let reopened = C.listed reopened pending (Ok (inventory ["reopened"])) in
  check (option string) "the reopened view accepts its own read" (Some "reopened") (selected reopened)

let test_removed_selection () =
  let view = listed (C.create ()) ["alpha"; "beta"; "gamma"] in
  let view, _ = C.key view "j" in
  check (option string) "the operator selected beta" (Some "beta") (selected view);
  let view = listed view ["alpha"; "gamma"] in
  check (option string) "removing beta selects a surviving row" (Some "alpha") (selected view);
  let view, _ = C.key view "j" in
  check (option string) "the next row remains reachable" (Some "gamma") (selected view);
  let view = listed view [] in
  check (option string) "empty inventory drops selection" None (selected view);
  let view = listed view ["delta"] in
  check (option string) "a new row restores selection" (Some "delta") (selected view)

let check_read_actions_blocked view =
  check (option string) "a pending or failed read cannot open its retained link" None (selected view);
  let attempted, _ = C.key view "x" in
  check bool "a retained row cannot open a revoke confirmation" true
    (snd (C.key attempted "enter") = C.Stay);
  check bool "machine observation remains available" true
    (snd (C.key view "m") = C.Watch Masc.Machine_lane.Msx);
  let issue, _ = C.key view "n" in
  check bool "issuing a new invite remains independent of the inventory read" true (C.text_input_active issue)

let test_refresh_navigation () =
  let view = listed (C.create ()) ["alpha"; "beta"; "gamma"] in
  let view, _ = C.key view "j" in
  let view, read = C.loading view in
  check_read_actions_blocked view;
  let view, _ = C.key view "j" in
  let view = C.listed view read (Ok (inventory ["alpha"; "gamma"; "beta"])) in
  check (option string) "navigation through retained rows follows the invite name after refresh"
    (Some "gamma") (selected view);
  let view, read = C.loading view in
  let view = C.listed view read (Ok (inventory [])) in
  check (option string) "a successful empty read clears the retained inventory" None (selected view);
  let attempted, _ = C.key view "x" in
  check bool "a cleared invite cannot be revoked" true (snd (C.key attempted "enter") = C.Stay)

let test_failed_refresh_navigation () =
  let view = listed (C.create ()) ["alpha"; "beta"; "gamma"] in
  let view, _ = C.key view "j" in
  let view, _ = C.key view "j" in
  let view, read = C.loading view in
  let view = C.listed view read (Error "offline") in
  check_read_actions_blocked view;
  let view, _ = C.key view "k" in
  let view, read = C.loading view in
  check_read_actions_blocked view;
  let view = C.listed view read (Ok (inventory ["gamma"; "beta"; "alpha"])) in
  check (option string) "retry retains navigation after the failure" (Some "beta") (selected view);
  let _, action = C.key (fst (C.key view "x")) "enter" in
  check bool "a successful reread restores revocation for the selected invite" true
    (match action with C.Revoke (_, "beta") -> true | _ -> false)

let test_refresh_preserves_captured_confirmation () =
  let view = listed (C.create ()) ["alpha"] in
  let view, _ = C.key view "x" in
  let view, _ = C.loading view in
  check bool "refresh does not withdraw an already captured revoke confirmation" true
    (match snd (C.key view "enter") with C.Revoke (_, "alpha") -> true | _ -> false)

let test_notice_does_not_settle_mutation () =
  let view, first = revoke (listed (C.create ()) ["alpha"]) in
  let view = C.notice view "The one-time link is not retained" in
  let view = listed view ["alpha"] in
  let attempted, _ = C.key view "n" in
  check bool "notice and refresh cannot reenable issue while revocation is pending"
    false (C.text_input_active attempted);
  let second_view, foreign = revoke (listed (C.create ()) ["alpha"]) in
  let view = C.settled view foreign in
  let attempted, _ = C.key view "n" in
  check bool "a foreign mutation receipt cannot release this owner" false (C.text_input_active attempted);
  let view = C.settled view first in
  let attempted, _ = C.key view "n" in
  check bool "the matching receipt releases the form" true (C.text_input_active attempted);
  let view, second = revoke view in
  let view = C.settled view first in
  let attempted, _ = C.key view "n" in
  check bool "an earlier receipt cannot release a later mutation" false (C.text_input_active attempted);
  let view = C.settled view second in
  let attempted, _ = C.key view "n" in
  check bool "the later receipt releases its own form" true (C.text_input_active attempted);
  let second_view = C.settled second_view first in
  let attempted, _ = C.key second_view "n" in
  check bool "a reopened owner retains its own pending mutation" false (C.text_input_active attempted)

let test_explicit_unknown_resolution () =
  let view = C.write_access (C.create ()) (C.Uncertain {request_id="request-r"; notice="unknown request"}) in
  let view, _ = C.key view "u" in
  let pasted = C.paste view "\r" in
  check bool "pasting cannot submit resolution" false (C.text_input_active pasted);
  let _, action = C.key view "enter" in
  check bool "the confirmation retains the request being verified" true (action = C.Resolve_unknown "request-r");
  let replaced = C.write_access view (C.Uncertain {request_id="request-r2"; notice="another request"}) in
  let _, action = C.key replaced "enter" in
  check bool "a different unknown request withdraws the confirmation" true (action = C.Stay);
  let blocked = C.write_access view (C.Read_only "workspace mismatch") in
  let _, action = C.key blocked "enter" in
  check bool "losing authority withdraws the confirmation" true (action = C.Stay);
  let cancelled, _ = C.key view "esc" in
  let _, action = C.key cancelled "enter" in
  check bool "cancelled resolution cannot be confirmed" true (action = C.Stay)

(* The invites are the list the keys move, so the overlay hands the selected
   invite among them (RFC tui-one-screen-grammar, section 2), read as the
   value handed. *)
let test_position_is_the_selected_invite () =
  let rows view = match C.position view with
    | Some (Masc_tui_value.Position.Row { at; total }) -> Some (at, total)
    | Some (Masc_tui_value.Position.Window _ | Masc_tui_value.Position.Partial _) ->
        fail "the invite list hands its selected row, not a window"
    | None -> None in
  check (option (pair int int)) "nothing listed hands nothing" None (rows (C.create ()));
  let view = listed (C.create ()) ["a"; "b"; "c"] in
  let view, _ = C.key view "j" in
  check (option (pair int int)) "the second of three invites" (Some (2, 3)) (rows view)

let () = run "Collab request ownership" ["operator flows", [
  test_case "the position is the selected invite" `Quick test_position_is_the_selected_invite;
  test_case "superseded and foreign inventories are ignored" `Quick test_superseded_inventory;
  test_case "removed selections move to surviving invites" `Quick test_removed_selection;
  test_case "refresh retains navigation without admitting row actions" `Quick test_refresh_navigation;
  test_case "failed refresh retains navigation until a successful retry" `Quick test_failed_refresh_navigation;
  test_case "refresh preserves an existing explicit confirmation" `Quick test_refresh_preserves_captured_confirmation;
  test_case "only the matching receipt settles a mutation" `Quick test_notice_does_not_settle_mutation;
  test_case "unknown resolution requires its explicit current confirmation" `Quick test_explicit_unknown_resolution;
]]
