(** Pure current persisted post, comment and audience codecs.
    Decoding retains diagnostics for the caller to emit at the public boundary;
    a rejected row can still carry diagnostics from its nested fields. *)

open Board_types

type diagnostic =
  | Invalid_post_kind of { post_id : string }
  | Invalid_agent_id of { raw : string }

type 'a decoded = {
  value : 'a option;
  diagnostics : diagnostic list;
}

val post_to_yojson : post -> Yojson.Safe.t
val post_origin_to_yojson : post_origin -> Yojson.Safe.t
val post_close_state_to_yojson : post_close_state -> Yojson.Safe.t
val comment_to_yojson : comment -> Yojson.Safe.t
val audience_to_yojson : audience -> Yojson.Safe.t

val post_of_yojson : Yojson.Safe.t -> post decoded
val comment_of_yojson : Yojson.Safe.t -> comment decoded
val audience_of_yojson : Yojson.Safe.t -> audience decoded
