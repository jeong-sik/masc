(** Strict JSON wire decoding combinators, timestamp parsers, [Observed.t]
    adapters, server health identity, and shared v2 response/error envelopes.

    All decoders return [Result.t] and reject missing required fields, malformed
    types, or unknown enum values without silent defaults. *)

open Masc_tui_core

type envelope_meta = {
  schema_version : int;
  instance_id : string;
  generated_at_unix : float;
}

val unwrap_v2_envelope :
  Yojson.Safe.t -> (envelope_meta * Yojson.Safe.t, string) result
(** Decode a v2 envelope [{ schema_version; instance_id; generated_at_unix; data }].
    Rejects non-positive [schema_version], blank [instance_id], non-finite
    timestamps, and absent [data]. *)

val unwrap_v2_or_raw :
  Yojson.Safe.t -> (envelope_meta option * Yojson.Safe.t, string) result
(** Unwrap a v2 envelope when [schema_version] and [data] are present;
    otherwise validate that the payload is a JSON object and return it directly
    with [None] metadata. *)

(** {1 Strict Field Combinators} *)

val has_field : Yojson.Safe.t -> string -> bool
(** True iff the JSON value is an object containing key [name] (even when its
    value is [null]). *)

val reject_forbidden_field :
  Yojson.Safe.t -> string -> context:string -> (unit, string) result
(** Fail with a clear error when key [name] is present on the object, even as
    [null]. Used e.g. to reject legacy [status] on Goals. *)

val required_finite_float : Yojson.Safe.t -> string -> (float, string) result
val optional_finite_float : Yojson.Safe.t -> string -> (float option, string) result
val required_nonnegative_float : Yojson.Safe.t -> string -> (float, string) result
val required_nonblank_string : Yojson.Safe.t -> string -> (string, string) result
val optional_nonblank_string : Yojson.Safe.t -> string -> (string option, string) result
val required_string_list : Yojson.Safe.t -> string -> (string list, string) result
val optional_string_list : Yojson.Safe.t -> string -> (string list, string) result

val decode_enum :
  field:string -> (string -> 'a option) -> Yojson.Safe.t -> ('a, string) result

val decode_optional_enum :
  field:string ->
  (string -> 'a option) ->
  Yojson.Safe.t ->
  ('a option, string) result

(** {1 Observed.t Field Decoders}

    Absence of the key on the wire yields [Observed.Unreported]; an explicit
    [null] yields [Observed.Absent]; a valid typed value yields
    [Observed.Value]; a malformed JSON shape returns [Error]. *)

val observed_float :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  string ->
  (float Observed.t, string) result

val observed_int :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  string ->
  (int Observed.t, string) result

val observed_string :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  string ->
  (string Observed.t, string) result

val observed_bool :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  string ->
  (bool Observed.t, string) result

val observed_of_json :
  observed_at:Clock.Mono.t ->
  (Yojson.Safe.t -> ('a, string) result) ->
  Yojson.Safe.t ->
  string ->
  ('a Observed.t, string) result

(** {1 RFC3339 & Unix Timestamp Helpers} *)

val parse_rfc3339_unix : string -> (float, string) result
(** Parse an RFC3339 timestamp ([YYYY-MM-DDTHH:MM:SS(.frac)?(Z|[+-]HH:MM)])
    into Unix epoch seconds. *)

val format_unix_rfc3339 : float -> string
(** Format Unix epoch seconds as UTC RFC3339 ([YYYY-MM-DDTHH:MM:SSZ]). *)

val decode_timestamp_unix : Yojson.Safe.t -> string -> (float, string) result
(** Accept a finite Unix timestamp number or a valid RFC3339 string. *)

val decode_optional_timestamp_unix :
  Yojson.Safe.t -> string -> (float option, string) result

(** {1 URL Encoding} *)

val percent_encode : string -> string
(** RFC 3986 unreserved-safe percent encoding for path segments and query values. *)

(** {1 Server Identity & Health ([GET /health])} *)

type workspace_identity = {
  instance_id : string option;
  base_path : string;
  masc_root : string;
  workspace_sha256 : string option;
}

type health_scope =
  | Public_health
  | Full_health of workspace_identity

type server_gc_stats = {
  live_words : int option;
  heap_words : int option;
  major_collections : int option;
  minor_collections : int option;
}

type server_health = {
  ok : bool;
  live : bool option;
  ready : bool option;
  phase : string option;
  status : string;
  version : string;
  binary_commit : string option;
  uptime_display : string option;
  uptime_sec : float option;
  scope : health_scope;
  gc : server_gc_stats option;
  active_keepers : int option;
}

val health_path : string
val decode_server_health : Yojson.Safe.t -> (server_health, string) result
(** Decode [GET /health] in both public unauthenticated form ([Public_health])
    and authenticated full form ([Full_health] with [paths.effective_base_path]
    and [paths.effective_masc_root]). Never fabricates missing workspace paths
    or instance IDs. Rejects multi-account payloads carrying [account_mode]. *)

(** {1 Structured API Error Envelope} *)

type api_error_code =
  | Invalid_param
  | Unauthorized
  | Not_found
  | Sandbox_telemetry_missing
  | Conflict_cas
  | Workspace_mismatch
  | Validation_failed
  | Store_unavailable
  | Other_code of string

type api_error = {
  code : api_error_code;
  message : string;
  field : string option;
  expected_instance : string option;
  observed_instance : string option;
  observed_workspace_sha256 : string option;
}

val api_error_code_of_string : string -> api_error_code
val api_error_code_to_string : api_error_code -> string
val decode_api_error : Yojson.Safe.t -> (api_error, string) result
(** Decode structured server error JSON [{ "error": { "code"; "message"; ... } }]
    or flat [{ "code"; "error"|"message"; ... }]. *)
