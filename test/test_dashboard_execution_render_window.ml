(* An execution dashboard render that finished as its window closed is the
   render.

   [Dashboard_execution.json] bounds the render so a stalled store read cannot
   hold a request for hours, and the bound used to be
   [Eio.Time.with_timeout], which keeps whichever arm finished first. A render
   that completed in the pass the window expired was replaced with the
   "render timed out" page. The mock clock puts the window's wake-up ahead of
   the render's on purpose. *)
open Alcotest
open Masc
module Execution = Dashboard_execution

let window_s = 1.0

let with_clock f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run @@ fun sw -> f ~sw ~clock
;;

let rendered = `Assoc [ "rendered", `Bool true ]

let test_a_render_that_finished_as_the_window_closed_is_the_render () =
  with_clock
  @@ fun ~sw ~clock ->
  let render_done, finish = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Execution.For_test.render_under_timeout ~clock ~timeout_s:window_s (fun () ->
        Eio.Promise.await render_done))
  in
  (* The window closes first: its wake-up is queued. The render then
     finishes, queuing its wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve finish rendered;
  match Eio.Promise.await_exn running with
  | Ok payload ->
    check bool "the render that finished is the answer" true (Yojson.Safe.equal rendered payload)
  | Error `Timeout -> fail "a render that finished as the window closed became the timeout page"
;;

let test_a_render_that_never_finishes_is_a_timeout () =
  with_clock
  @@ fun ~sw ~clock ->
  let never, _ = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Execution.For_test.render_under_timeout ~clock ~timeout_s:window_s (fun () ->
        Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await_exn running with
  | Error `Timeout -> ()
  | Ok _ -> fail "nothing was rendered, yet the window did not end the render"
;;

let test_workspace_root_matches_item_admission_through_symlink () =
  let root = Filename.temp_dir "execution-root-" "" in
  let alias = root ^ "-alias" in
  Unix.symlink root alias;
  Fun.protect ~finally:(fun () -> Unix.unlink alias; Fs_compat.remove_tree root) (fun () ->
    let config = Masc.Workspace.default_config alias in
    let diagnostics = Masc.Server_base_path_diagnostics.detect
      ~effective_base_path:config.base_path ~effective_masc_root:(Masc.Workspace.masc_dir config) () in
    let status = Execution.For_test.workspace_status_json config in
    let observed = Yojson.Safe.Util.(status |> member "workspace_root" |> to_string) in
    check string "execution and Item admission use one canonical identity"
      diagnostics.effective_base_path observed;
    check string "the alias resolves to the actual workspace" (Unix.realpath root) observed)
;;

module Builders = Dashboard_execution_builders

let source_time = 1_800_000_000.0
let source_iso = Masc_domain.iso8601_of_unix_seconds source_time

let keeper_row ?(paused = false) ?(quiet_reason = `Null) () =
  `Assoc ["name", `String "deadline-keeper"; "status", `String "idle";
    "paused", `Bool paused; "tool_audit_at", `String source_iso;
    "updated_at", `String source_iso; "created_at", `String source_iso;
    "diagnostic", `Assoc [
      "health_state", `String (Keeper_status_runtime.keeper_health_to_string Keeper_types.KH_healthy);
      "quiet_reason", quiet_reason]]
;;

let next_deadline ~now_ts ?(agents = []) ?(keepers = []) () =
  Builders.next_policy_change_unix ~now_ts ~agents ~messages:[] ~keepers
;;

let test_continuity_deadline_matches_the_rendered_policy () =
  let row = keeper_row () in
  let due = source_time +. Env_config.Dashboard.keeper_action_stale_sec in
  let before = Float.next_after due neg_infinity in
  check (option (float 0.0)) "existing inclusive action-age boundary"
    (Some due) (next_deadline ~now_ts:before ~keepers:[row] ());
  let state now_ts = match Builders.continuity_row_of_keeper ~now_ts row with
    | Error error -> fail error
    | Ok row -> Yojson.Safe.Util.(row.json |> member "state" |> to_string) in
  check bool "the deadline changes the actual continuity row" true
    (not (String.equal (state before) (state due)));
  check (option (float 0.0)) "settled stale state has no display-age clock"
    None (next_deadline ~now_ts:due ~keepers:[row] ());
  check (option (float 0.0)) "operator pause has no action-age deadline"
    None (next_deadline ~now_ts:before ~keepers:[keeper_row ~paused:true ()] ())
;;

let test_agent_quiet_deadline_changes_the_visible_brief () =
  let agent : Masc_domain.agent = {
    id = None; name = "deadline-agent"; agent_type = "review";
    status = Masc_domain.Active; capabilities = []; current_task = None;
    session_bound_at = source_iso; last_seen = source_iso; meta = None } in
  let boundary = source_time +. Env_config.Dashboard.signal_quiet_sec in
  let due = match next_deadline ~now_ts:boundary ~agents:[agent] () with
    | Some at -> at | None -> fail "the quiet transition was lost" in
  check bool "strict source-age boundary stays owed" true (due > boundary);
  let briefs now_ts = Builders.build_worker_support_briefs
      ~now_ts ~tasks:[] ~agents:[agent] ~messages:[] in
  check int "the exact boundary is still watching" 0 (List.length (briefs boundary));
  check int "the returned boundary makes the actual quiet brief visible" 1
    (List.length (briefs due));
  check (option (float 0.0)) "fully stale agent has no perpetual freshness scan"
    None (next_deadline
      ~now_ts:(source_time +. Env_config.Dashboard.signal_stale_sec +. 1.0)
      ~agents:[agent] ())
;;

let test_startup_boundary_stays_owed_when_assembly_crossed_it () =
  let reason = Keeper_status_runtime.keeper_quiet_reason_to_string
      Keeper_status_runtime.Starting_up in
  let row = keeper_row ~paused:true ~quiet_reason:(`String reason) () in
  let boundary = source_time +. Keeper_status_runtime.agent_staleness_threshold_s in
  let due = Float.next_after boundary infinity in
  check (option (float 0.0)) "published startup state retains an elapsed policy edge"
    (Some due) (next_deadline ~now_ts:(due +. 5.0) ~keepers:[row] ());
  let settled = keeper_row ~paused:true
      ~quiet_reason:(`String (Keeper_status_runtime.keeper_quiet_reason_to_string Never_started)) () in
  check (option (float 0.0)) "the next current row consumes the edge exactly once"
    None (next_deadline ~now_ts:(due +. 5.0) ~keepers:[settled] ());
  check (option (float 0.0)) "an empty source cannot regenerate an idle deadline"
    None (next_deadline ~now_ts:source_time ())
;;

exception Current_source_read_failed

let test_current_observation_bypasses_actor_ttl_and_keeps_failure () =
  Eio_main.run (fun env ->
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Dashboard_projection_cache.register_operator_snapshot_json
        {snapshot = Operator_control.snapshot_read};
      Dashboard_projection_cache.invalidate_snapshot_json
        ~config:(Workspace.default_config base_path);
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
      (fun () -> Eio.Switch.run (fun sw ->
        let config = Workspace.default_config base_path in
        let cached = `Assoc ["old_actor_metadata", `Bool true] in
        ignore (Dashboard_projection_cache.get_or_compute_snapshot_json
          ~config ~actor:None (fun _ -> Pool_work.cpu ~name:__FUNCTION__ (fun () -> cached)));
        let observed = ref None in
        Dashboard_projection_cache.register_operator_snapshot_json {
          snapshot = (fun ?read_policy ?actor:_ ?view:_ ?include_messages:_
              ?include_keepers:_ ?include_summary_fields:_ ?lightweight_summary:_ _ctx ->
            observed := read_policy;
            raise Current_source_read_failed) };
        (match Execution.observe_current ~config ~sw ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None () with
         | _ -> fail "current metadata was silently replaced by the old actor snapshot"
         | exception Current_source_read_failed -> ());
        check bool "current reaches the nested metadata reader" true
          (!observed = Some Dashboard_projection_read.Current))))
;;

let () =
  run
    "dashboard_execution_render_window"
    [ ( "render window"
      , [ test_case "workspace symlink uses Item admission identity" `Quick
          test_workspace_root_matches_item_admission_through_symlink
      ; test_case
            "a render that finished as the window closed is the render"
            `Quick
            test_a_render_that_finished_as_the_window_closed_is_the_render
        ; test_case
            "a render that never finishes is a timeout"
            `Quick
            test_a_render_that_never_finishes_is_a_timeout
        ] )
    ; "source deadlines", [
        test_case "continuity deadline changes the actual policy" `Quick
          test_continuity_deadline_matches_the_rendered_policy;
        test_case "quiet signal deadline changes the visible brief" `Quick
          test_agent_quiet_deadline_changes_the_visible_brief;
        test_case "startup edge crossed during assembly stays owed" `Quick
          test_startup_boundary_stays_owed_when_assembly_crossed_it;
        test_case "current metadata bypasses TTL and preserves read failure" `Quick
          test_current_observation_bypasses_actor_ttl_and_keeps_failure ]
    ]
;;
