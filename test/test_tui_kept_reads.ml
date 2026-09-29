(* What a dashboard read sends and what answers it, through
   [Masc_tui_kept_reads] alone: the HTTP exchange is played by the test. *)

let address = "http://127.0.0.1:8935/api/v1/dashboard/goals"
let not_modified = 304
let ok = 200
let unavailable = 503

(* One read: what it sends, then the value that answers it once the server
   answered [status] with [headers]. [decoded] stands for decoding the body. *)
let read reads ~status ~headers ~decoded =
  let sent = Masc_tui_kept_reads.find reads ~address in
  let request = Masc_tui_kept_reads.request_headers sent in
  let answer =
    Masc_tui_kept_reads.settle reads ~address ~sent ~status ~headers ~decode:decoded
  in
  (request, answer)

let sent_tag request = List.assoc_opt "If-None-Match" request

(* The tag the next read would send, without answering it. *)
let next_tag reads =
  sent_tag
    (Masc_tui_kept_reads.request_headers (Masc_tui_kept_reads.find reads ~address))

let decode_must_not_run () = Alcotest.fail "the body was decoded for an unchanged answer"
let answer_t = Alcotest.(result string string)

let test_a_tagged_answer_is_offered_and_a_304_reuses_it () =
  let reads = Masc_tui_kept_reads.create () in
  let first = "goals, first body" in
  let request, answer =
    read reads ~status:ok ~headers:[ ("ETag", {|W/"a1"|}) ] ~decoded:(fun () -> Ok first)
  in
  Alcotest.(check (option string)) "the first read sends no tag" None (sent_tag request);
  Alcotest.check answer_t "the first read answers with the body" (Ok first) answer;
  let request, answer =
    read reads ~status:not_modified ~headers:[] ~decoded:decode_must_not_run
  in
  Alcotest.(check (option string)) "the next read sends the tag" (Some {|W/"a1"|})
    (sent_tag request);
  match answer with
  | Ok value -> Alcotest.(check bool) "a 304 answers with the kept value" true (value == first)
  | Error detail -> Alcotest.failf "a 304 was refused: %s" detail

let test_a_changed_answer_replaces_the_kept_one () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads ~status:ok ~headers:[ ("ETag", {|"a1"|}) ] ~decoded:(fun () -> Ok "first"));
  let _, answer =
    read reads ~status:ok ~headers:[ ("ETag", {|"b2"|}) ] ~decoded:(fun () -> Ok "second")
  in
  Alcotest.check answer_t "a 200 answers with its own body" (Ok "second") answer;
  Alcotest.(check (option string)) "and its tag goes out next" (Some {|"b2"|}) (next_tag reads);
  let _, answer = read reads ~status:not_modified ~headers:[] ~decoded:decode_must_not_run in
  Alcotest.check answer_t "a 304 then answers with the newer value" (Ok "second") answer

let test_an_untagged_or_failed_answer_drops_what_was_kept () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads ~status:ok ~headers:[ ("ETag", {|"a1"|}) ] ~decoded:(fun () -> Ok "first"));
  let _, answer = read reads ~status:ok ~headers:[] ~decoded:(fun () -> Ok "untagged") in
  Alcotest.check answer_t "an answer without a tag is used" (Ok "untagged") answer;
  Alcotest.(check (option string)) "and nothing is offered next" None (next_tag reads);
  ignore (read reads ~status:ok ~headers:[ ("ETag", {|"c3"|}) ] ~decoded:(fun () -> Ok "third"));
  let _, answer =
    read reads ~status:unavailable ~headers:[ ("ETag", {|"c3"|}) ]
      ~decoded:(fun () -> Error "HTTP 503")
  in
  Alcotest.check answer_t "a refused read is refused" (Error "HTTP 503") answer;
  Alcotest.(check (option string)) "and drops what was kept" None (next_tag reads)

let test_a_304_to_a_read_without_a_tag_is_decoded () =
  let reads = Masc_tui_kept_reads.create () in
  let _, answer =
    read reads ~status:not_modified ~headers:[] ~decoded:(fun () -> Error "HTTP 304")
  in
  Alcotest.check answer_t "the status is decoded like any other" (Error "HTTP 304") answer

let test_an_answer_lasts_two_generations_without_a_read () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads ~status:ok ~headers:[ ("ETag", {|"a1"|}) ] ~decoded:(fun () -> Ok "first"));
  Masc_tui_kept_reads.start_generation reads;
  Alcotest.(check (option string)) "a read in the next generation still finds it"
    (Some {|"a1"|}) (next_tag reads);
  Masc_tui_kept_reads.start_generation reads;
  Alcotest.(check (option string)) "finding it kept it one generation more"
    (Some {|"a1"|}) (next_tag reads);
  Masc_tui_kept_reads.start_generation reads;
  Masc_tui_kept_reads.start_generation reads;
  Alcotest.(check (option string)) "two generations without a read drop it" None
    (next_tag reads)

let test_the_tag_header_name_is_read_in_any_case () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads ~status:ok ~headers:[ ("etag", {|"lower"|}) ] ~decoded:(fun () -> Ok "v"));
  Alcotest.(check (option string)) "an etag header in lower case is kept"
    (Some {|"lower"|}) (next_tag reads)

let () =
  Alcotest.run "tui_kept_reads"
    [
      ( "kept dashboard answers",
        [
          Alcotest.test_case "a tagged answer is offered and a 304 reuses it" `Quick
            test_a_tagged_answer_is_offered_and_a_304_reuses_it;
          Alcotest.test_case "a changed answer replaces the kept one" `Quick
            test_a_changed_answer_replaces_the_kept_one;
          Alcotest.test_case "an untagged or failed answer drops what was kept" `Quick
            test_an_untagged_or_failed_answer_drops_what_was_kept;
          Alcotest.test_case "a 304 to a read without a tag is decoded" `Quick
            test_a_304_to_a_read_without_a_tag_is_decoded;
          Alcotest.test_case "an answer lasts two generations without a read" `Quick
            test_an_answer_lasts_two_generations_without_a_read;
          Alcotest.test_case "the tag header name is read in any case" `Quick
            test_the_tag_header_name_is_read_in_any_case;
        ] );
    ]
