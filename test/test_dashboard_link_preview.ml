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

let check_addr expected raw =
  match Ipaddr.of_string raw with
  | Error _ -> failf "test input %S did not parse as an IP address" raw
  | Ok ip ->
      Alcotest.(check bool)
        (Printf.sprintf "%s blocked" raw)
        expected
        (Server_dashboard_http_link_preview.ipaddr_is_private_or_reserved ip)

(* The V6 arm matched on the rendered address, and every IPv4-carrying form
   renders starting with "::", so none of its prefixes could see the address
   inside. ::ffff:169.254.169.254 reached the fetcher even though the V4 arm
   rejects 169.254.0.0/16. *)
let test_v4_inside_v6_is_blocked () =
  List.iter (check_addr true)
    [
      "::ffff:127.0.0.1";
      "::ffff:169.254.169.254";
      "::ffff:10.0.0.1";
      "::ffff:192.168.1.1";
      "::ffff:172.16.0.1";
      "::ffff:100.64.0.1";
      "::127.0.0.1";
    ]

let test_native_v6_ranges_stay_blocked () =
  List.iter (check_addr true)
    [ "::1"; "::"; "fe80::1"; "febf::1"; "fc00::1"; "fd00::1"; "ff02::1"; "2001:db8::1" ]

let test_public_addresses_stay_allowed () =
  List.iter (check_addr false)
    [ "8.8.8.8"; "1.1.1.1"; "2001:4860:4860::8888"; "::ffff:8.8.8.8" ]

let () =
  Alcotest.run "dashboard_link_preview"
    [
      ( "preview",
        [
          test_case "extract html preview fields" `Quick
            test_extract_html_preview_fields;
          test_case "image url detection" `Quick test_image_url_detection;
          test_case "normalize rejects non-http" `Quick
            test_normalize_request_url_rejects_non_http;
          test_case "IPv4 inside IPv6 is blocked" `Quick
            test_v4_inside_v6_is_blocked;
          test_case "native v6 ranges stay blocked" `Quick
            test_native_v6_ranges_stay_blocked;
          test_case "public addresses stay allowed" `Quick
            test_public_addresses_stay_allowed;
        ] );
    ]
