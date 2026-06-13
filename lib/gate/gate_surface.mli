(** Gate_surface — typed connector surface identity (RFC-0223 §3).

    A surface is one lane a keeper can hear from or speak to: the
    dashboard, a bound Discord/Slack channel, or any other connector
    speaking the generic gate protocol. The type round-trips to the
    on-disk [source] labels written by {!Keeper_chat_store.append_turn}
    producers ("dashboard" / "discord" / "slack" / connector channel
    labels).

    RFC names this module [Surface]; the [Gate_] prefix follows the
    masc_gate convention ([(wrapped false)] puts modules in the global
    namespace, so a bare [Surface] is too generic). *)

type t =
  | Dashboard
  | Discord of { workspace_id : string option; channel_id : string option }
  | Slack of { workspace_id : string option; channel_id : string option }
  | Gate of { channel : string; channel_id : string option }
      (** Any other connector speaking the generic gate protocol;
          [channel] is the connector's registered label, verbatim.
          [workspace_id]/[channel_id] are [option] because chat rows
          persist only the [source] label today — a row-derived
          surface knows its lane label but not always the lane id. *)

val label : t -> string
(** Round-trips to today's on-disk [source] strings: ["dashboard"],
    ["discord"], ["slack"], or the gate channel label verbatim. *)

val of_source :
  source:string -> workspace_id:string option -> channel_id:string option -> t
(** Parse a persisted [source] label. Unknown labels map to
    [Gate { channel = source; _ }] — the honest reading (every
    non-builtin source IS a gate channel label), not a permissive
    default. *)

(** {1 Presence (RFC-0223 P2)} *)

type surface_presence = { surface : t; alive : bool }

val connected_surfaces_for_keeper :
  keeper_name:string -> surface_presence list
(** Surfaces currently attached to [keeper_name], recomputed from the
    connector registry's binding stores and liveness sources on every
    call — no cached presence state (RFC-0223 §2 principle 6).

    The dashboard is always present and alive (the bearer-gated chat
    route always exists; no per-keeper dashboard attachment is
    tracked). Connector entries come from
    {!Channel_gate_connector.all}, so only connectors registered in
    this process (server startup) are visible. Sorted for stable
    prompt rendering. *)
