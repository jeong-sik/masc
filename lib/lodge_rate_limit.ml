(** Lodge Rate Limit — Per-agent rate limiting for posts, comments, and votes.

    Tracks check-in timestamps and enforces time gaps and daily limits.
    Also tracks per-agent-per-post comment counts to prevent spam.

    @since 2.14.0
    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** {1 Check-in Tracking} *)

(** Last check-in timestamp per agent *)
let last_checkin : (string, float) Hashtbl.t = Hashtbl.create 10

(** Round-robin pointer — index into agent list *)
let round_robin_idx = ref 0

(** {1 Per-agent Rate State} *)

(** Per-agent rate state for posts/comments *)
type rate_state = {
  mutable last_post: float;
  mutable last_comment: float;
  mutable posts_today: int;
  mutable comments_today: int;
  mutable day_reset: float;      (** Start of current day (for daily counters) *)
}

let rate_states : (string, rate_state) Hashtbl.t = Hashtbl.create 10

let min_post_gap = Env_config_governance.LodgeV2.min_post_gap_seconds
let min_comment_gap = Env_config_governance.LodgeV2.min_comment_gap_seconds
(* Governable: read via Runtime_params so masc_set_param changes take effect *)
let max_posts_per_day () = Runtime_params.get Governance_registry.lodge_max_posts_per_day
let max_comments_per_day = Env_config_governance.LodgeV2.max_comments_per_day

(** Get or create rate state for agent *)
let get_rate_state ~agent_name =
  let now = Time_compat.now () in
  let day_start = Float.of_int (int_of_float now / 86400 * 86400) in
  match Hashtbl.find_opt rate_states agent_name with
  | Some rs ->
    (* Reset daily counters if new day *)
    if now -. rs.day_reset > 86400.0 then begin
      rs.posts_today <- 0;
      rs.comments_today <- 0;
      rs.day_reset <- day_start
    end;
    rs
  | None ->
    let rs = { last_post = 0.0; last_comment = 0.0;
               posts_today = 0; comments_today = 0; day_reset = day_start } in
    Hashtbl.replace rate_states agent_name rs;
    rs

(** Check if agent can perform the given action *)
let check_rate_limit ~agent_name action_type =
  let now = Time_compat.now () in
  let rs = get_rate_state ~agent_name in
  match action_type with
  | `Post ->
    now -. rs.last_post >= min_post_gap && rs.posts_today < max_posts_per_day ()
  | `Comment ->
    now -. rs.last_comment >= min_comment_gap && rs.comments_today < max_comments_per_day
  | `Vote -> true  (* Votes are always allowed *)

(** Record that agent performed an action (update rate state) *)
let record_rate_action ~agent_name action_type =
  let now = Time_compat.now () in
  let rs = get_rate_state ~agent_name in
  match action_type with
  | `Post -> rs.last_post <- now; rs.posts_today <- rs.posts_today + 1
  | `Comment -> rs.last_comment <- now; rs.comments_today <- rs.comments_today + 1
  | `Vote -> ()

(** Record a check-in timestamp *)
let record_checkin ~agent_name =
  Hashtbl.replace last_checkin agent_name (Time_compat.now ())

(** Check if enough time passed since last check-in *)
let can_checkin ~agent_name ~min_gap_s =
  let now = Time_compat.now () in
  match Hashtbl.find_opt last_checkin agent_name with
  | None -> true
  | Some last -> now -. last >= min_gap_s

(** {1 Per-agent-per-post Comment Tracking} *)

(** Per-agent-per-post comment tracker: (agent_name, post_id) -> count *)
let agent_comment_counts : (string * string, int) Hashtbl.t = Hashtbl.create 50

(** Max comments per agent per post *)
let max_comments_per_agent_per_post = 3

(** Check if agent can comment on this post *)
let can_agent_comment ~agent_name ~post_id =
  let key = (agent_name, post_id) in
  let count = match Hashtbl.find_opt agent_comment_counts key with
    | Some c -> c | None -> 0
  in
  count < max_comments_per_agent_per_post

(** Record agent comment for throttling *)
let record_agent_comment ~agent_name ~post_id =
  let key = (agent_name, post_id) in
  let count = match Hashtbl.find_opt agent_comment_counts key with
    | Some c -> c | None -> 0
  in
  Hashtbl.replace agent_comment_counts key (count + 1)
