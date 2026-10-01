(* What a dashboard read sends and what answers it, through
   [Masc_tui_kept_reads.read] alone: the test plays the server in [send]. *)

let address = "http://127.0.0.1:8935/api/v1/dashboard/goals"
let other_address = "http://127.0.0.1:8935/api/v1/dashboard/briefing"
let ok = 200
let found = 302
let not_modified = 304
let unavailable = 503

let respond ?(headers = []) ?(body = "") status =
  Ok { Masc_tui_kept_reads.status; headers; body }

let tagged tag body = respond ~headers:[ ("ETag", tag) ] ~body ok

let decode_body { Masc_tui_kept_reads.status; body; _ } =
  if status = ok then Ok body else Error (Printf.sprintf "HTTP %d" status)

let decode_must_not_run _ = Alcotest.fail "the body was decoded for an unchanged answer"

(* One read: the request headers [send] was given, and what answered it. *)
let read ?(address = address) ?(decode = decode_body) reads answer =
  let request = ref [] in
  let result =
    Masc_tui_kept_reads.read reads ~address ~decode ~send:(fun headers ->
        request := headers;
        answer headers)
  in
  (!request, result)

let sent_tag request = List.assoc_opt "If-None-Match" request

(* The tag the next read of [address] sends, answered by a refusal that the
   test then forgets. Refusing drops what was kept, so it is the last read. *)
let next_tag ?(address = address) reads =
  let request, _ = read ~address reads (fun _ -> respond unavailable) in
  sent_tag request

let answer_t = Alcotest.(result string string)

let test_a_tagged_answer_is_offered_and_a_304_reuses_it () =
  let reads = Masc_tui_kept_reads.create () in
  let request, answer = read reads (fun _ -> tagged {|W/"a1"|} "goals, first body") in
  Alcotest.(check (option string)) "the first read sends no tag" None (sent_tag request);
  match answer with
  | Error detail -> Alcotest.failf "the first read was refused: %s" detail
  | Ok first -> (
      Alcotest.(check string) "the first read answers with the body" "goals, first body"
        first;
      let request, answer =
        read reads ~decode:decode_must_not_run (fun _ -> respond not_modified)
      in
      Alcotest.(check (option string)) "the next read sends the tag" (Some {|W/"a1"|})
        (sent_tag request);
      match answer with
      | Ok value ->
          Alcotest.(check bool) "a 304 answers with the kept value" true (value == first)
      | Error detail -> Alcotest.failf "a 304 was refused: %s" detail)

let test_a_changed_answer_replaces_the_kept_one () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let _, answer = read reads (fun _ -> tagged {|"b2"|} "second") in
  Alcotest.check answer_t "a 200 answers with its own body" (Ok "second") answer;
  let request, answer =
    read reads ~decode:decode_must_not_run (fun _ -> respond not_modified)
  in
  Alcotest.(check (option string)) "its tag goes out next" (Some {|"b2"|}) (sent_tag request);
  Alcotest.check answer_t "and a 304 answers with the newer value" (Ok "second") answer

let test_an_untagged_or_failed_answer_drops_what_was_kept () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let _, answer = read reads (fun _ -> respond ~body:"untagged" ok) in
  Alcotest.check answer_t "an answer without a tag is used" (Ok "untagged") answer;
  Alcotest.(check (option string)) "and nothing is offered next" None (next_tag reads);
  ignore (read reads (fun _ -> tagged {|"c3"|} "third"));
  (* Kept in the generation before, so the refusal has to drop it there. *)
  Masc_tui_kept_reads.start_generation reads;
  let _, answer = read reads (fun _ -> respond ~headers:[ ("ETag", {|"c3"|}) ] unavailable) in
  Alcotest.check answer_t "a refused read is refused" (Error "HTTP 503") answer;
  let request, _ = read reads (fun _ -> tagged {|"d4"|} "fourth") in
  Alcotest.(check (option string)) "and drops what was kept" None (sent_tag request)

let test_a_304_to_a_read_without_a_tag_is_decoded () =
  let reads = Masc_tui_kept_reads.create () in
  let _, answer = read reads (fun _ -> respond not_modified) in
  Alcotest.check answer_t "the status is decoded like any other" (Error "HTTP 304") answer

let test_a_redirect_to_a_tagged_read_is_decoded () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let request, answer = read reads (fun _ -> respond found) in
  Alcotest.(check (option string)) "the read sent the tag" (Some {|"a1"|}) (sent_tag request);
  Alcotest.check answer_t "only a 304 reuses the kept value" (Error "HTTP 302") answer

let test_a_transport_error_leaves_the_kept_answer () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let _, answer = read reads (fun _ -> Error "connection refused") in
  Alcotest.check answer_t "the error answers the read" (Error "connection refused") answer;
  Alcotest.(check (option string)) "and the tag still goes out" (Some {|"a1"|}) (next_tag reads)

let test_addresses_are_kept_apart () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "goals"));
  Alcotest.(check (option string)) "another address sends no tag" None
    (next_tag ~address:other_address reads);
  Alcotest.(check (option string)) "its own address still does" (Some {|"a1"|})
    (next_tag reads)

let test_an_answer_lasts_two_generations_without_a_read () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  Masc_tui_kept_reads.start_generation reads;
  let request, _ = read reads (fun _ -> respond not_modified) in
  Alcotest.(check (option string)) "a read in the next generation still finds it"
    (Some {|"a1"|}) (sent_tag request);
  Masc_tui_kept_reads.start_generation reads;
  Masc_tui_kept_reads.start_generation reads;
  Alcotest.(check (option string)) "two generations without a read drop it" None
    (next_tag reads)

(* A pass can start while a read is out. The 304 that answers it confirms the
   kept answer, so the answer is kept into the generation it arrived in. *)
let test_a_304_after_a_new_generation_keeps_the_answer () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let _, answer =
    read reads ~decode:decode_must_not_run (fun _ ->
        Masc_tui_kept_reads.start_generation reads;
        respond not_modified)
  in
  Alcotest.check answer_t "the 304 answers with the kept value" (Ok "first") answer;
  Masc_tui_kept_reads.start_generation reads;
  Alcotest.(check (option string)) "the next pass still sends the tag" (Some {|"a1"|})
    (next_tag reads)

(* Two reads of one address overlap: the later one finishes first with a
   changed answer, then the earlier one gets its 304. *)
let test_a_late_304_does_not_undo_a_newer_answer () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> tagged {|"a1"|} "first"));
  let _, answer =
    read reads ~decode:decode_must_not_run (fun _ ->
        ignore (read reads (fun _ -> tagged {|"b2"|} "second"));
        respond not_modified)
  in
  Alcotest.check answer_t "the earlier read gets the value its tag named" (Ok "first") answer;
  Alcotest.(check (option string)) "and the newer tag goes out next" (Some {|"b2"|})
    (next_tag reads)

let test_the_tag_header_name_is_read_in_any_case () =
  let reads = Masc_tui_kept_reads.create () in
  ignore (read reads (fun _ -> respond ~headers:[ ("etag", {|"lower"|}) ] ~body:"v" ok));
  Alcotest.(check (option string)) "an etag header in lower case is kept" (Some {|"lower"|})
    (next_tag reads)

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
          Alcotest.test_case "a redirect to a tagged read is decoded" `Quick
            test_a_redirect_to_a_tagged_read_is_decoded;
          Alcotest.test_case "a transport error leaves the kept answer" `Quick
            test_a_transport_error_leaves_the_kept_answer;
          Alcotest.test_case "addresses are kept apart" `Quick test_addresses_are_kept_apart;
          Alcotest.test_case "the tag header name is read in any case" `Quick
            test_the_tag_header_name_is_read_in_any_case;
        ] );
      ( "generations",
        [
          Alcotest.test_case "an answer lasts two generations without a read" `Quick
            test_an_answer_lasts_two_generations_without_a_read;
          Alcotest.test_case "a 304 after a new generation keeps the answer" `Quick
            test_a_304_after_a_new_generation_keeps_the_answer;
          Alcotest.test_case "a late 304 does not undo a newer answer" `Quick
            test_a_late_304_does_not_undo_a_newer_answer;
        ] );
    ]
