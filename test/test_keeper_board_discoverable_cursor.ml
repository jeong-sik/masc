open Alcotest
open Masc

module KKS = Keeper_keepalive_signal
module KBAC = Keeper_board_attention_candidate

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_workspace f =
  let base_path = Filename.temp_dir "keeper-board-cursor" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      remove_tree base_path)
    (fun () ->
       ignore (Workspace.init config ~agent_name:None : string);
       Board_dispatch.reset_for_test ();
       Board.reset_global_for_test ();
       f config)
;;

let keeper_meta ?(board_interests = []) config name =
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_text (Filename.concat keepers_dir (name ^ ".toml"))
    (fun oc -> Printf.fprintf oc
      "[keeper]\ninstructions = \"Review Board evidence.\"\nsandbox_profile = \"docker\"\nboard_interests = [%s]\n"
      (String.concat ", " (List.map (Printf.sprintf "%S") board_interests)));
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  match Keeper_meta_store.read_effective_meta config name with
  | Ok (Some resolved) ->
    check (list string) "declared interests survive configuration read" board_interests
      resolved.Keeper_meta_contract.board_interests;
    resolved
  | Ok None -> fail "configured Keeper metadata missing"
  | Error detail -> fail detail
;;

let register config meta =
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  ignore
    (Keeper_registry.For_testing.register
       ~base_path:config.Workspace.base_path
       meta.Keeper_meta_contract.name
       meta)
;;

let attention_count config keeper_name =
  match KBAC.load_candidates ~base_path:config.Workspace.base_path ~keeper_name with
  | Ok candidates -> List.length candidates
  | Error detail -> fail detail
;;

let queue_length config keeper_name =
  match
    Keeper_registry_event_queue.snapshot_result
      ~base_path:config.Workspace.base_path
      keeper_name
  with
  | Ok queue -> Keeper_event_queue.length queue
  | Error detail -> fail detail
;;

let persist_discoverable signal =
  match
    Board_dispatch.create_post
      ~author:signal.Board_dispatch.author
      ~content:signal.content
      ~title:signal.title
      ~post_kind:Board.Human_post
      ~visibility:Board.Internal
      ()
  with
  | Error error -> fail (Board.show_board_error error)
  | Ok post ->
    { Board_dispatch.signal =
        { signal with post_id = Board.Post_id.to_string post.id }
    ; audience = Board.Discoverable
    }
;;

let signal ~post_id ~author ~title ~content : Board_dispatch.board_signal =
  { kind = Board_dispatch.Board_post_created
  ; post_id
  ; author
  ; title
  ; content
  ; hearth = None
  ; updated_at = Some 1.0
  }
;;

let test_initialized_lane_uses_owner_cursor () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta ~board_interests:[ "research" ] config "discoverablelane" in
  register config meta;
  ignore
    (persist_discoverable
       (signal
          ~post_id:"cursor-baseline"
          ~author:meta.name
          ~title:"cursor baseline"
          ~content:"establish a non-empty cursor"));
  ignore
    (Keeper_world_observation.collect_board_events
       ~base_path:config.base_path
       ~meta);
  let addressed =
    persist_discoverable
      (signal
         ~post_id:"discoverable"
         ~author:"external-author"
         ~title:"unaddressed research"
         ~content:"new evidence without an explicit recipient")
  in
  KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
  check int "producer candidate count" 0 (attention_count config meta.name);
  check int "direct queue count" 0 (queue_length config meta.name);
  let events, post_count, mention_count =
    Keeper_world_observation.collect_board_events
      ~base_path:config.base_path
      ~meta
  in
  check int "judgment-only replay events" 0 (List.length events);
  check int "owner cursor post count" 1 post_count;
  check int "owner cursor mention count" 0 mention_count;
  check int "owner cursor candidate count" 1 (attention_count config meta.name)
;;

let test_zero_cursor_lane_keeps_producer_fallback () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta ~board_interests:[ "research" ] config "firstcursorlane" in
  register config meta;
  let addressed =
    persist_discoverable
      (signal
         ~post_id:"before-first-cursor"
         ~author:"external-author"
         ~title:"startup evidence"
         ~content:"persist before the owner cursor initializes")
  in
  KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
  check int "fallback candidate count" 1 (attention_count config meta.name);
  let events, post_count, mention_count =
    Keeper_world_observation.collect_board_events
      ~base_path:config.base_path
      ~meta
  in
  check int "first cursor events" 0 (List.length events);
  check int "first cursor post delta" 0 post_count;
  check int "first cursor mention delta" 0 mention_count;
  check int "preserved fallback candidate" 1 (attention_count config meta.name)
;;

let test_no_interests_skips_producer_and_owner_judgment () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta config "uninterestedlane" in
  register config meta;
  let publish post_id =
    let addressed =
      persist_discoverable
        (signal ~post_id ~author:"external-author" ~title:"research"
           ~content:"new evidence without an explicit recipient")
    in
    KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
    check int "producer does not judge without interests" 0
      (attention_count config meta.name);
    let events, _, _ =
      Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta
    in
    check int "owner does not deliver without interests" 0 (List.length events);
    check int "owner does not judge without interests" 0
      (attention_count config meta.name);
    check int "no direct queue delivery" 0 (queue_length config meta.name)
  in
  publish "before-first-cursor";
  publish "after-first-cursor"
;;

let test_initialized_cursor_receives_each_discoverable_edit () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta ~board_interests:["research"] config "editobserver" in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
    ~title:"Research" ~body:"Original evidence" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  let _, cursor = Keeper_registry.get_board_cursor ~base_path:config.base_path meta.name in
  check (option string) "owner cursor is already initialized"
    (Some (Board.Post_id.to_string post.id)) cursor;
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let edit body = get (Board_dispatch.update_post ~post_id:(Board.Post_id.to_string post.id)
    ~editor:"editor" ~title:"Research" ~body ~content:body ()) in
  ignore (edit "First unaddressed revision");
  check int "initialized cursor cannot suppress first edit" 1 (attention_count config meta.name);
  ignore (edit "Second unaddressed revision");
  check int "second edit has its own candidate" 2 (attention_count config meta.name);
  ignore (edit "Second unaddressed revision");
  check int "identical edit creates no duplicate candidate" 2 (attention_count config meta.name);
  ignore (Keeper_world_observation.collect_board_events_without_advancing_cursor
    ~base_path:config.base_path ~meta);
  check int "preview does not mint an edit candidate" 2 (attention_count config meta.name);
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  check int "replayed edit converges to its live candidate" 2 (attention_count config meta.name);
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  check int "next tick does not rejudge the edit" 2 (attention_count config meta.name);
  check int "discoverable edits still require judgment before direct delivery" 0
    (queue_length config meta.name)
;;

let test_live_comment_and_catchup_share_identity_after_title_edit () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta config "commentreader" in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get (Board_dispatch.create_post ~author:"editor" ~content:"body"
      ~title:"original title" ~body:"body" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let post_id = Board.Post_id.to_string post.id in
  let comment = get (Board_dispatch.add_comment ~post_id ~author:"external"
      ~content:"@commentreader reply" ()) in
  check int "live comment is queued" 1 (queue_length config meta.name);
  ignore (get (Board_dispatch.update_post ~post_id ~editor:"editor"
      ~title:"changed title" ~body:"body" ~content:"body" ()));
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path meta.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "changed inherited title does not duplicate the same comment" 1
    (Keeper_event_queue.length queue);
  match Keeper_event_queue.to_list queue with
  | [{ payload = Keeper_event_queue.Board_signal
         {kind = Keeper_event_queue.Comment_added identity; title; _}; _ }] ->
    check string "producer comment identity remains" (Board.Comment_id.to_string comment.id)
      identity.comment_id;
    check string "first accepted payload remains unchanged" "original title" title
  | _ -> fail "expected the original queued comment"
;;

let test_queued_edits_keep_their_captured_content () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta config "editreader" in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
    ~title:"Original title" ~body:"Original evidence" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let edit title body = get (Board_dispatch.update_post ~post_id:(Board.Post_id.to_string post.id)
    ~editor:"editor" ~title ~body ~content:body ()) in
  let first = edit "First title" "@editreader first captured body" in
  let second = edit "Second title" "@editreader second captured body" in
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path meta.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "both explicitly addressed edits are durable before consumption" 2
    (Keeper_event_queue.length queue);
  let events = Keeper_event_queue.to_list queue |> List.map (fun stimulus ->
    match Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "queued edit disappeared from projection"
    | Error _ -> fail "queued edit could not read its Board source") in
  check (list string) "queued titles keep A then B rather than rereading latest B"
    [first.title; second.title] (List.map (fun event -> event.Keeper_world_observation.title) events);
  check (list string) "queued bodies keep A then B rather than rereading latest B"
    [first.body; second.body] (List.map (fun event -> event.Keeper_world_observation.preview) events);
  check (list (float 0.)) "each projection carries its own persisted content time"
    [first.content_updated_at; second.content_updated_at]
    (List.map (fun event -> event.Keeper_world_observation.updated_at) events);
  List.iter (fun event -> check bool "projection remains a typed edit" true
    (event.Keeper_world_observation.event_kind = Keeper_world_observation.Board_post_updated)) events
;;

let () =
  run
    "keeper Board discoverable cursor"
    [ ( "producer and owner boundary"
      , [ test_case "live comment and catchup share identity after title edit" `Quick
            test_live_comment_and_catchup_share_identity_after_title_edit
        ; test_case "initialized cursor receives each discoverable edit" `Quick
            test_initialized_cursor_receives_each_discoverable_edit
        ; test_case "queued edits preserve captured content before consumption" `Quick
            test_queued_edits_keep_their_captured_content
        ; test_case
            "initialized lane defers to owner cursor"
            `Quick
            test_initialized_lane_uses_owner_cursor
        ; test_case
            "zero cursor lane keeps durable producer fallback"
            `Quick
            test_zero_cursor_lane_keeps_producer_fallback
        ; test_case
            "no interests skips producer and owner judgment"
            `Quick
            test_no_interests_skips_producer_and_owner_judgment
        ] )
    ]
;;
