(** Persisted heartbeat freshness from the canonical Keeper metrics ledger. *)

type t =
  { timestamp : string
  ; timestamp_unix : float
  }

val latest :
  config:Workspace.config -> keeper_name:string -> (t option, string) result
(** Read the newest typed heartbeat row. Missing stores return [Ok None];
    layout and I/O failures remain explicit so health projections never
    silently switch freshness sources. *)
