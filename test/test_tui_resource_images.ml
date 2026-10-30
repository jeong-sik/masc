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
  | Preview.Output_image {source=Inline_data data;_} -> Masc_tui_image_payload.encoded data
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
      (match Masc_tui_image_payload.decode_wire (payload image) with
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
    (match Masc_tui_image_payload.decode_wire (payload image) with Error _ -> () | Ok _ -> fail "invalid payload decoded")
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
  let third = "data:image/svg+xml,%3Csvg/%3E" in
  let source = "<html><head><script>fetch('/secret')</script></head><body>"
    ^ "<p><span><img alt='first' src='" ^ first ^ "'></span></p>"
    ^ "<table><tr><td><img src='" ^ second ^ "'></td>"
    ^ "<td><img src='" ^ third ^ "'></td>"
    ^ "<td><img src='file:///private/not-opened.png'></td></tr></table>"
    ^ "<div hidden><img src='data:image/png;base64,SElEREVO'></div>"
    ^ "<template><img src='data:image/png;base64,VEVNUExBVEU='></template>"
    ^ "</body></html>" in
  let parts = [text (Some "text/html; charset=utf-8") source;
    blob (Some "image/jpeg") "QUJD"] in
  let images = Images.images ~mime_type:None parts in
  check (list int) "embedded candidates keep owning source part" [1;1;1;1;2]
    (List.map fst images);
  check string "nested image URI remains exact" first (payload (snd (List.nth images 0)));
  check string "table image URI remains exact" second (payload (snd (List.nth images 1)));
  check string "percent SVG URI remains exact" third (payload (snd (List.nth images 2)));
  (match snd (List.nth images 3) with
   | Preview.Unavailable_image _ -> ()
   | Named_path _ | Staged _ | Stored_attachment _ | Output_image _ | No_image ->
     fail "HTML file image must not become a local or remote read");
  check string "next original part is retained" "QUJD" (payload (snd (List.nth images 4)));
  match List.hd parts with
  | {Mcp.rc_kind=Resource_text original;_} -> check string "HTML source is unchanged" source original
  | {Mcp.rc_kind=Resource_blob _;_} -> fail "original HTML part changed"

let test_html_unavailable_sources () =
  let source = "<img src='https://example.invalid/picture.png'>"
    ^ "<img src='/api/v1/artifacts/not-followed'>"
    ^ "<img src='javascript:alert(1)'>"
    ^ "<img src='data:text/html;base64,QUJD'>"
    ^ "<img src='data:image/png;base64'>" in
  let candidates = Images.images ~mime_type:None [text (Some "text/html") source] in
  check int "unavailable declarations stay selectable" 5 (List.length candidates);
  List.iter (fun (_,preview) -> match preview with
    | Preview.Unavailable_image _ -> ()
    | Named_path _ | Staged _ | Stored_attachment _ | Output_image _ | No_image ->
      fail "HTML image declaration must not grant an external read") candidates

let test_retained_svg_format () =
  let reference = match Tool_output.make_artifact_ref
      ~sha256:(String.make 64 'a') ~bytes:4 ~mime:"text/plain" ~preview:"attachment payload" with
    | Ok reference -> reference
    | Error error -> fail (Tool_output.make_error_to_string error) in
  let marker = Tool_output.encode_for_agent_core (Tool_output.Stored reference) in
  match Preview.persisted_attachment ~name:"figure.svg" ~mime:"image/svg+xml" ~data:(Some marker) with
  | Stored_attachment {reference;format;_} ->
    check string "wire blob keeps its encoded-text MIME" "text/plain" reference.mime;
    (match format with
     | Masc_tui_image_payload.Svg -> ()
     | General_image -> fail "original attachment format was replaced by wire MIME")
  | Named_path _ | Staged _ | Output_image _ | Unavailable_image _ | No_image ->
    fail "expected immutable retained attachment"

let test_markdown_diagrams () =
  let first = "flowchart LR\n A[개인 계정] --> B{권한 확인}" in
  let second = "pie title Work\n \"Done\":8\n \"Pending\":2" in
  let source = "# Report\n\n```mermaid\n" ^ first ^ "\n```\n\n"
    ^ "~~~mermaid\n" ^ second ^ "\n~~~\n\n```mermaid\nflowchart TD\n X --> Y" in
  let parts = [text (Some "text/plain") source;
    text None source; blob (Some "image/png") "QUJD";
    text (Some "application/json") source] in
  let candidates = Images.images ~mime_type:(Some "TEXT/MARKDOWN; charset=utf-8") parts in
  check (list int) "only declared Markdown and images participate" [2;2;3]
    (List.map fst candidates);
  let diagrams = List.filter_map (function
    | _, Preview.Output_image {name;source=Inline_mermaid source} -> Some (name,source)
    | _, (Named_path _ | Staged _ | Stored_attachment _
      | Output_image {source=(Inline_data _ | Inline_svg _ | Server_path _ | Remote_uri _);_}
      | Unavailable_image _ | No_image) -> None) candidates in
  check (list (pair string string)) "exact closed sources keep part and occurrence identity"
    ["Mermaid · part 2 · diagram 1", first;
     "Mermaid · part 2 · diagram 2", second] diagrams;
  check string "following image still owns its original part" "QUJD"
    (payload (snd (List.nth candidates 2)));
  List.iter (fun mime ->
    check int "document Markdown aliases share diagram admission" 2
      (List.length (Images.images ~mime_type:None [text (Some mime) source])))
    ["text/markdown"; "text/x-markdown"; "application/markdown"];
  match List.nth parts 1 with
  | {Mcp.rc_kind=Resource_text original;_} ->
      check string "retained report source is unchanged" source original
  | {Mcp.rc_kind=Resource_blob _;_} -> fail "expected retained Markdown"

let test_diagram_preparation_ownership () =
  let module Diagrams = Masc_tui_resource_diagrams in
  let source = "flowchart LR\n A[계정] --> B[확인]" in
  let content = "```mermaid\n" ^ source ^ "\n```" in
  let parts = [text None content] in
  let create contents = Diagrams.create ~mime_type:(Some "text/markdown")
    ~contents ~width:640 ~cell_pixels:(8,16) ~colors:None in
  let cache = create parts in
  let request = Diagrams.request cache in
  check (list string) "render request retains exact source" [source] (Diagrams.sources request);
  check (pair int int) "pending source" (0,1) (Diagrams.progress cache);
  check bool "original response and geometry own preparation" true
    (Diagrams.matches ~mime_type:(Some "text/markdown") ~contents:parts
      ~width:640 ~cell_pixels:(8,16) ~colors:None cache);
  check bool "equal replacement response is a different observation" false
    (Diagrams.matches ~mime_type:(Some "text/markdown") ~contents:(List.map Fun.id parts)
      ~width:640 ~cell_pixels:(8,16) ~colors:None cache);
  let retired = Diagrams.request (create parts) in
  let ignored = Diagrams.settle retired ~source (Error "stale render") cache in
  check bool "another request cannot settle pending work" true (cache == ignored);
  let failed = Diagrams.settle request ~source (Error "renderer unavailable") cache in
  check (option string) "failure stays explicit" (Some "renderer unavailable")
    (Diagrams.failure ~source failed);
  check (pair int int) "failure is terminal preparation" (1,1) (Diagrams.progress failed);
  let duplicate = Diagrams.settle request ~source (Error "duplicate") failed in
  check (option string) "duplicate result cannot replace terminal outcome"
    (Some "renderer unavailable") (Diagrams.failure ~source duplicate);
  let reread = create (List.map Fun.id parts) in
  let rejected = Diagrams.settle (Diagrams.request reread) ~source (Ok "not a PNG") reread in
  check bool "invalid bytes do not become a displayed image" true
    (Option.is_none (Diagrams.image ~source rejected));
  check int "invalid bytes retain a failure" 1 (List.length (Diagrams.failures rejected))

let test_crlf_diagram_association () =
  let module Diagrams = Masc_tui_resource_diagrams in
  let report = "# Report\r\n\r\n```mermaid\r\nflowchart LR\r\n A[계정] --> B[확인]\r\n```\r\n" in
  let parts = [text (Some "text/markdown") report] in
  let cache = Diagrams.create ~mime_type:None ~contents:parts
    ~width:640 ~cell_pixels:(8,16) ~colors:None in
  let request = Diagrams.request cache in
  let source = match Diagrams.sources request with [source] -> source
    | [] | _ :: _ -> fail "expected one retained diagram" in
  let png = Base64.decode_exn "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lV8AAAAASUVORK5CYII=" in
  let prepared = Diagrams.settle request ~source (Ok png) cache in
  check bool "PNG accepted before association" true
    (Option.is_some (Diagrams.image ~source prepared));
  let displayed = Masc_tui_text_block.lines report |> String.concat "\n"
    |> Masc_tui_markdown.mermaid_sources in
  match displayed with
  | [source] -> check bool "full CRLF document resolves its prepared source" true
      (Option.is_some (Diagrams.image_for_display ~source prepared))
  | [] | _ :: _ -> fail "full document lost its diagram"

let test_source_pixel_viewport () =
  let module Viewport = Masc_tui_image_viewport in
  let create width height = match Viewport.create ~width ~height with
    | Some viewport -> viewport | None -> fail "valid source dimensions refused" in
  let apply = Viewport.apply ~cell_pixels:(10,20) ~columns:80 ~rows:20 in
  let window = Viewport.window ~cell_pixels:(10,20) ~columns:80 ~rows:20 in
  let original = create 1600 800 in
  let fitted = window original in
  check (pair int int) "fit retains full original source" (1600,800) (fitted.width,fitted.height);
  let enlarged = apply Zoom_in original in
  let cropped = window enlarged in
  check (pair int int) "zoom sends a smaller source rectangle" (800,400) (cropped.width,cropped.height);
  let moved = window (apply Right enlarged) in
  check bool "horizontal input changes the source offset" true (moved.x > cropped.x);
  let bounds viewport =
    let view = window viewport in
    check bool "crop stays inside original pixels" true
      (view.x >= 0 && view.y >= 0 && view.width > 0 && view.height > 0
       && view.x+view.width <= 1600 && view.y+view.height <= 800
       && view.columns <= 80 && view.rows <= 20) in
  List.iter (fun action ->
    let rec exercise remaining viewport =
      bounds viewport;
      if remaining > 0 then exercise (remaining-1) (apply action viewport) in
    exercise 1600 enlarged) [Left;Right;Up;Down;Zoom_in;Zoom_out];
  let reset = window (apply Fit (apply Down enlarged)) in
  check (pair int int) "fit restores full source after pan" (1600,800) (reset.width,reset.height);
  List.iter (fun (width,height) ->
    let original = create width height in
    let fit viewport = Viewport.window ~cell_pixels:(17,37) ~columns:130 ~rows:45 viewport in
    let shown = fit original in
    check (pair int int) "fit cannot round away a source border" (width,height)
      (shown.width,shown.height);
    check (pair int int) "fit starts at original origin" (0,0) (shown.x,shown.y);
    let reset = fit (apply Fit (apply Down (apply Zoom_in original))) in
    check (pair int int) "reset retains irregular full source" (width,height)
      (reset.width,reset.height)) [(480,212);(641,359);(1,1000);(1000,1)];
  check bool "nonpositive source is refused" true (Option.is_none (Viewport.create ~width:0 ~height:10))

let () = run "resource image sources" ["source decisions", [
  test_case "zoom and pan remain inside original source pixels" `Quick test_source_pixel_viewport;
  test_case "CRLF document retains diagram association" `Quick test_crlf_diagram_association;
  test_case "diagram preparation owns response and request" `Quick test_diagram_preparation_ownership;
  test_case "Markdown diagrams retain source and part ownership" `Quick test_markdown_diagrams;
  test_case "wire conservation" `Quick test_wire_conservation;
  test_case "malformed parts refused" `Quick test_malformed_parts_refused;
  test_case "multipart declared media" `Quick test_multipart_types;
  test_case "immutable source ownership" `Quick test_source_ownership;
  test_case "payload decode refusal" `Quick test_decode_refusal;
  test_case "inert embedded HTML sources" `Quick test_html_embedded_sources;
  test_case "external HTML declarations remain unavailable" `Quick test_html_unavailable_sources;
  test_case "retained SVG keeps original format" `Quick test_retained_svg_format]]
