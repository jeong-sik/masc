(** Keeper configuration — defaults, environment variable parsing, profiles. *)

open Tool_args
include Keeper_config_rp_helpers

(** Upper bound for keeper time configs expressed in seconds.  Repeated
    seven times as the bare literal [172800] across this file before
    the extraction; [Masc_time_constants.day_int * 2] makes the "2 days"
    intent explicit and satisfies sw-dev §"Magic Number 금지". *)
let two_days_seconds_int = Masc_time_constants.day_int * 2

(** One-day upper bound expressed in seconds for goal observation windows. *)
(* runtime→Runtime 숙청: per-phase runtime name 구분 제거. runtime 세계의
   phase_recovery / phase_buffer / tool_action / routing 은 서로 다른 route
   였으나, Runtime 모델에서는 모든 phase 가 동일한 default Runtime 을 쓴다 —
   넷 다 default_runtime_id () 으로 수렴하는 죽은 구분이었다. 단일 함수로
   collapse 하고, eager 모듈-레벨 baking(module-init 시점 미초기화 싱글톤 읽기)
   도 함께 제거한다. *)
let default_runtime_id () = Runtime.get_default_runtime_id ()

let validate_max_context_override_value value =
  if value > 0
  then Ok value
  else
    Error
      (Printf.sprintf
         "max_context_override must be positive (received %d)"
         value)
;;

include Keeper_config_text


let keeper_status_fast_default () : bool =
  bool_of_env_default "MASC_KEEPER_STATUS_FAST_DEFAULT" ~default:false

(* Own-recent-board-posts self-awareness layer. The board-event collector is
   cursor-based and filters out self-authored posts, so without this layer a
   keeper never observes its own published posts in-prompt and can repeat the
   same content every cycle (observed in production: 23 of 26 posts in one
   hour were near-duplicates). The layer restores raw observation data only —
   relevance and novelty remain model decisions; there is no dedup gate.

   [max] bounds how many of the keeper's own newest posts the world
   observation carries per turn. The Board query applies canonical ownership
   before this result limit, so unrelated traffic cannot hide the keeper's
   latest post. *)
(* How many of the Keeper's own newest [thinking] blocks the HITL judgment
   bundle carries. 0 drops them all, which is what #31172 shipped.

   Not a plain on/off, because the two things at stake pull opposite ways and
   both live in the same blocks. Size: measured 2026-08-27, thinking was 51%
   of the bundle's message blocks (23.2 kB of 85.6 kB) while the call being
   judged was 2.5 kB. Evidence: the judge's own deny rationales that day cited
   the Keeper's self-imposed constraints -- "the agent's own memory notes ...
   explicitly state 'Do NOT retry task-366'" -- and those constraints are
   stated in the newest blocks, not the oldest.

   Newest rather than oldest: a constraint a Keeper set for itself is the one
   it just wrote down, and the bulk is the reasoning it has since moved past.

   Left at 0 so this knob changes nothing on its own. Raising it is how an
   operator buys the deny evidence back, and how the two settings can be
   compared against the same durable queue. *)
let keeper_hitl_thinking_blocks_rp =
  _rp_int ~key:"keeper.hitl.thinking_blocks"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_HITL_THINKING_BLOCKS"
                          ~default:0 ~min_v:0 ~max_v:1000)
    ~min_v:0 ~max_v:1000
    ~description:"Newest keeper thinking blocks kept in the HITL judgment bundle (0 = drop all)" ()
let keeper_hitl_thinking_blocks () : int =
  Runtime_params.get keeper_hitl_thinking_blocks_rp

(* Auto Judge work is independent, durable, and nonblocking to the Keeper. A
   single owner slot turned a burst from one Keeper into a serial queue even
   while provider capacity sat idle. Four matches the existing completion
   authority fan-out and remains below the runtime/provider global caps. The
   runtime parameter keeps the product default observable and operator-tunable
   without baking deployment policy into the queue algorithm. *)
let keeper_hitl_max_concurrent_per_keeper_rp =
  _rp_int ~key:"keeper.hitl.max_concurrent_per_keeper"
    ~default:(fun () ->
      int_of_env_default
        "MASC_KEEPER_HITL_MAX_CONCURRENT_PER_KEEPER"
        ~default:4
        ~min_v:1
        ~max_v:16)
    ~min_v:1
    ~max_v:16
    ~description:"Concurrent Auto Judge workers admitted per Keeper"
    ()

let keeper_hitl_max_concurrent_per_keeper () : int =
  Runtime_params.get keeper_hitl_max_concurrent_per_keeper_rp

let keeper_board_own_recent_max_rp =
  _rp_int ~key:"keeper.board.own_recent.max"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOARD_OWN_RECENT_MAX"
                          ~default:5 ~min_v:0 ~max_v:1000)
    ~min_v:0 ~max_v:1000
    ~description:"Own recent board posts injected into the world observation per turn (0 = disable)" ()
let keeper_board_own_recent_max () : int =
  Runtime_params.get keeper_board_own_recent_max_rp

(* Fleet-message context layer. A keeper broadcast is projected into every
   other keeper's transcript, but the pending-message lanes admit only rows
   that mention this keeper or that the Owner authored, so a projected row
   reaches the dashboard and never the prompt. This layer carries the newest
   projected rows as raw observation data.

   [max] bounds how many rows the world observation carries per turn. The
   layer is cursor-independent standing context, like own recent board posts:
   there is no acknowledgement watermark, so nothing accumulates for a keeper
   that never runs an autonomous turn. *)
let keeper_fleet_messages_max_rp =
  _rp_int ~key:"keeper.fleet.messages.max"
    ~default:(fun () -> 10)
    ~min_v:0 ~max_v:1000
    ~description:"Fleet messages injected into the world observation per turn (0 = disable)" ()
let keeper_fleet_messages_max () : int =
  Runtime_params.get keeper_fleet_messages_max_rp

(* How many of the keeper's own past turns are replayed as actions. The default
   is the depth the product states a keeper must not lose ("10턴 전에 한 자신의
   발화나 행동"), and it fits the measured fleet distribution: a turn renders
   at a median 1.6 KB, so ten turns add ~16 KB to a prompt that was assembling
   5.8 KB against a 131 KB runtime cap. *)
let keeper_own_recent_turns_max_rp =
  _rp_int ~key:"keeper.own_actions.turns.max"
    ~default:(fun () -> 10)
    ~min_v:0 ~max_v:200
    ~description:"Past turns of the keeper's own tool calls replayed into the world observation (0 = disable)" ()
let keeper_own_recent_turns_max () : int =
  Runtime_params.get keeper_own_recent_turns_max_rp

(* The briefing is pinned: the conversation window cannot take back whatever
   it occupies. A keeper whose briefing outgrew its runtime's whole request cap
   could not assemble a turn at all, and no cut of the history helped, because
   the bytes were never in the history (masc#29676: 141,937 pinned bytes
   against a 131,072 cap, 86 turns refused across eight hours).

   Half keeps the guarantee symmetric — the turn being briefed always has at
   least as much room as the briefing about it. It is a ceiling, not a target:
   a briefing that already fits takes what it needs and this never applies. *)
let keeper_context_briefing_share_percent_rp =
  _rp_int ~key:"keeper.context.briefing.share_percent"
    ~default:(fun () -> 50)
    ~min_v:1 ~max_v:100
    ~description:"Share of the runtime's declared request-body cap the world-state briefing may occupy" ()
let keeper_context_briefing_share_percent () : int =
  Runtime_params.get keeper_context_briefing_share_percent_rp

let keeper_bootstrap_proactive_warmup_sec_rp =
  _rp_int ~key:"keeper.proactive.warmup_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_PROACTIVE_WARMUP_SEC"
                          ~default:60 ~min_v:0 ~max_v:two_days_seconds_int)
    ~min_v:0 ~max_v:two_days_seconds_int
    ~description:"Bootstrap proactive warmup delay (seconds)" ()
let keeper_bootstrap_proactive_warmup_sec () : int =
  Runtime_params.get keeper_bootstrap_proactive_warmup_sec_rp

let keeper_bootstrap_stagger_step_sec_rp =
  _rp_int ~key:"keeper.proactive.stagger_step_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_STAGGER_STEP_SEC"
                          ~default:15 ~min_v:0 ~max_v:120)
    ~min_v:0 ~max_v:120
    ~description:"Bootstrap warmup deterministic jitter window (seconds)" ()
let keeper_bootstrap_stagger_step_sec () : int =
  Runtime_params.get keeper_bootstrap_stagger_step_sec_rp

let keeper_bootstrap_retry_interval_sec_rp =
  _rp_int ~key:"keeper.bootstrap.retry_interval_sec"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOOTSTRAP_RETRY_INTERVAL_SEC"
                          ~default:30 ~min_v:5 ~max_v:300)
    ~min_v:5 ~max_v:300
    ~description:"Delay between autoboot retry rounds (seconds)" ()
let keeper_bootstrap_retry_interval_sec () : int =
  Runtime_params.get keeper_bootstrap_retry_interval_sec_rp

let keeper_batch_limit_rp =
  _rp_int ~key:"keeper.turn.batch_limit"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BATCH_LIMIT"
                          ~default:200 ~min_v:10 ~max_v:2000)
    ~min_v:10 ~max_v:2000
    ~description:"Max batch size per keeper cycle" ()
let keeper_batch_limit () : int =
  Runtime_params.get keeper_batch_limit_rp

(* Batch-size knob, not a workaround cap: adversarial review on
   masc#27054 traced continuation_wake and found it re-wakes the owner for
   exactly one more Completed partition per heartbeat cycle, not an
   off-turn queue. So the choice is not "block vs don't block" but a
   cycle-count/per-cycle-blocking-time tradeoff with bad extremes on both
   ends: 1 settlement/turn means 192 heartbeat cycles for a 192-item
   backlog; 192 settlements/turn is the original unbounded blocking this
   knob replaced (384 durable writes before the owner's turn can proceed
   at all). 8 sits between those without profiling data past that it
   avoids either extreme; max_v caps the dial at the largest backlog
   this repo has observed in production (masc#27017's 192). *)
let keeper_board_attention_settlements_per_turn_rp =
  _rp_int ~key:"keeper.board_attention.settlements_per_turn"
    ~default:(fun () -> int_of_env_default "MASC_KEEPER_BOARD_ATTENTION_SETTLEMENTS_PER_TURN"
                          ~default:8 ~min_v:1 ~max_v:192)
    ~min_v:1 ~max_v:192
    ~description:"Completed board-attention partitions settled per owner turn before the remainder defers to a continuation wake" ()
let keeper_board_attention_settlements_per_turn () : int =
  Runtime_params.get keeper_board_attention_settlements_per_turn_rp





(* ================================================================ *)
(* Keeper execution — previously hardcoded magic numbers             *)
(* ================================================================ *)

(* ================================================================ *)
(* Unified Keeper Turn parameters                                   *)
(* ================================================================ *)

let keeper_unified_temperature_rp =
  _rp_float ~key:"keeper.turn.temperature"
    ~default:(fun () -> float_of_env_default "MASC_KEEPER_UNIFIED_TEMP"
                          ~default:0.4 ~min_v:0.0 ~max_v:2.0)
    ~min_v:0.0 ~max_v:2.0
    ~description:"Keeper turn temperature" ()
let keeper_unified_temperature () : float =
  Runtime_params.get keeper_unified_temperature_rp

(** Force module initialization to guarantee all runtime params are registered
    before [Runtime_params.restore]. Call from server bootstrap. *)
let ensure_runtime_params_init () =
  let (_ : float) = Runtime_params.get keeper_unified_temperature_rp in
  ()

let keeper_enable_thinking_rp =
  _rp_bool ~key:"keeper.turn.enable_thinking"
    ~default:(fun () -> bool_of_env_default "MASC_KEEPER_ENABLE_THINKING" ~default:false)
    ~description:"Pass enable_thinking to AGENT_CORE (default: false; Ollama+Qwen3.5 consumes all tokens in thinking mode)" ()

let keeper_enable_thinking () : bool =
  Runtime_params.get keeper_enable_thinking_rp

(* The AGENT_CORE run loop continues after every tool round and stops only when
   the model finishes, errors, or runs a terminal tool, so a turn ended by
   exhausting wall clock or context rather than by any declared bound. Measured
   2026-08-24 over 4,416 keeper turns: p50 0 rounds, p90 6, p99 56, max 279;
   20 turns went past 80. A run that reaches the ceiling fails with
   ToolRoundLimitExceeded, which the turn's terminal reason code carries -- it
   is not truncated into something that reads as a finished run. 0 keeps the
   loop unbounded. *)
let keeper_max_tool_rounds_rp =
  _rp_int ~key:"keeper.turn.max_tool_rounds"
    ~default:(fun () -> 0)
    ~min_v:0 ~max_v:1000
    ~description:"Ceiling on tool-continuation rounds in one keeper turn (0 = unbounded)" ()

let keeper_max_tool_rounds () : int option =
  match Runtime_params.get keeper_max_tool_rounds_rp with
  | 0 -> None
  | rounds -> Some rounds
;;

(* A deferred tool placed with its schema is charged to every request of every
   later turn, and what earns it that place is having been run. "Ever run" has
   no upper bound: measured over 19,100 turns 2026-09-01..03 the per-keeper
   median carried was 32.1 KB of schema and reached 51.9 KB, while the median
   gap between two uses of the same tool is 2 turns and p90 is 24.

   Counted in tool calls rather than turns, which is the evidence the carry is
   read from. At the measured 6.7 calls per turn, 300 is about 45 turns --
   past the p90 re-use gap of 24. The curve is flat from 200 to 500 (17.0 to
   18.8 KB carried); below 200 the re-asks climb without buying carry, at 100
   costing 1,121 loads against 958 for 1.6 KB less held.

   0 places every tool the conversation has run, which is what shipped before
   this. Set it there if the fleet moves to models that all cache prompts: the
   saving here comes from the 58% of requests on models that cache nothing and
   so pay full price for every schema byte on every request.

   Sampled, not enforced continuously. The carry is measured against this
   window only on a call to a tool the carry does not already hold, because
   that is the call that changes the tool array and forfeits the provider's
   cache prefix anyway. Between two such calls the carried set is frozen, so a
   tool can sit further back than this and still be sent, and a Keeper that
   keeps re-using what it already carries evicts nothing until it reaches for
   something else. The sizing above comes from a replay of the earlier cut
   rule (cut at a name's first use in the conversation); the rule that ships
   cuts strictly more often, so those carried figures are an upper bound. *)
let keeper_tool_carry_window_rp =
  _rp_int ~key:"keeper.tool_search.carry_window"
    ~default:(fun () -> 300)
    ~min_v:0 ~max_v:100000
    ~description:
      "How far back a tool's last call may be and still be sent with its schema, in tool calls, measured when the conversation calls a tool it is not already carrying rather than between those calls (0 = every tool the conversation has run)" ()

let keeper_tool_carry_window () : int =
  Runtime_params.get keeper_tool_carry_window_rp
;;
