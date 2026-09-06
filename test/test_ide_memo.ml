(* The memo grammar, from both sides: what a comment reads as, and that a
   memo a writer composes reads back as itself. *)

open Ide_memo

let memo =
  Alcotest.testable (fun fmt t -> Format.pp_print_string fmt (to_body t)) ( = )

let read label expected comment =
  match of_comment comment with
  | Memo t -> Alcotest.check memo label expected t
  | Malformed why -> Alcotest.failf "%s: malformed: %s" label why
  | Not_a_memo -> Alcotest.failf "%s: not read as a memo" label

let not_a_memo label comment =
  match of_comment comment with
  | Not_a_memo -> ()
  | Memo t -> Alcotest.failf "%s: read a memo: %s" label (to_body t)
  | Malformed why -> Alcotest.failf "%s: read as malformed: %s" label why

let malformed label ~reason comment =
  match of_comment comment with
  | Malformed why -> Alcotest.(check string) label reason why
  | Memo t -> Alcotest.failf "%s: read a memo: %s" label (to_body t)
  | Not_a_memo -> Alcotest.failf "%s: not read as a memo at all" label

let plain author text = { author; kind = Agent_observation.Comment; text }

let test_a_comment_in_each_marker_reads_as_a_memo () =
  read "ocaml block" (plain "alpha" "the lock is held across the await on purpose")
    "(* masc(alpha): the lock is held across the await on purpose *)";
  read "c block" (plain "alpha" "same") "/* masc(alpha): same */";
  read "double slash" (plain "alpha" "same") "// masc(alpha): same";
  read "hash" (plain "alpha" "same") "# masc(alpha): same";
  read "double dash" (plain "alpha" "same") "-- masc(alpha): same";
  read "html block" (plain "alpha" "same") "<!-- masc(alpha): same -->";
  read "surrounding blanks are not part of it" (plain "alpha" "same")
    "   #   masc(alpha):   same   "

let test_a_kind_word_names_the_kind () =
  read "question"
    { author = "alpha"; kind = Agent_observation.Question; text = "why not batch this" }
    "// masc(alpha) question: why not batch this";
  read "decision"
    { author = "alpha"; kind = Agent_observation.Decision; text = "batch later" }
    "// masc(alpha) decision: batch later";
  read "bookmark"
    { author = "ci.bot-2"; kind = Agent_observation.Bookmark; text = "start here" }
    "# masc(ci.bot-2) bookmark: start here";
  read "the plain kind may be spelled out" (plain "alpha" "same")
    "// masc(alpha) comment: same";
  read "the text keeps its own colons" (plain "a" "see: this, and: that")
    "// masc(a): see: this, and: that"

let test_other_comments_are_left_alone () =
  not_a_memo "a todo" "// TODO: later";
  not_a_memo "the word inside prose" "(* masc is the tool that reads this *)";
  not_a_memo "a block comment that goes on" "(* masc(alpha): text";
  not_a_memo "a marker nobody here writes" "; masc(alpha): text";
  not_a_memo "code, not a comment" "let masc(alpha) = 1"

let test_a_memo_that_stops_short_says_where () =
  malformed "no author" ~reason:"no author between masc( and )" "// masc(): x";
  malformed "a space in the author" ~reason:"the author is not closed by )"
    "// masc(al pha): x";
  malformed "no colon" ~reason:"no : after the author" "// masc(alpha) x";
  malformed "a kind nobody knows" ~reason:"unknown kind verdict"
    "// masc(alpha) verdict: x";
  malformed "no text" ~reason:"the memo has no text" "// masc(alpha):   "

let test_a_made_memo_reads_back_as_itself () =
  List.iter
    (fun kind ->
      match make ~author:"alpha" ~kind ~text:"  the text  " with
      | Error why -> Alcotest.failf "make refused %s" why
      | Ok t ->
        Alcotest.(check string) "trimmed" "the text" t.text;
        read (Agent_observation.annotation_kind_to_string kind) t ("// " ^ to_body t);
        read "inside a block" t ("(* " ^ to_body t ^ " *)"))
    Agent_observation.all_annotation_kinds;
  Alcotest.(check string) "the plain comment carries no word"
    "masc(alpha): x" (to_body (plain "alpha" "x"));
  Alcotest.(check string) "the kind is the word"
    "masc(alpha) question: x"
    (to_body { author = "alpha"; kind = Agent_observation.Question; text = "x" });
  Alcotest.(check string) "a line marker leads the body"
    "// masc(alpha): x"
    (to_line (Line "//") (plain "alpha" "x"));
  Alcotest.(check string) "a block marker encloses the body"
    "(* masc(alpha): x *)"
    (to_line (Block { opens = "(*"; closes = "*)" }) (plain "alpha" "x"));
  List.iter
    (fun markers ->
      let t = plain "alpha" "every known marker reads back" in
      read "known marker round trip" t (to_line markers t))
    known_markers

let test_make_refuses_what_of_comment_could_not_read () =
  let refused label ~author ~text =
    match make ~author ~kind:Agent_observation.Comment ~text with
    | Ok t -> Alcotest.failf "%s: made %s" label (to_body t)
    | Error _ -> ()
  in
  refused "author with a space" ~author:"al pha" ~text:"x";
  refused "author with a paren" ~author:"a)" ~text:"x";
  refused "empty author" ~author:"" ~text:"x";
  refused "empty text" ~author:"a" ~text:"   ";
  refused "two lines" ~author:"a" ~text:"one\ntwo"

let () =
  Alcotest.run "ide_memo"
    [ ( "reading"
      , [ Alcotest.test_case "a comment in each marker reads as a memo" `Quick
            test_a_comment_in_each_marker_reads_as_a_memo
        ; Alcotest.test_case "a kind word names the kind" `Quick
            test_a_kind_word_names_the_kind
        ; Alcotest.test_case "other comments are left alone" `Quick
            test_other_comments_are_left_alone
        ; Alcotest.test_case "a memo that stops short says where" `Quick
            test_a_memo_that_stops_short_says_where
        ] )
    ; ( "writing"
      , [ Alcotest.test_case "a made memo reads back as itself" `Quick
            test_a_made_memo_reads_back_as_itself
        ; Alcotest.test_case "make refuses what of_comment could not read" `Quick
            test_make_refuses_what_of_comment_could_not_read
        ] )
    ]
