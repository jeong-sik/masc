(* What the wide pane beside a list says with nothing open in it (#35894).

   Code and Resources fitted a failed list read to the narrow pane, which cut
   the cause off the end of the reason, and the wide pane beside it said the
   same thing whatever the list held: Code offered Enter beside a listing that
   held nothing to select. These pin the choice the wide pane makes from the
   list's reading, driven through the reads that produce it. *)

open Alcotest
module F = Masc_tui_fetched
module Idle = Masc_tui_list_idle

let equal = String.equal

let started = function
  | F.Started (t, request) -> t, request
  | F.Already_loading -> fail "expected the request to start"
;;

(* What the pane chose, and the reason it was handed to draw. *)
let chose = function
  | Idle.List_unread -> "unread", None
  | List_loading -> "loading", None
  | List_failed reason -> "failed", Some reason
  | List_empty reason -> "empty", reason
  | Rows_ready reason -> "rows", reason
;;

let reading = pair string (option string)

(* The cause sits at the end, after the label the narrow pane kept. *)
let cause = "workspace entries: HTTP 503: fixture endpoint unavailable"

let listing t = Idle.of_listing (F.view_for ~equal t ~key:"lib")

let test_a_listing_that_failed_hands_over_its_whole_reason () =
  let loading, request = started (F.start ~equal F.initial ~key:"lib") in
  check reading "nothing asked" ("unread", None) (chose (listing F.initial));
  check reading "asked, waiting" ("loading", None) (chose (listing loading));
  let failed = F.complete ~equal loading request (Error cause) in
  check reading "the failure arrives whole, with nothing to open"
    ("failed", Some cause) (chose (listing failed))
;;

let test_only_rows_to_select_offer_something_to_open () =
  let loading, request = started (F.start ~equal F.initial ~key:"lib") in
  check reading "an answer with no entries is not a wait" ("empty", None)
    (chose (listing (F.complete ~equal loading request (Ok []))));
  check reading "entries to select" ("rows", None)
    (chose (listing (F.complete ~equal loading request (Ok [ "a.ml" ]))))
;;

(* A refresh that fails keeps the rows it read, and the narrow pane's label
   for it ("Refresh failed, showing the last read: ") is wider than the pane,
   so the reason after the label was never on screen at all. *)
let test_a_failed_refresh_keeps_its_rows_and_its_reason () =
  let refreshed rows =
    let loading, request = started (F.start ~equal F.initial ~key:"lib") in
    let ready = F.complete ~equal loading request (Ok rows) in
    let again, retry = started (F.refresh ~equal ready ~key:"lib") in
    F.complete ~equal again retry (Error cause)
  in
  check reading "rows stay selectable beside the reason" ("rows", Some cause)
    (chose (listing (refreshed [ "a.ml" ])));
  check reading "an empty reading keeps its reason too" ("empty", Some cause)
    (chose (listing (refreshed [])))
;;

(* Resources holds its inventory as rows, a status line and a pending read. *)
let test_the_inventory_chooses_from_the_same_states () =
  let inventory ~rows ~reason ~reading = chose (Idle.of_inventory ~rows ~reason ~reading) in
  let mcp_failed = "MCP initialize: HTTP 503: fixture endpoint unavailable" in
  check reading "a failed list with nothing read" ("failed", Some mcp_failed)
    (inventory ~rows:None ~reason:(Some mcp_failed) ~reading:false);
  check reading "a failure outranks a retry still pending" ("failed", Some mcp_failed)
    (inventory ~rows:None ~reason:(Some mcp_failed) ~reading:true);
  check reading "a read on the wire" ("loading", None)
    (inventory ~rows:None ~reason:None ~reading:true);
  check reading "no read pending is not a wait" ("unread", None)
    (inventory ~rows:None ~reason:None ~reading:false);
  check reading "no resources" ("empty", None)
    (inventory ~rows:(Some []) ~reason:None ~reading:false);
  check reading "a partial inventory keeps its rows and says why" ("rows", Some mcp_failed)
    (inventory ~rows:(Some [ "report" ]) ~reason:(Some mcp_failed) ~reading:false)
;;

let () =
  run "tui_list_idle"
    [ ( "listing",
        [ test_case "a listing that failed hands over its whole reason" `Quick
            test_a_listing_that_failed_hands_over_its_whole_reason
        ; test_case "only rows to select offer something to open" `Quick
            test_only_rows_to_select_offer_something_to_open
        ; test_case "a failed refresh keeps its rows and its reason" `Quick
            test_a_failed_refresh_keeps_its_rows_and_its_reason ] )
    ; ( "inventory",
        [ test_case "the inventory chooses from the same states" `Quick
            test_the_inventory_chooses_from_the_same_states ] ) ]
;;
