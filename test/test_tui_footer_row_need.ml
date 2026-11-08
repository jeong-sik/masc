(* A list with no rows has nothing for the row keys to act on. The dispatcher
   ends [j/k], [Right / Enter] and the keys that answer, edit or copy a row in
   [()] there, and the footer drew them anyway, first in line -- so a terminal
   too narrow for the whole row gave up the keys that do act before them: on an
   empty Schedules list the footer showed [j/k], [PgUp/PgDn] and
   [Right / Enter] and left [n:new] behind [...?].

   The table says which keys need a row ([Masc_tui_keys.row_need]) and
   [footer_hints ~has_rows] leaves them out. This file pins that half, one
   surface at a time as each list renderer starts passing [~has_rows]. The
   argument is optional, so a renderer that omits it still compiles and goes
   back to advertising every key; the table half cannot catch that. *)

open Alcotest
module Keys = Masc_tui_keys
module T = Masc_tui_types

let contains haystack needle =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec scan index =
    if index + needle_length > haystack_length then false
    else if String.equal (String.sub haystack index needle_length) needle then
      true
    else scan (index + 1)
  in
  scan 0

(* An item is "key:label" and items are joined by two spaces, so a key names
   an item only right after a separator: "e:" is inside "Left / Esc:". *)
let names_item hints key = contains ("  " ^ hints) ("  " ^ key ^ ":")

(* A surface, the keys it spells that need a row, and the keys that answer on
   an empty list. Each is the key as the table spells it. *)
let surfaces =
  [ ( "Schedules",
      T.Schedules,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "e"; "x"; "Y"; "Home/End" ],
      [ "n"; "< / >"; "Esc"; "r"; "q" ] )
  ; ( "Harness",
      T.Harness,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "y / x"; "Y"; "Home/End" ],
      [ "v"; "/"; "Esc"; "r"; "q" ] )
  ; ( "Task Review",
      T.Verification,
      [ "j/k"; "Right / Enter"; "a / x"; "n / N"; "PgUp/PgDn"; "Home/End" ],
      [ "v"; "h"; "/"; "< / >"; "Esc"; "r"; "q" ] )
  ; ( "Fusion",
      T.Fusion,
      [ "j/k"; "PgUp/PgDn"; "Enter"; "K"; "B"; "Y"; "/"; "n / N"; "Home/End" ],
      [ "a"; "Esc"; "r"; "q" ] )
  ; ( "Clients",
      T.Clients,
      [ "j/k"; "Enter"; "/"; "n / N"; "PgUp/PgDn"; "Home/End" ],
      [ "p / Esc"; "r"; "q" ] )
  ]

let test_each_surface_scopes_a_key_to_a_row () =
  List.iter
    (fun (name, surface, _, _) ->
      check bool (name ^ " has a key that needs a row") true
        (Keys.has_row_scoped_keys surface))
    surfaces

let test_an_empty_list_names_no_key_that_needs_a_row () =
  List.iter
    (fun (name, surface, needing, _) ->
      let empty = Keys.footer_hints ~detail_open:false ~has_rows:false surface in
      List.iter
        (fun key ->
          check bool
            (name ^ " empty list does not name " ^ key)
            false (names_item empty key))
        needing)
    surfaces

let test_a_list_with_a_row_names_every_key () =
  List.iter
    (fun (name, surface, needing, answering) ->
      let full = Keys.footer_hints ~detail_open:false ~has_rows:true surface in
      List.iter
        (fun key ->
          check bool (name ^ " list with a row names " ^ key) true
            (names_item full key))
        (needing @ answering))
    surfaces

(* Scoping moved the keys, it did not delete them: a caller that says nothing
   about rows reads every one, which is what every caller did before the
   argument existed and what the cheat sheet still draws. *)
let test_a_caller_that_names_no_rows_keeps_every_key () =
  List.iter
    (fun (name, surface, needing, answering) ->
      let unsaid = Keys.footer_hints ~detail_open:false surface in
      List.iter
        (fun key ->
          check bool (name ^ " naming no rows still names " ^ key) true
            (names_item unsaid key))
        (needing @ answering))
    surfaces

(* What an empty list can still do stays on the footer: the keys that create,
   page the server, go back, find, refresh or quit. *)
let test_an_empty_list_keeps_the_keys_that_answer () =
  List.iter
    (fun (name, surface, _, answering) ->
      let empty = Keys.footer_hints ~detail_open:false ~has_rows:false surface in
      List.iter
        (fun key ->
          check bool (name ^ " empty list still names " ^ key) true
            (names_item empty key))
        answering)
    surfaces

let () =
  run "tui footer row need"
    [ ( "table",
        [ test_case "each surface scopes a key to a row" `Quick
            test_each_surface_scopes_a_key_to_a_row
        ; test_case "an empty list names no key that needs a row" `Quick
            test_an_empty_list_names_no_key_that_needs_a_row
        ; test_case "a list with a row names every key" `Quick
            test_a_list_with_a_row_names_every_key
        ; test_case "a caller that names no rows keeps every key" `Quick
            test_a_caller_that_names_no_rows_keeps_every_key
        ; test_case "an empty list keeps the keys that answer" `Quick
            test_an_empty_list_keeps_the_keys_that_answer
        ] )
    ]
