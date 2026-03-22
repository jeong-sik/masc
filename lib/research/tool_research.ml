(** Tool_research — MCP tool for the code research loop.

    Exposes Research_loop as a MASC tool:
    - masc_research_start: kick off an automated code improvement loop
    - masc_research_status: check running experiment results *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_research_start";
    description = "Start an automated code improvement research loop. \
Uses local LLM (Qwen3.5-35B via llama-server) to propose small code improvements, \
tests them in isolated git worktrees, and keeps changes that pass all tests. \
Results logged to research_results.tsv.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("repo_path", `Assoc [
          ("type", `String "string");
          ("description", `String "Target repository path (default: MASC base path)");
        ]);
        ("max_iterations", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of experiments (default: 20)");
        ]);
        ("cascade_name", `Assoc [
          ("type", `String "string");
          ("description", `String "LLM model name (default: llama)");
        ]);
        ("llm_url", `Assoc [
          ("type", `String "string");
          ("description", `String "OpenAI-compatible LLM endpoint URL (default: env RESEARCH_LLM_URL or http://127.0.0.1:8085/v1/chat/completions)");
        ]);
      ]);
      ("required", `List []);
    ];
  };
  {
    name = "masc_research_status";
    description = "Show results from the most recent research loop run. \
Returns the contents of research_results.tsv with experiment outcomes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

type context = {
  base_path : string;
  agent_name : string option;
}

let dispatch (ctx : context) ~name ~args : (bool * string) option =
  match name with
  | "masc_research_start" ->
    let repo_path =
      Yojson.Safe.Util.(member "repo_path" args |> to_string_option)
      |> Option.value ~default:ctx.base_path
    in
    let max_iterations =
      Yojson.Safe.Util.(member "max_iterations" args |> to_int_option)
      |> Option.value ~default:20
    in
    let cascade_name =
      Yojson.Safe.Util.(member "cascade_name" args |> to_string_option)
      |> Option.value ~default:"llama"
    in
    let llm_url =
      Yojson.Safe.Util.(member "llm_url" args |> to_string_option)
    in
    let config = Research_config.default
      ~repo:(Research_config.default_repo_config ~path:repo_path ())
      ()
    in
    let config = { config with
      max_iterations;
      cascade_name;
      results_file = Printf.sprintf "%s/research_results.tsv" repo_path;
    } in
    let config = match llm_url with
      | Some url -> { config with llm_url = url }
      | None -> config
    in
    let results = Research_loop.run ~config in
    let kept = List.filter (fun (e : Research_loop.experiment_entry) ->
      e.metric.status = Research_metric.Keep) results in
    let summary = Printf.sprintf
      "Research complete. %d experiments run, %d kept.\nResults: %s"
      (List.length results) (List.length kept) config.results_file
    in
    Some (true, summary)

  | "masc_research_status" ->
    let results_file = Printf.sprintf "%s/research_results.tsv" ctx.base_path in
    if Sys.file_exists results_file then begin
      let ic = open_in results_file in
      let content = In_channel.input_all ic in
      close_in ic;
      Some (true, content)
    end else
      Some (true, "No research results found. Run masc_research_start first.")

  | _ -> None
