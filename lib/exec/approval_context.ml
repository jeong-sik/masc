(* Approval_context — runtime state record. *)

type t = {
  actor : string;
  session_id : string;
  worktree_root : string;
  now : float;
}

let make ~actor ~session_id ~worktree_root ~now =
  { actor; session_id; worktree_root; now }
