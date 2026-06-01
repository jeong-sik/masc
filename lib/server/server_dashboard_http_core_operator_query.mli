(** Operator query metadata helpers for dashboard HTTP core. *)

val operator_retention_json :
  config:Workspace.config -> scope:string -> producer:string -> Yojson.Safe.t

val operator_snapshot_query_json :
  actor:string option ->
  view:string option ->
  include_messages:bool ->
  include_keepers:bool ->
  lightweight_summary:bool ->
  default_summary_request:bool ->
  Yojson.Safe.t

val operator_digest_query_json :
  actor:string option ->
  target_type:string option ->
  target_id:string option ->
  include_workers:bool option ->
  effective_target_type:string ->
  default_namespace_request:bool ->
  Yojson.Safe.t

val with_operator_surface_metadata :
  config:Workspace.config ->
  ?cache_key:string ->
  dashboard_surface:string ->
  source:string ->
  scope:string ->
  producer:string ->
  query:Yojson.Safe.t ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val with_operator_snapshot_metadata :
  config:Workspace.config ->
  ?cache_key:string ->
  query:Yojson.Safe.t ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val with_operator_digest_metadata :
  config:Workspace.config ->
  ?cache_key:string ->
  query:Yojson.Safe.t ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val operator_snapshot_default_query : unit -> Yojson.Safe.t

val operator_digest_default_query : unit -> Yojson.Safe.t
