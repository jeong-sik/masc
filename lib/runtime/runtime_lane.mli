(** Runtime lane — ordered candidate list for keeper turn failover.

    [id] is the lane's own name, the [\[runtime.lanes.<name>\]] table key. It is
    chosen by the operator and carries no structure; a keeper assignment or a
    route id names it to walk the lane. Candidates are opaque runtime ids
    ("provider.model" binding keys), optionally paired with a declarative
    reasoning effort override. The [Runtime] module resolves ids to materialized
    runtimes, keeping this module free of the [Runtime] dependency cycle. *)

type t =
  { id : string
  ; candidates : string list
  ; default_effort : Llm_provider.Reasoning_effort.t option
  ; candidate_efforts : (string * Llm_provider.Reasoning_effort.t option) list
  }

val make
  :  ?default_effort:Llm_provider.Reasoning_effort.t
  -> ?candidate_efforts:(string * Llm_provider.Reasoning_effort.t option) list
  -> id:string
  -> string list
  -> t

val id : t -> string
val ordered_candidates : t -> string list
val default_effort : t -> Llm_provider.Reasoning_effort.t option
val effort_for_candidate : t -> string -> Llm_provider.Reasoning_effort.t option
