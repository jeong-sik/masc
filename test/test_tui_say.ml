(* Decisions only (RFC tui-one-screen-grammar section 10): which language a
   text renders in, and the order joined texts keep. The strings are markers,
   not screen words. *)

module Say = Masc_tui_say

let ko_marker = "K"
let en_marker = "E"
let received = "R"
let marked = Say.both ~ko:ko_marker ~en:en_marker

let render_picks_the_language () =
  Alcotest.(check string) "ko" ko_marker (Say.render Say.Ko marked);
  Alcotest.(check string) "en" en_marker (Say.render Say.En marked)

let per_language_runs_the_chosen_branch () =
  let calls = ref [] in
  let text =
    Say.per_language (fun language ->
        calls := language :: !calls;
        match language with
        | Say.Ko -> ko_marker
        | Say.En -> en_marker)
  in
  Alcotest.(check string) "en" en_marker (Say.render Say.En text);
  Alcotest.(check bool) "only the drawn language ran" true (!calls = [ Say.En ])

let as_received_is_the_same_in_both () =
  let text = Say.as_received received in
  Alcotest.(check string) "ko" received (Say.render Say.Ko text);
  Alcotest.(check string) "en" received (Say.render Say.En text)

let joining_keeps_order_and_language () =
  let sep = Say.both ~ko:"|" ~en:"/" in
  let text = Say.concat ~sep [ marked; Say.as_received received; Say.(empty ++ marked) ] in
  Alcotest.(check string) "ko" "K|R|K" (Say.render Say.Ko text);
  Alcotest.(check string) "en" "E/R/E" (Say.render Say.En text)

let ko_flag_bridge_follows_the_language () =
  let text = Say.of_ko_flag (fun ~ko -> if ko then ko_marker else en_marker) in
  Alcotest.(check string) "ko" ko_marker (Say.render Say.Ko text);
  Alcotest.(check string) "en" en_marker (Say.render Say.En text)

let map_changes_each_language () =
  let text = Say.map String.lowercase_ascii marked in
  Alcotest.(check string) "ko" "k" (Say.render Say.Ko text);
  Alcotest.(check string) "en" "e" (Say.render Say.En text)

let () =
  Alcotest.run "tui_say"
    [ ( "say",
        [ Alcotest.test_case "render picks the language" `Quick render_picks_the_language;
          Alcotest.test_case "per_language runs the chosen branch" `Quick
            per_language_runs_the_chosen_branch;
          Alcotest.test_case "as_received is the same in both" `Quick
            as_received_is_the_same_in_both;
          Alcotest.test_case "joining keeps order and language" `Quick
            joining_keeps_order_and_language;
          Alcotest.test_case "the ko flag bridge follows the language" `Quick
            ko_flag_bridge_follows_the_language;
          Alcotest.test_case "map changes each language" `Quick map_changes_each_language ] ) ]
