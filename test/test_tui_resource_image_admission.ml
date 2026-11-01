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
    sir_name = "local.png"; sir_owner = owner; sir_resource = None;
    sir_purpose = Types.Open_image }

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

let test_local_sources_on_resources () =
  let state = state () and original = attachment () in
  state.view <- Types.Resources;
  state.msg_attachments <- [original];
  let file = pending state (Types.Local_file_image_read state.workspace_authority) in
  let draft = pending state (Types.Draft_image_read (state.workspace_authority, original)) in
  let peer = pending state (Types.Peer_image_read state.workspace_read_authority) in
  let check_owners () =
    check bool "local file independent of resource reading" true (Types.image_reading_is_current state file);
    check bool "draft independent of resource reading" true (Types.image_reading_is_current state draft);
    check bool "peer still requires original resource reading" false (Types.image_reading_is_current state peer) in
  check_owners ();
  state.resource_content <- Some (uri, parts ());
  state.resource_pending_key <- Some uri;
  state.resource_content_error <- Some (uri, "previous resource refused");
  check_owners ();
  state.resource_pending_key <- None;
  state.resource_content_error <- None;
  check_owners ()

let test_remote_url_resource_independence () =
  let state = state () in
  state.view <- Types.Resources;
  let remote = pending state (Types.Remote_url_image_read state.workspace_authority) in
  check bool "URL needs no peer resource" true
    (Types.image_reading_is_current state remote);
  state.resource_content <- Some (uri, parts ());
  state.resource_pending_key <- Some uri;
  state.resource_content_error <- Some (uri, "unrelated read failed");
  state.workspace_read_authority <- ref ();
  check bool "URL keeps its workspace through peer resource refresh" true
    (Types.image_reading_is_current state remote);
  state.workspace_authority <- Types.Workspace_authority 1;
  check bool "URL cannot cross workspaces" false
    (Types.image_reading_is_current state remote)

let test_suspended_diagram_preparation () =
  let state = state () in
  let original = parts () in
  state.resource_content <- Some (uri,original);
  state.resource_diagrams <- Some (Masc_tui_resource_diagrams.create
    ~mime_type:None ~contents:original ~width:640 ~cell_pixels:(8,16) ~colors:None);
  Types.suspend_workspace_readings state;
  check bool "withdrawn epoch releases its preparation" true
    (Option.is_none state.resource_diagrams);
  check bool "retained original response remains readable" true
    (saved state == original)

let test_operator_protocol_boundary () =
  let module Reader = Masc_tui_input_reader in
  check bool "APC reply cannot withdraw an image request" false
    (Reader.is_operator_input (Reader.Graphics_reply "i=31;OK"));
  List.iter (fun event -> check bool "operator action can withdraw a request" true
    (Reader.is_operator_input event))
    [Reader.Key "esc";Reader.Mouse_left_press (1,1);
     Reader.Mouse_wheel (Masc.Tui_mouse_protocol.Wheel_up,1,1)]

let board_post ?(body="post body") ?(attachments=[]) id : Types.board_post =
  {bp_id=id;bp_author="author";bp_title="title";bp_body=body;bp_votes=0;
   bp_comment_count=0;bp_created_at="";bp_created_at_unix=None;bp_updated_at=None;
   bp_hearth=None;bp_kind=None;bp_closed=None;bp_attachments=attachments}

let board_comment id body : Types.board_comment =
  {bc_id=id;bc_parent_id=None;bc_author="author";bc_content=body;
   bc_created_at="";bc_votes={bcv_up=0;bcv_down=0}}

let board_detail state post comments =
  let module Detail = Masc_tui_board_detail in
  let loading,request = match Detail.start (Detail.clear state.Types.board_detail) ~post_id:post.Types.bp_id with
    | Started (loading,request) -> loading,request
    | Already_loading -> fail "unexpected pending Board detail" in
  state.board_detail <- Detail.complete loading request (Ok (post,comments,None))

let board_state post comments =
  let state=state () in
  let module Decode=Masc.Tui_decode in
  let identity : Decode.server_identity =
    {sid_version="test";sid_binary_commit="test";sid_binary_commit_age_s=None;
     sid_base_path=Decode.Canonical_path.of_path "/board-test";
     sid_masc_root=Decode.Canonical_path.of_path "/board-test/.masc";
     sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
     sid_sse_clients=None;sid_gc=None;sid_scheduler=None} in
  state.server_identity <- Some identity;
  state.workspace_identity <- Types.Workspace_identity_match;
  state.view <- Types.Board;
  state.board_mode <- Types.Board_read post.Types.bp_id;
  board_detail state post comments;
  state

let test_board_diagram_ownership () =
  let post=board_post ~body:"post diagram" "post-a" in
  let comment=board_comment "comment-a" "comment diagram" in
  let state=board_state post [comment] in
  let owner=Types.Board_diagram (Board_post_diagram {post_id=post.bp_id;body=post.bp_body}) in
  let post_read=pending state (Types.Board_image_read (state.workspace_read_authority,owner,ref ())) in
  let current pending = Types.image_reading_is_current state pending in
  check bool "post diagram owns its source" true (current post_read);
  board_detail state {post with bp_body="replacement"} [comment];
  check bool "changed post body retires preview" false (current post_read);
  board_detail state post [comment];
  state.board_comments_focused <- true;
  state.board_comment_cursor <- Some comment.bc_id;
  check bool "selected comment is not the post" false (current post_read);
  let owner=Types.Board_diagram (Board_comment_diagram
    {post_id=post.bp_id;comment_id=comment.bc_id;body=comment.bc_content}) in
  let comment_read=pending state (Types.Board_image_read (state.workspace_read_authority,owner,ref ())) in
  check bool "selected comment owns its source" true (current comment_read);
  board_detail state post [{comment with bc_content="updated"}];
  check bool "changed comment retires preview" false (current comment_read);
  board_detail state post [comment];
  state.board_comment_cursor <- Some "other";
  check bool "another selection retires preview" false (current comment_read);
  state.board_comment_cursor <- Some comment.bc_id;
  state.board_mode <- Types.Board_read "post-b";
  check bool "another post retires preview" false (current comment_read)

let test_board_attachment_ownership () =
  let attachment : Types.board_attachment =
    {ba_kind=Ak_image;ba_source=As_artifact {sha256=String.make 64 'a';bytes=4};
     ba_name=Some "image.png"} in
  let post=board_post ~attachments:[Ok attachment] "post-a" in
  let state=board_state post [] in
  let owner=Types.Board_attachment_image {post_id=post.bp_id;attachment} in
  let image=pending state (Types.Board_image_read (state.workspace_read_authority,owner,ref ())) in
  let current () = Types.image_reading_is_current state image in
  check bool "exact selected attachment owns preview" true (current ());
  board_detail state {post with bp_attachments=[Ok {attachment with ba_source=As_artifact
    {sha256=String.make 64 'a';bytes=5}}]} [];
  check bool "changed byte count retires preview" false (current ());
  board_detail state {post with bp_attachments=[Ok {attachment with ba_kind=Ak_file}]} [];
  check bool "changed attachment kind retires preview" false (current ());
  board_detail state post [];
  state.view <- Types.Resources;
  check bool "leaving Board retires preview" false (current ());
  state.view <- Types.Board;
  Types.suspend_workspace_readings state;
  check bool "withdrawn workspace reading retires preview" false (current ())

let test_board_preview_input_barrier () =
  let module Protocol = Masc_tui_async_protocol in
  let preview view = Protocol.Sent_image_ready {generation=1;view;keeper_name=None;
    name="preview";skill_reference=None;result=Error "unavailable"} in
  let scoped message = Protocol.Workspace_scoped (Types.Workspace_authority 0,Some (ref ()),message) in
  check bool "Board completion waits for pending input" true
    (Protocol.board_preview_waits_for_input (scoped (preview Types.Board)));
  check bool "other image surfaces retain their existing policy" false
    (Protocol.board_preview_waits_for_input (scoped (preview Types.Resources)))

let test_board_svg_and_original_reader () =
  let module Payload = Masc_tui_image_payload in
  let module Reader = Masc_tui_board_reader in
  let svg="<?xml version='1.0'?><svg xmlns='http://www.w3.org/2000/svg'><rect width='1' height='1'/></svg>" in
  check bool "SVG namespace selects the offline renderer" true (Payload.format_of_bytes svg=Svg);
  check bool "a different XML namespace is not SVG" true
    (Payload.format_of_bytes "<svg xmlns='urn:other'/>"=General_image);
  check bool "binary data is not an SVG root" true (Payload.format_of_bytes "\255\000"=General_image);
  let key : Reader.key = {post_id="post-a";sha256=Agent_core_sha256.(digest_string svg |> to_hex);
    bytes=String.length svg;name=Some "image.svg"} in
  let attachment : Types.board_attachment =
    {ba_kind=Ak_image;ba_source=As_artifact {sha256=key.sha256;bytes=key.bytes};ba_name=key.name} in
  let post=board_post ~attachments:[Ok attachment] key.post_id in
  let state=board_state post [] in
  state.board_reader_owner <- Some (state.workspace_authority,state.workspace_read_authority,Ak_image);
  state.board_reader <- Reader.offer_image ~key ~reason:"renderer unavailable" state.board_reader;
  check bool "fallback retains original attachment ownership" true (Option.is_some (Types.current_board_reader state));
  check bool "fallback does not fetch or offer unverified bytes" true
    (Option.is_none (Reader.pending state.board_reader) && Option.is_none (Reader.saved_source state.board_reader));
  board_detail state {post with bp_attachments=[Ok {attachment with ba_kind=Ak_file}]} [];
  check bool "same bytes under another kind retire reader" true (Option.is_none (Types.current_board_reader state));
  board_detail state post [];
  let reader,request=Reader.open_read ~content_kind:Image_bytes ~key state.board_reader in
  let request=match request with Some request -> request | None -> fail "original read did not start" in
  let reader=Reader.complete reader request (Reader.validate key svg) in
  check bool "image source is not expanded as text" true (Result.is_error (Reader.source reader));
  (match Reader.saved_source reader with
   | Some (_,_,bytes) -> check string "verified original remains saveable" svg bytes
   | None -> fail "verified original image is unavailable for saving")

let () = run "resource image admission" ["stored source",[
  test_case "protocol replies are not cancellation input" `Quick test_operator_protocol_boundary;
  test_case "Board post and comment diagram ownership" `Quick test_board_diagram_ownership;
  test_case "Board attachment ownership" `Quick test_board_attachment_ownership;
  test_case "Board preview waits for input" `Quick test_board_preview_input_barrier;
  test_case "Board SVG and original-image reader" `Quick test_board_svg_and_original_reader;
  test_case "workspace suspension retires diagram preparation" `Quick test_suspended_diagram_preparation;
  test_case "original SVG and multipart admission" `Quick test_original_admission;
  test_case "wrong pending URI" `Quick test_wrong_pending;
  test_case "failed and detached completion" `Quick test_failed_read;
  test_case "new immutable observation" `Quick test_new_observation;
  test_case "local draft and peer withdrawal" `Quick test_local_peer_loss;
  test_case "local draft replacement and workspace" `Quick test_local_draft_replacement;
  test_case "peer resource owner" `Quick test_peer_resource_owner;
  test_case "remote URL workspace owner" `Quick test_remote_url_resource_independence;
  test_case "local sources on Resources" `Quick test_local_sources_on_resources]]
