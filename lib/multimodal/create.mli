(** Create — factory constructors for {!Artifact.t} values.

    Cycle 24-25 / Tier A7 (first half).

    {1 What this module is}

    Convenience constructors for the four artifact kinds, plus
    payload-shape shortcuts. Each kind has a dedicated factory
    that narrows the phantom witness on the returned
    {!Artifact.t}, so handlers downstream can take advantage of
    compile-time kind discrimination without manually
    constructing the record.

    Tier A7's second half (workspace + dashboard route) builds
    on this module to register artifacts into the {!Workspace}
    registry; the dashboard `/api/v1/artifacts/*` route lands
    in a subsequent PR.

    {1 Provenance defaults}

    Every constructor accepts an optional [?origins] list and a
    required [~created_by] / [~created_at] pair. When [origins]
    is omitted, the artifact is treated as the start of a new
    creation chain (no predecessors) and {!Provenance_stub.empty}
    is used.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Code artifact} *)

val create_code :
  id:Shared_types.Artifact_id.t ->
  payload:Payload.t ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  Artifact.code Artifact.t

(** {1 Image artifact} *)

val create_image :
  id:Shared_types.Artifact_id.t ->
  payload:Payload.t ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  Artifact.image Artifact.t

(** {1 Audio artifact} *)

val create_audio :
  id:Shared_types.Artifact_id.t ->
  payload:Payload.t ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  Artifact.audio Artifact.t

(** {1 Doc artifact} *)

val create_doc :
  id:Shared_types.Artifact_id.t ->
  payload:Payload.t ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  Artifact.doc Artifact.t

(** {1 Payload-shape shortcuts}

    Each shortcut wraps a payload constructor + the kind factory
    above so callers do not need to manually construct
    {!Payload.t}. *)

val create_with_blob_ref :
  kind:'a Artifact.kind ->
  id:Shared_types.Artifact_id.t ->
  blob_ref:string ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  'a Artifact.t

val create_with_streaming :
  kind:'a Artifact.kind ->
  id:Shared_types.Artifact_id.t ->
  bytes_so_far:int ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  'a Artifact.t

val create_with_lazy_payload :
  kind:'a Artifact.kind ->
  id:Shared_types.Artifact_id.t ->
  thunk:(unit -> string) ->
  ?metadata:Yojson.Safe.t ->
  ?origins:Shared_types.Artifact_id.t list ->
  created_by:string ->
  created_at:float ->
  unit ->
  'a Artifact.t
