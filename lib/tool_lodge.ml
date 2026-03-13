type result = Tool_lodge_config_http.result

let init = Tool_lodge_agents_cache.init
let load_agents_config = Tool_lodge_agents_cache.load_agents_config
let get_all_agents = Tool_lodge_agents_ops.get_all_agents
let autonomous_loop = Tool_lodge_autonomous.autonomous_loop

let tools = [
  Tool_lodge_discussion_defs.tool_heartbeat;
  Tool_lodge_discussion_defs.tool_classify;
  Tool_lodge_discussion_defs.tool_react;
  Tool_lodge_discussion_defs.tool_cycle;
  Tool_lodge_discussion_defs.tool_discussion;
  Tool_lodge_orchestrate.tool_orchestrate;
  Tool_lodge_orchestrate.tool_auto_chain;
  Tool_lodge_agents_ops.tool_evolve;
  Tool_lodge_agents_ops.tool_spawn;
  Tool_lodge_agents_ops.tool_agents;
  Tool_lodge_agents_ops.tool_agent_patrol;
  Tool_lodge_project.tool_propose_project;
  Tool_lodge_project.tool_join_project;
  Tool_lodge_project.tool_share_code;
  Tool_lodge_project.tool_research;
  Tool_lodge_autonomous.tool_profile;
  Tool_lodge_autonomous.tool_autonomous_loop;
  Tool_lodge_autonomous.tool_search;
  Tool_lodge_autonomous.tool_comment_like;
  Tool_lodge_autonomous.tool_progress;
]

let handle_tool ~net name args =
  match name with
  | "lodge_heartbeat" -> Tool_lodge_react_core.heartbeat ~net args
  | "lodge_classify" -> Tool_lodge_react_core.classify ~net args
  | "lodge_react" -> Tool_lodge_react_core.react ~net args
  | "lodge_cycle" -> Tool_lodge_react_core.full_cycle ~net args
  | "lodge_discussion" -> Tool_lodge_discussion_defs.lodge_discussion ~net args
  | "lodge_orchestrate" -> Tool_lodge_orchestrate.lodge_orchestrate ~net args
  | "lodge_auto_chain" -> Tool_lodge_orchestrate.lodge_auto_chain ~net args
  | "lodge_evolve" -> Tool_lodge_agents_ops.evolve ~net args
  | "lodge_spawn" -> Tool_lodge_agents_ops.spawn ~net args
  | "lodge_agents" -> Tool_lodge_agents_ops.list_agents ~net args
  | "lodge_agent_patrol" -> Tool_lodge_agents_ops.agent_patrol ~net args
  | "lodge_propose_project" -> Tool_lodge_project.propose_project ~net args
  | "lodge_join_project" -> Tool_lodge_project.join_project ~net args
  | "lodge_share_code" -> Tool_lodge_project.share_code ~net args
  | "lodge_research" -> Tool_lodge_project.research ~net args
  | "lodge_profile" -> Tool_lodge_project.get_profile ~net args
  | "lodge_autonomous_loop" -> Tool_lodge_autonomous.autonomous_loop ~net args
  | "lodge_search" -> Tool_lodge_project.lodge_search ~net args
  | "lodge_comment_like" -> Tool_lodge_project.lodge_comment_like ~net args
  | "lodge_progress" -> Tool_lodge_project.lodge_progress ~net args
  | _ -> (false, Printf.sprintf "Unknown lodge tool: %s" name)
