(* The wiki lint's modules read and write nothing, and they do not reach into
   the tool or the journal. The source files are the evidence: after the
   comments are removed, none of them names a module or function through
   which a file, a clock, a thread or the tool could be reached
   (RFC-wiki-lint-and-page-contracts §11.1 item 5). *)

open Alcotest

let modules =
  [ "wiki_page_name"
  ; "wiki_page"
  ; "wiki_link"
  ; "wiki_sources"
  ; "wiki_log"
  ; "wiki_graph"
  ; "wiki_lint"
  ; "wiki_lint_report"
  ]
;;

(* What none of them may mention. *)
let forbidden =
  [ "Tool_wiki"
  ; "Wiki_journal"
  ; "Fs_compat"
  ; "File_lock"
  ; "Unix."
  ; "Sys."
  ; "Eio"
  ; "In_channel"
  ; "Out_channel"
  ; "open_in"
  ; "open_out"
  ; "Time_compat"
  ; "Random."
  ]
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* Removes (* … *) comments, nested, and leaves string literals alone. *)
let strip_comments text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let rec code i =
    if i >= length
    then ()
    else if i + 1 < length && text.[i] = '(' && text.[i + 1] = '*'
    then comment (i + 2) 1
    else if text.[i] = '"'
    then (
      Buffer.add_char buffer '"';
      literal (i + 1))
    else (
      Buffer.add_char buffer text.[i];
      code (i + 1))
  and literal i =
    if i >= length
    then ()
    else if text.[i] = '\\' && i + 1 < length
    then (
      Buffer.add_char buffer text.[i];
      Buffer.add_char buffer text.[i + 1];
      literal (i + 2))
    else if text.[i] = '"'
    then (
      Buffer.add_char buffer '"';
      code (i + 1))
    else (
      Buffer.add_char buffer text.[i];
      literal (i + 1))
  and comment i depth =
    if i >= length
    then ()
    else if i + 1 < length && text.[i] = '(' && text.[i + 1] = '*'
    then comment (i + 2) (depth + 1)
    else if i + 1 < length && text.[i] = '*' && text.[i + 1] = ')'
    then if depth = 1 then code (i + 2) else comment (i + 2) (depth - 1)
    else comment (i + 1) depth
  in
  code 0;
  Buffer.contents buffer
;;

let contains ~needle text =
  let needle_length = String.length needle in
  let limit = String.length text - needle_length in
  let rec go i = i <= limit && (String.equal (String.sub text i needle_length) needle || go (i + 1)) in
  go 0
;;

let test_no_module_reaches_a_file_or_the_tool () =
  List.iter
    (fun name ->
       List.iter
         (fun extension ->
            let path = Filename.concat "../lib" (name ^ extension) in
            let code = strip_comments (read_file path) in
            List.iter
              (fun word ->
                 check bool
                   (Printf.sprintf "%s%s does not mention %s" name extension word)
                   false (contains ~needle:word code))
              forbidden)
         [ ".ml"; ".mli" ])
    modules
;;

let test_the_checker_sees_what_it_should () =
  check bool "a comment is not code" false
    (contains ~needle:"Unix." (strip_comments "(* Unix.tm (* nested *) *) let x = 1"));
  check bool "code after a comment is seen" true
    (contains ~needle:"Unix." (strip_comments "(* c *) let t = Unix.time ()"));
  check bool "a string is code text" true
    (contains ~needle:"Unix." (strip_comments "let s = \"(* Unix. *)\""))
;;

let () =
  run
    "wiki_core_purity"
    [ ( "sources"
      , [ test_case "no module reaches a file or the tool" `Quick
            test_no_module_reaches_a_file_or_the_tool
        ; test_case "the checker sees what it should" `Quick
            test_the_checker_sees_what_it_should
        ] )
    ]
;;
