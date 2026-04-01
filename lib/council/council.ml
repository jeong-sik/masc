(** Council - Unified API for MASC multi-agent governance

    통합 인터페이스:
    - Debate: 구조화된 토론 (파일 기반)
    - Consensus: 투표/합의 (파일 영속성 + 메모리 캐시)
    - Balance: 공정성 정책
    - Conversation: 영속적 대화 (파일 + Neo4j)

    @since MASC v2.6.0
*)

(** {1 Re-exports} *)

module Debate = Debate
module Consensus = Consensus
module Balance = Balance
module Executor = Executor
module Conversation = Conversation
module Governance_v2 = Governance_v2
module Loop_guard = Loop_guard
module Thread_persist = Thread_persist

(** {1 Types} *)

type agent_id = string

type council_config = {
  base_path: string;
}

type council_result = {
  success: bool;
  message: string;
  data: Yojson.Safe.t option;
}

let make_config ~base_path =
  Consensus.init ~base_path;
  { base_path }

(** {1 Debate API} *)

module DebateApi = struct
  (** Start a new debate on a topic *)
  let start ~config ~topic ~notify_fn ?context () =
    Debate.start_debate config.base_path ~topic ?context ~notify_fn ()

  (** Add an argument to an ongoing debate *)
  let add_argument ~config ~debate_id ~agent ~position ~content 
      ?(evidence=[]) ?(reply_to=None) ?(mentions=[]) ?(notify_fn=None) () =
    Debate.add_argument config.base_path ~debate_id ~agent ~position ~content 
      ~evidence ~reply_to ~mentions ~notify_fn ()

  (** Close a debate and get summary *)
  let close ~config ~debate_id =
    Debate.close_debate config.base_path ~debate_id

  (** List all debates *)
  let list_all ~config ?(status_filter=None) ?(limit=50) () =
    Debate.list_debates config.base_path ~status_filter ~limit ()

  (** Get a specific debate *)
  let get ~config ~debate_id =
    Debate.get_debate config.base_path ~debate_id

  (** Get debate status summary *)
  let status ~config ~debate_id =
    Debate.get_debate_status config.base_path ~debate_id
end

(** {1 Consensus API} *)

module ConsensusApi = struct
  (** Start a new voting session *)
  let start_vote ~topic ~initiator ?(quorum=2) ?(threshold=0.5) ?context () =
    Consensus.start_voting ~topic ~initiator ~quorum ~threshold ?context ()

  (** Cast a vote *)
  let cast ~session_id ~agent ~decision ~reason ?(archetype=None) ?(weight=1.0) () =
    Consensus.cast_vote ~session_id ~agent ~decision ~reason ~archetype ~weight ()

  (** Close voting and get result *)
  let close ~session_id =
    Consensus.close_session ~session_id

  (** Get voting result *)
  let result ~session_id =
    Consensus.get_result ~session_id

  (** Get session by ID *)
  let get ~session_id =
    Consensus.get_session ~session_id

  (** List active sessions *)
  let list_active () =
    Consensus.list_active_sessions ()

  (** List all sessions *)
  let list_all () =
    Consensus.list_all_sessions ()

  (** Cancel a session *)
  let cancel ~session_id =
    Consensus.cancel_session ~session_id
end

(** {1 Balance API} *)

module BalanceApi = struct
  (** Check if an agent is dominating *)
  let check_dominance ~agent_stats ~total_rounds =
    Balance.check_dominance ~agent_stats ~total_rounds

  (** Determine balance action needed *)
  let determine_action ~agent_stats ~total_rounds ~is_winner =
    Balance.determine_action ~agent_stats ~total_rounds ~is_winner

  (** Get participation rate *)
  let participation_rate ~agent_stats ~total_rounds =
    Balance.get_participation_rate ~agent_stats ~total_rounds

  (** Create empty stats *)
  let empty_stats () =
    Balance.empty_stats ()
end

(** {1 Executor API} *)

module ExecutorApi = struct
  (** Execute a decision based on voting result *)
  let execute ~topic ~result =
    Executor.execute_decision ~topic ~result

  (** Dry run - show what would happen *)
  let dry_run ~topic ~result =
    Executor.dry_run ~topic ~result

  (** Find matching action for a topic *)
  let find_action topic =
    Executor.find_action topic
end

(** {1 Conversation API} *)

module ConversationApi = struct
  (** Start a new conversation thread *)
  let start ~config ~topic ~initiator ?max_turns ?initial_content () =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";  (* Can be parameterized *)
    } in
    Conversation.start ~config:convo_config ~topic ~initiator ?max_turns ?initial_content ()

  (** Reply to a thread *)
  let reply ~config ~thread_id ~speaker ~content ?confidence ?reply_to ?mentions () =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";
    } in
    (* Check loop guard *)
    match Conversation.get ~config:convo_config ~thread_id with
    | None -> Error (Printf.sprintf "Thread not found: %s" thread_id)
    | Some thread ->
        let loop_check = Loop_guard.check
          ~thread ~speaker ~content
          ~config:Loop_guard.default_config
        in
        match Loop_guard.to_error_message loop_check with
        | Some err -> Error err
        | None ->
            Conversation.reply ~config:convo_config ~thread_id ~speaker ~content
              ?confidence ?reply_to ?mentions ()

  (** Conclude a thread *)
  let conclude ~config ~thread_id ~concluder ~conclusion () =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";
    } in
    Conversation.conclude ~config:convo_config ~thread_id ~concluder ~conclusion ()

  (** Get a thread by ID *)
  let get ~config ~thread_id =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";
    } in
    Conversation.get ~config:convo_config ~thread_id

  (** List active threads *)
  let list_active ~config =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";
    } in
    Conversation.list_active ~config:convo_config

  (** Sync all threads to Neo4j *)
  let sync_neo4j ~config =
    let convo_config : Conversation.config = {
      base_path = config.base_path;
      room = "default";
    } in
    Thread_persist.sync_all ~config:convo_config
end

(** {1 High-level Orchestration} *)

(** Run a full debate-to-vote cycle *)
let run_cycle ~config ~topic ~initiator ~quorum ~threshold ~notify_fn =
  (* 1. Start debate *)
  match DebateApi.start ~config ~topic ~notify_fn () with
  | Error e -> Error (Printf.sprintf "Failed to start debate: %s" e)
  | Ok debate ->
    let debate_id = debate.Debate.id in
    (* 2. Start voting session *)
    (match ConsensusApi.start_vote ~topic ~initiator ~quorum ~threshold () with
    | Error e -> 
      let msg = match e with
        | Consensus.Session_not_found id -> Printf.sprintf "Session not found: %s" id
        | Consensus.Session_closed id -> Printf.sprintf "Session closed: %s" id
        | Consensus.Already_voted agent -> Printf.sprintf "Already voted: %s" agent
        | Consensus.Quorum_not_met { required; current } -> 
          Printf.sprintf "Quorum not met: %d/%d" current required
        | Consensus.Invalid_threshold t -> Printf.sprintf "Invalid threshold: %f" t
        | Consensus.Persistence_failed msg -> Printf.sprintf "Persistence failed: %s" msg
      in
      Error (Printf.sprintf "Failed to start vote: %s" msg)
    | Ok session ->
      Ok {
        success = true;
        message = Printf.sprintf "Cycle started: debate=%s, vote=%s" debate_id session.Consensus.id;
        data = Some (`Assoc [
          ("debate_id", `String debate_id);
          ("vote_session_id", `String session.Consensus.id);
          ("topic", `String topic);
        ]);
      })

(** Quick vote without debate *)
let quick_vote ~topic ~initiator ~votes =
  let quorum = List.length votes in
  let threshold = 0.5 in
  match ConsensusApi.start_vote ~topic ~initiator ~quorum ~threshold () with
  | Error _ as e -> e
  | Ok session ->
    let session_id = session.Consensus.id in
    (* Cast all votes *)
    let rec cast_all = function
      | [] -> Ok ()
      | (agent, decision, reason) :: rest ->
        match ConsensusApi.cast ~session_id ~agent ~decision ~reason () with
        | Error _ as e -> e
        | Ok _ -> cast_all rest
    in
    match cast_all votes with
    | Error _ as e -> e
    | Ok () ->
      ConsensusApi.close ~session_id

(** {1 Status & Health} *)

let status ~config =
  let debates = DebateApi.list_all ~config () in
  let active_votes = ConsensusApi.list_active () in
  let active_threads = ConversationApi.list_active ~config in
  `Assoc [
    ("version", `String "2.11.0");
    ("modules", `List [
      `String "debate";
      `String "consensus";
      `String "router";
      `String "archive";
      `String "balance";
      `String "conversation";
    ]);
    ("active_debates", `Int (List.length debates));
    ("active_votes", `Int (List.length active_votes));
    ("active_threads", `Int (List.length active_threads));
  ]

(** Version info *)
let version = "2.11.0"
