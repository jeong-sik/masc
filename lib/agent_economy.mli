module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Agent_economy — Currency/reward system for MASC agents

    Agents earn credits by completing tasks, writing board posts,
    receiving upvotes, and responding to mentions.
    They spend credits when consuming MODEL resources.

    Behavioral pressure: when balance drops below thresholds,
    agent deliberation priorities shift (Normal → Frugal → Hustle).

    Feature flag: MASC_ECONOMY_ENABLED (default: false).
    Ledger: .masc/economy/ledger.jsonl (append-only).

    @since Phase 1 — Agent Economy
*)

(** {1 Pressure Modes} *)

type pressure_mode =
  | Normal   (** >= frugal_threshold: free proactive, reflection, planning *)
  | Frugal   (** < frugal_threshold: proactive cooldown 2x, shorter responses *)
  | Hustle   (** < hustle_threshold: proactive suppressed, pending tasks first *)

(** {1 Transaction Types} *)

type transaction_kind =
  | Earn_task_done
  | Earn_board_post
  | Earn_upvote
  | Earn_mention_response
  | Spend_model_call
  | Spend_deliberation
  | Adjustment

type transaction = {
  id: string;
  agent_name: string;
  kind: transaction_kind;
  amount: float;
  balance_after: float;
  reason: string;
  counterparty: string;
  metadata: Yojson.Safe.t;
  timestamp: float;
}

(** {1 Configuration} *)

val enabled : unit -> bool
(** Whether the economy system is active. *)

val initial_balance : unit -> float
(** Starting balance for new agents. *)

val frugal_threshold : unit -> float
(** Balance below this triggers Frugal mode. *)

val hustle_threshold : unit -> float
(** Balance below this triggers Hustle mode. *)

(** {1 Core Operations} *)

val earn :
  base_path:string ->
  agent_name:string ->
  kind:transaction_kind ->
  reason:string ->
  ?reputation_score:float ->
  ?metadata:Yojson.Safe.t ->
  unit ->
  (float, string) Result.t
(** Record an earning. Returns new balance or error.
    Amount is determined by kind + env config + reputation multiplier.
    Pass [~reputation_score] (0.0-1.0) to enable reputation-based
    reward multiplier. If omitted, multiplier defaults to 1.0. *)

val spend :
  base_path:string ->
  agent_name:string ->
  amount:float ->
  kind:transaction_kind ->
  reason:string ->
  ?metadata:Yojson.Safe.t ->
  unit ->
  (float, string) Result.t
(** Record a spend. [amount] should be positive (will be negated internally).
    Returns new balance or error. *)

val get_balance : base_path:string -> agent_name:string -> float
(** Current balance for an agent. Returns initial_balance if no history. *)

val list_transactions : base_path:string -> transaction list
(** Read ledger transactions in append order. Malformed entries are skipped. *)

val economic_pressure : base_path:string -> agent_name:string -> pressure_mode
(** Determine behavioral pressure mode from current balance. *)

(** {1 Serialization} *)

val transaction_to_json : transaction -> Yojson.Safe.t
val transaction_of_json : Yojson.Safe.t -> transaction option
val pressure_mode_to_string : pressure_mode -> string

(** {1 Reputation Integration} *)

val reward_multiplier : overall_score:float -> float
(** Compute reward multiplier from reputation score (0.0-1.0).
    Maps to 0.5x-1.5x range. Only applied when
    MASC_ECONOMY_REPUTATION_MULTIPLIER=true. *)

(** {1 Testing Support} *)

val reset_cache : unit -> unit
(** Clear in-memory balance cache. For testing only. *)
