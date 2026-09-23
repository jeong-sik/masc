open Alcotest
module P = Masc.Keeper_librarian_continuity
module B = Masc.Keeper_turn_boundaries
module C = Masc.Keeper_checkpoint_store
module Current = Masc.Keeper_memory_os_current
module Notifications = Masc.Keeper_memory_commit_notifications
module Queue = Masc.Keeper_librarian_queue_refresh
module F = Exact_output_fixture
module T = Agent_core.Types

let get = function Ok value -> value | Error detail -> fail detail
let some = function Some value -> value | None -> fail "expected persisted value"
let trace_id = "cancel-recovery-trace"
let keeper_name = "cancel-recovery-keeper"
let message text = T.make_message ~role:T.User [T.Text text]
let checkpoint messages : Agent_core.Checkpoint.t =
  {version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
   agent_name=keeper_name; model="fixture"; system_prompt=None; messages;
   usage=T.empty_usage; turn_count=List.length messages; created_at=1000.;
   tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
   top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
   preserve_thinking=None;response_format=T.Off;cache_system_prompt=false;
   context=Agent_core.Context.create_sync ();mcp_sessions=[];working_context=None}

exception Cancel_after_memory

let test_cancelled_memory_commit_resumes_without_reapplication () =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
  F.with_official_client_runtimes @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path=Filename.temp_dir "continuity-cancel-recovery-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let config=Masc.Workspace.default_config base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml")) (fun oc ->
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\n"
      keeper_name "Preserve project facts and pending requests." "docker");
  Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name;
  let meta=Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_name;"trace_id",`String trace_id]) |> get in
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let registry=Masc.Exact_lane_run_registry.create
    ~path:(Filename.concat base_path Masc.Exact_lane_run_registry.storage_filename) () in
  (match Masc.Exact_lane_run_registry.install_global registry with
   | Ok () -> () | Error Already_installed -> fail "fixture registry already installed");
  let root=Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Masc.Prompt_defaults.init ();
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[F.cli_primary_runtime] (F.resolver_snapshot ~source:"cancel-recovery" []));
  let session_dir=Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
  let save messages=match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
    | Ok (C.Saved _) -> () | Ok (C.Stale_noop _) -> fail "stale fixture" | Error detail -> fail detail in
  let source=[message "The project is called Meridian.";message "Wait for publication approval."] in
  save source;
  B.append ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {B.recorded_at=1000.;event=B.Turn_ended
      {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
       history_at_start=B.Continued_history;position=B.position_of_messages source |> get}}
    |> Result.map_error B.append_error_to_string |> get;
  let prepared=P.prepare ~config ~keeper_name ~trace_id () |> get |> some in
  let expected_receipt=P.memory_range_id ~config ~keeper_name prepared |> get in
  let first_calls=ref 0 and notifications=ref [] in
  let initial_runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr first_calls;
    Ok {|{"new_claims":[{"claim":"The project is called Meridian.","category":"fact","board_post_id":null,"board_comment_id":null,"supersedes":null,"absorbs":[]}],"dropped":[],"working_contexts":[],"working_state":"Meridian is awaiting publication approval."}|} in
  let physical_keepers_dir=Unix.realpath keepers_dir in
  (try
     Eio.Cancel.sub (fun cancellation ->
       let unsubscribe=Notifications.subscribe (fun (event : Notifications.event) ->
         if event.store=Notifications.Ordinary && event.keeper_id=keeper_name
            && event.keepers_dir=physical_keepers_dir then (
           notifications:=event.revision :: !notifications;
           Eio.Cancel.cancel cancellation Cancel_after_memory;
           (* Existing subscriber cancellation semantics propagate after the
              real snapshot/WAL commit and before continuity publication. *)
           raise (Eio.Cancel.Cancelled Cancel_after_memory))) in
       Fun.protect ~finally:unsubscribe (fun () ->
         Queue.For_testing.run_continuity ~cli_runner:initial_runner ~base_path ~keeper_name ()));
     fail "queue swallowed cancellation after Memory commit"
   with Eio.Cancel.Cancelled Cancel_after_memory -> ());
  check int "one actual runtime generation before cancellation" 1 !first_calls;
  let committed=Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get |> some in
  check (list int) "notification identifies committed revision" [committed.revision] !notifications;
  check int "actual disposition saved a fact" 1 (List.length committed.facts);
  let receipt ()=Current.committed_durable_range ~keepers_dir ~keeper_id:keeper_name
    ~receipt_scope:(P.path ~config ~keeper_name) |> get in
  check bool "Memory saved the original exact range" true (receipt ()=Some expected_receipt);
  check bool "cancellation precedes continuity publication" true
    (P.read ~config ~keeper_name |> get |> Option.is_none);
  let extended=source@[message "An in-flight request must stay outside saved coverage."] in
  save extended;
  let recovered=P.prepare ~config ~keeper_name ~trace_id () |> get |> some in
  check bool "new wake recovers persisted range before newer input" true
    ((P.memory_range_id ~config ~keeper_name recovered |> get)=expected_receipt);
  let resumed_calls=ref 0 in
  (* Memory for this range is committed, so the resumed pass is Context-only
     and asks for the working state alone (#38184). *)
  let resumed_runner ~runtime_id:_ ~system_prompt:_ ~output_schema ~prompt:_ =
    incr resumed_calls;
    check bool "resumed pass asks for no Memory field" true
      (Yojson.Safe.Util.(output_schema |> member "properties" |> member "new_claims") = `Null);
    Ok {|{"working_state":"Meridian is awaiting publication approval."}|} in
  Queue.For_testing.run_continuity ~cli_runner:resumed_runner ~base_path ~keeper_name ();
  check int "resumption regenerates exactly the unpublished state" 1 !resumed_calls;
  let after=Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get |> some in
  check int "Memory was not applied a second time" committed.revision after.revision;
  check bool "Memory content and commit evidence are unchanged" true (after=committed && receipt ()=Some expected_receipt);
  let saved=P.read ~config ~keeper_name |> get |> some in
  check int "published frontier is the original committed endpoint" expected_receipt.end_atom saved.end_atom;
  check int "published boundary is the original real turn" expected_receipt.end_boundary_line saved.end_boundary_line;
  let canonical=match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
    | Ok snapshot -> C.exact_snapshot_messages snapshot | Error _ -> fail "source checkpoint disappeared" in
  check bool "cancellation and resume never rewrite source" true
    (List.equal T.Message_value.equal extended canonical);
  let lines=B.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name |> get in
  let restored=Masc.Librarian_continuity_snapshot.restore ~trace_id ~lines ~messages:canonical saved
    |> Result.map_error Masc.Librarian_continuity_snapshot.error_to_string |> get in
  check bool "next request keeps the uncommitted suffix" true
    (List.equal T.Message_value.equal [List.nth extended 2] restored.messages)

let () = run "continuity Memory cancellation recovery"
  ["queue",[test_case "committed Memory resumes without reapplication" `Quick
    test_cancelled_memory_commit_resumes_without_reapplication]]
