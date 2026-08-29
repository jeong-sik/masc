(* Ownership comparison for task claims: [same_task_actor] folds ASCII case
   only, in one direction. A keeper whose durable name is "lane-smith" must
   recognise a claim written as "Lane-Smith" as its own — otherwise the claim
   dangles until someone logs in under the original byte sequence. The fold is
   deliberately not broader: names differing by shape (hyphens, underscores,
   prefixes) stay different actors, because no typed alias registry grants
   them shared identity. [same_task_actor] ignores its config (the comparison
   is identity, not workspace state), so the suite builds one config from a
   temp base path and reuses it; nothing here writes through the backend. *)

let make_config () =
  let base_path = Filename.temp_dir "same-task-actor" "" in
  Masc.Workspace.default_config base_path
;;

let expect_same left right =
  if not (Workspace_task_classify.same_task_actor (make_config ()) left right)
  then failwith (left ^ " / " ^ right ^ " must be the same actor")
;;

let expect_different left right =
  if Workspace_task_classify.same_task_actor (make_config ()) left right
  then failwith (left ^ " / " ^ right ^ " must stay different actors")
;;

let () =
  (* Case-only differences fold to one actor, in both directions. *)
  expect_same "lane-smith" "Lane-Smith";
  expect_same "Lane-Smith" "lane-smith";
  expect_same "lane-smith" "LANE-SMITH";
  expect_same "lane-smith" "lane-smith";
  (* Shape differences are a different actor: the 2026-07-18 duplicate
     board-post loop traced to "keeper-lane-smith-agent" vs "lane-smith",
     and that mismatch needs a typed identity, not a looser fold. *)
  expect_different "lane-smith" "keeper-lane-smith-agent";
  expect_different "lane-smith" "lane_smith";
  expect_different "lane-smith" "lane-smith-agent";
  expect_different "lane-smith" "lane";
  print_endline "test_same_task_actor_case_fold: all tests passed"
