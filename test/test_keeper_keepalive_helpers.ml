module Types = Masc_domain

(** Focused tests for keepalive identity reconciliation, directed wake
    selection, directive diagnostics, and status-tick observation shape. *)

open Alcotest
open Masc
module KK = Masc.Keeper_keepalive
let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_workspace f =
  let base_path = Filename.temp_dir "keeper-heartbeat-current-task" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      rm_rf base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None : string);
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      f config)

let make_keepalive_meta ~name ~agent_name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String agent_name);
        ("trace_id", `String ("trace-" ^ name));
        ("sandbox_profile", `String "local");
        ("network_mode", `String "inherit");
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> meta

let make_in_progress_task ~id ~assignee : Types.task =
  {
    id;
    title = "Heartbeat current task";
    description = "";
    task_status =
      Types.InProgress { assignee; started_at = "2026-06-26T00:00:00Z" };
    priority = 3;
    files = [];
    created_at = "2026-06-26T00:00:00Z";
    created_by = Some "test";
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let test_current_task_id_for_agent_reconciles_from_empty_registry_task () =
  with_temp_workspace (fun config ->
    let keeper_name = "heartbeat-current-task-owner" in
    let agent_name = "keeper-heartbeat-current-task-owner-agent" in
    let task_id = "task-heartbeat-current" in
    let meta = make_keepalive_meta ~name:keeper_name ~agent_name in
    (match Keeper_meta_store.write_meta config meta with
     | Ok () -> ()
     | Error err -> fail ("write_meta failed: " ^ err));
    Workspace.write_backlog config
      {
        Types.tasks = [ make_in_progress_task ~id:task_id ~assignee:agent_name ];
        last_updated = "2026-06-26T00:00:01Z";
        version = 2;
      };
    ignore
      (Keeper_registry.For_testing.register
         ~base_path:config.Workspace.base_path
         keeper_name
         meta);
    Fun.protect
      ~finally:(fun () ->
        Keeper_registry.For_testing.unregister ~base_path:config.Workspace.base_path keeper_name)
      (fun () ->
        check string "heartbeat task id" task_id
          (KK.current_task_id_for_agent ~config agent_name);
        let current_from_registry =
          match Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
          | Some entry ->
            Keeper_runtime_contract.current_task_id_opt entry.meta
          | None -> None
        in
        check (option string) "registry current task reconciled" (Some task_id)
          current_from_registry;
        let current_from_disk =
          match Keeper_meta_store.read_meta config keeper_name with
          | Ok (Some persisted) ->
            Keeper_runtime_contract.current_task_id_opt persisted
          | Ok None -> None
          | Error err -> fail ("read_meta failed: " ^ err)
        in
        check (option string) "persisted current task reconciled" (Some task_id)
          current_from_disk))

let is_warn_unknown_keeper = function
  | KK.Warn_unknown_keeper -> true
  | KK.Debug_throttled_unknown_keeper -> false

let is_debug_throttled_unknown_keeper = function
  | KK.Debug_throttled_unknown_keeper -> true
  | KK.Warn_unknown_keeper -> false

let test_not_in_registry_warn_due_first_event () =
  check bool "first unknown-keeper directive warns" true
    (KK.not_in_registry_warn_due ~previous:None ~now:1_000.0 ())

let test_not_in_registry_warn_due_throttles_within_window () =
  check bool "same window throttles" false
    (KK.not_in_registry_warn_due
       ~previous:(Some 1_000.0)
       ~now:(1_000.0 +. (KK.not_in_registry_warn_cooldown_s /. 2.0))
       ())

let test_not_in_registry_warn_due_recovers_on_clock_regression () =
  check bool "clock regression does not suppress forever" true
    (KK.not_in_registry_warn_due ~previous:(Some 1_000.0) ~now:999.0 ())

let test_not_in_registry_warn_state_is_per_agent () =
  let open KK in
  let state = StringMap.add "keeper-a-agent" 1_000.0 StringMap.empty in
  let decision_a, _ =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-a-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  let decision_b, updated =
    not_in_registry_warn_state_step
      ~agent_name:"keeper-b-agent"
      ~now:(1_000.0 +. (not_in_registry_warn_cooldown_s /. 2.0))
      state
  in
  check bool "same agent throttled" true
    (is_debug_throttled_unknown_keeper decision_a);
  check bool "different agent warns" true (is_warn_unknown_keeper decision_b);
  check bool "different agent recorded" true
    (Option.is_some (StringMap.find_opt "keeper-b-agent" updated))

let test_not_in_registry_warn_state_is_bounded () =
  let open KK in
  let state =
    List.fold_left
      (fun acc i ->
         StringMap.add
           ("keeper-" ^ string_of_int i ^ "-agent")
           (2_000.0 -. float_of_int i)
           acc)
      StringMap.empty
      [ 0; 1; 2; 3; 4 ]
  in
  let decision, updated =
    not_in_registry_warn_state_step
      ~max_entries:3
      ~agent_name:"keeper-new-agent"
      ~now:2_001.0
      state
  in
  check bool "new unknown keeper still warns" true (is_warn_unknown_keeper decision);
  check int "warn throttle map is capped" 3 (StringMap.cardinal updated);
  check bool "new unknown keeper is retained" true
    (Option.is_some (StringMap.find_opt "keeper-new-agent" updated));
  check bool "oldest unknown keeper is pruned" true
    (Option.is_none (StringMap.find_opt "keeper-4-agent" updated))

module KKS = Masc.Keeper_keepalive_signal
module KWOBS = Masc.Keeper_world_observation_board_signal
module KBA = Masc.Keeper_board_audience
module KBAC = Masc.Keeper_board_attention_candidate

let make_board_resume_meta name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("sandbox_profile", `String "local")
      ; ("network_mode", `String "inherit")
      ]
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta -> meta
;;

let test_directed_wake_cuts_configured_sleep () =
  Eio_main.run (fun env ->
    let stop = Atomic.make false in
    let wakeup = Atomic.make true in
    let outcome =
      KKS.interruptible_sleep
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        30.0
    in
    check bool "directed wake returns Woken" true
      (match outcome with
       | KKS.Woken -> true
       | KKS.Stopped | KKS.Timeout -> false);
    check bool "wake atomic is consumed" false (Atomic.get wakeup))
;;

let test_explicit_stop_cuts_configured_sleep () =
  Eio_main.run (fun env ->
    let stop = Atomic.make true in
    let wakeup = Atomic.make false in
    let outcome =
      KKS.interruptible_sleep
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        30.0
    in
    check bool "explicit stop returns Stopped" true
      (match outcome with
       | KKS.Stopped -> true
       | KKS.Woken | KKS.Timeout -> false))
;;

let test_board_goal_keyword_overlap_is_not_wake_reason () =
  let meta = make_board_resume_meta "keyword-overlap" in
  let signal : Board_dispatch.board_signal =
    { kind = Board_dispatch.Board_post_created
    ; post_id = "post-keyword-overlap"
    ; author = "external-author"
    ; title = "test"
    ; content = "this test overlaps the keeper goal but does not address it"
    ; hearth = None
    ; updated_at = Some 123.0
    }
  in
  match KWOBS.wake_reason ~meta ~signal with
  | KWOBS.Available None -> ()
  | KWOBS.Available (Some reason) ->
    failf "goal keyword overlap woke as %s" (KWOBS.wake_reason_label reason)
  | KWOBS.Unavailable unavailable ->
    failf "Board fixture unavailable: %s" (KWOBS.unavailable_to_string unavailable)

let check_exact_board_mention ~content ~expected =
  let meta = make_board_resume_meta "foo" in
  let signal : Board_dispatch.board_signal =
    { kind = Board_dispatch.Board_post_created
    ; post_id = "post-exact-mention"
    ; author = "external-author"
    ; title = "test"
    ; content
    ; hearth = None
    ; updated_at = Some 123.0
    }
  in
  let matched = KWOBS.match_signal ~meta ~signal in
  check bool content expected matched.explicit_mention

let test_board_mentions_use_exact_typed_keeper_ids () =
  check_exact_board_mention ~content:"@foo please inspect" ~expected:true;
  check_exact_board_mention ~content:"@foobar is a different lane" ~expected:false;
  check_exact_board_mention ~content:"mail foo@example.com" ~expected:false

let audience_signal ?(kind = Board_dispatch.Board_post_created) ~author content :
  Board_dispatch.board_signal
  =
  { kind
  ; post_id = "post-audience"
  ; author
  ; title = "audience"
  ; content
  ; hearth = None
  ; updated_at = Some 123.0
  }
;;

let classified ?(visibility = Board.Internal) signal =
  match KBA.classify ~visibility signal with
  | Ok audience -> audience
  | Error error -> fail (KBA.classification_error_to_string error)
;;

let route ~audience ~meta signal =
  match KBA.route_for_keeper ~audience ~meta ~signal with
  | KWOBS.Available route -> route
  | KWOBS.Unavailable unavailable ->
    fail (KWOBS.unavailable_to_string unavailable)
;;

let test_closed_board_audience_routes_only_its_authority () =
  let alpha = make_board_resume_meta "alpha" in
  let beta = make_board_resume_meta "beta" in
  let targeted = audience_signal ~author:"external-author" "@alpha inspect" in
  let targeted_audience = classified targeted in
  check bool "explicit address classifies as Targets" true
    (match targeted_audience with KBA.Targets _ -> true | _ -> false);
  check bool "target receives direct delivery" true
    (match route ~audience:targeted_audience ~meta:alpha targeted with
     | KBA.Deliver KWOBS.Explicit_mention -> true
     | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
  check bool "non-target is retired, not judged" true
    (match route ~audience:targeted_audience ~meta:beta targeted with
     | KBA.Ignore -> true
     | KBA.Deliver _ | KBA.Judge_discoverable -> false);
  (* W1: a non-Keeper target mixed into the audience must not fail the whole
     classification — the valid Keeper target keeps live routing, and both
     audience consumers (routing [classify] and structural
     [mention_ids_of_signal]) project the exact same Keeper id set.
     [Keeper_id.of_string] mints a raw-fallback id for non-Keeper names
     (RFC-0232 §3.4), so this also pins that behavior against regressions. *)
  let mixed_audience =
    audience_signal ~author:"external-author" "@alpha @human-b inspect"
  in
  let mixed_classified = classified mixed_audience in
  check bool "mixed Keeper and non-Keeper targets still classify" true
    (match mixed_classified with KBA.Targets _ -> true | _ -> false);
  check bool "valid Keeper target keeps direct delivery with a mixed audience" true
    (match route ~audience:mixed_classified ~meta:alpha mixed_audience with
     | KBA.Deliver KWOBS.Explicit_mention -> true
     | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
  check bool "both audience consumers project the same Keeper id set" true
    (match mixed_classified with
     | KBA.Targets targets ->
       List.equal
         Keeper_identity.Keeper_id.equal
         targets
         (KWOBS.mention_ids_of_signal mixed_audience)
     | KBA.Broadcast | KBA.Thread_participants | KBA.Discoverable -> false);
  let discoverable = audience_signal ~author:"external-author" "new research" in
  let discoverable_audience = classified discoverable in
  check bool "new unaddressed post is discoverable" true
    (match discoverable_audience with KBA.Discoverable -> true | _ -> false);
  check bool "discoverable enters judgment only for non-author" true
    (match route ~audience:discoverable_audience ~meta:alpha discoverable with
     | KBA.Judge_discoverable -> true
     | KBA.Deliver _ | KBA.Ignore -> false);
  let hearth_only = { discoverable with hearth = Some "@alpha" } in
  check bool "Board category cannot become recipient authority" true
    (match classified hearth_only with KBA.Discoverable -> true | _ -> false);
  check bool "Board category is absent from mention metrics" false
    (KWOBS.match_signal ~meta:alpha ~signal:hearth_only).explicit_mention;
  let self_authored = audience_signal ~author:"keeper-alpha" "new research" in
  check bool "author lane never judges its own post" true
    (match route ~audience:(classified self_authored) ~meta:alpha self_authored with
     | KBA.Ignore -> true
     | KBA.Deliver _ | KBA.Judge_discoverable -> false);
  let broadcast = audience_signal ~author:"external-author" "@@all inspect" in
  check bool "exact Keeper broadcast is direct delivery" true
    (match route ~audience:(classified broadcast) ~meta:beta broadcast with
     | KBA.Deliver KWOBS.Broadcast -> true
     | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
  let comment =
    audience_signal
      ~kind:Board_dispatch.Board_comment_added
      ~author:"external-author"
      "thread update"
  in
  check bool "unaddressed comment is thread-scoped" true
    (match classified comment with KBA.Thread_participants -> true | _ -> false);
  check bool "Direct thread follow-up stays participant-scoped" true
    (match classified ~visibility:Board.Direct comment with
     | KBA.Thread_participants -> true
     | _ -> false);
  let inherited_title =
    { comment with title = "original post for @alpha"; content = "plain follow-up" }
  in
  check bool "inherited post title cannot re-address a comment" true
    (match classified inherited_title with
     | KBA.Thread_participants -> true
     | _ -> false);
  check bool "structural matcher ignores inherited title address" false
    (KWOBS.match_signal ~meta:alpha ~signal:inherited_title).explicit_mention;
  let inherited_reaction =
    audience_signal
      ~kind:
        (Board_dispatch.Board_reaction_changed
           { target_type = Board.Reaction_post
           ; target_id = "post-audience"
           ; user_id = "external-author"
           ; emoji = "eyes"
           ; reacted = true
           })
      ~author:"external-author"
      "original post body for @alpha"
  in
  check bool "inherited post body cannot re-address a reaction" true
    (match classified inherited_reaction with
     | KBA.Thread_participants -> true
     | _ -> false);
  let unsupported = audience_signal ~author:"external-author" "@@analyst inspect" in
  check bool "unsupported broadcast fails closed" true
    (match KBA.classify ~visibility:Board.Internal unsupported with
     | Error (KBA.Invalid_board_audience (Board.Validation_error _)) -> true
     | Error _ | Ok _ -> false);
  check bool "Direct without targets fails closed" true
    (match KBA.classify ~visibility:Board.Direct discoverable with
     | Error (KBA.Invalid_board_audience (Board.Validation_error _)) -> true
     | Error _ | Ok _ -> false);
  let mixed = audience_signal ~author:"external-author" "@alpha @@analyst inspect" in
  check bool "mixed direct target and unsupported selector fails closed" true
    (match KBA.classify ~visibility:Board.Internal mixed with
     | Error (KBA.Invalid_board_audience (Board.Validation_error _)) -> true
     | Error _ | Ok _ -> false);
  let direct_broadcast = audience_signal ~author:"external-author" "@@all inspect" in
  check bool "@@all on a Direct post fails closed" true
    (match KBA.classify ~visibility:Board.Direct direct_broadcast with
     | Error (KBA.Invalid_board_audience (Board.Validation_error _)) -> true
     | Error _ | Ok _ -> false);
  check bool "@@all on a non-Direct post still broadcasts" true
    (match KBA.classify ~visibility:Board.Internal direct_broadcast with
     | Ok KBA.Broadcast -> true
     | Error _ | Ok _ -> false)

let persist_and_register_board_lane config meta =
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error detail -> fail ("write_meta failed: " ^ detail));
  ignore
    (Keeper_registry.For_testing.register
       ~base_path:config.Workspace.base_path
       meta.Keeper_meta_contract.name
       meta)
;;

let board_queue_length config keeper_name =
  Keeper_registry_event_queue.snapshot
    ~base_path:config.Workspace.base_path
    keeper_name
  |> Keeper_event_queue.length
;;

let board_attention_count config keeper_name =
  match
    KBAC.load_candidates
      ~base_path:config.Workspace.base_path
      ~keeper_name
  with
  | Ok candidates -> List.length candidates
  | Error detail -> fail ("load_candidates failed: " ^ detail)
;;

let persist_board_signal (signal : Board_dispatch.board_signal) =
  match
    Board_dispatch.create_post
      ~author:signal.author
      ~content:signal.content
      ~title:signal.title
      ~post_kind:Board.Human_post
      ~visibility:Board.Internal
      ?hearth:signal.hearth
      ()
  with
  | Error error -> fail (Board.show_board_error error)
  | Ok post ->
    let signal = { signal with post_id = Board.Post_id.to_string post.id } in
    let audience =
      match
        Board.audience_for_post
          ~visibility:post.visibility
          ~title:post.title
          ~content:post.content
      with
      | Ok audience -> audience
      | Error error -> fail (Board.show_board_error error)
    in
    { Board_dispatch.signal; audience }
;;

let overwrite_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let test_exact_mentions_deliver_and_wake_each_lane_independently () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let alpha = make_board_resume_meta "alpha" in
       let beta = make_board_resume_meta "beta" in
       let gamma = make_board_resume_meta "gamma" in
       persist_and_register_board_lane config alpha;
       persist_and_register_board_lane config beta;
       persist_and_register_board_lane config gamma;
       let signal : Board_dispatch.addressed_board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-multi-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@alpha @beta inspect independently"
         ; hearth = None
         ; updated_at = Some 123.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "alpha durable queue" 1 (board_queue_length config "alpha");
       check int "beta durable queue" 1 (board_queue_length config "beta");
       check int "non-target durable queue" 0 (board_queue_length config "gamma");
       check int "non-target attention fan-out" 0
         (board_attention_count config "gamma");
       List.iter
         (fun keeper_name ->
            match Keeper_registry.get ~base_path:config.base_path keeper_name with
            | Some entry ->
              check bool (keeper_name ^ " independently woken") true
                (Atomic.get entry.fiber_wakeup)
            | None -> fail (keeper_name ^ " registry entry missing"))
         [ "alpha"; "beta" ])
;;

let test_mixed_address_signal_is_dropped_at_routing () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       (* Policy pin (P2-1): a post mixing a valid [@keeper] target with an
          unsupported [@@] selector is rejected whole — the valid target is
          NOT partially routed.  #25378 pinned this at routing; the write
          boundary now rejects the post before any signal exists, which is
          the same fail-closed policy enforced one layer earlier. *)
       let alpha = make_board_resume_meta "alpha" in
       let beta = make_board_resume_meta "beta" in
       persist_and_register_board_lane config alpha;
       persist_and_register_board_lane config beta;
       (match
          Board_dispatch.create_post
            ~author:"external-author"
            ~content:"@alpha @@analyst inspect"
            ~title:"mixed address"
            ~post_kind:Board.Human_post
            ~visibility:Board.Internal
            ()
        with
        | Ok _ -> fail "mixed-address post must be rejected at the write boundary"
        | Error (Board.Validation_error _) -> ()
        | Error error -> fail (Board.show_board_error error));
       check int "mixed-address target durable queue" 0
         (board_queue_length config "alpha");
       check int "mixed-address non-target durable queue" 0
         (board_queue_length config "beta");
       match Keeper_registry.get ~base_path:config.base_path "alpha" with
       | Some entry ->
         check bool "mixed-address target not woken" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "alpha registry entry missing")
;;

let test_paused_exact_mention_is_durable_without_wake () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let meta = make_board_resume_meta "pausedlane" in
       persist_and_register_board_lane config meta;
       (match
          Keeper_registry.dispatch_event
            ~base_path:config.base_path
            meta.name
            Keeper_state_machine.Operator_pause
        with
        | Ok _ -> ()
        | Error _ -> fail "failed to pause Keeper fixture");
       let signal : Board_dispatch.addressed_board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-paused-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@pausedlane retain this"
         ; hearth = None
         ; updated_at = Some 124.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "paused durable queue" 1 (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "paused lane wake hint remains false" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "paused registry entry missing")
;;

let test_restarting_exact_mention_is_durable_with_deferred_wake () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let meta = make_board_resume_meta "restartlane" in
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error detail -> fail ("write_meta failed: " ^ detail));
       (match
          Keeper_registry.register_restarting
            ~base_path:config.base_path
            meta.name
            meta
        with
        | Ok _ -> ()
        | Error _ -> fail "failed to register Restarting Keeper fixture");
       let signal : Board_dispatch.addressed_board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-restarting-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@restartlane retain this while relaunching"
         ; hearth = None
         ; updated_at = Some 124.5
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "Restarting durable queue" 1
         (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "Restarting lane keeps deferred wake hint" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "Restarting registry entry missing")
;;

let test_lane_meta_failure_does_not_block_next_durable_delivery () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let broken = make_board_resume_meta "zzzbroken" in
       let healthy = make_board_resume_meta "aaahealthy" in
       persist_and_register_board_lane config broken;
       persist_and_register_board_lane config healthy;
       (match Keeper_registry.all ~base_path:config.base_path () with
        | first :: _ ->
          check string "fixture processes failing lane first" broken.name first.name
        | [] -> fail "lane-isolation registry fixture is empty");
       overwrite_file
         (Keeper_types_profile.keeper_meta_path config broken.name)
         "{ malformed Keeper metadata";
       let signal : Board_dispatch.addressed_board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-lane-isolation"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@zzzbroken @aaahealthy inspect independently"
         ; hearth = None
         ; updated_at = Some 125.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "unreadable lane has no queued signal" 0
         (board_queue_length config broken.name);
       check int "next lane receives durable signal" 1
         (board_queue_length config healthy.name))
;;

(* #25600 fixture: a [Thread_participants]-audience comment signal is the
   only route that re-reads the board store at signal time
   ([check_self_comment_status]).  The keeper authored an earlier comment on
   the post, so a newer external comment addresses it as
   [Thread_reply_after_self_comment] — but only if the store read succeeds. *)
let create_thread_fixture config ~keeper_name =
  let meta = make_board_resume_meta keeper_name in
  persist_and_register_board_lane config meta;
  let post =
    match
      Board_dispatch.create_post
        ~author:"external-author"
        ~content:"thread topic"
        ~title:"thread"
        ~post_kind:Board.Human_post
        ~visibility:Board.Internal
        ()
    with
    | Error error -> fail (Board.show_board_error error)
    | Ok post -> post
  in
  let post_id = Board.Post_id.to_string post.id in
  let add_comment ~author ~content =
    match Board_dispatch.add_comment ~post_id ~author ~content () with
    | Error error -> fail (Board.show_board_error error)
    | Ok _comment -> ()
  in
  add_comment ~author:meta.Keeper_meta_contract.agent_name ~content:"keeper was here";
  add_comment ~author:"external-author" ~content:"follow up";
  let signal : Board_dispatch.addressed_board_signal =
    { signal =
        { kind = Board_dispatch.Board_comment_added
        ; post_id
        ; author = "external-author"
        ; title = "thread"
        ; content = "follow up"
        ; hearth = None
        ; updated_at = Some 125.5
        }
    ; audience = Board.Thread_participants
    }
  in
  meta, signal
;;

(* #25600 regression: a transient store read failure on the
   [Thread_participants] route must not silently drop the signal — the
   bounded retry re-reads and the addressed keeper still wakes. *)
let test_thread_participant_wakes_after_transient_store_read_failure () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      KKS.force_transient_relevance_failures_for_test 0;
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta, signal = create_thread_fixture config ~keeper_name:"threadlane" in
       KKS.force_transient_relevance_failures_for_test 1;
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "addressed lane durable queue after transient failure" 1
         (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "addressed lane woken after transient failure" true
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "threadlane registry entry missing")
;;

(* #25600 bound pin: the retry is bounded — a store that keeps failing past
   [board_signal_relevance_max_attempts] still drops the lane (loudly), it
   does not retry forever. *)
let test_thread_participant_drop_is_bounded_under_persistent_failure () =
  Eio_main.run @@ fun _env ->
  with_temp_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      KKS.force_transient_relevance_failures_for_test 0;
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta, signal = create_thread_fixture config ~keeper_name:"boundlane" in
       KKS.force_transient_relevance_failures_for_test 100;
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "persistently failing lane stays undelivered" 0
         (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "persistently failing lane not woken" false
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "boundlane registry entry missing")
;;

(* ── Test runner ─── *)

let () =
  run
    "keeper keepalive helpers"
    [ ( "current_task_reconciliation"
      , [ test_case
            "heartbeat reconciles empty current_task_id from active backlog"
            `Quick
            test_current_task_id_for_agent_reconciles_from_empty_registry_task
        ] )
    ; ( "directive_orphan_warn_gate"
      , [ test_case "first unknown keeper directive warns" `Quick
            test_not_in_registry_warn_due_first_event
        ; test_case "same unknown keeper is throttled within window" `Quick
            test_not_in_registry_warn_due_throttles_within_window
        ; test_case "clock regression does not suppress forever" `Quick
            test_not_in_registry_warn_due_recovers_on_clock_regression
        ; test_case "warn gate is per agent" `Quick
            test_not_in_registry_warn_state_is_per_agent
        ; test_case "warn gate state is bounded" `Quick
            test_not_in_registry_warn_state_is_bounded
        ] )
    ; ( "board_signal_delivery"
      , [ test_case "goal keyword overlap is not a wake reason" `Quick
            test_board_goal_keyword_overlap_is_not_wake_reason
        ; test_case "mentions use exact typed Keeper ids" `Quick
            test_board_mentions_use_exact_typed_keeper_ids
        ; test_case "closed audience routes only its authority" `Quick
            test_closed_board_audience_routes_only_its_authority
        ; test_case "exact mentions deliver and wake every lane" `Quick
            test_exact_mentions_deliver_and_wake_each_lane_independently
        ; test_case "mixed address signal is dropped at routing" `Quick
            test_mixed_address_signal_is_dropped_at_routing
        ; test_case "paused exact mention is durable without wake" `Quick
            test_paused_exact_mention_is_durable_without_wake
        ; test_case "Restarting exact mention is durable with deferred wake" `Quick
            test_restarting_exact_mention_is_durable_with_deferred_wake
        ; test_case "lane metadata failure does not block next durable delivery" `Quick
            test_lane_meta_failure_does_not_block_next_durable_delivery
        ; test_case "thread participant wakes after transient store read failure" `Quick
            test_thread_participant_wakes_after_transient_store_read_failure
        ; test_case "thread participant drop is bounded under persistent failure" `Quick
            test_thread_participant_drop_is_bounded_under_persistent_failure
        ] )
    ; ( "interruptible_cadence"
      , [ test_case "directed wake cuts configured sleep" `Quick
            test_directed_wake_cuts_configured_sleep
        ; test_case "explicit stop cuts configured sleep" `Quick
            test_explicit_stop_cuts_configured_sleep
        ] )
    ]
;;
