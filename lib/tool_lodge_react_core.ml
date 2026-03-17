open Tool_lodge_config_http
open Tool_lodge_llm_cycle
open Tool_lodge_agents_cache

(** {1 REACT: Dynamic agent system (Neo4j SSOT)}

    All agent data comes from Neo4j via GraphQL cache.
    No hardcoded agent enums — add new agents by MERGE into Neo4j.
*)

(** Get all cached agent names *)
let get_all_agent_names () =
  Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    Hashtbl.fold (fun k _ acc -> k :: acc) agent_cache [])

(** Pick a random agent name from cache *)
let random_agent_name () =
  let names = get_all_agent_names () in
  if names = [] then "dreamer"  (* fallback if cache empty — should not happen after startup *)
  else List.nth names (Random.int (List.length names))

(** Validate agent name exists in cache (replaces validate_agent_name) *)
let validate_agent_name name =
  if name = "random" || name = "랜덤" then None
  else match get_cached_agent name with
    | Some _ -> Some name
    | None ->
      (* Try Korean name lookup *)
      Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
        Hashtbl.fold (fun k v acc ->
          match acc with Some _ -> acc | None ->
          if v.korean_name = name then Some k else None
        ) agent_cache None)

(** Get model for agent (from Neo4j cache) *)
let get_agent_model name =
  match get_cached_agent name with
  | Some c -> c.model
  | None -> default_model ()

(** Get prompt from Neo4j cache *)
let get_agent_prompt name =
  match get_cached_agent name with
  | Some config ->
    (match config.prompt_template with
     | Some prompt -> prompt
     | None -> Printf.sprintf "You are %s." name)
  | None ->
    load_agents_config ();
    match get_cached_agent name with
    | Some config ->
      (match config.prompt_template with
       | Some prompt -> prompt
       | None -> Printf.sprintf "You are %s." name)
    | None ->
      Printf.sprintf "You are %s. (Not found in Neo4j)" name

(** Format agent name with emoji badge (from Neo4j cache) *)
let format_agent_name_dynamic name =
  match get_cached_agent name with
  | Some c -> Printf.sprintf "%s **%s** (%s)" c.emoji name c.korean_name
  | None -> Printf.sprintf "🤖 **%s**" name

(** Extract just the post content from formatted board output.
    Input format:
      **p-xxx** [visibility] (by author, time, TTL: ttl)
      ACTUAL CONTENT
      [↑N ↓N = +/-N] [N replies]
      ...
    Returns: just the ACTUAL CONTENT part *)
let extract_post_content formatted =
  try
    (* Split by newline *)
    let lines = String.split_on_char '\n' formatted in
    (* Skip first line (metadata), take lines until vote line *)
    let content_lines = List.filter (fun line ->
      not (String.length line > 0 && line.[0] = '*' && String.sub line 0 3 = "**p") &&  (* skip **p-xxx** line *)
      not (String.length line > 0 && line.[0] = '[' && String.sub line 0 2 = "[↑") &&   (* skip vote line *)
      not (String.length line > 3 && String.sub line 0 4 = "💬 *")                       (* skip comments header *)
    ) lines in
    (* Also filter out comment lines (start with spaces) *)
    let content_lines = List.filter (fun line ->
      String.length line = 0 || (String.length line > 0 && line.[0] <> ' ')
    ) content_lines in
    let result = String.trim (String.concat "\n" content_lines) in
    if result = "" then formatted else result  (* fallback to original if extraction fails *)
  with Invalid_argument _ | Not_found -> formatted

(** Translate text to Korean using CLI rotation.
    If translation fails or text is already Korean, returns original. *)
let translate_to_korean ~net text =
  (* Skip if already mostly Korean (simple heuristic: check for Hangul syllables) *)
  let korean_char_count = ref 0 in
  String.iter (fun c ->
    let code = Char.code c in
    (* Hangul syllables are in 0xAC00-0xD7AF range, but in UTF-8 they span multiple bytes *)
    (* Simple check: if byte is in 0xE0-0xEF range, might be Korean *)
    if code >= 0xE0 && code <= 0xEF then incr korean_char_count
  ) text;
  if !korean_char_count > 5 then text  (* Already has Korean *)
  else
    let system = "/no_think\nTranslate the following text to natural Korean. Output ONLY the Korean translation, nothing else. Keep it concise (2-4 sentences)." in
    match smart_generate ~net ~temperature:0.3 ~num_predict:300 ~system text with
    | Ok translated -> String.trim translated
    | Error _ -> text  (* fallback to original *)

type lodge_reaction_outcome =
  | Delegated of string
  | Completed of Lodge_worker.completion

let default_reaction_goal ?target_post_id ~allow_post () =
  match target_post_id, allow_post with
  | Some post_id, _ ->
      Printf.sprintf
        "Inspect board post %s, decide whether to comment, upvote, or skip, and use MASC tools directly to carry out the decision. Do not create a new top-level post."
        post_id
  | None, true ->
      "Inspect the provided board context and decide whether to write a new top-level post, comment on an existing post, upvote, or skip. Use MASC tools directly to carry out the decision."
  | None, false ->
      "Inspect the provided board context and decide whether to comment, upvote, or skip using MASC tools directly. Do not create a new top-level post."

let reaction_context posts =
  posts
  |> List.map (fun (post_id, content) ->
         Printf.sprintf "[target_post_id=%s]\n%s" post_id content)
  |> String.concat "\n\n"

let select_reaction_assignments ~net ~agent_name_opt ~posts ~max_agents ~allow_post
    : (Lodge_decision.assignment list, string) Stdlib.result =
  let candidate_post_ids = List.map fst posts in
  let explicit_agent =
    match agent_name_opt with
    | Some name -> validate_agent_name name
    | None -> None
  in
  match explicit_agent with
  | Some agent_name ->
      Ok
        [
          {
            Lodge_decision.agent_name;
            target_post_id =
              (match posts with
              | (post_id, _) :: _ -> Some post_id
              | [] -> None);
            goal =
              default_reaction_goal
                ?target_post_id:
                  (match posts with
                  | (post_id, _) :: _ -> Some post_id
                  | [] -> None)
                ~allow_post ();
            reason = "explicitly requested agent";
            confidence = 1.0;
          };
        ]
  | None ->
      let candidate_agents =
        get_all_agent_names ()
        |> List.map (fun name -> (name, get_agent_prompt name))
      in
      let prompt =
        Lodge_decision.selection_prompt ~agent_name:"lodge-orchestrator"
          ~candidate_agents
          ~posts:(List.map (fun (post_id, content) -> (post_id, "unknown", content)) posts)
          ~extra_context:
            (Some
               "Choose the best reacting agents for this board context. They should inspect the posts and use Lodge-safe MCP tools directly.")
          ~max_agents ~allow_post
      in
      let system =
        "/no_think\nReturn valid JSON only. Do not use markdown fences."
      in
      match smart_generate ~net ~temperature:0.2 ~num_predict:500 ~system prompt with
      | Error e -> Error e
      | Ok response -> (
          match
            Lodge_decision.parse_selection_plan
              ~allowed_agents:(List.map fst candidate_agents)
              ~allowed_post_ids:candidate_post_ids ~max_agents response
          with
          | Ok plan when plan.assignments <> [] -> Ok plan.assignments
          | Ok _ -> Error "selection returned no assignments"
          | Error e -> Error (Printf.sprintf "❌ Lodge selection: %s" e))

(** React to content with a dynamic agent (from Neo4j cache) *)
let react_to_content ~net ~agent_name_opt ~post_id content =
  match
    select_reaction_assignments ~net ~agent_name_opt
      ~posts:[ (post_id, content) ] ~max_agents:1 ~allow_post:false
  with
  | Error e -> Error e
  | Ok (assignment :: _) ->
      let agent_name = assignment.agent_name in
      let agent_desc = get_agent_prompt agent_name in
      let reaction_context = reaction_context [ (post_id, content) ] in
      let allowed_tools = Lodge_worker.allowed_tools ~allow_post:false () in
      if Env_config.LodgeV2.delegate_llm then begin
        A2a_tools.emit_heartbeat_task ~agent:agent_name ~goal:assignment.goal
          ~context:reaction_context ~allowed_tools
          ~decision_reason:assignment.reason
          ~decision_confidence:assignment.confidence ();
        Ok (Delegated agent_name)
      end else (
        match
          Lodge_worker.run_local ~agent_name ~identity_prompt:agent_desc
            ~goal:assignment.goal ~context:reaction_context ~allow_post:false ()
        with
        | Error e -> Error e
        | Ok completion ->
            let new_interests = extract_interests ~net content in
            let _ = save_interests_to_neo4j ~agent_name new_interests in
            Ok (Completed completion))
  | Ok [] -> Error "reaction selection returned no assignments"

(** {1 Heartbeat: Full Read → Dig → Share cycle} *)

let heartbeat ~net (args : Yojson.Safe.t) =
  let source_str = Safe_ops.json_string ~default:"hn" "source" args in
  let source = source_of_string source_str |> Option.value ~default:HackerNews in

  (* READ *)
  let read_result = match source with
    | HackerNews -> fetch_hn_article ~net
    | GeekNews -> fetch_geek_article ~net
  in
  match read_result with
  | Error e -> (false, Printf.sprintf "❌ Lodge: Read failed [%s]" e)
  | Ok article ->
    (* DIG — with Eio timeout *)
    match dig_article ~net article with
    | Error e -> (false, Printf.sprintf "❌ Lodge: Dig failed [article=%s, error=%s]" article.title e)
    | Ok analysis ->
      let content = Printf.sprintf
        "📖 **%s**\n🔗 %s\n\n%s\n\n---\n_Lodge Heartbeat · %s_"
        article.title article.url analysis (string_of_source article.source)
      in
      (* SHARE to board *)
      let escaped_content = content in
      let post_args = `Assoc [
        ("author", `String "lodge");
        ("content", `String escaped_content);
        ("category", `String "lodge");
        ("title", `String (Printf.sprintf "📖 %s" article.title));
      ] in
      let (success, msg) = Tool_board.handle_tool "masc_board_post" post_args in
      if success then begin
        (* Auto-react: enabled by default, disable with MASC_LODGE_AUTO_REACT=0 *)
        let auto_react_enabled = Sys.getenv_opt "MASC_LODGE_AUTO_REACT" |> Option.value ~default:"1" = "1" in
        let summary = if auto_react_enabled then begin
          (* Extract post_id for auto-react *)
          let post_id = try
            let re = Str.regexp "p-[a-f0-9]+" in
            ignore (Str.search_forward re msg 0);
            Str.matched_string msg
          with Not_found -> "" in
          (* Auto-trigger reactions from agents *)
          let reactions = if post_id <> "" then
            match
              select_reaction_assignments ~net ~agent_name_opt:None
                ~posts:[ (post_id, content) ] ~max_agents:2 ~allow_post:false
            with
            | Error _ -> []
            | Ok assignments ->
                List.filter_map
                  (fun (assignment : Lodge_decision.assignment) ->
                    match
                      react_to_content ~net ~agent_name_opt:(Some assignment.agent_name)
                        ~post_id content
                    with
                    | Error _ -> None
                    | Ok (Delegated agent) ->
                        Some (Printf.sprintf "🔮 %s (delegated)" agent)
                    | Ok (Completed completion) ->
                        Some
                          (Printf.sprintf "%s %s"
                             (match completion.status with
                             | Lodge_worker.Acted -> "🛠️"
                             | Lodge_worker.Skipped -> "⏭️"
                             | Lodge_worker.Failed -> "❌")
                             assignment.agent_name))
                  assignments
          else [] in
          match reactions with [] -> "" | rs -> "\n🎭 " ^ String.concat ", " rs
        end else "" in
        (true, Printf.sprintf "🏔️ Lodge shared: %s\n%s%s" article.title msg summary)
      end else
        (false, Printf.sprintf "❌ Lodge: Share failed [%s]" msg)

(** {1 Classify tool: classify a post} *)

let classify ~net (args : Yojson.Safe.t) =
  let post_id = Safe_ops.json_string ~default:"" "post_id" args in
  if post_id = "" then (false, "❌ Lodge: post_id required")
  else
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ Lodge: Board get failed [%s]" detail)
    else
      let clean_content = extract_post_content detail in
      let cls = classify_content ~net clean_content in
      let result = Printf.sprintf "🏷️ %s → %s (%s)" post_id (string_of_category cls.category) cls.details in
      (true, result)

(** {1 React tool: respond to a post with agent} *)

(** React to a post with agent

    When skip_classify=true, bypasses LLM classification and directly generates
    a reaction. This significantly speeds up the process by avoiding one LLM call. *)
let rec react ~net (args : Yojson.Safe.t) =
  let post_id_arg = Safe_ops.json_string ~default:"" "post_id" args in
  let agent_str = Safe_ops.json_string ~default:"random" "agent" args in
  let skip_classify = Safe_ops.json_bool ~default:true "skip_classify" args in
  let agent_name = validate_agent_name agent_str in
  if post_id_arg = "" then (false, "❌ Lodge: post_id required")
  else
    let post_id =
      if post_id_arg = "random" then begin
        let (ok, list_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("random", `Bool true); ("limit", `Int 10)]) in
        if ok then
          try
            let re = Str.regexp "p-[a-f0-9]+" in
            let _ = Str.search_forward re list_result 0 in
            Str.matched_string list_result
          with Not_found -> post_id_arg
        else post_id_arg
      end else post_id_arg
    in
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ Lodge: Board get failed [%s]" detail)
    else
      let clean_content = extract_post_content detail in
      if skip_classify then
      match react_to_content ~net ~agent_name_opt:agent_name ~post_id clean_content with
      | Error e ->
          (false,
           Printf.sprintf "❌ Lodge: React failed [agent=%s, error=%s]"
             (Option.value ~default:"auto" agent_name) e)
      | Ok (Delegated agent) ->
          (true, Printf.sprintf "🔮 Lodge reaction delegated for %s [agent=%s]" post_id agent)
      | Ok (Completed completion) -> (
          match completion.status with
          | Lodge_worker.Acted ->
              (true,
               Printf.sprintf "🛠️ Lodge worker acted on %s [agent=%s, tools=%s]"
                 post_id completion.worker_name
                 (if completion.tool_names = [] then "none"
                  else String.concat ", " completion.tool_names))
          | Lodge_worker.Skipped ->
              (true,
               Printf.sprintf "⏭️ %s skipped %s (%s)"
                 completion.worker_name post_id
                 completion.decision_reason)
          | Lodge_worker.Failed ->
              (false,
               Printf.sprintf "❌ Lodge worker failed [agent=%s, error=%s]"
                 completion.worker_name
                 (Option.value ~default:completion.summary completion.failure_reason)))
    else
      let cls = classify_content ~net clean_content in
      match cls.category with
      | Noise -> (true, Printf.sprintf "🔇 %s classified as NOISE — no reaction" post_id)
      | Notify -> (true, Printf.sprintf "⚠️ %s classified as NOTIFY — flagged for human" post_id)
      | Review ->
        react ~net (`Assoc [
          ("post_id", `String post_id);
          ("agent", `String (Option.value ~default:"random" agent_name));
          ("skip_classify", `Bool true);
        ])

(** {1 Full cycle: heartbeat + ONE random agent reacts} *)

let full_cycle ~net (args : Yojson.Safe.t) =
  (* Step 1: Heartbeat (Read → Dig → Share) *)
  let (ok, msg) = heartbeat ~net args in
  if not ok then (false, msg)
  else
    (* Extract post_id from heartbeat result *)
    let post_id =
      try
        let re = Str.regexp "p-[a-f0-9]+" in
        ignore (Str.search_forward re msg 0);
        Str.matched_string msg
      with Not_found -> ""
    in
    if post_id = "" then (true, Printf.sprintf "%s\n(no post_id found for reaction)" msg)
    else
      let (ok2, result) = react ~net (`Assoc [
        ("post_id", `String post_id);
        ("agent", `String "random");
      ]) in
      (true, Printf.sprintf "%s\n\n💬 Lodge reacted:\n%s"
        msg (if ok2 then result else "❌ " ^ result))

