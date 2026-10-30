open Alcotest
open Masc

(* The Keeper board scan replays the audience a post or comment recorded when
   it was written. It does not read an address back out of the text.

   Each post or comment below is written through the real write path and then
   has its stored row edited, so that the recorded audience disagrees with what
   its own text would give. A scan that still read the text delivers to a
   different set than the one asserted here. *)

module KBA = Keeper_board_audience

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

(* The Board store lives under [MASC_BASE_PATH]; pointing it at the workspace
   keeps its JSONL file inside the directory this test removes. *)
let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-board-recorded" "" in
  (* A variable cannot be unset from OCaml, so one that was unset is put back
     empty, which the base path reader takes as unset. *)
  let previous_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Unix.putenv "MASC_BASE_PATH" (Option.value previous_base_path ~default:"");
      (* A removal that fails must not hide the failure of the test. *)
      try remove_tree base_path with Sys_error _ | Unix.Unix_error _ -> ())
    (fun () ->
       ignore (Workspace.init config ~agent_name:None : string);
       Board_dispatch.reset_for_test ();
       Board.reset_global_for_test ();
       Board_dispatch.init_jsonl ();
       f config)
;;

let register_keeper config name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_text (Filename.concat keepers_dir (name ^ ".toml")) (fun oc ->
    output_string
      oc
      "[keeper]\n\
       instructions = \"Review Board evidence.\"\n\
       sandbox_profile = \"docker\"\n\
       sandbox_image = \"base\"\n");
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail detail);
  let resolved =
    match Keeper_meta_store.read_effective_meta config name with
    | Ok (Some resolved) -> resolved
    | Ok None -> fail "configured Keeper metadata missing"
    | Error detail -> fail detail
  in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path:config.Workspace.base_path
       resolved.Keeper_meta_contract.name
       resolved);
  resolved
;;

let get = function
  | Ok value -> value
  | Error error -> fail (Board.show_board_error error)
;;

let post_id (post : Board.post) = Board.Post_id.to_string post.id

let reload_board () =
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ()
;;

(* Rewrites the stored row of each listed id in the file at [path] so that it
   records the given audience wire (none for [None]), then reloads the store
   from the files. *)
let record_audiences ~path edits =
  let rows =
    In_channel.with_open_text path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let edited row =
    match Yojson.Safe.from_string row with
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) ->
         (match List.assoc_opt id edits with
          | None -> row
          | Some audience ->
            let others = List.remove_assoc "audience" fields in
            let fields =
              match audience with
              | Some audience -> ("audience", audience) :: others
              | None -> others
            in
            Yojson.Safe.to_string (`Assoc fields))
       | _ -> row)
    | _ -> fail "a stored row is not a JSON object"
  in
  Out_channel.with_open_text path (fun oc ->
    List.iter (fun row -> output_string oc (edited row ^ "\n")) rows);
  reload_board ()
;;

let targets_wire names =
  `Assoc [ "kind", `String "targets"; "targets", `List (List.map (fun n -> `String n) names) ]
;;

let board_event_failures () =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ObservationQueryFailures)
    ~labels:[ "operation", Runtime_observation_query_operation.(to_label Board_events) ]
    ()
;;

let queued_post_ids config name =
  match
    Keeper_registry_event_queue.snapshot_result ~base_path:config.Workspace.base_path name
  with
  | Ok queue ->
    Keeper_event_queue.to_list queue
    |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
  | Error detail -> fail detail
;;

let queued_comment_ids config name =
  match
    Keeper_registry_event_queue.snapshot_result ~base_path:config.Workspace.base_path name
  with
  | Ok queue ->
    Keeper_event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Board_signal
          { kind = Keeper_event_queue.Comment_added identity; _ } ->
        Some identity.comment_id
      | _ -> None)
  | Error detail -> fail detail
;;

let test_scan_follows_the_recorded_audience () =
  with_workspace
  @@ fun config ->
  let meta = register_keeper config "scanreader" in
  let create content =
    get
      (Board_dispatch.create_post
         ~author:"external-author"
         ~content
         ~title:"note"
         ~body:content
         ~visibility:Board.Internal
         ~post_kind:Board.Human_post
         ())
  in
  (* Text names the lane, row has no audience. The scan reads posts oldest
     first, so it meets this one before the other two. *)
  let unrecorded = create "@scanreader older row" in
  Unix.sleepf 0.01;
  (* Text names nobody, record names the lane. *)
  let recorded_target = create "plain note" in
  Unix.sleepf 0.01;
  (* Text names the lane, record is open to discovery. *)
  let recorded_open = create "@scanreader please look" in
  record_audiences
    ~path:(Board.persist_path ())
    [ post_id recorded_target, Some (targets_wire [ "scanreader" ])
    ; post_id recorded_open, Some (`Assoc [ "kind", `String "discoverable" ])
    ; post_id unrecorded, None
    ];
  let audience_of post =
    KBA.of_post (get (Board_dispatch.get_post ~post_id:(post_id post)))
  in
  check
    bool
    "the edited rows reload with the audiences they were given"
    true
    (match audience_of recorded_target, audience_of recorded_open, audience_of unrecorded with
     | Ok (KBA.Targets [ _ ]), Ok KBA.Discoverable, Error KBA.Audience_not_recorded -> true
     | _ -> false);
  (* A cursor just past zero puts all three posts after it. *)
  Keeper_registry.set_board_cursor
    ~base_path:config.Workspace.base_path
    meta.Keeper_meta_contract.name
    1.0
    None;
  let failures_before = board_event_failures () in
  let _events, post_count, mention_count =
    Keeper_world_observation.collect_board_events
      ~base_path:config.Workspace.base_path
      ~meta
  in
  check int "all three posts are replayed" 3 post_count;
  check int "one delivery counts as a mention" 1 mention_count;
  check
    (list string)
    "the walk goes on past the unrecorded post and delivers only the post whose record names the lane"
    [ post_id recorded_target ]
    (queued_post_ids config meta.Keeper_meta_contract.name);
  check
    (float 0.)
    "the post without a recorded audience is counted as a failure"
    1.0
    (board_event_failures () -. failures_before)
;;

(* A post written before the audience was recorded. The scan reaches it only
   through a signal that is newer than its cursor. A new comment or vote moves
   the post's [updated_at] and lists it again, but the post's own signal needs
   a content time past the cursor, so the missing audience is never read and
   nothing is counted as a failure. *)
let test_an_old_post_without_an_audience_costs_nothing () =
  with_workspace
  @@ fun config ->
  let meta = register_keeper config "scanreader" in
  let name = meta.Keeper_meta_contract.name in
  let base_path = config.Workspace.base_path in
  let old_post =
    get
      (Board_dispatch.create_post
         ~author:"external-author"
         ~content:"@scanreader older row"
         ~title:"note"
         ~body:"@scanreader older row"
         ~visibility:Board.Internal
         ~post_kind:Board.Human_post
         ())
  in
  record_audiences ~path:(Board.persist_path ()) [ post_id old_post, None ];
  let scan () = Keeper_world_observation.collect_board_events ~base_path ~meta in
  let _events, listed, _mentions = scan () in
  check int "the first scan only starts the cursor" 0 listed;
  Unix.sleepf 0.01;
  let failures_before = board_event_failures () in
  ignore
    (get
       (Board_dispatch.add_comment
          ~post_id:(post_id old_post)
          ~author:"external-author"
          ~content:"@scanreader please look"
          ()));
  let _events, listed, mentions = scan () in
  check int "a new comment lists the old post again" 1 listed;
  check int "the comment is delivered from its own audience" 1 mentions;
  check (list string) "the delivery belongs to the old post" [ post_id old_post ]
    (queued_post_ids config name);
  Unix.sleepf 0.01;
  ignore
    (get
       (Board_dispatch.vote
          ~voter:"someone"
          ~post_id:(post_id old_post)
          ~direction:Board.Up));
  let _events, listed, mentions = scan () in
  check int "a vote lists the old post again" 1 listed;
  check int "a vote delivers nothing" 0 mentions;
  check
    (float 0.)
    "neither scan counted the missing audience as a failure"
    0.0
    (board_event_failures () -. failures_before)
;;

(* When the missing audience is read, it is the post's own signal that is
   refused. The comments on the same post are separate signals and still go
   through. *)
let test_a_post_without_an_audience_does_not_stop_its_comments () =
  with_workspace
  @@ fun config ->
  let meta = register_keeper config "scanreader" in
  let post =
    get
      (Board_dispatch.create_post
         ~author:"external-author"
         ~content:"plain note"
         ~title:"note"
         ~body:"plain note"
         ~visibility:Board.Internal
         ~post_kind:Board.Human_post
         ())
  in
  ignore
    (get
       (Board_dispatch.add_comment
          ~post_id:(post_id post)
          ~author:"external-author"
          ~content:"@scanreader please look"
          ()));
  record_audiences ~path:(Board.persist_path ()) [ post_id post, None ];
  Keeper_registry.set_board_cursor
    ~base_path:config.Workspace.base_path
    meta.Keeper_meta_contract.name
    1.0
    None;
  let failures_before = board_event_failures () in
  let _events, listed, mentions =
    Keeper_world_observation.collect_board_events
      ~base_path:config.Workspace.base_path
      ~meta
  in
  check int "the post is replayed once" 1 listed;
  check int "its comment is delivered" 1 mentions;
  check
    (float 0.)
    "the post's own signal is counted as a failure"
    1.0
    (board_event_failures () -. failures_before)
;;

let comment_id (comment : Board.comment) = Board.Comment_id.to_string comment.id

let test_scan_follows_the_recorded_comment_audience () =
  with_workspace
  @@ fun config ->
  let meta = register_keeper config "scanreader" in
  let post =
    get
      (Board_dispatch.create_post
         ~author:"scanreader"
         ~content:"thread root"
         ~title:"thread"
         ~body:"thread root"
         ~visibility:Board.Internal
         ~post_kind:Board.Human_post
         ())
  in
  let comment content =
    get
      (Board_dispatch.add_comment
         ~post_id:(post_id post)
         ~author:"external-author"
         ~content
         ())
  in
  (* Text names nobody, record names the lane. *)
  let recorded_target = comment "plain follow-up" in
  (* Text names the lane, record names someone else. *)
  let recorded_elsewhere = comment "@scanreader please look" in
  (* Text names the lane, row has no audience. *)
  let unrecorded = comment "@scanreader older row" in
  (* Text names nobody, row has no audience.  The lane wrote the post, so a
     scan that guessed "the thread" for a missing record would deliver it
     without reading any text. *)
  let unrecorded_plain = comment "older row without an address" in
  (* Text names nobody, record is the thread: the lane wrote the post, so it
     belongs to this thread and the comment reaches it. *)
  let recorded_thread = comment "plain follow-up two" in
  record_audiences
    ~path:(Board.comments_path ())
    [ comment_id recorded_target, Some (targets_wire [ "scanreader" ])
    ; comment_id recorded_elsewhere, Some (targets_wire [ "someone-else" ])
    ; comment_id recorded_thread, Some (`Assoc [ "kind", `String "thread_participants" ])
    ; comment_id unrecorded, None
    ; comment_id unrecorded_plain, None
    ];
  let audience_of comment =
    match Board_dispatch.read_comments ~post_id:(post_id post) with
    | Ok comments ->
      (match
         List.find_opt (fun c -> String.equal (comment_id c) (comment_id comment)) comments
       with
       | Some reloaded -> KBA.of_comment reloaded
       | None -> fail "comment lost across reload")
    | Error _ -> fail "comments unreadable after reload"
  in
  check
    bool
    "the edited rows reload with the audiences they were given"
    true
    (match
       ( audience_of recorded_target
       , audience_of recorded_elsewhere
       , audience_of recorded_thread
       , audience_of unrecorded
       , audience_of unrecorded_plain )
     with
     | ( Ok (KBA.Targets [ _ ])
       , Ok (KBA.Targets [ _ ])
       , Ok KBA.Thread_participants
       , Error KBA.Audience_not_recorded
       , Error KBA.Audience_not_recorded ) -> true
     | _ -> false);
  Keeper_registry.set_board_cursor
    ~base_path:config.Workspace.base_path
    meta.Keeper_meta_contract.name
    1.0
    None;
  let failures_before = board_event_failures () in
  let _events, post_count, mention_count =
    Keeper_world_observation.collect_board_events
      ~base_path:config.Workspace.base_path
      ~meta
  in
  check int "the thread is replayed once" 1 post_count;
  check int "one delivery counts as a mention" 1 mention_count;
  (* The two comments the record reaches to the lane are delivered: the one
     that names it, and the one on a thread it wrote.  The comment recorded for
     someone else and the comment without a record are not, although the text of
     both names the lane. *)
  check
    (list string)
    "only the comments whose record reaches the lane are delivered"
    (List.sort String.compare [ comment_id recorded_target; comment_id recorded_thread ])
    (List.sort
       String.compare
       (queued_comment_ids config meta.Keeper_meta_contract.name));
  check
    (float 0.)
    "each comment without a recorded audience is counted as a failure"
    2.0
    (board_event_failures () -. failures_before)
;;

let () =
  run
    "keeper Board recorded audience"
    [ ( "scan"
      , [ test_case
            "follows the recorded audience, not the text"
            `Quick
            test_scan_follows_the_recorded_audience
        ; test_case
            "an old post without an audience costs nothing"
            `Quick
            test_an_old_post_without_an_audience_costs_nothing
        ; test_case
            "a post without an audience does not stop its comments"
            `Quick
            test_a_post_without_an_audience_does_not_stop_its_comments
        ; test_case
            "follows the recorded comment audience, not the text"
            `Quick
            test_scan_follows_the_recorded_comment_audience
        ] )
    ]
;;
