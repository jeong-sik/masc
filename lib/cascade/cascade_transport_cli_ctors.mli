(** CLI transport constructors and registration side effects. *)

val make_per_call_switch_transport :
  (sw:Eio.Switch.t -> Llm_provider.Llm_transport.t) -> Llm_provider.Llm_transport.t
