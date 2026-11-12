(** Immutable projections published by source-owned server workers. Reads never
    compute or touch the filesystem. An epoch's publisher cannot replace a
    successor's values, including when both epochs use the same paths. *)

type tools_projection = private {
  base_path : string;
  workspace_path : string;
  masc_root : string;
  json : Yojson.Safe.t;
  etag : string;
  encoded : Http_response_payload.prepared;
}

type tools_result =
  | Tools_pending of Yojson.Safe.t
  | Tools_ready of Yojson.Safe.t
  | Tools_error of Yojson.Safe.t
(** Readiness from the actual tools reader, independent of empty inventories. *)

type t = private {
  generated_at : float;
  base_path : string;
  workspace_path : string;
  masc_root : string;
  shell : Yojson.Safe.t;
  shell_light : Yojson.Safe.t;
  tools : tools_projection;
  telemetry_summary : Yojson.Safe.t;
}

type publisher

val activate : config:Workspace.config -> publisher
(** Install an empty publisher for one captured workspace epoch. *)

val retire : publisher -> unit
(** Clear only this publisher; a successor keeps its current values. *)

val publish_shell : publisher -> shell:Yojson.Safe.t -> shell_light:Yojson.Safe.t -> unit
val publish_tools : publisher -> Yojson.Safe.t -> unit
val publish_telemetry : publisher -> Yojson.Safe.t -> unit
(** Install successful immutable component values. The complete snapshot becomes
    available after all three components have succeeded. Later component writes
    retain the others. Tools JSON, ETag and encoded bytes are prepared together
    on the caller's worker. A retired publisher can update only its own cell. *)

val current : unit -> t option
val current_for_config : Workspace.config -> t option
(** Constant-time atomic reads. [current_for_config] also requires the exact
    published base/workspace/MASC-root scope, without filesystem resolution. *)

val public_activity_events : Workspace.config -> Yojson.Safe.t
(** Shared public events projection. Every hit revalidates its Public parent
    proof. Invoke on a worker. *)

val invalidate_public_activity_events : base_path:string -> unit
(** Drop this workspace's retained public window before source publication. *)

val publish_for_test : t -> unit
val make_for_test :
  config:Workspace.config -> shell:Yojson.Safe.t ->
  ?shell_light:Yojson.Safe.t -> tools:Yojson.Safe.t ->
  telemetry_summary:Yojson.Safe.t -> unit -> t
val reset_for_test : unit -> unit

module For_testing : sig
  type activity_cache
  val make_activity_cache : unit -> activity_cache
  val refresh_activity_events :
    config:Workspace.config -> now:(unit -> float) -> ttl:float ->
    cache:activity_cache ->
    (keep:(Activity_graph.event -> bool) -> Yojson.Safe.t) -> Yojson.Safe.t
end
