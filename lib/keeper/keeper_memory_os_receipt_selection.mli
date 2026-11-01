(** Pure selection of decoded Librarian consumption receipts. Snapshot durability,
    unread archival, quarantine, file replacement and cache publication belong to
    [Keeper_memory_os_current]. This module performs none of those effects. *)
open Keeper_memory_os_current_types

type snapshot_evidence = int * string Lazy.t
(** Observed revision and the caller's existing shared lazy digest. Selection
    neither hashes bytes nor confirms that a prepared snapshot is durable. *)

type range_key = string * [ `Atom | `Official | `Explicit_candidate of string ]

val range_key : consumed_range -> range_key
(** Coarse scope/kind/request identity shared with receipt upsert. This is not
    exact consumed-range equality and must not decide unproven exclusion. *)

type decision =
  | Keep of durable_range_receipt list
  | Remove
  | Rewrite of durable_range_receipt list

type t = private
  { all_verified_for_archive : durable_range_receipt list
  ; unproven : (int * durable_range_receipt) list
  ; decision : decision
  }
(** All verified receipts are retained for archival, including promoted prepared
    receipts and duplicates with distinct unread evidence. [unproven] retains
    original receipts and zero-based decoded-list positions; raw decoder-skipped
    positions belong to the caller. Serialize these entries only after archival.

    Apply [decision] only after archiving every verified receipt and completing
    both quarantines. [Keep []] preserves the no-change empty-input case. *)

val select :
  snapshot:snapshot_evidence option ->
  had_skipped_entries:bool ->
  durable_range_receipt list -> t
(** Prepared receipts require the exact observed revision/digest; committed
    receipts also survive a higher observed revision. The caller confirms any
    matching prepared snapshot's durability before applying this plan.

    Exclude an unproven receipt only when a verified receipt has the exact same
    consumed range. Retention deduplicates by [range_key], keeping first input
    occurrence and original order. The shared lazy digest is forced only for
    revision equality; it must remain local to the caller's serialized pass. *)
