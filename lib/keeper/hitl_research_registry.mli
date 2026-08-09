(** Process-local SSOT for workspace-scoped HITL research authority.

    Runtime bootstrap installs one full-tool runner for its exact workspace.
    Gate recovery resolves only that exact key and fails closed when bootstrap
    has not installed an authority. *)

val install :
  base_path:string -> Hitl_summary_worker.research_runner -> unit

val resolve :
  base_path:string -> (Hitl_summary_worker.research_runner, string) result

module For_testing : sig
  val reset : unit -> unit
end
