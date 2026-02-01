(** Social - Moltbook-style social features for MASC

    Provides posts, threaded comments, and voting system for agent collaboration.
    Storage: .masc/social/posts/ and .masc/social/comments/ directories.
*)

(** {1 Types} *)

(** Post in the social feed *)
type post = {
  id: string;
  author: string;
  content: string;
  submolt: string option;  (** Topic channel/category *)
  created_at: float;
  votes: int;
}

(** Comment on a post (supports threading) *)
type comment = {
  id: string;
  post_id: string;
  parent_id: string option;  (** None = top-level, Some = threaded reply *)
  author: string;
  content: string;
  created_at: float;
  votes: int;
}

(** Vote direction *)
type vote_direction = Up | Down

(** Vote record *)
type vote_record = {
  voter: string;
  direction: vote_direction;
  voted_at: float;
}

(** {1 ID Generation} *)

val generate_post_id : unit -> string
val generate_comment_id : unit -> string

(** {1 JSON Serialization} *)

val post_to_yojson : post -> Yojson.Safe.t
val post_of_yojson : Yojson.Safe.t -> (post, string) result
val comment_to_yojson : comment -> Yojson.Safe.t
val comment_of_yojson : Yojson.Safe.t -> (comment, string) result

(** {1 Storage Operations} *)

(** Get the social directory path *)
val social_dir : Room_utils.config -> string

(** Get posts directory *)
val posts_dir : Room_utils.config -> string

(** Get comments directory *)
val comments_dir : Room_utils.config -> string

(** Get votes directory *)
val votes_dir : Room_utils.config -> string

(** Ensure social directories exist *)
val ensure_dirs : Room_utils.config -> unit

(** {1 Post Operations} *)

(** Create a new post *)
val create_post : Room_utils.config -> author:string -> content:string ->
  ?submolt:string -> unit -> (post, string) result

(** Get a post by ID *)
val get_post : Room_utils.config -> post_id:string -> (post, string) result

(** List posts, optionally filtered by submolt, sorted by votes desc *)
val list_posts : Room_utils.config -> ?submolt:string -> ?limit:int ->
  unit -> post list

(** {1 Comment Operations} *)

(** Add a comment to a post *)
val add_comment : Room_utils.config -> post_id:string -> author:string ->
  content:string -> ?parent_id:string -> unit -> (comment, string) result

(** Get comments for a post, optionally as a tree *)
val get_comments : Room_utils.config -> post_id:string -> comment list

(** Get threaded comments (returns top-level comments with nested replies) *)
val get_comments_threaded : Room_utils.config -> post_id:string ->
  (comment * comment list) list

(** {1 Voting} *)

(** Vote on a post or comment *)
val vote : Room_utils.config -> voter:string -> target_type:[ `Post | `Comment ] ->
  target_id:string -> direction:vote_direction -> (int, string) result

(** Get current vote count for a target *)
val get_votes : Room_utils.config -> target_type:[ `Post | `Comment ] ->
  target_id:string -> int
