(** Pure byte-size and role-count estimation for keeper wake-time
    payload telemetry. Unit-testable building block for
    [Keeper_agent_run] telemetry hook. *)

type sizes = {
  system_prompt_bytes : int;
  tool_defs_bytes : int;
  messages_bytes : int;
  approx_body_bytes : int;
  message_count : int;
  role_counts : (string * int) list;
  tool_count : int;
}

val role_key : Agent_sdk.Types.role -> string

val bytes_of_content_block : Agent_sdk.Types.content_block -> int

val bytes_of_message : Agent_sdk.Types.message -> int

val estimate_tool_defs_bytes : Agent_sdk.Tool.t list -> int

val role_counts_with_pending_user :
  Agent_sdk.Types.message list -> (string * int) list

(** Compute payload-size estimates and role distribution for a keeper
    turn about to invoke [Oas_worker.run_named]. The result assumes OAS
    will synthesize a new User message from [~user_message] and append
    it after [~history_messages]; therefore [message_count] and
    [role_counts] include that pending user turn.

    Invariant: [message_count = sum_of_role_counts result.role_counts]. *)
val compute_sizes :
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  history_messages:Agent_sdk.Types.message list ->
  user_message:string ->
  sizes
