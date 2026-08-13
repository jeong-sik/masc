(** Neutral runtime observation bus for agent activity.

    Producers in Keeper/Tooling emit here without depending on any UI/IDE
    storage module. Consumers register process-local sinks that translate
    these neutral records into their own persistence or streaming surfaces. *)

type codebase_partition =
  | By_url of string
      (** canonical URL 정상 resolved: host_path slug. *)
  | No_canonical_url
      (** [canonical_url_of_remote] returned None: blank [repo.url] or malformed
          remote. v2 §7 "(1) 빈 repo/remote 없음". *)
  | Unmatched
      (** Caller passed [repo_id] but the repository store could not resolve it.
          v2 §7 "(2) repo_id unmatched". *)
  | Base_unresolved
      (** [file_path] under no registered repo (unregistered worktree, outside
          playground). v2 §7 "(4) base 경로 소실" — write-path [unregistered_repo]
          is the live instance. *)
  | Legacy_default
      (** No [canonical_url]/[repo_id] supplied, or record has no [partition]
          field (tool/turn). Structural ceiling, NOT a soft fallback.
          v2 §7 "(3) default 미갱신". *)

val canonical_url_of_remote : string -> string option
(** [canonical_url_of_remote remote] normalises a git remote string into a
    deterministic host_path slug. Returns [None] for blank, malformed, or
    traversal-looking inputs. *)

module Code_address : sig
  type t
  (** A code fact's address: [(codebase, path)] where [codebase] is a
      canonical host_path slug (the partitioned store's directory name,
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
    | Unnormalized_path

  val invalid_to_string : invalid -> string

  val v : codebase:string -> path:string -> (t, invalid) result
  (** Rejects rather than repairs: the codebase must already be a
      canonical slug and the path must already be a normalized relative
      path — [.], [..], empty segments, and absolute paths are errors,
      not inputs to fix. *)

  val codebase : t -> string
  val path : t -> string
  val equal : t -> t -> bool
end

module Unattributed : sig
  (** Typed reasons a write's file path failed attribution to a codebase.

      RFC-0378 §5.1: attribution failure is a fact kind, not a store
      partition — the reason rides the fact as a queryable field.
      RFC-keeper-workspace-root-only 2a owns this vocabulary's evolution
      once attribution moves to git observation. *)

  type reason =
    | Blank_remote_url
    | Unparseable_remote_url of string
    | Unregistered_repo_id of string
    | Unregistered_path
    | Repository_catalog_unavailable

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

(** Where a fact that names a file belongs. An annotation or write region
    always names a file, so [Pathless] is unrepresentable for them. *)
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
            three incompatible shapes in one partition (masc#28582). *)
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type turn_event =
  { base_path : string
  ; turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }
(** A turn is a keeper-timeline fact by definition (RFC-0378): it can
    touch any number of codebases, so it carries no attribution — the
    per-codebase timeline is derived by joining addressed tool facts on
    [turn_id]. *)

type write_region_event =
  { base_path : string
  ; attribution : file_attribution
  ; keeper_id : string
  ; turn : int
  ; tool_call_json : Yojson.Safe.t
  }

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

type annotation_reference =
  { relation : string
  ; reference : string
  }
(** Product-neutral link carried by an annotation.  Both fields are opaque to
    the observation bus: producers choose the relation label and reference
    value, while consumers may render but must not interpret them. *)

val annotation_references_to_json : annotation_reference list -> Yojson.Safe.t

val annotation_references_of_json :
  Yojson.Safe.t -> (annotation_reference list, string) result
(** Decode a [references] array.  [`Null] means no references.  Malformed or
    blank entries are rejected explicitly instead of being dropped. *)

type annotation_request =
  { base_path : string
  ; attribution : file_attribution
  ; keeper_id : string
  ; line_start : int
  ; line_end : int
  ; kind : annotation_kind
  ; content : string
  ; goal_id : string option
  ; task_id : string option
  ; references : annotation_reference list
  }

type annotation_result =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  }

type tool_event_sink = tool_event -> unit
type turn_event_sink = turn_event -> unit
type write_region_error =
  | Write_region_sink_not_installed
  | Write_region_sink_failed

val write_region_error_to_string : write_region_error -> string

type write_region_sink = write_region_event -> (unit, write_region_error) result
type annotation_sink = annotation_request -> (annotation_result, string) result

val register_tool_event_sink : tool_event_sink -> unit
val register_turn_event_sink : turn_event_sink -> unit
val register_write_region_sink : write_region_sink -> unit
val register_annotation_sink : annotation_sink -> unit

val emit_tool_event : tool_event -> unit
val emit_turn_event : turn_event -> unit
val emit_write_region_event : write_region_event -> (unit, write_region_error) result
val emit_annotation_request : annotation_request -> (annotation_result, string) result

type snapshot

val take_snapshot : unit -> snapshot
(** Return accumulated observations and reset the accumulator atomically. *)

val peek_snapshot : unit -> snapshot
(** Return accumulated observations without resetting the accumulator. *)

val snapshot_to_json : snapshot -> Yojson.Safe.t

val reset_for_testing : unit -> unit
(** Reset sinks and accumulated observations. Intended for isolated tests only. *)
