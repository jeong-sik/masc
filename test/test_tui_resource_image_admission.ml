open Alcotest
module Mcp = Masc_tui_mcp
module Images = Masc_tui_resource_images
module Updates = Masc_tui_resources_updates
module Types = Masc_tui_types

module Catalog = Masc_tui_resource_catalog
let key = testable (fun fmt _ -> Format.pp_print_string fmt "resource key") Catalog.equal_key
let read_done state ~key result =
  let owner = ref () in
  state.Types.resource_read_owner <- Some owner;
  Updates.read_done state ~request:{Catalog.key;owner} (Result.map Catalog.mcp_reading result)
let uri = Catalog.Mcp_uri "masc://drawing"
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
  state.resource_pending_key <- Some uri;
  state.resource_image_cursor <- 1;
  read_done state ~key:uri (Ok original);
  let admitted = saved state in
  check (option key) "pending consumed" None state.resource_pending_key;
  check int "new image selection" 0 state.resource_image_cursor;
  check (list int) "multipart response order" [1;2]
    (List.map fst (Images.images ~mime_type:None admitted));
  (match Images.images ~mime_type:None admitted with
   | (_,Masc_tui_image_preview.Output_image {source=Inline_svg raw;_}) :: _ ->
       check string "XML TAB and CRLF survive admission" svg raw
   | [] | (_, (Masc_tui_image_preview.Named_path _ | Staged _ | Stored_attachment _
       | Output_image {source=(Inline_data _ | Inline_mermaid _ | Server_path _ | Remote_uri _);_}
       | Unavailable_image _ | No_image)) :: _ -> fail "expected original SVG source");
  check bool "retain original immutable observation" true (original == admitted);
  match admitted with
  | part :: _ ->
      check (option string) "original URI" (Some "masc://drawing?original=1") part.rc_uri;
      check (option string) "original MIME" (Some "image/svg+xml") part.rc_mime_type
  | [] -> fail "missing original parts"

let test_wrong_pending () =
  let state = state () and original = parts () in
  state.resource_content <- Some (uri,original);
  state.resource_pending_key <- Some (Catalog.Mcp_uri "masc://next");
  read_done state ~key:uri (Ok (parts ()));
  check bool "late URI cannot replace content" true (saved state == original);
  check (option key) "current request retained" (Some (Catalog.Mcp_uri "masc://next")) state.resource_pending_key

let test_failed_read () =
  let state = state () and original = parts () in
  state.resource_content <- Some (uri,original);
  state.resource_pending_key <- Some uri;
  read_done state ~key:uri (Error "read refused");
  check bool "failure preserves original" true (saved state == original);
  check (option (pair key string)) "explicit failure" (Some (uri,"read refused")) state.resource_content_error;
  read_done state ~key:uri (Ok (parts ()));
  check bool "detached completion cannot replace" true (saved state == original)

let test_new_observation () =
  let state = state () and original = parts () in
  let old = Some (uri,original) in
  state.resource_content <- old;
  state.resource_pending_key <- Some uri;
  state.resource_content_error <- Some (uri,"previous failure");
  let next = parts () in
  read_done state ~key:uri (Ok next);
  check bool "new response stored exactly" true (saved state == next);
  check bool "equal new bytes retire old preview" false (Images.same_reading ~equal:Catalog.equal_key old state.resource_content);
  check (option (pair key string)) "success clears previous error" None state.resource_content_error

let attachment () =
  { Masc_tui_keeper_chat_projection.attachment_id = "draft-1";
    name = "local.png"; mime_type = "image/png"; size = 3;
    data = String.init 4 (fun _ -> 'A') }

let pending state owner =
  { Types.sir_generation = state.Types.image_request_generation;
    sir_view = state.view; sir_keeper = state.msg_target_keeper_name;
    sir_name = "local.png"; sir_owner = owner; sir_resource = None }

let test_local_peer_loss () =
  let state = state () and original = attachment () in
  state.msg_attachments <- [original];
  let local = pending state (Types.Draft_image_read (state.workspace_authority, original)) in
  let peer = pending state (Types.Peer_image_read state.workspace_read_authority) in
  let file = pending state (Types.Local_file_image_read state.workspace_authority) in
  Types.suspend_workspace_readings state;
  check bool "local file survives peer withdrawal" true (Types.image_reading_is_current state file);
  check bool "local draft survives peer withdrawal" true (Types.image_reading_is_current state local);
  check bool "peer reply loses its read epoch" false (Types.image_reading_is_current state peer);
  check bool "original attachment retained" true (List.hd state.msg_attachments == original);
  check string "encoded attachment preserved" "AAAA" original.data;
  state.workspace_authority <- Types.Workspace_authority 1;
  check bool "file owner cannot cross workspaces" false (Types.image_reading_is_current state file)

let test_local_draft_replacement () =
  let state = state () and original = attachment () in
  state.msg_attachments <- [original];
  let local = pending state (Types.Draft_image_read (state.workspace_authority, original)) in
  state.msg_attachments <- [attachment ()];
  check bool "equal replacement is another draft" false (Types.image_reading_is_current state local);
  state.msg_attachments <- [];
  check bool "removed draft cannot paint" false (Types.image_reading_is_current state local);
  state.msg_attachments <- [original];
  state.workspace_authority <- Types.Workspace_authority 1;
  check bool "same object in another workspace cannot paint" false (Types.image_reading_is_current state local)

let test_peer_resource_owner () =
  let state = state () and original = parts () in
  state.view <- Types.Resources;
  state.resource_content <- Some (uri, original);
  let peer = { (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_resource = state.resource_content } in
  check bool "original peer resource owned" true (Types.image_reading_is_current state peer);
  state.resource_content <- Some (uri, parts ());
  check bool "equal new response retires preview" false (Types.image_reading_is_current state peer);
  state.resource_content <- Some (uri, original);
  state.resource_pending_key <- Some uri;
  check bool "pending replacement cannot paint" false (Types.image_reading_is_current state peer)

let () = run "resource image admission" ["stored source",[
  test_case "original SVG and multipart admission" `Quick test_original_admission;
  test_case "wrong pending URI" `Quick test_wrong_pending;
  test_case "failed and detached completion" `Quick test_failed_read;
  test_case "new immutable observation" `Quick test_new_observation;
  test_case "local draft and peer withdrawal" `Quick test_local_peer_loss;
  test_case "local draft replacement and workspace" `Quick test_local_draft_replacement;
  test_case "peer resource owner" `Quick test_peer_resource_owner]]
