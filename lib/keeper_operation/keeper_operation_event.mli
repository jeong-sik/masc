(** Closed typed families admitted to the MASC Keeper operation journal. *)

type t =
  | Compaction of Keeper_compaction_operation.event
