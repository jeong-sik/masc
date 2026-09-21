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

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ])
  with
  | Ok meta -> meta
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
  let meta = keeper_meta "discoverablelane" in
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
  let meta = keeper_meta "firstcursorlane" in
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

let () =
  run
    "keeper Board discoverable cursor"
    [ ( "producer and owner boundary"
      , [ test_case
            "initialized lane defers to owner cursor"
            `Quick
            test_initialized_lane_uses_owner_cursor
        ; test_case
            "zero cursor lane keeps durable producer fallback"
            `Quick
            test_zero_cursor_lane_keeps_producer_fallback
        ] )
    ]
;;
