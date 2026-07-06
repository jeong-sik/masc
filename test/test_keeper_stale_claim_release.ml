(** Regression guard for stale-claim release during [keeper_task_claim].

    When a keeper claims work, tasks held by keepers that have gone stale
    (last_seen far in the past, claim aged past the release window) must be
    released back to the pool before the new claim resolves. This is the
    zombie-task cleanup path and is independent of the (now retired) WIP
    admission gate: the response no longer carries a [wip_admission] field, so
    this test asserts only [stale_claim_releases], the resulting [claimed_task],
    and that a released task returns to [Todo].

    Restored from the deleted test/test_keeper_wip_admission.ml (the WIP
    admission retirement dropped the whole file, taking this unrelated
    stale-release coverage with it). *)

open Alcotest

module Task_runtime = Masc.Keeper_tool_task_runtime
module U = Yojson.Safe.Util

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_stale_claim_release_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with
  | _ -> ()

let add_goal_task config ~goal_id ~title =
  match
    Masc.Workspace.add_task_with_result config ~goal_id ~title ~priority:3
      ~description:"stale release fixture"
  with
  | Ok created -> created.Masc.Workspace.task_id
  | Error err -> fail (Masc.Workspace.add_task_error_to_string err)

let claim_task_exn config ~agent_name ~task_id =
  match Masc.Workspace.claim_task_r config ~agent_name ~task_id () with
  | Ok _ -> ()
  | Error err -> fail ("claim_task_r failed: " ^ Masc_domain.masc_error_to_string err)

let iso8601_seconds_precision_margin_s = 1.0

let stale_release_timestamp () =
  let age_s =
    Env_config_runtime.Claim.ttl_seconds +. iso8601_seconds_precision_margin_s
  in
  Masc_domain.iso8601_of_unix_seconds (Time_compat.now () -. age_s)

let mark_agent_stale_for_release config ~agent_name ~last_seen =
  Masc.Workspace.update_local_agent_state config ~agent_name (fun agent ->
    { agent with status = Masc_domain.Active; last_seen })

let rewrite_task_status config ~task_id ~f =
  let backlog = Masc.Workspace.read_backlog config in
  let updated_tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.id task_id
         then { task with task_status = f task.task_status }
         else task)
      backlog.tasks
  in
  Masc.Workspace.write_backlog config { backlog with tasks = updated_tasks }

let age_claimed_task_for_release config ~task_id ~claimed_at =
  rewrite_task_status config ~task_id ~f:(function
    | Masc_domain.Claimed { assignee; _ } ->
      Masc_domain.Claimed { assignee; claimed_at }
    | other -> other)

let meta_with_active_goal goal_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "keeper-stale-release"
        ; "agent_name", `String "keeper-stale-release-agent"
        ; "trace_id", `String "trace-stale-release"
        ; "active_goal_ids", `List [ `String goal_id ]
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let test_keeper_task_claim_releases_stale_owners () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let goal, _ =
         match Goal_store.upsert_goal config ~title:"stale release goal" () with
         | Ok payload -> payload
         | Error msg -> fail msg
       in
       let task_ids =
         List.init 4 (fun i ->
           add_goal_task config ~goal_id:goal.id
             ~title:(Printf.sprintf "fix: stale release fixture %d" (i + 1)))
       in
       let first_stale_task_id, second_stale_task_id, stale_claims =
         match task_ids with
         | first :: second :: third :: _ ->
           ( first
           , second
           , [ "keeper-a-agent", first; "keeper-b-agent", second; "keeper-c-agent", third ] )
         | _ -> fail "expected four created task ids"
       in
       List.iter
         (fun (agent_name, task_id) ->
            let stale_timestamp = stale_release_timestamp () in
            claim_task_exn config ~agent_name ~task_id;
            mark_agent_stale_for_release config ~agent_name
              ~last_seen:stale_timestamp;
            age_claimed_task_for_release config ~task_id
              ~claimed_at:stale_timestamp)
         stale_claims;
       let payload =
         Task_runtime.handle_keeper_task_tool ~config
           ~meta:(meta_with_active_goal goal.id)
           ~name:"keeper_task_claim" ~args:(`Assoc [])
       in
       let json = Yojson.Safe.from_string payload in
       check bool "claimed task present" true
         (json |> U.member "claimed_task" <> `Null);
       check int "stale release count" 3
         (json |> U.member "stale_claim_releases" |> U.to_list |> List.length);
       check string "new claimant took released task" first_stale_task_id
         (json |> U.member "claimed_task" |> U.member "task_id" |> U.to_string);
       let backlog = Masc.Workspace.read_backlog config in
       match
         List.find_opt
           (fun (task : Masc_domain.task) -> String.equal task.id second_stale_task_id)
           backlog.tasks
       with
       | Some { task_status = Masc_domain.Todo; _ } -> ()
       | Some task ->
         fail
           (Printf.sprintf "expected %s to be released, got %s" second_stale_task_id
              (Masc_domain.task_status_to_string task.task_status))
       | None -> fail (second_stale_task_id ^ " missing from backlog"))

let () =
  run "Keeper_stale_claim_release"
    [ ( "stale release"
      , [ test_case "keeper_task_claim releases stale owners before claiming"
            `Quick test_keeper_task_claim_releases_stale_owners
        ] )
    ]
