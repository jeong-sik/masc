(** Tests for the dashboard "Keeper autonomous background" projection
    ({!Server_keeper_background}). The projection joins the keeper registry
    (loop liveness) with the recurring-task registry, so each case seeds those
    global stores and pins the projected wire shape.

    Isolation: a unique base_path per case namespaces registry entries and
    recurring entries; [Keeper_recurring.clear] resets the in-memory store. *)

open Alcotest
module Server_keeper_background = Masc.Server_keeper_background
module Keeper_registry = Masc.Keeper_registry
module Keeper_recurring = Masc.Keeper_recurring
module J = Yojson.Safe.Util

let temp_base () =
  let d = Filename.temp_file "keeper_background_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String ("agent-" ^ name)
        ; "trace_id", `String ("trace-" ^ name)
        ; "allowed_paths", `List [ `String "*" ]
        ])
  with
  | Ok meta -> meta
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let register_keeper ~base name = ignore (Keeper_registry.register ~base_path:base name (make_meta name))

let keeper_row json name =
  json
  |> J.member "keepers"
  |> J.to_list
  |> List.find_opt (fun row -> String.equal name J.(row |> member "keeper_name" |> to_string))
;;

let recurring_of row = row |> J.member "recurring" |> J.to_list

(* ── a keeper with no recurring task is not surfaced ── *)
let test_empty_when_no_recurring () =
  Keeper_recurring.clear ();
  let base = temp_base () in
  let config = Workspace_core.default_config base in
  register_keeper ~base "lonely-keeper";
  let json = Server_keeper_background.dashboard_json config in
  check string "schema" "masc.dashboard.keeper_background.v1" J.(json |> member "schema" |> to_string);
  check int "keeper registered" 1 J.(json |> member "keeper_count" |> to_int);
  check int "no recurring keeper rows" 0 J.(json |> member "recurring_keeper_count" |> to_int);
  check int "no recurring tasks" 0 J.(json |> member "recurring_count" |> to_int);
  check int "keepers list empty" 0 (json |> J.member "keepers" |> J.to_list |> List.length)
;;

(* ── a recurring task surfaces with loop context; a never-run task reports
      null last/next run rather than epoch 0 ── *)
let test_recurring_task_surfaced () =
  Keeper_recurring.clear ();
  let base = temp_base () in
  let config = Workspace_core.default_config base in
  let name = "watcher" in
  register_keeper ~base name;
  ignore
    (Keeper_recurring.add
       ~base_path:base
       ~keeper_name:name
       ~label:"board 감시"
       ~interval_sec:30
       (Keeper_recurring.Broadcast "tick"));
  let json = Server_keeper_background.dashboard_json config in
  check int "one recurring keeper" 1 J.(json |> member "recurring_keeper_count" |> to_int);
  check int "one recurring task" 1 J.(json |> member "recurring_count" |> to_int);
  match keeper_row json name with
  | None -> fail "keeper with recurring task missing from projection"
  | Some row ->
    check string "loop phase running" "running" J.(row |> member "loop" |> member "phase" |> to_string);
    (match recurring_of row with
     | [ task ] ->
       check string "label" "board 감시" J.(task |> member "label" |> to_string);
       check int "interval" 30 J.(task |> member "interval_sec" |> to_int);
       check bool "enabled" true J.(task |> member "enabled" |> to_bool);
       check string "action kind" "broadcast" J.(task |> member "action_kind" |> to_string);
       check int "run count" 0 J.(task |> member "run_count" |> to_int);
       check bool "last_run null (never run)" true (J.member "last_run_at" task = `Null);
       check bool "next_run null (never run)" true (J.member "next_run_at" task = `Null)
	     | other -> failf "expected exactly one recurring task, got %d" (List.length other))
;;

(* ── top-level recurring_count is scoped to returned keeper rows, not every
      global Keeper_recurring entry keyed by an absent keeper name ── *)
let test_recurring_count_ignores_unregistered_keepers () =
  Keeper_recurring.clear ();
  let base = temp_base () in
  let config = Workspace_core.default_config base in
  let name = "registered-keeper" in
  register_keeper ~base name;
  ignore
    (Keeper_recurring.add
       ~base_path:base
       ~keeper_name:name
       ~label:"visible"
       ~interval_sec:30
       (Keeper_recurring.Broadcast "visible"));
  ignore
    (Keeper_recurring.add
       ~base_path:base
       ~keeper_name:"orphan-keeper"
       ~label:"orphan"
       ~interval_sec:30
       (Keeper_recurring.Broadcast "orphan"));
  let json = Server_keeper_background.dashboard_json config in
  check int "registered keepers" 1 J.(json |> member "keeper_count" |> to_int);
  check int "one visible recurring keeper" 1 J.(json |> member "recurring_keeper_count" |> to_int);
  check int "orphan recurring task excluded" 1 J.(json |> member "recurring_count" |> to_int);
  check int "only registered keeper row returned" 1 (json |> J.member "keepers" |> J.to_list |> List.length);
  match keeper_row json name with
  | None -> fail "registered keeper missing from projection"
  | Some row ->
    (match recurring_of row with
      | [ task ] -> check string "visible task only" "visible" J.(task |> member "label" |> to_string)
     | other -> failf "expected one visible task, got %d" (List.length other))
;;

(* ── recurring tasks are scoped by base_path as well as keeper name; two
      workspaces can legitimately have a keeper with the same name ── *)
let test_same_keeper_name_is_base_path_scoped () =
  Keeper_recurring.clear ();
  let base_a = temp_base () in
  let base_b = temp_base () in
  let config_a = Workspace_core.default_config base_a in
  let config_b = Workspace_core.default_config base_b in
  let name = "watcher" in
  register_keeper ~base:base_a name;
  register_keeper ~base:base_b name;
  ignore
    (Keeper_recurring.add
       ~base_path:base_b
       ~keeper_name:name
       ~label:"base-b-only"
       ~interval_sec:30
       (Keeper_recurring.Broadcast "base-b"));
  let json_a = Server_keeper_background.dashboard_json config_a in
  check int "base A has registered keeper" 1 J.(json_a |> member "keeper_count" |> to_int);
  check int "base A has no recurring rows" 0 J.(json_a |> member "recurring_keeper_count" |> to_int);
  check int "base A has no recurring tasks" 0 J.(json_a |> member "recurring_count" |> to_int);
  check int "base A keeper list empty" 0 (json_a |> J.member "keepers" |> J.to_list |> List.length);
  let json_b = Server_keeper_background.dashboard_json config_b in
  check int "base B has recurring row" 1 J.(json_b |> member "recurring_keeper_count" |> to_int);
  check int "base B has recurring task" 1 J.(json_b |> member "recurring_count" |> to_int);
  match keeper_row json_b name with
  | None -> fail "base B keeper with recurring task missing"
  | Some row ->
    (match recurring_of row with
     | [ task ] -> check string "base B task only" "base-b-only" J.(task |> member "label" |> to_string)
     | other -> failf "expected one base B task, got %d" (List.length other))
;;

(* ── next_run is derived only for a task that has run and is still enabled;
      a paused task reports null next_run even with a concrete last_run ── *)
let test_next_run_derivation () =
  Keeper_recurring.clear ();
  let base = temp_base () in
  let config = Workspace_core.default_config base in
  let name = "cadence-keeper" in
  register_keeper ~base name;
  let task =
    Keeper_recurring.add ~base_path:base ~keeper_name:name ~label:"주기 브로드캐스트" ~interval_sec:60
      (Keeper_recurring.Broadcast "beat")
  in
  task.last_run_ts <- 1000.0;
  task.run_count <- 3;
  let json = Server_keeper_background.dashboard_json config in
  (match keeper_row json name with
   | Some row ->
     (match recurring_of row with
      | [ t ] ->
        check (float 0.001) "last_run surfaced" 1000.0 J.(t |> member "last_run_at" |> to_number);
        check (float 0.001) "next_run = last + interval" 1060.0 J.(t |> member "next_run_at" |> to_number);
        check int "run count" 3 J.(t |> member "run_count" |> to_int)
      | _ -> fail "expected one task")
   | None -> fail "keeper missing");
  (* pause the task: next_run must drop to null even though last_run is concrete *)
  task.enabled <- false;
  let json = Server_keeper_background.dashboard_json config in
  match keeper_row json name with
  | Some row ->
    (match recurring_of row with
     | [ t ] ->
       check bool "disabled" false J.(t |> member "enabled" |> to_bool);
       check (float 0.001) "last_run still surfaced" 1000.0 J.(t |> member "last_run_at" |> to_number);
       check bool "next_run null when paused" true (J.member "next_run_at" t = `Null)
     | _ -> fail "expected one task")
  | None -> fail "keeper missing"
;;

let () =
  run "server_keeper_background"
    [ ( "projection",
        [ test_case "empty when no recurring task" `Quick test_empty_when_no_recurring
        ; test_case "recurring task surfaced with loop context" `Quick test_recurring_task_surfaced
        ; ( test_case
              "recurring_count ignores unregistered keepers"
              `Quick
              test_recurring_count_ignores_unregistered_keepers )
        ; ( test_case
              "same keeper name is base_path scoped"
              `Quick
              test_same_keeper_name_is_base_path_scoped )
        ; test_case "next_run derivation and pause" `Quick test_next_run_derivation
        ] )
    ]
;;
