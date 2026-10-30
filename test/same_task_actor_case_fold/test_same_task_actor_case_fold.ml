(* Current-law characterization of Workspace_task_classify.same_task_actor.

[same_task_actor] accepts a config and ignores it: the comparison is byte
equality. Two incident reports show the cost of that law, and both are why
this table deserves a pin:

- #8667 — a task claimed under a mixed-case agent id could never be
  transitioned: the claim stored "…T131006Z" while transitions arrived as
  "…t131006z"; the bytes differ, so the owner was refused forever.
- #25490 — a keeper asking as "executor" against assignee
  "keeper-executor-agent" was refused 102 times over 11h40m (task-2296).

This suite pins the present behaviour; it does not endorse it. When the
ownership-identity work lands — #31861 option (a), the one-shot
assignee-correction migration approved on 2026-08-29; RFC-0393 forbids
reinterpreting historical decorated strings — the affected rows change in
the same PR and this diff tells the story.

The suite builds two configs from distinct temp base paths and requires the
same answer under both, which is the observable content of "the config is
ignored". Nothing here initialises a workspace or writes through the
backend. *)
let with_two_configs f =
  let dir_a = Filename.temp_dir "same_task_actor_a" "" in
  let dir_b = Filename.temp_dir "same_task_actor_b" "" in
  let () =
    f
      (Workspace_core.default_config dir_a)
      (Workspace_core.default_config dir_b)
  in
  (try ignore (Unix.rmdir dir_a) with _ -> ());
  try ignore (Unix.rmdir dir_b) with _ -> ()
;;

let expect_same ~config_a ~config_b left right =
  let same_a = Workspace_task_classify.same_task_actor config_a left right in
  let same_b = Workspace_task_classify.same_task_actor config_b left right in
  if (not same_a) || (not same_b)
  then failwith (left ^ " / " ^ right ^ " must be the same actor")
;;

let expect_different ~config_a ~config_b left right =
  let same_a = Workspace_task_classify.same_task_actor config_a left right in
  let same_b = Workspace_task_classify.same_task_actor config_b left right in
  if same_a || same_b
  then failwith (left ^ " / " ^ right ^ " must stay different actors")
;;

let () =
  with_two_configs @@ fun config_a config_b ->
  (* Byte-identical spellings are one actor — including the decorated form,
     which both sides send since the 2026-07-18 duplicate-loop fix aligned
     the call sites on "keeper-…-agent". *)
  expect_same ~config_a ~config_b "lane-smith" "lane-smith";
  expect_same ~config_a ~config_b "keeper-executor-agent" "keeper-executor-agent";
  (* Case-only differences are different actors today (#8667's wedge). *)
  expect_different ~config_a ~config_b "lane-smith" "Lane-Smith";
  expect_different ~config_a ~config_b "lane-smith" "LANE-SMITH";
  (* Shape differences are different actors: no alias registry exists. *)
  expect_different ~config_a ~config_b "lane-smith" "lane_smith";
  expect_different ~config_a ~config_b "lane-smith" "lane-smith-agent";
  expect_different ~config_a ~config_b "lane-smith" "lane";
  (* The decorated form is not linked to the bare name (#25490's wedge). *)
  expect_different ~config_a ~config_b "keeper-lane-smith-agent" "lane-smith";
  print_endline "test_same_task_actor_case_fold: current law pinned"
;;