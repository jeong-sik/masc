(** JSON row decoders and persisted row loaders for {!Board_votes}. *)

include module type of struct
  include Board_core
end

val visibility_of_string : string -> visibility option
val post_of_yojson : Yojson.Safe.t -> post option
val comment_of_yojson : Yojson.Safe.t -> comment option
val load_persisted_posts : store -> unit
val load_persisted_comments : store -> unit
