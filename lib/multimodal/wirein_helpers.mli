(** Wirein_helpers — pure helpers for the Tier K1 keeper post-turn
    multimodal wire-in.

    Cycle 27 / Tier K1.

    {1 What this module does}

    Provides three functions used by [Keeper_post_turn]:

    - {!masc_multimodal_enabled} — env flag gate.
    - {!extract_raw_artifacts} — pull raw artifact JSON from a
      [working_context] bag.
    - {!upsert_workspace_meta} — record a workspace summary into
      the OAS Checkpoint working_context.

    The wire-in body lives directly inside [Keeper_post_turn] (see
    [apply_multimodal_wirein] there) so we mirror the A5/A6 layout.
    These helpers are pure and unit-testable without dragging the
    full [masc_mcp] library into the test closure.

    {1 Convention for raw artifact extraction}

    The keeper agent loop signals "I produced an artifact this
    turn" by appending a JSON object to a [`List] under the
    ["multimodal_artifacts"] key of [working_context]. Each entry
    has the same shape as
    {!Multimodal_keeper_bridge.raw_artifact}:

    {[
      {
        "id": "<uuid v7 string>",
        "kind_hint": "code" | "image" | "audio" | "doc",
        "payload_json": <opaque>,
        "metadata": <opaque>
      }
    ]}

    The wire-in consumes (and removes) these entries each turn so
    they are not double-counted. *)

val masc_multimodal_enabled : unit -> bool
(** [true] iff [MASC_MULTIMODAL] is set to one of ["1"], ["true"],
    ["yes"], or ["on"]. Default ([false]) keeps the wire-in inert. *)

val extract_raw_artifacts :
  Yojson.Safe.t option ->
  Multimodal_keeper_bridge.raw_artifact list * Yojson.Safe.t option
(** [extract_raw_artifacts wc] returns
    [(raws, wc_without_multimodal_key)]:

    - [raws] = parsed [raw_artifact] values from
      [wc.multimodal_artifacts]. Malformed entries are silently
      skipped; the function never raises.
    - [wc_without_multimodal_key] = the same working_context with
      the consumed key dropped (so the next turn does not
      re-process them).

    [wc = None] or non-[`Assoc] payload → [([], wc)]. *)

val upsert_workspace_meta :
  Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
(** [upsert_workspace_meta wc meta] stores [meta] under the
    ["workspace_meta"] key of an [`Assoc] working_context. Same
    semantics as
    {!Autonomous.Wirein_helpers.upsert_autonomous_meta} for the
    autonomous_meta key. *)
