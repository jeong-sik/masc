(** Discovery_parse — pure JSON parsers for the llama-server discovery
    surface.

    Extracted from {!Discovery} (lines 122-195 in the pre-split
    [discovery.ml]) so the parse layer can be reused by callers that
    just need to interpret one of the discovery JSON shapes without
    pulling in the I/O + Atomic-state half of [Discovery].

    {!Discovery} re-exports {!model_info}, {!server_props}, and
    {!slot_status} as transparent record aliases so existing imports
    of [Discovery.model_info] etc. continue to type-check and continue
    to pattern-match against record literals.

    Pure module: no I/O, no env reads, no async. *)

(** Model info from [/v1/models]. *)
type model_info =
  { id : string
  ; owned_by : string
  }

(** Server properties from [/props]. *)
type server_props =
  { total_slots : int
  ; ctx_size : int
  ; model : string
  }

(** Slot utilization from [/slots]. *)
type slot_status =
  { total : int
  ; busy : int
  ; idle : int
  }

(** OpenAI-compatible [/v1/models] response → list of [{ id; owned_by }].
    Empty [data] is valid. Missing fields, wrong types, blank identifiers, and
    malformed entries return an explicit schema error; entries are never
    silently dropped. *)
val parse_models : Yojson.Safe.t -> (model_info list, string) result

(** llama-server [/props] response → typed {!server_props}. Required fields
    must have their declared types and positive numeric values. *)
val parse_props : Yojson.Safe.t -> (server_props, string) result

(** llama-server [/slots] response → typed {!slot_status}. Each slot must
    declare a boolean [is_processing]; malformed entries are explicit schema
    errors. *)
val parse_slots : Yojson.Safe.t -> (slot_status, string) result
