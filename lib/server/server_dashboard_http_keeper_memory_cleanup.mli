(** Admin-only exact cleanup boundaries for Keeper-owned derived state.

    [POST /api/v1/keepers/:name/memory/retractions] accepts exactly [plan_id]
    and non-empty [retractions: [{memory_id, reason}]]. Each retraction is one
    direct write to the Keeper's Memory writer by the operator who asked, on
    the trace [plan_id], in the order of the request (RFC
    librarian-call-only-proposes §8.5). The answer lists what each one did:
    [retracted], with the facts that left Memory, or [not_current].

    The first retraction the writer does not take ends the request. The
    answer is then [ok=false] with [code=memory_unwritable], the reason in
    [unwritable], the id it stopped at, and the retractions answered before
    it, which are committed. Sending the request again answers those as
    [not_current]. The Keeper has a writer while it is in the Keeper
    registry, so a Keeper that is not running answers
    [keeper_not_registered].

    [POST /api/v1/keepers/:name/working-context/source-retractions] accepts
    exactly [plan_id], [expected_generation], [expected_revision],
    [expected_snapshot_sha256], and non-empty [source_references]. Success
    returns the new generation, revision, and snapshot SHA-256. *)

type target =
  | Current_memory of string
  | Working_context of string

val permission : Masc_domain.permission
val route : string -> target option

type retraction =
  { memory_id : string
  ; reason : string
  }

type current_memory_request =
  { plan_id : string
  ; retractions : retraction list
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

type retraction_result =
  | Retraction_committed of Librarian_log.commit
  | Retraction_not_current

type retractions_outcome =
  { answered : (retraction * retraction_result) list
  (** In the order of the request. *)
  ; stopped : (retraction * Keeper_tool_memory_validation.memory_unwritable) option
  (** The retraction the writer did not take, and why. The ones after it
      were not sent. *)
  }

(** What {!handle_post} does with a parsed Memory request. [actor] is the
    operator's name on every line it commits. *)
val retract_through_writer
  :  base_path:string
  -> keeper:string
  -> actor:string
  -> current_memory_request
  -> retractions_outcome

val handle_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Http_reqd.t ->
  target ->
  string ->
  unit
