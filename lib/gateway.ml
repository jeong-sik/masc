(** Gateway - Intelligent Agent Routing

    Routes messages to the best-fit agent based on:
    1. @mention → Direct routing to specific agent
    2. Capability matching → Route based on skills (coding, review, search)
    3. Load balancing → Pick least busy agent with matching capabilities

    OpenClaw-inspired patterns for efficient multi-agent coordination.
*)

(** {1 Types} *)

(** Routing decision *)
type route_decision =
  | Direct of string          (** Route to specific agent *)
  | Capability of string list (** Route to agents with these capabilities *)
  | Broadcast                 (** Send to all agents *)
  | No_route                  (** No suitable target found *)

(** Routing result *)
type route_result = {
  decision: route_decision;
  targets: string list;       (** Resolved agent names *)
  reason: string;             (** Why this routing was chosen *)
}

(** {1 Capability Mapping} *)

(** Map keywords to capabilities *)
let keyword_to_capability = [
  (* Coding keywords *)
  ("code", "coding");
  ("implement", "coding");
  ("fix", "coding");
  ("bug", "coding");
  ("feature", "coding");
  ("refactor", "coding");

  (* Review keywords *)
  ("review", "review");
  ("pr", "review");
  ("check", "review");
  ("approve", "review");

  (* Search keywords *)
  ("search", "search");
  ("find", "search");
  ("lookup", "search");
  ("query", "search");

  (* Documentation keywords *)
  ("doc", "documentation");
  ("explain", "documentation");
  ("document", "documentation");

  (* Testing keywords *)
  ("test", "testing");
  ("coverage", "testing");
  ("spec", "testing");
]

(** Default capabilities by agent type *)
let default_capabilities = [
  ("claude", ["coding"; "review"; "documentation"; "analysis"]);
  ("codex", ["coding"; "review"; "testing"]);
  ("gemini", ["search"; "analysis"; "documentation"]);
  ("ollama", ["coding"; "review"]);
]

(** Get capabilities for agent type (reserved for future spawn integration) *)
let _capabilities_for_type agent_type =
  match List.assoc_opt agent_type default_capabilities with
  | Some caps -> caps
  | None -> ["general"]

(** {1 Routing Logic} *)

(** Extract capabilities from message content *)
let extract_capabilities_from_content content =
  let content_lower = String.lowercase_ascii content in
  keyword_to_capability
  |> List.filter_map (fun (keyword, cap) ->
      if String.length content_lower >= String.length keyword then
        try
          let _ = Str.search_forward (Str.regexp_string keyword) content_lower 0 in
          Some cap
        with Not_found -> None
      else None
    )
  |> List.sort_uniq compare

(** Find agents with matching capabilities *)
let find_agents_with_capabilities (agents : Types.agent list) capabilities =
  List.filter_map (fun (agent : Types.agent) ->
    if List.exists (fun cap -> List.mem cap agent.capabilities) capabilities
    then Some agent.name
    else None
  ) agents

(** Find least busy agent from list *)
let find_least_busy (agents : Types.agent list) names =
  let matching = List.filter (fun (a : Types.agent) -> List.mem a.name names) agents in
  let status_rank (s : Types.agent_status) = match s with
    | Types.Active -> 0
    | Types.Listening -> 1
    | Types.Busy -> 2
    | Types.Inactive -> 3
  in
  let sorted = List.sort (fun (a : Types.agent) (b : Types.agent) ->
    compare (status_rank a.status) (status_rank b.status)
  ) matching in
  match sorted with
  | [] -> None
  | agent :: _ -> Some agent.name

(** Main routing function *)
let route ~(agents : Types.agent list) ~content : route_result =
  let get_name (a : Types.agent) = a.name in
  let all_names () = List.map get_name agents in

  (* 1. Check for @mention *)
  match Mention.parse content with
  | Mention.Stateless target ->
      let targets =
        if List.exists (fun (a : Types.agent) -> a.name = target) agents
        then [target]
        else []
      in
      { decision = Direct target;
        targets;
        reason = Printf.sprintf "@%s mention" target }

  | Mention.Stateful agent_type ->
      (* Find all agents of this type *)
      let type_agents = List.filter (fun (a : Types.agent) ->
        Mention.agent_type_of_mention a.name = agent_type
      ) agents in
      let names = List.map get_name type_agents in
      let best = find_least_busy agents names in
      { decision = Direct agent_type;
        targets = (match best with Some n -> [n] | None -> names);
        reason = Printf.sprintf "@%s type (best-fit selection)" agent_type }

  | Mention.Broadcast agent_type ->
      (* Find all agents of this type for broadcast *)
      let type_agents = List.filter (fun (a : Types.agent) ->
        Mention.agent_type_of_mention a.name = agent_type
      ) agents in
      let names = List.map get_name type_agents in
      { decision = Broadcast;
        targets = names;
        reason = Printf.sprintf "@@%s broadcast" agent_type }

  | Mention.None ->
      (* 2. Try capability-based routing *)
      let capabilities = extract_capabilities_from_content content in
      if capabilities = [] then
        { decision = Broadcast;
          targets = all_names ();
          reason = "no specific target, broadcasting" }
      else
        let matching = find_agents_with_capabilities agents capabilities in
        match matching with
        | [] ->
            { decision = Capability capabilities;
              targets = all_names ();
              reason = Printf.sprintf "no agents with [%s], broadcasting"
                (String.concat ", " capabilities) }
        | names ->
            let best = find_least_busy agents names in
            { decision = Capability capabilities;
              targets = (match best with Some n -> [n] | None -> names);
              reason = Printf.sprintf "capability match [%s]"
                (String.concat ", " capabilities) }

(** {1 Formatting} *)

let decision_to_string = function
  | Direct agent -> Printf.sprintf "direct:%s" agent
  | Capability caps -> Printf.sprintf "capability:[%s]" (String.concat "," caps)
  | Broadcast -> "broadcast"
  | No_route -> "no_route"

let result_to_json result =
  `Assoc [
    ("decision", `String (decision_to_string result.decision));
    ("targets", `List (List.map (fun t -> `String t) result.targets));
    ("reason", `String result.reason);
  ]
