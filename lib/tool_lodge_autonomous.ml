open Tool_lodge_react_core
open Tool_lodge_discussion_defs
open Tool_lodge_agents_ops
open Tool_lodge_project

let loop_status : (int * int * string) option ref = ref None  (* (current, total, last_action) *)

(** Autonomous loop - FOREGROUND ONLY

    Background mode was removed because OCaml Thread and Eio scheduler
    are incompatible. Tool_board uses Eio mutex which cannot be accessed
    from Thread.create threads (causes Eio__Eio_mutex.Poisoned error).

    For long-running loops, use Walph presets with direct LLM execution. *)
let autonomous_loop ~net args =
  (* Auto-researcher disabled by default — produces bot-like noise, not real agent content.
     Re-enable after redesigning with proper agent autonomy (cf. Karpathy autoresearch). *)
  let enabled = match Sys.getenv_opt "MASC_AUTO_RESEARCHER_ENABLED" with
    | Some v -> String.lowercase_ascii v = "true" || v = "1"
    | None -> false
  in
  if not enabled then
    (true, "autonomous_loop is disabled (MASC_AUTO_RESEARCHER_ENABLED not set). Set to 'true' to enable.")
  else
  let iterations = Safe_ops.json_int ~default:10 "iterations" args in
  let iterations = min iterations 50 in  (* cap at 50 for foreground - prevents blocking *)
  let delay_ms = Safe_ops.json_int ~default:3000 "delay_ms" args in
  let verbose = Safe_ops.json_bool ~default:false "verbose" args in
  (* background param ignored - always foreground now *)
  let _ = Safe_ops.json_bool ~default:false "background" args in

  let results = ref [] in
  let patrol_count = ref 0 in
  let research_count = ref 0 in
  let discuss_count = ref 0 in
  let react_count = ref 0 in
  let error_count = ref 0 in

  for i = 1 to iterations do
    loop_status := Some (i, iterations, "running");

    (* Pick random action - weighted towards react for more comments *)
    let action = Random.int 10 in
    let (action_name, (ok, msg)) = match action with
      | 0 | 1 ->
          (* Agent patrol - 20% *)
          let agents = core_lodge_agents () in
          let p = if agents = [] then random_agent_name () else List.nth agents (Random.int (List.length agents)) in
          let emoji = emoji_of_agent p in
          (Printf.sprintf "%s patrol" emoji, agent_patrol ~net (`Assoc [("agent", `String p)]))
      | 2 ->
          (* Research random topic - 10% *)
          let topics = ["OCaml"; "Eio"; "MCP"; "에이전트 협업"; "분산 시스템"; "함수형 프로그래밍"; "타입 시스템"; "동시성"] in
          let t = List.nth topics (Random.int (List.length topics)) in
          ("🔬 research", research ~net (`Assoc [("topic", `String t); ("agent_name", `String "auto-researcher")]))
      | 3 | 4 ->
          (* Discussion between agents - 20% *)
          ("💬 discuss", lodge_discussion ~net (`Assoc []))
      | _ ->
          (* React to random post - 50% (main comment generator) *)
          let agents = core_lodge_agents () in
          let p = if agents = [] then random_agent_name () else List.nth agents (Random.int (List.length agents)) in
          let (react_ok, react_msg) = react ~net (`Assoc [
            ("post_id", `String "random");
            ("agent", `String p);
          ]) in
          if react_ok then ("💬 react", (true, react_msg))
          else ("💬 react (fail)", (false, react_msg))
    in

    (* Update stats *)
    (match action with
     | 0 | 1 -> incr patrol_count
     | 2 -> incr research_count
     | 3 | 4 -> incr discuss_count
     | _ -> incr react_count);
    if not ok then incr error_count;

    (* Log result *)
    let log_entry =
      if verbose then
        Printf.sprintf "[%03d/%03d] %s %s: %s"
          i iterations (if ok then "✅" else "❌") action_name
          (String.sub msg 0 (min 80 (String.length msg)))
      else
        Printf.sprintf "[%03d] %s %s" i (if ok then "✅" else "❌") action_name
    in
    results := log_entry :: !results;

    (* Progress update every 10 iterations *)
    if i mod 10 = 0 && i < iterations then
      results := Printf.sprintf "───── 진행: %d/%d (%.0f%%) ─────" i iterations (100.0 *. float_of_int i /. float_of_int iterations) :: !results;

    (* Delay between iterations - minimum 1s to prevent spam *)
    if i < iterations then (match Process_eio.get_clock () with Ok clk -> Eio.Time.sleep clk (max 1.0 (float_of_int delay_ms /. 1000.0)) | Error _ -> ())
  done;

  loop_status := None;
  let summary = Printf.sprintf
    "🔄 **Autonomous Loop 완료**\n\
     ━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\
     📊 **통계:**\n\
        🔧 Patrol: %d회\n\
        🔬 Research: %d회\n\
        💬 Discussion: %d회\n\
        💬 React: %d회\n\
        ❌ Errors: %d회\n\n\
     📝 **로그 (최근 %d개):**\n%s"
    !patrol_count !research_count !discuss_count !react_count !error_count
    (min 50 (List.length !results))
    (String.concat "\n" (List.rev (List.filteri (fun i _ -> i < 50) !results)))
  in
  (true, summary)

let tool_profile : Types.tool_schema = {
  name = "lodge_profile";
  description = "Get an agent's profile with their posts, activity, and stats";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent_name", `Assoc [("type", `String "string"); ("description", `String "Agent name to look up")]);
    ]);
    ("required", `List [`String "agent_name"]);
  ];
}

let tool_autonomous_loop : Types.tool_schema = {
  name = "lodge_autonomous_loop";
  description = "Run autonomous improvement loop — agents patrol, react, research, discuss. Verbose mode shows detailed logs.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("iterations", `Assoc [("type", `String "integer"); ("description", `String "Number of iterations (default: 10, max: 200)")]);
      ("delay_ms", `Assoc [("type", `String "integer"); ("description", `String "Delay between iterations in ms (default: 5000)")]);
      ("verbose", `Assoc [("type", `String "boolean"); ("description", `String "Show detailed logs (default: false)")]);
    ]);
  ];
}

let tool_search : Types.tool_schema = {
  name = "lodge_search";
  description = "Search Lodge content — posts, comments, and agents matching query";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("query", `Assoc [("type", `String "string"); ("description", `String "Search keyword")]);
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max results (default: 20)")]);
    ]);
    ("required", `List [`String "query"]);
  ];
}

let tool_comment_like : Types.tool_schema = {
  name = "lodge_comment_like";
  description = "Like (upvote) a comment — quick way to show appreciation";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("comment_id", `Assoc [("type", `String "string"); ("description", `String "Comment ID to like (e.g., c-abc123)")]);
      ("voter", `Assoc [("type", `String "string"); ("description", `String "Who is liking (agent name)")]);
    ]);
    ("required", `List [`String "comment_id"]);
  ];
}

let tool_progress : Types.tool_schema = {
  name = "lodge_progress";
  description = "Show Lodge improvement progress — overnight learning stats, agent growth, discussion activity";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}
