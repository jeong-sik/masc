(** Host-owned evidence for one actual ordered HTTP/CLI exact-output walk.
    This is not worker wire, execution authority, or a Memory disposition. *)
type t
type http
type visit = private { ordinal:int; candidate_id:string }
type response_family = Responses_codec | Other_codec
(** [Other_codec] combines every non-Responses HTTP codec. *)
type observed_status = Queued | In_progress | Completed | Failed | Incomplete | Cancelled
  | Other_digest of string
type lifecycle = Observed_status of observed_status | Ambiguous_envelope | Unreadable_json
type response_observation = private { visit:visit; call_id:string; family:response_family;
  http_status:int option; body_sha256:string option; lifecycle:lifecycle option }

val response_observations : t -> response_observation list option
(** [None] is a version 1 receipt without these observations. [Some] is the
    version 2 attempt-ordered list, including attempts with no response. *)

type cli_result = Not_reached | Prompt_unavailable | Answered of string | Exhausted
  | Stopped_before_dispatch of string
      (** The walk stopped just before sending to this declared slot. It was
          visited and not dispatched, and no later slot was visited. *)

type cli
val cli : visited:string list -> dispatched:string list -> failures:Keeper_lane_cli_oneshot.failure list ->
  result:cli_result -> cli
(** Preserve the actual visited prefix separately from configured declarations:
    the existing walker can demote quota-bound candidates between visits.
    Dispatch observations are an ordered subsequence; unresolved/non-official
    visits fail without dispatch. Every failed predecessor remains before the
    successful visit. No remote effect is inferred. *)

val http_not_started : detail:string -> http
val http_success : ('accepted, 'rejection) Agent_core.Exact_output.validated_flow_success ->
  rejection_to_string:('rejection -> string) -> http
val http_failure :
  callback_error_to_string:('callback_error -> string) ->
  rejection_to_string:('rejection -> string) ->
  ('callback_error, 'rejection) Agent_core.Exact_output.validated_flow_error -> http
(** Capture real immutable flow, generation, measurement and semantic evidence.
    Diagnostic renderers never determine policy. *)

val make : declared_http:string list -> excluded_http:string list ->
  declared_cli:string list -> http:http -> cli:cli -> (t, string) result
(** The complete original effective declarations, not current configuration.
    [excluded_http] preserves the declared slots no flow saw: held ones and
    ones left out for a size refusal on record; any exclusion or
    declared CLI tail disqualifies API-only unread proof. The caller's original
    envelope separately binds physical ownership, request/schema and attempt. *)

val make_v2 : declared_http:string list -> excluded_http:string list ->
  declared_cli:string list -> http:http -> cli:cli -> (t, string) result
(** As [make], with same-attempt HTTP status, completed response-body digest
    and Responses lifecycle observations captured in the version 2 receipt.
    Missing observations stay missing; they do not establish remote completion.
    An unrecognized status is stored as a digest of its normalized wire value. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict version 1 and version 2 receipt formats. Version 1 retains its
    canonical encoding and meaning. Closed normalized causes are classified again;
    unknown/missing/extra or internally inconsistent evidence refuses. Physical
    host receipt authority and original request binding belong to the caller. *)

val failure_evidence : t -> Keeper_exact_walk_failure.t
val generation_dispatch : t -> Agent_core.Exact_output.generation_dispatch_fact
(** HTTP generation only. Measurement and official-client dispatch remain
    separate observations, not provider acceptance/billing evidence. *)
val exhausted_input_refusals : t -> Keeper_librarian_input_refusal.t list option
(** Derived nonempty named causes only for an exhausted, fully visited,
    actually dispatched API-only walk without semantic/invalid/local veto. *)

type http_slot = { slot_id:string; target_fingerprint:string }
(** One HTTP slot as a walk bound it: its id and the
    [Exact_output.target_identity_fingerprint] of the target it named. *)

type http_slot_answer = Input_size_refused | Other_answer

val http_slot_answers : t -> (http_slot * http_slot_answer) list
(** What the provider behind each HTTP slot said to the generation request
    this walk sent it. [Input_size_refused] is a sent request the provider
    refused for its size, the observations
    {!Keeper_exact_walk_failure.of_api_observation} gives a named input
    refusal. [Other_answer] is any other sent request, answered or failed.
    A slot this walk sent nothing to is absent: excluded, not reached,
    rejected locally, or failed before its dispatch. A walk the host
    completed lists a slot once; a reader that needs one answer per slot
    takes the first (RFC-exact-request-skips-a-slot-that-refused-its-input
    3.2). *)

val answered_slot : t -> string option
(** [Some slot] only for a transport accepted by the original host walk;
    [None] for exhausted, unavailable or locally stopped walks. *)
