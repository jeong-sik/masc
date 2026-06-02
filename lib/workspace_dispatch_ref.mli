(** RFC-0182 §3.1 — workspace dispatch dependency inversion ref.

    See [workspace_dispatch_ref.ml] for the rationale. *)

val dispatch
  : (config:Workspace.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
