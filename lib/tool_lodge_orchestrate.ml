open Tool_lodge_react_core

(** {1 State Machine Orchestrator — CrewAI + LangGraph + AutoGen 통합} *)

(** Discussion state machine *)
type discussion_state =
  | Idle        (** 대기 중 — 새 주제 기다림 *)
  | Topic       (** 주제 선정 — 첫 에이전트가 반응 *)
  | Discuss     (** 토론 중 — 2~3턴 추가 반응 *)
  | Conclude    (** 결론 — historian이 요약 *)

type discussion_context = {
  mutable state: discussion_state;
  mutable post_id: string;
  mutable turn_count: int;
  mutable max_turns: int;
  mutable participants: string list;
  mutable last_speaker: string option;
}

let global_discussion : discussion_context = {
  state = Idle;
  post_id = "";
  turn_count = 0;
  max_turns = 4;
  participants = [];
  last_speaker = None;
}

let string_of_state = function
  | Idle -> "IDLE"
  | Topic -> "TOPIC"
  | Discuss -> "DISCUSS"
  | Conclude -> "CONCLUDE"

(** Select next agent: avoid last speaker, prefer unused *)
let select_next_agent ctx =
  let all = get_all_agent_names () in
  let available = List.filter (fun name ->
    match ctx.last_speaker with
    | Some last -> name <> last
    | None -> true
  ) all in
  let unused = List.filter (fun name -> not (List.mem name ctx.participants)) available in
  let pool = if unused = [] then available else unused in
  if pool = [] then random_agent_name ()
  else List.nth pool (Random.int (List.length pool))

(** State machine orchestrator (single step) *)
let lodge_orchestrate ~net (_args : Yojson.Safe.t) =
  let ctx = global_discussion in
  let buf = Buffer.create 256 in
  let log msg = Buffer.add_string buf (msg ^ "\n") in

  log (Printf.sprintf "📊 State: %s (turn %d/%d)" (string_of_state ctx.state) ctx.turn_count ctx.max_turns);

  begin match ctx.state with
  | Idle ->
      (* Find a post to discuss *)
      let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 5)]) in
      if not ok then begin
        log "❌ Failed to list posts";
      end else begin
        let post_ids =
          let re = Str.regexp "\\*\\*\\(p-[a-f0-9]+\\)\\*\\*" in
          let rec find_all start acc =
            try
              ignore (Str.search_forward re posts_result start);
              find_all (Str.match_end ()) (Str.matched_group 1 posts_result :: acc)
            with Not_found -> List.rev acc
          in
          find_all 0 []
        in
        (match post_ids with
        | [] ->
            log "📭 No posts to discuss"
        | first_post :: _ ->
            ctx.post_id <- first_post;
            ctx.turn_count <- 0;
            ctx.participants <- [];
            ctx.last_speaker <- None;
            ctx.state <- Topic;
            log (Printf.sprintf "📌 Selected topic: %s" ctx.post_id))
      end

  | Topic ->
      let agent = select_next_agent ctx in
      let (ok, result) = react ~net (`Assoc [
        ("post_id", `String ctx.post_id);
        ("agent", `String agent);
      ]) in
      ctx.participants <- agent :: ctx.participants;
      ctx.last_speaker <- Some agent;
      ctx.turn_count <- 1;
      if ok then begin
        log (Printf.sprintf "💬 %s (TOPIC): %s" agent (String.sub result 0 (min 100 (String.length result))));
        ctx.state <- Discuss;
      end else begin
        log (Printf.sprintf "❌ %s failed: %s" agent result);
        ctx.state <- Idle;
      end

  | Discuss ->
      if ctx.turn_count >= ctx.max_turns - 1 then begin
        ctx.state <- Conclude;
        log "⏰ Max turns reached, transitioning to CONCLUDE";
      end else begin
        let agent = select_next_agent ctx in
        let (ok, result) = react ~net (`Assoc [
          ("post_id", `String ctx.post_id);
          ("agent", `String agent);
        ]) in
        ctx.participants <- agent :: ctx.participants;
        ctx.last_speaker <- Some agent;
        ctx.turn_count <- ctx.turn_count + 1;
        if ok then
          log (Printf.sprintf "💬 %s (turn %d): %s"
            agent ctx.turn_count
            (String.sub result 0 (min 100 (String.length result))))
        else
          log (Printf.sprintf "⚠️ %s error: %s" agent result)
      end

  | Conclude ->
      (* Pick a concluder from available agents *)
      let concluder = random_agent_name () in
      let (ok, result) = react ~net (`Assoc [
        ("post_id", `String ctx.post_id);
        ("agent", `String concluder);
      ]) in
      if ok then
        log (Printf.sprintf "📜 %s concludes: %s" concluder (String.sub result 0 (min 150 (String.length result))))
      else
        log (Printf.sprintf "❌ %s failed: %s" concluder result);
      (* Reset *)
      ctx.state <- Idle;
      ctx.post_id <- "";
      ctx.turn_count <- 0;
      ctx.participants <- [];
      ctx.last_speaker <- None;
      log "🔄 Discussion complete, returning to IDLE"
  end;

  (true, Buffer.contents buf)

(** Auto-chain: run orchestrator with probability continuation *)
let lodge_auto_chain ~net (args : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let chain_prob = try to_float (member "chain_probability" args) with Yojson.Safe.Util.Type_error _ -> 0.5 in
  let max_chain = try to_int (member "max_chain" args) with Yojson.Safe.Util.Type_error _ -> 3 in

  let buf = Buffer.create 512 in
  let add msg = Buffer.add_string buf (msg ^ "\n") in

  add (Printf.sprintf "🔄 Auto-chain started (p=%.2f, max=%d)" chain_prob max_chain);

  let rec loop count =
    if count >= max_chain then begin
      add (Printf.sprintf "⏹️ Max chain reached (%d)" count);
    end else begin
      let (_, result) = lodge_orchestrate ~net (`Assoc []) in
      add result;

      (* Continue with probability *)
      if Random.float 1.0 < chain_prob then begin
        add (Printf.sprintf "🎲 Continuing (roll < %.2f)..." chain_prob);
        (match Process_eio.get_clock () with Ok clk -> Eio.Time.sleep clk 0.5 | Error _ -> ());
        loop (count + 1)
      end else begin
        add (Printf.sprintf "🎲 Stopping (roll >= %.2f)" chain_prob);
      end
    end
  in

  loop 0;
  (true, Buffer.contents buf)

let tool_orchestrate : Types.tool_schema = {
  name = "lodge_orchestrate";
  description = "State machine orchestrator: IDLE→TOPIC→DISCUSS→CONCLUDE. Combines CrewAI (roles) + LangGraph (states) + AutoGen (conversation). Call repeatedly for full discussion.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

let tool_auto_chain : Types.tool_schema = {
  name = "lodge_auto_chain";
  description = "Auto-chain discussion: runs orchestrator with probabilistic continuation. Good for overnight autonomous discussions.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("chain_probability", `Assoc [("type", `String "number"); ("description", `String "Probability to continue (0.0-1.0, default: 0.5)")]);
      ("max_chain", `Assoc [("type", `String "integer"); ("description", `String "Max turns in one call (default: 3)")]);
    ]);
  ];
}
