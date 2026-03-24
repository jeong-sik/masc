(** Procedure-to-Tool Materializer — promotes high-confidence learned procedures
    into callable MCP tools at runtime.

    When a keeper's procedural memory reaches maturity (confidence >= 0.9,
    evidence >= 5), the procedure is registered as an MCP tool via
    Tool_dispatch.register.  The tool handler executes the procedure's pattern
    as a structured prompt via Oas_worker.run_named, so there is no arbitrary
    code execution — only LLM-mediated interpretation.

    Materialized tool names use the "proc_" prefix to distinguish them from
    built-in tools.

    @since 2.128.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type materialized_tool = {
  procedure_id : string;
  tool_name : string;
  description : string;
  confidence : float;
  evidence_count : int;
  registered_at : float;
}

(* ================================================================ *)
(* Internal state                                                   *)
(* ================================================================ *)

(** Materialized tool registry — keyed by procedure_id to prevent duplicates. *)
let materialized : (string, materialized_tool) Hashtbl.t = Hashtbl.create 16

(* ================================================================ *)
(* Thresholds                                                       *)
(* ================================================================ *)

(** Minimum confidence for materialization.
    Higher than crystallization (0.7) — only well-proven procedures
    become callable tools. *)
let materialize_min_confidence = 0.9

(** Minimum evidence count for materialization. *)
let materialize_min_evidence = 5

(* ================================================================ *)
(* Name sanitization                                                *)
(* ================================================================ *)

(** Convert a procedure pattern into a valid tool name.
    - Lowercase
    - Replace non-alphanumeric with underscore
    - Collapse consecutive underscores
    - Truncate to 48 chars
    - Prefix with "proc_" *)
let sanitize_tool_name (pattern : string) : string =
  let buf = Buffer.create 64 in
  let lower = String.lowercase_ascii pattern in
  let prev_underscore = ref false in
  String.iter (fun c ->
    match c with
    | 'a'..'z' | '0'..'9' ->
      Buffer.add_char buf c;
      prev_underscore := false
    | _ ->
      if not !prev_underscore && Buffer.length buf > 0 then begin
        Buffer.add_char buf '_';
        prev_underscore := true
      end
  ) lower;
  let raw = Buffer.contents buf in
  (* Trim trailing underscore *)
  let trimmed =
    if String.length raw > 0 && raw.[String.length raw - 1] = '_'
    then String.sub raw 0 (String.length raw - 1)
    else raw
  in
  (* Truncate *)
  let truncated =
    if String.length trimmed > 48
    then String.sub trimmed 0 48
    else trimmed
  in
  sprintf "proc_%s" truncated

(* ================================================================ *)
(* Handler factory                                                  *)
(* ================================================================ *)

(** Create a Tool_dispatch.handler that executes the procedure's pattern
    as a structured prompt via OAS Agent.run.
    Single-turn, no tools, low temperature for deterministic output. *)
let make_handler (procedure : Procedural_memory.procedure) : Tool_dispatch.handler =
  fun ~name:_ ~args ->
    let query =
      match args with
      | `Assoc fields ->
        (match List.assoc_opt "query" fields with
         | Some (`String s) -> s
         | _ -> Yojson.Safe.to_string args)
      | _ -> Yojson.Safe.to_string args
    in
    let system_prompt = sprintf
      "You are executing a learned procedure. Follow this pattern precisely:\n\n%s\n\n\
       Apply this procedure to the user's request. Be concise and actionable."
      procedure.pattern
    in
    match
      Oas_worker.run_named
        ~cascade_name:"materialized_procedure"
        ~goal:query
        ~system_prompt
        ~max_turns:1
        ~temperature:0.3
        ~max_tokens:2048
        ()
    with
    | Ok result ->
      let text = Oas_response.text_of_response result.response in
      Some (true, text)
    | Error e ->
      Some (false, sprintf "Procedure execution failed: %s" e)

(* ================================================================ *)
(* Tool schema factory                                              *)
(* ================================================================ *)

(** Generate a tool_schema for a materialized procedure. *)
let make_schema ~tool_name ~description : Types.tool_schema =
  {
    name = tool_name;
    description = sprintf
      "[Learned procedure] %s" description;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String
            "The request or context to apply this learned procedure to.");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
    visibility = Public;
  }

(* ================================================================ *)
(* Scan and discover agent names                                    *)
(* ================================================================ *)

(** List agent names that have procedure directories. *)
let discover_agent_names () : string list =
  let me_root = Env_config.me_root () in
  let dir = sprintf "%s/.masc/procedures" me_root in
  if Sys.file_exists dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
      Sys.is_directory (Filename.concat dir name))
  else []

(* ================================================================ *)
(* Core: materialize                                                *)
(* ================================================================ *)

let materialize_mature_procedures () : materialized_tool list =
  let agent_names = discover_agent_names () in
  let newly_materialized = ref [] in
  List.iter (fun agent_name ->
    let procedures = Procedural_memory.load_procedures ~agent_name in
    List.iter (fun (proc : Procedural_memory.procedure) ->
      let evidence_count = List.length proc.evidence in
      (* Check maturity thresholds *)
      if proc.confidence >= materialize_min_confidence
         && evidence_count >= materialize_min_evidence
         && not (Hashtbl.mem materialized proc.id)
      then begin
        let tool_name = sanitize_tool_name proc.pattern in
        (* Avoid name collisions with existing tools *)
        if not (Tool_dispatch.is_registered tool_name) then begin
          let handler = make_handler proc in
          (* Register in dispatch for tool call routing *)
          Tool_dispatch.register ~tool_name ~handler;
          let now = Time_compat.now () in
          let mt = {
            procedure_id = proc.id;
            tool_name;
            description = proc.pattern;
            confidence = proc.confidence;
            evidence_count;
            registered_at = now;
          } in
          Hashtbl.replace materialized proc.id mt;
          newly_materialized := mt :: !newly_materialized;
          Log.Keeper.info
            "materialized procedure %s as tool %s (confidence=%.2f, evidence=%d)"
            proc.id tool_name proc.confidence evidence_count
        end else
          Log.Keeper.warn
            "skipping procedure %s: tool name %s already registered"
            proc.id tool_name
      end
    ) procedures
  ) agent_names;
  List.rev !newly_materialized

(* ================================================================ *)
(* Query                                                            *)
(* ================================================================ *)

let materialized_tools () : materialized_tool list =
  Hashtbl.fold (fun _id mt acc -> mt :: acc) materialized []
  |> List.sort (fun a b -> Float.compare b.registered_at a.registered_at)

let materialized_count () : int =
  Hashtbl.length materialized

(* ================================================================ *)
(* Dematerialize                                                    *)
(* ================================================================ *)

let dematerialize ~tool_name =
  let to_remove = ref None in
  Hashtbl.iter (fun id mt ->
    if mt.tool_name = tool_name then
      to_remove := Some id
  ) materialized;
  match !to_remove with
  | Some id ->
    Hashtbl.remove materialized id;
    (* Note: Tool_dispatch does not expose an unregister function.
       The handler remains in the dispatch registry but the tool
       will not appear in materialized_tools() listings.
       A full unregister would require extending Tool_dispatch. *)
    Log.Keeper.info "dematerialized tool %s (procedure %s)" tool_name id
  | None ->
    Log.Keeper.warn "dematerialize: tool %s not found in materialized registry" tool_name

(* ================================================================ *)
(* JSON serialization (for dashboard/status)                        *)
(* ================================================================ *)

let materialized_tool_to_json (mt : materialized_tool) : Yojson.Safe.t =
  `Assoc [
    ("procedure_id", `String mt.procedure_id);
    ("tool_name", `String mt.tool_name);
    ("description", `String mt.description);
    ("confidence", `Float mt.confidence);
    ("evidence_count", `Int mt.evidence_count);
    ("registered_at", `Float mt.registered_at);
  ]

let status_json () : Yojson.Safe.t =
  let tools = materialized_tools () in
  `Assoc [
    ("materialized_count", `Int (List.length tools));
    ("tools", `List (List.map materialized_tool_to_json tools));
  ]
