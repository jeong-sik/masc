(** Immutable LLM decisions over {!Keeper_compaction_unit.partition}. *)

type t

type decode_error =
  | Expected_object
  | Missing_field of string
  | Duplicate_field of string
  | Expected_array of string
  | Expected_integer of string
  | Expected_string of string
  | Unknown_field of string
  | Blank_summary of int
  | Index_out_of_range of
      { index : int
      ; unit_count : int
      }
  | Duplicate_decision of int
  | Missing_decision of int
  | No_compaction
[@@deriving show]

val input_json
  :  Keeper_compaction_unit.partition
  -> Yojson.Safe.t
(** Canonical closed-prefix units supplied to the LLM. The protected suffix is
    deliberately absent. *)

val decode
  :  source:Keeper_compaction_unit.partition
  -> Yojson.Safe.t
  -> (t, decode_error) result
(** Bind exactly one keep, summarize, or drop decision to every source unit. *)

val apply : t -> Agent_sdk.Types.message list
(** Rebuild units chronologically and append the protected suffix exact. *)

type observation =
  { summarized_units : int
  ; summarized_source_messages : int
  ; emitted_summary_messages : int
  ; dropped_units : int
  ; dropped_source_messages : int
  }

val observation : t -> observation
