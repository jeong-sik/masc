open Alcotest
module Mcp = Masc_tui_mcp
module Images = Masc_tui_resource_images
module Updates = Masc_tui_resources_updates
module Types = Masc_tui_types
module Fetched = Masc_tui_fetched

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
let state () = Types.create_state ~workspace:"resource-test" ~port:0 ()
let keeper_row name : Types.keeper =
  {k_origin=Masc.Tui_decode.Persisted_keeper;k_name=name;k_paused=false;
   k_identity=Error (Masc.Tui_decode.Identity_unreadable "not observed");k_activity=None}
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
    sir_memory_activity = None;
    sir_skill_reference = None;
    sir_purpose = Types.Open_image }

let test_repeated_remote_save_keeps_the_exact_request () =
  let state=state () in
  let origin=pending state (Types.Remote_url_image_read state.workspace_authority) in
  state.image_request_generation <- state.image_request_generation + 1;
  let save={origin with sir_generation=state.image_request_generation} in
  state.image_open <- true;
  state.image_cell_view <- Some (Types.Image_cells {
    ic_title="captured";ic_caption=[];ic_lines=[];ic_columns=0;ic_terminal_size=(24,80);
    ic_workspace=state.workspace_authority;ic_origin=origin;ic_unconfirmed=false;
    ic_copy_path=Some "https://fixture.invalid/image";ic_copy_page=Some "https://fixture.invalid/image";
    ic_alternate_target=None;ic_last_open=None;
    ic_unsaved_remote=Some {uri_bytes="original";uri_image_url="https://fixture.invalid/image";
                            uri_reason="preview limit"};ic_save_cancelled=false });
  state.sent_image_read <- Some save;
  check bool "the fresh save owns this displayed source" true (Types.unsaved_remote_save_in_flight state);
  state.image_request_generation <- state.image_request_generation + 1;
  check bool "a later generation retires the save" false (Types.unsaved_remote_save_in_flight state);
  state.image_request_generation <- save.sir_generation;
  let other={save with sir_owner=Types.Remote_url_image_read state.workspace_authority} in
  state.sent_image_read <- Some other;
  check bool "a different remote request is not the save" false (Types.unsaved_remote_save_in_flight state);
  state.sent_image_read <- Some save;
  state.image_open <- false;
  check bool "a closed card no longer owns the save" false (Types.unsaved_remote_save_in_flight state)

let test_skill_image_owner () =
  let module Tools=Masc.Tui_decode_tools in
  let reference name revision =
    Skill_reference.of_yojson (`Assoc [
      "identity", `Assoc ["source_id", `String "workspace"; "package_id", `String "diagram";
        "name", `String name];
      "content_revision", `String (String.make 64 revision)]) |> Result.get_ok in
  let original=reference "diagram" 'a' in
  let profile esp_reference : Tools.effective_skill_profile = {
    esp_reference; esp_name="diagram"; esp_kind="composition"; esp_execution="inline";
    esp_body_bytes=0; esp_discovery_bytes=0; esp_load_reasons=[]; esp_node_count=0;
    esp_batch_count=0; esp_max_parallelism=0; esp_flow=None; esp_io=Model_orchestrated } in
  let inventory ?(left_out=[]) selected : Tools.tool_snapshot = {
    ts_tools=[]; ts_count=0; ts_freshness=Settled;
    ts_effective=Some (Effective_surface_available {
      ets_keeper_name="keeper-a"; ets_runtime_id="runtime"; ets_official_client_kind="client";
      ets_tool_delivery=Effective_tools_delivered; ets_native_posture=None;
      ets_skill_snapshot_revision="snapshot"; ets_skill_resource_read_max_bytes=None;
      ets_skills_left_out=left_out; ets_unavailable_skill_names=[];
      ets_skill_profiles=List.map profile selected;
      ets_tool_surface_bytes=None; ets_skill_tool_surface_bytes=None; ets_skill_discovery_bytes=0;
      ets_skill_body_bytes=None; ets_tools=[]; ets_tool_surface_sha256=None });
    ts_usage=None; ts_volume_gc_report=None;
    ts_storage={ st_host_disk=Host_disk_absent; st_keeper_cleanup=Keeper_cleanup_absent } } in
  let state=state () in
  state.view <- Types.Tools;
  state.local_keepers <- Types.Local_workspace_read;
  state.keepers <- [keeper_row "keeper-a"];
  let image={ (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_keeper=Some "keeper-a";
    sir_skill_reference=Some original } in
  state.image_open <- true;
  state.image_cell_view <- Some (Types.Image_cells {
    ic_title="diagram";ic_caption=[];ic_lines=[];ic_columns=0;ic_terminal_size=(24,80);
    ic_workspace=state.workspace_authority;ic_origin=image;ic_unconfirmed=false;
             ic_copy_path=None;ic_copy_page=None;ic_alternate_target=None;ic_last_open=None;ic_unsaved_remote=None;ic_save_cancelled=false });
  let window : Masc_tui_image_viewport.window = {x=0;y=0;width=1;height=1;columns=1;rows=1} in
  let inspection={image with sir_purpose=Inspect_image {identity=ref ();window}} in
  state.tools_inventory <- Some (inventory [original]);
  check bool "exact skill revision owns the open" true (Types.image_reading_is_current state image);
  check bool "inspection retains that owner" true (Types.image_reading_is_current state inspection);
  let displayed () = Option.is_some
    (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority image) in
  check bool "displayed skill image retains its source" true (displayed ());
  state.keepers <- [keeper_row "keeper-b"];
  let wrongly_rebound = {image with sir_keeper=Some "keeper-b"} in
  check bool "keeper A inventory cannot authorize a keeper B request" false
    (Types.image_reading_is_current state wrongly_rebound);
  check bool "A inventory does not match B" false
    (Types.tools_skill_inventory_matches_keeper state (Some "keeper-b"));
  state.keepers <- [keeper_row "keeper-a"];
  state.tools_error <- Some "temporary failure";
  check bool "failed skill refresh retains displayed source" true (displayed ());
  check bool "failed skill refresh is indicated" true (Types.image_cell_source_unconfirmed state image);
  state.tools_error <- None;
  state.tools_read_inflight <- Some {tri_generation=state.tools_request_generation;
    tri_keeper=None;tri_pending=[Tools_inventory_read]};
  check bool "pending skill refresh retains the last confirmed observation" false
    (Types.image_cell_source_unconfirmed state image);
  state.tools_read_inflight <- None;
  state.tools_inventory <- Some (inventory ~left_out:["one document unavailable"] [reference "other" 'a']);
  check bool "a partial inventory retains the absent displayed skill" true (displayed ());
  check bool "a partial inventory marks the absent skill unconfirmed" true
    (Types.image_cell_source_unconfirmed state image);
  check bool "refresh restores the captured Skill instead of the temporary cursor" true
    (Option.exists (Skill_reference.equal original)
      (Types.tools_skill_reference_for_refresh state ~keeper_name:(Some "keeper-a")));
  state.tools_inventory <- Some (inventory [reference "other" 'a'; original]);
  state.tools_skill_cursor <- 0;
  check bool "recovery keeps the original even after automatic cursor reconciliation" true (displayed ());
  check bool "a different Skill selection is unconfirmed" true
    (Types.image_cell_source_unconfirmed state image);
  state.tools_skill_cursor <- 1;
  check bool "recovered original is confirmed" false (Types.image_cell_source_unconfirmed state image);
  state.tools_skill_cursor <- 0;
  state.tools_inventory <- Some (inventory ~left_out:["unrelated advisory"] [original]);
  check bool "a still-present skill stays confirmed despite another diagnostic" false
    (Types.image_cell_source_unconfirmed state image);
  state.tools_inventory <- Some (inventory ~left_out:["unrelated advisory"] [reference "diagram" 'b']);
  check bool "a confirmed replacement is retired despite another diagnostic" false (displayed ());
  state.tools_inventory <- Some (inventory [reference "diagram" 'b']);
  check bool "a replacement revision retires the open" false (Types.image_reading_is_current state image);
  check bool "a replacement revision retires inspection" false (Types.image_reading_is_current state inspection);
  check bool "replacement revision retires the displayed image" false (displayed ());
  state.tools_inventory <- Some (inventory [reference "other" 'a']);
  check bool "a different skill retires the open" false (Types.image_reading_is_current state image);
  check bool "a confirmed missing skill retires the displayed image" false (displayed ());
  state.tools_inventory <- None;
  check bool "a missing skill retires the open" false (Types.image_reading_is_current state image);
  check bool "an unavailable skill inventory retains the displayed image" true (displayed ());
  check bool "unavailable skill inventory is indicated" true (Types.image_cell_source_unconfirmed state image);
  state.tools_inventory <- Some (inventory []);
  check bool "a confirmed empty inventory retires the displayed image" false (displayed ());
  let local=pending state (Types.Local_file_image_read state.workspace_authority) in
  let draft=attachment () in
  state.msg_attachments <- [draft];
  let draft=pending state (Types.Draft_image_read (state.workspace_authority,draft)) in
  check bool "local images do not require a skill" true (Types.image_reading_is_current state local);
  check bool "draft images do not require a skill" true (Types.image_reading_is_current state draft)

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

let test_superseded_resource_diagram_worker () =
  let module Diagrams=Masc_tui_resource_diagrams in
  let module Work=Masc_tui_board_preview_work in
  let contents = [{Mcp.rc_uri=None;rc_mime_type=Some "text/markdown";
    rc_kind=Resource_text "```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\ngraph TD; C-->D\n```\n"}] in
  let frame = Diagrams.{frame_mime_type=None;frame_contents=contents;frame_width=640;
    frame_cell_pixels=(8,16);frame_colors=None} in
  let old=Diagrams.create ~mime_type:None ~contents ~width:640 ~cell_pixels:(8,16) ~colors:None in
  let next=Diagrams.create ~mime_type:None ~contents ~width:320 ~cell_pixels:(8,16) ~colors:None in
  let request=Diagrams.request old in
  let source=match Diagrams.sources request with [source;_] -> source | _ -> fail "expected two diagrams" in
  let decide ~frame snapshot = Diagrams.admission request ~frame snapshot in
  check bool "current frame may start" true
    (decide ~frame:(Some frame) (Some old) = Diagrams.Admit);
  check bool "leaving before the first source prevents admission" true
    (decide ~frame:None (Some old) = Diagrams.Retire);
  let partially_done=Diagrams.settle request ~source (Error "first source finished") old in
  check bool "first completion still owns the request" true
    (Diagrams.progress partially_done = (1,2));
  check bool "leaving between sources prevents further admission" true
    (decide ~frame:None (Some partially_done) = Diagrams.Retire);
  let first,first_claim,first_preparing = match Diagrams.claim_next old with
    | Some claim -> claim | None -> fail "first diagram claim" in
  check bool "the first source is exclusively claimed" true
    (String.equal first source && Diagrams.owns_claim request ~source:first first_claim first_preparing
     && Option.is_none (Diagrams.claim_next first_preparing));
  let first_done=Diagrams.settle request ~source:first (Error "first source finished") first_preparing in
  let second,old_claim,second_preparing = match Diagrams.claim_next first_done with
    | Some claim -> claim | None -> fail "second diagram claim" in
  let interrupted=Diagrams.abandon_preparing second_preparing in
  check bool "withdrawing a pending source preserves completed progress" true
    (Diagrams.progress interrupted = (1,2));
  let retry,retry_claim,retrying = match Diagrams.claim_next interrupted with
    | Some claim -> claim | None -> fail "retry diagram claim" in
  check bool "only the unfinished source is retried" true (String.equal second retry);
  let after_old_cleanup=Diagrams.abandon request ~source:second old_claim retrying in
  check bool "old cleanup cannot abandon a new claim for the same source" true
    (Diagrams.owns_claim request ~source:retry retry_claim after_old_cleanup);
  let stale_completion=Diagrams.settle_claimed request ~source:second old_claim
    (Error "stale completion") after_old_cleanup in
  check bool "an old completion cannot settle a new claim for the same source" true
    (stale_completion == after_old_cleanup);
  let finished=Diagrams.settle_claimed request ~source:retry retry_claim
    (Error "retry finished") stale_completion in
  check bool "the retained and retried sources both finish" true (Diagrams.progress finished = (2,2));
  List.iter (fun changed ->
    check bool "changed frame is not admitted" true
      (decide ~frame:(Some changed) (Some old) = Diagrams.Retire))
    [ {frame with frame_width=320}; {frame with frame_cell_pixels=(9,16)};
      {frame with frame_colors=Some ("#ffffff", "#000000")};
      {frame with frame_mime_type=Some "text/plain"};
      {frame with frame_contents=List.map Fun.id contents} ];
  check bool "a replaced owner is ignored" true
    (decide ~frame:(Some frame) (Some next) = Diagrams.Ignore);
  check bool "old claim cleanup preserves the replacement request" true
    (Diagrams.abandon request ~source:second old_claim next == next);
  let worker=Work.create () in
  let old_ticket=match Work.reserve worker with Some ticket -> ticket | None -> fail "old dispatch" in
  if decide ~frame:None (Some old) = Diagrams.Retire then
    check bool "pending dispatch was withdrawn" true (Work.withdraw_pending worker);
  let new_ticket=match Work.reserve worker with Some ticket -> ticket | None -> fail "replacement dispatch" in
  check bool "withdrawn diagram dispatch cannot start" true
    (Option.is_none (Work.run_reserved worker old_ticket (fun () -> ())));
  Work.withdraw worker old_ticket;
  check bool "old cleanup cannot cancel the replacement dispatch" true
    (Option.is_some (Work.run_reserved worker new_ticket (fun () -> ())));
  check bool "the old physical worker starts" true (Work.try_acquire worker);
  check bool "withdrawal does not free an active renderer" false (Work.withdraw_pending worker);
  check bool "new width no longer matches the old request" false
    (Diagrams.matches ~mime_type:None ~contents ~width:320 ~cell_pixels:(8,16) ~colors:None old);
  check bool "a replacement waits while physical work remains" true (Option.is_none (Work.reserve worker));
  let after_stale=Diagrams.settle request ~source (Error "old request") next in
  check bool "old completion cannot change the replacement" true (after_stale == next);
  Work.release worker;
  check bool "the replacement can start after physical return" true
    (Option.is_some (Work.try_run worker (fun () -> ())))

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
     sid_runtime_instance_id=None;
     sid_base_path=Decode.Canonical_path.of_path "/board-test";
     sid_masc_root=Decode.Canonical_path.of_path "/board-test/.masc";
     sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
     sid_sse_clients=None;sid_gc=None;sid_scheduler=None;sid_operator_action=None} in
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

let test_displayed_cell_resource_owner () =
  let state = state () and original = parts () in
  state.view <- Types.Resources;
  state.resource_content <- Some (uri, original);
  let workspace = state.workspace_authority in
  let origin = { (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_resource = state.resource_content } in
  let retained origin = Types.image_cell_origin_for_redraw state ~workspace origin in
  check bool "displayed resource is retained" true (Option.is_some (retained origin));
  check bool "original resource is confirmed" false (Types.image_cell_source_unconfirmed state origin);
  Types.suspend_workspace_readings state;
  state.workspace_identity <- Types.Workspace_identity_match_unconfirmed "temporarily unread";
  state.resource_pending_key <- Some uri;
  check bool "unconfirmed workspace and pending reread retain the displayed observation" true
    (Option.is_some (retained origin));
  check bool "unconfirmed workspace is indicated" true (Types.image_cell_source_unconfirmed state origin);
  state.workspace_identity <- Types.Workspace_identity_match;
  state.resource_pending_key <- None;
  state.resource_content_error <- Some (uri, "temporary failure");
  check bool "failed same-source reread retains the displayed observation" true
    (Option.is_some (retained origin));
  check bool "failed reread is indicated" true (Types.image_cell_source_unconfirmed state origin);
  state.resource_content_error <- None;
  let equal_parts = parts () in
  state.resource_content <- Some (uri, equal_parts);
  let rebound = match retained origin with Some origin -> origin | None -> fail "equal reread retired image" in
  check bool "equal completed reread is confirmed" false (Types.image_cell_source_unconfirmed state rebound);
  check bool "equal reread rebinds to the new snapshot" true
    (match rebound.sir_resource with Some (_, current) -> current == equal_parts | None -> false);
  state.resource_pending_key <- Some (Catalog.Mcp_uri "masc://other");
  check bool "a different selection retires the displayed image" true (Option.is_none (retained rebound));
  state.resource_pending_key <- None;
  let changed = [{Mcp.rc_uri=Some "masc://drawing";rc_mime_type=Some "image/svg+xml";
    rc_kind=Mcp.Resource_text "changed"}] in
  state.resource_content <- Some (uri, changed);
  check bool "confirmed different bytes retire the displayed image" true (Option.is_none (retained rebound));
  state.resource_pending_key <- Some uri;
  check bool "a later pending reread cannot hide already changed bytes" true (Option.is_none (retained rebound));
  state.resource_pending_key <- None;
  state.resource_content_error <- Some (uri, "later reread failed");
  check bool "a later failed reread cannot hide already changed bytes" true (Option.is_none (retained rebound));
  state.resource_content_error <- None;
  state.resource_content <- Some (uri, equal_parts);
  let owner = Updates.begin_listing state in
  Updates.listed state ~owner (Ok {Catalog.entries=[];notes=["MCP listing incomplete"];reports_complete=true});
  check bool "partial inventory cannot prove the MCP source absent" true (Option.is_some (retained rebound));
  check bool "cleared reading remains visibly unconfirmed" true (Types.image_cell_source_unconfirmed state rebound);
  let owner = Updates.begin_listing state in
  Updates.listed state ~owner (Ok {Catalog.entries=[];notes=[];reports_complete=true});
  check bool "MCP inventory alone cannot prove the captured source absent" true (Option.is_some (retained rebound));
  state.resource_content <- Some (uri, equal_parts);
  state.workspace_authority <- Types.Workspace_authority 1;
  check bool "another workspace retires even equal bytes" true (Option.is_none (retained rebound))

let test_displayed_cell_board_owner () =
  let post = board_post "post-a" and comment = board_comment "comment-a" "original" in
  let state = board_state post [comment] in
  state.board_comments_focused <- true;
  state.board_comment_cursor <- Some comment.bc_id;
  let subject = Types.Board_diagram (Board_comment_diagram
    {post_id=post.bp_id;comment_id=comment.bc_id;body=comment.bc_content}) in
  let origin = pending state (Types.Board_image_read (state.workspace_read_authority,subject,ref ())) in
  let workspace = state.workspace_authority in
  let retained () = Option.is_some (Types.image_cell_origin_for_redraw state ~workspace origin) in
  check bool "displayed Board comment retained" true (retained ());
  check bool "Board comment begins confirmed" false (Types.image_cell_source_unconfirmed state origin);
  let module Detail = Masc_tui_board_detail in
  let loading, request = match Detail.start state.board_detail ~post_id:post.bp_id with
    | Started (loading, request) -> loading, request
    | Already_loading -> fail "unexpected Board refresh" in
  state.board_detail <- loading;
  check bool "refresh in flight retains Board image" true (retained ());
  state.board_detail <- Detail.complete loading request (Error "temporary failure");
  check bool "failed refresh retains Board image" true (retained ());
  check bool "failed Board refresh is indicated" true (Types.image_cell_source_unconfirmed state origin);
  Types.suspend_workspace_readings state;
  state.workspace_identity <- Types.Workspace_identity_match_unconfirmed "temporarily unread";
  check bool "unconfirmed workspace retains Board image" true (retained ());
  board_detail state post [comment];
  check bool "same source reconfirmed" true (retained ());
  state.workspace_identity <- Types.Workspace_identity_match;
  check bool "reconfirmed Board observation is indicated" false (Types.image_cell_source_unconfirmed state origin);
  board_detail state post [];
  check bool "comment absent from a partial page stays retained" true (retained ());
  check bool "comment outside the page is unconfirmed" true (Types.image_cell_source_unconfirmed state origin);
  board_detail state post [{comment with bc_content="replacement"}];
  check bool "confirmed changed comment retires Board image" false (retained ())

let test_displayed_cell_attachment_uncertain () =
  let attachment : Types.board_attachment =
    {ba_kind=Ak_image;ba_source=As_artifact {sha256=String.make 64 'a';bytes=4};
     ba_name=Some "image.png"} in
  let post=board_post ~attachments:[Ok attachment] "post-a" in
  let state=board_state post [] in
  let subject=Types.Board_attachment_image {post_id=post.bp_id;attachment} in
  let origin=pending state (Types.Board_image_read (state.workspace_read_authority,subject,ref ())) in
  let retained () = Option.is_some
    (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority origin) in
  check bool "observed attachment is confirmed" false (Types.image_cell_source_unconfirmed state origin);
  board_detail state {post with bp_attachments=[Error "unreadable attachment"]} [];
  check bool "malformed attachment retains captured image" true (retained ());
  check bool "malformed attachment is indicated as unconfirmed" true
    (Types.image_cell_source_unconfirmed state origin);
  board_detail state {post with bp_attachments=[]} [];
  check bool "unidentified attachment absence stays unconfirmed" true
    (retained () && Types.image_cell_source_unconfirmed state origin);
  board_detail state post [];
  check bool "observed original attachment is confirmed again" false
    (Types.image_cell_source_unconfirmed state origin)

let test_displayed_chat_cell_is_captured () =
  let state=state () in
  state.view <- Types.Keepers Keeper_message;
  let origin=pending state (Types.Peer_image_read state.workspace_read_authority) in
  check bool "chat image is retained for the same workspace" true
    (Option.is_some (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority origin));
  check bool "chat image without a source anchor is marked unconfirmed" true
    (Types.image_cell_source_unconfirmed state origin)

let test_memory_image_keeper_owner () =
  let state=state () in
  state.view <- Types.Memory;
  state.memory_page <- Types.Memory_changes;
  state.memory_facts_keeper <- Some "memory-keeper";
  state.msg_target_keeper_name <- Some "unrelated-chat";
  let origin={ (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_keeper=Some "memory-keeper" } in
  let current () = Types.image_request_keeper_is_current state origin in
  check bool "memory request is independent of the chat target" true (current ());
  state.memory_facts_keeper <- Some "another-keeper";
  check bool "another memory keeper refuses completion" false (current ());
  state.memory_facts_keeper <- Some "memory-keeper";
  state.memory_page <- Types.Memory_facts;
  check bool "leaving changes refuses diagram completion" false (current ())

let begin_memory_activity state keeper =
  match Fetched.refresh ~equal:String.equal state.Types.memory_activity ~key:keeper with
  | Fetched.Started (source, request) -> state.memory_activity <- source; request
  | Fetched.Already_loading -> fail "expected a new Memory activity read"

let memory_image_capture () =
  let state=state () in
  state.view <- Types.Memory;
  state.memory_page <- Types.Memory_changes;
  state.memory_facts_keeper <- Some "memory-keeper";
  state.workspace_identity <- Types.Workspace_identity_match;
  let activity : Masc.Keeper_memory_activity.t =
    {limit=30; journal_lines=1; events=[]; notes=[]} in
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok activity);
  let origin={ (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_keeper=Some "memory-keeper"; sir_memory_activity=Some activity } in
  state, activity, origin

let test_memory_image_source_freshness () =
  let state, activity, origin=memory_image_capture () in
  let retained origin = Option.is_some
    (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority origin) in
  check bool "exact fresh Memory activity is confirmed" false
    (Types.image_cell_source_unconfirmed state origin);
  let identical = match Masc.Keeper_memory_activity.of_json
      (Masc.Keeper_memory_activity.to_json activity) with
    | Ok decoded -> decoded
    | Error error -> fail ("activity roundtrip failed: " ^ error) in
  check bool "successful reread decodes a different activity object" false (identical == activity);
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok identical);
  check bool "identical successful reread confirms the captured activity" false
    (Types.image_cell_source_unconfirmed state origin);
  let request=begin_memory_activity state "memory-keeper" in
  check bool "in-flight reread retains the captured image" true (retained origin);
  check bool "retained Ready value during reread is unconfirmed" true
    (Types.image_cell_source_unconfirmed state origin);
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request
    (Error "activity read failed");
  check bool "failed reread retains the captured image" true (retained origin);
  check bool "failed reread is unconfirmed" true (Types.image_cell_source_unconfirmed state origin);
  let replacement={activity with journal_lines=2} in
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok replacement);
  check bool "new activity does not replace the captured image" true (retained origin);
  check bool "another Ready activity cannot confirm the old capture" true
    (Types.image_cell_source_unconfirmed state origin);
  let reopened={origin with sir_memory_activity=Some replacement} in
  check bool "reopening captures the current fresh activity" false
    (Types.image_cell_source_unconfirmed state reopened);
  state.memory_facts_keeper <- Some "another-keeper";
  check bool "another selected Keeper cannot confirm the capture" true
    (Types.image_cell_source_unconfirmed state reopened);
  state.memory_facts_keeper <- Some "memory-keeper";
  state.memory_page <- Types.Memory_facts;
  check bool "another Memory page cannot confirm the capture" true
    (Types.image_cell_source_unconfirmed state reopened);
  state.memory_page <- Types.Memory_changes;
  state.workspace_identity <- Types.Workspace_identity_unread;
  check bool "unconfirmed workspace retains the captured image" true (retained reopened);
  check bool "unconfirmed workspace cannot confirm the capture" true
    (Types.image_cell_source_unconfirmed state reopened);
  state.workspace_identity <- Types.Workspace_identity_match;
  state.workspace_read_authority <- ref ();
  check bool "another workspace read epoch cannot confirm the capture" true
    (Types.image_cell_source_unconfirmed state reopened)

let test_memory_image_source_unavailable () =
  let state, activity, origin=memory_image_capture () in
  check bool "unanchored Memory image stays unconfirmed" true
    (Types.image_cell_source_unconfirmed state {origin with sir_memory_activity=None});
  let partial={activity with notes=["unreadable journal row"]} in
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok partial);
  check bool "partial Ready history stays unconfirmed" true
    (Types.image_cell_source_unconfirmed state {origin with sir_memory_activity=Some partial});
  state.memory_activity <- Fetched.initial;
  check bool "absent activity stays unconfirmed" true (Types.image_cell_source_unconfirmed state origin);
  let request=begin_memory_activity state "memory-keeper" in
  check bool "initial loading stays unconfirmed" true (Types.image_cell_source_unconfirmed state origin);
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request
    (Error "activity unavailable");
  check bool "failed activity stays unconfirmed" true (Types.image_cell_source_unconfirmed state origin);
  let request=begin_memory_activity state "another-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok activity);
  check bool "another fetched Keeper cannot confirm the capture" true
    (Types.image_cell_source_unconfirmed state origin)

let test_memory_pixel_source_retention () =
  let state, activity, origin=memory_image_capture () in
  let source : Types.image_pixel_source =
    {ips_workspace=state.workspace_authority;ips_origin=origin;
     ips_unconfirmed=true;ips_footer=""} in
  let current () = match Types.image_pixel_source_for_redraw state source with
    | Some current -> current
    | None -> fail "expected the captured Memory pixel source" in
  check bool "fresh pixel source is confirmed" false (current ()).ips_unconfirmed;
  let request=begin_memory_activity state "memory-keeper" in
  check bool "pixel source becomes unconfirmed during refresh" true (current ()).ips_unconfirmed;
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request
    (Error "activity unavailable");
  let retained=current () in
  check bool "failed refresh retains the exact pixel origin" true (retained.ips_origin == origin);
  check bool "failed refresh keeps the pixel source unconfirmed" true retained.ips_unconfirmed;
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request
    (Ok {activity with journal_lines=2});
  check bool "changed activity retains the captured pixel origin" true
    ((current ()).ips_origin == origin);
  check bool "changed activity keeps the pixel source unconfirmed" true (current ()).ips_unconfirmed;
  let request=begin_memory_activity state "memory-keeper" in
  state.memory_activity <- Fetched.complete ~equal:String.equal state.memory_activity request (Ok activity);
  check bool "matching successful activity reconfirms the pixel source" false (current ()).ips_unconfirmed;
  state.memory_facts_keeper <- Some "another-keeper";
  check bool "another selected Keeper withdraws the pixel source" true
    (Option.is_none (Types.image_pixel_source_for_redraw state source));
  state.memory_facts_keeper <- Some "memory-keeper";
  state.workspace_authority <- Types.Workspace_authority 1;
  check bool "another workspace withdraws the pixel source" true
    (Option.is_none (Types.image_pixel_source_for_redraw state source))

let test_tools_image_keeper_owner () =
  let state=state () in
  state.view <- Types.Tools;
  state.local_keepers <- Types.Local_workspace_read;
  state.keepers <- [keeper_row "keeper-a"];
  let reference = Skill_reference.of_yojson (`Assoc [
    "identity", `Assoc ["source_id", `String "workspace"; "package_id", `String "diagram";
      "name", `String "diagram"];
    "content_revision", `String (String.make 64 'a')]) |> Result.get_ok in
  let origin={ (pending state (Types.Peer_image_read state.workspace_read_authority)) with
    sir_keeper=Some "keeper-a";sir_skill_reference=Some reference } in
  state.image_open <- true;
  state.image_cell_view <- Some (Types.Image_cells {
    ic_title="diagram";ic_caption=[];ic_lines=[];ic_columns=0;ic_terminal_size=(24,80);
    ic_workspace=state.workspace_authority;ic_origin=origin;ic_unconfirmed=false;
    ic_copy_path=None;ic_copy_page=None;ic_alternate_target=None;ic_last_open=None;ic_unsaved_remote=None;ic_save_cancelled=false });
  state.msx_open <- true;
  check bool "a hidden image cannot restore Tools selection" true
    (Option.is_none (Types.tools_skill_cell_image_owner state));
  state.msx_open <- false;
  let current () = Types.image_request_keeper_is_current state origin in
  let retained () = Option.is_some
    (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority origin) in
  check bool "Tools request captures the selected keeper" true (origin.sir_keeper=Some "keeper-a");
  check bool "the selected keeper can accept completion" true (current ());
  state.keepers <- [];
  state.keepers_error <- Some "roster unavailable";
  check bool "an unconfirmed keeper cannot accept completion" false (current ());
  check bool "an open image survives a missing keeper observation" true (retained ());
  check bool "missing keeper is indicated" true (Types.image_cell_source_unconfirmed state origin);
  let local=pending state (Types.Local_file_image_read state.workspace_authority) in
  check bool "local image is independent of the Tools keeper roster" true
    (Types.image_request_keeper_is_current state local
     && Option.is_some (Types.image_cell_origin_for_redraw state ~workspace:state.workspace_authority local));
  state.keepers_error <- None;
  check bool "confirmed removal retires the open image" false (retained ());
  let a=keeper_row "keeper-a" and b=keeper_row "keeper-b" in
  state.keepers <- [a;b];
  state.keeper_cursor <- 0;
  Masc_tui_loader.replace_keeper_rows ~preserve_on_error:true state
    ~keepers:[b] ~error:(Some "partial roster");
  check bool "partial roster cannot replace the captured keeper" true (retained ());
  check bool "partial roster is indicated" true (Types.image_cell_source_unconfirmed state origin);
  Masc_tui_loader.replace_keeper_rows ~preserve_on_error:true state
    ~keepers:[a;b] ~error:None;
  check bool "reconciliation restores the displayed Keeper" true
    (Option.map (fun (keeper : Types.keeper) -> keeper.k_name) (Types.selected_keeper state) = Some "keeper-a");
  check bool "recovered captured keeper retains the displayed image" true (retained ());
  Masc_tui_loader.replace_keeper_rows ~preserve_on_error:true state
    ~keepers:[b] ~error:None;
  check bool "another keeper cannot accept the old completion" false (current ());
  check bool "another keeper retires the open image" false (retained ());
  state.sent_image_read <- Some origin;
  check bool "current workspace read has no retired notice" true
    (Option.is_none (Types.retired_skill_image_notice state));
  state.workspace_read_authority <- ref ();
  check bool "retired read is held only for an input-sensitive notice" true
    (Option.exists (fun pending -> pending == origin) (Types.retired_skill_image_notice state));
  ignore (Types.withdraw_image_open state);
  check bool "operator input cancels the retired preview notice" true
    (Option.is_none (Types.retired_skill_image_notice state))

let test_roster_view_change_retires_pending_worker () =
  let module Work = Masc_tui_board_preview_work in
  let state = state () and worker = Work.create () in
  let a = keeper_row "keeper-a" and b = keeper_row "keeper-b" in
  state.view <- Types.Keepers Keeper_detail;
  state.workspace_identity <- Types.Workspace_identity_match;
  state.local_keepers <- Types.Local_workspace_read;
  state.keepers <- [a;b];
  state.keeper_cursor <- 0;
  let old = pending state (Types.Remote_url_image_read state.workspace_authority) in
  state.sent_image_read <- Some old;
  let ticket = match Work.reserve worker with Some ticket -> ticket | None -> fail "reservation" in
  let calls = ref 0 in
  let before_view_change () =
    incr calls;
    check bool "owner is withdrawn before navigation" true (state.view = old.sir_view);
    ignore (Types.withdraw_image_open state);
    ignore (Work.withdraw_pending worker) in
  let replace keepers =
    Masc_tui_loader.replace_keeper_rows ~before_view_change ~preserve_on_error:true state
      ~keepers ~error:None in
  replace [a;b];
  check int "same view preserves pending work" 0 !calls;
  check bool "same view retains the exact owner" true
    (Option.exists (fun request -> request == old) state.sent_image_read);
  replace [b];
  check int "changed view withdraws once" 1 !calls;
  let next = match Work.reserve worker with Some next -> next | None -> fail "replacement reservation" in
  check bool "withdrawn worker cannot start" true
    (Option.is_none (Work.run_reserved worker ticket (fun () -> ())));
  Work.withdraw worker ticket;
  check bool "old withdrawal cannot release the replacement" true
    (Option.is_some (Work.run_reserved worker next (fun () -> ())));
  state.view <- old.sir_view;
  check bool "returning to the old view cannot revive its owner" true
    (Option.is_none (Types.take_image_read state old))

let test_image_preview_input_barrier () =
  let module Protocol = Masc_tui_async_protocol in
  let state=state () in
  let preview view =
    let request={ (pending state (Types.Local_file_image_read state.workspace_authority)) with
      sir_view=view } in
    Protocol.Sent_image_ready {request;
      result=Protocol.Image_prepared (Error "unavailable")} in
  let scoped message = Protocol.Workspace_scoped (Types.Workspace_authority 0,Some (ref ()),message) in
  let waits message = Protocol.message_waits_for_input ~resource_read:(fun _ -> false)
      ~recovery_loaded:(fun _ -> false) message in
  check bool "Board completion waits for pending input" true
    (waits (scoped (preview Types.Board)));
  check bool "Resources completion also waits" true
    (waits (scoped (preview Types.Resources)));
  let request=pending state (Types.Remote_url_image_read state.workspace_authority) in
  check bool "a busy inspection waits for pending input" true
    (waits (Protocol.Sent_image_ready {request;result=Protocol.Image_worker_busy}));
  let remote=Protocol.Image_render_ready {request;title="image";caption=[];
    page_url="https://example.invalid";image_url="https://example.invalid/image";
    result=Error "unavailable"} in
  check bool "remote failure waits before browser fallback" true
    (waits remote);
  let key : Masc_tui_board_reader.key =
    {post_id="post";sha256=String.make 64 'a';bytes=0;name=None} in
  let _,request=Masc_tui_board_reader.open_read ~key Masc_tui_board_reader.initial in
  let request=match request with Some request -> request | None -> fail "missing reader request" in
  let attachment : Types.board_attachment =
    {ba_kind=Ak_image;ba_source=As_url "https://example.invalid/image.png";ba_name=None} in
  let prepared=match Masc_tui_attachment_action.prepare ~fetch:(fun ~sha256:_ -> Error "unused") attachment with
    | Ok prepared -> prepared | Error _ -> fail "URL preparation failed" in
  let attempt=ref () in
  let open_ready=Protocol.Board_msg (Protocol.Board_attachment_saved (request, Ok (Protocol.Board_image_open_ready (attempt,prepared)))) in
  check bool "external open waits for pending input" true
    (waits (scoped (Protocol.Workspace_operation open_ready)));
  let retry=Protocol.Board_msg (Protocol.Board_attachment_saved (request, Ok (Protocol.Board_image_open_retry {attempt;prepared;opener="open"}))) in
  check bool "fallback opener also waits for pending input" true
    (waits (scoped retry));
  let saved=Protocol.Board_msg (Protocol.Board_attachment_saved (request, Ok (Protocol.Board_saved_original "saved"))) in
  check bool "completed save is not deferred" false
    (waits saved);
  let request : Catalog.read_request = {key=uri;owner=ref ()} in
  let read=Protocol.Resource_msg (Protocol.Resource_read (request,Error "unavailable",Types.Share_journal_not_needed)) in
  let lookup : Types.resource_share_recovery_lookup =
    {recovery_lookup_owner=ref ();recovery_lookup_workspace=state.workspace_authority;
     recovery_lookup_origin={wi_base_path="/test";wi_masc_root="/test/.masc"};
     recovery_lookup_key=uri} in
  let recovery=Protocol.Resource_msg (Protocol.Resource_share_recovery_loaded (lookup,Error "unavailable")) in
  let waits_owned message = Protocol.message_waits_for_input ~resource_read:(fun _ -> true)
      ~recovery_loaded:(fun _ -> true) message in
  List.iter (fun message ->
    check bool "owned share read waits for input" true (waits_owned (scoped message));
    check bool "operation envelope does not inherit share callbacks" false
      (waits_owned (scoped (Protocol.Workspace_operation message)))) [read;recovery]

let test_image_input_ownership () =
  let module Reader = Masc_tui_input_reader in
  let state=state () in
  let make_remote () = pending state (Types.Remote_url_image_read state.workspace_authority) in
  let input event =
    if Reader.is_operator_input event then ignore (Types.withdraw_image_open state) in
  let admitted request = Option.is_some (Types.take_image_read state request) in
  let initial_generation=state.image_request_generation in
  let first=make_remote () in
  state.sent_image_read <- Some first;
  input (Reader.Graphics_reply "i=31;OK");
  check bool "terminal reply preserves the pending image" true (admitted first);
  check bool "a completion is consumed only once" false (admitted first);
  List.iter (fun event ->
    let old=make_remote () in
    state.sent_image_read <- Some old;
    input event;
    check bool "operator input withdraws the opening" true (Option.is_none state.sent_image_read);
    check bool "late result cannot draw or open a browser" false (admitted old))
    [Reader.Key "esc";Reader.Key "ctrl-g";Reader.Mouse_left_press (1,1);
     Reader.Mouse_wheel (Masc.Tui_mouse_protocol.Wheel_up,1,1)];
  let old=make_remote () in
  state.sent_image_read <- Some old;
  ignore (Types.withdraw_image_open state);
  let replacement=make_remote () in
  state.sent_image_read <- Some replacement;
  check int "browser generation is not changed by early withdrawal"
    initial_generation state.image_request_generation;
  check bool "identical-looking old read is refused" false (admitted old);
  check bool "old read does not consume replacement" true
    (Option.exists (fun current -> current == replacement) state.sent_image_read);
  check bool "replacement is admitted" true (admitted replacement);
  let window : Masc_tui_image_viewport.window =
    {x=0;y=0;width=10;height=10;columns=5;rows=5} in
  let inspection={ (make_remote ()) with
    sir_purpose=Types.Inspect_image {identity=ref ();window} } in
  state.sent_image_read <- Some inspection;
  input (Reader.Key "left");
  check bool "inspection worker remains in flight" true
    (Option.exists (fun current -> current == inspection) state.sent_image_read);
  check bool "inspection worker can settle" true (admitted inspection)

let test_image_result_with_full_mailbox () =
  let module Protocol = Masc_tui_async_protocol in
  let module Results = Masc_tui_workspace_result in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let shared=Eio.Stream.create 1 in
    Eio.Stream.add shared ();
    List.iter (fun (result,withdraw,expected_draw,expected_open) ->
      let state=state () and results=Results.create () in
      let request=pending state (Types.Remote_url_image_read state.workspace_authority) in
      state.sent_image_read <- Some request;
      let delivered,resolve=Eio.Promise.create () in
      Eio_context.with_turn_switch sw (fun () ->
        Results.launch_session ~results ~boundary_error:Fun.id
          ~deliver:(fun result ->
            Eio.Promise.resolve resolve ();
            Protocol.Image_render_ready {request;title="image";caption=[];
              page_url="https://example.invalid";image_url="https://example.invalid/image";result})
          (fun () -> result));
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Promise.await delivered);
      Eio.Fiber.yield ();
      check int "shared mailbox remains full" 1 (Eio.Stream.length shared);
      if withdraw then ignore (Types.withdraw_image_open state);
      let draw=ref 0 and open_browser=ref 0 in
      (match Results.take_ready results with
       | [{message=Protocol.Image_render_ready {request;result;_};_}] ->
           if Option.is_some (Types.take_image_read state request) then
             (match result with Ok _ -> incr draw | Error _ -> incr open_browser)
       | _ -> fail "expected the session-owned image completion");
      check int "only an admitted result can draw" expected_draw !draw;
      check int "only an admitted failure can open the browser" expected_open !open_browser;
      Results.close results)
      [Ok (Masc_tui_image_cache.Remote_png "png"),false,1,0; Error "unavailable",false,0,1;
       Ok (Masc_tui_image_cache.Remote_png "png"),true,0,0; Error "unavailable",true,0,0]))

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
  state.board_reader <- Reader.offer_image ~key ~message:"renderer unavailable" state.board_reader;
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
   | None -> fail "verified original image is unavailable for saving");
  let reader,opened=Reader.begin_original_open reader in
  let first_attempt=match opened with Some (attempt,_,_,_) -> attempt | None -> fail "original open did not start" in
  let reader,duplicate=Reader.begin_original_open reader in
  check bool "repeated input cannot duplicate preparation" true (Option.is_none duplicate);
  let reader=Reader.finish_original_open reader request first_attempt in
  let reader,opened_again=Reader.begin_original_open reader in
  let next_attempt=match opened_again with Some (attempt,_,_,_) -> attempt | None -> fail "second open did not start" in
  let reader=Reader.finish_original_open reader request first_attempt in
  check bool "late retry from the previous attempt has no authority" false
    (Reader.owns_original_open reader request first_attempt);
  let reader,stale_attempt=Reader.begin_original_open reader in
  check bool "late completion cannot release a newer attempt on the same read" true (Option.is_none stale_attempt);
  check bool "new attempt retains ownership" true (Reader.owns_original_open reader request next_attempt);
  let reopened,new_request=Reader.open_read ~content_kind:Image_bytes ~key reader in
  let new_request=match new_request with Some request -> request | None -> fail "fresh read did not start" in
  let reopened=Reader.complete reopened new_request (Reader.validate key svg) in
  let reopened,opened=Reader.begin_original_open reopened in
  let newest_attempt=match opened with Some (attempt,_,_,_) -> attempt | None -> fail "new reader open did not start" in
  let reopened=Reader.finish_original_open reopened request next_attempt in
  let reopened,stale_release=Reader.begin_original_open reopened in
  check bool "old completion cannot release the new opening" true (Option.is_none stale_release);
  let reopened=Reader.finish_original_open reopened new_request newest_attempt in
  let reopened,next=Reader.begin_original_open reopened in
  let interrupted=match next with Some (attempt,_,_,_) -> attempt | None -> fail "later open did not start" in
  let reopened=Reader.withdraw_original_open reopened in
  check bool "interrupt retires an opener or retry that has not started" false
    (Reader.owns_original_open reopened new_request interrupted);
  let reopened,next=Reader.begin_original_open reopened in
  let after_interrupt=match next with Some (attempt,_,_,_) -> attempt | None -> fail "fresh open did not start" in
  let reopened=Reader.finish_original_open reopened new_request interrupted in
  check bool "interrupted receipt cannot release the new attempt" true
    (Reader.owns_original_open reopened new_request after_interrupt)

let test_board_worker_and_png_boundary () =
  let module Work=Masc_tui_board_preview_work in
  let worker=Work.create () in
  let busy=ref false in
  let first=Work.run worker (fun () ->
    busy := Result.is_error (Work.run worker (fun () -> Ok ()));
    Ok ()) in
  check bool "worker refuses a second preparation before physical return" true !busy;
  check bool "first worker completes" true (Result.is_ok first);
  (try ignore (Work.run worker (fun () -> failwith "worker exception")) with Failure _ -> ());
  check bool "worker releases its slot even on exception" true (Result.is_ok (Work.run worker (fun () -> Ok ())));
  check bool "a child opener acquires its slot" true (Work.try_acquire worker);
  check bool "a second opener is refused until the first is reaped" false (Work.try_acquire worker);
  Work.release worker;
  check bool "a reaped opener releases the slot" true (Work.try_acquire worker);
  Work.release worker;
  check bool "a last worker acquires its slot" true (Work.try_acquire worker);
  Work.stop worker;
  check bool "shutdown rejects work that has not started" false (Work.try_acquire worker);
  Work.release worker;
  Work.await_stopped worker;
  check bool "truncated PNG magic does not reach the terminal" false
    (Masc_tui_image_cache.has_png_structure "\137PNG");
  let header="\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001" in
  check bool "a truncated IHDR does not reach the terminal" false
    (Masc_tui_image_cache.has_png_structure header);
  let png="\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001\b\006\
    \000\000\000\031\021\196\137\000\000\000\nIDATx\156c\000\001\000\000\005\
    \000\001\r\n-\180\000\000\000\000IEND\174B`\130" in
  check bool "complete one-pixel PNG has the required structure" true
    (Masc_tui_image_cache.has_png_structure png)

let test_physical_inspection_worker () =
  let module Work=Masc_tui_board_preview_work in
  let worker=Work.create () in
  let mutex=Mutex.create () and changed=Condition.create () in
  let started=ref false and attempted=ref false and finish=ref false in
  let retired=match Work.reserve worker with Some ticket -> ticket | None -> fail "first reservation" in
  ignore (Work.withdraw_pending worker);
  let current=match Work.reserve worker with Some ticket -> ticket | None -> fail "new reservation" in
  let stale_started=ref false in
  let stale=Work.run_reserved worker retired (fun () -> stale_started := true) in
  let first=Thread.create (fun () -> Fun.protect ~finally:(fun () ->
    Mutex.lock mutex;
    attempted := true;
    Condition.broadcast changed;
    Mutex.unlock mutex) (fun () ->
      ignore (Work.run_reserved worker current (fun () ->
        Mutex.lock mutex;
        started := true;
        Condition.broadcast changed;
        while not !finish do Condition.wait changed mutex done;
        Mutex.unlock mutex)))) () in
  Mutex.lock mutex;
  while not !started && not !attempted do Condition.wait changed mutex done;
  let did_start = !started in
  Mutex.unlock mutex;
  ignore (Work.withdraw_pending worker);
  let second_started=ref false in
  let second=Work.try_run worker (fun () -> second_started := true) in
  Mutex.lock mutex;
  finish := true;
  Condition.broadcast changed;
  Mutex.unlock mutex;
  Thread.join first;
  check bool "the current reservation starts" true did_start;
  check bool "a withdrawn reservation cannot start after a new reservation" true
    (Option.is_none stale && not !stale_started);
  check bool "a withdrawn observer cannot start a second physical worker" true
    (Option.is_none second && not !second_started);
  check bool "a later inspection starts after the worker returns" true
    (Option.is_some (Work.try_run worker (fun () -> ())));
  let later=match Work.reserve worker with Some ticket -> ticket | None -> fail "later reservation" in
  Work.stop worker;
  check bool "shutdown withdraws a worker that has not started" true
    (Option.is_none (Work.run_reserved worker later (fun () -> ())));
  check bool "shutdown prevents later inspections" true
    (Option.is_none (Work.try_run worker (fun () -> ())))

let test_queued_copy_waits_for_physical_worker () =
  let module Work=Masc_tui_board_preview_work in
  let worker=Work.create () in
  check bool "first worker acquires the slot" true (Work.try_acquire worker);
  let retired=match Work.reserve_after_active worker with
    | Some ticket -> ticket | None -> fail "queued reservation" in
  check bool "only one reservation can wait" true
    (Option.is_none (Work.reserve_after_active worker));
  ignore (Work.withdraw_pending worker);
  let current=match Work.reserve_after_active worker with
    | Some ticket -> ticket | None -> fail "replacement reservation" in
  let stale=Work.run_reserved_after_active worker retired (fun () -> fail "withdrawn work ran") in
  check bool "withdrawn reservation cannot start" true (Option.is_none stale);
  let started=Atomic.make false and result=ref None in
  let thread=Thread.create (fun () ->
    result := Work.run_reserved_after_active worker current (fun () -> Atomic.set started true)) () in
  check bool "a queued worker does not release the active one" true (Work.is_busy worker);
  Work.release worker;
  Thread.join thread;
  check bool "current reservation runs after physical completion" true
    (Atomic.get started && Option.is_some !result);
  check bool "a completed worker releases the slot" false (Work.is_busy worker);
  check bool "another physical worker acquires the slot" true (Work.try_acquire worker);
  let queued=match Work.reserve_after_active worker with
    | Some ticket -> ticket | None -> fail "shutdown reservation" in
  let result=ref None in
  let thread=Thread.create (fun () ->
    result := Work.run_reserved_after_active worker queued (fun () -> fail "stopped work ran")) () in
  Work.stop worker;
  Thread.join thread;
  Work.release worker;
  check bool "shutdown wakes a queued worker without running it" true (Option.is_none !result)

let test_initial_vector_worker () =
  let module Work=Masc_tui_board_preview_work in
  let module Requests=Masc_tui_image_requests in
  let worker=Work.create () and board=Work.create () in
  let directory=Filename.temp_dir "tui vector admission " "" in
  Fun.protect ~finally:(fun () -> Unix.rmdir directory) (fun () ->
    let calls=ref 0 and blocked=ref false in
    let run_vector _ =
      incr calls;
      blocked := Option.is_none (Work.reserve worker);
      Unix.WEXITED 1 in
    let board_calls=ref 0 in
    let run_board _ = incr board_calls; Unix.WEXITED 1 in
    let source=Requests.Generated (Masc_tui_image_preview.mermaid_source "graph TD; A-->B") in
    let load ~board_worker ~vector_admission source = Requests.load
        ~host:"127.0.0.1" ~port:0 ~cache_dir:(fun () -> directory)
        ~diagram_width:100 ~diagram_height:100 ~diagram_font_size:12 ~diagram_colors:None
        ~board_worker
        ~admit_vector:(fun () -> match vector_admission with
          | Some admission -> Ok admission | None -> Error "not admitted")
        ~run:run_board ~vector_run:run_vector
        ~display:Masc_tui_image_cache.Pixel_graphics source in
    check bool "Mermaid is admitted as a vector" true (Requests.is_vector source);
    let source_of = function
      | Masc_tui_image_preview.Output_image {source;_} -> Requests.Generated source
      | Named_path _ | Staged _ | Stored_attachment _ | Unavailable_image _ | No_image -> fail "missing image source" in
    let svg=source_of (Masc_tui_image_preview.inline_svg ~name:"svg" "<svg xmlns='http://www.w3.org/2000/svg'/>") in
    check bool "inline SVG is admitted as a vector" true (Requests.is_vector svg);
    let raster=source_of (Masc_tui_image_preview.inline_payload ~name:"png"
        (Masc_tui_image_payload.of_base64 ~mime_type:"image/png"
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAEAAAUAAQ0KLbQAAAAASUVORK5CYII=")) in
    check bool "raster image does not reserve Pele" false (Requests.is_vector raster);
    check bool "raster preview still loads without a reservation" true
      (Result.is_ok (load ~board_worker:None ~vector_admission:None raster));
    let old=match Work.reserve worker with Some ticket -> ticket | None -> fail "old admission" in
    ignore (Work.withdraw_pending worker);
    let current=match Work.reserve worker with Some ticket -> ticket | None -> fail "current admission" in
    check bool "withdrawn open cannot start Pele" true
      (Result.is_error (load ~board_worker:None ~vector_admission:(Some (worker,old)) source));
    Work.withdraw worker old;
    check int "withdrawn open made no renderer call" 0 !calls;
    check bool "current admission reaches its renderer" true
      (Result.is_error (load ~board_worker:None ~vector_admission:(Some (worker,current)) source));
    check int "only the current open entered Pele" 1 !calls;
    check bool "initial render excludes a concurrent inspection" true !blocked;
    check bool "the renderer released the physical slot" true
      (Option.is_some (Work.try_run worker (fun () -> ())));
    check bool "a vector without admission cannot start Pele" true
      (Result.is_error (load ~board_worker:None ~vector_admission:None source));
    check int "unadmitted vector made no renderer call" 1 !calls;
    let invalid=Requests.Draft { (attachment ()) with mime_type="image/svg+xml"; data="?" } in
    let decoding=match Work.reserve worker with Some ticket -> ticket | None -> fail "decode admission" in
    check bool "invalid vector input fails during admitted preparation" true
      (Result.is_error (load ~board_worker:None ~vector_admission:(Some (worker,decoding)) invalid));
    check bool "failed decoding releases the physical worker" false (Work.is_busy worker);
    let pending=match Work.reserve worker with Some ticket -> ticket | None -> fail "pending vector" in
    ignore (load ~board_worker:(Some board) ~vector_admission:None source);
    check int "Board keeps its separate renderer" 1 !board_calls;
    check bool "Board did not consume the non-Board reservation" true
      (Option.is_some (Work.run_reserved worker pending (fun () -> ()))))

let test_vector_character_presentation_is_bounded () =
  let module Work=Masc_tui_board_preview_work in
  let module Requests=Masc_tui_image_requests in
  let directory=Filename.temp_dir "tui vector character " "" in
  let executable=Filename.concat directory "masc-pele" in
  let png_path=Filename.concat directory "fixture.png" in
  let previous=Option.value (Sys.getenv_opt "PATH") ~default:"" in
  let png="\137PNG\r\n\026\n\000\000\000\rIHDR\000\000\000\001\000\000\000\001\b\006\
    \000\000\000\031\021\196\137\000\000\000\nIDATx\156c\000\001\000\000\005\
    \000\001\r\n-\180\000\000\000\000IEND\174B`\130" in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "PATH" previous;
    Unix.unlink executable;
    Unix.unlink png_path;
    Unix.rmdir directory) (fun () ->
      Out_channel.with_open_bin png_path (fun out -> Out_channel.output_string out png);
      Out_channel.with_open_text executable (fun out ->
        Printf.fprintf out "#!/bin/sh\nprintf 'masc-pele-protocol:1\\n'\ncat %s\n" (Filename.quote png_path));
      Unix.chmod executable 0o700;
      Unix.putenv "PATH" (directory ^ ":" ^ previous);
      let worker=Work.create () in
      let admission=match Work.reserve worker with Some ticket -> ticket | None -> fail "vector admission" in
      let bounded_calls=ref 0 and unbounded_calls=ref 0 in
      let vector_run command =
        incr bounded_calls;
        if !bounded_calls = 1 then Unix.system command else Unix.WEXITED 1 in
      let run _ = incr unbounded_calls; Unix.WEXITED 1 in
      let source=Requests.Generated (Masc_tui_image_preview.mermaid_source "graph TD; A-->B") in
      let result=Requests.load ~host:"127.0.0.1" ~port:0 ~cache_dir:(fun () -> directory)
          ~diagram_width:100 ~diagram_height:100 ~diagram_font_size:12 ~diagram_colors:None
          ~board_worker:None ~admit_vector:(fun () -> Ok (worker,admission)) ~run ~vector_run
          ~display:(Masc_tui_image_cache.Character_cells {columns=10;rows=5}) source in
      check bool "character conversion failure is reported" true (Result.is_error result);
      check int "Pele and character conversion use the bounded runner" 2 !bounded_calls;
      check int "character conversion never uses the unbounded runner" 0 !unbounded_calls;
      check bool "conversion failure releases the physical worker" false (Work.is_busy worker))

(* Deadline for a child that a passing run ends some other way: by exiting on
   its own, by cancellation, or by process shutdown. It is not the behavior
   under test. Reaching it means the run is stuck, so it stays far above the
   start-up delay of a child on a loaded host. *)
let hang_detector_deadline_seconds = 30.

let test_board_pele_deadline () =
  let directory=Filename.temp_dir "board pele test " "" in
  let executable=Filename.concat directory "masc-pele" in
  let opener=Filename.concat directory "open" in
  let fallback=Filename.concat directory "xdg-open" in
  let previous=Option.value ~default:"" (Sys.getenv_opt "PATH") in
  Out_channel.with_open_text executable (fun out -> Out_channel.output_string out "#!/bin/sh\nexec sleep 30\n");
  Out_channel.with_open_text opener (fun out -> Out_channel.output_string out "#!/bin/sh\nexit 3\n");
  Out_channel.with_open_text fallback (fun out -> Out_channel.output_string out "#!/bin/sh\nexec sleep 30\n");
  Unix.chmod executable 0o700;
  Unix.chmod opener 0o700;
  Unix.chmod fallback 0o700;
  Fun.protect ~finally:(fun () ->
    Unix.putenv "PATH" previous; Unix.unlink executable; Unix.unlink opener; Unix.unlink fallback; Unix.rmdir directory) (fun () ->
    Unix.putenv "PATH" (directory ^ ":" ^ previous);
    let slot=Masc_tui_board_preview_work.create () in
    let run=Masc_tui_image_cache.run_bounded ~deadline_seconds:0.2 in
    let runner=Masc_tui_pele.command_runner ~run in
    let scene=Masc_tui_pele.scene ~format:Mermaid ~max_width:100 ~font_size:12
      ~now_ms:0L ~colors:None "graph TD; A-->B" in
    let result=Masc_tui_board_preview_work.run slot (fun () ->
      Masc_tui_pele.render ~cache_dir:directory ~runner scene) in
    check bool "hung renderer is terminated" true (Result.is_error result);
    check bool "renderer return releases its slot" true
      (Result.is_ok (Masc_tui_board_preview_work.run slot (fun () -> Ok ())));
    let first,pid=match Masc_tui_browser.spawn_url "image with spaces.png" with
      | Ok started -> started | Error error -> fail error in
    check bool "first opener failure is observable" true
      (match Masc_tui_image_cache.wait_bounded ~deadline_seconds:hang_detector_deadline_seconds pid with
       | Unix.WEXITED 3 -> true | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false);
    let second,pid=match Masc_tui_browser.spawn_url ~after:first "image with spaces.png" with
      | Ok started -> started | Error error -> fail error in
    check string "failed opener advances to the next executable" "xdg-open" second;
    check bool "hung external opener is reaped at its deadline" true
      (match Masc_tui_image_cache.wait_bounded ~deadline_seconds:0.2 pid with
       | Unix.WSIGNALED signal -> signal=Sys.sigkill
       | Unix.WEXITED _ | Unix.WSTOPPED _ -> false);
    let _,pid=match Masc_tui_browser.spawn_url ~after:first "image with spaces.png" with
      | Ok started -> started | Error error -> fail error in
    let cancelled=Atomic.make false and status=ref None in
    let thread=Thread.create (fun () ->
      status := Some (Masc_tui_image_cache.wait_bounded
        ~cancelled:(fun () -> Atomic.get cancelled) ~deadline_seconds:hang_detector_deadline_seconds pid)) () in
    Atomic.set cancelled true;
    Thread.join thread;
    check bool "shutdown cancellation kills and reaps the opener" true
      (match !status with Some (Unix.WSIGNALED signal) -> signal=Sys.sigkill
       | Some (Unix.WEXITED _ | Unix.WSTOPPED _) | None -> false);
    check bool "cancelled child cannot be reaped a second time" true
      (match Unix.waitpid [Unix.WNOHANG] pid with
       | exception Unix.Unix_error (Unix.ECHILD,_,_) -> true
       | _ -> false))

let test_renderer_shutdown () =
  let directory=Filename.temp_dir "board renderer shutdown " "" in
  let executable=Filename.concat directory "renderer" and marker=Filename.concat directory "pid"
  and result=Filename.concat directory "result" in
  let partial=marker ^ ".tmp" and partial_result=result ^ ".tmp" in
  Fun.protect ~finally:(fun () ->
    Sys.readdir directory |> Array.iter (fun name ->
      if String.starts_with ~prefix:"pele-" name then Unix.unlink (Filename.concat directory name));
    List.iter (fun name -> if Sys.file_exists name then Unix.unlink name)
      [executable;marker;partial;result;partial_result];
    Unix.rmdir directory) (fun () ->
    Out_channel.with_open_text executable (fun out ->
      Printf.fprintf out "#!/bin/sh\nprintf '%%s' \"$$\" > %s && mv %s %s && exec sleep 30\n"
        (Filename.quote partial) (Filename.quote partial) (Filename.quote marker));
    Unix.chmod executable 0o700;
    let test_executable=Unix.realpath Sys.executable_name in
    let null=Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
    let supervisor=Fun.protect ~finally:(fun () -> Unix.close null) (fun () ->
      Unix.create_process test_executable
        [|test_executable;"--board-renderer-supervisor";executable;marker;result|] null null null) in
    let reaped=ref false in
    let rec poll () = match Unix.waitpid [Unix.WNOHANG] supervisor with
      | 0,_ -> true
      | _,_ -> reaped := true; false
      | exception Unix.Unix_error (Unix.EINTR,_,_) -> poll () in
    Fun.protect ~finally:(fun () ->
      if not !reaped && poll () then begin
        (* The live supervisor owns the fixture's process group, including a
           renderer left behind by the failure this test is looking for. *)
        (try Unix.kill (-supervisor) Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
        (try Unix.kill supervisor Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
        let rec reap () = match Unix.waitpid [] supervisor with
          | _ -> ()
          | exception Unix.Unix_error (Unix.EINTR,_,_) -> reap () in
        reap ()
      end) (fun () ->
      let started=Mtime_clock.elapsed_ns () in
      let rec wait_result () =
        if Sys.file_exists result then true
        else if not (poll ()) || Int64.sub (Mtime_clock.elapsed_ns ()) started >= 5_000_000_000L then false
        else (Unix.sleepf 0.01; wait_result ()) in
      check bool "shutdown probe completed" true (wait_result ());
      check string "process shutdown completed" "ok" (In_channel.with_open_text result In_channel.input_all);
      let pid=In_channel.with_open_text marker In_channel.input_all |> int_of_string in
      check bool "renderer did not survive its parent" true
        (match Unix.kill pid 0 with
         | exception Unix.Unix_error (Unix.ESRCH,_,_) -> true
         | () -> false);
      check bool "renderer source and output temporaries were removed" false
        (Sys.readdir directory |> Array.exists (String.starts_with ~prefix:"pele-"))))

let renderer_shutdown_probe executable marker =
  let worker=Masc_tui_board_preview_work.create () in
  at_exit (fun () ->
    Masc_tui_board_preview_work.stop worker;
    Masc_tui_image_cache.stop_subprocesses ();
    Masc_tui_board_preview_work.await_stopped worker);
  let runner ~input:_ ~output:_ ~errors:_ =
    Masc_tui_image_cache.run_bounded ~deadline_seconds:hang_detector_deadline_seconds (Filename.quote executable) in
  let scene=Masc_tui_pele.scene ~format:Mermaid ~max_width:100 ~font_size:12
    ~now_ms:0L ~colors:None "graph TD; A-->B" in
  let _thread=Thread.create (fun () ->
    ignore (Masc_tui_board_preview_work.run worker (fun () ->
      Masc_tui_pele.render ~cache_dir:(Filename.dirname marker) ~runner scene))) () in
  let started=Mtime_clock.elapsed_ns () in
  let rec wait () =
    if Sys.file_exists marker then exit 0
    else if Int64.sub (Mtime_clock.elapsed_ns ()) started >= 3_000_000_000L then exit 1
    else (Unix.sleepf 0.01; wait ()) in
  wait ()

let renderer_shutdown_supervisor executable marker result =
  ignore (Unix.setsid ());
  let outcome = try
    let test_executable=Unix.realpath Sys.executable_name in
    let child=Unix.create_process test_executable
      [|test_executable;"--board-renderer-shutdown-probe";executable;marker|]
      Unix.stdin Unix.stdout Unix.stderr in
    let rec wait () = match Unix.waitpid [] child with
      | _,status -> status
      | exception Unix.Unix_error (Unix.EINTR,_,_) -> wait () in
    if wait ()=Unix.WEXITED 0 then "ok" else "failed"
    with _ -> "failed" in
  (try
    Out_channel.with_open_text (result ^ ".tmp") (fun out -> Out_channel.output_string out outcome);
    Sys.rename (result ^ ".tmp") result
   with Sys_error _ -> ());
  while true do Unix.sleepf 30. done

let () =
  match Array.to_list Sys.argv with
  | [_;"--board-renderer-shutdown-probe";executable;marker] -> renderer_shutdown_probe executable marker
  | [_;"--board-renderer-supervisor";executable;marker;result] ->
      renderer_shutdown_supervisor executable marker result
  | _ -> run "resource image admission" ["stored source",[
  test_case "protocol replies are not cancellation input" `Quick test_operator_protocol_boundary;
  test_case "image input retains exact read ownership" `Quick test_image_input_ownership;
  test_case "repeated remote save keeps the exact request" `Quick test_repeated_remote_save_keeps_the_exact_request;
  test_case "image results bypass a full shared mailbox" `Quick test_image_result_with_full_mailbox;
  test_case "Board post and comment diagram ownership" `Quick test_board_diagram_ownership;
  test_case "Board attachment ownership" `Quick test_board_attachment_ownership;
  test_case "displayed cell resource survives failed rereads" `Quick test_displayed_cell_resource_owner;
  test_case "displayed cell Board source survives failed rereads" `Quick test_displayed_cell_board_owner;
  test_case "displayed cell attachment treats malformed absence as unconfirmed" `Quick test_displayed_cell_attachment_uncertain;
  test_case "displayed chat cell names its unconfirmed source" `Quick test_displayed_chat_cell_is_captured;
  test_case "Memory diagram owns its keeper" `Quick test_memory_image_keeper_owner;
  test_case "Memory image freshness belongs to its captured activity" `Quick test_memory_image_source_freshness;
  test_case "Memory image keeps missing and partial observations unconfirmed" `Quick test_memory_image_source_unavailable;
  test_case "Memory pixel source retains its captured reading" `Quick test_memory_pixel_source_retention;
  test_case "Tools image owns the selected keeper" `Quick test_tools_image_keeper_owner;
  test_case "roster navigation retires a pending image worker" `Quick test_roster_view_change_retires_pending_worker;
  test_case "image completions wait for input" `Quick test_image_preview_input_barrier;
  test_case "Board SVG and original-image reader" `Quick test_board_svg_and_original_reader;
  test_case "Board worker and PNG header boundary" `Quick test_board_worker_and_png_boundary;
  test_case "inspection worker stays owned until physical return" `Quick test_physical_inspection_worker;
  test_case "queued image copy waits for physical completion" `Quick test_queued_copy_waits_for_physical_worker;
  test_case "initial vectors require their owned renderer" `Quick test_initial_vector_worker;
  test_case "vector character conversion uses the bounded runner" `Quick test_vector_character_presentation_is_bounded;
  test_case "Board Pele deadline releases worker" `Quick test_board_pele_deadline;
  test_case "Board renderer shutdown reaps child" `Quick test_renderer_shutdown;
  test_case "workspace suspension retires diagram preparation" `Quick test_suspended_diagram_preparation;
  test_case "superseded resource diagrams retain physical ownership" `Quick test_superseded_resource_diagram_worker;
  test_case "original SVG and multipart admission" `Quick test_original_admission;
  test_case "wrong pending URI" `Quick test_wrong_pending;
  test_case "failed and detached completion" `Quick test_failed_read;
  test_case "new immutable observation" `Quick test_new_observation;
  test_case "local draft and peer withdrawal" `Quick test_local_peer_loss;
  test_case "skill image ownership follows exact revision" `Quick test_skill_image_owner;
  test_case "local draft replacement and workspace" `Quick test_local_draft_replacement;
  test_case "peer resource owner" `Quick test_peer_resource_owner;
  test_case "remote URL workspace owner" `Quick test_remote_url_resource_independence;
  test_case "local sources on Resources" `Quick test_local_sources_on_resources]]
