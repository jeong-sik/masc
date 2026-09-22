(** Admin-only exact cleanup boundaries for Keeper-owned derived state.

    [POST /api/v1/keepers/:name/memory/retractions] accepts exactly
    [plan_id], [expected_revision], [expected_snapshot_sha256], and non-empty
    [retractions: [{memory_id, reason}]]. Success means both the replacement
    snapshot and its exact reason-bearing journal entry are durable. A failure
    after replacement returns HTTP 503 with [snapshot_committed=true] and is
    reconciled from the prepared plan receipt before the next snapshot write.
    Success returns the new revision and snapshot SHA-256 for a following exact
    plan without another inventory read.

    [POST /api/v1/keepers/:name/working-context/source-retractions] accepts
    exactly [plan_id], [expected_generation], [expected_revision],
    [expected_snapshot_sha256], and non-empty [source_references]. Success
    returns the new generation, revision, and snapshot SHA-256. *)

type target =
  | Current_memory of string
  | Working_context of string

val permission : Masc_domain.permission
val route : string -> target option

type current_memory_request =
  { plan_id : string
  ; expected_revision : int
  ; expected_snapshot_sha256 : string
  ; retractions : Keeper_memory_os_current.retraction list
  }

type working_context_request =
  { plan_id : string
  ; expected_version : Keeper_librarian_context.version
  ; expected_snapshot_sha256 : string
  ; source_references : string list
  }

val parse_current_memory_request :
  string -> (current_memory_request, string) result

val parse_working_context_request :
  string -> (working_context_request, string) result

val handle_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  target ->
  string ->
  unit
