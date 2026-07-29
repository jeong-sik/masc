(** JSON row decoders and persisted row loaders for {!Board_votes}. *)

include module type of struct
  include Board_core
end

val visibility_of_string : string -> visibility option
val post_of_yojson : Yojson.Safe.t -> post option
val comment_of_yojson : Yojson.Safe.t -> comment option
val load_persisted_posts : store -> (int, board_error) result
(** Load posts from disk into [store].  Returns [Ok loaded_count] on success
    (including when the persistence file is absent: [Ok 0]).  Returns
    [Error (Persistence_reset_required _)] when any row is not the current
    schema and [Error (Io_error _)] when the file cannot be read. No rows are
    inserted unless the whole snapshot validates. [Eio.Cancel.Cancelled] is
    propagated unchanged. *)

val load_persisted_comments : store -> (int, board_error) result
(** See {!load_persisted_posts}. *)
