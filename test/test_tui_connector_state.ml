open Alcotest
module State = Masc_tui_connector_state
module Reading = Masc.Tui_decode

let connections =
  [ ("connected", Reading.Connector_connected)
  ; ("connected / unavailable", Reading.Connector_connected_unavailable)
  ; ("disconnected", Reading.Connector_disconnected)
  ; ("offline", Reading.Connector_offline)
  ; ("stale", Reading.Connector_stale)
  ]

let test_every_connection_spells_its_own_badge () =
  let words = List.map (fun (_, c) -> State.badge_word c) connections in
  check int "one word per connection" (List.length connections)
    (List.length (List.sort_uniq String.compare words));
  List.iter
    (fun word ->
      check bool (word ^ " is spelled for the badge") true
        (String.equal word (String.uppercase_ascii word)))
    words

(* The connector the server sends, read through the same decoder the pane
   reads it through. [status]/[available]/[connected] pick the badge. *)
let connector ~status ~available ~connected ?gateway_state ?poll_state () =
  let optional name = function
    | None -> []
    | Some value -> [ (name, `String value) ]
  in
  let json =
    `Assoc
      [ ( "connectors"
        , `List
            [ `Assoc
                ([ ("connector_id", `String "transport")
                 ; ("display_name", `String "Transport")
                 ; ("status", `String status)
                 ; ("available", `Bool available)
                 ; ("connected", `Bool connected)
                 ; ("configured_bindings", `List [])
                 ]
                @ optional "gateway_state" gateway_state
                @ optional "poll_state" poll_state)
            ] )
      ; ("total", `Int 1)
      ; ("active_count", `Int 1)
      ]
  in
  match Reading.decode_connector_snapshot json with
  | Ok { Reading.cs_connectors = [ c ]; _ } -> c
  | Ok _ -> fail "expected one connector"
  | Error err -> failf "decode failed: %s" err

(* The Discord row read "Connection ● CONNECTED" above "Runtime state
   connected": the gateway's state and the badge's are the same reading. *)
let test_a_runtime_state_the_badge_already_names_is_not_drawn () =
  check (option string) "a connected gateway under CONNECTED" None
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~gateway_state:"connected" ()));
  check (option string) "a disconnected gateway under DISCONNECTED" None
    (State.runtime_state_to_draw
       (connector ~status:"disconnected" ~available:true ~connected:false
          ~gateway_state:"disconnected" ()));
  (* The badge spells two words here, and CONNECTED is one of them. The row
     used to draw "Runtime state connected" underneath it -- the half the
     badge had already spelled, with nothing to say which half it meant. *)
  check (option string) "a connected gateway under CONNECTED / UNAVAILABLE"
    None
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:true
          ~gateway_state:"connected" ()))

(* Slack's transport read "○ UNAVAILABLE" with a gateway that said
   "disconnected", which is the reading this row exists for. *)
let test_a_runtime_state_the_badge_does_not_name_is_drawn () =
  check (option string) "a disconnected gateway under UNAVAILABLE"
    (Some "disconnected")
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:false
          ~gateway_state:"disconnected" ()));
  check (option string) "a resuming gateway under CONNECTED"
    (Some "resuming")
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~gateway_state:"resuming" ()));
  (* The pair above and this one share a badge, so this is the input that
     tells "the badge spells this word" apart from "this badge says
     everything": CONNECTED / UNAVAILABLE spells neither half as "resuming". *)
  check (option string) "a resuming gateway under CONNECTED / UNAVAILABLE"
    (Some "resuming")
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:true
          ~gateway_state:"resuming" ()));
  check (option string) "a poller under CONNECTED" (Some "polling")
    (State.runtime_state_to_draw
       (connector ~status:"connected" ~available:true ~connected:true
          ~poll_state:"polling" ()));
  check (option string) "a transport with no state of its own draws none" None
    (State.runtime_state_to_draw
       (connector ~status:"offline" ~available:false ~connected:false ()))

(* One vocabulary, read from one table. The Channels pane draws the badge in
   two places -- a word in the list row and a coloured badge in the detail --
   and it used to carry its own byte-identical copy of this table for the list
   row. A copy is not merely a duplicate: the omission rule above judges
   against [badge_word], so a vocabulary change that lands in the copy alone
   leaves the rule judging against a spelling the screen no longer uses. The
   literals are taken from the table rather than written out here, because a
   test that forbids a copy must not keep one. *)
let test_the_pane_keeps_no_copy_of_the_badge_vocabulary () =
  let literals = List.map (fun (_, c) -> State.badge_word c) connections in
  check int "badge words spelled inside keeper_detail_pane" 0
    (Ast_grep.count_string_literals_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"keeper_detail_pane"
       ~literals)

(* The list row reserved twelve cells for the badge word while one of the
   five words is twenty-three cells long, so that row cut [CONNECTED /
   UNAVAILABLE] down to [CONNECTED …]. A cut name is still a name; a cut
   state word is a *different state*, and this one dropped exactly the half
   an operator has to act on. The column asks the table how wide it has to
   be, so a new word widens it instead of being cut by it. *)
let test_the_badge_column_holds_every_word_whole () =
  check int "one word per connection" (List.length connections)
    (List.length State.badge_words);
  let widest =
    List.fold_left
      (fun widest word -> max widest (String.length word))
      0 State.badge_words
  in
  check int "the column is as wide as the widest word" widest
    State.badge_column_cells;
  check bool "and no wider: a word fills it exactly" true
    (List.exists
       (fun word -> String.length word = State.badge_column_cells)
       State.badge_words);
  (* The fact that made this a defect rather than a preference. *)
  check bool "the compound word did not fit the twelve cells the row reserved"
    true
    (String.length (State.badge_word Reading.Connector_connected_unavailable)
    > 12)

(* Three things share the row and only one may be shortened. Without the two
   narrow readings below, a column that simply always hands out fourteen
   cells passes the wide ones. *)
let test_the_name_column_is_the_one_that_gives_way () =
  let tail_cells = String.length "  2 here / 7 total" in
  let name inner = State.list_row_name_cells ~inner ~fixed_cells:6 ~tail_cells in
  check int "a wide frame draws the row it drew yesterday"
    State.name_cells_preferred (name 136);
  check int "so does the narrowest split pane" State.name_cells_preferred
    (name 76);
  check int "a narrow frame spends the name's cells, not the badge's" 9
    (name 56);
  check bool "and the name never vanishes" true (name 20 >= 8);
  check bool "the name is never grown past what the row asked for" true
    (name 400 = State.name_cells_preferred)

(* The width is a fact about the table, so the pane must not carry a second
   copy of it -- the same reason the pane keeps no copy of the words. *)
let test_the_pane_keeps_no_copy_of_the_column_width () =
  let literals =
    Ast_grep.int_literals_in_value_binding
      ~module_path:"bin/masc_tui_render.ml" ~binding_name:"keeper_detail_pane"
  in
  check bool "the badge column width is not written out in the pane" false
    (List.mem State.badge_column_cells literals);
  check bool "neither is the twelve the row used to reserve" false
    (List.mem 12 literals)

let () =
  run "tui connector state"
    [ ( "badge"
      , [ test_case "every connection spells its own badge" `Quick
            test_every_connection_spells_its_own_badge
        ; test_case "the pane keeps no copy of the badge vocabulary" `Quick
            test_the_pane_keeps_no_copy_of_the_badge_vocabulary
        ] )
    ; ( "list row"
      , [ test_case "the badge column holds every word whole" `Quick
            test_the_badge_column_holds_every_word_whole
        ; test_case "the name column is the one that gives way" `Quick
            test_the_name_column_is_the_one_that_gives_way
        ; test_case "the pane keeps no copy of the column width" `Quick
            test_the_pane_keeps_no_copy_of_the_column_width
        ] )
    ; ( "runtime state"
      , [ test_case "a state the badge already names is not drawn" `Quick
            test_a_runtime_state_the_badge_already_names_is_not_drawn
        ; test_case "a state the badge does not name is drawn" `Quick
            test_a_runtime_state_the_badge_does_not_name_is_drawn
        ] )
    ]
