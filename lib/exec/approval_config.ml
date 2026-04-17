(* Approval_config — pure data.  No I/O.  *)

type agent_overlay = {
  allow_safe_in_worktree : bool;
  ask_audited : bool;
  deny_destructive_git : bool;
}

type t = {
  defaults : agent_overlay;
  per_agent : (string * agent_overlay) list;
}

let strict_default : agent_overlay =
  {
    allow_safe_in_worktree = false;
    ask_audited = true;
    deny_destructive_git = true;
  }

let permissive_default : agent_overlay =
  {
    allow_safe_in_worktree = true;
    ask_audited = true;
    deny_destructive_git = true;
  }

let empty : t = { defaults = strict_default; per_agent = [] }

let lookup t ~actor =
  match List.assoc_opt actor t.per_agent with
  | Some overlay -> overlay
  | None -> t.defaults
