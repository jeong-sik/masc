(** Cascade_error_classify — SDK error parser, substring classifier, and the
    {!admission_wait_timeout_error} construction helper.

    RFC-0142 Phase 2 PR-1: the [masc_internal_error] ADT, its JSON codec, the
    Prometheus accounting, and the per-variant kind/cascade_name labels live in
    {!Cascade_internal_error}.  This module [include]s that surface so callers
    that reference [Cascade_error_classify.masc_internal_error],
    [Cascade_error_classify.Cascade_exhausted], etc. continue to compile
    unchanged.

    @since God file decomposition *)

(** {1 Re-exported [masc_internal_error] surface} *)

include module type of Cascade_internal_error

(** {1 Construction helpers} *)

val admission_wait_timeout_error :
  keeper_name:string ->
  cascade_name:Cascade_name.t ->
  priority:Llm_provider.Request_priority.t ->
  int ->
  (string, Agent_sdk.Error.sdk_error) result
(** Build an [Admission_queue_timeout] error from a wait duration in ms. *)

(** {1 Parsers} *)

val classify_masc_internal_error :
  Agent_sdk.Error.sdk_error -> masc_internal_error option
(** Parse an SDK error back into a [masc_internal_error] when it was
    originally produced by {!sdk_error_of_masc_internal_error}.  Returns
    [None] for errors that do not carry the [masc_oas_error] prefix. *)

val classify_masc_internal_error_of_string :
  string -> masc_internal_error option
(** Parse a [masc_internal_error] from a raw string that may contain
    the [[masc_oas_error]] prefix anywhere (e.g. in a blocker text with
    "Internal error: [masc_oas_error] ..." wrapper).  Returns [None]
    when the prefix is absent or the JSON payload is malformed. *)

val sdk_error_is_server_rejected_parse_error :
  Agent_sdk.Error.sdk_error -> bool
(** [true] when the provider rejected the request body before processing it
    because the JSON/request payload could not be parsed. *)
