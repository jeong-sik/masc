(** JSON row decoders and persisted row loaders for {!Board_votes}. *)

include module type of struct
  include Board_core
end

type post_meta_json_string_parse_error =
  | Post_meta_json_string_json_decode_error of string

val post_meta_json_string_parse_error_to_string :
  post_meta_json_string_parse_error -> string

val parse_post_meta_json_string_result :
  string -> (Yojson.Safe.t, post_meta_json_string_parse_error) result
(** [parse_post_meta_json_string_result raw] parses the legacy
    string-valued [meta_json] persistence field.  The parser only
    separates JSON syntax success/failure; object-shape validation stays
    with {!Board_core_payload.normalize_post_payload} so persisted-row
    semantics do not drift. *)

val parse_post_meta_json_string : string -> Yojson.Safe.t option
(** Compatibility projection over {!parse_post_meta_json_string_result}. *)

val visibility_of_string : string -> visibility option
val post_of_yojson : Yojson.Safe.t -> post option
val comment_of_yojson : Yojson.Safe.t -> comment option
val load_persisted_posts : store -> (int, string * exn) result
(** Load posts from disk into [store].  Returns [Ok loaded_count] on success
    (including when the persistence file is absent: [Ok 0]).  Returns
    [Error (path, cause)] when the file existed but could not be parsed or
    read.  Caller decides how to surface the failure — earlier behaviour
    swallowed the exception inside this function, leaving a partially loaded
    store undistinguishable from a clean one.  [Eio.Cancel.Cancelled] is
    propagated unchanged. *)

val load_persisted_comments : store -> (int, string * exn) result
(** See {!load_persisted_posts}. *)
