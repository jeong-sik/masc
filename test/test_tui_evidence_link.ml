(* Links are parsed into a closed variant; the tests state what becomes a link
   and what does not. *)

module Decode = Masc.Tui_decode
module Link = Masc_tui_evidence_link

let link_testable =
  let pp formatter link = Format.pp_print_string formatter (Link.text link) in
  Alcotest.testable pp ( = )

let note text = Decode.Ev_note text

let artifact content =
  Decode.Ev_artifact
    { ev_reference = "artifact:out.txt"; ev_content = content; ev_bytes = String.length content
    ; ev_truncated = false }

let source ~reference content =
  Decode.Ev_collaboration { ev_reference = reference; ev_content = content; ev_sha256 = "x" }

let web url = Link.Web_url url

let test_a_note_yields_the_urls_it_names () =
  Alcotest.(check (list link_testable)) "in order, without repeats"
    [ web "https://example.com/a"; web "http://example.com/b" ]
    (Link.of_item
       (note "see https://example.com/a and http://example.com/b, then https://example.com/a again"))

let test_sentence_punctuation_is_not_part_of_the_address () =
  Alcotest.(check (list link_testable)) "full stop, comma, question mark"
    [ web "https://x.example/z"; web "https://y.example/q" ]
    (Link.of_item (note "see https://x.example/z. Or https://y.example/q?"));
  Alcotest.(check (list link_testable)) "a query string inside the address is kept"
    [ web "https://x.example/z?a=1&b=2" ]
    (Link.of_item (note "https://x.example/z?a=1&b=2"))

let test_only_http_addresses_with_a_host_are_links () =
  List.iter
    (fun text -> Alcotest.(check (list link_testable)) text [] (Link.of_item (note text)))
    [ "javascript:alert(1)"
    ; "file:///etc/passwd"
    ; "ftp://example.com/x"
    ; "http://"
    ; "https://."
    ; "no address here"
    ]

let test_a_control_sequence_ends_the_address () =
  Alcotest.(check (list link_testable)) "an escape is not part of a URL"
    [ web "https://x.example/a" ]
    (Link.of_item (note "https://x.example/a\x1b[2Jrest"))

let test_text_that_follows_an_address_without_a_space_is_not_part_of_it () =
  (* Korean particles attach to the word before them without a space, and an
     address is ASCII. *)
  List.iter
    (fun (label, text, expected) ->
      Alcotest.(check (list link_testable)) label [ web expected ] (Link.of_item (note text)))
    [ "a Korean particle", "설계는 https://docs.example/d를 참고", "https://docs.example/d"
    ; "a full-width comma", "https://docs.example/d，그리고", "https://docs.example/d"
    ; "an ellipsis", "https://docs.example/a\xe2\x80\xa6", "https://docs.example/a"
    ; "a Korean sentence end", "https://docs.example/d입니다.", "https://docs.example/d"
    ]

let test_parentheses_around_and_inside_an_address () =
  Alcotest.(check (list link_testable)) "a pair inside the address is part of it"
    [ web "https://en.wikipedia.org/wiki/Foo_(bar)" ]
    (Link.of_item (note "(https://en.wikipedia.org/wiki/Foo_(bar))"));
  Alcotest.(check (list link_testable)) "a parenthesis that closes the sentence's is not"
    [ web "https://x.example/a" ]
    (Link.of_item (note "(see https://x.example/a)"));
  Alcotest.(check (list link_testable)) "a closing one with nothing to close ends it"
    [ web "https://x.example/a" ]
    (Link.of_item (note "https://x.example/a) and more"))

let test_an_address_is_shown_as_it_is_written () =
  (* A user-info part is the address's own text; nothing is shortened to its
     host, so the reader sees what the author wrote. *)
  Alcotest.(check (list string)) "the whole address"
    [ "https://trusted.example@evil.example/x" ]
    (List.map Link.text (Link.of_item (note "https://trusted.example@evil.example/x")))

let test_a_submitted_source_links_to_its_masc_object () =
  Alcotest.(check (list link_testable)) "board post"
    [ Link.Masc_reference { kind = Masc_tui_link.Board_post; id = "post-1" } ]
    (Link.of_item (source ~reference:"board:post-1" "{}"));
  Alcotest.(check (list link_testable)) "fusion run"
    [ Link.Masc_reference { kind = Masc_tui_link.Fusion_run; id = "run-9" } ]
    (Link.of_item (source ~reference:"fusion:run-9" "{}"));
  Alcotest.(check (list link_testable)) "Task state source"
    [ Link.Masc_reference { kind = Masc_tui_link.Task; id = "task-42" } ]
    (Link.of_item (source ~reference:"task:task-42" "{}"));
  Alcotest.(check string) "printed as the shared reference"
    (Masc_tui_link.reference Masc_tui_link.Board_post "post-1")
    (Link.text (Link.Masc_reference { kind = Masc_tui_link.Board_post; id = "post-1" }))

(* The source's text is JSON. A URL before a line break must not carry the two
   characters of the JSON escape with it. *)
let test_urls_are_read_from_the_text_inside_a_source () =
  let content =
    Yojson.Safe.to_string
      (`Assoc [ "body", `String "design at https://docs.example/d\nsecond line"
              ; "comments", `List [ `String "ref https://ci.example/run/3" ] ])
  in
  Alcotest.(check (list link_testable)) "the source object first, then its URLs"
    [ Link.Masc_reference { kind = Masc_tui_link.Board_post; id = "p" }
    ; web "https://docs.example/d"
    ; web "https://ci.example/run/3"
    ]
    (Link.of_item (source ~reference:"board:p" content))

let test_an_artifacts_own_path_is_not_a_link () =
  Alcotest.(check (list link_testable)) "only URLs in its text"
    [ web "https://example.com/report" ]
    (Link.of_item (artifact "report at https://example.com/report"));
  Alcotest.(check (list link_testable)) "no URL, no link" [] (Link.of_item (artifact "plain"))

let test_items_without_text_carry_no_links () =
  Alcotest.(check (list link_testable)) "unreadable artifact" []
    (Link.of_item
       (Decode.Ev_artifact_unreadable
          { ev_u_reference = Some "artifact:https://x.example"; ev_u_reason = "missing" }));
  Alcotest.(check (list link_testable)) "binary artifact" []
    (Link.of_item
       (Decode.Ev_binary
          { ev_b_reference = "artifact:https://x.example/a.png"; ev_b_bytes = 1
          ; ev_b_sha256 = "x"; ev_b_format = "png"
          ; ev_b_preview = Decode.Preview_withheld Decode.Withheld_not_image_format }))

let () =
  Alcotest.run "Tui evidence link"
    [ ( "web urls"
      , [ Alcotest.test_case "a note yields the urls it names" `Quick
            test_a_note_yields_the_urls_it_names
        ; Alcotest.test_case "sentence punctuation is not the address" `Quick
            test_sentence_punctuation_is_not_part_of_the_address
        ; Alcotest.test_case "only http addresses with a host" `Quick
            test_only_http_addresses_with_a_host_are_links
        ; Alcotest.test_case "a control sequence ends the address" `Quick
            test_a_control_sequence_ends_the_address
        ; Alcotest.test_case "text attached to an address is not part of it" `Quick
            test_text_that_follows_an_address_without_a_space_is_not_part_of_it
        ; Alcotest.test_case "parentheses around and inside an address" `Quick
            test_parentheses_around_and_inside_an_address
        ; Alcotest.test_case "an address is shown as it is written" `Quick
            test_an_address_is_shown_as_it_is_written
        ] )
    ; ( "items"
      , [ Alcotest.test_case "a source links to its object" `Quick
            test_a_submitted_source_links_to_its_masc_object
        ; Alcotest.test_case "urls come from the text inside a source" `Quick
            test_urls_are_read_from_the_text_inside_a_source
        ; Alcotest.test_case "an artifact's path is not a link" `Quick
            test_an_artifacts_own_path_is_not_a_link
        ; Alcotest.test_case "items without text carry no links" `Quick
            test_items_without_text_carry_no_links
        ] )
    ]
