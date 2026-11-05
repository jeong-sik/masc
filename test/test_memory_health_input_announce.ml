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
           ( Repositories | Verification_requests | Harness_verdicts | Clients
           | Account_emails | Provider_usage | Provider_standing | Keeper_costs
           | Keeper_oauth_attempts _ | Memory_health _ ))
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
      let id = "memory-health-input-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          Option.iter
            (fun keeper ->
               heard := (keeper, Option.is_some (Dashboard_cache.peek fleet_key)) :: !heard)
            (memory_health_keeper event.ext_payload))
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        f ~config ~fleet_key ~elsewhere ~config_keepers_dir ~runtime_keepers_dir
          ~heard:(fun () -> List.rev !heard)))
;;

let test_writes_under_the_workspace_announce_their_keeper () =
  with_workspace
  @@ fun ~config ~fleet_key ~elsewhere ~config_keepers_dir ~runtime_keepers_dir ~heard ->
  let keepers () = List.map fst (heard ()) in
  let seed_fleet () =
    Dashboard_cache.seed_stale_if_missing fleet_key ~stale_for:60.0 (`Assoc []);
    check bool "the fleet answer is cached before the write" true
      (Option.is_some (Dashboard_cache.peek fleet_key))
  in
  Eio.Switch.run (fun sw ->
    (* Neither directory exists yet: the server names each under its
       resolved ancestor, where the first write creates it. *)
    Server_memory_health_broadcast.install ~sw ~config;
    Fs_compat.mkdir_p config_keepers_dir;
    Fs_compat.mkdir_p runtime_keepers_dir;
    seed_fleet ();
    Keeper_memory_health_input.written ~keepers_dir:runtime_keepers_dir ~keeper_id:"largo";
    check (list (pair string bool))
      "a write under the runtime keepers dir names its Keeper, the fleet answer already gone"
      [ "largo", false ] (heard ());
    Keeper_memory_health_input.written ~keepers_dir:config_keepers_dir ~keeper_id:"piano";
    check (list string) "a write under the config keepers dir names its Keeper"
      [ "largo"; "piano" ] (keepers ());
    (* A writer that reached the directory through a symlink names the same
       directory once the signal resolves it. *)
    let alias = Filename.concat elsewhere "runtime-keepers-alias" in
    Unix.symlink runtime_keepers_dir alias;
    Keeper_memory_health_input.written ~keepers_dir:alias ~keeper_id:"largo";
    check (list string) "a write through a symlinked keepers dir names its Keeper"
      [ "largo"; "piano"; "largo" ] (keepers ());
    seed_fleet ();
    Keeper_memory_commit_notifications.notify_committed
      { Keeper_memory_commit_notifications.keepers_dir = Unix.realpath config_keepers_dir
      ; keeper_id = "forte"
      ; store = Keeper_memory_commit_notifications.Source_bound
      ; revision = 3
      };
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
   the Keeper and the resolved keepers directory. The continuity snapshot's
   save is internal to its module and is not written here. *)
let test_each_store_write_tells_the_signal () =
  with_workspace
  @@ fun ~config ~fleet_key:_ ~elsewhere:_ ~config_keepers_dir ~runtime_keepers_dir ~heard:_ ->
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
    Eio.Switch.run (fun sw ->
      let store = Keeper_types_support.keeper_turn_record_store config "largo" in
      Eio.Switch.on_release sw (fun () -> Dated_jsonl.prepare_for_directory_removal store);
      Keeper_turn_record_writer.write ~request_observations:[] ~config ~keeper_name:"largo"
        ~agent_name:"largo" ~turn_kind:Turn_record.Direct ~trace_id:"trace" ~absolute_turn:1
        ~runtime_profile:"announce.fixture" ~selected_model:None ~finish_reason:None
        ~context_window:None ~price_input_per_million:None ~price_output_per_million:None
        ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
        ~model_input_window:None ~response_observed_model_input:None ~raw_trace_run_ref:None
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
      told_as "a turn record" [ runtime_dir, "largo" ] (take ())))
;;

let () =
  run "memory_health_input_announce"
    [ ( "workspace"
      , [ test_case "writes under the workspace announce their Keeper" `Quick
            test_writes_under_the_workspace_announce_their_keeper
        ] )
    ; ( "stores"
      , [ test_case "each store write tells the signal once" `Quick
            test_each_store_write_tells_the_signal
        ] )
    ]
;;
