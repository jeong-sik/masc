(** Who counts as a participant in a board thread.

    [check_self_thread_status] decides whether the [Thread_participants]
    audience reaches a given keeper. It used to consult only the comment
    stream, so the author of a post was not a participant in its own thread: a
    keeper that raised a blocker as a post scored [`Never] and every reply was
    dropped before it reached the lane.

    Measured live on 2026-07-28: a keeper posted a blocker at 10:06, an
    operator answered on the post, no stimulus was produced, and the keeper
    went on calling [keeper_tasks_list] 547 times over 4h52m receiving `[]`
    each time. Re-sending the same answer with an explicit [@mention] — which
    routes through [Targets] and never reads participation — woke it in 60s.

    This focused suite exercises both the snapshot decision and the typed
    [wake_reason] producer boundary. The broader
    [test_keeper_keepalive_helpers] board fixtures currently cannot build a
    keeper meta (`meta_of_json failed: fields outside the current schema`) and
    fail identically on origin/main. *)

open Alcotest
open Masc
module Board_signal = Masc.Keeper_world_observation_board_signal

let keeper_ids name =
  List.filter_map Keeper_identity.Keeper_id.of_string [ name ]
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String ("keeper-" ^ name)
        ; "trace_id", `String ("trace-" ^ name)
        ; "autoboot_enabled", `Bool false
        ])
  with
  | Ok meta -> meta
  | Error message -> fail ("meta fixture rejected: " ^ message)
;;

let create_post ~author ~title =
  match
    Board_dispatch.create_post
      ~author
      ~content:"thread body"
      ~title
      ~post_kind:Board.Human_post
      ~visibility:Board.Internal
      ()
  with
  | Error error -> fail (Board.show_board_error error)
  | Ok post -> Board.Post_id.to_string post.id
;;

let comment ~post_id ~author ~content =
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Error error -> fail (Board.show_board_error error)
  | Ok _comment -> ()
;;

let expect_new_external ~label ~count ~author = function
  | Board_signal.Available (`New_external (actual_count, actual_author, _)) ->
    check int (label ^ ": count") count actual_count;
    check string (label ^ ": author") author actual_author
  | Board_signal.Unavailable unavailable ->
    failf "%s: board read unavailable: %s" label
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available `Never -> failf "%s: expected external activity, got never" label
  | Board_signal.Available `No_new_external ->
    failf "%s: expected external activity, got no new activity" label
;;

let expect_no_new_external ~label = function
  | Board_signal.Available `No_new_external -> ()
  | Board_signal.Unavailable unavailable ->
    failf "%s: board read unavailable: %s" label
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available `Never -> failf "%s: expected participation, got never" label
  | Board_signal.Available (`New_external _) ->
    failf "%s: expected no new activity, got external activity" label
;;

let expect_never ~label = function
  | Board_signal.Available `Never -> ()
  | Board_signal.Unavailable unavailable ->
    failf "%s: board read unavailable: %s" label
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available `No_new_external ->
    failf "%s: expected non-participation, got participation" label
  | Board_signal.Available (`New_external _) ->
    failf "%s: expected non-participation, got external activity" label
;;

let expect_reason ~label expected = function
  | Board_signal.Available (Some actual) ->
    check bool label true (actual = expected)
  | Board_signal.Unavailable unavailable ->
    failf "%s: board read unavailable: %s" label
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available None -> failf "%s: expected a wake reason, got none" label
;;

let expect_no_reason ~label = function
  | Board_signal.Available None -> ()
  | Board_signal.Unavailable unavailable ->
    failf "%s: board read unavailable: %s" label
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available (Some reason) ->
    failf "%s: unexpected wake reason %s" label
      (Board_signal.wake_reason_label reason)
;;

let comment_signal ~post_id ~author : Board_dispatch.board_signal =
  { kind = Board_dispatch.Board_comment_added
  ; post_id
  ; author
  ; title = "thread"
  ; content = "thread update"
  ; hearth = None
  ; updated_at = None
  }
;;

let reaction_signal ~post_id ~author : Board_dispatch.board_signal =
  { kind =
      Board_dispatch.Board_reaction_changed
        { target_type = Board.Reaction_post
        ; target_id = post_id
        ; user_id = author
        ; emoji = "eyes"
        ; reacted = true
        }
  ; post_id
  ; author
  ; title = "thread"
  ; content = ""
  ; hearth = None
  ; updated_at = None
  }
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_board_thread_participation_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> cleanup_dir (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

(* The board store lazily initializes under an Eio context and resolves its
   persist path from MASC_BASE_PATH, which a production guard refuses to let
   fall back to $HOME. Each case gets its own empty store so post and comment
   counts are exact. *)
let with_board f () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  let previous_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  let previous_base_path_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Board_dispatch.reset_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Unix.putenv "MASC_BASE_PATH" (Option.value previous_base_path ~default:"");
      Unix.putenv
        "MASC_BASE_PATH_INPUT"
        (Option.value previous_base_path_input ~default:"");
      cleanup_dir base)
    f
;;

(* The case that was broken: authorship is the keeper's only contribution. *)
let test_post_author_is_a_participant () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved - assignment withdrawn";
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_new_external
       ~label:"reply to my own post is new external activity"
       ~count:1
       ~author:"operator"
;;

(* Authorship alone, with nobody having answered yet, is participation without
   news — not [`Never]. The distinction matters: [`Never] is what the replay
   path re-surfaces as unseen, so a keeper used to be shown its own posts. *)
let test_own_post_without_replies_is_participation_without_news () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_no_new_external ~label:"my own unanswered post is not news to me"
;;

(* A keeper with no post and no comment in the thread stays a non-participant;
   widening participation must not make every keeper a participant in
   everything. *)
let test_uninvolved_keeper_is_not_a_participant () =
  let self_ids = keeper_ids "bystander" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved";
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_never ~label:"no post and no comment means no participation"
;;

(* The pre-existing comment route must keep working unchanged. *)
let test_commenter_is_still_a_participant () =
  let self_ids = keeper_ids "rondo" in
  let post_id = create_post ~author:"external-author" ~title:"thread" in
  comment ~post_id ~author:"rondo" ~content:"rondo was here";
  comment ~post_id ~author:"operator" ~content:"follow up";
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_new_external
       ~label:"reply after my comment is new external activity"
       ~count:1
       ~author:"operator"
;;

(* The baseline is the keeper's LATEST contribution across both kinds. A reply
   older than the keeper's own comment must not re-trigger, even though the
   keeper also authored the post. *)
let test_baseline_is_the_latest_self_contribution () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"first answer";
  comment ~post_id ~author:"verifier" ~content:"acknowledged";
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_no_new_external ~label:"nothing external since my own last word";
  comment ~post_id ~author:"operator" ~content:"second answer";
  Board_signal.check_self_thread_status ~self_ids ~post_id
  |> expect_new_external
       ~label:"a later external reply re-triggers"
       ~count:1
       ~author:"operator"
;;

let test_missing_post_reports_atomic_snapshot_operation () =
  match
    Board_signal.read_self_thread_snapshot
      ~self_ids:(keeper_ids "verifier")
      ~post_id:"never-existed"
  with
  | Board_signal.Unavailable
      { operation = Board_signal.Get_post_and_comments
      ; error = Board.Post_not_found _
      ; _
      } ->
    ()
  | Board_signal.Unavailable unavailable ->
    failf "unexpected unavailable operation: %s"
      (Board_signal.unavailable_to_string unavailable)
  | Board_signal.Available _ -> fail "missing post unexpectedly produced a snapshot"
;;

let test_cursor_scan_snapshots_post_and_comments_together () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  let cursor_ts, cursor_post_id = Board_dispatch.current_post_cursor () in
  let cursor_post_id = Option.value cursor_post_id ~default:"" in
  comment ~post_id ~author:"operator" ~content:"arrived after discovery";
  let snapshots =
    Board_dispatch.list_post_thread_snapshots_after_cursor
      ~after:(cursor_ts, cursor_post_id)
      ~limit:Board.Limits.cursor_snapshot_batch_size
  in
  match snapshots with
  | [ (post, comments) ] ->
    check bool "comment strictly advances the post cursor" true
      (post.updated_at > cursor_ts);
    check string "snapshot carries the updated post"
      post_id
      (Board.Post_id.to_string post.id);
    check int "snapshot carries the matching comment stream" 1
      (List.length comments);
    Board_signal.thread_status_of_snapshot ~self_ids ~post ~comments
    |> fun status ->
    expect_new_external
      ~label:"atomic cursor snapshot sees the reply"
      ~count:1
      ~author:"operator"
      (Board_signal.Available status)
  | _ ->
    failf "expected one atomic post/thread snapshot, got %d"
      (List.length snapshots)
;;

let test_cursor_scan_stops_before_uncommitted_comment () =
  let store = Board.create_store () in
  let post =
    match
      Board.create_post
        store
        ~author:"verifier"
        ~content:"thread body"
        ~title:"blocker"
        ~post_kind:Board.Human_post
        ()
    with
    | Error error -> fail (Board.show_board_error error)
    | Ok post -> post
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board.add_comment
       store
       ~post_id
       ~author:"operator"
       ~content:"staged reply"
       ()
   with
   | Error error -> fail (Board.show_board_error error)
   | Ok _comment -> ());
  check bool "successful comment clears its commit fence" false
    (Hashtbl.mem store.pending_comment_commits post_id);
  Hashtbl.replace store.pending_comment_commits post_id 1;
  let after = post.updated_at, post_id in
  check int "uncommitted post is a cursor barrier" 0
    (List.length
       (Board.list_post_thread_snapshots_after_cursor
          store
          ~after
          ~limit:Board.Limits.cursor_snapshot_batch_size));
  Hashtbl.remove store.pending_comment_commits post_id;
  check int "durably settled post is visible on the next scan" 1
    (List.length
       (Board.list_post_thread_snapshots_after_cursor
          store
          ~after
          ~limit:Board.Limits.cursor_snapshot_batch_size))
;;

let test_cursor_replay_delivers_reply_to_post_author () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let meta = keeper_meta "verifier" in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path
       meta.Keeper_meta_contract.name
       meta);
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister
        ~base_path
        meta.Keeper_meta_contract.name)
    (fun () ->
       let post_id =
         create_post
           ~author:meta.Keeper_meta_contract.agent_name
           ~title:"blocker"
       in
       let initial_events, initial_count, initial_mentions =
         Keeper_world_observation.collect_board_events ~base_path ~meta
       in
       check int "initial head produces no replay event" 0
         (List.length initial_events);
       check int "initial head is not counted as new" 0 initial_count;
       check int "initial head has no replay mention" 0 initial_mentions;
       comment ~post_id ~author:"operator" ~content:"resolved";
       let events, new_count, mention_count =
         Keeper_world_observation.collect_board_events ~base_path ~meta
       in
       check int "reply to authored post is replayed once" 1
         (List.length events);
       check int "reply to authored post is counted once" 1 new_count;
       check int "plain reply does not invent a mention" 0 mention_count;
       match events with
       | [ event ] ->
         check bool "cursor replay preserves participation" true
           event.self_participated;
         check int "cursor replay projects one external reply" 1
           event.new_external_since;
         check string "cursor replay keeps the authored post id"
           post_id
           event.post_id
       | _ -> fail "expected exactly one cursor replay event")
;;

let test_comment_wakes_post_author () =
  let meta = keeper_meta "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved";
  Board_signal.wake_reason
    ~meta
    ~signal:(comment_signal ~post_id ~author:"operator")
  |> expect_reason
       ~label:"producer returns thread reply reason"
       Board_signal.Thread_reply_after_self_activity
;;

let test_comment_stimulus_projects_atomic_participation () =
  let meta = keeper_meta "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved";
  let signal = comment_signal ~post_id ~author:"operator" in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 200.0
    ; payload =
        Keeper_event_queue.Board_signal
          (Board_signal.board_stimulus_of_board_signal signal)
    }
  in
  match Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
  | Error unavailable ->
    fail ("projection unavailable: " ^ Board_signal.unavailable_to_string unavailable)
  | Ok None -> fail "Board comment stimulus produced no pending event"
  | Ok (Some event) ->
    check bool "post authorship is projected as participation" true
      event.self_participated;
    check int "one external reply is projected" 1 event.new_external_since;
    check (option string) "latest external author is projected"
      (Some "operator")
      event.latest_external_author;
    check string "post metadata comes from the same snapshot"
      "blocker"
      event.title
;;

let test_external_reaction_wakes_post_author () =
  let meta = keeper_meta "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  Board_signal.wake_reason
    ~meta
    ~signal:(reaction_signal ~post_id ~author:"operator")
  |> expect_reason
       ~label:"external reaction reaches post author"
       Board_signal.Reaction_after_self_activity
;;

let test_own_reaction_does_not_wake () =
  let meta = keeper_meta "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  Board_signal.wake_reason
    ~meta
    ~signal:(reaction_signal ~post_id ~author:"verifier")
  |> expect_no_reason ~label:"self reaction is ignored"
;;

let test_external_reaction_wakes_commenter () =
  let meta = keeper_meta "verifier" in
  let post_id = create_post ~author:"operator" ~title:"thread" in
  comment ~post_id ~author:"verifier" ~content:"participating";
  Board_signal.wake_reason
    ~meta
    ~signal:(reaction_signal ~post_id ~author:"operator")
  |> expect_reason
       ~label:"external reaction reaches commenter"
       Board_signal.Reaction_after_self_activity
;;

let test_external_reaction_ignores_uninvolved_keeper () =
  let meta = keeper_meta "bystander" in
  let post_id = create_post ~author:"operator" ~title:"thread" in
  Board_signal.wake_reason
    ~meta
    ~signal:(reaction_signal ~post_id ~author:"operator")
  |> expect_no_reason ~label:"external reaction ignores uninvolved keeper"
;;

let () =
  run
    "keeper_board_thread_participation"
    [ ( "post_author"
      , [ test_case "post author is a thread participant" `Quick
            (with_board test_post_author_is_a_participant)
        ; test_case "own post without replies is participation without news" `Quick
            (with_board test_own_post_without_replies_is_participation_without_news)
        ] )
    ; ( "boundaries"
      , [ test_case "uninvolved keeper is not a participant" `Quick
            (with_board test_uninvolved_keeper_is_not_a_participant)
        ; test_case "commenter is still a participant" `Quick
            (with_board test_commenter_is_still_a_participant)
        ; test_case "baseline is the latest self contribution" `Quick
            (with_board test_baseline_is_the_latest_self_contribution)
        ] )
    ; ( "atomic_snapshot"
      , [ test_case "missing post reports atomic snapshot operation" `Quick
            (with_board test_missing_post_reports_atomic_snapshot_operation)
        ; test_case "cursor scan snapshots post and comments together" `Quick
            (with_board test_cursor_scan_snapshots_post_and_comments_together)
        ; test_case "cursor scan stops before uncommitted comment" `Quick
            (with_board test_cursor_scan_stops_before_uncommitted_comment)
        ; test_case "cursor replay delivers reply to post author" `Quick
            (with_board test_cursor_replay_delivers_reply_to_post_author)
        ] )
    ; ( "wake_reason"
      , [ test_case "comment wakes post author" `Quick
            (with_board test_comment_wakes_post_author)
        ; test_case "comment stimulus projects atomic participation" `Quick
            (with_board test_comment_stimulus_projects_atomic_participation)
        ; test_case "external reaction wakes post author" `Quick
            (with_board test_external_reaction_wakes_post_author)
        ; test_case "own reaction does not wake" `Quick
            (with_board test_own_reaction_does_not_wake)
        ; test_case "external reaction wakes commenter" `Quick
            (with_board test_external_reaction_wakes_commenter)
        ; test_case "external reaction ignores uninvolved keeper" `Quick
            (with_board test_external_reaction_ignores_uninvolved_keeper)
        ] )
    ]
;;
