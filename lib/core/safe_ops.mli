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

val try_with_default : default:'a -> string -> (unit -> 'a) -> 'a
(** Execute with default value on failure. *)

val try_catch : (unit -> 'a) -> ('a, exn) result
(** Cancel-aware Result wrapper.
    Re-raises [Eio.Cancel.Cancelled]; captures any other exception as [Error exn]. *)

val handle : (unit -> 'a) -> (exn -> 'a) -> 'a
(** Cancel-aware exception handler.
    Re-raises [Eio.Cancel.Cancelled]; delegates other exceptions to the handler. *)

(** {1 JSON Parsing} *)

type utf8_repair_stats =
  { repaired_reads : int
  ; repaired_bytes : int
  ; path_samples : string list
  }

val repair_utf8_text :
  ?surface:string -> ?path:string -> string -> string
(** Replace malformed UTF-8 byte sequences with U+FFFD and record an
    observable persistence repair. Valid UTF-8 is returned unchanged. *)

val persistence_utf8_repair_stats : unit -> utf8_repair_stats
(** Process-local cumulative count of malformed UTF-8 repairs seen by
    persistence read helpers. *)

val reset_persistence_utf8_repair_stats_for_tests : unit -> unit
(** Reset {!persistence_utf8_repair_stats}. Test-only. *)

val parse_json_safe : context:string -> string -> (Yojson.Safe.t, string) result
(** Parse JSON with detailed error reporting. *)

(** {1 File I/O} *)

val read_file_safe : string -> (string, string) result
(** Read file contents with error handling.
    Uses Eio-native I/O via Fs_compat when available (after set_fs),
    falls back to blocking I/O in non-Eio contexts. *)

val read_json_file_safe : string -> (Yojson.Safe.t, string) result
(** Read JSON file safely. *)

val read_json_file_logged : label:string -> string -> Yojson.Safe.t option
(** Read JSON file safely, logging errors instead of silently discarding them.
    Returns [Some json] on success, [None] on failure with a warning log. *)

val persistence_read_drop_reason_list_dir_error : string
val persistence_read_drop_reason_entry_load_error : string
val persistence_read_drop_reason_invalid_payload : string

val report_persistence_read_drop :
  on_drop:(unit -> unit) ->
  surface:string ->
  reason:string ->
  path:string ->
  detail:string ->
  unit
(** Report a persisted read-model drop via WARN log + Prometheus counter. *)

val result_to_option_logged :
  on_drop:(unit -> unit) ->
  surface:string ->
  reason:string ->
  path:string ->
  ('a, string) result ->
  'a option
(** Convert a [Result] into an option while reporting [Error] as an
    observable persisted-read drop. *)

val read_json_eio : string -> Yojson.Safe.t
(** Read JSON file via Eio-native I/O (Fs_compat).
    Drop-in replacement for [Yojson.Safe.from_file] in Eio fiber contexts. *)

val list_dir_safe : string -> (string list, string) result
(** List files in directory safely. *)

val remove_file_logged : ?context:string -> string -> unit
(** Remove file with logging on failure (for cleanup operations). *)

val close_in_logged : in_channel -> unit
(** Close channel with logging on failure. *)

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

val get_env_float_logged : string -> default:float -> float
(** Get environment variable as float with logging when invalid. *)

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
val json_int_opt : string -> Yojson.Safe.t -> int option
val json_float_opt : string -> Yojson.Safe.t -> float option
val json_bool_opt : string -> Yojson.Safe.t -> bool option

val json_list : string -> Yojson.Safe.t -> Yojson.Safe.t list
(** Extract a JSON list by key. Returns [[]] if missing or non-list. *)

val json_list_opt : string -> Yojson.Safe.t -> Yojson.Safe.t list option
(** Extract a JSON list by key. Returns [None] if missing or non-list. *)

val json_assoc : string -> Yojson.Safe.t -> (string * Yojson.Safe.t) list
(** Extract a JSON object by key. Returns [[]] if missing or non-object. *)

val json_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
(** Extract any non-null JSON value by key. Returns [None] for [`Null] or missing key. *)

(** {1 Tail-recursive list helpers} *)

val concat_map_safe : ('a -> 'b list) -> 'a list -> 'b list
(** Tail-recursive [List.concat_map].  Stdlib's version uses O(N) stack. *)

val map_safe : ('a -> 'b) -> 'a list -> 'b list
(** Tail-recursive [List.map].  Stdlib's version uses O(N) stack. *)
