(** Boundary redaction SSOT.

    External-surface emit sites (dashboard telemetry, OAS boundary,
    operator log) must redact provider/model identity to a small set
    of [public_label] values. The [private string] type prevents
    callers from constructing arbitrary labels — the only labels are
    the constructors exposed below.

    Internal observability paths (real provider tracking, internal
    metrics) MUST NOT use this module — they should emit the real
    string. RFC-0132 §3 enumerates the boundary classification.

    Adding a new public label requires both: a new constructor here,
    and a row in RFC-0132 §3 explaining the surface that emits it. *)

type public_label = private string

val runtime_provider_label : public_label
(** Redaction label for provider fields at external boundaries.
    It intentionally serializes to the same public lane as
    [runtime_model_label], while preserving the source field's meaning at
    call sites. *)

val runtime_model_label : public_label
(** Redaction label for model fields at external boundaries.
    It intentionally serializes to the same public lane as
    [runtime_provider_label], while preserving the source field's meaning at
    call sites. *)

val to_string : public_label -> string

(** Redacted lane label for external observability metric labels
    ([model] / [model_used]). Callers that serialize labels must use
    [to_string runtime_lane_label]. SSOT consolidating the previously-duplicated
    [to_string runtime_model_label] expression at keeper emit sites
    (RFC-0132 §3). *)
val runtime_lane_label : public_label
