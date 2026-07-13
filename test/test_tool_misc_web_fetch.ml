open Alcotest

let contains_substring text needle =
  let len_text = String.length text in
  let len_needle = String.length needle in
  if len_needle = 0 then true
  else if len_needle > len_text then false
  else
    let rec loop idx =
      if idx > len_text - len_needle then false
      else if String.equal (String.sub text idx len_needle) needle then true
      else loop (idx + 1)
    in
    loop 0

let handle ?(extract_mode = "markdown") ?(max_chars = 5_000) url =
  Eio_main.run @@ fun _env ->
  Masc.Tool_misc_web_fetch.handle ~tool_name:"masc_web_fetch"
    ~start_time:(Unix.gettimeofday ())
    (`Assoc
       [
         ("url", `String url);
         ("extractMode", `String extract_mode);
         ("maxChars", `Int max_chars);
       ])

let success_json result =
  if not (Tool_result.is_success result) then
    fail ("unexpected failure: " ^ Tool_result.message result);
  Yojson.Safe.from_string (Tool_result.message result)

let test_html_metadata_and_article_extraction () =
  let html =
    {|
<!doctype html>
<html>
  <head>
    <title>Fetch Title &amp; Proof</title>
    <meta property="og:description" content="Fetch description &amp; detail">
  </head>
  <body>
    <nav>drop me</nav>
    <article>
      <h1>Primary Article</h1>
      <p>Readable <b>content</b> &amp; links <a href="https://example.com/ref">ref</a>.</p>
    </article>
  </body>
</html>|}
  in
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
      check string "requested url" "https://example.com/start" url;
      Ok
        { Masc.Tool_misc_web_fetch.http_status = Some 200
        ; final_url = "https://example.com/final"
        ; redirect_count = 1
        ; content_type = Some "text/html; charset=utf-8"
        ; downloaded_bytes = Some (String.length html)
        ; body = html
        })
    (fun () ->
      let json = success_json (handle "https://example.com/start") in
      let open Yojson.Safe.Util in
      check string "final url" "https://example.com/final"
        (json |> member "final_url" |> to_string);
      check int "redirect count" 1 (json |> member "redirect_count" |> to_int);
      check string "content kind" "html" (json |> member "content_kind" |> to_string);
      check string "source" "article"
        (json |> member "extraction_source" |> to_string);
      check string "title" "Fetch Title & Proof" (json |> member "title" |> to_string);
      check string "description" "Fetch description & detail"
        (json |> member "description" |> to_string);
      check string "content type" "text/html; charset=utf-8"
        (json |> member "content_type" |> to_string);
      check int "downloaded bytes" (String.length html)
        (json |> member "downloaded_bytes" |> to_int);
      let text = json |> member "text" |> to_string in
      check bool "heading rendered" true (contains_substring text "# Primary Article");
      check bool "link rendered" true
        (contains_substring text "[ref](https://example.com/ref)");
      check bool "nav dropped" false (contains_substring text "drop me"))

let test_plain_text_preserves_angle_brackets () =
  let body = "Keep <literal> tokens\nand second line." in
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
      Ok
        { Masc.Tool_misc_web_fetch.http_status = Some 200
        ; final_url = "https://example.com/plain.txt"
        ; redirect_count = 0
        ; content_type = Some "text/plain"
        ; downloaded_bytes = Some (String.length body)
        ; body
        })
    (fun () ->
      let json = success_json (handle "https://example.com/plain.txt") in
      let open Yojson.Safe.Util in
      check string "content kind" "text" (json |> member "content_kind" |> to_string);
      check string "source" "raw_text"
        (json |> member "extraction_source" |> to_string);
      let text = json |> member "text" |> to_string in
      check bool "literal brackets preserved" true
        (contains_substring text "<literal>"))

let test_invalid_redirect_is_workflow_rejection () =
  Masc.Tool_misc_web_fetch.with_http_fetch_for_test
    (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
      Error
        (Masc.Tool_misc_web_fetch.Invalid_redirect
           "redirect target must be a valid http or https URL"))
    (fun () ->
      let result = handle "https://example.com/redirects-local" in
      check bool "failed" false (Tool_result.is_success result);
      check
        (option string)
        "failure class"
        (Some "workflow_rejection")
        (Tool_result.failure_class result
        |> Option.map Tool_result.tool_failure_class_to_string);
      check bool "message" true
        (contains_substring (Tool_result.message result) "invalid redirect"))

let () =
  run "tool_misc_web_fetch"
    [
      ( "fetch",
        [
          test_case "html metadata and article extraction" `Quick
            test_html_metadata_and_article_extraction;
          test_case "plain text preserves angle brackets" `Quick
            test_plain_text_preserves_angle_brackets;
          test_case "invalid redirect class" `Quick
            test_invalid_redirect_is_workflow_rejection;
        ] );
    ]
