(** Surface_ref — the shared typed surface vocabulary (RFC-0232 §3.6).

    One immutable value names the surface a lane event came from or
    goes to: the dashboard, a Discord/Slack coordinate, a webhook,
    the keeper's own agent-initiated path, or
    any other connector speaking the generic gate protocol.  Extracted
    from [Keeper_external_attention.surface_ref] (which re-exports it
    unchanged) so the lane ({!Keeper_chat_store}), the attention store,
    and the gate recorder speak the same closed type instead of open
    [source] strings.

    Values are pure immutable data — no mutable fields, no hidden
    state; [equal]/[compare] are structural.  Construction is direct
    (the variants are the API); the only derivations live here:
    {!lane_label} (the legacy on-disk label) and the total JSON codec. *)

type t =
  | Dashboard of { session_id : string option }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
    }
  | Webhook of { source : string; event_id : string }
  | Agent
      (** Keeper/agent-initiated lane traffic with no external surface
          (the [masc_keeper_msg] direct path) — previously the open
          string label ["agent"]. *)
  | Gate of { label : string; address : (string * string) list }

val equal : t -> t -> bool
val compare : t -> t -> int

val lane_label : t -> string
(** The legacy [source] label this surface writes on a lane row:
    ["dashboard"] / ["discord"] / ["slack"] / ["webhook"]
    / ["agent"] / the gate channel label verbatim.  The single
    derivation site — writers no longer invent label strings. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Total decode: unknown [kind] labels are an [Error], never a
    default. *)
