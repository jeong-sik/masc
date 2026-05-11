(** Shared record type for cascade weighted entries.

    Extracted from [Cascade_config_loader] so that downstream resolvers
    (e.g. [Cascade_declarative_legacy_bridge]) can produce values of the
    same type without re-importing the loader — preventing a dependency
    cycle since the loader itself now consumes the bridge as a fallback. *)

type t =
  { model : string
  ; weight : int
  ; supports_tool_choice : bool option
  ; secondary : string option
  ; secondary_supports_tool_choice : bool option
  }
