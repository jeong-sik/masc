(** Private canonical domains and validation for immutable revival payloads. *)

val payload_schema : string
val ref_schema : string
val payload_digest_domain : string
val transaction_leaf_domain : string
val authority_leaf_domain : string
val payload_root_leaf : string
val authority_leaf_prefix : string
val transaction_leaf_prefix : string
val json_leaf_suffix : string

val ( let* ) :
  ('a, 'error) result ->
  ('a -> ('b, 'error) result) ->
  ('b, 'error) result

val sha256 : string -> string
val length_delimited : string -> string
val domain_digest : string -> string list -> string
val is_lowercase_sha256 : string -> bool

val exact_fields :
  kind:string ->
  string list ->
  Yojson.Safe.t ->
  ((string * Yojson.Safe.t) list, string) result

val required_field :
  kind:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (Yojson.Safe.t, string) result

val required_string :
  kind:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (string, string) result

val required_int :
  kind:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (int, string) result

val required_positive_int64 :
  kind:string ->
  string ->
  (string * Yojson.Safe.t) list ->
  (int64, string) result

val validate_payload :
  Keeper_dead_revival_payload_types.payload ->
  (unit, Keeper_dead_revival_payload_types.error) result
