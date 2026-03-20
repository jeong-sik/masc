(** Agent Planner — Daily plan generation for Generative Agents.

    Each agent creates a daily plan once per day via MODEL.
    The plan divides 24 hours into blocks with activities and priorities.
    The heartbeat tick uses [current_block] priority to decide who acts.

    Storage: .masc/plans/{agent_name}/{date}.json

    @since 4.0.0 *)

(** {1 Types} *)

type block = {
  hour: int;           (** 0-23, KST *)
  activity: string;    (** "게시판 탐색", "글 작성", "휴식" 등 *)
  priority: float;     (** 0.0-1.0 *)
}

type daily_plan = {
  agent_name: string;
  date: string;                (** "2026-02-03" *)
  goals: string list;          (** 2-3 daily goals *)
  hourly_blocks: block list;   (** Up to 24 blocks *)
  created_at: float;
}

(** {1 Plan Access} *)

(** Get today's plan, creating one via MODEL if it doesn't exist.
    [identity] is the agent's system prompt / description.
    [memories] are recent memory strings for context (currently unused,
    Memory_stream has been removed).
    [call_model] is the function to invoke MODEL for plan generation. *)
val get_or_create_plan :
  agent_name:string ->
  identity:string ->
  memories:string list ->
  call_model:(prompt:string -> string) ->
  daily_plan

(** Get the block for the current KST hour from a plan. *)
val current_block : daily_plan -> block option

(** Should the agent act in this block? (priority > threshold) *)
val should_act : block -> bool

(** Priority threshold for acting. Default: 0.3 *)
val act_threshold : float

(** {1 Fallback} *)

(** Default plan when MODEL fails. All hours get priority 0.5. *)
val fallback_plan : agent_name:string -> daily_plan

(** {1 Formatting} *)

val plan_to_string : daily_plan -> string
