(** RFC-0182 §3.1 — coord dispatch dependency inversion ref.

    See [coord_dispatch_ref.ml] for the rationale. *)

val dispatch
  : (config:Coord.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.t option)
      ref
