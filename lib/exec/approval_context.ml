(* Approval_context — runtime state record. *)

type t = {
  actor : Agent_id.t;
  session_id : string;
  workspace_root : string;
  now : float;
}

let make ~actor ~session_id ~workspace_root ~now =
  { actor; session_id; workspace_root; now }
