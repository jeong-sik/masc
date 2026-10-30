(** One usage report an official client (Codex app-server, Claude Code,
    Antigravity) sent on its own stream while a turn runs. The runtime reads
    it before the turn has an outcome, so a turn that ends in an error still
    has it. The Keeper records it as a raw cost-ledger observation. *)

(** What one report counts. *)
type count =
  | Running_count of Agent_core.Types.api_usage
      (** The client's count, covering what [usage_scope] names. *)
  | Count_replaced
      (** The client replaced its running count instead of reporting one:
          Codex after a request overflowed the context window
          (fill_to_context_window). Nothing is counted here. The
          conversation's count before it is the last it reached, and a count
          after it starts again from zero. *)

type t =
  { official_turn : int
        (** The client turn the report belongs to, as the completion hook
            numbers it. *)
  ; response_id : string
        (** The client's identity for that turn, the one the completion hook
            writes. *)
  ; model : string
  ; conversation_id : string
        (** The client conversation the counts belong to: the Codex thread,
            the Claude Code session, the Antigravity conversation. A
            conversation-cumulative count means nothing without it. *)
  ; position : Keeper_usage_resolution.cumulative_position
        (** Whether this client turn started the conversation or resumed it. *)
  ; usage_scope : Runtime_usage_scope.t
        (** What the counts cover: one client turn, or the conversation so
            far. *)
  ; count : count
  ; vendor_total_tokens : int option
        (** The client's own total, when it reports one. For
            [Count_replaced] it is the context window Codex wrote in place of
            the count. *)
  }
