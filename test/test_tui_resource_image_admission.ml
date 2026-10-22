open Alcotest
module Mcp = Masc_tui_mcp
module Images = Masc_tui_resource_images
module Updates = Masc_tui_resources_updates
module Types = Masc_tui_types

let uri = "masc://drawing"
let svg = "<svg\twidth=\"10\" height=\"10\" xmlns=\"http://www.w3.org/2000/svg\">\r\n<text>A\tB</text>\r\n</svg>"
let parts () =
  List.map Fun.id [{ Mcp.rc_uri = Some "masc://drawing?original=1";
     rc_mime_type = Some "image/svg+xml";
     rc_kind = Mcp.Resource_text svg };
   { Mcp.rc_uri = Some "file:///never-opened.png";
     rc_mime_type = Some "image/png";
     rc_kind = Mcp.Resource_blob {base64="QUJDRA=="} }]
let state () = Types.create_state ~workspace:"resource-test" ~port:0 ~refresh_interval:0. ()
let saved state =
  match state.Types.resource_content with
  | Some (_, parts) -> parts
  | None -> fail "expected admitted content"

let test_original_admission () =
  let state = state () and original = parts () in
  state.resource_pending_uri <- Some uri;
  state.resource_image_cursor <- 1;
  Updates.read_done state ~uri (Ok original);
  let admitted = saved state in
  check (option string) "pending consumed" None state.resource_pending_uri;
  check int "new image selection" 0 state.resource_image_cursor;
  check (list int) "multipart response order" [1;2]
    (List.map fst (Images.images ~mime_type:None admitted));
  (match Images.images ~mime_type:None admitted with
   | (1,Masc_tui_image_preview.Output_image {source=Inline_svg raw;_}) :: _ ->
       check string "XML TAB and CRLF survive admission" svg raw
   | _ -> fail "expected original SVG source");
  check bool "retain original immutable observation" true (original == admitted);
  match admitted with
  | part :: _ ->
      check (option string) "original URI" (Some "masc://drawing?original=1") part.rc_uri;
      check (option string) "original MIME" (Some "image/svg+xml") part.rc_mime_type
  | [] -> fail "missing original parts"

let test_wrong_pending () =
  let state = state () and original = parts () in
  state.resource_content <- Some (uri,original);
  state.resource_pending_uri <- Some "masc://next";
  Updates.read_done state ~uri (Ok (parts ()));
  check bool "late URI cannot replace content" true (saved state == original);
  check (option string) "current request retained" (Some "masc://next") state.resource_pending_uri

let test_failed_read () =
  let state = state () and original = parts () in
  state.resource_content <- Some (uri,original);
  state.resource_pending_uri <- Some uri;
  Updates.read_done state ~uri (Error "read refused");
  check bool "failure preserves original" true (saved state == original);
  check (option (pair string string)) "explicit failure" (Some (uri,"read refused")) state.resource_content_error;
  Updates.read_done state ~uri (Ok (parts ()));
  check bool "detached completion cannot replace" true (saved state == original)

let test_new_observation () =
  let state = state () and original = parts () in
  let old = Some (uri,original) in
  state.resource_content <- old;
  state.resource_pending_uri <- Some uri;
  state.resource_content_error <- Some (uri,"previous failure");
  let next = parts () in
  Updates.read_done state ~uri (Ok next);
  check bool "new response stored exactly" true (saved state == next);
  check bool "equal new bytes retire old preview" false (Images.same_reading old state.resource_content);
  check (option (pair string string)) "success clears previous error" None state.resource_content_error

let () = run "resource image admission" ["stored source",[
  test_case "original SVG and multipart admission" `Quick test_original_admission;
  test_case "wrong pending URI" `Quick test_wrong_pending;
  test_case "failed and detached completion" `Quick test_failed_read;
  test_case "new immutable observation" `Quick test_new_observation]]
