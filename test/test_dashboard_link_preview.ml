open Alcotest

module Lib = Masc

let test_extract_html_preview_fields () =
  let html =
    {|
      <html>
        <head>
          <title>Fallback Title</title>
          <meta data-note="1 > 0" content="OG &copy; Title" property="og:title">
          <meta property="og:description" content="OG description here">
          <meta property="og:site_name" content="Example Site">
          <meta property="og:image" content="/cover.png">
          <link rel="canonical" href="/entry">
          <link rel="shortcut&#x9;icon" href="/favicon.ico">
        </head>
      </html>
    |}
  in
  let extracted =
    Server_dashboard_http_link_preview.extract_html_preview_fields
      ~url:"https://example.com/blog/post" html
  in
  check (option string) "title" (Some "OG © Title") extracted.title;
  check (option string) "description" (Some "OG description here")
    extracted.description;
  check (option string) "site_name" (Some "Example Site") extracted.site_name;
  check (option string) "image_url" (Some "https://example.com/cover.png")
    extracted.image_url;
  check (option string) "canonical_url" (Some "https://example.com/entry")
    extracted.canonical_url;
  check (option string) "favicon_url"
    (Some "https://example.com/favicon.ico") extracted.favicon_url

let test_extract_html_preview_fields_multibyte_boundary () =
  (* task-350 / #7690 shape: the byte cap used to cut a multibyte
     character in half. <title> text is RCDATA — the parser passes it
     through raw, so a partial trailing byte surfaces in the extracted
     title. Padding places the 262_144-byte cap on the middle byte of
     the first Korean character in the title text. *)
  let head_ = {|<html><head><title>|} in
  let pad_len = 262_144 - 1 - String.length head_ in
  let pad = String.make pad_len 'x' in
  let html = head_ ^ pad ^ {|한글 제목 테스트</title></head></html>|} in
  check bool "body larger than the byte cap" true
    (String.length html > 262_144);
  let extracted =
    Server_dashboard_http_link_preview.extract_html_preview_fields
      ~url:"https://example.com/blog/post" html
  in
  (* Old code cut the 3-byte 한 at byte 2, leaving a partial sequence;
     utf8_prefix clamps to the boundary and drops the whole character. *)
  match extracted.title with
  | Some value ->
      check bool "title has no partial character" true
        (String_util.is_valid_utf8 value);
      check bool "title is not truncated mid-character" true
        (not (String.contains value '\xEF'))
  | None -> failf "title should survive the cap, got None"

let test_image_url_detection () =
  check bool "png is image" true
    (Server_dashboard_http_link_preview.infer_image_url
       "https://example.com/demo.png");
  check bool "html is not image" false
    (Server_dashboard_http_link_preview.infer_image_url
       "https://example.com/page.html")

let test_normalize_request_url_rejects_non_http () =
  match
    Server_dashboard_http_link_preview.normalize_request_url
      "file:///tmp/example.html"
  with
  | Error _ -> ()
  | Ok value ->
      failf "expected non-http URL to be rejected, got %s" value

let test_extract_html_preview_fields_utf8_truncation () =
  let prefix =
    "<html><head><title>UTF8 Truncation Title</title></head><body>"
  in
  let padding_len = 262_143 - String.length prefix in
  let padding = String.make padding_len 'x' in
  let hangul_suffix = "한글</body></html>" in
  let html = prefix ^ padding ^ hangul_suffix in
  let extracted =
    Server_dashboard_http_link_preview.extract_html_preview_fields
      ~url:"https://example.com/utf8" html
  in
  check (option string) "title" (Some "UTF8 Truncation Title") extracted.title

let () =
  Alcotest.run "dashboard_link_preview"
    [
      ( "preview",
        [
          test_case "extract html preview fields" `Quick
            test_extract_html_preview_fields;
          test_case "extract html preview fields utf8 truncation" `Quick
            test_extract_html_preview_fields_utf8_truncation;
          test_case "image url detection" `Quick test_image_url_detection;
          test_case "multibyte title survives the byte cap" `Quick
            test_extract_html_preview_fields_multibyte_boundary;
          test_case "normalize rejects non-http" `Quick
            test_normalize_request_url_rejects_non_http;
        ] );
    ]
