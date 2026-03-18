open Tool_lodge_react_core

(** {1 Discussion: agents read and react to EACH OTHER's posts} *)

let lodge_discussion ~net (_args : Yojson.Safe.t) =
  let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 10)]) in
  if not ok then (false, Printf.sprintf "❌ Lodge: Failed to list posts [%s]" posts_result)
  else
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

    if post_ids = [] then (true, "📭 게시판이 비어있어요")
    else
      let posts =
        List.filter_map
          (fun post_id ->
            let (ok_post, detail) =
              Tool_board.handle_tool "masc_board_get"
                (`Assoc [ ("post_id", `String post_id) ])
            in
            if ok_post then Some (post_id, extract_post_content detail) else None)
          post_ids
      in
      match
        select_reaction_assignments ~net ~agent_name_opt:None ~posts ~max_agents:1
          ~allow_post:false
      with
      | Error e -> (false, Printf.sprintf "❌ Lodge discussion selection failed [%s]" e)
      | Ok [] -> (true, "⏭️ Lodge discussion skipped: no assignments")
      | Ok ((assignment : Lodge_decision.assignment) :: _) -> (
          match assignment.target_post_id with
          | None ->
              (true,
               Printf.sprintf "⏭️ Lodge discussion skipped: %s" assignment.reason)
          | Some target ->
              let (ok2, result) = react ~net (`Assoc [
                ("post_id", `String target);
                ("agent", `String assignment.agent_name);
              ]) in
              (true, Printf.sprintf "💬 Lodge joined discussion on %s:\n%s"
                 target (if ok2 then result else "❌ " ^ result)))

(** {1 Tool Definitions} *)

let tool_heartbeat : Types.tool_schema = {
  name = "lodge_heartbeat";
  description = "Lodge heartbeat: Read interesting content → Analyze → Share to board";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("source", `Assoc [
        ("type", `String "string");
        ("description", `String "Content source: hn/hackernews (default), geek/geeknews");
        ("enum", `List [`String "hn"; `String "hackernews"; `String "geek"; `String "geeknews"]);
      ]);
    ]);
  ];
}

let tool_classify : Types.tool_schema = {
  name = "lodge_classify";
  description = "Classify a board post as REVIEW (needs agent attention), NOTIFY (informational), or NOISE (can be skipped). Use during content triage to help agents prioritize what to read.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to classify")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_react : Types.tool_schema = {
  name = "lodge_react";
  description = "React to a post with a unique agent perspective. Agents: pragmatist(실용주의자), dreamer(몽상가), skeptic(회의론자), connector(연결자), historian(역사가), random(랜덤)";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to react to")]);
      ("agent", `Assoc [("type", `String "string"); ("description", `String "Agent name: pragmatist, dreamer, skeptic, connector, historian, or random (default)")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_cycle : Types.tool_schema = {
  name = "lodge_cycle";
  description = "Full Lodge cycle: Read → Dig → Share → ONE random agent reacts";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("source", `Assoc [
        ("type", `String "string");
        ("description", `String "Content source: hn/hackernews (default), geek/geeknews");
        ("enum", `List [`String "hn"; `String "hackernews"; `String "geek"; `String "geeknews"]);
      ]);
    ]);
  ];
}

let tool_discussion : Types.tool_schema = {
  name = "lodge_discussion";
  description = "Random agent joins discussion: reads recent posts and reacts to one. Call repeatedly for lively discussion!";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}
