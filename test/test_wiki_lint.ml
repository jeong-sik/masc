(* Wiki_graph, Wiki_sources and Wiki_lint over small fixed wikis, and the
   order-independence the RFC asks of the graph
   (RFC-wiki-lint-and-page-contracts §11.1 items 2 and 6). *)

open Alcotest
module G = Masc.Wiki_graph
module Link = Masc.Wiki_link
module Lint = Masc.Wiki_lint
module Sources = Masc.Wiki_sources

let readable ~page body =
  G.Readable { page; links = Link.extract body; sources = Sources.of_body body }
;;

let describe findings =
  List.map
    (fun finding ->
       match (finding : Lint.finding) with
       | Lint.Broken_link { page; line; target } ->
         Printf.sprintf "broken_link %s:%d %s" page line target
       | Lint.Unsupported_link { page; line; form; target } ->
         Printf.sprintf "unsupported_link %s:%d %s %s" page line form target
       | Lint.Orphan { page } -> "orphan " ^ page
       | Lint.Orphan_unconfirmed { page } -> "orphan_unconfirmed " ^ page
       | Lint.Missing_sources { page } -> "missing_sources " ^ page
       | Lint.Hearsay_only { page } -> "hearsay_only " ^ page
       | Lint.Unreadable_page { file; reason } -> Printf.sprintf "unreadable_page %s (%s)" file reason)
    findings
;;

let sourced = "\n## Sources\n- repo:jeong-sik/masc@0000000000000000000000000000000000000000:lib/a.ml\n"

let test_sources_section () =
  let count body = Sources.of_body body in
  check bool "no section" true (count "text only\n" = { Sources.references = 0; hearsay = 0 });
  check bool "four reference kinds" true
    (count
       "## Sources\n- repo:a\n- board:b\n- artifact:c\n- url:https://x (read 2026-10-13)\n"
     = { Sources.references = 4; hearsay = 0 });
  check bool "said is hearsay" true
    (count "## Sources\n- said:someone@2026-10-13 — \"x\"\n"
     = { Sources.references = 0; hearsay = 1 });
  check bool "a line without a known prefix does not count" true
    (count "## Sources\n- some prose\n- repo:a\n" = { Sources.references = 1; hearsay = 0 });
  check bool "the section ends at the next heading" true
    (count "## Sources\n- repo:a\n## Other\n- repo:b\n" = { Sources.references = 1; hearsay = 0 });
  check bool "a fenced example does not count" true
    (count "## Sources\n```\n- repo:a\n```\n- board:b\n" = { Sources.references = 1; hearsay = 0 });
  check bool "another heading is not the section" true
    (count "### Sources\n- repo:a\n" = { Sources.references = 0; hearsay = 0 })
;;

let fixed_wiki () =
  [ readable ~page:"alpha" ("See [beta](beta.md) and [gone](gone.md).\n" ^ sourced)
  ; readable ~page:"beta" ("Back to [alpha](alpha.md). Also [x](beta.md#top).\n" ^ sourced)
  ; readable ~page:"lonely" "No links in, and no sources.\n"
  ; G.Unreadable { file = "broken.md"; reason = "no frontmatter" }
  ]
;;

let test_fixed_wiki_findings () =
  let findings = Lint.run (G.of_nodes (fixed_wiki ())) in
  check (list string) "findings"
    [ "broken_link alpha:1 gone.md"
    ; "unsupported_link beta:1 anchor beta.md#top"
    ; "unreadable_page broken.md (no frontmatter)"
    ; "missing_sources lonely"
    ; "orphan_unconfirmed lonely"
    ]
    (describe findings)
;;

let test_orphan_is_confirmed_without_unreadable_pages () =
  let nodes = List.filter (function G.Unreadable _ -> false | G.Readable _ -> true) (fixed_wiki ()) in
  let findings = Lint.run (G.of_nodes nodes) in
  check (list string) "findings"
    [ "broken_link alpha:1 gone.md"
    ; "unsupported_link beta:1 anchor beta.md#top"
    ; "missing_sources lonely"
    ; "orphan lonely"
    ]
    (describe findings);
  check (list (pair string int)) "counts"
    [ "broken_link", 1
    ; "unsupported_link", 1
    ; "orphan", 1
    ; "orphan_unconfirmed", 0
    ; "missing_sources", 1
    ; "hearsay_only", 0
    ; "unreadable_page", 0
    ]
    (Lint.counts findings)
;;

let test_clean_wiki_has_no_findings () =
  let nodes =
    [ readable ~page:"alpha" ("Links to [beta](beta.md) and [the log](log.md) and [out](https://example.org).\n" ^ sourced)
    ; readable ~page:"beta" ("Links to [alpha](alpha.md).\n" ^ sourced)
    ]
  in
  check (list string) "no findings" [] (describe (Lint.run (G.of_nodes nodes)));
  check bool "all counts zero" true
    (List.for_all (fun (_, n) -> n = 0) (Lint.counts (Lint.run (G.of_nodes nodes))))
;;

let test_links_to_an_unreadable_page_are_not_broken () =
  let nodes =
    [ readable ~page:"alpha" ("See [other](other.md).\n" ^ sourced)
    ; G.Unreadable { file = "other.md"; reason = "no frontmatter" }
    ]
  in
  check (list string) "findings"
    [ "orphan_unconfirmed alpha"; "unreadable_page other.md (no frontmatter)" ]
    (describe (Lint.run (G.of_nodes nodes)))
;;

let test_self_link_and_index_do_not_count () =
  let nodes =
    [ readable ~page:"alpha" ("I link to [myself](alpha.md) and the [index](index.md).\n" ^ sourced) ]
  in
  check (list string) "alpha is an orphan" [ "orphan alpha" ] (describe (Lint.run (G.of_nodes nodes)))
;;

let test_hearsay_only () =
  let nodes =
    [ readable ~page:"alpha" "A claim, see [beta](beta.md).\n\n## Sources\n- said:someone@2026-10-13 — \"it is so\"\n"
    ; readable ~page:"beta" ("[a](alpha.md)\n" ^ sourced)
    ]
  in
  check (list string) "findings" [ "hearsay_only alpha" ] (describe (Lint.run (G.of_nodes nodes)))
;;

(* Every rotation and the reverse give the same findings. *)
let test_node_order_does_not_change_the_findings () =
  let nodes = fixed_wiki () in
  let expected = describe (Lint.run (G.of_nodes nodes)) in
  let rotate n list =
    let length = List.length list in
    let n = n mod length in
    List.filteri (fun i _ -> i >= n) list @ List.filteri (fun i _ -> i < n) list
  in
  List.iteri
    (fun n _ ->
       check (list string)
         (Printf.sprintf "rotation %d" n)
         expected
         (describe (Lint.run (G.of_nodes (rotate n nodes)))))
    nodes;
  check (list string) "reversed" expected (describe (Lint.run (G.of_nodes (List.rev nodes))))
;;

let test_same_graph_same_output () =
  let first = describe (Lint.run (G.of_nodes (fixed_wiki ()))) in
  let second = describe (Lint.run (G.of_nodes (fixed_wiki ()))) in
  check (list string) "twice" first second
;;

let () =
  run
    "wiki_lint"
    [ ( "sources", [ test_case "the Sources section" `Quick test_sources_section ] )
    ; ( "lint"
      , [ test_case "fixed wiki" `Quick test_fixed_wiki_findings
        ; test_case "orphan confirmed without unreadable pages" `Quick
            test_orphan_is_confirmed_without_unreadable_pages
        ; test_case "clean wiki" `Quick test_clean_wiki_has_no_findings
        ; test_case "unreadable link target is not broken" `Quick
            test_links_to_an_unreadable_page_are_not_broken
        ; test_case "self link and index do not count" `Quick
            test_self_link_and_index_do_not_count
        ; test_case "hearsay only" `Quick test_hearsay_only
        ; test_case "node order does not matter" `Quick
            test_node_order_does_not_change_the_findings
        ; test_case "same graph, same output" `Quick test_same_graph_same_output
        ] )
    ]
;;
