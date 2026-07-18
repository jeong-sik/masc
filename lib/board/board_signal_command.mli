(** Immutable Board mutation command persisted by the routing outbox.

    This module is the single owner of the command type, its strict durable
    codec, routing audience, emitted signal, and deterministic replay. *)

type routing_post_snapshot = {
  post_id : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float;
  reply_count : int;
}

type t = private
  | Post of {
      post : Board.post;
      audience : Board_signal_audience.t;
    }
  | Comment of {
      comment : Board.comment;
      routing_post : routing_post_snapshot;
      audience : Board_signal_audience.t;
    }
  | Reaction of {
      target_type : Board.reaction_target_type;
      target_id : string;
      user_id : string;
      emoji : string;
      reacted : bool;
      created_at : float;
      routing_post : routing_post_snapshot;
      audience : Board_signal_audience.t;
    }

type signal_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of reaction_change

and reaction_change = {
  target_type : Board.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type signal = {
  kind : signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val routing_post_snapshot_of_post : Board.post -> routing_post_snapshot

val post : Board.post -> (t, Board.board_error) result

val comment :
  post:Board.post ->
  comments:Board.comment list ->
  Board.comment ->
  (t, Board.board_error) result

val reaction :
  post:Board.post ->
  comments:Board.comment list ->
  target_type:Board.reaction_target_type ->
  target_id:string ->
  user_id:string ->
  emoji:string ->
  reacted:bool ->
  created_at:float ->
  (t, Board.board_error) result

val signal : t -> signal
val audience : t -> Board_signal_audience.t
val referenced_post_id : t -> string
val referenced_comment_id : t -> string option
val apply : Board.store -> t -> (unit, string) result
