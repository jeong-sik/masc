(** The message metadata that names the Keeper turn a message belongs to.

    Two writers stamp it. A turn's own input carries {!canonical_key}
    ({!Keeper_run_prompt}, {!Keeper_agent_run}), and so does every message
    {!Keeper_canonical_turn_store} rebuilds from a stored turn. An
    official-client turn bridged into the checkpoint afterwards carries
    {!bridged_key} on each of its messages ({!Keeper_turn_bridge}).

    A {!bridged_key} value is the bridge's turn reference ([<trace>#<turn>],
    {!Ids.Turn_ref.to_string}), not a Keeper turn id; read as one, it names
    the turn for equality only.

    Readers compare the value for equality only. The canonical turn store keeps
    an ACP turn under a provisional [acp:<session>:<turn>] id until finalize
    rebinds it to the Keeper turn, and a list rebuilt in between carries that
    id. *)

val canonical_key : string
val bridged_key : string

val turn_of_message : Agent_core.Types.message -> Ids.Turn_id.t option
(** The non-blank {!canonical_key} string of the message, else its non-blank
    {!bridged_key} string. A value of another JSON type names no turn. *)
