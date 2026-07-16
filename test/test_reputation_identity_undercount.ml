open Alcotest
open Masc

(* Regression for the reputation task-count undercount: a keeper claims and
   completes tasks under its full actor id ("keeper-<h>-agent") — the form the
   backlog persists — while reputation is computed per short handle. The count
   must fold both sides to the canonical keeper name so the keeper's own rows
   are not dropped. Before the fix [count_tasks_from_backlog] compared the raw
   short handle against the stored full actor id and returned zero. *)

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_reputation_identity_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir

let with_workspace ?(agent_name = "keeper-repkeeper-agent") f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some agent_name));
      f config)

let configured_llm_completion_pass : Masc_domain.configured_llm_completion_verdict =
  { decision = Masc_domain.Completion_pass
  ; runtime_id = "reputation-identity-test-reviewer"
  ; rationale = None
  ; evaluated_at = "2026-07-13T00:00:00Z"
  }

let claim_and_complete config ~agent_name ~task_id =
  ignore (Workspace.claim_task config ~agent_name ~task_id);
  match
    Workspace.transition_task_r config ~agent_name ~task_id
      ~action:Masc_domain.Done_action
      ~configured_llm_verdict:configured_llm_completion_pass
      ()
  with
  | Ok _ -> ()
  | Error err ->
      Alcotest.failf "done transition failed: %s"
        (Masc_domain.masc_error_to_string err)

(* The keeper claims under the full actor id; reputation queried by the short
   handle must still see the completed task. *)
let test_full_actor_id_counted_for_short_handle () =
  with_workspace ~agent_name:"keeper-repkeeper-agent" (fun config ->
      ignore
        (Workspace.add_task config ~title:"reputation task" ~priority:1
           ~description:"d");
      claim_and_complete config ~agent_name:"keeper-repkeeper-agent"
        ~task_id:"task-001";
      let rep = Reputation.compute_reputation config ~agent_name:"repkeeper" in
      check int "completed task counted via short handle" 1
        rep.Reputation.tasks_completed;
      check int "claimed task counted via short handle" 1
        rep.Reputation.tasks_claimed)

(* The canonical fold widens matching, it must not merge distinct keepers:
   a task owned by repkeeper must not surface when reputation is queried for an
   unrelated handle. *)
let test_unrelated_handle_not_counted () =
  with_workspace ~agent_name:"keeper-repkeeper-agent" (fun config ->
      ignore
        (Workspace.add_task config ~title:"reputation task" ~priority:1
           ~description:"d");
      claim_and_complete config ~agent_name:"keeper-repkeeper-agent"
        ~task_id:"task-001";
      let rep = Reputation.compute_reputation config ~agent_name:"otherkeeper" in
      check int "unrelated handle sees no completed task" 0
        rep.Reputation.tasks_completed;
      check int "unrelated handle sees no claimed task" 0
        rep.Reputation.tasks_claimed)

let () =
  Alcotest.run "Reputation identity undercount"
    [
      ( "task-count",
        [
          test_case "full actor id counted for short handle" `Quick
            test_full_actor_id_counted_for_short_handle;
          test_case "unrelated handle not counted" `Quick
            test_unrelated_handle_not_counted;
        ] );
    ]
