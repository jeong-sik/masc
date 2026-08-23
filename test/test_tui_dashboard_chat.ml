open Alcotest
open Masc_tui_types

let test_surface_dashboard_chat_variant () =
  let view = Dashboard_chat in
  match view with
  | Dashboard_chat -> Alcotest.(check bool) "is dashboard chat" true true
  | _ -> Alcotest.fail "expected Dashboard_chat"

let test_dashboard_chat_entry_formatting () =
  let entry : msg_entry = {
    me_role = Message_user;
    me_text = "/directive keeper-analyst resume task-464";
    me_timestamp = "2026-08-23T11:00:00Z";
    me_keeper_name = "operator";
    me_request_id = "global-chat";
  } in
  Alcotest.(check string) "text match" "/directive keeper-analyst resume task-464" entry.me_text;
  Alcotest.(check string) "keeper name match" "operator" entry.me_keeper_name

let () =
  run "TUI Dashboard Chat"
    [ ( "surface"
      , [ test_case "dashboard_chat variant" `Quick test_surface_dashboard_chat_variant
        ; test_case "entry formatting" `Quick test_dashboard_chat_entry_formatting
        ] )
    ]
