(** The four spawn tool handlers backed by a turn-scoped process registry. *)

type context =
  { registry : Spawn_registry.t
  ; sw : Eio.Switch.t
  }

val dispatch
  :  context
  -> name:string
  -> args:Yojson.Safe.t
  -> Tool_result.result option

val schemas : Masc_domain.tool_schema list
