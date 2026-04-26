open Alcotest
module Lib = Masc_mcp

let test_extract_html_preview_fields () =
  let html =
    {|
      <html>
        <head>
          <title>Fallback Title</title>
          <meta property="og:title" content="OG Title">
          <meta property="og:description" content="OG description here">
          <meta property="og:site_name" content="Example Site">
          <meta property="og:image" content="/cover.png">
          <link rel="canonical" href="/entry">
          <link rel="icon" href="/favicon.ico">
        </head>
      </html>
    |}
  in
  let extracted =
    Lib.Server_dashboard_http_link_preview.extract_html_preview_fields
      ~url:"https://example.com/blog/post"
      html
  in
  check (option string) "title" (Some "OG Title") extracted.title;
  check (option string) "description" (Some "OG description here") extracted.description;
  check (option string) "site_name" (Some "Example Site") extracted.site_name;
  check
    (option string)
    "image_url"
    (Some "https://example.com/cover.png")
    extracted.image_url;
  check
    (option string)
    "canonical_url"
    (Some "https://example.com/entry")
    extracted.canonical_url;
  check
    (option string)
    "favicon_url"
    (Some "https://example.com/favicon.ico")
    extracted.favicon_url
;;

let test_image_url_detection () =
  check
    bool
    "png is image"
    true
    (Lib.Server_dashboard_http_link_preview.infer_image_url
       "https://example.com/demo.png");
  check
    bool
    "html is not image"
    false
    (Lib.Server_dashboard_http_link_preview.infer_image_url
       "https://example.com/page.html")
;;

let test_normalize_request_url_rejects_non_http () =
  match
    Lib.Server_dashboard_http_link_preview.normalize_request_url
      "file:///tmp/example.html"
  with
  | Error _ -> ()
  | Ok value -> failf "expected non-http URL to be rejected, got %s" value
;;

let () =
  Alcotest.run
    "dashboard_link_preview"
    [ ( "preview"
      , [ test_case "extract html preview fields" `Quick test_extract_html_preview_fields
        ; test_case "image url detection" `Quick test_image_url_detection
        ; test_case
            "normalize rejects non-http"
            `Quick
            test_normalize_request_url_rejects_non_http
        ] )
    ]
;;
