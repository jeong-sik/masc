(** A package's declared primary navigation category. This is display metadata,
    independent of service obligations, capabilities, model routes and authority. *)
type t =
  | Memory_and_judgment
  | Browser
  | External_communications
  | Voice_and_media
  | Execution_environment
  | Analysis

val to_string : t -> string
val of_string : string -> (t, string) result
(** Exact closed wire vocabulary; unknown, empty or padded values are errors.
    An omitted category is represented by the enclosing [option], never by a
    fallback category. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Only a supported string is a declared category; [null] is not absence. *)
