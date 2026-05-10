(* Approval_context — runtime state record. *)

type t = {
  actor : Agent_id.t;
  session_id : string;
  worktree_root : string;
  now : float;
}

let make ~actor ~session_id ~worktree_root ~now =
  { actor; session_id; worktree_root; now }
