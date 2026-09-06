(** Neutral runtime observation bus for agent activity.

    Producers in Keeper/Tooling emit here without depending on any UI/IDE
    storage module. Consumers register process-local sinks that translate
    these neutral records into their own persistence or streaming surfaces. *)

val canonical_url_of_remote : string -> string option
(** [canonical_url_of_remote remote] normalises a git remote string into a
    deterministic host_path slug. Returns [None] for blank, malformed, or
    traversal-looking inputs. *)

module Code_address : sig
  type t
  (** A code fact's address: [(codebase, path)] where [codebase] is a
      canonical host_path slug (the store's per-codebase directory name,
      {!canonical_url_of_remote} output) and [path] is the file's
      repo-root-relative path.

      RFC-0378 §5.1: the address is minted once where the write is
      attributed; consumers carry the value and never re-derive either
      half from tool input or store layout. The type is abstract so a
      raw string cannot stand in for a parsed address. *)

  type invalid =
    | Empty_codebase
    | Malformed_codebase
    | Empty_path
    | Absolute_path
    | Malformed_path
    | Unnormalized_path

  val invalid_to_string : invalid -> string

  val v : codebase:string -> path:string -> (t, invalid) result
  (** Rejects rather than repairs: the codebase must already be a
      canonical slug and the path must already be a normalized relative
      path — malformed paths (including NUL bytes), [.], [..], empty
      segments, and absolute paths are errors, not inputs to fix.

      Layering: the keeper write resolver lexically collapses dot
      segments in raw tool arguments before minting, so on that path
      these rejections guard the resolver's own invariant. Wire-facing
      callers hand user input to [v] directly; that is where the
      rejections fire as typed contract errors. *)

  val codebase : t -> string
  val path : t -> string
  val equal : t -> t -> bool

  val valid_codebase : string -> bool
  (** Whether a string is shaped like a canonical host_path slug — the
      exact acceptance [v] applies to its [codebase] argument. Read-path
      scope parsing shares this so the wire key has one validator. *)
end

module Unattributed : sig
  (** Typed reasons a write's file path failed attribution to a codebase.

      RFC-0378 §5.1: attribution failure is a fact kind, not a store
      location — the reason rides the fact as a queryable field.
      RFC-keeper-workspace-root-only 2a owns this vocabulary's evolution
      once attribution moves to git observation. *)

  type reason =
    | Blank_remote_url
    | Unparseable_remote_url of string
    | Unregistered_repo_id of string
    | Unregistered_path
    | Repository_catalog_unavailable
    | Unmintable of Code_address.invalid
        (** The repo and relative path were recovered but the address
            constructor rejected the residue — a resolver invariant
            break carried for diagnosis instead of collapsed. *)

  val reason_to_string : reason -> string
end

type addressed =
  { address : Code_address.t
  ; checkout : string option
        (** Projection metadata: which checkout the write was observed in.
            Never part of the join key. [None] until attribution measures
            it (workspace-root-only 2b). *)
  }

type unaddressed =
  { reason : Unattributed.reason
  ; attempted_path : string
        (** The path exactly as the resolver saw it — forensic identity
            for records that never joined a codebase. *)
  }

(** Where a fact that names a file belongs. A write region always names
    a file, so [Pathless] is unrepresentable for it. *)
type file_attribution =
  | Addressed of addressed
  | Unaddressed of unaddressed

(** Where any tool fact belongs: a pathless call (coordination, board,
    memory) is a keeper-timeline fact with no document — distinct from a
    failed attribution. *)
type attribution =
  | File of file_attribution
  | Pathless

type tool_event =
  { base_path : string
  ; attribution : attribution
        (** RFC-0378 §5.1: the address is minted where the write is
            attributed and carried as a parsed value. Producers must not
            hand consumers the raw tool argument — the resolver is the
            only thing that knows which root the argument was relative
            to, and a consumer re-deriving the path from [input] produced
            three incompatible shapes in one store (masc#28582). *)
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

(** A turn is a keeper-timeline fact (RFC-0378): its durable record is
    the keeper turn-records store, and the per-codebase timeline is
    derived by joining addressed tool facts on [turn_id]. The
    observation bus carries no turn events. *)

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark

val annotation_kind_to_string : annotation_kind -> string

val all_annotation_kinds : annotation_kind list
val valid_annotation_kind_strings : string list
(** The schema's enum, derived from the constructors rather than restated, so a
    new kind cannot reach the wire without appearing here. *)
val annotation_kind_of_string : string -> annotation_kind option

type tool_event_sink = tool_event -> unit

val register_tool_event_sink : tool_event_sink -> unit

val emit_tool_event : tool_event -> unit

type snapshot

val peek_snapshot : unit -> snapshot
(** Return accumulated observations without resetting the accumulator. *)

val snapshot_to_json : snapshot -> Yojson.Safe.t

val reset_for_testing : unit -> unit
(** Reset sinks and accumulated observations. Intended for isolated tests only. *)
