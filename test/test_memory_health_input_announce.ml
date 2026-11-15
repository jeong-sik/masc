(* RFC-0487 L3: a write to a file a Keeper's memory health row reads tells the
   workspace's readers that this Keeper's row moved, after emptying the fleet
   answer the route caches. *)

open Alcotest
open Masc

(* The Keeper a memory health announcement names, or [None] for any other
   event on the runtime. *)
let memory_health_keeper (payload : Yojson.Safe.t) =
  match payload with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields, Workspace_dataset_event.of_fields fields with
     | Some (`String kind), Ok (Workspace_dataset_event.Memory_health { keeper })
       when String.equal kind Workspace_dataset_event.event_type -> Some keeper
     | ( Some _ | None )
     , Ok
         Workspace_dataset_event.(
           ( Repositories | Verification_requests | Harness_verdicts | Goals
           | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
           | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
           | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
           | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
           | Keeper_oauth_attempts _ | Memory_health _ | World_memory | Play_seats
           | Dashboard_observation _ ))
     | (Some _ | None), Error _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

(* Neither keepers directory exists when [f] starts, so the server resolves
   each through its existing ancestor. *)
let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let scratch = Unix.realpath (Filename.temp_dir "memory-health-announce-" "") in
  let elsewhere = Unix.realpath (Filename.temp_dir "memory-health-elsewhere-" "") in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.remove_tree scratch;
      Fs_compat.remove_tree elsewhere)
    (fun () ->
      let config = Workspace.default_config scratch in
      ignore (Workspace.init config ~agent_name:None);
      let base_path = config.Workspace.base_path in
      let config_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let runtime_keepers_dir = Workspace.keepers_runtime_dir config in
      (* Only directories inside this test's own scratch directory are
         removed; anything else fails the test first. *)
      List.iter
        (fun dir ->
           if not (String.starts_with ~prefix:(scratch ^ "/") dir)
           then fail ("a keepers dir outside the test's scratch directory: " ^ dir);
           if Sys.file_exists dir then Fs_compat.remove_tree dir)
        [ config_keepers_dir; runtime_keepers_dir ];
      let fleet_key = Server_dashboard_http_keeper_memory_health.fleet_cache_key ~base_path in
      let heard = ref [] in
      let notices = Eio.Stream.create 1 in
      let id = "memory-health-input-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          Option.iter
            (fun keeper ->
               heard := (keeper, Option.is_some (Dashboard_cache.peek fleet_key)) :: !heard;
               Eio.Stream.add notices ())
            (memory_health_keeper event.ext_payload))
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        f ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~await_health:(fun () -> Eio.Stream.take notices)
          ~config ~fleet_key ~elsewhere ~config_keepers_dir ~runtime_keepers_dir
          ~heard:(fun () -> List.rev !heard)))
;;

let test_writes_under_the_workspace_announce_their_keeper () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock ~await_health ~config ~fleet_key ~elsewhere
       ~config_keepers_dir ~runtime_keepers_dir ~heard ->
  let keepers () = List.map fst (heard ()) in
  let seed_fleet () =
    Dashboard_cache.seed_stale_if_missing fleet_key ~stale_for:60.0 (`Assoc []);
    check bool "the fleet answer is cached before the write" true
      (Option.is_some (Dashboard_cache.peek fleet_key))
  in
  Eio.Switch.run (fun sw ->
    (* Neither directory exists yet: the server names each under its
       resolved ancestor, where the first write creates it. *)
    Server_memory_health_broadcast.install ~sw ~mono_clock ~config;
    Fs_compat.mkdir_p config_keepers_dir;
    Fs_compat.mkdir_p runtime_keepers_dir;
    seed_fleet ();
    Keeper_memory_health_input.written ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo";
    await_health ();
    check (list (pair string bool))
      "a write under the runtime keepers dir names its Keeper, the fleet answer already gone"
      [ "largo", false ] (heard ());
    Keeper_memory_health_input.written ~keepers_dir:config_keepers_dir ~keeper_id:"piano";
    await_health ();
    check (list string) "a write under the config keepers dir names its Keeper"
      [ "largo"; "piano" ] (keepers ());
    (* A writer that reached the directory through a symlink names the same
       directory once the signal resolves it. *)
    let alias = Filename.concat elsewhere "runtime-keepers-alias" in
    Unix.symlink runtime_keepers_dir alias;
    Keeper_memory_health_input.written ~keepers_dir:alias ~keeper_id:"largo";
    await_health ();
    check (list string) "a write through a symlinked keepers dir names its Keeper"
      [ "largo"; "piano"; "largo" ] (keepers ());
    seed_fleet ();
    Keeper_memory_commit_notifications.notify_committed
      { Keeper_memory_commit_notifications.keepers_dir = Unix.realpath config_keepers_dir
      ; keeper_id = "forte"
      ; store = Keeper_memory_commit_notifications.Source_bound
      ; revision = 3
      };
    await_health ();
    check (list (pair string bool))
      "a snapshot commit names its Keeper, the fleet answer already gone"
      [ "largo", false; "piano", false; "largo", false; "forte", false ] (heard ());
    Keeper_memory_health_input.written ~keepers_dir:elsewhere ~keeper_id:"largo";
    Keeper_memory_commit_notifications.notify_committed
      { Keeper_memory_commit_notifications.keepers_dir = elsewhere
      ; keeper_id = "largo"
      ; store = Keeper_memory_commit_notifications.Ordinary
      ; revision = 4
      };
    check (list string) "a write under another directory is not this workspace's"
      [ "largo"; "piano"; "largo"; "forte" ] (keepers ()));
  Keeper_memory_health_input.written ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo";
  check (list string) "once the server's switch is released nothing is announced"
    [ "largo"; "piano"; "largo"; "forte" ] (keepers ())
;;

let require = function
  | Ok value -> value
  | Error detail -> fail detail
;;

(* Each store write that changed a file the row reads says so once, naming
   the Keeper and the resolved keepers directory, and so does each change of
   an input the row reads from this process's memory. The continuity
   snapshot's save and the drain measurement's publication are internal to
   their modules and are not written here. *)
let test_each_store_write_tells_the_signal () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock:_ ~await_health:_ ~config ~fleet_key:_ ~elsewhere:_
       ~config_keepers_dir ~runtime_keepers_dir ~heard:_ ->
  Fs_compat.mkdir_p config_keepers_dir;
  Fs_compat.mkdir_p runtime_keepers_dir;
  let told = ref [] in
  let unsubscribe =
    Keeper_memory_health_input.subscribe
      (fun { Keeper_memory_health_input.keepers_dir; keeper_id } ->
         told := (keepers_dir, keeper_id) :: !told)
  in
  Fun.protect ~finally:unsubscribe (fun () ->
    let config_dir = Unix.realpath config_keepers_dir in
    let runtime_dir = Unix.realpath runtime_keepers_dir in
    let take () =
      let seen = List.rev !told in
      told := [];
      seen
    in
    let told_as = check (list (pair string string)) in
    (match
       Keeper_librarian_progress.write ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo"
         { Keeper_librarian_progress.position =
             { trace_id = "trace"; end_atom = 2; last_atom_digest = "d" }
         ; boundary_lines_seen = 1
         }
     with
     | Ok () -> ()
     | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
    told_as "a Librarian progress write" [ runtime_dir, "largo" ] (take ());
    Keeper_turn_boundaries.append ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo"
      { Keeper_turn_boundaries.recorded_at = 1000.
      ; event = Keeper_turn_boundaries.History_restarted { trace_id = "trace" }
      }
    |> Result.map_error Keeper_turn_boundaries.append_error_to_string
    |> require;
    told_as "a turn boundary append" [ runtime_dir, "largo" ] (take ());
    ignore
      (Keeper_librarian_unread_ledger.archive ~keepers_dir:config_keepers_dir
         ~keeper_id:"piano" []
       |> require);
    told_as "an archive that changes nothing says nothing" [] (take ());
    let messages =
      [ Agent_core.Types.make_message ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "prefix" ]
      ; Agent_core.Types.make_message ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "unread original" ]
      ]
    in
    let hole =
      Keeper_librarian_unread.for_atom ~trace_id:"trace" ~history_start_boundary_line:1
        ~atom:1 ~message_in_atom:0 ~messages
        ~reasons:[ Keeper_librarian_input_refusal.Input_capacity ]
      |> require
    in
    ignore
      (Keeper_librarian_unread_ledger.archive ~keepers_dir:config_keepers_dir
         ~keeper_id:"piano" [ hole ]
       |> require);
    told_as "an archive that adds a hole" [ config_dir, "piano" ] (take ());
    ignore
      (Keeper_librarian_unread_ledger.archive ~keepers_dir:config_keepers_dir
         ~keeper_id:"piano" [ hole ]
       |> require);
    told_as "archiving the same hole again says nothing" [] (take ());
    Keeper_memory_os_current.append_librarian_failure ~keepers_dir:config_keepers_dir
      ~keeper_id:"forte" ~now:1000. ~trace_id:"trace"
      ~kind:Keeper_memory_os_current.Prompt_render_failure ~detail:"fixture"
      ~snapshot_present:false;
    told_as "a memory journal line" [ config_dir, "forte" ] (take ());
    (* A publication that stopped before its snapshot rename leaves a prepared
       receipt. Recovering it writes no commit, so it says so itself. *)
    let module Current = Keeper_memory_os_current in
    let module Types = Keeper_memory_os_types in
    let source = { Current.kind = Current.Explicit_write; trace_id = "trace" } in
    let fact claim =
      Types.observed ~claim ~category:Types.Fact ~now:10.
        ~origin:{ kind = Types.Authored; trace_id = "trace" }
    in
    ignore
      (Current.replace ~keepers_dir:config_keepers_dir ~keeper_id:"mezzo"
         ~expected_revision:None ~now:20. ~source ~facts:[ fact "before" ] ()
       |> require);
    let write_snapshot path content =
      Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
        ~sync_file:(fun _ -> failwith "before rename")
        ~sync_parent:(fun _ -> failwith "after rename") path content
    in
    (match
       Current.For_testing.replace_with_publication_io ~write_snapshot
         ~sync_snapshot:(fun _ -> Error "unconfirmed") ~on_committed:(fun _ _ -> ())
         ~before_journal:(fun () -> ()) ~keepers_dir:config_keepers_dir ~keeper_id:"mezzo"
         ~now:30. ~source ~facts:[ fact "after" ]
     with
     | Error _ -> ()
     | Ok _ -> fail "the publication must stop before its rename");
    check bool "the prepared receipt waits for recovery" true
      (Sys.file_exists
         (Current.publication_receipt_path ~keepers_dir:config_keepers_dir ~keeper_id:"mezzo"));
    ignore (take ());
    Current.recover_publication ~keepers_dir:config_keepers_dir ~keeper_id:"mezzo" |> require;
    told_as "recovering a publication that never reached its target"
      [ config_dir, "mezzo" ] (take ());
    let unreadable =
      Agent_core.Types.Image
        { media_type = "image/png"
        ; source = Agent_core.Types.Stored (Agent_core.History.stored_of_raw "never put")
        }
    in
    ignore
      (Keeper_vision_ingest.evict_blocks ~base_path:config.Workspace.base_path
         ~media_store:(Agent_core.History.Memory_store.create ())
         ~mode:Keeper_vision_ingest.Store_only ~delegate:true ~keeper_name:"forte"
         [ unreadable ]);
    told_as "a vision eviction error" [ config_dir, "forte" ] (take ());
    Eio.Switch.run (fun sw ->
      let store = Keeper_types_support.keeper_turn_record_store config "largo" in
      Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
      Keeper_turn_record_writer.write ~request_observations:[] ~config ~keeper_name:"largo"
        ~agent_name:"largo" ~turn_kind:Turn_record.Direct ~trace_id:"trace" ~absolute_turn:1
        ~runtime_profile:"announce.fixture" ~selected_model:None ~finish_reason:None
        ~context_window:None ~price_input_per_million:None ~price_output_per_million:None
        ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
        ~model_input_window:None ~response_observed_model_input:None ~refused_model_input:None ~raw_trace_run_ref:None
        ~sampling:{ temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
        ~turn_output_tokens:None
        ~usage:
          { input_tokens = None
          ; output_tokens = None
          ; cache_creation_input_tokens = None
          ; cache_read_input_tokens = None
          ; scope = Runtime_usage_scope.Usage_scope_unavailable
          ; input_provenance = None
          }
        ~execution_ids:[] ~blocks:[] ~input_components:None ~tool_surface_ref:None ();
      told_as "a turn record" [ runtime_dir, "largo" ] (take ()));
    (* The inputs the row reads from this process's memory. *)
    Keeper_continuity_observation.record ~config ~keeper_name:"largo"
      { Keeper_continuity_observation.prepared_at = 1000.
      ; runtime_id = "fixture-runtime"
      ; input = Keeper_continuity_observation.Not_applied
      ; request_bytes = 1
      };
    told_as "a continuity observation" [ runtime_dir, "largo" ] (take ());
    Keeper_continuity_observation.forget ~config ~keeper_name:"largo";
    told_as "forgetting the observations" [ runtime_dir, "largo" ] (take ());
    Keeper_librarian_queue_refresh.forget_measurement ~config ~keeper_name:"largo";
    told_as "forgetting the drain measurement" [ runtime_dir, "largo" ] (take ()))
;;

(* The writers have already committed and some still have bookkeeping to do,
   so a subscriber that raises, a cancellation included, stops neither the
   other subscribers nor the writer. *)
let test_a_failing_subscriber_stops_nothing () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock:_ ~await_health:_ ~config:_ ~fleet_key:_ ~elsewhere:_
       ~config_keepers_dir:_ ~runtime_keepers_dir ~heard:_ ->
  Fs_compat.mkdir_p runtime_keepers_dir;
  let told = ref 0 in
  let unsubscribers =
    [ Keeper_memory_health_input.subscribe (fun _ -> failwith "subscriber fault")
    ; Keeper_memory_health_input.subscribe (fun _ ->
        raise (Eio.Cancel.Cancelled (Failure "subscriber cancellation")))
    ; Keeper_memory_health_input.subscribe (fun _ -> incr told)
    ]
  in
  Fun.protect ~finally:(fun () -> List.iter (fun unsubscribe -> unsubscribe ()) unsubscribers)
    (fun () ->
      Keeper_memory_health_input.written ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo";
      check int "the other subscriber still heard it, and the writer went on" 1 !told)
;;

(* The retention pass tells the row's readers about each Keeper whose turn
   records lost a day file (RFC-0487 §2.7), and about no other store's. *)
let test_a_turn_record_prune_tells_its_keeper () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock:_ ~await_health:_ ~config ~fleet_key:_ ~elsewhere:_
       ~config_keepers_dir:_ ~runtime_keepers_dir ~heard:_ ->
  let module Store = Dated_jsonl.Store in
  let masc_root = Common.masc_dir_from_base_path ~base_path:config.Workspace.base_path in
  let root = Store.root_of_masc_dir masc_root in
  let turn_records = Store.keeper root ~keeper:"largo" Store.Keeper.Turn_records in
  check bool "a per-keeper location names its Keeper and store" true
    (Store.keeper_store turn_records = Some ("largo", Store.Keeper.Turn_records));
  check bool "a workspace store names no Keeper" true
    (Option.is_none (Store.keeper_store (Store.at root Store.Root.Costs)));
  let old_day_file location =
    let dated = Store.dated_path location ~ts:(Unix.gettimeofday () -. (400. *. 86_400.)) in
    Fs_compat.mkdir_p (Filename.dirname dated.path);
    Out_channel.with_open_text dated.path (fun oc -> output_string oc "{}\n");
    dated.path
  in
  let files =
    [ old_day_file turn_records
    ; old_day_file (Store.keeper root ~keeper:"largo" Store.Keeper.Execution_receipts)
    ; old_day_file (Store.keeper root ~keeper:"piano" Store.Keeper.Metrics)
    ]
  in
  let told = ref [] in
  let unsubscribe =
    Keeper_memory_health_input.subscribe
      (fun { Keeper_memory_health_input.keepers_dir; keeper_id } ->
         told := (keepers_dir, keeper_id) :: !told)
  in
  Fun.protect ~finally:unsubscribe (fun () ->
    ignore (Server_runtime_startup_maintenance.prune_shared_jsonl_stores ~days:30 ~masc_root
            : int));
  check (list bool) "every old day file is gone" [ false; false; false ]
    (List.map Sys.file_exists files);
  check (list (pair string string)) "only the turn records' Keeper is told, once"
    [ Unix.realpath runtime_keepers_dir, "largo" ] (List.rev !told)
;;

let test_a_notification_reloads_the_warm_row () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock ~await_health ~config ~fleet_key:_ ~elsewhere:_
       ~config_keepers_dir ~runtime_keepers_dir ~heard:_ ->
  let module Current = Keeper_memory_os_current in
  let module Types = Keeper_memory_os_types in
  let module Health = Server_dashboard_http_keeper_memory_health in
  let keeper = "largo" in
  Fs_compat.mkdir_p config_keepers_dir;
  Fs_compat.mkdir_p runtime_keepers_dir;
  let source = { Current.kind = Current.Explicit_write; trace_id = "trace" } in
  let ordinary_writes = ref 0 in
  let write_ordinary () =
    incr ordinary_writes;
    let expected_revision =
      match Current.read_for_keepers_dir ~keepers_dir:config_keepers_dir ~keeper_id:keeper with
      | Ok None -> None
      | Ok (Some snapshot) -> Some snapshot.revision
      | Error detail -> fail detail
    in
    Current.replace ~keepers_dir:config_keepers_dir ~keeper_id:keeper ~expected_revision
      ~now:(20. +. float_of_int !ordinary_writes) ~source
      ~facts:[ Types.observed ~claim:("ordinary fact " ^ string_of_int !ordinary_writes)
                 ~category:Types.Fact ~now:20.
                 ~origin:{ kind = Types.Authored; trace_id = "trace" } ]
      ()
    |> require |> ignore
  in
  let attempts = ref 0 in
  Health.For_testing.with_runtime
    ~keeper_health:(fun ~config ~keepers_dir keeper_id ->
      incr attempts;
      Health.For_testing.keeper_health ~config ~keepers_dir keeper_id)
    (fun () ->
      write_ordinary ();
      Eio.Switch.run (fun sw ->
        Server_memory_health_broadcast.install ~sw ~mono_clock ~config;
        let read_row () =
          ignore (Health.keeper_memory_health_row_http_json
                    ~base_path:config.Workspace.base_path ~keeper)
        in
        read_row ();
        check int "the row starts warm" 1 !attempts;
        let observed_loads = Eio.Stream.create 1 in
        let id = "memory-health-row-read-during-notification" in
        Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path:config.base_path)
          ~id ~callback:(fun (event : Sse.external_event) ->
            Option.iter
              (fun changed ->
                 if String.equal changed keeper then begin
                   read_row ();
                   Eio.Stream.add observed_loads !attempts
                 end)
              (memory_health_keeper event.ext_payload))
          ();
        Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
          let check_reload label write =
            let before = !attempts in
            write ();
            let observed = Eio.Stream.take observed_loads in
            await_health ();
            check int (label ^ " reloads before the callback") (before + 1) observed;
            check int (label ^ " reloads once") (before + 1) !attempts
          in
          check_reload "Librarian progress" (fun () ->
            match
              Keeper_librarian_progress.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper
                { Keeper_librarian_progress.position =
                    { trace_id = "trace"; end_atom = 2; last_atom_digest = "d" }
                ; boundary_lines_seen = 1
                }
            with
            | Ok () -> ()
            | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
          check_reload "turn record" (fun () ->
            let store = Keeper_types_support.keeper_turn_record_store config keeper in
            Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
            Keeper_turn_record_writer.write ~request_observations:[] ~config ~keeper_name:keeper
              ~agent_name:keeper ~turn_kind:Turn_record.Direct ~trace_id:"trace" ~absolute_turn:1
              ~runtime_profile:"announce.fixture" ~selected_model:None ~finish_reason:None
              ~context_window:None ~price_input_per_million:None ~price_output_per_million:None
              ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
              ~model_input_window:None ~response_observed_model_input:None ~refused_model_input:None ~raw_trace_run_ref:None
              ~sampling:{ temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
              ~turn_output_tokens:None
              ~usage:
                { input_tokens = None
                ; output_tokens = None
                ; cache_creation_input_tokens = None
                ; cache_read_input_tokens = None
                ; scope = Runtime_usage_scope.Usage_scope_unavailable
                ; input_provenance = None
                }
              ~execution_ids:[] ~blocks:[] ~input_components:None ~tool_surface_ref:None ());
          check_reload "vision error" (fun () ->
            let unreadable =
              Agent_core.Types.Image
                { media_type = "image/png"
                ; source = Agent_core.Types.Stored (Agent_core.History.stored_of_raw "never put")
                }
            in
            ignore
              (Keeper_vision_ingest.evict_blocks ~base_path:config.Workspace.base_path
                 ~media_store:(Agent_core.History.Memory_store.create ())
                 ~mode:Keeper_vision_ingest.Store_only ~delegate:true ~keeper_name:keeper
                 [ unreadable ]));
          check_reload "unread ledger" (fun () ->
            let messages =
              [ Agent_core.Types.make_message ~role:Agent_core.Types.User
                  [ Agent_core.Types.Text "unread original" ]
              ]
            in
            let hole =
              Keeper_librarian_unread.for_atom ~trace_id:"trace" ~history_start_boundary_line:1
                ~atom:1 ~message_in_atom:0 ~messages
                ~reasons:[ Keeper_librarian_input_refusal.Input_capacity ]
              |> require
            in
            ignore
              (Keeper_librarian_unread_ledger.archive ~keepers_dir:config_keepers_dir
                 ~keeper_id:keeper [ hole ]
               |> require));
          check_reload "ordinary snapshot" write_ordinary;
          check_reload "source-bound commit" (fun () ->
            Keeper_memory_commit_notifications.notify_committed
              { Keeper_memory_commit_notifications.keepers_dir = Unix.realpath config_keepers_dir
              ; keeper_id = keeper
              ; store = Keeper_memory_commit_notifications.Source_bound
              ; revision = 3
              }))))
;;

(* World inventory readers settle after a successful read. Each durable input
   must therefore empty the cached inventory before announcing the change. *)
let test_world_writes_invalidate_before_announcing () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock ~await_health:_ ~config ~fleet_key:_ ~elsewhere ~config_keepers_dir:_
       ~runtime_keepers_dir:_ ~heard:_ ->
  let base_path = config.Workspace.base_path in
  let key = Server_dashboard_http_core_cache.workspace_memory_inventory_cache_key ~base_path in
  let seen = ref [] in
  let notices = Eio.Stream.create 1 in
  let id = "world-memory-write-announcement" in
  let is_world (event : Sse.external_event) =
    match event.ext_payload with
    | `Assoc fields ->
      (match Workspace_dataset_event.of_fields fields with
       | Ok Workspace_dataset_event.World_memory -> true
       | Ok Workspace_dataset_event.(
           ( Repositories | Verification_requests | Harness_verdicts | Goals
           | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
           | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
           | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
           | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
           | Keeper_oauth_attempts _ | Memory_health _ | Play_seats | Dashboard_observation _ ))
       | Error _ -> false)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
  in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
    ~callback:(fun event ->
      if is_world event then (
        seen := (Option.is_some (Dashboard_cache.peek key),
                 Result.is_ok (Workspace_memory_ledger.load ~base_path)) :: !seen;
        Eio.Stream.add notices ()))
    ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
    let seed () =
      Dashboard_cache.seed_stale_if_missing key ~stale_for:60.0 (`Assoc []);
      check bool "the prior inventory is cached" true
        (Option.is_some (Dashboard_cache.peek key))
    in
    Eio.Switch.run (fun sw ->
      Server_memory_health_broadcast.install ~sw ~mono_clock ~config;
      seed ();
      Workspace_memory_ledger.save ~base_path Workspace_memory_ledger.empty |> require;
      Eio.Stream.take notices;
      check (list (pair bool bool)) "the ledger is readable and the inventory gone at notification"
        [ false, true ] (List.rev !seen);
      seed ();
      Workspace_memory_briefing.save
        ~directory:(Workspace_memory_ledger.directory ~base_path)
        Workspace_memory_briefing.empty |> require;
      Eio.Stream.take notices;
      check (list (pair bool bool)) "a briefing commit invalidates the same inventory"
        [ false, true; false, true ] (List.rev !seen);
      seed ();
      Workspace_memory_changed.written ~directory:elsewhere;
      check bool "another workspace leaves the cached answer alone" true
        (Option.is_some (Dashboard_cache.peek key));
      check int "another workspace is not announced here" 2 (List.length !seen));
    Workspace_memory_ledger.save ~base_path Workspace_memory_ledger.empty |> require;
    check int "a released server no longer announces" 2 (List.length !seen))
;;

let test_briefing_prompt_changes_invalidate_without_a_curator () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock ~await_health:_ ~config ~fleet_key:_ ~elsewhere:_ ~config_keepers_dir:_
       ~runtime_keepers_dir:_ ~heard:_ ->
  let module Ledger = Workspace_memory_ledger in
  let module Briefing = Workspace_memory_briefing in
  let base_path = config.Workspace.base_path in
  let key = Prompt_names.workspace_memory_briefing in
  let prompts = Filename.concat base_path "prompts" in
  Fs_compat.mkdir_p prompts;
  Out_channel.with_open_text (Filename.concat prompts (key ^ ".md")) (fun channel ->
    output_string channel
      "---\ndescription: briefing fixture\ncategory: test\n---\nBriefing fixture contract");
  Prompt_registry.clear ();
  Fun.protect ~finally:Prompt_registry.clear (fun () ->
    Prompt_registry.set_markdown_dir prompts;
    let claim = "The workspace has one saved claim" in
    let fact = Ledger.Ordinary {
      keeper_id = "fixture";
      claim_sha256 = Agent_core_sha256.(digest_string claim |> to_hex);
    } in
    let ledger =
      Ledger.apply Ledger.empty ~selected:[{ Ledger.fact = fact; claim }]
        [{ Ledger.fact = fact; decision = Ledger.Create_claim claim }]
      |> Result.map_error Ledger.apply_error_to_string |> require in
    Ledger.save ~base_path ledger |> require;
    let contract = Briefing.contract ~template:(Prompt_registry.get_prompt key) in
    let saved =
      match Briefing.prepare ~sources:(Ledger.briefing_sources ledger) ~contract
          ~render:(fun json -> Ok (Yojson.Safe.to_string json)) Briefing.empty |> require with
      | Briefing.Prepared batch -> Briefing.accept batch ~text:"Saved briefing" |> require
      | Briefing.Unchanged | Briefing.Cleanup _ -> fail "the claim prepared no briefing" in
    Briefing.save ~directory:(Ledger.directory ~base_path) saved |> require;
    let status () =
      match Ledger.observe ~base_path with
      | Ledger.Missing -> fail "the saved ledger disappeared"
      | Ledger.Unavailable detail -> fail detail
      | Ledger.Available { briefing; _ } ->
        match briefing with
        | Error detail -> fail detail
        | Ok Briefing.Missing -> fail "the saved briefing disappeared"
        | Ok (Briefing.Current _) -> "current"
        | Ok (Briefing.Stale _) -> "stale"
    in
    check string "the original contract is current" "current" (status ());
    let cache_key =
      Server_dashboard_http_core_cache.workspace_memory_inventory_cache_key ~base_path in
    let seed () =
      Dashboard_cache.seed_stale_if_missing cache_key ~stale_for:60.0 (`Assoc []);
      check bool "the prior inventory is warm" true
        (Option.is_some (Dashboard_cache.peek cache_key)) in
    let seen = ref 0 in
    let waiting = ref None in
    let id = "world-memory-prompt-contract" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
      ~id ~callback:(fun (event : Sse.external_event) ->
        let world = match event.ext_payload with
          | `Assoc fields ->
            Workspace_dataset_event.of_fields fields = Ok Workspace_dataset_event.World_memory
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false in
        if world then begin
          incr seen;
          let observation = Option.is_some (Dashboard_cache.peek cache_key), status () in
          Option.iter (fun resolve -> Eio.Promise.resolve resolve observation) !waiting;
          waiting := None
        end) ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      Eio.Switch.run (fun sw ->
        Server_memory_health_broadcast.install ~sw ~mono_clock ~config;
        let unsubscribe_fault = Workspace_memory_changed.subscribe
          (fun ~directory:_ -> raise (Eio.Cancel.Cancelled (Failure "subscriber failure"))) in
        Eio.Switch.on_release sw unsubscribe_fault;
        let applied request =
          match Server_prompt_override_mutation.apply ~base_path request with
          | Error (Validation detail | Persistence detail) -> fail detail
          | Ok result ->
            check bool "there is no curator owner" true
              (result.curator_refresh = Some Server_workspace_memory_curator.No_owner) in
        let change request expected =
          let observed, resolve = Eio.Promise.create () in
          waiting := Some resolve;
          applied request;
          let cached, actual = Eio.Promise.await observed in
          check bool "inventory invalidated before World notification" false cached;
          check string "the same durable briefing follows the effective contract" expected actual in
        seed ();
        change (Server_prompt_override_request.Set { key; value = "Changed briefing contract" }) "stale";
        seed ();
        applied (Server_prompt_override_request.Set { key; value = "Changed briefing contract" });
        Eio.Fiber.yield ();
        check int "an identical effective contract does not announce" 1 !seen;
        check bool "an identical contract keeps the inventory warm" true
          (Option.is_some (Dashboard_cache.peek cache_key));
        let overrides = Filename.concat (Common.masc_dir_from_base_path ~base_path)
            "prompt_overrides.json" in
        Sys.remove overrides;
        Unix.mkdir overrides 0o700;
        (match Server_prompt_override_mutation.apply ~base_path
            (Server_prompt_override_request.Set { key; value = "Cannot be persisted" }) with
         | Error (Persistence _) -> ()
         | Error (Validation detail) -> fail detail
         | Ok _ -> fail "a directory accepted the prompt override file");
        Eio.Fiber.yield ();
        check int "a failed persistence with unchanged live contract does not announce" 1 !seen;
        check string "the failed write preserves the live contract" "Changed briefing contract"
          (Prompt_registry.get_prompt key);
        check bool "the failed unchanged contract keeps the cached inventory" true
          (Option.is_some (Dashboard_cache.peek cache_key));
        Unix.rmdir overrides;
        change (Server_prompt_override_request.Clear { key }) "current";
        check int "set and clear each announce once without a curator" 2 !seen)))
;;

let test_world_commit_keeps_its_result_when_a_subscriber_cancels () =
  with_workspace
  @@ fun ~clock:_ ~mono_clock:_ ~await_health:_ ~config ~fleet_key:_ ~elsewhere:_ ~config_keepers_dir:_
       ~runtime_keepers_dir:_ ~heard:_ ->
  let base_path = config.Workspace.base_path in
  let reason = Failure "cancel World writer after its atomic commit" in
  let returned = ref false in
  (match Eio.Cancel.sub (fun owner ->
     let unsubscribe = Workspace_memory_changed.subscribe (fun ~directory:_ ->
       Eio.Cancel.cancel owner reason;
       raise (Eio.Cancel.Cancelled Exit)) in
     Fun.protect ~finally:unsubscribe (fun () ->
       Workspace_memory_ledger.save ~base_path Workspace_memory_ledger.empty |> require;
       returned := true;
       Eio.Fiber.check ())) with
   | () -> fail "the writer's actual cancellation disappeared"
   | exception Eio.Cancel.Cancelled actual when actual == reason -> ()
   | exception exn -> raise exn);
  check bool "the committed save returned its original result before cancellation" true !returned;
  check bool "the committed ledger remains readable" true
    (Result.is_ok (Workspace_memory_ledger.load ~base_path))
;;

let test_world_writer_never_waits_for_sse_fanout () =
  with_workspace
  @@ fun ~clock ~mono_clock ~await_health ~config ~fleet_key:_ ~elsewhere:_
       ~config_keepers_dir:_ ~runtime_keepers_dir ~heard:_ ->
  let base_path = config.Workspace.base_path in
  let started, mark_started = Eio.Promise.create () in
  let release, finish_fanout = Eio.Promise.create () in
  let is_world (event : Sse.external_event) =
    match event.ext_payload with
    | `Assoc fields ->
      List.assoc_opt "type" fields = Some (`String Workspace_dataset_event.event_type)
      && Result.fold ~error:(fun _ -> false)
           ~ok:(fun dataset -> Workspace_dataset_event.kind dataset = Workspace_dataset_event.Kind.World_memory)
           (Workspace_dataset_event.of_fields fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
  in
  let id = "world-memory-suspended-fanout" in
  Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
    ~callback:(fun event ->
      if is_world event then (
        if not (Eio.Promise.is_resolved started) then Eio.Promise.resolve mark_started ();
        Eio.Promise.await release)) ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
    (* This only bounds a failed deadlock regression; it is not product cadence. *)
    match Eio.Time.with_timeout clock 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Server_memory_health_broadcast.install ~sw ~mono_clock ~config;
        Workspace_memory_ledger.save ~base_path Workspace_memory_ledger.empty |> require;
        Eio.Promise.await started;
        (* A suspended World fanout also cannot hold up another read model.
           The signal names the directory a write resolved to, so it exists. *)
        Fs_compat.mkdir_p runtime_keepers_dir;
        Keeper_memory_health_input.written ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo";
        await_health ();
        Eio.Promise.resolve finish_fanout ());
      Ok ()) with
    | Ok () -> ()
    | Error `Timeout -> fail "a committed writer or sibling read model waited for SSE fanout")
;;

let () =
  run "memory_health_input_announce"
    [ ( "workspace"
      , [ test_case "writes under the workspace announce their Keeper" `Quick
            test_writes_under_the_workspace_announce_their_keeper
        ; test_case "a notification reloads the warm row" `Quick
            test_a_notification_reloads_the_warm_row
        ; test_case "world writes invalidate before announcing" `Quick
            test_world_writes_invalidate_before_announcing
        ; test_case "briefing contract invalidates without a curator" `Quick
            test_briefing_prompt_changes_invalidate_without_a_curator
        ; test_case "World commit keeps its result when a subscriber cancels" `Quick
            test_world_commit_keeps_its_result_when_a_subscriber_cancels
        ; test_case "World writer never waits for SSE fanout" `Quick
            test_world_writer_never_waits_for_sse_fanout
        ] )
    ; ( "stores"
      , [ test_case "each store write tells the signal once" `Quick
            test_each_store_write_tells_the_signal
        ; test_case "a turn record prune tells its Keeper" `Quick
            test_a_turn_record_prune_tells_its_keeper
        ; test_case "a failing subscriber stops nothing" `Quick
            test_a_failing_subscriber_stops_nothing
        ] )
    ]
;;
