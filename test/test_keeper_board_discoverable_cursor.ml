open Alcotest
open Masc

module KKS = Keeper_keepalive_signal
module KBAC = Keeper_board_attention_candidate

(* These tests pin how a comment or an edit reaches the cursor, not who is
   declared: every name with the shape of a Board identity stands for itself.
   Which names are declared is pinned in test_board_recipient_resolution. *)
let get_created = function
  | Ok value -> value
  | Error failure ->
    Alcotest.fail (Masc.Board.Post_publication_failure.to_string failure)

let every_name_declared =
  Recipient_lookup.make (fun candidate ->
    Ok
      (Result.to_option
         (Board.Agent_id.parse (Recipient_lookup.Candidate.to_string candidate))))
;;

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

let with_temp_workspace ?(recipient_lookup = every_name_declared) f =
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
       Result.get_ok (Board_dispatch.init_jsonl
         ~base_path
         ~recipient_lookup ());
       f config)
;;

let keeper_meta ?(board_interests = []) ?(mention_targets = []) config name =
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
      "[keeper]\ninstructions = \"Review Board evidence.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nboard_interests = [%s]\nmention_targets = [%s]\n"
      (String.concat ", " (List.map (Printf.sprintf "%S") board_interests))
      (String.concat ", " (List.map (Printf.sprintf "%S") mention_targets)));
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
  | Error error -> fail (Board.Post_publication_failure.to_string error)
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

let test_direct_readership_precedes_delivery_and_judgment () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let reader = keeper_meta ~board_interests:["research"] ~mention_targets:["reader-alias"] config "reader" in
  let outsider = keeper_meta ~board_interests:["research"] config "outsider" in
  register config reader;
  register config outsider;
  let post = get_created (Board_dispatch.create_post ~author:"writer"
    ~content:"@reader-alias research secret" ~visibility:Board.Direct ~post_kind:Board.Human_post ()) in
  let signal = signal ~post_id:(Board.Post_id.to_string post.id) ~author:"writer"
      ~title:post.title ~content:post.body in
  List.iter (fun audience ->
    check bool "a nonreader cannot receive or judge a private signal" true
      (match Keeper_board_audience.route_for_keeper ~audience ~meta:outsider ~signal with
       | Keeper_world_observation_board_signal.Available Keeper_board_audience.Ignore -> true
       | Keeper_world_observation_board_signal.Available _
       | Keeper_world_observation_board_signal.Unavailable _ -> false))
    [Keeper_board_audience.Broadcast; Discoverable; Targets [Option.get (Keeper_identity.Keeper_id.of_string "outsider")]];
  check bool "the recipient's declared alias still receives the post" true
    (match Keeper_board_audience.route_for_keeper
       ~audience:(Targets [Option.get (Keeper_identity.Keeper_id.of_string "reader-alias")]) ~meta:reader ~signal with
     | Keeper_world_observation_board_signal.Available (Keeper_board_audience.Deliver _) -> true
     | Keeper_world_observation_board_signal.Available _
     | Keeper_world_observation_board_signal.Unavailable _ -> false);
  let addressed : Board_dispatch.addressed_board_signal = {signal; audience=Board.Discoverable} in
  KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
  check int "a forced discoverable signal creates no nonreader candidate" 0 (attention_count config outsider.name);
  let retained = KBAC.of_board_signal ~meta:outsider ~recorded_at:post.created_at addressed in
  check bool "a retained Direct candidate never invokes semantic judgment" true
    (match KBAC.candidate_parent_visibility_filter retained with
     | Ok KBAC.Skip_non_discoverable_comment -> true
     | Ok KBAC.Keep_discoverable_comment | Error _ -> false)
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

let test_replayed_comment_discovery_respects_parent_visibility () =
  Eio_main.run @@ fun _env ->
  List.iter
    (fun (label, visibility, expected_candidates) ->
       let alias_declared = ref false in
       let recipient_lookup =
         Recipient_lookup.make (fun candidate ->
           let name = Recipient_lookup.Candidate.to_string candidate in
           if String.equal name "latealias" && not !alias_declared
           then Ok None
           else Ok (Result.to_option (Board.Agent_id.parse name))) in
       with_temp_workspace ~recipient_lookup @@ fun config ->
       let meta = keeper_meta ~board_interests:[ "research" ] config "replaylane" in
       register config meta;
       let poster = keeper_meta config "thread-author" in
       register config poster;
       Keeper_registry.set_board_cursor ~base_path:config.base_path meta.name 1.0 None;
       Keeper_registry.set_board_cursor ~base_path:config.base_path poster.name 1.0 None;
       (* All posts have a different explicit recipient, so only the unaddressed
          comment can produce a candidate for this lane. *)
       let post =
         match Board_dispatch.create_post
                 ~author:"thread-author" ~title:"thread"
                 ~content:"@thread-owner discussion" ~visibility
                 ~post_kind:Board.Human_post () with
         | Ok post -> post
         | Error error -> fail (Board.Post_publication_failure.to_string error) in
       let post_id = Board.Post_id.to_string post.id in
       let comment =
         match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"comment-author"
                 ~content:"@latealias new research" () with
         | Ok comment -> comment
         | Error error -> fail (Board.show_board_error error) in
       check bool (label ^ ": unresolved name stored as thread audience") true
         (comment.audience = Some Board.Thread_participants);
       alias_declared := true;
       let meta = keeper_meta ~board_interests:[ "research" ]
           ~mention_targets:[ "latealias" ] config "replaylane" in
       check (list string) (label ^ ": alias registered before replay")
         [ "latealias" ] meta.mention_targets;
       let count_comment () =
         match KBAC.load_candidates ~base_path:config.base_path ~keeper_name:meta.name with
         | Error detail -> fail detail
         | Ok candidates ->
           List.filter (fun (candidate : KBAC.candidate) ->
             match candidate.signal.kind with
             | Board_dispatch.Board_comment_added identity ->
               String.equal (Board.Comment_id.to_string identity.comment_id)
                 (Board.Comment_id.to_string comment.id)
             | Board_dispatch.Board_post_created | Board_dispatch.Board_post_updated _
             | Board_dispatch.Board_reaction_changed _ | Board_dispatch.Board_vote_cast _ -> false)
             candidates
           |> List.length in
       let count_poster_reply () =
         match Keeper_registry_event_queue.snapshot_result
                 ~base_path:config.base_path poster.name with
         | Error detail -> fail detail
         | Ok queue ->
           Keeper_event_queue.to_list queue
           |> List.filter (fun (entry : Keeper_event_queue.stimulus) ->
             match entry.payload with
             | Keeper_event_queue.Board_signal
                 { kind = Keeper_event_queue.Comment_added identity; _ } ->
               String.equal identity.comment_id (Board.Comment_id.to_string comment.id)
             | Keeper_event_queue.Board_signal _ | Board_routing_pending _ | Board_attention _ | Bootstrap
             | Fusion_completed _ | Schedule_due _ | Connector_attention _
             | Hitl_resolved _ | Ask_answered _ | Completion_authority_rejected _
             | Task_cancelled _ | Workspace_message _ | Delegate_completed _
             | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _
             | Task_outcome _ -> false)
           |> List.length in
       ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
       check int (label ^ ": replayed comment candidates") expected_candidates (count_comment ());
       check int (label ^ ": later alias does not directly receive replayed comment") 0
         (queue_length config meta.name);
       ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta:poster);
       check int (label ^ ": replayed comment reaches post author") 1 (count_poster_reply ());
       ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
       ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta:poster);
       check int (label ^ ": replay does not duplicate the candidate") expected_candidates (count_comment ());
       check int (label ^ ": replay does not duplicate the delivery") 1 (count_poster_reply ()))
    [ "public", Board.Public, 1
    ; "internal", Board.Internal, 1
    ; "unlisted", Board.Unlisted, 0
    ; "direct", Board.Direct, 0
    ]
;;

let test_initialized_cursor_receives_each_discoverable_edit () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta ~board_interests:["research"] config "editobserver" in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
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
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:"body"
      ~title:"original title" ~body:"body" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  ignore (Keeper_world_observation.collect_board_events ~base_path:config.base_path ~meta);
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let post_id = Board.Post_id.to_string post.id in
  let comment = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"external"
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

let test_queued_creation_keeps_content_and_audience_after_edit () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let alice = keeper_meta config "alice" in
  let bob = keeper_meta config "bob" in
  register config alice;
  register config bob;
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let original_body = "@alice original private content" in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:original_body
    ~title:"Original title" ~body:original_body ~visibility:Board.Direct
    ~post_kind:Board.Human_post ()) in
  check int "creation is queued for alice" 1 (queue_length config alice.name);
  let post_id = Board.Post_id.to_string post.id in
  let revised_body = "@alice revised private content" in
  (match Board_dispatch.update_post ~post_id:(Board.Post_id.to_string post.id)
    ~editor:"editor" ~title:"Revised title" ~body:revised_body ~content:revised_body () with
   | Ok _ -> ()
   | Error error -> fail (Board.show_board_error error));
  check int "the existing reader receives the revision" 2 (queue_length config alice.name);
  check int "an edit does not grant readership to bob" 0 (queue_length config bob.name);
  (match Board_dispatch.update_post ~post_id ~editor:"editor"
      ~title:"Rejected title" ~body:"@bob changed readers" ~content:"@bob changed readers" () with
   | Ok _ -> fail "Direct edit changed its stored readers"
   | Error error ->
     match error with
     | Board.Validation_error _ -> ()
     | Board.Invalid_id _ | Post_not_found _ | Comment_not_found _ | Io_error _
     | Already_voted _ | Already_exists _ | Unauthorized _ | Recipient_lookup_failed _ ->
       fail (Board.show_board_error error));
  check int "refused reader change creates no extra notification" 2
    (queue_length config alice.name);
  check int "refused reader change does not notify bob" 0 (queue_length config bob.name);
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok stored -> check string "refused reader change preserves the applied revision"
       revised_body stored.body
   | Error error -> fail (Board.show_board_error error));
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path alice.name with
    | Ok queue -> queue | Error detail -> fail detail in
  let event = match Keeper_event_queue.to_list queue with
    | stimulus :: _ ->
      (match Keeper_world_observation.pending_board_event_of_stimulus
        ~base_path:config.base_path ~meta:bob stimulus with
       | Ok None -> ()
       | Ok (Some _) -> fail "an old Direct stimulus exposed content to a nonreader"
       | Error unavailable ->
         fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable));
      (match Keeper_world_observation.pending_board_event_of_stimulus
        ~base_path:config.base_path ~meta:alice stimulus with
       | Ok (Some event) -> event
       | Ok None -> fail "queued creation disappeared from projection"
       | Error unavailable ->
         fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable))
    | [] -> fail "expected the queued creation for alice" in
  check bool "projection remains a typed creation" true
    (event.Keeper_world_observation.event_kind = Keeper_world_observation.Board_post_created);
  check string "creation keeps its original title" post.title (Option.get event.title);
  check string "creation keeps its original body" original_body (Option.get event.preview);
  check (float 0.) "creation keeps its original time" post.created_at event.updated_at;
  check bool "creation still explicitly mentions alice" true event.explicit_mention;
  check (list string) "creation keeps alice as the only matched target" [ "alice" ]
    event.matched_targets
;;

let test_thread_activity_does_not_project_unbound_parent_content () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let alice = keeper_meta config "alice" in
  let bob = keeper_meta config "bob" in
  let carol = keeper_meta config "carol" in
  register config alice;
  register config bob;
  register config carol;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let original_body = "@alice @peer private original" in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:original_body
    ~title:"Private parent" ~body:original_body ~visibility:Board.Direct
    ~hearth:"private-hearth" ~post_kind:Board.Human_post ()) in
  let post_id = Board.Post_id.to_string post.id in
  let own_comment = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"alice" ~content:"Earlier comment" ()) in
  let own_comment_id = Board.Comment_id.to_string own_comment.id in
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let reply = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"peer" ~parent_id:own_comment_id
    ~content:"@alice a reply" ()) in
  ignore (get (Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"peer" ~comment_id:own_comment_id ~direction:Board.Up));
  ignore (get (Board_dispatch.toggle_reaction ~reader:(Masc_board_handlers.Board_access.named "peer")
    ~target_type:Board.Reaction_comment ~target_id:own_comment_id ~user_id:"peer" ~emoji:"👍"));
  (match Board_dispatch.update_post ~post_id ~editor:"editor"
    ~title:"Private revision" ~body:"@carol private revision" ~content:"@carol private revision" () with
   | Ok _ -> fail "a thread edit changed Direct readers"
   | Error error ->
     match error with
     | Board.Validation_error _ -> ()
     | Board.Invalid_id _ | Post_not_found _ | Comment_not_found _ | Io_error _
     | Already_voted _ | Already_exists _ | Unauthorized _ | Recipient_lookup_failed _ ->
       fail (Board.show_board_error error));
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok stored -> check string "refused reader change preserves the original thread"
       original_body stored.body
   | Error error -> fail (Board.show_board_error error));
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path alice.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "comment, vote and reaction remain queued for alice" 3 (Keeper_event_queue.length queue);
  check int "a nonreader receives no thread activity" 0 (queue_length config bob.name);
  check int "a refused new reader receives no revision" 0 (queue_length config carol.name);
  List.iter (fun stimulus ->
    match Keeper_world_observation.pending_board_event_of_stimulus
        ~base_path:config.base_path ~meta:bob stimulus with
    | Ok None -> ()
    | Ok (Some _) -> fail "a retained Direct thread signal exposed a nonreader's activity"
    | Error unavailable -> fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable))
    (Keeper_event_queue.to_list queue);
  let events = Keeper_event_queue.to_list queue |> List.map (fun stimulus ->
    match Keeper_world_observation.pending_board_event_of_stimulus ~base_path:config.base_path ~meta:alice stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "queued thread activity disappeared from projection"
    | Error unavailable -> fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable)) in
  let rows = events |> List.map (fun event ->
    check (option string) "unbound parent title is absent" None event.Keeper_world_observation.title;
    check (option string) "unbound parent body is absent" None event.preview;
    check (option string) "unbound parent hearth is absent" None event.hearth;
    let fields = Keeper_unified_prompt.For_testing.board_event_fields event in
    check bool "the prompt omits unbound parent content" false
      (List.mem_assoc "title" fields || List.mem_assoc "preview" fields || List.mem_assoc "hearth" fields);
    fields) in
  let row key = match List.find_opt (List.mem_assoc key) rows with
    | Some fields -> fields | None -> fail ("missing event field " ^ key) in
  let comment = row "comment_id" in
  check string "the reply identity remains available" (Board.Comment_id.to_string reply.id)
    (List.assoc "comment_id" comment);
  check string "the parent comment identity remains available" own_comment_id
    (List.assoc "parent_comment_id" comment);
  check string "the addressed comment preview remains available" "@alice a reply"
    (List.assoc "latest_external_preview" comment);
  let vote = row "vote" in
  check string "the vote keeps its target" ("comment:" ^ own_comment_id) (List.assoc "target" vote);
  let reaction = row "reaction" in
  check string "the reaction keeps its target" ("comment:" ^ own_comment_id) (List.assoc "target" reaction)
;;

let test_queued_edits_keep_their_captured_content () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta config "editreader" in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
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
    match Keeper_world_observation.pending_board_event_of_stimulus ~base_path:config.base_path ~meta stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "queued edit disappeared from projection"
    | Error _ -> fail "queued edit could not read its Board source") in
  check (list string) "queued titles keep A then B rather than rereading latest B"
    [first.title; second.title] (List.map (fun event -> (Option.get event.Keeper_world_observation.title)) events);
  check (list string) "queued bodies keep A then B rather than rereading latest B"
    [first.body; second.body] (List.map (fun event -> (Option.get event.Keeper_world_observation.preview)) events);
  check (list (float 0.)) "each projection carries its own persisted content time"
    [first.content_updated_at; second.content_updated_at]
    (List.map (fun event -> event.Keeper_world_observation.updated_at) events);
  List.iter (fun event -> check bool "projection remains a typed edit" true
    (event.Keeper_world_observation.event_kind = Keeper_world_observation.Board_post_updated)) events
;;

let test_queued_edits_keep_their_recorded_audience () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta =
    keeper_meta ~mention_targets:[ "alice-alias"; "bob-alias" ] config "multireader"
  in
  register config meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
    ~title:"Original title" ~body:"Original evidence" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let edit title body = get (Board_dispatch.update_post ~post_id:(Board.Post_id.to_string post.id)
    ~editor:"editor" ~title ~body ~content:body ()) in
  let _first = edit "First title" "@alice-alias first addressed body" in
  let _second = edit "Second title" "@bob-alias second addressed body" in
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path meta.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "both addressed edits are durable before consumption" 2
    (Keeper_event_queue.length queue);
  let events = Keeper_event_queue.to_list queue |> List.map (fun stimulus ->
    match Keeper_world_observation.pending_board_event_of_stimulus ~base_path:config.base_path ~meta stimulus with
    | Ok (Some event) -> event
    | Ok None -> fail "queued edit disappeared from projection"
    | Error unavailable ->
      fail ("queued edit could not read its Board source: "
        ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable)) in
  (match events with
   | [ first_event; second_event ] ->
     check bool "first edit still explicitly mentions its own target" true
       first_event.Keeper_world_observation.explicit_mention;
     check (list string) "first edit matches alice alias only" [ "alice-alias" ]
       first_event.Keeper_world_observation.matched_targets;
     check bool "second edit still explicitly mentions its own target" true
       second_event.Keeper_world_observation.explicit_mention;
     check (list string) "second edit matches bob alias only" [ "bob-alias" ]
       second_event.Keeper_world_observation.matched_targets
   | _ -> fail "expected two queued edit projections in order")
;;

let test_queued_edit_keeps_audience_across_late_alias () =
  Eio_main.run @@ fun _env ->
  let alias_declared = ref false in
  let recipient_lookup =
    Recipient_lookup.make (fun candidate ->
      let name = Recipient_lookup.Candidate.to_string candidate in
      if String.equal name "latealias" && not !alias_declared
      then Ok None
      else Ok (Result.to_option (Board.Agent_id.parse name))) in
  with_temp_workspace ~recipient_lookup @@ fun config ->
  let meta = keeper_meta config "alice" in
  register config meta;
  let late_meta = keeper_meta config "latealias" in
  register config late_meta;
  let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
  let post = get_created (Board_dispatch.create_post ~author:"editor" ~content:"Original evidence"
    ~title:"Original title" ~body:"Original evidence" ~visibility:Board.Internal ~post_kind:Board.Human_post ()) in
  Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
  let post_id = Board.Post_id.to_string post.id in
  let _first = get (Board_dispatch.update_post ~post_id ~editor:"editor"
    ~title:"First title" ~body:"@alice first addressed body" ~content:"@alice first addressed body" ()) in
  check int "first edit reaches alice before the late alias exists" 1
    (queue_length config meta.name);
  alias_declared := true;
  let _second = get (Board_dispatch.update_post ~post_id ~editor:"editor"
    ~title:"Second title" ~body:"@latealias second addressed body" ~content:"@latealias second addressed body" ()) in
  check int "second edit reaches the late alias lane" 1
    (queue_length config late_meta.name);
  let queue = match Keeper_registry_event_queue.snapshot_result ~base_path:config.base_path meta.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "alice still holds only her own edit" 1 (Keeper_event_queue.length queue);
  let event = match Keeper_event_queue.to_list queue with
    | [ stimulus ] ->
      (match Keeper_world_observation.pending_board_event_of_stimulus ~base_path:config.base_path ~meta stimulus with
       | Ok (Some event) -> event
       | Ok None -> fail "queued edit disappeared from projection"
       | Error unavailable ->
         fail ("queued edit could not read its Board source: "
           ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable))
    | _ -> fail "expected one queued edit for alice" in
  check bool "first edit still explicitly mentions alice after the later edit" true
    event.Keeper_world_observation.explicit_mention;
  check (list string) "first edit still matches alice only" [ "alice" ]
    event.Keeper_world_observation.matched_targets
;;

let test_existing_durable_comment_candidates_respect_parent_visibility () =
  Eio_main.run @@ fun _env ->
  List.iter
    (fun (label, visibility, expected_delivery) ->
       with_temp_workspace @@ fun config ->
       let meta = keeper_meta ~board_interests:[ "research" ] config "durablelane" in
       register config meta;
       let get = function Ok value -> value | Error error -> fail (Board.show_board_error error) in
       let post =
         get_created
           (Board_dispatch.create_post
              ~author:"thread-author"
              ~title:"thread"
              ~content:"@thread-owner discussion"
              ~visibility
              ~post_kind:Board.Human_post
              ())
       in
       let post_id = Board.Post_id.to_string post.id in
       let comment =
         get
           (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
              ~post_id
              ~author:"comment-author"
              ~content:"unaddressed research comment"
              ())
       in
       let comment_signal : Board_dispatch.board_signal =
         { kind =
             Board_dispatch.Board_comment_added
               { comment_id = comment.id; parent_id = comment.parent_id }
         ; post_id
         ; author = "comment-author"
         ; title = post.title
         ; content = comment.content
         ; hearth = post.hearth
         ; updated_at = Some comment.created_at
         }
       in
       let addressed_comment : Board_dispatch.addressed_board_signal =
         { signal = comment_signal; audience = Board.Thread_participants }
       in
       let candidate = KBAC.of_board_signal ~meta ~recorded_at:comment.created_at addressed_comment in
       let persisted =
         match KBAC.record ~base_path:config.base_path candidate with
         | KBAC.Recorded persisted | KBAC.Duplicate persisted -> persisted
         | KBAC.Record_error detail -> fail detail
       in
       let minted_roots =
         match
           Keeper_board_attention_partition.ensure_roots
             ~base_path:config.base_path
             ~keeper_name:meta.name
             [ persisted ]
         with
         | Ok count -> count
         | Error detail -> fail detail
       in
       check int (label ^ ": pending partition root gate") expected_delivery minted_roots;
       let relevant_judgment : KBAC.judgment =
         { verdict =
             { decision = Keeper_board_attention_judgment.Relevant
             ; rationale = "matches research interest"
             }
         ; slot_id = "slot-1"
         ; source = KBAC.Cli_lane_slot
         ; judged_at = comment.created_at +. 1.0
         }
       in
       let delivered =
         match
           KBAC.apply_judgment_and_deliver
             ~base_path:config.base_path
             ~keeper_name:meta.name
             ~candidate_id:persisted.candidate_id
             ~judgment:relevant_judgment
         with
         | Ok (KBAC.Delivered delivered) -> delivered
         | Ok KBAC.Candidate_absent -> fail "expected persisted candidate to remain present"
         | Ok (KBAC.Judgment_conflict _) -> fail "the fixture candidate already records another judgment"
         | Error detail -> fail detail
       in
       (match delivered.status, expected_delivery with
        | KBAC.Consumed { delivery = KBAC.Enqueued_to_keeper_lane; _ }, 1 -> ()
        | KBAC.Consumed { delivery = KBAC.Not_relevant; _ }, 0 -> ()
        | _ -> fail (label ^ ": unexpected durable candidate consumption outcome"));
       check int (label ^ ": durable candidate queue delivery") expected_delivery
         (queue_length config meta.name);
       let attention_stimulus : Keeper_event_queue.stimulus =
         { post_id
         ; urgency = Keeper_event_queue.Normal
         ; arrived_at = comment.created_at +. 2.0
         ; payload =
             Keeper_event_queue.Board_attention
               { candidate_id = persisted.candidate_id
               ; signal =
                   Keeper_world_observation_board_signal.board_stimulus_of_board_signal
                     addressed_comment
               }
         }
       in
       match
         Keeper_world_observation.pending_board_event_of_stimulus
           ~base_path:config.base_path
           ~meta
           attention_stimulus
       with
       | Ok (Some _) when expected_delivery = 1 -> ()
       | Ok None when expected_delivery = 0 -> ()
       | Ok _ -> fail (label ^ ": unexpected stimulus intake visibility outcome")
       | Error unavailable ->
         fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable))
    [ "public", Board.Public, 1
    ; "internal", Board.Internal, 1
    ; "unlisted", Board.Unlisted, 0
    ; "direct", Board.Direct, 0
    ]
;;

let test_unavailable_posts_retain_a_judged_comment () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  let meta = keeper_meta ~board_interests:[ "research" ] config "durablelane" in
  register config meta;
  let post = get_created (Board_dispatch.create_post ~author:"thread-author"
    ~title:"thread" ~content:"research" ~visibility:Board.Public
    ~post_kind:Board.Human_post ()) in
  let post_id = Board.Post_id.to_string post.id in
  let comment = match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"comment-author"
      ~content:"research comment" () with
    | Ok comment -> comment | Error error -> fail (Board.show_board_error error) in
  let signal : Board_dispatch.board_signal =
    { kind = Board_comment_added { comment_id = comment.id; parent_id = comment.parent_id }
    ; post_id; author = "comment-author"; title = post.title; content = comment.content
    ; hearth = post.hearth; updated_at = Some comment.created_at } in
  let candidate = KBAC.of_board_signal ~meta ~recorded_at:comment.created_at
      { signal; audience = Board.Thread_participants } in
  let candidate = match KBAC.record ~base_path:config.base_path candidate with
    | KBAC.Recorded candidate | KBAC.Duplicate candidate -> candidate
    | KBAC.Record_error detail -> fail detail in
  let post_signal : Board_dispatch.board_signal =
    { signal with kind = Board_post_created; author = "thread-author"; content = post.body } in
  let post_candidate = KBAC.of_board_signal ~meta ~recorded_at:post.created_at
      { signal = post_signal; audience = Board.Discoverable } in
  let post_candidate = match KBAC.record ~base_path:config.base_path post_candidate with
    | KBAC.Recorded candidate | KBAC.Duplicate candidate -> candidate
    | KBAC.Record_error detail -> fail detail in
  let judgment : KBAC.judgment =
    { verdict = { decision = Keeper_board_attention_judgment.Relevant; rationale = "research" }
    ; slot_id = "slot-1"; source = KBAC.Cli_lane_slot; judged_at = comment.created_at +. 1.0 } in
  let posts = Board.persist_path (Board.global ()) in
  let held = posts ^ ".test-held" in
  let restart () =
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    Result.get_ok (Board_dispatch.init_jsonl ~base_path:config.base_path
      ~recipient_lookup:every_name_declared ()) in
  Unix.rename posts held;
  Fun.protect ~finally:(fun () -> if Sys.file_exists held then Unix.rename held posts)
  @@ fun () ->
  (* The running store has observed this posts file, so reading it again
     refuses the source once the file is gone. A restarted store would start
     an empty Board instead, which is not an unavailable source. *)
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts (Board.global ()) with
   | Error _ -> ()
   | Ok count -> failf "a vanished posts file was admitted with %d rows" count);
  (match Board_dispatch.read_post_for_evidence ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error (Board.Read_source_unavailable _) -> ()
   | Error error -> fail (Board.show_board_read_error error)
   | Ok _ -> fail "unavailable source authorized a parent post");
  (match Keeper_board_attention_partition.ensure_roots
      ~base_path:config.base_path ~keeper_name:meta.name [candidate; post_candidate] with
   | Ok 0 -> () | Ok _ -> fail "unavailable parents cannot acquire a judgment root"
   | Error detail -> fail detail);
  (match KBAC.apply_judgment_and_deliver ~base_path:config.base_path
      ~keeper_name:meta.name ~candidate_id:post_candidate.candidate_id ~judgment with
   | Error _ -> () | Ok _ -> fail "unavailable source consumed a post candidate");
  (match KBAC.apply_judgment_and_deliver ~base_path:config.base_path
      ~keeper_name:meta.name ~candidate_id:candidate.candidate_id ~judgment with
   | Error _ -> () | Ok _ -> fail "unavailable source consumed a judged candidate");
  (match KBAC.load_candidates ~base_path:config.base_path ~keeper_name:meta.name with
   | Ok candidates ->
     (match List.find_opt (fun (held : KBAC.candidate) -> held.candidate_id = candidate.candidate_id) candidates with
      | Some { status = KBAC.Judged _; _ } -> ()
      | Some _ | None -> fail "the original judgment was not retained")
   | Error detail -> fail detail);
  check int "neither unavailable parent authorizes a stimulus" 0
    (queue_length config meta.name);
  Unix.rename held posts;
  restart ();
  List.iter (fun candidate ->
    match KBAC.apply_judgment_and_deliver ~base_path:config.base_path
      ~keeper_name:meta.name ~candidate_id:candidate.KBAC.candidate_id ~judgment with
    | Ok (KBAC.Delivered { status = KBAC.Consumed { delivery = KBAC.Enqueued_to_keeper_lane; _ }; _ }) -> ()
    | Ok _ -> fail "recovered source did not deliver the retained judgment"
    | Error detail -> fail detail) [candidate; post_candidate];
  check int "recovery delivers both retained judgments" 2 (queue_length config meta.name)
;;

let () =
  run
    "keeper Board discoverable cursor"
    [ ( "producer and owner boundary"
      , [ test_case "Direct readership precedes delivery and judgment" `Quick
            test_direct_readership_precedes_delivery_and_judgment
        ; test_case "live comment and catchup share identity after title edit" `Quick
            test_live_comment_and_catchup_share_identity_after_title_edit
        ; test_case "initialized cursor receives each discoverable edit" `Quick
            test_initialized_cursor_receives_each_discoverable_edit
        ; test_case "replayed comment discovery follows parent visibility" `Quick
            test_replayed_comment_discovery_respects_parent_visibility
        ; test_case "existing durable comment candidates respect parent visibility" `Quick
            test_existing_durable_comment_candidates_respect_parent_visibility
        ; test_case "unavailable posts retain a judged comment until recovery" `Quick
            test_unavailable_posts_retain_a_judged_comment
        ; test_case "queued creation keeps content and audience after an edit" `Quick
            test_queued_creation_keeps_content_and_audience_after_edit
        ; test_case "thread activity excludes unbound parent content" `Quick
            test_thread_activity_does_not_project_unbound_parent_content
        ; test_case "queued edits preserve captured content before consumption" `Quick
            test_queued_edits_keep_their_captured_content
        ; test_case "queued edits keep their recorded audience" `Quick
            test_queued_edits_keep_their_recorded_audience
        ; test_case "queued edit keeps audience across late alias" `Quick
            test_queued_edit_keeps_audience_across_late_alias
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
