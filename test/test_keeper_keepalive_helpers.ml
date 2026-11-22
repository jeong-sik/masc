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

(* These tests check how the Board routes a text, not who is declared: every
   name with the shape of a Keeper name stands for itself. *)
let every_name_declared =
  Recipient_lookup.make (fun candidate ->
    Ok
      (Result.to_option
         (Board.Agent_id.parse (Recipient_lookup.Candidate.to_string candidate))))
;;

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

(* The Board tests below write through the dispatcher inside an Eio run, so the
   backend gets its recipient lookup before the first write. *)
let with_board_workspace ?(recipient_lookup = every_name_declared) f =
  with_temp_workspace (fun config ->
    Result.get_ok (Board_dispatch.init_jsonl
      ~base_path:config.Workspace.base_path
      ~recipient_lookup ());
    f config)

let make_keepalive_meta ~name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("trace-" ^ name));
        (* sandbox_profile and network_mode left the JSON wire schema — they
           arrive from keeper.toml now. This fixture only ever set them to the
           record defaults ("local" / "inherit"), so dropping them changes
           nothing this suite asserts. *)
      ]
  in
  (* The strict parser demands every persisted field; this suite only cares
     about identity and task ownership, so it uses the fixture helper that
     fills record defaults — the same seam the other keeper suites use. *)
  match Masc_test_deps.meta_of_json_fixture json with
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
    execution_links = Masc_domain.no_execution_links;
    skills = [];
  }

(* Reconcile persists the recovered current_task_id through the per-Keeper
   Owner, and the Owner inventory is installed once at boot — a fixture that
   skips the install reproduces "Keeper owner inventory is not installed"
   instead of the reconcile under test (issue #31192). Mirrors the
   [install_from_store] fixtures in test_keeper_effective_meta_overlay /
   test_heartbeat_integration. *)
let with_owner_runtime config f =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let install () =
    match
      Keeper_owner_registry.install_from_store
        ~sw
        ~operation_runner:None
        ~on_turn_slot_released:None
        config
    with
    | Ok _ -> ()
    | Error error ->
      fail (Keeper_owner_registry.install_error_to_string error)
  in
  f ~install

let test_current_task_id_for_agent_reconciles_from_empty_registry_task () =
  with_temp_workspace (fun config ->
    with_owner_runtime config @@ fun ~install ->
    let keeper_name = "heartbeat-current-task-owner" in
    let agent_name = keeper_name in
    let task_id = "task-heartbeat-current" in
    let meta = make_keepalive_meta ~name:keeper_name in
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error err -> fail ("write_meta failed: " ^ err));
    install ();
    Workspace.write_backlog config
      {
        Types.tasks = [ make_in_progress_task ~id:task_id ~assignee:agent_name ];
        task_creation_receipts = []; task_deletion_receipts = []; pending_completion_approvals = []; pending_completion_rejections = []; delivered_completion_rejections = [];
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
      ; ("trace_id", `String ("trace-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
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
        (fun () -> 30.0)
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
        (fun () -> 30.0)
    in
    check bool "explicit stop returns Stopped" true
      (match outcome with
       | KKS.Stopped -> true
       | KKS.Woken | KKS.Timeout -> false))
;;

let test_cadence_wake_consumes_only_active_sleep () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let stop = Atomic.make false in
    let wakeup = Atomic.make false in
    let cadence_sleeping = Atomic.make false in
    let outcome = ref None in
    Eio.Fiber.both
      (fun () ->
         outcome :=
           Some
             (KKS.interruptible_sleep
                ~cadence_sleeping
                ~clock
                ~stop
                ~wakeup
                (fun () -> 30.0)))
      (fun () ->
         while not (Atomic.get cadence_sleeping) do
           Eio.Time.sleep clock 0.001
         done;
         check bool "active sleeper CAS succeeds" true
           (Atomic.compare_and_set cadence_sleeping true false));
    check bool "cadence wake returns Woken" true
      (match !outcome with
       | Some KKS.Woken -> true
       | Some (KKS.Stopped | KKS.Timeout) | None -> false);
    check bool "sleep handshake is cleared" false
      (Atomic.get cadence_sleeping))
;;

let test_cadence_handshake_precedes_duration_resolution () =
  Eio_main.run (fun env ->
    let stop = Atomic.make false in
    let wakeup = Atomic.make false in
    let cadence_sleeping = Atomic.make false in
    let handshake_was_visible = ref false in
    let outcome =
      KKS.interruptible_sleep
        ~cadence_sleeping
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        (fun () ->
          handshake_was_visible := Atomic.get cadence_sleeping;
          ignore (Atomic.compare_and_set cadence_sleeping true false : bool);
          0.0)
    in
    check bool "duration resolves after handshake" true !handshake_was_visible;
    check bool "cadence change during resolution is observed" true
      (match outcome with
       | KKS.Woken -> true
       | KKS.Stopped | KKS.Timeout -> false))
;;

(* #34653: the provider backoff sleep is not cut short by a wakeup. Every
   stimulus that interrupted it re-ran the same rate-limited call (183 failed
   turns in 41 minutes, median 30 s apart against a declared 600 s). The
   wakeup is consumed when the duration ends, so the tick still happens once
   per signal, only later. *)
let test_backoff_sleep_serves_a_wakeup_only_after_the_duration () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let stop = Atomic.make false in
    let wakeup = Atomic.make true in
    let duration = 0.05 in
    let started = Eio.Time.now clock in
    let outcome =
      KKS.interruptible_sleep
        ~wake_policy:KKS.Serve_wakeup_after_duration
        ~clock
        ~stop
        ~wakeup
        (fun () -> duration)
    in
    let elapsed = Eio.Time.now clock -. started in
    (* Wall-clock reads around a monotonic sleep: allow the sub-microsecond
       rounding of the sleep deadline (#34663 review). *)
    check bool "the full duration elapsed before the wakeup was served" true
      (elapsed >= duration -. 0.001);
    check bool "the pending wakeup is served as Woken once the sleep ends" true
      (match outcome with
       | KKS.Woken -> true
       | KKS.Stopped | KKS.Timeout -> false);
    check bool "wake atomic is consumed" false (Atomic.get wakeup))
;;

let test_backoff_sleep_without_a_wakeup_times_out () =
  Eio_main.run (fun env ->
    let stop = Atomic.make false in
    let wakeup = Atomic.make false in
    let outcome =
      KKS.interruptible_sleep
        ~wake_policy:KKS.Serve_wakeup_after_duration
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        (fun () -> 0.01)
    in
    check bool "no wakeup means Timeout" true
      (match outcome with
       | KKS.Timeout -> true
       | KKS.Stopped | KKS.Woken -> false))
;;

let test_stop_still_cuts_a_backoff_sleep () =
  Eio_main.run (fun env ->
    let stop = Atomic.make true in
    let wakeup = Atomic.make true in
    let outcome =
      KKS.interruptible_sleep
        ~wake_policy:KKS.Serve_wakeup_after_duration
        ~clock:(Eio.Stdenv.clock env)
        ~stop
        ~wakeup
        (fun () -> 30.0)
    in
    check bool "stop ends a backoff sleep at once" true
      (match outcome with
       | KKS.Stopped -> true
       | KKS.Woken | KKS.Timeout -> false))
;;

let test_dependency_change_interrupts_provider_rest () =
  Eio_main.run (fun env ->
    let stop = Atomic.make false in
    let wakeup = Atomic.make true in
    let invalidated = ref false in
    let outcome =
      KKS.interruptible_sleep
        ~wake_policy:KKS.Serve_wakeup_after_duration
        ~interrupt_when:(fun () -> !invalidated)
        ~clock:(Eio.Stdenv.clock env) ~stop ~wakeup
        (fun () -> invalidated := true; 3600.0)
    in
    check bool "dependency changes re-evaluate the lane before provider release" true
      (match outcome with KKS.Woken -> true | KKS.Stopped | KKS.Timeout -> false);
    check bool "the queued wake is consumed once" false (Atomic.get wakeup))
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
  | KWOBS.Available KWOBS.Not_addressed -> ()
  | KWOBS.Available (KWOBS.Wake reason) ->
    failf "goal keyword overlap woke as %s" (KWOBS.wake_reason_label reason)
  | KWOBS.Available (KWOBS.Unaddressed_comment _) ->
    fail "a post was classified as an unaddressed comment"
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

(* The audience the write boundary derives from a signal's text: a post reads an
   address from its title and body, a comment from its content. *)
let write_boundary_audience ~post_kind ~visibility (signal : Board_dispatch.board_signal) =
  let derived =
    match signal.kind with
    | Board_dispatch.Board_post_created | Board_dispatch.Board_post_updated _ ->
      Board.audience_for_post
        ~lookup:every_name_declared
        ~post_kind
        ~visibility
        ~title:signal.title
        ~content:signal.content
      |> Result.map fst
    | Board_dispatch.Board_comment_added _ ->
      Board.audience_for_comment ~lookup:every_name_declared ~content:signal.content
      |> Result.map fst
    | Board_dispatch.Board_reaction_changed _ -> Ok Board.audience_for_reaction
    | Board_dispatch.Board_vote_cast _ -> Ok Board.audience_for_vote
  in
  Result.map
    (fun board_audience ->
       match KBA.of_board_audience board_audience with
       | Ok audience -> audience
       | Error error -> fail (KBA.classification_error_to_string error))
    derived
;;

let classified ?(visibility = Board.Internal) signal =
  match write_boundary_audience ~post_kind:Board.Human_post ~visibility signal with
  | Ok audience -> audience
  | Error error -> fail (Board.show_board_error error)
;;

let route ~audience ~meta (signal : Board_dispatch.board_signal) =
  let signal = match Board_dispatch.read_post_unchecked ~post_id:signal.post_id with
    | Ok _ -> signal
    | Error _ ->
      let post = match Board_dispatch.create_post ~author:signal.author ~title:signal.title
          ~content:signal.content ~visibility:Board.Public ~post_kind:Board.Human_post () with
        | Ok post -> post | Error error -> fail (Board.Post_publication_failure.to_string error) in
      {signal with post_id=Board.Post_id.to_string post.id} in
  match KBA.route_for_keeper ~audience ~meta ~signal with
  | KWOBS.Available route -> route
  | KWOBS.Unavailable unavailable ->
    fail (KWOBS.unavailable_to_string unavailable)
;;

let test_closed_board_audience_routes_only_its_authority () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun _config ->
  let alpha =
    { (make_board_resume_meta "alpha") with board_interests = [ "research" ] }
  in
  let beta =
    { (make_board_resume_meta "beta") with board_interests = [ "research" ] }
  in
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
     audience consumers (routing and structural [mention_ids_of_signal])
     project the exact same Keeper id set.
     [Keeper_id.of_string] mints a raw-fallback id for non-Keeper names,
     so this also pins that behavior against regressions. *)
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
  let no_interests = { alpha with board_interests = [] } in
  check bool "empty interests do not disable exact delivery" true
    (match route ~audience:targeted_audience ~meta:no_interests targeted with
     | KBA.Deliver KWOBS.Explicit_mention -> true
     | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
  check bool "empty interests turn targetless discovery off" true
    (match route ~audience:discoverable_audience ~meta:no_interests discoverable with
     | KBA.Ignore -> true
     | KBA.Deliver _ | KBA.Judge_discoverable -> false);
  let hearth_only = { discoverable with hearth = Some "@alpha" } in
  check bool "Board category cannot become recipient authority" true
    (match classified hearth_only with KBA.Discoverable -> true | _ -> false);
  check bool "Board category is absent from mention metrics" false
    (KWOBS.match_signal ~meta:alpha ~signal:hearth_only).explicit_mention;
  let self_authored = audience_signal ~author:"alpha" "new research" in
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
      ~kind:
        (Board_dispatch.Board_comment_added
           { comment_id =
               (Board.Comment_id.of_string "c-00000000000000000000000000000001"
                |> Result.get_ok)
           ; parent_id = None
           })
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
  let unsupported = audience_signal ~author:"external-author" "@@delta inspect" in
  check bool "unsupported broadcast fails closed" true
    (match write_boundary_audience ~post_kind:Board.Human_post ~visibility:Board.Internal unsupported with
     | Error (Board.Validation_error _) -> true
     | Error _ | Ok _ -> false);
  check bool "Direct without targets fails closed" true
    (match write_boundary_audience ~post_kind:Board.Human_post ~visibility:Board.Direct discoverable with
     | Error (Board.Validation_error _) -> true
     | Error _ | Ok _ -> false);
  let mixed = audience_signal ~author:"external-author" "@alpha @@delta inspect" in
  check bool "mixed direct target and unsupported selector fails closed" true
    (match write_boundary_audience ~post_kind:Board.Human_post ~visibility:Board.Internal mixed with
     | Error (Board.Validation_error _) -> true
     | Error _ | Ok _ -> false);
  let direct_broadcast = audience_signal ~author:"external-author" "@@all inspect" in
  check bool "@@all on a Direct post fails closed" true
    (match write_boundary_audience ~post_kind:Board.Human_post ~visibility:Board.Direct direct_broadcast with
     | Error (Board.Validation_error _) -> true
     | Error _ | Ok _ -> false);
  check bool "@@all on a non-Direct post still broadcasts" true
    (match write_boundary_audience ~post_kind:Board.Human_post ~visibility:Board.Internal direct_broadcast with
     | Ok KBA.Broadcast -> true
     | Error _ | Ok _ -> false);
  check bool "a system post reads no address from its text" true
    (match write_boundary_audience ~post_kind:Board.System_post ~visibility:Board.Internal mixed with
     | Ok KBA.Discoverable -> true
     | Error _ | Ok _ -> false)

(* The text of a system post is evidence, so a lane whose name appears in it is
   not addressed. An Unlisted system post is thread activity; the lane that the
   same text names on a human post is delivered to. *)
let test_system_post_text_does_not_wake_the_named_lane () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun _config ->
  let alpha =
    { (make_board_resume_meta "alpha") with board_interests = [ "research" ] }
  in
  let signal =
    audience_signal ~author:"platform" "Rejected task t (vrf:v): @alpha please redo"
  in
  let audience_of post_kind =
    match write_boundary_audience ~post_kind ~visibility:Board.Unlisted signal with
    | Ok audience -> audience
    | Error error -> fail (Board.show_board_error error)
  in
  let system = audience_of Board.System_post in
  check bool "an unlisted system post is thread activity" true
    (match system with KBA.Thread_participants -> true | _ -> false);
  check bool "the lane its text names is not woken" true
    (match route ~audience:system ~meta:alpha signal with
     | KBA.Ignore -> true
     | KBA.Deliver _ | KBA.Judge_discoverable -> false);
  let human = audience_of Board.Human_post in
  check bool "the same text on a human post addresses the lane" true
    (match human with KBA.Targets _ -> true | _ -> false);
  check bool "and the lane is delivered to" true
    (match route ~audience:human ~meta:alpha signal with
     | KBA.Deliver KWOBS.Explicit_mention -> true
     | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
  (* The edit of a system post is read the same way. *)
  let edited = { signal with kind = Board_dispatch.Board_post_updated { content_updated_at = 1.0 } } in
  check bool "an edited system post wakes no lane either" true
    (match route ~audience:system ~meta:alpha edited with
     | KBA.Ignore -> true
     | KBA.Deliver _ | KBA.Judge_discoverable -> false)

let write_board_lane_config config (meta : Keeper_meta_contract.keeper_meta) =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_text (Filename.concat keepers_dir (meta.name ^ ".toml"))
    (fun oc -> Printf.fprintf oc
      "[keeper]\ninstructions = \"Review Board evidence.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nboard_interests = [%s]\nmention_targets = [%s]\n"
      (String.concat ", " (List.map (Printf.sprintf "%S") meta.board_interests))
      (String.concat ", " (List.map (Printf.sprintf "%S") meta.mention_targets)))
;;

let persist_and_register_board_lane config meta =
  write_board_lane_config config meta;
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail ("write_meta failed: " ^ detail));
  ignore
    (Keeper_registry.For_testing.register
       ~base_path:config.Workspace.base_path
       meta.Keeper_meta_contract.name
       meta)
;;

let board_queue_length config keeper_name =
  match
    Keeper_registry_event_queue.snapshot_result
      ~base_path:config.Workspace.base_path
      keeper_name
  with
  | Ok queue -> Keeper_event_queue.length queue
  | Error detail -> fail ("event queue snapshot failed: " ^ detail)
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
  | Error error -> fail (Board.Post_publication_failure.to_string error)
  | Ok post ->
    let signal = { signal with post_id = Board.Post_id.to_string post.id } in
    let audience =
      match
        Board.audience_for_post
          ~lookup:every_name_declared
          ~post_kind:post.post_kind
          ~visibility:post.visibility
          ~title:post.title
          ~content:post.body
      with
      | Ok (audience, _unresolved) -> audience
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
  with_board_workspace @@ fun config ->
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
  with_board_workspace @@ fun config ->
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
            ~content:"@alpha @@delta inspect"
            ~title:"mixed address"
            ~post_kind:Board.Human_post
            ~visibility:Board.Internal
            ()
        with
        | Ok _ -> fail "mixed-address post must be rejected at the write boundary"
        | Error failure when
            (match Board.Post_publication_failure.cause failure with
             | Board.Post_publication_failure.Board_error (Board.Validation_error _) -> true
             | Board.Post_publication_failure.Board_error _
             | Board.Post_publication_failure.Raised _ -> false) -> ()
        | Error error -> fail (Board.Post_publication_failure.to_string error));
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
  with_board_workspace @@ fun config ->
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
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let meta = make_board_resume_meta "restartlane" in
       write_board_lane_config config meta;
       (match Keeper_meta_store.replace_snapshot config meta with
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

let test_unregistered_persisted_exact_mention_is_durable_across_registration () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:Keeper_registry.For_testing.clear
    (fun () ->
       let meta = make_board_resume_meta "unregisteredlane" in
       write_board_lane_config config meta;
       (match Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error detail -> fail ("write_meta failed: " ^ detail));
       check bool "fixture starts unregistered" false
         (Keeper_registry.is_registered ~base_path:config.base_path meta.name);
       let signal : Board_dispatch.addressed_board_signal =
         { kind = Board_dispatch.Board_post_created
         ; post_id = "post-unregistered-lane"
         ; author = "external-author"
         ; title = "addressed"
         ; content = "@unregisteredlane retain this before boot"
         ; hearth = None
         ; updated_at = Some 124.75
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "unregistered persisted keeper receives durable signal" 1
         (board_queue_length config meta.name);
       let entry =
         Keeper_registry.For_testing.register
           ~base_path:config.base_path
           meta.name
           meta
       in
       check int "registered keeper inherits durable queue" 1
         (Keeper_event_queue.length (Atomic.get entry.event_queue)))
;;

let test_lane_meta_failure_does_not_block_next_durable_delivery () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
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

(* The nested reply targets the keeper's exact parent comment. Its author
   must be read successfully from the Board store before direct delivery. *)
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
    | Error error -> fail (Board.Post_publication_failure.to_string error)
    | Ok post -> post
  in
  let post_id = Board.Post_id.to_string post.id in
  let add_comment ?parent_id ~author ~content () =
    match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author ~content ?parent_id () with
    | Error error -> fail (Board.show_board_error error)
    | Ok comment -> comment
  in
  let parent = add_comment ~author:meta.Keeper_meta_contract.name ~content:"keeper was here" () in
  let comment = add_comment ~parent_id:(Board.Comment_id.to_string parent.id)
      ~author:"external-author" ~content:"follow up" () in
  let signal : Board_dispatch.addressed_board_signal =
    { signal =
        { kind =
            Board_dispatch.Board_comment_added
              { comment_id = comment.id; parent_id = comment.parent_id }
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

(* A thread signal whose post is gone from the store has an unavailable
   relevance read. The push path routes once, delivers nothing and does not
   wake the lane. *)
let test_thread_signal_for_a_swept_post_delivers_nothing () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta, signal = create_thread_fixture config ~keeper_name:"sweptlane" in
       (match Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id:signal.signal.post_id with
        | Ok Board.Durable_deletion -> ()
        | Ok (Board.Deletion_decision_pending detail) -> Alcotest.fail detail
        | Ok (Board.Deletion_persistence_pending detail) -> fail detail
        | Error error -> fail (Board.show_board_error error));
       check bool "missing parent post is unavailable" true
         (match KBA.route_for_keeper ~audience:KBA.Thread_participants ~meta
                  ~signal:signal.signal with
          | KWOBS.Unavailable { operation = KWOBS.Get_post; _ } -> true
          | KWOBS.Available _ | KWOBS.Unavailable _ -> false);
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "lane queue stays empty" 0 (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "lane not woken" false (Atomic.get entry.fiber_wakeup)
       | None -> fail "sweptlane registry entry missing")
;;

(* The author of a post is a thread participant. [check_self_comment_status]
   only looks for the keeper's own comments, so before the authorship check an
   answer to a keeper's question never reached the keeper that asked. Measured
   on the live Board: 72 of 98 external comments on Keeper posts did not wake
   the poster. This fixture is the one the old rule missed — the keeper wrote
   the post and never commented on it. *)
let create_self_post_fixture config ~keeper_name =
  let meta = make_board_resume_meta keeper_name in
  persist_and_register_board_lane config meta;
  let post =
    match
      Board_dispatch.create_post
        ~author:meta.Keeper_meta_contract.name
        ~content:"does anyone know why the fixture is empty?"
        ~title:"question from the keeper"
        ~post_kind:Board.Human_post
        ~visibility:Board.Internal
        ()
    with
    | Error error -> fail (Board.Post_publication_failure.to_string error)
    | Ok post -> post
  in
  let post_id = Board.Post_id.to_string post.id in
  let comment =
    match
      Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
        ~post_id
        ~author:"external-author"
        ~content:"it is empty because the loader skips it"
        ()
    with
    | Error error -> fail (Board.show_board_error error)
    | Ok comment -> comment
  in
  let signal : Board_dispatch.addressed_board_signal =
    { signal =
        { kind =
            Board_dispatch.Board_comment_added
              { comment_id = comment.id; parent_id = comment.parent_id }
        ; post_id
        ; author = "external-author"
        ; title = "question from the keeper"
        ; content = "it is empty because the loader skips it"
        ; hearth = None
        ; updated_at = Some 130.5
        }
    ; audience = Board.Thread_participants
    }
  in
  meta, signal
;;

let test_comment_on_own_post_wakes_the_author () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta, signal = create_self_post_fixture config ~keeper_name:"posterlane" in
       KKS.wakeup_relevant_keeper_for_board_signal ~config signal;
       check int "author lane receives the comment" 1
         (board_queue_length config meta.name);
       match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some entry ->
         check bool "author woken by a comment on its own post" true
           (Atomic.get entry.fiber_wakeup)
       | None -> fail "posterlane registry entry missing")
;;

(* #29457: votes travel the same hook as comments and reactions. This drives
   the real producer ([Board_dispatch.vote] / [vote_comment]) through the real
   hook into the durable queue, so the whole path is measured: one vote on
   the keeper's writing is one stimulus for the author lane; a duplicate
   same-direction vote is [Already_voted] and adds nothing; the keeper's own
   vote on its own writing addresses nobody. *)
let vote_queue_kinds config keeper_name =
  match
    Keeper_registry_event_queue.snapshot_result
      ~base_path:config.Workspace.base_path
      keeper_name
  with
  | Error detail -> fail ("event queue snapshot failed: " ^ detail)
  | Ok queue ->
    Keeper_event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Board_signal { kind = Keeper_event_queue.Vote_cast vote; _ } ->
        Some vote
      | _ -> None)
;;

let create_post_exn ~author ~title ~content =
  match
    Board_dispatch.create_post
      ~author
      ~content
      ~title
      ~post_kind:Board.Human_post
      ~visibility:Board.Internal
      ()
  with
  | Error error -> fail (Board.Post_publication_failure.to_string error)
  | Ok post -> Board.Post_id.to_string post.id
;;

let test_vote_on_own_post_wakes_the_author_once () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.set_board_signal_hook (fun _ -> ());
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta = make_board_resume_meta "voterlane" in
       persist_and_register_board_lane config meta;
       Board_dispatch.set_board_signal_hook (fun signal ->
         KKS.wakeup_relevant_keeper_for_board_signal ~config signal);
       let post_id =
         create_post_exn
           ~author:meta.Keeper_meta_contract.name
           ~title:"keeper finding"
           ~content:"the loader skips empty fixtures"
       in
       (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"external-voter" ~post_id ~direction:Board.Up with
        | Error error -> fail (Board.show_board_error error)
        | Ok _ -> ());
       check int "one vote is one stimulus for the author" 1
         (board_queue_length config meta.name);
       (match vote_queue_kinds config meta.name with
        | [ vote ] ->
          check string "stimulus names the voter" "external-voter" vote.voter;
          check string "stimulus names the voted-on author"
            meta.Keeper_meta_contract.name vote.target_author;
          (match vote.direction with
           | Keeper_event_queue.Vote_up -> ()
           | Keeper_event_queue.Vote_down -> fail "direction must be up");
          (match vote.target with
           | Keeper_event_queue.Vote_on_post id -> check string "post target" post_id id
           | Keeper_event_queue.Vote_on_comment _ -> fail "target must be the post")
        | votes -> failf "expected one vote stimulus, got %d" (List.length votes));
       (match Keeper_registry.get ~base_path:config.base_path meta.name with
        | Some entry ->
          (* #54342: votes use Carry wake policy — durably queued for the
             Keeper's next turn without triggering an immediate wakeup storm. *)
          check bool "vote carries without immediate wakeup" false (Atomic.get entry.fiber_wakeup)
        | None -> fail "voterlane registry entry missing");
       (* Same voter, same direction: Already_voted, nothing new to act on. *)
       (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"external-voter" ~post_id ~direction:Board.Up with
        | Error (Board.Already_voted _) -> ()
        | Ok _ -> fail "expected Already_voted"
        | Error error -> fail (Board.show_board_error error));
       check int "duplicate vote adds no stimulus" 1 (board_queue_length config meta.name);
       (* The keeper voting on its own post addresses no lane. *)
       (match
          Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator
            ~voter:meta.Keeper_meta_contract.name
            ~post_id
            ~direction:Board.Up
        with
        | Error error -> fail (Board.show_board_error error)
        | Ok _ -> ());
       check int "self vote adds no stimulus" 1 (board_queue_length config meta.name))
;;

(* A comment vote addresses the comment's author, not the post's. *)
let test_vote_on_own_comment_wakes_the_commenter_not_the_poster () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.set_board_signal_hook (fun _ -> ());
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let poster = make_board_resume_meta "posterlane" in
       let commenter = make_board_resume_meta "commenterlane" in
       persist_and_register_board_lane config poster;
       persist_and_register_board_lane config commenter;
       Board_dispatch.set_board_signal_hook (fun signal ->
         KKS.wakeup_relevant_keeper_for_board_signal ~config signal);
       let post_id =
         create_post_exn
           ~author:poster.Keeper_meta_contract.name
           ~title:"question"
           ~content:"why is the fixture empty?"
       in
       let comment_id =
         match
           Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator
             ~post_id
             ~author:commenter.Keeper_meta_contract.name
             ~content:"the loader skips it"
             ()
         with
         | Error error -> fail (Board.show_board_error error)
         | Ok comment -> Board.Comment_id.to_string comment.id
       in
       (* The comment itself woke the poster; measure only the vote from here. *)
       let poster_before = board_queue_length config poster.name in
       let commenter_before = board_queue_length config commenter.name in
       (match
          Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator
            ~voter:"external-voter"
            ~comment_id
            ~direction:Board.Down
        with
        | Error error -> fail (Board.show_board_error error)
        | Ok _ -> ());
       check int "commenter receives the comment vote" (commenter_before + 1)
         (board_queue_length config commenter.name);
       check int "poster is not addressed by a vote on someone else's comment"
         poster_before
         (board_queue_length config poster.name);
       match vote_queue_kinds config commenter.name with
       | [ vote ] ->
         (match vote.target with
          | Keeper_event_queue.Vote_on_comment id -> check string "comment target" comment_id id
          | Keeper_event_queue.Vote_on_post _ -> fail "target must be the comment");
         (match vote.direction with
          | Keeper_event_queue.Vote_down -> ()
          | Keeper_event_queue.Vote_up -> fail "direction must be down")
       | votes -> failf "expected one vote stimulus, got %d" (List.length votes))
;;

(* #27329 regression: a comment on an internal thread classifies as [Thread_participants],
   and a lane that never touched the thread has no deterministic address —
   [wake_reason] reports an unaddressed comment. That used to fold to [Ignore]
   for every non-participant lane, so a comment could never reach attention
   judgment: [Judge_discoverable] was produced only for the [Discoverable]
   audience. Now an unaddressed comment escalates to [Judge_discoverable] on
   a discoverable thread and the push path records the
   attention candidate, while the participant lane keeps its direct
   delivery. *)
let test_comment_routes_bystander_lane_to_attention_judgment () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.set_board_signal_hook (fun _ -> ());
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let meta, addressed = create_thread_fixture config ~keeper_name:"threadlane" in
       let bystander =
         { (make_board_resume_meta "bystanderlane") with
           board_interests = [ "thread review" ]
         }
       in
       persist_and_register_board_lane config bystander;
       let bystander =
         match Keeper_meta_store.read_effective_meta config bystander.name with
         | Ok (Some meta) -> meta
         | Ok None -> fail "configured bystander metadata missing"
         | Error detail -> fail detail
       in
       check (list string) "bystander interests come from actual TOML"
         [ "thread review" ] bystander.board_interests;
       let audience =
         match KBA.of_board_audience addressed.Board_dispatch.audience with
         | Ok audience -> audience
         | Error error -> fail (KBA.classification_error_to_string error)
       in
       check bool "participant lane keeps direct delivery" true
         (match route ~audience ~meta addressed.Board_dispatch.signal with
          | KBA.Deliver KWOBS.Reply_to_self_comment -> true
          | KBA.Deliver _ | KBA.Judge_discoverable | KBA.Ignore -> false);
       check bool "bystander lane escalates to judgment" true
         (match route ~audience ~meta:bystander addressed.Board_dispatch.signal with
          | KBA.Judge_discoverable -> true
          | KBA.Deliver _ | KBA.Ignore -> false);
       check bool "empty-interest bystander is not judged" true
         (match
            route
              ~audience
              ~meta:{ bystander with board_interests = [] }
              addressed.Board_dispatch.signal
          with
          | KBA.Ignore -> true
          | KBA.Deliver _ | KBA.Judge_discoverable -> false);
       KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
       check int "participant lane still wakes directly" 1
         (board_queue_length config meta.Keeper_meta_contract.name);
       check int "bystander lane is not directly woken" 0
         (board_queue_length config bystander.Keeper_meta_contract.name);
       check int "bystander lane holds one attention candidate" 1
         (board_attention_count config bystander.Keeper_meta_contract.name);
       check int "participant lane holds no attention candidate" 0
         (board_attention_count config meta.Keeper_meta_contract.name))
;;

let test_comment_discovery_respects_parent_visibility () =
  Eio_main.run @@ fun _env ->
  List.iter
    (fun (label, visibility, expected_candidates) ->
       with_board_workspace @@ fun config ->
       Fun.protect
         ~finally:Keeper_registry.For_testing.clear
         (fun () ->
            let poster = make_board_resume_meta "posterlane" in
            let parent_author = make_board_resume_meta "threadlane" in
            let bystander =
              { (make_board_resume_meta "bystanderlane") with
                board_interests = [ "thread review" ] } in
            List.iter (persist_and_register_board_lane config) [ poster; parent_author; bystander ];
            let content = match visibility with
              | Board.Direct -> "@threadlane thread topic"
              | Board.Public | Board.Internal | Board.Unlisted -> "thread topic" in
            let get = function
              | Ok value -> value
              | Error error -> fail (Board.show_board_error error) in
            let post = match Board_dispatch.create_post ~author:poster.name
              ~content ~title:"thread" ~post_kind:Board.Human_post ~visibility () with
              | Ok post -> post
              | Error error -> fail (Board.Post_publication_failure.to_string error) in
            let post_id = Board.Post_id.to_string post.id in
            let parent = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:parent_author.name
              ~content:"keeper was here" ()) in
            Board_dispatch.set_board_signal_hook (KKS.wakeup_relevant_keeper_for_board_signal ~config);
            ignore (get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"external-author"
              ~parent_id:(Board.Comment_id.to_string parent.id) ~content:"follow up" ()));
            check int (label ^ ": direct parent receives its reply") 1
              (board_queue_length config parent_author.name);
            check int (label ^ ": post author receives its reply") 1
              (board_queue_length config poster.name);
            check int (label ^ ": bystander is not directly woken") 0
              (board_queue_length config bystander.name);
            check int (label ^ ": bystander attention candidates") expected_candidates
              (board_attention_count config bystander.name)))
    [ "public", Board.Public, 1
    ; "internal", Board.Internal, 1
    ; "unlisted", Board.Unlisted, 0
    ; "direct", Board.Direct, 0
    ]
;;

let test_unresolved_comment_name_cannot_become_a_recipient () =
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
       with_board_workspace ~recipient_lookup @@ fun config ->
       Fun.protect
         ~finally:(fun () ->
           Board_dispatch.set_board_signal_hook (fun _ -> ());
           Keeper_registry.For_testing.clear ())
         (fun () ->
            let poster = make_board_resume_meta "posterlane" in
            let parent_author = make_board_resume_meta "threadlane" in
            let bystander =
              { (make_board_resume_meta "bystanderlane") with
                board_interests = [ "thread review" ] } in
            List.iter (persist_and_register_board_lane config) [ poster; parent_author; bystander ];
            let get = function
              | Ok value -> value
              | Error error -> fail (Board.show_board_error error) in
            let post = match Board_dispatch.create_post ~author:poster.name
              ~content:"@threadlane thread topic" ~title:"thread"
              ~post_kind:Board.Human_post ~visibility () with
              | Ok post -> post
              | Error error -> fail (Board.Post_publication_failure.to_string error) in
            let post_id = Board.Post_id.to_string post.id in
            let parent = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:parent_author.name
              ~content:"keeper was here" ()) in
            let last_signal = ref None in
            Board_dispatch.set_board_signal_hook (fun addressed -> last_signal := Some addressed);
            let comment = get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"external-author"
              ~parent_id:(Board.Comment_id.to_string parent.id)
              ~content:"@latealias research" ()) in
            check bool (label ^ ": unresolved name was stored as thread audience") true
              (comment.audience = Some Board.Thread_participants);
            let addressed = Option.get !last_signal in
            alias_declared := true;
            let bystander = { bystander with mention_targets = [ "latealias" ] } in
            write_board_lane_config config bystander;
            (match Keeper_meta_store.read_effective_meta config bystander.name with
             | Ok (Some meta) ->
               check (list string) (label ^ ": later alias is active")
                 [ "latealias" ] meta.mention_targets
             | Ok None -> fail "configured bystander metadata missing"
             | Error detail -> fail detail);
            KKS.wakeup_relevant_keeper_for_board_signal ~config addressed;
            check int (label ^ ": post author receives the comment") 1
              (board_queue_length config poster.name);
            check int (label ^ ": parent author receives the reply") 1
              (board_queue_length config parent_author.name);
            check int (label ^ ": later alias does not directly receive old text") 0
              (board_queue_length config bystander.name);
            check int (label ^ ": discovery still follows visibility") expected_candidates
              (board_attention_count config bystander.name);
            let poster_with_late_alias =
              { poster with mention_targets = [ poster.name; "latealias" ] }
            in
            (match Keeper_registry_event_queue.snapshot_result
                     ~base_path:config.base_path poster.name with
             | Error detail -> fail detail
             | Ok queue ->
               (match Keeper_event_queue.to_list queue with
                | [ stimulus ] ->
                  (match Keeper_world_observation.pending_board_event_of_stimulus
                           ~base_path:config.base_path ~meta:poster_with_late_alias stimulus with
                   | Ok (Some event) ->
                     check bool (label ^ ": input assembly preserves recorded thread audience")
                       false event.explicit_mention;
                     check (list string) (label ^ ": input assembly matches no late alias")
                       [] event.matched_targets
                   | Ok None -> fail "expected queued comment event for post author"
                   | Error unavailable ->
                     fail (KWOBS.unavailable_to_string unavailable))
                | _ -> fail "expected exactly one queued stimulus for post author"));
            ignore (get (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"external-author"
              ~content:"@latealias explicit target" ()));
            let addressed_target = Option.get !last_signal in
            check bool (label ^ ": newly resolved name is a stored target") true
              (match addressed_target.audience with Board.Targets _ -> true | _ -> false);
            KKS.wakeup_relevant_keeper_for_board_signal ~config addressed_target;
            check int (label ^ ": stored target still receives a direct comment") 1
              (board_queue_length config bystander.name);
            (match Keeper_registry_event_queue.snapshot_result
                     ~base_path:config.base_path bystander.name with
             | Error detail -> fail detail
             | Ok queue ->
               (match Keeper_event_queue.to_list queue with
                | [ stimulus ] ->
                  (match Keeper_world_observation.pending_board_event_of_stimulus
                           ~base_path:config.base_path ~meta:bystander stimulus with
                   | Ok (Some event) ->
                     check bool (label ^ ": recorded target sets explicit_mention in input assembly")
                       true event.explicit_mention;
                     check (list string) (label ^ ": recorded target preserves matched_targets")
                       [ "latealias" ] event.matched_targets
                   | Ok None -> fail "expected queued target event for bystander"
                   | Error unavailable ->
                     fail (KWOBS.unavailable_to_string unavailable))
                | _ -> fail "expected exactly one queued stimulus for bystander"))))
    (* A Direct thread cannot reach the "later alias" step below: #50387 makes
       a comment on a Direct post addressable only to the parent post's
       readers (lib/board/board_comment_admission.ml), so replying with a name
       resolved outside that set is refused instead of stored. The Direct
       refusal is pinned by [test_direct_comment_cannot_address_a_non_reader]. *)
    [ "public", Board.Public, 1
    ; "internal", Board.Internal, 1
    ; "unlisted", Board.Unlisted, 0
    ]
;;

(* #50387: a comment on a Direct post may address only the parent post's
   readers. A name resolved outside that set cannot be added by replying, so
   the reply is refused and nothing is stored. *)
let test_direct_comment_cannot_address_a_non_reader () =
  Eio_main.run @@ fun _env ->
  (* [latealias] stays unresolved for the first comment and resolves for the
     second, so the two steps differ only in the name's state. *)
  let resolved = ref false in
  let recipient_lookup =
    Recipient_lookup.make (fun candidate ->
      let name = Recipient_lookup.Candidate.to_string candidate in
      if String.equal name "latealias" && not !resolved
      then Ok None
      else Ok (Result.to_option (Board.Agent_id.parse name))) in
  with_board_workspace ~recipient_lookup @@ fun config ->
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.set_board_signal_hook (fun _ -> ());
      Keeper_registry.For_testing.clear ())
    (fun () ->
       let poster = make_board_resume_meta "posterlane" in
       persist_and_register_board_lane config poster;
       let post =
         match
           Board_dispatch.create_post ~author:poster.name ~content:"@posterlane direct topic"
             ~title:"direct" ~post_kind:Board.Human_post ~visibility:Board.Direct ()
         with
         | Ok post -> post
         | Error error -> fail (Board.Post_publication_failure.to_string error) in
       let post_id = Board.Post_id.to_string post.id in
       (match
          Board_dispatch.add_comment
            ~reader:Masc_board_handlers.Board_access.Operator ~post_id
            ~author:"external-author" ~content:"@latealias research" ()
        with
        | Ok comment ->
          Alcotest.(check bool) "unresolved name stays a thread audience" true
            (comment.audience = Some Board.Thread_participants)
        | Error error -> fail (Board.show_board_error error));
       (* The name resolves now, so the reply addresses it directly. *)
       resolved := true;
       match
         Board_dispatch.add_comment
           ~reader:Masc_board_handlers.Board_access.Operator ~post_id
           ~author:"external-author" ~content:"@latealias explicit target" ()
       with
       | Ok _ -> fail "a Direct comment addressed a name outside the parent's readers"
       | Error (Board.Validation_error _) -> ()
       | Error error -> fail (Board.show_board_error error))
;;

(* RFC-provider-path-rest §3.3: a path's rest comes from the provider's answer
   alone. A usable hint rests that long (at least 1 s, #35246) whatever the
   keeper cadence is; without one a throttle rests the named floor and a hard
   quota rests the fallback cap. A usable provider hint outlives that cap. *)
let test_path_rest_follows_the_answer_not_the_cadence () =
  let rest = Keeper_runtime_failure_route.path_rest_sec ~cap_sec:900.0 in
  let floor_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec in
  let rate_limited = Keeper_runtime_failure_route.Rate_limited in
  let hard_quota = (Keeper_runtime_failure_route.Hard_quota Keeper_runtime_failure_route.Provider_quota_refused) in
  check (float 0.001) "a stated 5 s rests 5 s" 5.0
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 5.0));
  check (float 0.001) "a stated 120 s rests 120 s" 120.0
    (rest ~retry_class:hard_quota ~retry_after_hint:(Some 120.0));
  check (float 0.001) "a sub-second hint rests one second" 1.0
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 0.001));
  check (float 0.001) "an unstated throttle rests the floor" floor_sec
    (rest ~retry_class:rate_limited ~retry_after_hint:None);
  check (float 0.001) "an unstated provider capacity refusal rests the floor" floor_sec
    (rest ~retry_class:Keeper_runtime_failure_route.Provider_capacity
       ~retry_after_hint:None);
  check (float 0.001) "an unstated hard quota rests the cap" 900.0
    (rest ~retry_class:hard_quota ~retry_after_hint:None);
  check (float 0.001) "a zero hint is unstated" floor_sec
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 0.0));
  check (float 0.001) "a negative hint is unstated" floor_sec
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some (-5.0)));
  check (float 0.5) "a NaN hint is unstated" floor_sec
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some nan));
  check (float 0.001) "a stated reset outlives the fallback cap" 43200.0
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 43200.0));
  check (float 0.001) "a stated reset above the ceiling clamps to max_retry_after_s"
    Keeper_runtime_failure_route.max_retry_after_s
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 120000.0));
  check (float 0.001) "a Unix-epoch retry-after clamps to max_retry_after_s"
    Keeper_runtime_failure_route.max_retry_after_s
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some 1_760_000_000.0));
  check (float 0.001) "a hard quota reset outlives the fallback cap" 4470.0
    (rest ~retry_class:hard_quota ~retry_after_hint:(Some 4470.0));
  check (float 0.001) "an infinite hint is unstated" floor_sec
    (rest ~retry_class:rate_limited ~retry_after_hint:(Some infinity));
  check bool "default cap is not below the named floor" true
    (Float.compare Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec floor_sec
     >= 0)
;;

(* ── Test runner ─── *)

(* Audit S9: the Owner-registry rejection at shutdown comes in two shapes,
   the Owner itself stopping and the Owner inventory stopping. Both must
   end the cycle without a turn; only the second used to fall into the
   crash arm. Every other rejection ran no turn either, so it is not a failed
   turn (#34673). *)
let test_owner_inventory_stopping_completes_the_cycle () =
  let status = Keeper_heartbeat_loop.owner_turn_rejection_cycle_status in
  let name = function
    | Keeper_heartbeat_loop.Turn_cycle_turn_succeeded -> "turn_succeeded"
    | Keeper_heartbeat_loop.Turn_cycle_turn_failed -> "turn_failed"
    | Keeper_heartbeat_loop.Turn_cycle_without_turn -> "without_turn"
    | Keeper_heartbeat_loop.Turn_cycle_lifecycle_blocked -> "lifecycle_blocked"
    | Keeper_heartbeat_loop.Turn_cycle_owner_rejected -> "owner_rejected"
    | Keeper_heartbeat_loop.Turn_cycle_interrupted -> "interrupted"
    | Keeper_heartbeat_loop.Turn_cycle_crashed -> "crashed"
    | Keeper_heartbeat_loop.Turn_cycle_busy _ -> "busy"
    | Keeper_heartbeat_loop.Turn_cycle_rested -> "rested"
  in
  check string "inventory stopping ends the cycle without a turn" "without_turn"
    (name
       (status
          (Keeper_owner_registry.Command_lookup_failed
             Keeper_owner_registry.Inventory_stopping)));
  check string "owner stopping ends the cycle without a turn" "without_turn"
    (name
       (status
          (Keeper_owner_registry.Command_rejected Keeper_owner.Owner_stopping)));
  check string "owner not found is an owner rejection" "owner_rejected"
    (name
       (status
          (Keeper_owner_registry.Command_lookup_failed
             (Keeper_owner_registry.Owner_not_found "keeper-a"))));
  check string "owner closed is an owner rejection" "owner_rejected"
    (name
       (status (Keeper_owner_registry.Command_rejected Keeper_owner.Owner_closed)))
;;

let test_owner_inventory_stopping_refreshes_work_heartbeat () =
  let action =
    Keeper_heartbeat_loop.decide_keepalive_cycle_action
      (Keeper_heartbeat_loop.owner_turn_rejection_cycle_status
         (Keeper_owner_registry.Command_lookup_failed
            Keeper_owner_registry.Inventory_stopping))
  in
  let refreshes =
    match action with
    | Keeper_heartbeat_loop.Refresh_without_turn_status -> true
    | Keeper_heartbeat_loop.Record_turn_status
        ( ( Keeper_heartbeat_loop.Cycle_turn_succeeded
          | Keeper_heartbeat_loop.Cycle_turn_failed )
        , ( Keeper_heartbeat_loop.Refresh_work_heartbeat
          | Keeper_heartbeat_loop.Preserve_work_heartbeat ) )
    | Keeper_heartbeat_loop.Skip_interrupted_turn
    | Keeper_heartbeat_loop.Skip_unadmitted_cycle
    | Keeper_heartbeat_loop.Defer_autonomous_work _ -> false
  in
  check bool
    "shutdown boundary renews the lease and records no turn status"
    true
    refreshes
;;

let test_comments_address_post_and_direct_parent_only () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  Fun.protect
    ~finally:(fun () -> Board_dispatch.set_board_signal_hook (fun _ -> ()); Keeper_registry.For_testing.clear ())
    (fun () ->
      let poster = make_board_resume_meta "poster" in
      let parent_author = make_board_resume_meta "parent-author" in
      let participant = { (make_board_resume_meta "past-participant") with board_interests = [ "research" ] } in
      List.iter (persist_and_register_board_lane config) [poster; parent_author; participant];
      let post = match Board_dispatch.create_post ~author:poster.name ~content:"research question"
          ~title:"thread" ~post_kind:Board.Human_post ~visibility:Board.Internal () with
        | Ok post -> post | Error error -> fail (Board.Post_publication_failure.to_string error) in
      let post_id = Board.Post_id.to_string post.id in
      let add ?parent_id author =
        match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author ~content:"same text" ?parent_id () with
        | Ok comment -> comment | Error error -> fail (Board.show_board_error error) in
      let parent = add parent_author.name in
      ignore (add participant.name);
      let last_signal = ref None in
      Board_dispatch.set_board_signal_hook (fun addressed ->
        last_signal := Some addressed;
        KKS.wakeup_relevant_keeper_for_board_signal ~config addressed);
      ignore (add "external-author");
      check int "top-level comment reaches poster" 1 (board_queue_length config poster.name);
      check int "past comment does not address its author" 0 (board_queue_length config parent_author.name);
      check int "other participant is not directly addressed" 0 (board_queue_length config participant.name);
      check int "interested non-target receives judgment candidate" 1 (board_attention_count config participant.name);
      ignore (add ~parent_id:(Board.Comment_id.to_string parent.id) "external-author");
      check int "nested comment still reaches poster" 2 (board_queue_length config poster.name);
      check int "nested comment reaches exact parent author" 1 (board_queue_length config parent_author.name);
      check int "unrelated participant remains undelivered" 0 (board_queue_length config participant.name);
      check int "interested non-target judges each distinct comment" 2 (board_attention_count config participant.name);
      let signal = (Option.get !last_signal).Board_dispatch.signal in
      let missing = Board.Comment_id.of_string "c-00000000000000000000000000000001" |> Result.get_ok in
      let signal = match signal.kind with
        | Board_dispatch.Board_comment_added identity ->
          { signal with kind = Board_dispatch.Board_comment_added { identity with parent_id = Some missing } }
        | _ -> assert false in
      check bool "missing direct parent is unavailable, not a guessed recipient" true
        (match KWOBS.wake_reason ~meta:parent_author ~signal with
         | KWOBS.Unavailable { error = Board.Read_comment_not_found _; _ } -> true
         | _ -> false))
;;


let test_committed_board_action_retains_unavailable_routing action () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_board_workspace @@ fun config ->
  let meta = make_board_resume_meta "retainedlane" in
  persist_and_register_board_lane config meta;
  let post = match Board_dispatch.create_post ~author:meta.name
    ~title:"private retained event" ~content:"@retainedlane private original"
    ~post_kind:Board.Human_post ~visibility:Board.Direct () with
    | Ok post -> post | Error error -> fail (Board.Post_publication_failure.to_string error) in
  let post_id = Board.Post_id.to_string post.id in
  let store = Board.global () in
  let posts = Board.persist_path store in
  let held = posts ^ ".test-held" in
  let committed = ref None in
  Fun.protect ~finally:(fun () ->
    Board_dispatch.set_board_signal_hook (fun _ -> ());
    if Sys.file_exists held then Unix.rename held posts;
    Keeper_registry.For_testing.clear ())
  @@ fun () ->
  (* This hook runs after the actual vote/reaction commit. A different fiber's
     source reload can observe precisely this refusal before routing reads. *)
  Board_dispatch.set_board_signal_hook (fun addressed ->
    committed := Some addressed;
    Unix.rename posts held;
    (match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
     | Error _ -> () | Ok _ -> fail "missing primary was admitted");
    KKS.wakeup_relevant_keeper_for_board_signal ~config addressed);
  (match action with
   | `Vote -> ignore (Result.get_ok (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator
       ~voter:"external-voter" ~post_id ~direction:Board.Up))
   | `Reaction -> ignore (Result.get_ok (Board_dispatch.toggle_reaction
       ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
       ~target_id:post_id ~user_id:"external-reactor" ~emoji:"👍")));
  let addressed = Option.get !committed in
  let pending () = match Keeper_registry_event_queue.pending_selections_result
    ~base_path:config.base_path meta.name with
    | Ok selections -> selections | Error detail -> fail detail in
  let selection = match pending () with [selection] -> selection
    | _ -> fail "a committed action did not retain one routing source" in
  (match selection.source.payload with
   | Keeper_event_queue.Board_routing_pending bs ->
     check bool "original kind/content/audience retained" true
       (bs = KWOBS.board_stimulus_of_board_signal addressed)
   | _ -> fail "unavailable routing was admitted as a delivery");
  let entry = Option.get (Keeper_registry.get ~base_path:config.base_path meta.name) in
  check bool "unavailable routing requests no owner wake" false (Atomic.get entry.fiber_wakeup);
  (match Keeper_world_observation.pending_board_event_of_stimulus
    ~base_path:config.base_path ~meta selection.source with
   | Error {error=Board.Read_source_unavailable _;_} -> ()
   | _ -> fail "refused authority did not retain pending routing");
  check bool "same durable selection remains after refused read" true
    (match pending () with [same] -> Keeper_event_queue_state.same_entry selection same | _ -> false);
  Unix.rename held posts;
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
   | Ok _ -> () | Error (_,error) -> fail (Printexc.to_string error));
  let expected = match action with `Vote -> KWOBS.Vote_on_self_post
    | `Reaction -> KWOBS.Reaction_after_self_activity in
  (match KBA.route_for_keeper ~audience:KBA.Thread_participants ~meta ~signal:addressed.signal with
   | KWOBS.Available (KBA.Deliver reason) -> check bool "original actual route recovers" true (reason=expected)
   | _ -> fail "recovery changed original thread routing");
  (match Keeper_world_observation.pending_board_event_of_stimulus
    ~base_path:config.base_path ~meta selection.source with
   | Ok (Some event) -> check string "same event parent is projected" post_id event.post_id
   | _ -> fail "retained action did not project after recovery")
;;

let test_typed_wake_policy_and_inbound_queue_modes () =
  let check_policy label expected ~input_kind ~sender_kind =
    check bool label true
      (KKS.stimulus_wake_policy_of ~input_kind ~sender_kind = expected)
  in
  check_policy "human direct message wakes Now" KKS.Now
    ~input_kind:KKS.Direct_message ~sender_kind:KKS.Human_sender;
  check_policy "connector direct message wakes Now" KKS.Now
    ~input_kind:KKS.Direct_message ~sender_kind:KKS.Connector_sender;
  check_policy "keeper direct message coalesces At_tick" KKS.At_tick
    ~input_kind:KKS.Direct_message ~sender_kind:KKS.Keeper_sender;
  check_policy "human board mention wakes Now" KKS.Now
    ~input_kind:KKS.Board_mention_or_reply ~sender_kind:KKS.Human_sender;
  check_policy "keeper board mention coalesces At_tick" KKS.At_tick
    ~input_kind:KKS.Board_mention_or_reply ~sender_kind:KKS.Keeper_sender;
  check_policy "own async completion wakes Now" KKS.Now
    ~input_kind:KKS.Own_async_completion ~sender_kind:KKS.Own_async_sender;
  check_policy "reactions and votes Carry" KKS.Carry
    ~input_kind:KKS.Board_reaction_or_vote ~sender_kind:KKS.Human_sender;
  check_policy "ambient board attention Carries" KKS.Carry
    ~input_kind:KKS.Board_attention_ambient ~sender_kind:KKS.System_sender;
  check_policy "approved task outcome Carries" KKS.Carry
    ~input_kind:KKS.Task_outcome_approved ~sender_kind:KKS.System_sender;
  (* Inbound queue modes: Steer | FollowUp | Coalesce *)
  check bool "human Now during active turn steers" true
    (KKS.inbound_queue_mode_of ~turn_running:true ~wake_policy:KKS.Now
       ~sender_kind:KKS.Human_sender = KKS.Steer);
  check bool "connector Now during active turn steers" true
    (KKS.inbound_queue_mode_of ~turn_running:true ~wake_policy:KKS.Now
       ~sender_kind:KKS.Connector_sender = KKS.Steer);
  check bool "own-async Now during active turn follows up" true
    (KKS.inbound_queue_mode_of ~turn_running:true ~wake_policy:KKS.Now
       ~sender_kind:KKS.Own_async_sender = KKS.FollowUp);
  check bool "At_tick coalesces during active turn" true
    (KKS.inbound_queue_mode_of ~turn_running:true ~wake_policy:KKS.At_tick
       ~sender_kind:KKS.Keeper_sender = KKS.Coalesce);
  check bool "Carry coalesces while idle" true
    (KKS.inbound_queue_mode_of ~turn_running:false ~wake_policy:KKS.Carry
       ~sender_kind:KKS.Human_sender = KKS.Coalesce);
  (* Arrived stimuli mid-turn ordering prioritizes Steer > FollowUp > Coalesce *)
  let make_sel ~arrival ~arrived_at ~urgency payload
    : Keeper_event_queue_state.pending_selection =
    { source =
        { Keeper_event_queue.post_id = Printf.sprintf "arr-%Ld" arrival
        ; urgency
        ; arrived_at
        ; payload
        }
    ; admitted_revision = 1L
    ; arrival
    ; checkpoint_retentions = 0
    ; first_admitted_at = None
    }
  in
  let round =
    Keeper_arrived_stimuli.next_round
      ~run_started_at:100.0
      ~shown:[]
      [ make_sel ~arrival:1L ~arrived_at:101.0 ~urgency:Keeper_event_queue.Low
          (Keeper_event_queue.Workspace_message { wmsg_request_id = "r1"; wmsg_from = "k1" })
      ; make_sel ~arrival:2L ~arrived_at:102.0 ~urgency:Keeper_event_queue.Normal
          (Keeper_event_queue.Tool_result_ready "rcpt-1")
      ; make_sel ~arrival:3L ~arrived_at:103.0 ~urgency:Keeper_event_queue.Immediate
          (Keeper_event_queue.Workspace_message { wmsg_request_id = "r2"; wmsg_from = "human" })
      ]
  in
  let order = List.map (fun (r : Keeper_arrived_stimuli.row) -> r.arrival, r.mode) round.listed in
  check bool "Steer precedes FollowUp precedes Coalesce" true
    (order = [ 3L, KKS.Steer; 2L, KKS.FollowUp; 1L, KKS.Coalesce ])
;;

let test_staggered_tick_and_adaptive_pull_in_backoff () =
  let tick_a =
    KKS.next_staggered_tick ~now:1000.0 ~keeper_name:"alpha"
      ~tick_interval_sec:KKS.default_stagger_tick_sec
  in
  let tick_b =
    KKS.next_staggered_tick ~now:1000.0 ~keeper_name:"beta"
      ~tick_interval_sec:KKS.default_stagger_tick_sec
  in
  check bool "alpha next tick strictly after now" true (tick_a > 1000.0);
  check bool "alpha next tick within interval" true
    (tick_a <= 1000.0 +. KKS.default_stagger_tick_sec);
  check bool "beta next tick strictly after now" true (tick_b > 1000.0);
  check bool "distinct keepers stagger phases" true (not (Float.equal tick_a tick_b));
  (* Adaptive idle ladder: 30m -> 1h -> 2h (cap) while no reaction runs *)
  let s0 = KKS.adaptive_idle_init ~now:0.0 ~warmup_sec:0.0 in
  check bool "starts at Idle_30m" true (s0.stage = KKS.Idle_30m);
  let s1 = KKS.adaptive_idle_after_self_wake ~now:100.0 s0 in
  check bool "1st quiet self-wake advances to Idle_1h" true (s1.stage = KKS.Idle_1h);
  check (float 0.01) "1st quiet self-wake schedules +3600s" 3700.0 s1.next_spontaneous_at;
  let s2 = KKS.adaptive_idle_after_self_wake ~now:3700.0 s1 in
  check bool "2nd quiet self-wake advances to Idle_2h" true (s2.stage = KKS.Idle_2h);
  check (float 0.01) "2nd quiet self-wake schedules +7200s" 10900.0 s2.next_spontaneous_at;
  let s3 = KKS.adaptive_idle_after_self_wake ~now:10900.0 s2 in
  check bool "3rd quiet self-wake caps at Idle_2h" true (s3.stage = KKS.Idle_2h);
  check (float 0.01) "3rd quiet self-wake caps at +7200s" 18100.0 s3.next_spontaneous_at;
  (* Reactive pull-in resets to Idle_30m and pulls in without pushing out *)
  let pulled = KKS.adaptive_idle_pull_in_on_reactive ~now:11000.0 s3 in
  check bool "reactive pull-in resets stage to Idle_30m" true (pulled.stage = KKS.Idle_30m);
  check (float 0.01) "reactive pull-in shortens 2h deadline to now+30m"
    12800.0 pulled.next_spontaneous_at;
  let kept = KKS.adaptive_idle_pull_in_on_reactive ~now:12500.0 pulled in
  check (float 0.01) "reactive pull-in never pushes out earlier deadline"
    12800.0 kept.next_spontaneous_at;
  let crossed : KKS.adaptive_idle_state =
    { stage = KKS.Idle_1h
    ; next_spontaneous_at = 1000.0
    ; since_self_wake = KKS.Quiet_since_self_wake
    }
  in
  let after_crossing = KKS.adaptive_idle_pull_in_on_reactive ~now:1500.0 crossed in
  check (float 0.01) "a deadline that came due during the reaction stays due"
    1000.0 after_crossing.next_spontaneous_at;
  check bool "the crossed boundary is served on the next cycle" true
    (KKS.adaptive_idle_is_due ~now:1500.0 after_crossing);
  (* Continuous scaling with custom base_interval_sec (no 60s discontinuity) *)
  check (float 0.01) "base=60s Idle_30m" 60.0
    (KKS.adaptive_idle_interval ~base_interval_sec:60.0 KKS.Idle_30m);
  check (float 0.01) "base=60s Idle_1h" 120.0
    (KKS.adaptive_idle_interval ~base_interval_sec:60.0 KKS.Idle_1h);
  check (float 0.01) "base=60s Idle_2h" 240.0
    (KKS.adaptive_idle_interval ~base_interval_sec:60.0 KKS.Idle_2h)
;;

(* The loop transition reads the decision's channel and the wake label, never
   whether the batch was acked: a self-wake with an empty batch (acked=false)
   is exactly the turn that must back off. *)
let test_adaptive_idle_backs_off_quiet_self_wakes_and_resets_on_reactions () =
  let module L = Keeper_heartbeat_loop in
  let module WO = Keeper_world_observation in
  let step ~periodic_due ~wake ~decided_channel ?(due_schedule = L.No_due_schedule_served)
      ~now state =
    L.For_testing.adaptive_idle_after_cycle ~periodic_due ~wake ~decided_channel
      ~due_schedule ~base_interval_sec:1800.0 ~now state
  in
  let self_wake ~now state =
    step ~periodic_due:true ~wake:WO.Periodic_tick
      ~decided_channel:(Some WO.Scheduled_autonomous) ~now state
  in
  let s0 = KKS.adaptive_idle_init ~now:0.0 ~warmup_sec:1800.0 in
  let s1 = self_wake ~now:1800.0 s0 in
  check bool "quiet self-wake: 30m -> 1h" true (s1.stage = KKS.Idle_1h);
  check (float 0.01) "next self-wake one hour later" 5400.0 s1.next_spontaneous_at;
  let s2 = self_wake ~now:5400.0 s1 in
  check bool "quiet self-wake: 1h -> 2h" true (s2.stage = KKS.Idle_2h);
  let s3 = self_wake ~now:12600.0 s2 in
  check bool "quiet self-wake stays at the 2h cap" true (s3.stage = KKS.Idle_2h);
  check (float 0.01) "capped self-wake two hours later" 19800.0 s3.next_spontaneous_at;
  let reacted =
    step ~periodic_due:false ~wake:WO.Attention_wake
      ~decided_channel:(Some WO.Reactive) ~now:13000.0 s3
  in
  check bool "a reaction returns the stage to 30m" true (reacted.stage = KKS.Idle_30m);
  check (float 0.01) "a reaction pulls the next self-wake to now+30m" 14800.0
    reacted.next_spontaneous_at;
  let after_reacted = self_wake ~now:14800.0 reacted in
  check bool "the self-wake after a reaction stays at 30m" true
    (after_reacted.stage = KKS.Idle_30m);
  check (float 0.01) "and comes again 30m later" 16600.0
    after_reacted.next_spontaneous_at;
  let quiet_again = self_wake ~now:16600.0 after_reacted in
  check bool "the next quiet self-wake backs off again" true
    (quiet_again.stage = KKS.Idle_1h);
  let at_boundary =
    step ~periodic_due:true ~wake:WO.Periodic_tick ~decided_channel:(Some WO.Reactive)
      ~now:20000.0 quiet_again
  in
  check bool "a reaction at the boundary serves it at 30m" true
    (at_boundary.stage = KKS.Idle_30m);
  check (float 0.01) "the served boundary moves to now+30m" 21800.0
    at_boundary.next_spontaneous_at;
  check bool "after a served boundary the next quiet self-wake backs off" true
    ((self_wake ~now:21800.0 at_boundary).stage = KKS.Idle_1h);
  let deferred =
    step ~periodic_due:true ~wake:WO.Deferred_runtime_lane
      ~decided_channel:(Some WO.Scheduled_autonomous) ~now:20000.0 quiet_again
  in
  check bool "a deferred suffix at the boundary holds the stage" true
    (deferred.stage = KKS.Idle_1h);
  check (float 0.01) "and consumes the boundary at the held interval" 23600.0
    deferred.next_spontaneous_at;
  let undecided =
    step ~periodic_due:true ~wake:WO.Periodic_tick ~decided_channel:None ~now:20000.0
      quiet_again
  in
  check bool "an undecided cycle at the boundary holds the stage" true
    (undecided.stage = KKS.Idle_1h);
  let unrelated =
    step ~periodic_due:false ~wake:WO.Attention_wake
      ~decided_channel:(Some WO.Scheduled_autonomous) ~now:17000.0 quiet_again
  in
  check bool "a non-reaction off the boundary leaves the state alone" true
    (unrelated = quiet_again);
  let idle_2h_state : KKS.adaptive_idle_state =
    { stage = KKS.Idle_2h
    ; next_spontaneous_at = 7200.0
    ; since_self_wake = KKS.Quiet_since_self_wake
    }
  in
  let after_schedule =
    step ~periodic_due:false ~wake:WO.Attention_wake
      ~decided_channel:(Some WO.Scheduled_autonomous)
      ~due_schedule:L.Due_schedule_served ~now:5000.0 idle_2h_state
  in
  check (float 0.01) "a served due schedule moves the deadline to now+base" 6800.0
    after_schedule.next_spontaneous_at;
  check bool "a served due schedule returns the stage to 30m" true
    (after_schedule.stage = KKS.Idle_30m)
;;

(* A turn that took its batch and did not finish sleeps to the boundary, not
   the next tick, so a failing input is retried once per start interval. *)
let test_a_cycle_that_left_its_batch_sleeps_to_the_boundary () =
  let module L = Keeper_heartbeat_loop in
  List.iter
    (fun (label, status, left) ->
       check bool label left (L.For_testing.cycle_left_its_batch status))
    [ "failed turn", L.Turn_cycle_turn_failed, true
    ; "crashed cycle", L.Turn_cycle_crashed, true
    ; "interrupted cycle", L.Turn_cycle_interrupted, true
    ; "finished turn", L.Turn_cycle_turn_succeeded, false
    ; "no turn", L.Turn_cycle_without_turn, false
    ; "lifecycle blocked", L.Turn_cycle_lifecycle_blocked, false
    ; "owner rejected", L.Turn_cycle_owner_rejected, false
    ; "owner busy", L.Turn_cycle_busy Keeper_owner.Admission_paused, false
    ; "rested", L.Turn_cycle_rested, false
    ]
;;

let test_at_tick_pending_interrupts_long_sleep_at_staggered_tick () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let base_path = "/tmp/test-at-tick-sleep" in
    let keeper_name = "at-tick-sleeper" in
    let stop = Atomic.make false in
    let wakeup = Atomic.make false in
    let cadence_sleeping = Atomic.make false in
    let now_ref = ref 1000.0 in
    let outcome = ref None in
    Fun.protect
      ~finally:(fun () -> KKS.clear_at_tick_pending ~base_path ~keeper_name)
      (fun () ->
         Eio.Fiber.both
           (fun () ->
              outcome :=
                Some
                  (KKS.interruptible_sleep
                     ~cadence_sleeping
                     ~interrupt_when:(fun () ->
                       KKS.at_tick_due ~base_path ~keeper_name ~now:!now_ref)
                     ~clock
                     ~stop
                     ~wakeup
                     (fun () -> 7200.0)))
           (fun () ->
              while not (Atomic.get cadence_sleeping) do
                Eio.Time.sleep clock 0.001
              done;
              KKS.notify_at_tick_pending
                ~base_path
                ~keeper_name
                ~tick_interval_sec:KKS.default_stagger_tick_sec
                ~now:!now_ref
                ();
              let deadline =
                match KKS.at_tick_deadline_opt ~base_path ~keeper_name with
                | Some d -> d
                | None -> fail "expected pending at-tick deadline"
              in
              check bool "deadline is after arrival" true (deadline > 1000.0);
              check bool "deadline within stagger window" true
                (deadline <= 1000.0 +. KKS.default_stagger_tick_sec);
              now_ref := deadline -. 1.0;
              check bool "does not wake early before staggered tick" false
                (KKS.at_tick_due ~base_path ~keeper_name ~now:!now_ref);
              now_ref := deadline);
         check bool "At_tick arrival interrupts 2h sleep at staggered tick" true
           (match !outcome with
            | Some KKS.Woken -> true
            | Some (KKS.Stopped | KKS.Timeout) | None -> false)))
;;

let test_board_signal_enqueues_policy_urgency_before_wake () =
  Eio_main.run @@ fun _env ->
  with_board_workspace @@ fun config ->
  let target = make_board_resume_meta "alpha" in
  let peer_keeper = make_board_resume_meta "beta" in
  let persisted_keeper = make_board_resume_meta "persisted-peer" in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.set_board_signal_hook (fun _ -> ());
      KKS.clear_at_tick_pending ~base_path:config.base_path ~keeper_name:target.name;
      Keeper_registry.For_testing.clear ())
    (fun () ->
       persist_and_register_board_lane config target;
       persist_and_register_board_lane config peer_keeper;
       (* Persist without registering to ensure unregistered persisted Keepers
          are still recognized as Keeper_sender, not Human_sender. *)
       write_board_lane_config config persisted_keeper;
       (match Keeper_meta_store.replace_snapshot config persisted_keeper with
        | Ok () -> ()
        | Error detail -> fail ("write_meta failed: " ^ detail));
       let urgency_for_post post_id =
         match
           Keeper_event_queue_persistence.pending_selections_result
             ~base_path:config.base_path
             ~keeper_name:target.name
         with
         | Error detail -> fail ("pending_selections failed: " ^ detail)
         | Ok selections ->
           (match
              List.find_opt
                (fun (sel : Keeper_event_queue_state.pending_selection) ->
                   String.equal sel.source.post_id post_id)
                selections
            with
            | Some sel -> sel.source.urgency
            | None -> failf "expected queued stimulus for %s" post_id)
       in
       let reset_wake_state () =
         KKS.clear_at_tick_pending ~base_path:config.base_path ~keeper_name:target.name;
         match Keeper_registry.get ~base_path:config.base_path target.name with
         | Some entry -> Atomic.set entry.fiber_wakeup false
         | None -> fail "alpha registry entry missing"
       in
       (* 1. Keeper-authored @alpha mention -> At_tick -> Normal urgency, no immediate wake, pending at-tick deadline set *)
       reset_wake_state ();
       let keeper_mention =
         { Board_dispatch.kind = Board_dispatch.Board_post_created
         ; post_id = "post-keeper-mention"
         ; author = peer_keeper.name
         ; title = "peer ping"
         ; content = "@alpha sync at tick"
         ; hearth = None
         ; updated_at = Some 200.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config keeper_mention;
       check bool "keeper mention enqueues Normal urgency (not Immediate)" true
         (urgency_for_post keeper_mention.signal.post_id = Keeper_event_queue.Normal);
       check bool "keeper mention does not set immediate wakeup" false
         (Atomic.get (Option.get (Keeper_registry.get ~base_path:config.base_path target.name)).fiber_wakeup);
       check bool "keeper mention registers staggered at-tick deadline" true
         (Option.is_some
            (KKS.at_tick_deadline_opt ~base_path:config.base_path ~keeper_name:target.name));
       (* 2. Unregistered persisted Keeper mention -> still Keeper_sender -> Normal urgency *)
       reset_wake_state ();
       let persisted_mention =
         { Board_dispatch.kind = Board_dispatch.Board_post_created
         ; post_id = "post-persisted-keeper-mention"
         ; author = persisted_keeper.name
         ; title = "persisted peer ping"
         ; content = "@alpha sync from unregistered persisted keeper"
         ; hearth = None
         ; updated_at = Some 201.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config persisted_mention;
       check bool "persisted keeper mention enqueues Normal urgency" true
         (urgency_for_post persisted_mention.signal.post_id = Keeper_event_queue.Normal);
       check bool "persisted keeper mention does not set immediate wakeup" false
         (Atomic.get (Option.get (Keeper_registry.get ~base_path:config.base_path target.name)).fiber_wakeup);
       (* 3. Human-authored @alpha mention -> Now -> Immediate urgency + immediate wakeup *)
       reset_wake_state ();
       let human_mention =
         { Board_dispatch.kind = Board_dispatch.Board_post_created
         ; post_id = "post-human-mention"
         ; author = "external-human"
         ; title = "operator ping"
         ; content = "@alpha urgent check"
         ; hearth = None
         ; updated_at = Some 202.0
         }
         |> persist_board_signal
       in
       KKS.wakeup_relevant_keeper_for_board_signal ~config human_mention;
       check bool "human mention enqueues Immediate urgency" true
         (urgency_for_post human_mention.signal.post_id = Keeper_event_queue.Immediate);
       check bool "human mention triggers immediate wakeup" true
         (Atomic.get (Option.get (Keeper_registry.get ~base_path:config.base_path target.name)).fiber_wakeup);
       (* 4. Vote on alpha's own post -> Carry -> Low urgency, no immediate wake, no at-tick deadline *)
       reset_wake_state ();
       let own_post_id =
         create_post_exn
           ~author:target.name
           ~title:"alpha status"
           ~content:"status update"
       in
       Board_dispatch.set_board_signal_hook (fun signal ->
         KKS.wakeup_relevant_keeper_for_board_signal ~config signal);
       (match
          Board_dispatch.vote
            ~reader:Masc_board_handlers.Board_access.Operator
            ~voter:"external-voter"
            ~post_id:own_post_id
            ~direction:Board.Up
        with
        | Ok _ -> ()
        | Error err -> fail (Board.show_board_error err));
       check bool "vote enqueues Low urgency (Carry, not Normal)" true
         (urgency_for_post own_post_id = Keeper_event_queue.Low);
       check bool "vote does not trigger immediate wakeup" false
         (Atomic.get (Option.get (Keeper_registry.get ~base_path:config.base_path target.name)).fiber_wakeup);
       check bool "vote does not register an at-tick deadline" true
         (Option.is_none
            (KKS.at_tick_deadline_opt ~base_path:config.base_path ~keeper_name:target.name)))
;;

let () =
  run
    "keeper keepalive helpers"
    [ ( "wake_policy_circulation"
      , [ test_case "typed wake policy and Steer/FollowUp/Coalesce modes" `Quick
            test_typed_wake_policy_and_inbound_queue_modes
        ; test_case "staggered tick grid and adaptive pull-in idle backoff" `Quick
            test_staggered_tick_and_adaptive_pull_in_backoff
        ; test_case "quiet self-wakes back off and reactions reset" `Quick
            test_adaptive_idle_backs_off_quiet_self_wakes_and_resets_on_reactions
        ; test_case "a cycle that left its batch sleeps to the boundary" `Quick
            test_a_cycle_that_left_its_batch_sleeps_to_the_boundary
        ; test_case "At_tick pending interrupts long sleep at staggered tick" `Quick
            test_at_tick_pending_interrupts_long_sleep_at_staggered_tick
        ; test_case "board signal enqueues policy urgency before wake" `Quick
            test_board_signal_enqueues_policy_urgency_before_wake
        ] )
    ; ( "current_task_reconciliation"
      , [ test_case
            "heartbeat reconciles empty current_task_id from active backlog"
            `Quick
            test_current_task_id_for_agent_reconciles_from_empty_registry_task
        ] )
    ; ( "owner_turn_rejection"
      , [ test_case "owner inventory stopping completes the cycle" `Quick
            test_owner_inventory_stopping_completes_the_cycle
        ; test_case "owner inventory stopping refreshes the work heartbeat" `Quick
            test_owner_inventory_stopping_refreshes_work_heartbeat
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
      , [ test_case "comments address post and exact parent only" `Quick
            test_comments_address_post_and_direct_parent_only
        ; test_case "goal keyword overlap is not a wake reason" `Quick
            test_board_goal_keyword_overlap_is_not_wake_reason
        ; test_case "mentions use exact typed Keeper ids" `Quick
            test_board_mentions_use_exact_typed_keeper_ids
        ; test_case "closed audience routes only its authority" `Quick
            test_closed_board_audience_routes_only_its_authority
        ; test_case
            "system post text does not wake the named lane"
            `Quick
            test_system_post_text_does_not_wake_the_named_lane
        ; test_case "exact mentions deliver and wake every lane" `Quick
            test_exact_mentions_deliver_and_wake_each_lane_independently
        ; test_case "mixed address signal is dropped at routing" `Quick
            test_mixed_address_signal_is_dropped_at_routing
        ; test_case "paused exact mention is durable without wake" `Quick
            test_paused_exact_mention_is_durable_without_wake
        ; test_case "Restarting exact mention is durable with deferred wake" `Quick
            test_restarting_exact_mention_is_durable_with_deferred_wake
        ; test_case "unregistered persisted exact mention is durable across registration" `Quick
            test_unregistered_persisted_exact_mention_is_durable_across_registration
        ; test_case "lane metadata failure does not block next durable delivery" `Quick
            test_lane_meta_failure_does_not_block_next_durable_delivery
        ; test_case "committed vote survives routing source refusal" `Quick
            (test_committed_board_action_retains_unavailable_routing `Vote)
        ; test_case "committed reaction survives routing source refusal" `Quick
            (test_committed_board_action_retains_unavailable_routing `Reaction)
        ; test_case "thread signal for a swept post delivers nothing" `Quick
            test_thread_signal_for_a_swept_post_delivers_nothing
        ; test_case "comment routes bystander lane to attention judgment" `Quick
            test_comment_routes_bystander_lane_to_attention_judgment
        ; test_case "comment discovery follows parent visibility" `Quick
            test_comment_discovery_respects_parent_visibility
        ; test_case "later alias does not readdress stored thread comment" `Quick
            test_unresolved_comment_name_cannot_become_a_recipient
        ; test_case "a Direct comment cannot address a name outside the parent's readers"
            `Quick test_direct_comment_cannot_address_a_non_reader
        ; test_case "comment on own post wakes the author" `Quick
            test_comment_on_own_post_wakes_the_author
        ; test_case "vote on own post wakes the author once" `Quick
            test_vote_on_own_post_wakes_the_author_once
        ; test_case "vote on own comment wakes the commenter not the poster" `Quick
            test_vote_on_own_comment_wakes_the_commenter_not_the_poster
        ] )
    ; ( "interruptible_cadence"
      , [ test_case "directed wake cuts configured sleep" `Quick
            test_directed_wake_cuts_configured_sleep
        ; test_case "explicit stop cuts configured sleep" `Quick
            test_explicit_stop_cuts_configured_sleep
        ; test_case "cadence wake consumes only active sleep" `Quick
            test_cadence_wake_consumes_only_active_sleep
        ; test_case "cadence handshake precedes duration resolution" `Quick
            test_cadence_handshake_precedes_duration_resolution
        ; test_case "a path's rest follows the answer, not the cadence" `Quick
            test_path_rest_follows_the_answer_not_the_cadence
        ; test_case "backoff sleep serves a wakeup only after the duration" `Quick
            test_backoff_sleep_serves_a_wakeup_only_after_the_duration
        ; test_case "backoff sleep without a wakeup times out" `Quick
            test_backoff_sleep_without_a_wakeup_times_out
        ; test_case "stop still cuts a backoff sleep" `Quick
            test_stop_still_cuts_a_backoff_sleep
        ; test_case "dependency change interrupts provider rest" `Quick
            test_dependency_change_interrupts_provider_rest
        ] )
    ]
;;
