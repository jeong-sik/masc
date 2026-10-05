open Alcotest

module Goals = Masc.Workspace_goals
module Hooks = Workspace_hooks

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

let config_at path =
  let config = Workspace_utils.default_config_uncached path in
  Fs_compat.mkdir_p (Workspace_utils.masc_dir config);
  config

let with_workspace run =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_file "goal-drop-delivery-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let config = config_at path in
  let abandoned = ref 0 in
  let old = Atomic.exchange Hooks.goal_verification_abandoned_fn
    (fun _ ~goal_id:_ -> incr abandoned) in
  Fun.protect ~finally:(fun () ->
    Atomic.set Hooks.goal_verification_abandoned_fn old;
    remove_tree path)
    (fun () -> run config abandoned (Eio.Stdenv.process_mgr env))

let create config =
  match Goal_store.upsert_goal config ~title:"Preserve cancellation audit"
    ~metric:"cancelled Goals with audit" ~target_value:"1" () with
  | Ok (goal, _) -> goal
  | Error error -> fail (Goal_store.write_error_to_string error)

let drop config ?note goal_id =
  let ctx : Masc.Workspace_types.context = {config; agent_name="operator"} in
  Goals.handle_goal_transition ~tool_name:"masc_goal_transition"
    ~start_time:(Tool_timing.start ()) ctx
    (`Assoc (["goal_id", `String goal_id; "action", `String "drop"]
      @ match note with None -> [] | Some value -> ["note", `String value]))

let success result =
  if not (Tool_result.is_success result) then fail (Tool_result.message result);
  Yojson.Safe.from_string (Tool_result.message result)

let saved config =
  match Goal_store.load_source config with
  | Goal_store.Available state -> state
  | Uninitialized -> fail "missing Goal store"
  | Unavailable failure -> fail (Goal_store.unavailable_to_string failure)

let audit_path config = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"
let events config =
  Fs_compat.load_file (audit_path config) |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string

let member name json = Yojson.Safe.Util.member name json
let text name json = member name json |> Yojson.Safe.Util.to_string

let check_delivered_once config goal event_id =
  let rows = events config in
  check int "one committed cancellation event" 1 (List.length rows);
  let row = List.hd rows in
  check string "same durable event identity" event_id (text "event_id" row);
  check string "cancelled Goal" goal.Goal_store.id (text "goal_id" row);
  check string "event kind" "goal_phase" (text "event_type" row);
  check string "recorded phase" "dropped" (member "payload" row |> text "phase");
  check string "recorded actor" "operator" (member "payload" row |> text "actor");
  check int "outbox acknowledged" 0 (List.length (saved config).pending_events)

let obstruct_audit config = Unix.mkdir (audit_path config) 0o700
let restore_audit config = Unix.rmdir (audit_path config)

let committed_pending config goal response =
  check string "commit reported separately from delivery" "deferred"
    (member "effect_delivery" response |> text "status");
  let state = saved config in
  let current = List.find (fun g -> g.Goal_store.id = goal.Goal_store.id) state.goals in
  check string "Goal is durably cancelled" "dropped" (Goal_phase.to_string current.phase);
  check (option string) "reason is durable" (Some "operator cancellation") current.last_review_note;
  match state.pending_events with
  | [event] -> event.Goal_store.event_id
  | _ -> fail "cancellation lost its durable audit intent"

let test_repeat_repairs_audit () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  obstruct_audit config;
  let response = drop config ~note:"operator cancellation" goal.id |> success in
  let event_id = committed_pending config goal response in
  check int "verifier cancellation notified once" 1 !abandoned;
  restore_audit config;
  let repeated = drop config ~note:"must not replace the original reason" goal.id |> success in
  check bool "repeat is a lifecycle no-op" true (member "noop" repeated |> Yojson.Safe.Util.to_bool);
  check string "repeat repairs pending delivery" "delivered"
    (member "effect_delivery" repeated |> text "status");
  check_delivered_once config goal event_id;
  let current = List.find (fun g -> g.Goal_store.id = goal.id) (saved config).goals in
  check (option string) "repeat preserves the original cancellation reason"
    (Some "operator cancellation") current.last_review_note;
  let before = Fs_compat.load_file (Goal_store.goals_path config) in
  ignore (drop config goal.id |> success);
  check string "settled repeat does not rewrite the Goal" before
    (Fs_compat.load_file (Goal_store.goals_path config));
  check int "repeats do not notify verifier again" 1 !abandoned;
  check_delivered_once config goal event_id

let test_restart_recovers_after_goal_deletion () = with_workspace @@ fun config _ process_mgr ->
  let goal = create config in
  obstruct_audit config;
  let response = drop config ~note:"operator cancellation" goal.id |> success in
  let event_id = committed_pending config goal response in
  (match Goal_store.delete_goal config ~goal_id:goal.id with
   | Ok _ -> () | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  restore_audit config;
  Eio.Process.run process_mgr
    [Sys.executable_name; "--flush-goal-delivery"; config.base_path];
  check_delivered_once config goal event_id;
  check int "deleted Goal remains deleted" 0 (List.length (saved config).goals)

let test_failed_commit_has_no_effect () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let path = Goal_store.goals_path config in
  let before = Fs_compat.load_file path in
  let directory = Filename.dirname path in
  Unix.chmod directory 0o500;
  let result = Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700)
    (fun () -> drop config goal.id) in
  check bool "failed state commit is a failure" false (Tool_result.is_success result);
  check string "primary unchanged" before (Fs_compat.load_file path);
  check int "no cancellation hook before commit" 0 !abandoned;
  check int "no intent before commit" 0 (List.length (saved config).pending_events);
  check bool "no fabricated audit" false (Sys.file_exists (audit_path config))

let test_unavailable_is_not_a_drop () = with_workspace @@ fun config abandoned _ ->
  let goal = create config in
  let path = Goal_store.goals_path config in
  Fs_compat.save_file path "{broken";
  let result = drop config goal.id in
  check bool "unreadable primary is refused" false (Tool_result.is_success result);
  check string "corrupt primary is preserved" "{broken" (Fs_compat.load_file path);
  check int "no verifier cancellation" 0 !abandoned;
  check bool "no audit on failed read" false (Sys.file_exists (audit_path config))

let test_missing_goal_is_not_created () = with_workspace @@ fun config abandoned _ ->
  let result = drop config "goal-missing" in
  check bool "missing Goal is refused" false (Tool_result.is_success result);
  check bool "no Goal invented" false (Sys.file_exists (Goal_store.goals_path config));
  check int "no verifier cancellation" 0 !abandoned

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--flush-goal-delivery" then (
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    match Goal_delivery.flush (config_at Sys.argv.(2)) with
    | Ok () -> () | Error detail -> prerr_endline detail; exit 1)
  else
    run "Goal cancellation delivery"
      ["durability", [
        test_case "repeat repairs committed audit exactly once" `Quick test_repeat_repairs_audit;
        test_case "fresh process drains audit after Goal deletion" `Quick test_restart_recovers_after_goal_deletion;
        test_case "failed commit creates no effects" `Quick test_failed_commit_has_no_effect;
        test_case "unavailable primary remains unchanged" `Quick test_unavailable_is_not_a_drop;
        test_case "missing Goal remains missing" `Quick test_missing_goal_is_not_created]]
