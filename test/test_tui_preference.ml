(* RFC-0482 §3.1: the server takes a change to the [tui] table only in a
   shape it can write, and writes it the way the terminal reads it back. *)

open Alcotest

module P = Masc.Tui_preference
module Toml = Keeper_toml_loader

let keeper name =
  match Keeper_id.Keeper_name.of_string name with
  | Ok name -> name
  | Error detail -> failf "keeper name fixture: %s" detail

let change = testable (fun ppf change -> Yojson.Safe.pp ppf (P.change_to_yojson change)) ( = )

let parse text =
  match Yojson.Safe.from_string text with
  | json -> P.change_of_yojson json
  | exception Yojson.Json_error detail -> failf "fixture is not JSON: %s" detail

let every_change =
  [ P.Chat_visited (keeper "analyst")
  ; P.Theme_chosen (Some "ayu-dark")
  ; P.Theme_chosen None
  ; P.Language_chosen P.Lang_en
  ; P.Board_sort_chosen Masc.Board_dispatch.Discussed
  ; P.Candle_chosen P.Dotted
  ; P.Help_hint_retired
  ]

let test_every_change_reads_back_as_written () =
  List.iter
    (fun written ->
       check (result change string) (P.change_kind written) (Ok written)
         (P.change_of_yojson (P.change_to_yojson written)))
    every_change

let test_a_change_outside_the_shape_is_refused () =
  let refused label text =
    match parse text with
    | Ok parsed -> failf "%s was taken as %s" label (Yojson.Safe.to_string (P.change_to_yojson parsed))
    | Error _ -> ()
  in
  refused "a non-object" {|["theme"]|};
  refused "no kind" {|{"theme":"ayu-dark"}|};
  refused "an unknown kind" {|{"change":"font","font":"mono"}|};
  refused "a kind that is not a string" {|{"change":1}|};
  refused "a missing value" {|{"change":"theme"}|};
  refused "a field of another kind" {|{"change":"theme","device":"mic"}|};
  refused "an extra field" {|{"change":"candle","candle":"dotted","theme":"x"}|};
  refused "a repeated field" {|{"change":"candle","candle":"dotted","candle":"painted"}|};
  refused "a value on a kind without one" {|{"change":"help_hint_retired","value":true}|};
  refused "a blank theme" {|{"change":"theme","theme":"  "}|};
  refused "a theme with blanks around it" {|{"change":"theme","theme":" ayu-dark"}|};
  refused "an unknown language" {|{"change":"language","language":"fr"}|};
  refused "an unknown sort" {|{"change":"board_sort","sort":"oldest"}|};
  refused "an unknown candle" {|{"change":"candle","candle":"neon"}|};
  refused "a keeper name with a slash" {|{"change":"chat_visited","keeper":"a/b"}|};
  refused "a null language" {|{"change":"language","language":null}|}

let doc_of text =
  match Toml.parse_toml text with
  | Ok doc -> doc
  | Error detail -> failf "edited runtime.toml does not parse: %s" detail

let stored key text = Toml.toml_string_opt (doc_of text) (P.Key.doc_path key)

let test_each_change_writes_its_key () =
  let original = "# reader's note\n[runtime]\ndefault = \"x.y\"\n" in
  let edited = P.edit (P.Theme_chosen (Some "ayu-dark")) original in
  check (option string) "theme" (Some "ayu-dark") (stored P.Key.Theme edited);
  check bool "the comment stays" true
    (List.mem "# reader's note" (String.split_on_char '\n' edited));
  check (option string) "other tables stay" (Some "x.y")
    (Toml.toml_string_opt (doc_of edited) "runtime.default");
  check (option string) "no theme goes back to none" None
    (stored P.Key.Theme (P.edit (P.Theme_chosen None) edited));
  check (option string) "language" (Some "en")
    (stored P.Key.Language (P.edit (P.Language_chosen P.Lang_en) original));
  check (option string) "board sort" (Some "discussed")
    (stored P.Key.Board_sort (P.edit (P.Board_sort_chosen Masc.Board_dispatch.Discussed) original));
  check (option string) "candle" (Some "dotted")
    (stored P.Key.Candle (P.edit (P.Candle_chosen P.Dotted) original));
  check (option bool) "the help hint is a bare boolean" (Some true)
    (Toml.toml_bool_opt (doc_of (P.edit P.Help_hint_retired original))
       (P.Key.doc_path P.Key.Help_hint_shown))

(* The server skips a commit whose text did not move; these are the picks a
   reader repeats. *)
let test_a_repeated_pick_leaves_the_text_as_it_is () =
  let once change text = P.edit change text in
  List.iter
    (fun change ->
       let first = once change "[runtime]\ndefault = \"x.y\"\n" in
       check string (P.change_kind change) first (once change first))
    [ P.Chat_visited (keeper "analyst")
    ; P.Theme_chosen (Some "ayu-dark")
    ; P.Help_hint_retired
    ]

let test_a_chat_visit_moves_the_opening_target_only_on_last () =
  let visit text = P.edit (P.Chat_visited (keeper "analyst")) text in
  let on_last = visit "[tui]\nopening = \"last\"\nopening_keeper = \"scout\"\n" in
  check (option string) "last chat" (Some "analyst") (stored P.Key.Last_chat_keeper on_last);
  check (option string) "opening target follows on last" (Some "analyst")
    (stored P.Key.Opening_keeper on_last);
  let on_keeper = visit "[tui]\nopening = \"keeper\"\nopening_keeper = \"scout\"\n" in
  check (option string) "last chat" (Some "analyst") (stored P.Key.Last_chat_keeper on_keeper);
  check (option string) "a fixed opening keeps its target" (Some "scout")
    (stored P.Key.Opening_keeper on_keeper);
  check (option string) "an overview opening gets no target" None
    (stored P.Key.Opening_keeper (visit ""))

let () =
  run "tui_preference"
    [ ( "wire"
      , [ test_case "every change reads back as written" `Quick
            test_every_change_reads_back_as_written
        ; test_case "a change outside the shape is refused" `Quick
            test_a_change_outside_the_shape_is_refused
        ] )
    ; ( "edit"
      , [ test_case "each change writes its key" `Quick test_each_change_writes_its_key
        ; test_case "a repeated pick leaves the text as it is" `Quick
            test_a_repeated_pick_leaves_the_text_as_it_is
        ; test_case "a chat visit moves the opening target only on last" `Quick
            test_a_chat_visit_moves_the_opening_target_only_on_last
        ] )
    ]
