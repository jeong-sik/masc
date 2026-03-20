(** Chain Mermaid Graph — edge parsing, graph parsing, mermaid-to-chain conversion *)

open Chain_types
include Chain_mermaid_node_content

(** Parse edge line: A --> B or A & B --> C or A -->|label| B *)
let parse_edge_line (line : string) : mermaid_edge list =
  let line = trim line in

  (* Extract label from arrow if present: -->|label| becomes (-->, Some label) *)
  let extract_label_and_split s =
    (* Check for labeled edge pattern: A -->|label| B *)
    (* Use string search instead of complex regex to avoid Str.regexp | escaping issues *)
    match String.split_on_char '|' s with
    | [before_pipe; label_part; after_pipe] when String.length before_pipe > 0 ->
        (* Check if before_pipe ends with --> *)
        let before_trimmed = trim before_pipe in
        if String.length before_trimmed >= 3 &&
           String.sub before_trimmed (String.length before_trimmed - 3) 3 = "-->" then
          let from_part = String.sub before_trimmed 0 (String.length before_trimmed - 3) in
          (trim from_part, trim after_pipe, Some (trim label_part))
        else
          (* No --> before |, try simple arrow pattern *)
          (try
            if Str.string_match (Str.regexp {|^\([^-]*\)-->\(.*\)$|}) s 0 then
              let from_part = Str.matched_group 1 s in
              let to_part = Str.matched_group 2 s in
              (trim from_part, trim to_part, None)
            else
              (s, "", None)
          with Not_found -> (s, "", None))
    | _ ->
        (* Try pattern: A --> B (no label) *)
        (try
          if Str.string_match (Str.regexp {|^\([^-]*\)-->\(.*\)$|}) s 0 then
            let from_part = Str.matched_group 1 s in
            let to_part = Str.matched_group 2 s in
            (trim from_part, trim to_part, None)
          else
            (s, "", None)
        with Not_found -> (s, "", None))
  in

  let (from_part, to_part, label) = extract_label_and_split line in

  (* Check if to_part contains another --> (chained arrows like A --> B --> C) *)
  let has_chained_arrows =
    to_part <> "" &&
    (try let _ = Str.search_forward (Str.regexp "-->") to_part 0 in true
     with Not_found -> false)
  in

  if to_part = "" || has_chained_arrows then
    (* Fall back to original logic for complex multi-arrow lines *)
    let parts = Str.split arrow_re line in
    let rec build_edges acc = function
      | [] | [_] -> List.rev acc
      | from_part :: to_part :: rest ->
          let from_nodes =
            from_part
            |> Str.split ampersand_re
            |> List.map (fun s ->
                let s = trim s in
                match parse_node_definition s with
                | Some (id, _) -> id
                | None -> s)
          in
          let to_node =
            let s = trim to_part in
            match parse_node_definition s with
            | Some (id, _) -> id
            | None -> s
          in
          let edge = { from_nodes; to_node; label = None } in
          build_edges (edge :: acc) (to_part :: rest)
    in
    build_edges [] parts
  else
    (* Single labeled edge *)
    let from_nodes =
      from_part
      |> Str.split ampersand_re
      |> List.map (fun s ->
          let s = trim s in
          match parse_node_definition s with
          | Some (id, _) -> id
          | None -> s)
    in
    let to_node =
      match parse_node_definition to_part with
      | Some (id, _) -> id
      | None -> to_part
    in
    [{ from_nodes; to_node; label }]

(** Join lines that have unclosed brackets (handle multiline node content) *)
(* Parse state: (bracket_count, in_double_quote, in_single_quote) *)
let join_multiline_brackets (lines : string list) : string list =
  (* Update state by scanning a string, carrying over quote state *)
  let scan_string s (count, in_double, in_single) =
    let len = String.length s in
    let rec loop i count in_double in_single =
      if i >= len then (count, in_double, in_single)
      else
        let c = s.[i] in
        (* Handle escape: skip next char *)
        if c = '\\' && i + 1 < len then
          loop (i + 2) count in_double in_single
        (* Toggle double quote state (only if not in single) *)
        else if c = '"' && not in_single then
          loop (i + 1) count (not in_double) in_single
        (* Toggle single quote state (only if not in double) *)
        else if c = '\'' && not in_double then
          loop (i + 1) count in_double (not in_single)
        (* Count brackets only when not in any quoted string *)
        else if not in_double && not in_single then
          match c with
          | '[' -> loop (i + 1) (count + 1) in_double in_single
          | ']' -> loop (i + 1) (count - 1) in_double in_single
          | '{' -> loop (i + 1) (count + 1) in_double in_single
          | '}' -> loop (i + 1) (count - 1) in_double in_single
          | _ -> loop (i + 1) count in_double in_single
        else
          loop (i + 1) count in_double in_single
    in
    loop 0 count in_double in_single
  in

  let initial_state = (0, false, false) in

  let is_closed (count, in_double, in_single) =
    count <= 0 && not in_double && not in_single
  in

  let is_open (count, in_double, in_single) =
    count > 0 || in_double || in_single
  in

  let rec process acc pending_lines state = function
    | [] ->
        (* Flush any remaining pending lines *)
        if pending_lines = [] then List.rev acc
        else List.rev ((String.concat " " (List.rev pending_lines)) :: acc)
    | line :: rest ->
        let line = trim line in
        if line = "" then
          process acc pending_lines state rest
        else if is_open state then begin
          (* Continue collecting multiline content (unclosed brackets or quotes) *)
          let new_state = scan_string line state in
          let new_pending = line :: pending_lines in
          if is_closed new_state then
            (* All closed, flush the joined line *)
            let joined = String.concat " " (List.rev new_pending) in
            process (joined :: acc) [] initial_state rest
          else
            process acc new_pending new_state rest
        end
        else begin
          (* Check if this line opens unclosed brackets or quotes *)
          let new_state = scan_string line initial_state in
          if is_open new_state then
            (* Line has unclosed brackets/quotes, start collecting *)
            process acc [line] new_state rest
          else
            (* Normal complete line *)
            process (line :: acc) [] initial_state rest
        end
  in
  process [] [] initial_state lines

(** Parse full Mermaid graph text *)
(** Parse Mermaid text with metadata extraction (for lossless roundtrip) *)
let parse_mermaid_text_with_meta (text : string) : ((mermaid_graph * mermaid_meta), string) result =
  (* First join multiline bracket content *)
  let raw_lines = String.split_on_char '\n' text |> List.map trim in
  let lines = join_multiline_brackets raw_lines in

  (* Find graph direction *)
  let direction = ref "LR" in
  let nodes = Hashtbl.create 16 in
  let edges = ref [] in
  let meta = ref (empty_meta ()) in

  List.iter (fun line ->
    let line = trim line in
    (* Handle comments - extract metadata first, then skip *)
    if line = "" then ()
    else if String.length line > 0 && line.[0] = '%' then begin
      (* Try to extract metadata from comment *)
      meta := parse_meta_comment line !meta
    end
    (* Parse graph direction *)
    else if String.length line >= 5 && String.sub line 0 5 = "graph" then begin
      let rest = trim (String.sub line 5 (String.length line - 5)) in
      if rest <> "" then direction := rest
    end
    else if String.length line >= 9 && String.sub line 0 9 = "flowchart" then begin
      let rest = trim (String.sub line 9 (String.length line - 9)) in
      if rest <> "" then direction := rest
    end
    (* Skip subgraph/end for now *)
    else if String.length line >= 8 && String.sub line 0 8 = "subgraph" then ()
    else if line = "end" then ()
    (* Parse edges and collect nodes *)
    else begin
      (* Extract all node definitions from the line *)
      let parts = Str.split arrow_re line in
      List.iter (fun part ->
        let part = trim part in
        (* Split by & for multiple nodes *)
        let sub_parts = Str.split ampersand_re part in
        List.iter (fun sub ->
          match parse_node_definition (trim sub) with
          | Some (id, node) -> Hashtbl.replace nodes id node
          | None -> ()
        ) sub_parts
      ) parts;
      (* Parse edges *)
      let new_edges = parse_edge_line line in
      edges := !edges @ new_edges
    end
  ) lines;

  Ok ({
    direction = !direction;
    nodes = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [];
    edges = !edges;
  }, !meta)

(** Parse full Mermaid graph text (backward compatible, discards metadata) *)
let parse_mermaid_text (text : string) : (mermaid_graph, string) result =
  match parse_mermaid_text_with_meta text with
  | Ok (graph, _meta) -> Ok graph
  | Error e -> Error e

(** Build dependency graph from edges (incoming: to_node -> [from_nodes]) *)
let build_dependency_graph (edges : mermaid_edge list) : (string, string list) Hashtbl.t =
  let deps = Hashtbl.create 16 in
  List.iter (fun edge ->
    let existing =
      match Hashtbl.find_opt deps edge.to_node with
      | Some l -> l
      | None -> []
    in
    Hashtbl.replace deps edge.to_node (existing @ edge.from_nodes)
  ) edges;
  deps

(** Build outgoing edges map with labels (from_node -> [(to_node, label option)]) *)
let build_outgoing_edges (edges : mermaid_edge list) : (string, (string * string option) list) Hashtbl.t =
  let outgoing = Hashtbl.create 16 in
  List.iter (fun edge ->
    List.iter (fun from_node ->
      let existing =
        match Hashtbl.find_opt outgoing from_node with
        | Some l -> l
        | None -> []
      in
      Hashtbl.replace outgoing from_node (existing @ [(edge.to_node, edge.label)])
    ) edge.from_nodes
  ) edges;
  outgoing

(** Find nodes with no outgoing edges (terminal nodes) *)
let find_output_nodes (graph : mermaid_graph) : string list =
  let has_outgoing = Hashtbl.create 16 in
  List.iter (fun edge ->
    List.iter (fun from_node ->
      Hashtbl.replace has_outgoing from_node true
    ) edge.from_nodes
  ) graph.edges;

  graph.nodes
  |> List.filter (fun node -> not (Hashtbl.mem has_outgoing node.id))
  |> List.map (fun node -> node.id)

(** Convert Mermaid graph to Chain AST *)
let mermaid_to_chain ?(id = "mermaid_chain") (graph : mermaid_graph) : (chain, string) result =
  let deps = build_dependency_graph graph.edges in

  (* Convert each mermaid node to chain node *)
  let node_map = Hashtbl.create 16 in

  let convert_result = ref (Ok ()) in

  List.iter (fun mnode ->
    match !convert_result with
    | Error _ -> ()
    | Ok () ->
        (* Try new inference-based parsing first, fall back to old explicit syntax *)
        let parse_result =
          (* Check if content uses explicit type prefix (MODEL:, Tool:, etc.) *)
          (* Strip surrounding quotes that may be added by chain_to_mermaid *)
          let content = strip_quotes mnode.content in
          if has_explicit_type_prefix content then
            parse_node_content mnode.shape content
          else
            infer_type_from_id mnode.id mnode.shape content
        in
        match parse_result with
        | Error e -> convert_result := Error e
        | Ok node_type ->
            (* For Quorum, Merge, and StreamMerge nodes, we need to fill in the child nodes *)
            (* Use ChainRef with _ref suffix to avoid duplicate node ID issues *)
            let node_type = match node_type with
              | Quorum { consensus; nodes = _; weights } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (* Create ChainRef nodes for inputs with _ref suffix *)
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Quorum { consensus; nodes = input_nodes; weights }
              | Merge { strategy; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Merge { strategy; nodes = input_nodes }
              | StreamMerge { reducer; initial; min_results; timeout; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  StreamMerge { reducer; initial; min_results; timeout; nodes = input_nodes }
              | Race { timeout; nodes = _ } ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let input_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Race { timeout; nodes = input_nodes }
              | Fallback { primary = _; fallbacks = _ } ->
                  (* First input is primary, rest are fallbacks *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (match input_ids with
                  | primary_id :: fallback_ids ->
                      let primary = { id = primary_id ^ "_ref"; node_type = ChainRef primary_id; input_mapping = []; output_key = None; depends_on = None } in
                      let fallbacks = List.map (fun fb_id ->
                        { id = fb_id ^ "_ref"; node_type = ChainRef fb_id; input_mapping = []; output_key = None; depends_on = None }
                      ) fallback_ids in
                      Fallback { primary; fallbacks }
                  | [] ->
                      (* No inputs - keep placeholder *)
                      let placeholder = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
                      Fallback { primary = placeholder; fallbacks = [] })
              | Retry { max_attempts; backoff; retry_on; node = _ } ->
                  (* First input is the node to retry *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  (match input_ids with
                  | node_id :: _ ->
                      let inner_node = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } in
                      Retry { max_attempts; backoff; retry_on; node = inner_node }
                  | [] ->
                      (* No inputs - keep placeholder *)
                      let placeholder = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
                      Retry { max_attempts; backoff; retry_on; node = placeholder })
              | Cascade c ->
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let incoming_nodes = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  let tiers = List.mapi (fun i source_node ->
                    { Chain_types.tier_node = source_node;
                      tier_index = i;
                      confidence_threshold = c.default_threshold;
                      cost_weight = float_of_int i;
                      pass_context = true }
                  ) incoming_nodes in
                  Cascade { c with tiers }
              | Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates = _ } ->
                  (* Candidates from incoming edges *)
                  let input_ids =
                    match Hashtbl.find_opt deps mnode.id with
                    | Some ids -> ids
                    | None -> []
                  in
                  let candidates = List.map (fun input_id ->
                    { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                  ) input_ids in
                  Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates }
              | other -> other
            in
            let input_mapping =
              match Hashtbl.find_opt deps mnode.id with
              | Some inputs ->
                  (* Map: key (for substitution pattern {{key}}) -> node_id (for ctx.outputs lookup)
                     Note: Don't wrap in {{}} - resolve_inputs expects plain node_id *)
                  List.map (fun inp -> (inp, inp)) inputs
              | None -> []
            in
            let node = { id = mnode.id; node_type; input_mapping;
                         output_key = None; depends_on = None } in
            Hashtbl.replace node_map mnode.id node
  ) graph.nodes;

  match !convert_result with
  | Error e -> Error e
  | Ok () ->
      (* Build node list *)
      let nodes = Hashtbl.fold (fun _ node acc -> node :: acc) node_map [] in

      (* Find output node *)
      let output_nodes = find_output_nodes graph in
      let output = match output_nodes with
        | [single] -> single
        | first :: _ -> first  (* Take first if multiple *)
        | [] ->
            (* No terminal node, use last defined *)
            match List.rev graph.nodes with
            | last :: _ -> last.id
            | [] -> "output"
      in

      Ok {
        id;
        nodes;
        output;
        config = { default_config with direction = direction_of_string graph.direction };
        name = None; description = None; version = None;
        input_schema = None; output_schema = None; metadata = None;
      }

(** Convert Mermaid graph to Chain AST with metadata (for lossless roundtrip) *)
let mermaid_to_chain_with_meta ?(id = "mermaid_chain") (graph : mermaid_graph) (meta : mermaid_meta) : (chain, string) result =
  let fallback () =
    let deps = build_dependency_graph graph.edges in
    let outgoing = build_outgoing_edges graph.edges in

    (* Convert each mermaid node to chain node *)
    let node_map = Hashtbl.create 16 in
    let convert_result = ref (Ok ()) in

    List.iter (fun mnode ->
      match !convert_result with
      | Error _ -> ()
      | Ok () ->
          let parse_result =
            (* Strip surrounding quotes that may be added by chain_to_mermaid *)
            let content = strip_quotes mnode.content in
            if has_explicit_type_prefix content then
              parse_node_content mnode.shape content
            else
              infer_type_from_id mnode.id mnode.shape content
          in
          match parse_result with
          | Error e -> convert_result := Error e
          | Ok node_type ->
              (* Use ChainRef with _ref suffix to avoid duplicate node ID issues *)
              let node_type = match node_type with
                | Quorum { consensus; nodes = _; weights } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Quorum { consensus; nodes = input_nodes; weights }
                | Merge { strategy; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Merge { strategy; nodes = input_nodes }
                | StreamMerge { reducer; initial; min_results; timeout; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    StreamMerge { reducer; initial; min_results; timeout; nodes = input_nodes }
                | Race { timeout; nodes = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let input_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Race { timeout; nodes = input_nodes }
                | Fallback { primary = _; fallbacks = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    (match input_ids with
                    | primary_id :: fallback_ids ->
                        let primary = { id = primary_id ^ "_ref"; node_type = ChainRef primary_id; input_mapping = []; output_key = None; depends_on = None } in
                        let fallbacks = List.map (fun fb_id ->
                          { id = fb_id ^ "_ref"; node_type = ChainRef fb_id; input_mapping = []; output_key = None; depends_on = None }
                        ) fallback_ids in
                        Fallback { primary; fallbacks }
                    | [] ->
                        let placeholder = { id = "_fallback_primary"; node_type = ChainRef "_fallback_primary"; input_mapping = []; output_key = None; depends_on = None } in
                        Fallback { primary = placeholder; fallbacks = [] })
                | Retry { max_attempts; backoff; retry_on; node = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    (match input_ids with
                    | node_id :: _ ->
                        let inner_node = { id = node_id ^ "_ref"; node_type = ChainRef node_id; input_mapping = []; output_key = None; depends_on = None } in
                        Retry { max_attempts; backoff; retry_on; node = inner_node }
                    | [] ->
                        let placeholder = { id = "_retry_inner"; node_type = ChainRef "_retry_inner"; input_mapping = []; output_key = None; depends_on = None } in
                        Retry { max_attempts; backoff; retry_on; node = placeholder })
                | Cascade c ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let incoming_nodes = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    let tiers = List.mapi (fun i source_node ->
                      { Chain_types.tier_node = source_node;
                        tier_index = i;
                        confidence_threshold = c.default_threshold;
                        cost_weight = float_of_int i;
                        pass_context = true }
                    ) incoming_nodes in
                    Cascade { c with tiers }
                | Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates = _ } ->
                    let input_ids =
                      match Hashtbl.find_opt deps mnode.id with
                      | Some ids -> ids
                      | None -> []
                    in
                    let candidates = List.map (fun input_id ->
                      { id = input_id ^ "_ref"; node_type = ChainRef input_id; input_mapping = []; output_key = None; depends_on = None }
                    ) input_ids in
                    Evaluator { scoring_func; scoring_prompt; select_strategy; min_score; candidates }
                | GoalDriven gd ->
                    (* Apply metadata if available *)
                    (match Hashtbl.find_opt meta.node_goaldriven_meta mnode.id with
                    | Some gd_meta ->
                        (* Build action_node from metadata or edges *)
                        let action_node_id = match gd_meta.gd_action_node_id with
                          | Some id -> id
                          | None ->
                              (* Fall back to first edge source *)
                              match Hashtbl.find_opt deps mnode.id with
                              | Some (id :: _) -> id
                              | _ -> "_placeholder"
                        in
                        (* Use _ref suffix to avoid duplicate node ID *)
                        let action_node = { id = action_node_id ^ "_ref"; node_type = ChainRef action_node_id; input_mapping = []; output_key = None; depends_on = None } in
                        GoalDriven {
                          gd with
                          action_node;
                          measure_func = (match gd_meta.gd_measure_func with Some f -> f | None -> gd.measure_func);
                          strategy_hints = if gd_meta.gd_strategy_hints <> [] then gd_meta.gd_strategy_hints else gd.strategy_hints;
                          conversational = gd_meta.gd_conversational;
                          relay_models = if gd_meta.gd_relay_models <> [] then gd_meta.gd_relay_models else gd.relay_models;
                        }
                    | None ->
                        (* No metadata, use first edge as action_node *)
                        let action_node_id = match Hashtbl.find_opt deps mnode.id with
                          | Some (id :: _) -> id
                          | _ -> "_placeholder"
                        in
                        (* Use _ref suffix to avoid duplicate node ID *)
                        let action_node = { id = action_node_id ^ "_ref"; node_type = ChainRef action_node_id; input_mapping = []; output_key = None; depends_on = None } in
                        GoalDriven { gd with action_node })
                | other -> other
              in
              (* Use metadata input_mapping if available, otherwise infer from deps *)
              let input_mapping =
                match Hashtbl.find_opt meta.node_input_mappings mnode.id with
                | Some mapping -> mapping  (* Use metadata - preserves original keys! *)
                | None ->
                    (* Fall back to inferred mapping *)
                    match Hashtbl.find_opt deps mnode.id with
                    | Some inputs -> List.map (fun inp -> (inp, inp)) inputs
                    | None -> []
              in
              let node = { id = mnode.id; node_type; input_mapping;
                         output_key = None; depends_on = None } in
              Hashtbl.replace node_map mnode.id node
    ) graph.nodes;

    match !convert_result with
    | Error e -> Error e
    | Ok () ->
        let nodes_raw = Hashtbl.fold (fun _ node acc -> node :: acc) node_map [] in

        (* Post-process: Resolve node types that need edge information *)
        let nodes = List.map (fun (node : node) ->
          match node.node_type with
          | GoalDriven gd ->
              let action_node_id = gd.action_node.id in
              (match Hashtbl.find_opt node_map action_node_id with
               | Some actual_node ->
                   (* Replace ChainRef placeholder with actual node *)
                   { node with node_type = GoalDriven { gd with action_node = actual_node } }
               | None ->
                   (* Keep original if not found (will error at runtime) *)
                   node)
          | Mcts mcts ->
              (* Fill strategies from incoming edges - use ChainRef with _ref suffix *)
              let input_ids = match Hashtbl.find_opt deps node.id with
                | Some ids -> ids
                | None -> []
              in
              let strategies = List.map (fun id ->
                { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
              ) input_ids in
              { node with node_type = Mcts { mcts with strategies } }
          | Gate gate ->
              (* Resolve then_node and else_node from outgoing edges with labels *)
              let out_edges = match Hashtbl.find_opt outgoing node.id with
                | Some edges -> edges
                | None -> []
              in
              (* Find edges labeled "true" and "false" *)
              let then_id = List.find_map (fun (to_node, label) ->
                match label with
                | Some l when String.lowercase_ascii l = "true" -> Some to_node
                | _ -> None
              ) out_edges in
              let else_id = List.find_map (fun (to_node, label) ->
                match label with
                | Some l when String.lowercase_ascii l = "false" -> Some to_node
                | _ -> None
              ) out_edges in
              (* If no labels, use first two edges (first=then, second=else) *)
              let (then_id, else_id) = match (then_id, else_id) with
                | (Some t, Some e) -> (Some t, Some e)
                | (None, None) ->
                    (* No labeled edges, use positional *)
                    (match out_edges with
                     | [(to1, _)] -> (Some to1, None)
                     | (to1, _) :: (to2, _) :: _ -> (Some to1, Some to2)
                     | [] -> (None, None))
                | other -> other
              in
              (* Use ChainRef instead of actual node to avoid duplicate node issues *)
              (* The executor will resolve these refs at runtime *)
              let then_node = match then_id with
                | Some id ->
                    { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
                | None -> gate.then_node  (* Keep placeholder if not resolved *)
              in
              let else_node = match else_id with
                | Some id ->
                    Some { id = id ^ "_ref"; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
                | None -> gate.else_node
              in
              { node with node_type = Gate { gate with then_node; else_node } }
          | _ -> node
        ) nodes_raw in

        (* Use metadata output if available, otherwise find output node *)
        let output_nodes = find_output_nodes graph in
        let output = match meta.chain_output with
          | Some out -> out  (* Use metadata *)
          | None ->
              match output_nodes with
              | [single] -> single
              | first :: _ -> first
              | [] ->
                  match List.rev graph.nodes with
                  | last :: _ -> last.id
                  | [] -> "output"
        in

        (* Use metadata chain_id if available *)
        let final_id = match meta.chain_id with
          | Some mid -> mid
          | None -> id
        in

        (* Build config with metadata values *)
        let config = {
          max_depth = (match meta.chain_max_depth with Some d -> d | None -> default_config.max_depth);
          max_concurrency = (match meta.chain_max_concurrency with Some c -> c | None -> default_config.max_concurrency);
          timeout = (match meta.chain_timeout with Some t -> t | None -> default_config.timeout);
          trace = (match meta.chain_trace with Some t -> t | None -> default_config.trace);
          direction = direction_of_string graph.direction;
        } in

        Ok { id = final_id; nodes; output; config;
             name = None; description = None; version = None;
             input_schema = None; output_schema = None; metadata = None }
  in
  match meta.chain_full_json with
  | Some json_str ->
      (try
         let json = Yojson.Safe.from_string json_str in
         Chain_parser.parse_chain json
       with Yojson.Json_error _ ->
         (match meta.chain_json with
          | Some json ->
              (match Chain_parser.parse_chain json with
               | Ok chain -> Ok chain
               | Error _ -> fallback ())
          | None -> fallback ()))
  | None ->
      (match meta.chain_json with
       | Some json ->
           (match Chain_parser.parse_chain json with
            | Ok chain -> Ok chain
            | Error _ -> fallback ())
       | None -> fallback ())

(** Parse Mermaid text into Chain with metadata (lossless roundtrip)

    This function preserves all metadata embedded in Mermaid comments:
    - %% @chain {"id":"...", "output":"...", "timeout":300, "trace":true, "max_depth":4, "max_concurrency":3}
    - %% @chain_json { ... full chain JSON ... }
    - %% @node:nodeid {"input_mapping":[["key1","val1"],["key2","val2"]]}

    Usage:
      let mermaid = chain_to_mermaid chain in
      match parse_mermaid_to_chain ~id:"fallback_id" mermaid with
      | Ok chain2 -> (* chain2 is identical to chain *)
      | Error e -> ...
*)
let extract_chain_full (text : string) : string option =
  let lines = String.split_on_char '\n' text in
  let rec find = function
    | [] -> None
    | line :: rest ->
        let line = trim line in
        if String.length line >= 2 && String.sub line 0 2 = "%%" then
          let rest_line = trim (String.sub line 2 (String.length line - 2)) in
          if String.length rest_line >= 11 && String.sub rest_line 0 11 = "@chain_full" then
            Some (trim (String.sub rest_line 11 (String.length rest_line - 11)))
          else if String.length rest_line >= 11 && String.sub rest_line 0 11 = "@chain_json" then
            Some (trim (String.sub rest_line 11 (String.length rest_line - 11)))
          else
            find rest
        else
          find rest
  in
  find lines

let parse_mermaid_to_chain ?(id = "mermaid_chain") (text : string) : (chain, string) result =
  match extract_chain_full text with
  | Some json_str ->
      (try
         let json = Yojson.Safe.from_string json_str in
         Chain_parser.parse_chain json
       with Yojson.Json_error msg ->
         Error (Printf.sprintf "chain_full JSON parse error: %s" msg))
  | None ->
      (match parse_mermaid_text_with_meta text with
      | Error e -> Error e
      | Ok (graph, meta) ->
          (match meta.chain_full_json with
          | Some json_str ->
              (try
                 let json = Yojson.Safe.from_string json_str in
                 Chain_parser.parse_chain json
               with Yojson.Json_error msg ->
                 Error (Printf.sprintf "chain_full JSON parse error: %s" msg))
          | None ->
              mermaid_to_chain_with_meta ~id graph meta))

(** Main entry point: Parse Mermaid text into Chain *)
let parse_chain (text : string) : (chain, string) result =
  parse_mermaid_to_chain text

(** Parse with custom chain ID *)
let parse_chain_with_id ~id (text : string) : (chain, string) result =
  parse_mermaid_to_chain ~id text

