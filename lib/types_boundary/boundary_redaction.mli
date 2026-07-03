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
val runtime_model_label : public_label

val to_string : public_label -> string

(** Redacted lane label ["runtime"] for external observability metric labels
    ([model] / [model_used]). SSOT consolidating the previously-duplicated
    [to_string runtime_model_label] expression at five keeper emit sites
    (RFC-0132 §3). *)
val runtime_lane_label : string
