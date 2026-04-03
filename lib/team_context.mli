(** Team_context — shared context for team session workers.

    Provides a compact summary of the team's state that can be injected
    into worker prompts so they have awareness of:
    - The overall team goal
    - Decisions made by prior workers
    - Findings shared by teammates
    - Currently active workers

    Token budget: [to_prompt_section] output is capped at ~500 tokens.

    @since 3.0.0 *)

(** Summary of a single task in the session. *)
type task_summary = {
  task_id : string;
  title : string;
  status : string;
  assignee : string option;
}

(** Team context shared across workers in a session. *)
type team_context = {
  team_goal : string;
  prior_decisions : string list;
  shared_findings : string list;
  active_workers : string list;
  task_tree : task_summary list;
}

(** Build a team context from the current session state.
    Reads the session goal, worker results, and task list. *)
val build :
  base_path:string -> team_session_id:string -> team_context

(** Render the team context as a prompt section string.
    Output is capped to stay within ~500 tokens. *)
val to_prompt_section : team_context -> string

(** Record a shared finding from a completed worker.
    [finding] should be 1-2 sentences summarizing the key result. *)
val add_finding :
  base_path:string ->
  team_session_id:string ->
  worker_name:string ->
  finding:string ->
  unit

(** Load recent shared findings recorded by prior workers in a session.
    Returns a list of formatted strings: "[worker_name] finding". *)
val load_findings :
  base_path:string -> team_session_id:string -> string list

(** Empty context for when no session is active. *)
val empty : team_context

(** {1 OAS Collaboration bridge}

    Lossy projection from MASC team session (47 fields) to
    OAS {!Agent_sdk.Collaboration.t} (12 fields).
    MASC votes/artifacts are not in the session record, so those
    fields are empty in the result.  [shared_context] is populated
    from shared findings.

    @since 2.114.0 *)

val collaboration_of_session :
  base_path:string ->
  Team_session_types.session ->
  Agent_sdk.Collaboration.t

type runtime_health = {
  base_path_exists : bool;
  room_initialized : bool;
  session_running : bool;
}

val with_runtime_health :
  Agent_sdk.Collaboration.t ->
  runtime_health ->
  Agent_sdk.Collaboration.t
