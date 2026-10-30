open Alcotest
module Payload = Masc_tui_image_payload

let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='#19a974'/></svg>"
let encoded_svg = "PHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHdpZHRoPSc0MCcgaGVpZ2h0PScyMCc+PHJlY3Qgd2lkdGg9JzQwJyBoZWlnaHQ9JzIwJyBmaWxsPScjMTlhOTc0Jy8+PC9zdmc+"

let is_svg payload = match Payload.format payload with
  | Svg -> true | General_image -> false

let test_declared_format () =
  let payload = Payload.of_base64 ~mime_type:"IMAGE/SVG+XML; charset=utf-8" encoded_svg in
  check bool "declared SVG selects SVG decoder" true (is_svg payload);
  check string "encoded bytes retained" encoded_svg (Payload.encoded payload);
  check (result string string) "decoded markup" (Ok svg) (Payload.decode payload);
  let general = Payload.of_base64 ~mime_type:"image/png" encoded_svg in
  check bool "payload content does not override declaration" false (is_svg general);
  let invalid = Payload.of_base64 ~mime_type:"image/svg+xml" "%%%%" in
  check bool "invalid base64 is refused before rendering" true
    (Result.is_error (Payload.decode invalid))

let test_data_uri () =
  let source = "data:image/svg+xml;charset=utf-8;base64," ^ encoded_svg in
  let payload = match Payload.of_data_uri source with Ok p -> p | Error e -> fail e in
  check bool "SVG URI selects SVG decoder" true (is_svg payload);
  check string "complete URI retained" source (Payload.encoded payload);
  check (result string string) "URI bytes decoded" (Ok svg) (Payload.decode payload);
  List.iter (fun bad -> check bool "unsupported URI refused" true
    (Result.is_error (Payload.of_data_uri bad)))
    ["data:image/svg+xml;base64";
     "file:///private/image.svg"; "https://example.invalid/image.svg";
     "data:text/html;base64,UE5H"];
  List.iter (fun wire -> check (result string string) "shared binary codec"
    (Ok "PNG") (Payload.decode_wire wire))
    ["UE5H";"data:image/png;base64,UE5H";"data:audio/wav;base64,UE5H"]

let test_percent_data_uri () =
  let uri = "data:IMAGE/SVG+XML;charset=utf-8,%3Csvg%3E%3Ctext%3E%ED%95%9C%EA%B8%80%20+%20%2523%3C/text%3E%3C/svg%3E#selection" in
  let payload = match Payload.of_data_uri uri with Ok p -> p | Error e -> fail e in
  check bool "percent URI keeps declared SVG format" true (is_svg payload);
  check string "original URI including fragment retained" uri (Payload.encoded payload);
  check (result string string) "decode bytes once without form or fragment semantics"
    (Ok "<svg><text>한글 + %23</text></svg>") (Payload.decode payload);
  check (result string string) "percent escapes precede base64 decoding"
    (Ok "<svg/>") (Payload.decode_wire "data:image/svg+xml; BASE64,PHN2Zy8%2b#selection");
  check (result string string) "shared binary codec preserves zero, high byte and plus"
    (Ok "\000\255+") (Payload.decode_wire "data:audio/wav,%00%FF+");
  check bool "invalid escaped base64 is refused" true
    (Result.is_error (Payload.decode_wire "data:image/svg+xml;base64,%25%25%25"))

let test_html_data_uri () =
  List.iter (fun (uri, expected) ->
  let projection = Masc_tui_artifact_html.project
    ("<body><img alt='vector' src='" ^ uri ^ "'></body>") in
  match Masc_tui_artifact_html.images projection with
  | [image] ->
    (match image.source with
     | Embedded_data payload ->
       check bool "HTML uses declared SVG decoder" true (is_svg payload);
       check string "HTML URI retained exactly" uri (Payload.encoded payload);
       check (result string string) "HTML SVG bytes" (Ok expected) (Payload.decode payload)
     | Embedded_svg _ | Unavailable _ -> fail "expected encoded SVG image")
  | [] | _ :: _ -> fail "expected one HTML image")
    ["data:image/svg+xml;charset=utf-8;base64," ^ encoded_svg, svg;
     "data:image/svg+xml,%3Csvg/%3E", "<svg/>"]

let () = run "image payload boundary" ["declared decoding",[
  test_case "raw MIME identity and invalid data" `Quick test_declared_format;
  test_case "data URI and shared codec" `Quick test_data_uri;
  test_case "percent image URI and binary decoding" `Quick test_percent_data_uri;
  test_case "parameterized HTML SVG image" `Quick test_html_data_uri]]
