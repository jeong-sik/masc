open Keeper_memory_os_types

type source_kind =
  | Librarian
  | Explicit_write
  | Explicit_retract

type source =
  { kind : source_kind
  ; trace_id : string
  }

type support_invalidation =
  { fact : fact
  ; missing_premise_ids : string list
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : fact list
  ; change : change
  }
