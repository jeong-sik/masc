(* Wiki_graph, Wiki_sources, Wiki_log and Wiki_lint over small fixed wikis, and
   the order-independence the RFC asks of the graph
   (RFC-wiki-lint-and-page-contracts §11.1 items 2 and 6, §4.5 and §7 for the
   log parser and the revision check). *)

open Alcotest
module G = Masc.Wiki_graph
module Journal = Masc.Wiki_journal
module Link = Masc.Wiki_link
module Log = struct
  include Masc.Wiki_log

  let parse = parse ~minute_time:Masc.Wiki_log_clock.local_minute
end
module Report = Masc.Wiki_lint_report
module Lint = Masc.Wiki_lint
module Sources = Masc.Wiki_sources

let readable ?(revision = 1) ~page body =
  G.Readable
    { page; links = Link.extract body; sources = Sources.of_body body; revision }
;;

let no_log = Log.empty

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
       | Lint.Revision_log_gap { page; log_revision; page_revision } ->
         Printf.sprintf
           "revision_log_gap %s log r%d page r%d"
           page
           log_revision
           page_revision
       | Lint.Revision_log_hole { page; missing } ->
         Printf.sprintf "revision_log_hole %s r%d" page missing
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
  let findings = Lint.run (G.of_nodes (fixed_wiki ())) ~log:no_log in
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
  let findings = Lint.run (G.of_nodes nodes) ~log:no_log in
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
    ; "revision_log_gap", 0
    ; "revision_log_hole", 0
    ]
    (Lint.counts findings)
;;

let test_clean_wiki_has_no_findings () =
  let nodes =
    [ readable ~page:"alpha"
        ("Links to [beta](beta.md) and [the log](log.md) and [out](https://example.org).\n"
         ^ sourced)
    ; readable ~page:"beta" ("Links to [alpha](alpha.md).\n" ^ sourced)
    ]
  in
  check (list string) "no findings" [] (describe (Lint.run (G.of_nodes nodes) ~log:no_log));
  check bool "all counts zero" true
    (List.for_all (fun (_, n) -> n = 0) (Lint.counts (Lint.run (G.of_nodes nodes) ~log:no_log)))
;;

let test_links_to_an_unreadable_page_are_not_broken () =
  let nodes =
    [ readable ~page:"alpha" ("See [other](other.md).\n" ^ sourced)
    ; G.Unreadable { file = "other.md"; reason = "no frontmatter" }
    ]
  in
  check (list string) "findings"
    [ "orphan_unconfirmed alpha"; "unreadable_page other.md (no frontmatter)" ]
    (describe (Lint.run (G.of_nodes nodes) ~log:no_log))
;;

let test_self_link_and_index_do_not_count () =
  let nodes =
    [ readable ~page:"alpha" ("I link to [myself](alpha.md) and the [index](index.md).\n" ^ sourced) ]
  in
  check (list string) "alpha is an orphan" [ "orphan alpha" ] (describe (Lint.run (G.of_nodes nodes) ~log:no_log))
;;

let test_hearsay_only () =
  let nodes =
    [ readable ~page:"alpha"
        "A claim, see [beta](beta.md).\n\n## Sources\n- said:someone@2026-10-13 — \"it is so\"\n"
    ; readable ~page:"beta" ("[a](alpha.md)\n" ^ sourced)
    ]
  in
  check (list string) "findings" [ "hearsay_only alpha" ] (describe (Lint.run (G.of_nodes nodes) ~log:no_log))
;;

(* Every rotation and the reverse give the same findings. *)
let test_node_order_does_not_change_the_findings () =
  let nodes = fixed_wiki () in
  let expected = describe (Lint.run (G.of_nodes nodes) ~log:no_log) in
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
         (describe (Lint.run (G.of_nodes (rotate n nodes)) ~log:no_log)))
    nodes;
  check (list string) "reversed" expected (describe (Lint.run (G.of_nodes (List.rev nodes)) ~log:no_log))
;;

let test_same_graph_same_output () =
  let first = describe (Lint.run (G.of_nodes (fixed_wiki ())) ~log:no_log) in
  let second = describe (Lint.run (G.of_nodes (fixed_wiki ())) ~log:no_log) in
  check (list string) "twice" first second
;;

(* --- log.md read back (RFC §7) ------------------------------------------- *)

let journal_line = "## [2026-10-13 20:00] create r1 | alpha | someone | a note\n"

let test_log_reads_the_three_fields () =
  let parsed = Log.parse journal_line in
  check int "one line" 1 (List.length parsed.Log.lines);
  check int "nothing unknown" 0 parsed.Log.unknown_action;
  check int "nothing unreadable" 0 parsed.Log.unreadable_line;
  match parsed.Log.lines with
  | [ line ] ->
    check string "action" "create" line.Log.action;
    check int "revision" 1 line.Log.revision;
    check string "page" "alpha" line.Log.page
  | _ -> fail "expected exactly one line"
;;

(* The two words the parser knows are the two words the journal writes. The
   words live in two modules now, and this is what keeps them from drifting:
   the lines the journal renders for [Created] and [Updated] read back as
   exactly the action words, in the order of the list. *)
let test_log_reads_the_lines_the_journal_writes () =
  let time : Unix.tm =
    { tm_sec = 0
    ; tm_min = 0
    ; tm_hour = 20
    ; tm_mday = 13
    ; tm_mon = 9
    ; tm_year = 126
    ; tm_wday = 0
    ; tm_yday = 0
    ; tm_isdst = false
    }
  in
  let rendered =
    [ Journal.log_line
        ~time
        ~action:Journal.Created
        ~revision:1
        ~page:"alpha"
        ~author:"someone"
        ~note:"a"
    ; Journal.log_line
        ~time
        ~action:Journal.Updated
        ~revision:2
        ~page:"alpha"
        ~author:"someone"
        ~note:"b"
    ]
  in
  let parsed = Log.parse (String.concat "\n" rendered ^ "\n") in
  check int "nothing to count" 0 (parsed.Log.unknown_action + parsed.Log.unreadable_line);
  check (list string) "the actions are the known ones" Log.known_actions
    (List.map (fun line -> line.Log.action) parsed.Log.lines);
  check (list string) "pages" [ "alpha"; "alpha" ]
    (List.map (fun line -> line.Log.page) parsed.Log.lines);
  check (list int) "revisions" [ 1; 2 ]
    (List.map (fun line -> line.Log.revision) parsed.Log.lines);
  check (list (float 0.)) "the stamp reads back as the minute it was written in"
    [ fst (Unix.mktime time); fst (Unix.mktime time) ]
    (List.map (fun line -> line.Log.written_at) parsed.Log.lines)
;;

let test_log_counts_an_unknown_action_and_reads_the_rest () =
  let parsed =
    Log.parse
      (journal_line
       ^ "## [2026-10-13 20:01] publish r2 | beta | someone | shipped\n"
       ^ "## [2026-10-13 20:02] update r2 | alpha | someone | again\n")
  in
  check int "two readable lines" 2 (List.length parsed.Log.lines);
  check int "one unknown action" 1 parsed.Log.unknown_action;
  check int "nothing unreadable" 0 parsed.Log.unreadable_line;
  check (list string) "the lines around it read"
    [ "alpha"; "alpha" ]
    (List.map (fun line -> line.Log.page) parsed.Log.lines)
;;

let test_log_counts_a_line_it_cannot_read () =
  let parsed = Log.parse ("# Log\n\n" ^ journal_line) in
  check int "one readable line" 1 (List.length parsed.Log.lines);
  check int "two unreadable lines" 2 parsed.Log.unreadable_line;
  check int "nothing unknown" 0 parsed.Log.unknown_action
;;

(* The writer stamps a real minute. A stamp that names no minute would move
   into the next field if it were read, so the line is not read at all. *)
let test_log_counts_a_stamp_that_names_no_minute () =
  let line stamp = "## [" ^ stamp ^ "] create r1 | alpha | someone | a note\n" in
  let parsed =
    Log.parse
      (String.concat
         ""
         (List.map line [ "2026-02-30 10:00"; "2026-13-01 10:00"; "2026-10-13 24:00"; "yesterday" ]))
  in
  check int "no line reads" 0 (List.length parsed.Log.lines);
  check int "each is unreadable" 4 parsed.Log.unreadable_line
;;

(* The writer appends in place, so a read can catch a line half written. The
   piece after the last newline is not a line and is not counted either. *)
let test_log_does_not_count_the_unfinished_last_piece () =
  let parsed = Log.parse (journal_line ^ "## [2026-10-13 20:03] update r2 | beta | some") in
  check int "one line" 1 (List.length parsed.Log.lines);
  check int "the fragment is not an unreadable line" 0 parsed.Log.unreadable_line;
  check int "nothing unknown" 0 parsed.Log.unknown_action
;;

let test_log_empty_content_and_no_final_newline () =
  check bool "empty is empty" true (Log.parse "" = Log.empty);
  check int "a lone unfinished line is not a line" 0
    (List.length (Log.parse "## [2026-10-13 20:00] create r1 | alpha | x").Log.lines)
;;

(* --- the log run ahead of the page (RFC §4.5) ---------------------------- *)

let test_revision_log_gap_is_one_finding_per_page () =
  let nodes =
    [ readable ~page:"alpha" ~revision:3 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ~revision:5 ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  (* A page's lines run r1, r2, ... with no skips, so a realistic log is
     contiguous. alpha is four lines deep against a page at r3; that is one
     gap, not four. beta is at the revision its log records. *)
  let log =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
       ^ "## [2026-10-13 20:02] update r3 | alpha | someone | c\n"
       ^ "## [2026-10-13 20:03] update r4 | alpha | someone | d\n"
       ^ "## [2026-10-13 20:04] create r1 | beta | someone | e\n"
       ^ "## [2026-10-13 20:05] update r2 | beta | someone | f\n"
       ^ "## [2026-10-13 20:06] update r3 | beta | someone | g\n"
       ^ "## [2026-10-13 20:07] update r4 | beta | someone | h\n"
       ^ "## [2026-10-13 20:08] update r5 | beta | someone | i\n")
  in
  check (list string) "one finding for the page the log ran ahead of"
    [ "revision_log_gap alpha log r4 page r3" ]
    (describe (Lint.run (G.of_nodes nodes) ~log));
  check (list (pair string int)) "counts" [ "revision_log_gap", 1 ]
    (List.filter (fun (kind, _) -> kind = "revision_log_gap") (Lint.counts (Lint.run (G.of_nodes nodes) ~log)))
;;

let test_revision_log_gap_is_silent_when_the_log_matches () =
  let nodes =
    [ readable ~page:"alpha" ~revision:2 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let matching =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n")
  in
  let ahead = Log.parse (journal_line) in
  check (list string) "the log matches the page" [] (describe (Lint.run (G.of_nodes nodes) ~log:matching));
  check (list string) "the page ahead of the log is not a finding" []
    (describe (Lint.run (G.of_nodes nodes) ~log:ahead))
;;

let test_revision_log_gap_ignores_a_page_that_is_not_there () =
  let nodes =
    [ readable ~page:"alpha" ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let log = Log.parse (journal_line ^ "## [2026-10-13 20:01] update r9 | gone | someone | c\n") in
  check (list string) "a log line for an absent page is not a gap"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log))
;;

(* --- a line that reached the page and never reached the log (§4.5) ------ *)

let test_revision_log_hole_finds_the_skipped_line () =
  let nodes =
    [ readable ~page:"alpha" ~revision:4 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  (* alpha's lines are r1, r2, r4: r3 was written to the page and lost from the
     log. This is what an append_log that failed leaves. The page reached r4,
     so there is no gap: only the hole. *)
  let log =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
       ^ "## [2026-10-13 20:02] update r4 | alpha | someone | d\n")
  in
  check (list string) "the skipped revision is named"
    [ "revision_log_hole alpha r3" ]
    (describe (Lint.run (G.of_nodes nodes) ~log))
;;

let test_revision_log_hole_is_silent_on_a_contiguous_column () =
  let nodes = [ readable ~page:"alpha" ~revision:3 ("[beta](beta.md)\n" ^ sourced)
              ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
              ] in
  let contiguous =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
       ^ "## [2026-10-13 20:02] update r3 | alpha | someone | c\n")
  in
  (* A page ahead of its log leaves the top of the column empty, not a hole. *)
  let page_ahead = Log.parse (journal_line) in
  check (list string) "no hole in a contiguous column"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log:contiguous));
  check (list string) "a page ahead of the log is not a hole"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log:page_ahead))
;;

let test_revision_log_hole_ignores_a_page_that_is_not_there () =
  let nodes = [ readable ~page:"alpha" ("[beta](beta.md)\n" ^ sourced)
              ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
              ] in
  let log = Log.parse (journal_line ^ "## [2026-10-13 20:01] update r5 | gone | someone | c\n") in
  check (list string) "a hole in an absent page's column is not a finding"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log))
;;

(* A line the parser could not read might have carried an r<N> for this page,
   in a place we cannot read, so the column is not one we can call complete. *)
let test_revision_log_hole_is_silent_when_a_line_was_dropped () =
  let nodes =
    [ readable ~page:"alpha" ~revision:4 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let with_unreadable =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n\
       ## [2026-10-13 20:01] update r2 | alpha | someone | b\n\
       ## [2026-10-13 20:02] upd\n\
       ## [2026-10-13 20:03] update r4 | alpha | someone | d\n")
  in
  let with_unknown_action =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n\
       ## [2026-10-13 20:01] update r2 | alpha | someone | b\n\
       ## [2026-10-13 20:02] publish r3 | alpha | someone | c\n\
       ## [2026-10-13 20:03] update r4 | alpha | someone | d\n")
  in
  check (list string) "a torn line hides the column"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log:with_unreadable));
  check (list string) "an unknown action word hides the column"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log:with_unknown_action))
;;

(* A page whose log starts at r3 (no create line) must not be reported as
   hole r1 forever. The column starts where the log's own lowest line starts. *)
let test_revision_log_hole_does_not_start_at_r1 () =
  let nodes =
    [ readable ~page:"alpha" ~revision:4 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let starts_at_three =
    Log.parse
      ("## [2026-10-13 20:00] update r3 | alpha | someone | c\n\
       ## [2026-10-13 20:01] update r4 | alpha | someone | d\n")
  in
  check (list string) "no hole when the column starts above r1"
    []
    (describe (Lint.run (G.of_nodes nodes) ~log:starts_at_three))
;;

(* --- the report as the tool hands it back (RFC §4.2) -------------------- *)

let member key json = Yojson.Safe.Util.member key json

let render_with nodes log =
  let request : Report.request = { page = None; kind = None; limit = None; cursor = None } in
  match
    Report.render
      ~pages_total:(List.length nodes)
      ~pages_unreadable:0
      ~log
      ~findings:(Lint.run (G.of_nodes nodes) ~log)
      request
  with
  | Ok json -> json
  | Error problem -> fail ("render refused: " ^ Report.problem_to_string problem)
;;

let test_report_carries_the_log_counts_and_the_gap () =
  let nodes =
    [ readable ~page:"alpha" ~revision:1 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let log =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
       ^ "## [2026-10-13 20:02] update r3 | alpha | someone | c\n"
       ^ "## [2026-10-13 20:03] publish r3 | beta | someone | d\n")
  in
  let json = render_with nodes log in
  check int "log_unknown_action" 1 Yojson.Safe.Util.(to_int (member "log_unknown_action" json));
  check int "log_unreadable_line" 0 Yojson.Safe.Util.(to_int (member "log_unreadable_line" json));
  check int "counts.revision_log_gap" 1
    Yojson.Safe.Util.(to_int (member "revision_log_gap" (member "counts" json)));
  check int "counts.revision_log_hole" 0
    Yojson.Safe.Util.(to_int (member "revision_log_hole" (member "counts" json)));
  let gap =
    Yojson.Safe.Util.(
      to_list (member "findings" json)
      |> List.find (fun f -> to_string (member "kind" f) = "revision_log_gap"))
  in
  check int "the gap carries log_revision" 3 Yojson.Safe.Util.(to_int (member "log_revision" gap));
  check int "the gap carries page_revision" 1 Yojson.Safe.Util.(to_int (member "page_revision" gap));
  check string "the gap names the page" "alpha" Yojson.Safe.Util.(to_string (member "page" gap))
;;

let test_report_carries_the_hole () =
  let nodes =
    [ readable ~page:"alpha" ~revision:4 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let log =
    Log.parse
      ("## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
       ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
       ^ "## [2026-10-13 20:02] update r4 | alpha | someone | d\n")
  in
  let json = render_with nodes log in
  check int "counts.revision_log_hole" 1
    Yojson.Safe.Util.(to_int (member "revision_log_hole" (member "counts" json)));
  let hole =
    Yojson.Safe.Util.(
      to_list (member "findings" json)
      |> List.find (fun f -> to_string (member "kind" f) = "revision_log_hole"))
  in
  check int "the hole carries missing" 3 Yojson.Safe.Util.(to_int (member "missing" hole));
  check string "the hole names the page" "alpha" Yojson.Safe.Util.(to_string (member "page" hole))
;;

(* The hole rule refuses to report while the log has a dropped line, so the
   response must not leave an empty revision_log_hole list to be read as "no
   holes". The flag names the condition, and a clean log still reports the
   hole. *)
let test_report_says_when_a_dropped_line_turned_the_hole_check_off () =
  let nodes =
    [ readable ~page:"alpha" ~revision:4 ("[beta](beta.md)\n" ^ sourced)
    ; readable ~page:"beta" ("[alpha](alpha.md)\n" ^ sourced)
    ]
  in
  let column =
    "## [2026-10-13 20:00] create r1 | alpha | someone | a\n"
    ^ "## [2026-10-13 20:01] update r2 | alpha | someone | b\n"
    ^ "## [2026-10-13 20:02] update r4 | alpha | someone | d\n"
  in
  (* One unknown action word ("publish") drops that line; the column below the
     highest recorded revision may then be incomplete, so the check is off. *)
  let dropped = render_with nodes (Log.parse (column ^ "## [2026-10-13 20:03] publish r3 | alpha | someone | c\n")) in
  check int "the dropped line is counted" 1
    Yojson.Safe.Util.(to_int (member "log_unknown_action" dropped));
  check bool "the check is reported off" true
    Yojson.Safe.Util.(to_bool (member "revision_log_hole_suppressed" dropped));
  check int "and no hole is reported" 0
    Yojson.Safe.Util.(to_int (member "revision_log_hole" (member "counts" dropped)));
  let clean = render_with nodes (Log.parse column) in
  check bool "a clean log leaves the check on" false
    Yojson.Safe.Util.(to_bool (member "revision_log_hole_suppressed" clean));
  check int "and the r3 hole is reported" 1
    Yojson.Safe.Util.(to_int (member "revision_log_hole" (member "counts" clean)))
;;

let () =
  run
    "wiki_lint"
    [ ( "sources", [ test_case "the Sources section" `Quick test_sources_section ] )
    ; ( "log"
      , [ test_case "the three fields" `Quick test_log_reads_the_three_fields
        ; test_case "the lines the journal writes" `Quick
            test_log_reads_the_lines_the_journal_writes
        ; test_case "an unknown action is counted, the rest read" `Quick
            test_log_counts_an_unknown_action_and_reads_the_rest
        ; test_case "a line that does not read is counted" `Quick
            test_log_counts_a_line_it_cannot_read
        ; test_case "a stamp that names no minute is counted" `Quick
            test_log_counts_a_stamp_that_names_no_minute
        ; test_case "the unfinished last piece is not a line" `Quick
            test_log_does_not_count_the_unfinished_last_piece
        ; test_case "empty log" `Quick test_log_empty_content_and_no_final_newline
        ] )
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
        ; test_case "one gap finding per page" `Quick test_revision_log_gap_is_one_finding_per_page
        ; test_case "no gap when the log matches" `Quick test_revision_log_gap_is_silent_when_the_log_matches
        ; test_case "no gap for a page that is not there" `Quick
            test_revision_log_gap_ignores_a_page_that_is_not_there
        ; test_case "a hole names the skipped line" `Quick
            test_revision_log_hole_finds_the_skipped_line
        ; test_case "no hole on a contiguous column" `Quick
            test_revision_log_hole_is_silent_on_a_contiguous_column
        ; test_case "no hole for a page that is not there" `Quick
            test_revision_log_hole_ignores_a_page_that_is_not_there
        ; test_case "a dropped line hides the column" `Quick
            test_revision_log_hole_is_silent_when_a_line_was_dropped
        ; test_case "the column does not start at r1" `Quick
            test_revision_log_hole_does_not_start_at_r1
        ] )
    ; ( "report"
      , [ test_case "the report carries the log counts and the gap" `Quick
            test_report_carries_the_log_counts_and_the_gap
        ; test_case "the report carries the hole" `Quick test_report_carries_the_hole
        ; test_case "the report says when the check is off" `Quick
            test_report_says_when_a_dropped_line_turned_the_hole_check_off
        ] )
    ]
;;
