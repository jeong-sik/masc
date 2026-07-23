(** Pure byte-size and role-count observation for keeper wake-time payloads.
    Unit-testable building block for
    [Keeper_agent_run] telemetry hook. *)

type sizes = {
  system_prompt_bytes : int;
  tool_schema_json_bytes : int;
  message_content_bytes : int;
  message_count : int;
  role_counts : (string * int) list;
  tool_count : int;
}

val role_key : Agent_sdk.Types.role -> string

val bytes_of_content_block : Agent_sdk.Types.content_block -> int

val bytes_of_message_content : Agent_sdk.Types.message -> int

val bytes_of_tool_schema_json : Agent_sdk.Tool.t list -> int

val role_counts_with_pending_user :
  Agent_sdk.Types.message list -> (string * int) list

(** Compute exact component-content byte counts and role distribution for a keeper
    turn about to invoke [Keeper_turn_driver.run_named]. OAS will synthesize the
    pending User message from [~user_blocks] when present, otherwise from
    [~user_message]; [message_count] and [role_counts] include that turn.

    These are exact byte counts of the canonical component values MASC owns,
    not an estimate of a provider-specific HTTP request body. In particular,
    [message_content_bytes] excludes message role, name, and provider metadata;
    [tool_schema_json_bytes] sums each canonical tool schema JSON value without
    claiming provider request-array overhead.

    Invariant: [message_count = sum_of_role_counts result.role_counts]. *)
val compute_sizes :
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  history_messages:Agent_sdk.Types.message list ->
  ?user_blocks:Agent_sdk.Types.content_block list ->
  user_message:string ->
  unit ->
  sizes
