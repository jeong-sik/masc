(** Approval_context sanity — record shape + accessor round-trip. *)

open Masc_exec

let test_make_and_read () =
  let actor = Agent_id.of_string "keeper/alpha" in
  let ctx =
    Approval_context.make
      ~actor
      ~session_id:"sess-42"
      ~worktree_root:"/tmp/mascwt"
      ~now:123.5
  in
  assert (ctx.actor = actor);
  assert (ctx.session_id = "sess-42");
  assert (ctx.worktree_root = "/tmp/mascwt");
  assert (ctx.now = 123.5)

let test_distinct_sessions_are_independent () =
  let a =
    Approval_context.make
      ~actor:`Coord_git
      ~session_id:"A"
      ~worktree_root:"/wt" ~now:0.0
  in
  let b =
    Approval_context.make
      ~actor:`System_task_sandbox
      ~session_id:"B"
      ~worktree_root:"/wt" ~now:10.0
  in
  assert (a.session_id <> b.session_id);
  assert (a.actor <> b.actor);
  assert (a.worktree_root = b.worktree_root)

let () =
  test_make_and_read ();
  test_distinct_sessions_are_independent ();
  print_endline "[test_approval_context] all tests passed"
