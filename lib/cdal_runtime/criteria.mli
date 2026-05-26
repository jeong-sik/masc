(** Typed CDAL eval criteria — RFC-0109 Phase A.

    Replaces the opaque [Yojson.Safe.t] passthrough in [Risk_contract.eval_criteria]
    with a closed sum type that enumerates the concrete producer shapes observed
    in the codebase (inventory taken 2026-05-26):

    - [Keeper_turn_capture_v1] — built by [Keeper.Keeper_cdal_contract.of_keeper_meta].
    - [Contract_catalog_invariants] — built by [Masc_contract_catalog.eval_criteria].
      The [Jsonl_writer_contract_fixture.eval_criteria] orphan still emits the
      raw JSON shape (leaf sub-lib without cdal_runtime dependency) and is
      auto-routed by [of_yojson]'s required-field detection.
    - [Verification_request] — RFC-0109 Phase B prereq (no current producer).
    - [Persona_probe] — speculative, deferred.
    - [Free] — migration escape; callers MUST attach a TODO + target RFC link
      (linted by [scripts/pr-rfc-check.sh] §10 — added by RFC-0109).

    Wire format is JSON-compatible with the legacy opaque shape. Decoding
    accepts both new tagged form ({"criteria_kind":"..."}) and any legacy
    [Assoc] payload (auto-routed to the matching variant when [kind] is
    recognized; falls back to [Free] otherwise).

    Type fidelity note (cdal_runtime independence): this sub-library does
    not depend on [Keeper_types]. Fields whose source type lives in the
    main [masc_mcp] library (e.g. [tool_access], [Task_id]) are carried as
    their JSON projection (string or [Yojson.Safe.t]). Consumers that need
    structured semantics call back into [Keeper_types.*_of_meta_json].

    @since RFC-0109 Phase A *)

(** Tool access JSON projection. Opaque to this module — kept as JSON to
    avoid pulling [Keeper_types.tool_access] into [cdal_runtime]. *)
type tool_access_json = Yojson.Safe.t

(** Goal reference for verification-aware variants. [goal_title] is a
    witness for log lines and is NOT load-bearing for routing. *)
type goal_ref =
  { goal_id : string
  ; goal_title : string
  }

(** Typed criteria. *)
type t =
  | Keeper_turn_capture_v1 of
      { keeper_name : string
      ; agent_name : string
      ; sandbox_profile : string
      ; sandbox_image : string option
      ; network_mode : string
      ; tool_access : tool_access_json
      ; tool_denylist : string list
      ; allowed_paths : string list
      ; active_goal_ids : string list
      ; current_task_id : string option
      }
  | Contract_catalog_invariants of
      { contract_name : string
      ; description : string
      ; invariants : string list
      }
  | Verification_request of
      { goal_id : string
      ; request_id : string
      }
  | Persona_probe of
      { persona_id : string
      ; trace_id : string
      }
  | Free of Yojson.Safe.t
    (** Migration escape. Callers MUST add an inline comment with the form
        [(* TODO RFC-NNNN: migrate to typed variant *)] next to construction.
        The PR lint guard (scripts/pr-rfc-check.sh §10) rejects new uses
        without such a comment. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** Tag used as the discriminator in the JSON encoding for the typed
    variants. Free is encoded as its inner payload (no tag) for
    backward-compatibility with legacy opaque eval_criteria. *)
val criteria_kind : t -> string

val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
