(* RFC-0044 PR-1: closed sum type for persistence read-drop reason.

   See [.mli] for the public contract. This file holds the type
   definition and the wire-format serialisation chosen to be
   byte-for-byte compatible with the legacy [string] constants in
   [Core.Safe_ops] as of main.

   RFC-0134 PR-1 (2026-05-19): adds [Concurrent_removal] and
   [Transient_fd_pressure] as typed surfaces for the two operational
   causes measured on 2026-05-19 (TOCTOU race between [list_dir] and
   delete-then-replace writers, and [ENFILE]/[EMFILE] FD pressure).
   PR-1 is pure additive: callers continue to use [Entry_load_error].
   PR-2 promotes [Coord_verification_store.load_request_header] to a
   typed [load_error]. PR-3 routes the new variants away from the
   data-integrity WARN/counter path. *)

type t =
  | List_dir_error
  | Entry_load_error
  | Invalid_payload
  | Json_syntax_error
  | Lock_contention
  | Schema_version_mismatch
  | Decompression_error
  | Path_normalization_error
  | Stat_error
  | Concurrent_removal (* RFC-0134 PR-1. *)
  | Transient_fd_pressure (* RFC-0134 PR-1. *)
  | Other of string

let to_wire = function
  | List_dir_error -> "list_dir_error"
  | Entry_load_error -> "entry_load_error"
  | Invalid_payload -> "invalid_payload"
  | Json_syntax_error -> "json_syntax_error"
  | Lock_contention -> "lock_contention"
  | Schema_version_mismatch -> "schema_version_mismatch"
  | Decompression_error -> "decompression_error"
  | Path_normalization_error -> "path_normalization_error"
  | Stat_error -> "stat_error"
  | Concurrent_removal -> "concurrent_removal"
  | Transient_fd_pressure -> "transient_fd_pressure"
  | Other s -> s
;;

let of_wire = function
  | "list_dir_error" -> List_dir_error
  | "entry_load_error" -> Entry_load_error
  | "invalid_payload" -> Invalid_payload
  | "json_syntax_error" -> Json_syntax_error
  | "lock_contention" -> Lock_contention
  | "schema_version_mismatch" -> Schema_version_mismatch
  | "decompression_error" -> Decompression_error
  | "path_normalization_error" -> Path_normalization_error
  | "stat_error" -> Stat_error
  | "concurrent_removal" -> Concurrent_removal
  | "transient_fd_pressure" -> Transient_fd_pressure
  | s -> Other s
;;

let equal a b =
  match a, b with
  | List_dir_error, List_dir_error
  | Entry_load_error, Entry_load_error
  | Invalid_payload, Invalid_payload
  | Json_syntax_error, Json_syntax_error
  | Lock_contention, Lock_contention
  | Schema_version_mismatch, Schema_version_mismatch
  | Decompression_error, Decompression_error
  | Path_normalization_error, Path_normalization_error
  | Stat_error, Stat_error
  | Concurrent_removal, Concurrent_removal
  | Transient_fd_pressure, Transient_fd_pressure -> true
  | Other a, Other b -> String.equal a b
  | List_dir_error, _
  | Entry_load_error, _
  | Invalid_payload, _
  | Json_syntax_error, _
  | Lock_contention, _
  | Schema_version_mismatch, _
  | Decompression_error, _
  | Path_normalization_error, _
  | Stat_error, _
  | Concurrent_removal, _
  | Transient_fd_pressure, _
  | Other _, _ -> false
;;

let pp fmt t = Format.pp_print_string fmt (to_wire t)
