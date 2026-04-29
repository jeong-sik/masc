(** Multimodal artifact dashboard HTTP surface.

    Cycle 27 / Tier D1. Operator-facing read-only view over the
    multimodal workspace.

    {1 Routes}

    {v
      GET /api/v1/multimodal/list                — all artifacts
      GET /api/v1/multimodal/get/<id>            — single artifact
      GET /api/v1/multimodal/provenance/<id>     — DAG neighbors
    v}

    {1 Workspace source}

    The handler reads the live workspace via a getter callback
    registered through {!bind_workspace_getter}. Until the keeper
    integration follow-up lands, the default getter returns
    [Multimodal.Workspace.empty] — endpoints respond with empty
    lists, but the surface is exposed.

    {1 Why a separate module}

    [Server_routes_http_routes_artifacts] (existing) handles the
    Tool blob store under [/api/v1/artifacts/<sha256>]. Despite
    the path token "artifacts" overlap, the two are different
    concepts (sha-keyed blob vs id-keyed multimodal). This module
    namespaces under [/api/v1/multimodal/] to avoid path conflicts. *)

val bind_workspace_getter :
  (unit -> Multimodal.Workspace.t) -> unit
(** Override the default workspace getter. Called by the keeper
    integration follow-up to wire keeper-side state into the
    HTTP surface. *)

val list_response : unit -> Yojson.Safe.t
(** [{ "count": n, "artifacts": [...] }] envelope listing
    every artifact currently in the workspace. *)

val artifact_response :
  id_str:string -> Yojson.Safe.t * Httpun.Status.t
(** Single-artifact lookup by string id.
    - Malformed id → 400 [{error}]
    - Not found → 404 [{error, id}]
    - Found → 200 [{...artifact JSON...}]. *)

val provenance_response :
  id_str:string -> Yojson.Safe.t * Httpun.Status.t
(** Provenance neighbors:
    [{ id, origins: [aid...], descendants: [aid...] }].
    Returns empty arrays if the id is unknown to the workspace. *)

val add_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register the three GET routes under
    [/api/v1/multimodal/]. Returns the augmented router. *)
