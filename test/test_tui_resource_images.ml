open Alcotest
module Images = Masc_tui_resource_images
module Mcp = Masc_tui_mcp
module Preview = Masc_tui_image_preview

let text mime value =
  { Mcp.rc_uri = None; rc_mime_type = mime; rc_kind = Mcp.Resource_text value }
let blob mime value =
  { Mcp.rc_uri = Some "/not-a-local-image.png"; rc_mime_type = mime;
    rc_kind = Mcp.Resource_blob {base64=value} }

let payload = function
  | Preview.Output_image {source=Inline_data data;_} -> data
  | Named_path _ | Staged _ | Stored_attachment _
  | Output_image {source=(Inline_svg _ | Inline_mermaid _ | Server_path _ | Remote_uri _);_}
  | Unavailable_image _ | No_image -> fail "expected retained inline bytes"

let test_wire_conservation () =
  let body = Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0"; "id",`String "read";
    "result",`Assoc ["contents",`List [
      `Assoc ["mimeType",`String "text/plain"; "text",`String "caption"];
      `Assoc ["uri",`String "file:///private/not-opened.png"; "mimeType",`String "image/png"; "blob",`String "QUJDRA=="]]]]) in
  match Mcp.resource_contents_of_body ~request_id:"read" body with
  | Error detail -> fail detail
  | Ok parts ->
    match Images.images ~mime_type:None parts with
    | [2,image] ->
      check string "encoded bytes retained" "QUJDRA==" (payload image);
      (match Preview.decode_payload (payload image) with
       | Ok bytes -> check string "original bytes" "ABCD" bytes
       | Error error -> fail error)
    | [] | _ :: _ -> fail "every response image keeps its original part number"

let test_multipart_types () =
  let parts = [text (Some "text/markdown") "![label](/not-followed.png)";
    blob (Some "IMAGE/PNG; charset=binary") "QUJD";
    blob (Some "application/octet-stream") "REVG";
    blob None "R0hJ";
    text (Some "image/svg+xml") "<svg/>";
    blob (Some "text/plain") "SktM"] in
  let images = Images.images ~mime_type:(Some "image/jpeg") parts in
  check (list int) "declared image parts in original order" [2;4;5] (List.map fst images);
  check string "first payload" "QUJD" (payload (snd (List.nth images 0)));
  check string "MIME inheritance" "R0hJ" (payload (snd (List.nth images 1)));
  (match snd (List.nth images 2) with
   | Preview.Output_image {source=Inline_svg source;_} -> check string "SVG source" "<svg/>" source
   | Preview.Named_path _ | Staged _ | Stored_attachment _
   | Output_image {source=(Inline_data _ | Inline_mermaid _ | Server_path _ | Remote_uri _);_}
   | Unavailable_image _ | No_image -> fail "SVG text retains markup")

let test_source_ownership () =
  let parts = [blob (Some "image/png") "QUJD"] in
  let uri = "masc://image" in
  check bool "original retained observation" true (Images.same_reading ~equal:String.equal (Some (uri,parts)) (Some (uri,parts)));
  check bool "new response with equal bytes" false (Images.same_reading ~equal:String.equal (Some (uri,parts)) (Some (uri,List.map Fun.id parts)));
  check bool "different resource" false (Images.same_reading ~equal:String.equal (Some (uri,parts)) (Some ("masc://other",parts)));
  check bool "withdrawn source" false (Images.same_reading ~equal:String.equal (Some (uri,parts)) None);
  check bool "absence never owns" false (Images.same_reading ~equal:String.equal None None)

let test_decode_refusal () =
  match Images.images ~mime_type:None [blob (Some "image/png") "***"] with
  | [_,image] ->
    (match Preview.decode_payload (payload image) with Error _ -> () | Ok _ -> fail "invalid payload decoded")
  | [] | _ :: _ -> fail "decoding belongs to acquisition, not metadata selection"

let test_malformed_parts_refused () =
  let image = `Assoc ["mimeType",`String "image/png"; "blob",`String "QUJD"] in
  let read parts =
    Mcp.resource_contents_of_body ~request_id:"read"
      (Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0"; "id",`String "read";
        "result",`Assoc ["contents",`List parts]])) in
  List.iter (fun malformed ->
    match read [image;malformed;image] with
    | Error _ -> ()
    | Ok _ -> fail "malformed part must not disappear and renumber later images")
    [`Null; `Assoc []; `Assoc ["text",`Int 7];
     `Assoc ["text",`String "caption"; "blob",`String "QUJD"];
     `Assoc ["blob",`String "QUJD"; "blob",`String "REVG"]]

let test_html_embedded_sources () =
  let first = "data:image/png;base64,QUJDRA==" in
  let second = "data:image/svg+xml;base64,PHN2Zy8+" in
  let source = "<html><head><script>fetch('/secret')</script></head><body>"
    ^ "<p><span><img alt='first' src='" ^ first ^ "'></span></p>"
    ^ "<table><tr><td><img src='" ^ second ^ "'></td>"
    ^ "<td><img src='file:///private/not-opened.png'></td></tr></table>"
    ^ "<div hidden><img src='data:image/png;base64,SElEREVO'></div>"
    ^ "<template><img src='data:image/png;base64,VEVNUExBVEU='></template>"
    ^ "</body></html>" in
  let parts = [text (Some "text/html; charset=utf-8") source;
    blob (Some "image/jpeg") "QUJD"] in
  let images = Images.images ~mime_type:None parts in
  check (list int) "embedded candidates keep owning source part" [1;1;1;2]
    (List.map fst images);
  check string "nested image URI remains exact" first (payload (snd (List.nth images 0)));
  check string "table image URI remains exact" second (payload (snd (List.nth images 1)));
  (match snd (List.nth images 2) with
   | Preview.Unavailable_image _ -> ()
   | Named_path _ | Staged _ | Stored_attachment _ | Output_image _ | No_image ->
     fail "HTML file image must not become a local or remote read");
  check string "next original part is retained" "QUJD" (payload (snd (List.nth images 3)));
  match List.hd parts with
  | {Mcp.rc_kind=Resource_text original;_} -> check string "HTML source is unchanged" source original
  | {Mcp.rc_kind=Resource_blob _;_} -> fail "original HTML part changed"

let test_html_unavailable_sources () =
  let source = "<img src='https://example.invalid/picture.png'>"
    ^ "<img src='/api/v1/artifacts/not-followed'>"
    ^ "<img src='javascript:alert(1)'>"
    ^ "<img src='data:text/html;base64,QUJD'>"
    ^ "<img src='data:image/png,not-base64'>" in
  let candidates = Images.images ~mime_type:None [text (Some "text/html") source] in
  check int "unavailable declarations stay selectable" 5 (List.length candidates);
  List.iter (fun (_,preview) -> match preview with
    | Preview.Unavailable_image _ -> ()
    | Named_path _ | Staged _ | Stored_attachment _ | Output_image _ | No_image ->
      fail "HTML image declaration must not grant an external read") candidates

let () = run "resource image sources" ["source decisions", [
  test_case "wire conservation" `Quick test_wire_conservation;
  test_case "malformed parts refused" `Quick test_malformed_parts_refused;
  test_case "multipart declared media" `Quick test_multipart_types;
  test_case "immutable source ownership" `Quick test_source_ownership;
  test_case "payload decode refusal" `Quick test_decode_refusal;
  test_case "inert embedded HTML sources" `Quick test_html_embedded_sources;
  test_case "external HTML declarations remain unavailable" `Quick test_html_unavailable_sources]]
