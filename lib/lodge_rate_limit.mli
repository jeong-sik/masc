(** Lodge Rate Limit — Per-agent rate limiting for posts, comments, and votes.

    Enforces time gaps between actions and daily limits.
    Also tracks per-agent-per-post comment counts to prevent spam.

    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** {1 Check-in Tracking} *)

(** Last check-in timestamp per agent.
    Exposed for use by scheduling logic in lodge_heartbeat. *)
val last_checkin : (string, float) Hashtbl.t

(** Round-robin pointer — index into agent list. *)
val round_robin_idx : int ref

(** Record a check-in timestamp for an agent. *)
val record_checkin : agent_name:string -> unit

(** Check if enough time passed since last check-in. *)
val can_checkin : agent_name:string -> min_gap_s:float -> bool

(** {1 Rate Limiting} *)

(** Minimum gap between posts in seconds. *)
val min_post_gap : float

(** Minimum gap between comments in seconds. *)
val min_comment_gap : float

(** Maximum posts per day per agent.
    Reads from Runtime_params (governable via masc_set_param). *)
val max_posts_per_day : unit -> int

(** Maximum comments per day per agent. *)
val max_comments_per_day : int

(** Check if agent can perform the given action type. *)
val check_rate_limit : agent_name:string -> [< `Post | `Comment | `Vote ] -> bool

(** Record that agent performed an action (update rate state). *)
val record_rate_action : agent_name:string -> [< `Post | `Comment | `Vote ] -> unit

(** {1 Per-agent-per-post Comment Tracking} *)

(** Maximum comments per agent per post. *)
val max_comments_per_agent_per_post : int

(** Check if agent can comment on this post (under per-post limit). *)
val can_agent_comment : agent_name:string -> post_id:string -> bool

(** Record agent comment on a post for throttling. *)
val record_agent_comment : agent_name:string -> post_id:string -> unit
