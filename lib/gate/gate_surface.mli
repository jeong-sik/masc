(** Gate_surface — typed connector surface identity (RFC-0223 §3).

    A surface is one lane a keeper can hear from or speak to: the
    dashboard, a bound Discord/Slack channel, or any other connector
    speaking the generic gate protocol. Presence is derived from the current
    connector registry, not from persisted chat labels.

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
          [workspace_id]/[channel_id] are [option] because a connector
          registry may expose only the lane label. *)

val label : t -> string
(** Current connector label: ["dashboard"], ["discord"], ["slack"], or the
    generic gate channel label verbatim. *)

(** {1 Presence (RFC-0223 P2)} *)

type surface_presence = { surface : t; alive : bool }

type presence_failure =
  { connector_id : string
  ; error : Channel_gate_binding_store.binding_store_error
  }

type presence_snapshot =
  { surfaces : surface_presence list
  ; failures : presence_failure list
  }

val connected_surfaces_for_keeper :
  keeper_name:string -> presence_snapshot
(** Surfaces currently attached to [keeper_name], recomputed from the
    connector registry's binding stores and liveness sources on every
    call — no cached presence state (RFC-0223 §2 principle 6).

    The dashboard is always present and alive (the bearer-gated chat
    route always exists; no per-keeper dashboard attachment is
    tracked). A failed binding-store read is retained in [failures] while
    healthy connector surfaces remain available; it is never projected as an
    empty binding list. Connector entries come from
    {!Channel_gate_connector.all}, so only connectors registered in
    this process (server startup) are visible. Sorted for stable
    prompt rendering. *)
