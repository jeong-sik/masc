(** Safe Operations Module

    Provides safe wrappers for common operations that may fail,
    with proper error handling and logging instead of silent suppression.
*)

(** {1 Exception-Safe Wrappers} *)

val protect : default:'a -> (unit -> 'a) -> 'a
(** Run [f ()], re-raising [Eio.Cancel.Cancelled] with its original backtrace
    and returning [default] for any other exception. *)

val try_with_log : string -> (unit -> 'a) -> 'a option
(** Execute a function, logging exceptions and returning None on failure. *)

val handle : (unit -> 'a) -> (exn -> 'a) -> 'a
(** Cancel-aware exception handler.
    Re-raises [Eio.Cancel.Cancelled]; delegates other exceptions to the handler. *)

(** {1 JSON Parsing} *)

type utf8_repair_stats =
  { repaired_reads : int
  ; repaired_bytes : int
  ; path_samples : string list
  }

type utf8_repair_result =
  { text : string
  ; invalid_bytes : int
  ; changed : bool
  }
(** Result of repairing malformed UTF-8 text. *)

val repair_utf8_text_with_stats :
  ?surface:string -> ?path:string -> string -> utf8_repair_result
(** Replace malformed UTF-8 byte sequences with U+FFFD, record an
    observable persistence repair when [changed = true], and return the
    repair metadata needed by callers that can self-heal the backing file. *)

val repair_utf8_text :
  ?surface:string -> ?path:string -> string -> string
(** Replace malformed UTF-8 byte sequences with U+FFFD and record an
    observable persistence repair. Valid UTF-8 is returned unchanged. *)

val persistence_utf8_repair_stats : unit -> utf8_repair_stats
(** Process-local cumulative count of malformed UTF-8 repairs seen by
    persistence read helpers. *)

val set_persistence_utf8_repair_metric_hook : (unit -> unit) -> unit
(** Install the higher-level metrics hook called once for each persistence
    UTF-8 repair. Safe_ops lives below Otel_metric_store, so the hook keeps the
    dependency direction one-way. *)

val reset_persistence_utf8_repair_stats_for_tests : unit -> unit
(** Reset {!persistence_utf8_repair_stats}. Test-only. *)

val persistence_utf8_repair_log_entry_limit_for_tests : unit -> int
(** Current UTF-8 repair warning rate-limit table bound. Test-only. *)

val persistence_utf8_repair_log_key_count_for_tests : unit -> int
(** Current UTF-8 repair warning rate-limit table size. Test-only. *)

val sanitize_text_utf8 : string -> string
(** Replace invalid UTF-8 bytes with U+FFFD and replace disallowed ASCII
    control characters with spaces (except LF/CR/TAB), without recording a
    read-path persistence repair. *)

val sanitize_json_utf8 : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively scrub every JSON string node through {!sanitize_text_utf8}.
    Intended for writer-side sanitization before persistence or broadcast. *)

val parse_json_safe : context:string -> string -> (Yojson.Safe.t, string) result
(** Parse JSON with detailed error reporting. *)

(** {1 File I/O} *)

type read_file_error =
  | File_not_found of string
  | Read_failed of
      { path : string
      ; detail : string
      }

val read_file_error_to_string : read_file_error -> string

val read_file_result : string -> (string, read_file_error) result
(** Read file contents with a typed error, so callers that branch on the
    missing-file case match a constructor rather than the rendered
    message's prefix. Uses Eio-native I/O via Fs_compat when available
    (after set_fs), falls back to blocking I/O in non-Eio contexts. *)

val read_file_safe : string -> (string, string) result
(** [read_file_result] with the error rendered for display. *)

val read_json_file_safe : string -> (Yojson.Safe.t, string) result
(** Read JSON file safely. *)

val read_json_file_logged : label:string -> string -> Yojson.Safe.t option
(** Read JSON file safely, logging errors instead of silently discarding them.
    Returns [Some json] on success, [None] on failure with a warning log. *)

(* The five reason words used to be exported here as strings while
   [Read_drop_reason] held the same vocabulary as a closed variant that nothing
   passed. Two spellings, and the compiler compared neither: a new reason could
   be added to one and missed by the other, and a typo in a call site was a
   valid string. The reporters below take the variant. *)

val report_persistence_read_drop :
  on_drop:(unit -> unit) ->
  surface:string ->
  reason:Read_drop_reason.t ->
  path:string ->
  detail:string ->
  unit
(** Report a persisted read-model drop via WARN log + Otel_metric_store counter. *)

val report_persistence_read_drop_counted :
  surface:string ->
  reason:Read_drop_reason.t ->
  path:string ->
  detail:string ->
  unit
(** [report_persistence_read_drop_counted] calls
    {!report_persistence_read_drop} with the drop counter every JSONL
    surface uses: [masc_persistence_read_drops_total] incremented with
    labels [surface] and [reason]. *)

val read_json_eio : string -> Yojson.Safe.t
(** Read JSON file via Eio-native I/O (Fs_compat).
    Drop-in replacement for [Yojson.Safe.from_file] in Eio fiber contexts. *)

val list_dir_safe : string -> (string list, string) result
(** List files in directory safely. *)

val remove_file_logged : ?context:string -> string -> unit
(** Remove file with logging on failure (for cleanup operations). *)

(** {1 Numeric Parsing} *)

val int_of_string_safe : string -> int option
(** Safe integer parsing. *)

val int_of_string_with_default : default:int -> string -> int
(** Integer parsing with default. *)

val float_of_string_safe : string -> float option
(** Safe float parsing. *)

val float_of_string_with_default : default:float -> string -> float
(** Float parsing with default. *)

(** {1 Environment Variables} *)

val get_env_int_logged : string -> default:int -> int
(** Get environment variable as int with logging when invalid. *)

val get_env_bool_logged : string -> default:bool -> bool
(** Get environment variable as bool with logging when invalid. Empty strings
    are treated as explicit [false] so present-but-empty env overrides do not
    accidentally enable opt-out flags. *)

(** {1 JSON Value Extraction Helpers}

    Safe extraction from Yojson.Safe.t values with proper error handling.
    These replace [with _ -> default] patterns in JSON parsing code.
*)

val json_string : ?default:string -> string -> Yojson.Safe.t -> string
val json_int : ?default:int -> string -> Yojson.Safe.t -> int
val json_float : ?default:float -> string -> Yojson.Safe.t -> float
val json_bool : ?default:bool -> string -> Yojson.Safe.t -> bool
val json_string_list : string -> Yojson.Safe.t -> string list
val json_string_opt : string -> Yojson.Safe.t -> string option

val json_string_nonempty_opt : string -> Yojson.Safe.t -> string option
(** [json_string_nonempty_opt key json] returns the trimmed string field
    [key], or [None] when the field is missing, is not a string, or is
    empty after trimming. *)

val json_int_opt : string -> Yojson.Safe.t -> int option
val json_float_opt : string -> Yojson.Safe.t -> float option
val json_bool_opt : string -> Yojson.Safe.t -> bool option

val json_list_opt : string -> Yojson.Safe.t -> Yojson.Safe.t list option
(** Extract a JSON list by key. Returns [None] if missing or non-list. *)

val json_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
(** Extract any non-null JSON value by key. Returns [None] for [`Null] or missing key. *)

val safe_member : string -> Yojson.Safe.t -> Yojson.Safe.t
(** Extract a JSON value by key from an object. Returns [`Null] if key is
    missing or the enclosing value is not an object. *)
