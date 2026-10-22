(** Host-owned evidence for one actual ordered HTTP/CLI exact-output walk.
    This is not worker wire, execution authority, or a Memory disposition. *)
type t
type http

type cli_result = Not_reached | Prompt_unavailable | Answered of string | Exhausted

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
    [excluded_http] preserves preflight/structural exclusions; any exclusion or
    declared CLI tail disqualifies API-only unread proof. The caller's original
    envelope separately binds physical ownership, request/schema and attempt. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Sole strict current format. Closed normalized causes are classified again;
    unknown/missing/extra or internally inconsistent evidence refuses. Physical
    host receipt authority and original request binding belong to the caller. *)

val failure_evidence : t -> Keeper_exact_walk_failure.t
val generation_dispatch : t -> Agent_core.Exact_output.generation_dispatch_fact
(** HTTP generation only. Measurement and official-client dispatch remain
    separate observations, not provider acceptance/billing evidence. *)
val exhausted_input_refusals : t -> Keeper_librarian_input_refusal.t list option
(** Derived nonempty named causes only for an exhausted, fully visited,
    actually dispatched API-only walk without semantic/invalid/local veto. *)

val answered_slot : t -> string option
(** [Some slot] only for a transport accepted by the original host walk;
    [None] for exhausted, unavailable or locally stopped walks. *)
