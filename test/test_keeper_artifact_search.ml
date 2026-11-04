(** Line search over a stored artifact ([keeper_artifact_read] with [contains]).

    Two things are pinned. The scan gives the same hits for every chunk size,
    budget and match limit, and resuming from [next_offset] never skips or
    repeats a line. The request boundary names the field that was wrong and
    keeps the response under the wire ceiling. *)

module S = Masc.Keeper_artifact_search
module R = Masc.Keeper_artifact_read

(* ---- an in-memory artifact ---------------------------------------------- *)

let reader content ~offset ~max_bytes =
  let total = String.length content in
  if offset >= total
  then Ok ("", total)
  else Ok (String.sub content offset (min max_bytes (total - offset)), total)
;;

let spec ?(ignore_case = false) ?(max_matches = 1000) ?(start = 0) needle : S.spec =
  { needle; ignore_case; max_matches; start }
;;

let scan_exn ?chunk_bytes ?max_line_bytes ?scan_budget_bytes content spec =
  match S.scan ?chunk_bytes ?max_line_bytes ?scan_budget_bytes ~read:(reader content) spec with
  | Ok outcome -> outcome
  | Error (S.Read_failed (_ : string)) -> Alcotest.fail "scan: read failed"
  | Error (S.Offset_past_end _) -> Alcotest.fail "scan: offset past end"
  | Error (S.Short_read _) -> Alcotest.fail "scan: short read"
;;

(* ---- an independent reference ------------------------------------------- *)

let strip_cr line =
  let length = String.length line in
  if length > 0 && line.[length - 1] = '\r' then String.sub line 0 (length - 1) else line
;;

(* Every line with the offset of its first byte; a last line without a
   terminator counts. *)
let reference_lines content =
  let total = String.length content in
  let rec go start acc =
    if start >= total
    then List.rev acc
    else (
      match String.index_from_opt content start '\n' with
      | Some newline ->
        go (newline + 1) ((start, strip_cr (String.sub content start (newline - start))) :: acc)
      | None -> List.rev ((start, strip_cr (String.sub content start (total - start))) :: acc))
  in
  go 0 []
;;

let contains_naive ~ignore_case line needle =
  let fold = if ignore_case then String.lowercase_ascii else Fun.id in
  let line = fold line
  and needle = fold needle in
  let line_length = String.length line
  and needle_length = String.length needle in
  let rec at index =
    index + needle_length <= line_length
    && (String.equal (String.sub line index needle_length) needle || at (index + 1))
  in
  at 0
;;

(* (offset, line_bytes, text) of every matching line, and how many lines were
   too long to search. *)
let reference ?(ignore_case = false) ?(max_line_bytes = 1_048_576) content needle =
  List.fold_left
    (fun (hits, skipped) (offset, line) ->
       if String.length line > max_line_bytes
       then hits, skipped + 1
       else if contains_naive ~ignore_case line needle
       then (offset, String.length line, line) :: hits, skipped
       else hits, skipped)
    ([], 0)
    (reference_lines content)
  |> fun (hits, skipped) -> List.rev hits, skipped
;;

let hit_triples (hits : S.hit list) =
  List.map (fun (hit : S.hit) -> hit.offset, hit.line_bytes, hit.text) hits
;;

let triples = Alcotest.(list (triple int int string))

(* Lines of several shapes, a CRLF now and then, and sometimes no final
   terminator. A fixed generator keeps a failure reproducible by its seed. *)
let generated_content seed =
  let state = ref seed in
  let next bound =
    state := ((!state * 1103515245) + 12345) land 0x3fffffff;
    (!state lsr 8) mod bound
  in
  let pieces =
    [| "alpha"
     ; "needle"
     ; "beta needle gamma"
     ; ""
     ; "é한 needle 한é"
     ; "x"
     ; "NEEDLE upper"
     ; "a longer line without the word but with enough bytes to cross a boundary"
     ; "needleneedle"
    |]
  in
  let buffer = Buffer.create 4096 in
  let lines = 40 + next 40 in
  for line = 1 to lines do
    Buffer.add_string buffer pieces.(next (Array.length pieces));
    let last = line = lines in
    if last && next 2 = 0
    then ()
    else Buffer.add_string buffer (if next 4 = 0 then "\r\n" else "\n")
  done;
  Buffer.contents buffer
;;

(* ---- the scan ------------------------------------------------------------ *)

let chunk_sizes = [ 1; 2; 3; 5; 7; 11; 16; 64; 4096 ]

let test_chunk_size_does_not_change_the_hits () =
  List.iter
    (fun seed ->
       let content = generated_content seed in
       List.iter
         (fun ignore_case ->
            let expected, expected_skipped =
              reference ~ignore_case ~max_line_bytes:30 content "needle"
            in
            List.iter
              (fun chunk_bytes ->
                 let label =
                   Printf.sprintf "seed %d ignore_case %b chunk %d" seed ignore_case chunk_bytes
                 in
                 let outcome =
                   scan_exn ~chunk_bytes ~max_line_bytes:30 content
                     (spec ~ignore_case "needle")
                 in
                 Alcotest.check triples (label ^ " hits") expected (hit_triples outcome.hits);
                 Alcotest.(check int) (label ^ " skipped") expected_skipped outcome.skipped_lines;
                 Alcotest.(check int)
                   (label ^ " ends at the end")
                   (String.length content)
                   outcome.next_offset)
              chunk_sizes)
         [ false; true ])
    [ 1; 2; 3; 4; 5; 6 ]
;;

(* Scan to the end the way a caller does: continue at [next_offset]. *)
let collect_all ?chunk_bytes ?max_line_bytes ?scan_budget_bytes ~max_matches content needle =
  let total = String.length content in
  let rec go start hits skipped scans =
    if scans > 100_000 then Alcotest.fail "the scan does not advance";
    let outcome =
      scan_exn ?chunk_bytes ?max_line_bytes ?scan_budget_bytes content
        (spec ~max_matches ~start needle)
    in
    Alcotest.(check bool)
      "a scan that did not reach the end moves forward"
      true
      (outcome.next_offset > start || outcome.next_offset >= total);
    Alcotest.(check bool)
      "the place to continue is a line start"
      true
      (outcome.next_offset >= total
       || outcome.next_offset = 0
       || content.[outcome.next_offset - 1] = '\n');
    let hits = hits @ outcome.hits
    and skipped = skipped + outcome.skipped_lines in
    if outcome.next_offset >= total then hits, skipped else go outcome.next_offset hits skipped (scans + 1)
  in
  go 0 [] 0 0
;;

let test_resuming_from_next_offset_loses_nothing () =
  List.iter
    (fun seed ->
       let content = generated_content seed in
       let expected, expected_skipped = reference ~max_line_bytes:30 content "needle" in
       List.iter
         (fun (label, chunk_bytes, max_matches, scan_budget_bytes) ->
            let hits, skipped =
              collect_all ~chunk_bytes ~max_line_bytes:30 ~scan_budget_bytes ~max_matches
                content "needle"
            in
            let label = Printf.sprintf "seed %d %s" seed label in
            Alcotest.check triples (label ^ " hits") expected (hit_triples hits);
            Alcotest.(check int) (label ^ " skipped") expected_skipped skipped)
         [ "one hit per scan", 16, 1, 1_000_000
         ; "two hits per scan", 7, 2, 1_000_000
         ; "tiny budget", 16, 1000, 40
         ; "budget of one byte", 3, 1000, 1
         ; "budget and limit", 5, 3, 25
         ])
    [ 1; 2; 3; 4 ]
;;

let test_hit_limit_stops_after_the_last_hit_line () =
  let content = "needle one\nskip\nneedle two\nneedle three\n" in
  let outcome = scan_exn content (spec ~max_matches:2 "needle") in
  Alcotest.check triples "first two hits"
    [ 0, 10, "needle one"; 16, 10, "needle two" ]
    (hit_triples outcome.hits);
  Alcotest.(check int) "continues at the line after the last hit" 27 outcome.next_offset;
  Alcotest.(check int) "total" (String.length content) outcome.total_bytes
;;

let test_ignore_case_folds_ascii_only () =
  let content = "Error: one\nerror: two\nERROR: three\nÉrror: four\n" in
  let case_sensitive = scan_exn content (spec "error") in
  Alcotest.(check int) "case-sensitive" 1 (List.length case_sensitive.hits);
  let folded = scan_exn content (spec ~ignore_case:true "error") in
  Alcotest.(check int) "ASCII letters match in either case" 3 (List.length folded.hits)
;;

let test_line_terminators () =
  let content = "needle a\r\nneedle b\nneedle c" in
  let outcome = scan_exn content (spec "needle") in
  Alcotest.check triples "CR is not line content, the last line needs no terminator"
    [ 0, 8, "needle a"; 10, 8, "needle b"; 19, 8, "needle c" ]
    (hit_triples outcome.hits);
  let empty = scan_exn "" (spec "needle") in
  Alcotest.(check int) "an empty artifact has no hits" 0 (List.length empty.hits);
  Alcotest.(check int) "and is at its end" 0 empty.next_offset
;;

let test_long_lines_are_skipped_and_counted_whatever_the_chunking () =
  let content =
    String.concat "\n"
      [ "needle ok"; "needle " ^ String.make 20 'x'; "needle"; "needle " ^ String.make 11 'y' ^ "\r"; "tail needle" ]
  in
  let expected, expected_skipped = reference ~max_line_bytes:12 content "needle" in
  Alcotest.(check int) "two lines are over the limit" 2 expected_skipped;
  List.iter
    (fun chunk_bytes ->
       let outcome = scan_exn ~chunk_bytes ~max_line_bytes:12 content (spec "needle") in
       let label = Printf.sprintf "chunk %d" chunk_bytes in
       Alcotest.check triples (label ^ " hits") expected (hit_triples outcome.hits);
       Alcotest.(check int) (label ^ " skipped") expected_skipped outcome.skipped_lines)
    chunk_sizes
;;

let test_text_is_cut_at_a_utf8_boundary () =
  let long = "a" ^ String.concat "" (List.init 100 (fun _ -> "한")) in
  let outcome = scan_exn (long ^ "\n") (spec "한") in
  match outcome.hits with
  | [ hit ] ->
    Alcotest.(check int) "line_bytes is the whole line" 301 hit.line_bytes;
    Alcotest.(check bool) "text fits" true (String.length hit.text <= S.line_text_bytes);
    Alcotest.(check int) "text ends on a code point, not inside one" 238 (String.length hit.text);
    Alcotest.(check int) "text is valid UTF-8" (String.length hit.text)
      (S.valid_utf8_prefix_length hit.text)
  | [] | _ :: _ :: _ -> Alcotest.fail "expected exactly one hit"
;;

let test_start_offsets () =
  let content = "abc needle\nxyz needle\n" in
  let middle = scan_exn content (spec ~start:4 "needle") in
  Alcotest.check triples "a start inside a line searches the rest of it as a line"
    [ 4, 6, "needle"; 11, 10, "xyz needle" ]
    (hit_triples middle.hits);
  let at_end = scan_exn content (spec ~start:(String.length content) "needle") in
  Alcotest.(check int) "a start at the end finds nothing" 0 (List.length at_end.hits);
  Alcotest.(check int) "and is at the end" (String.length content) at_end.next_offset;
  match
    S.scan ~read:(reader content) (spec ~start:(String.length content + 1) "needle")
  with
  | Error (S.Offset_past_end { offset; total_bytes }) ->
    Alcotest.(check int) "offset reported" (String.length content + 1) offset;
    Alcotest.(check int) "size reported" (String.length content) total_bytes
  | Ok _ | Error (S.Read_failed (_ : string)) | Error (S.Short_read _) ->
    Alcotest.fail "a start past the end must be refused"
;;

let test_read_failures_are_reported () =
  (match S.scan ~read:(fun ~offset:_ ~max_bytes:_ -> Error "disk") (spec "x") with
   | Error (S.Read_failed "disk") -> ()
   | Ok _ | Error (S.Read_failed (_ : string)) | Error (S.Offset_past_end _) | Error (S.Short_read _)
     -> Alcotest.fail "the read error must come back unchanged");
  let truncated ~offset:_ ~max_bytes =
    if max_bytes = 1 then Ok ("a", 100) else Ok ("", 100)
  in
  match S.scan ~read:truncated (spec "x") with
  | Error (S.Short_read { offset = 0; total_bytes = 100 }) -> ()
  | Ok _ | Error (S.Read_failed (_ : string)) | Error (S.Offset_past_end _) | Error (S.Short_read _)
    -> Alcotest.fail "a read that returns nothing before the end must be an error"
;;

(* ---- the request boundary ------------------------------------------------ *)

let sha = String.make 64 'a'

let operation_exn json =
  match R.For_testing.operation_of_json json with
  | Ok operation -> operation
  | Error invalid -> Alcotest.fail (R.invalid_request_to_string invalid)
;;

let rejection json =
  match R.For_testing.operation_of_json json with
  | Ok _ -> Alcotest.fail "expected a rejection"
  | Error invalid -> R.invalid_request_to_string invalid
;;

let names ~label message needle =
  let message_length = String.length message
  and needle_length = String.length needle in
  let rec at index =
    index + needle_length <= message_length
    && (String.equal (String.sub message index needle_length) needle || at (index + 1))
  in
  Alcotest.(check bool) (Printf.sprintf "%s names %S in %S" label needle message) true (at 0)
;;

let test_requests_without_search_fields_are_page_reads () =
  match operation_exn (`Assoc [ "sha256", `String sha; "offset", `Int 5; "max_bytes", `Int 100 ]) with
  | R.Read_page { sha256; offset = 5; max_bytes = 100 } ->
    Alcotest.(check string) "sha256" sha sha256
  | R.Read_page _ | R.Search_text _ -> Alcotest.fail "expected a page read"
;;

let test_contains_makes_a_search_with_defaults () =
  match operation_exn (`Assoc [ "sha256", `String sha; "contains", `String "error:" ]) with
  | R.Search_text { sha256; offset = 0; needle = "error:"; ignore_case = false; max_matches } ->
    Alcotest.(check string) "sha256" sha sha256;
    Alcotest.(check int) "default match limit" S.default_max_matches max_matches
  | R.Search_text _ | R.Read_page _ -> Alcotest.fail "expected a search with defaults"
;;

let test_search_options_are_read () =
  match
    operation_exn
      (`Assoc
        [ "sha256", `String sha
        ; "contains", `String "x"
        ; "ignore_case", `Bool true
        ; "max_matches", `Int 7
        ; "offset", `Int 123
        ])
  with
  | R.Search_text { offset = 123; needle = "x"; ignore_case = true; max_matches = 7; sha256 = _ } -> ()
  | R.Search_text _ | R.Read_page _ -> Alcotest.fail "expected the options to be read"
;;

let refuses ~label field json = names ~label (rejection json) field

let test_search_requests_are_refused_by_field () =
  let base = [ "sha256", `String sha ] in
  let with_contains extra = `Assoc (base @ (("contains", `String "x") :: extra)) in
  refuses ~label:"max_bytes with contains" "max_bytes" (with_contains [ "max_bytes", `Int 10 ]);
  refuses ~label:"ignore_case alone" "ignore_case" (`Assoc (base @ [ "ignore_case", `Bool true ]));
  refuses ~label:"max_matches alone" "max_matches" (`Assoc (base @ [ "max_matches", `Int 3 ]));
  refuses ~label:"empty contains" "contains" (`Assoc (base @ [ "contains", `String "" ]));
  refuses ~label:"contains of the wrong type" "contains" (`Assoc (base @ [ "contains", `Int 1 ]));
  refuses ~label:"null contains" "contains" (`Assoc (base @ [ "contains", `Null ]));
  refuses ~label:"too long contains" "contains"
    (`Assoc (base @ [ "contains", `String (String.make (S.maximum_needle_bytes + 1) 'x') ]));
  refuses ~label:"ignore_case of the wrong type" "ignore_case"
    (with_contains [ "ignore_case", `String "yes" ]);
  List.iter
    (fun bad ->
       refuses ~label:"max_matches out of range" "max_matches"
         (with_contains [ "max_matches", `Int bad ]))
    [ S.minimum_max_matches - 1; S.maximum_max_matches + 1 ];
  refuses ~label:"negative offset" "offset" (with_contains [ "offset", `Int (-1) ]);
  refuses ~label:"short sha256" "sha256" (`Assoc [ "sha256", `String "abc"; "contains", `String "x" ])
;;

(* ---- the response -------------------------------------------------------- *)

let search_request : R.search =
  { sha256 = sha; offset = 0; needle = "x"; ignore_case = false; max_matches = 100 }
;;

let member name json = Yojson.Safe.Util.member name json

let test_response_stays_under_the_wire_ceiling () =
  let hits =
    List.init 100 (fun index ->
      ({ offset = 1000 * (index + 1)
       ; line_bytes = S.line_text_bytes
       ; text = String.make S.line_text_bytes 'x'
       }
       : S.hit))
  in
  let outcome : S.outcome =
    { hits; next_offset = 123_456; total_bytes = 200_000; skipped_lines = 0 }
  in
  match R.For_testing.search_page search_request outcome with
  | Error message -> Alcotest.fail message
  | Ok json ->
    let size = String.length (Yojson.Safe.to_string json) in
    Alcotest.(check bool) "fits the ceiling" true (size <= R.maximum_max_bytes);
    let kept = member "match_count" json |> Yojson.Safe.Util.to_int in
    Alcotest.(check bool) "some hits were dropped" true (kept > 0 && kept < 100);
    Alcotest.(check int) "the next call starts at the first dropped line"
      (1000 * (kept + 1))
      (member "next_offset" json |> Yojson.Safe.Util.to_int);
    Alcotest.(check bool) "so the scan has not reached the end" false
      (member "eof" json |> Yojson.Safe.Util.to_bool);
    let lines =
      String.split_on_char '\n' (member "content" json |> Yojson.Safe.Util.to_string)
    in
    Alcotest.(check int) "one content line per kept hit" kept (List.length lines)
;;

let test_response_reports_what_the_scan_found () =
  let hit : S.hit = { offset = 7; line_bytes = 300; text = String.make 240 'y' } in
  let outcome : S.outcome =
    { hits = [ hit ]; next_offset = 500; total_bytes = 500; skipped_lines = 2 }
  in
  match R.For_testing.search_page search_request outcome with
  | Error message -> Alcotest.fail message
  | Ok json ->
    Alcotest.(check bool) "ok" true (member "ok" json |> Yojson.Safe.Util.to_bool);
    Alcotest.(check bool) "the scan reached the end" true
      (member "eof" json |> Yojson.Safe.Util.to_bool);
    Alcotest.(check int) "next_offset is the scan's" 500
      (member "next_offset" json |> Yojson.Safe.Util.to_int);
    Alcotest.(check int) "skipped lines are reported" 2
      (member "skipped_lines" json |> Yojson.Safe.Util.to_int);
    let content = member "content" json |> Yojson.Safe.Util.to_string in
    names ~label:"content" content "7\t";
    names ~label:"a cut line says how much was cut" content "(+60 bytes)";
    let none : S.outcome =
      { hits = []; next_offset = 0; total_bytes = 0; skipped_lines = 0 }
    in
    (match R.For_testing.search_page search_request none with
     | Error message -> Alcotest.fail message
     | Ok json ->
       Alcotest.(check bool) "skipped_lines is absent when nothing was skipped" true
         (member "skipped_lines" json = `Null);
       Alcotest.(check int) "no matches" 0 (member "match_count" json |> Yojson.Safe.Util.to_int))
;;

let () =
  Alcotest.run
    "keeper_artifact_search"
    [ ( "scan"
      , [ Alcotest.test_case "chunk size does not change the hits" `Quick
            test_chunk_size_does_not_change_the_hits
        ; Alcotest.test_case "resuming from next_offset loses nothing" `Quick
            test_resuming_from_next_offset_loses_nothing
        ; Alcotest.test_case "the hit limit stops after the last hit line" `Quick
            test_hit_limit_stops_after_the_last_hit_line
        ; Alcotest.test_case "ignore_case folds ASCII only" `Quick
            test_ignore_case_folds_ascii_only
        ; Alcotest.test_case "line terminators" `Quick test_line_terminators
        ; Alcotest.test_case "long lines are skipped and counted whatever the chunking" `Quick
            test_long_lines_are_skipped_and_counted_whatever_the_chunking
        ; Alcotest.test_case "text is cut at a UTF-8 boundary" `Quick
            test_text_is_cut_at_a_utf8_boundary
        ; Alcotest.test_case "start offsets" `Quick test_start_offsets
        ; Alcotest.test_case "read failures are reported" `Quick test_read_failures_are_reported
        ] )
    ; ( "request"
      , [ Alcotest.test_case "no search field is a page read" `Quick
            test_requests_without_search_fields_are_page_reads
        ; Alcotest.test_case "contains makes a search with defaults" `Quick
            test_contains_makes_a_search_with_defaults
        ; Alcotest.test_case "search options are read" `Quick test_search_options_are_read
        ; Alcotest.test_case "bad search requests are refused by field" `Quick
            test_search_requests_are_refused_by_field
        ] )
    ; ( "response"
      , [ Alcotest.test_case "stays under the wire ceiling" `Quick
            test_response_stays_under_the_wire_ceiling
        ; Alcotest.test_case "reports what the scan found" `Quick
            test_response_reports_what_the_scan_found
        ] )
    ]
;;
