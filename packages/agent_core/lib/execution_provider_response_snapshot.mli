(** Canonical closed codec for the durable provider response authority.

    The authority is the response tool admission kept together with what
    admission decided about it: where each admitted ToolUse stood among the
    provider's tool calls, and which calls it refused. Recovery reads both from
    this one record, so a resumed turn seals its tool occurrences with the
    original ordinals and answers the refused calls the way the fresh turn
    would have (#30728, #32715). Nothing is re-derived from the admitted
    content, planned indices or provider call ids. *)

type admission =
  { source_map : Hooks.admitted_tool_source_map
  ; unavailable_names : string list
        (** Readable calls whose name routed to no tool, in response order. *)
  ; unreadable : Llm_provider.Types.unreadable_tool_use list
        (** Calls whose arguments were not one JSON object. *)
  }

type t =
  { response : Llm_provider.Types.api_response
        (** The admitted response. Its [unreadable_tool_uses] is empty: those
            calls live in [admission.unreadable]. *)
  ; admission : admission
  }

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** Prints the record as its wire JSON. *)
val pp : Format.formatter -> t -> unit

(** Rejects a record whose admission does not describe its response: every
    ToolUse of the response has exactly one source in planned order, source
    ordinals are distinct and inside [source_tool_use_count], unreadable calls
    hold the ordinals no admitted call holds, and the count equals admitted plus
    refused calls. Also requires an exact JSON round trip. *)
val validate : t -> (unit, string) result
