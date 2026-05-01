open Base

(** Tool_input_validation — pre-dispatch input validation hook.

    Registers a {!Tool_dispatch.register_pre_hook} that runs the
    OAS [Tool_middleware.make_validation_hook] over every incoming
    tool call.  Two MASC-specific responsibilities layered on top
    of the generic OAS hook:

    1. [masc_transition] arg normalisation — accepts a wide set of
       human-friendly aliases for the [action] / [to] field
       ([claim/claimed], [start/started/in_progress], etc.) and
       canonicalises them before validation.
    2. Missing-required-field hint augmentation — when OAS reports
       [`"<field>": MISSING (required: ...)`], surface the closest
       similarly-named key from the actual args so the next turn
       can self-correct in one shot (#9785).

    @since 2.220.0 — OAS delegation
    @since 2.221.0 — use Tool_middleware.make_validation_hook *)

val augment_missing_param_hint :
  args:Yojson.Safe.t -> string -> string
(** [augment_missing_param_hint ~args oas_message] returns
    [oas_message] augmented with a [Did you mean:] block listing
    suggestions when the OAS message reports a missing required
    field that has a similarly-named key in [args].

    {2 Similarity scoring}

    | Condition | Score |
    |---|---|
    | Exact match (case-insensitive) | 1.0 |
    | One contains the other (e.g. [name ⊂ tool_name]) | 0.8 |
    | otherwise | {!Text_similarity.jaccard_similarity} |

    Only suggestions with score [>= 0.4] are listed.  The
    threshold is operator-tunable only by code change — pinning at
    the contract seam so a future "be more lenient" PR must touch
    this explicitly.

    {2 Output format}

    When at least one suggestion exists, the message is suffixed
    with:
    {[
      <oas_message>

      Did you mean:
        hint: you sent "<closest>"; rename it to "<missing>"
        ...
    ]}

    The literal [Did you mean:] header and [hint: you sent ...; rename it to ...]
    line format are pinned — the LLM is expected to match this
    pattern when self-correcting.

    Pure transformation — no side effects, can be called outside
    the validation hook (e.g. tests).  Exposed for unit testing
    via {!test_tool_input_validation}. *)

val register_pre_hook : unit -> unit
(** [register_pre_hook ()] installs the validation hook on
    {!Tool_dispatch}.

    {b Must be called after} all tool schemas are registered
    (server init, post-{!Tool_dispatch.register_schema} sweeps).
    Tools without a registered schema are allowed through
    permissively — the absence of a schema is treated as "no
    validation requested", not "reject by default".

    {2 Hook behaviour}

    For each [(name, args)] tool call:

    1. Strip internal marker args (keys starting with [_]).
    2. If [name = "masc_transition"], normalise [action] / [to] /
       [note] aliases via {!normalize_transition_args} (private).
    3. Run the OAS validation hook on the (possibly-modified)
       args.

    Result mapping:

    | OAS verdict | MASC pre-hook action |
    |---|---|
    | [Pass], args unchanged | [Pass] |
    | [Pass], args coerced by aliasing | [Proceed coerced] (info-logged) |
    | [Proceed coerced] | [Proceed coerced] (info-logged) |
    | [Reject { message; _ }] | [Reject { ...; data = augmented }] (info-logged) |

    On reject, the [data] payload is:
    {[
      `Assoc [
        ("error", `String <augmented_message>);
        ("validation", `String "oas_tool_middleware");
      ]
    ]}
    The [validation: "oas_tool_middleware"] string is operator-
    visible — runbooks key off it to distinguish OAS-rejected
    calls from other failure modes.  [duration_ms] is always
    [0.0] because validation rejection precedes the dispatch
    timing instrumentation. *)
