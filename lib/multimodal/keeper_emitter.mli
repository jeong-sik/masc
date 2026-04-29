(** Keeper-side emission API for multimodal artifacts.

    Cycle 27 / Tier K2 — the producer-side counterpart of the K1
    consumer wire-in.

    {1 What this module is}

    A single typed function {!emit} that appends a [raw_artifact]
    JSON entry to [working_context["multimodal_artifacts"]]. The
    K1 keeper post-turn wire-in
    ({!Wirein_helpers.extract_raw_artifacts}) consumes (and
    removes) the list each turn, so this is a write-then-flush
    contract — every emission is observed at most once.

    {1 Why a typed API rather than free-form JSON}

    Three reasons:

    + The keeper agent's prompt layer should not encode the raw
      JSON shape — that contract belongs in OCaml, where ppx_tla
      keeps {!Artifact.kind_tag} and the emitter in lockstep.
    + Tests can exercise the producer side without instantiating
      a full keeper agent ({!emit} is pure).
    + A single definition lets us add invariants (e.g. id
      uniqueness check, payload size cap) here rather than in
      every caller.

    {1 RFC-0002 compliance}

    This module lives in [lib/multimodal/] and does not import
    [lib/keeper]. Keeper-side callers (hooks, prompts, tool
    interceptors) thread their [working_context] through {!emit}
    and use the returned value. *)

val emit :
  working_context:Yojson.Safe.t option ->
  id:string ->
  kind_tag:Artifact.kind_tag ->
  payload_json:Yojson.Safe.t ->
  metadata:Yojson.Safe.t ->
  Yojson.Safe.t option
(** [emit ~working_context ~id ~kind_tag ~payload_json ~metadata]
    returns a working_context with the new entry appended to the
    [multimodal_artifacts] list. The list is created if absent.
    Other [`Assoc] keys are preserved.

    The [kind_tag] is rendered to its canonical lowercase string
    (["code"], ["image"], ["audio"], ["doc"]) so the K1 wire-in's
    {!Multimodal_keeper_bridge.parse_kind_hint} round-trips
    cleanly. *)

val emit_many :
  working_context:Yojson.Safe.t option ->
  (string * Artifact.kind_tag * Yojson.Safe.t * Yojson.Safe.t) list ->
  Yojson.Safe.t option
(** [emit_many ~working_context entries] is the bulk variant. Each
    [(id, kind_tag, payload_json, metadata)] tuple is appended in
    order. Equivalent to a left fold of {!emit} over [entries]. *)
