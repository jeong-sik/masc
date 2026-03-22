(** Research_config — Configuration for the code research loop.

    Defines target repository, build/test commands, and iteration limits
    for automated code improvement experiments. *)

type repo_config = {
  path : string;
  build_cmd : string list;     (** argv for build, e.g. ["dune"; "build"; "--root"; "."] *)
  test_cmd : string list;      (** argv for test,  e.g. ["make"; "test"] *)
  build_timeout_sec : float;
  test_timeout_sec : float;
}

type t = {
  repo : repo_config;
  max_iterations : int;
  time_budget_per_experiment_sec : float;
  results_file : string;
  cascade_name : string;       (** OAS cascade name for LLM calls *)
  system_prompt : string;
}

let default_repo_config ?(path = ".") () : repo_config =
  {
    path;
    build_cmd = [ "dune"; "build"; "--root"; "." ];
    test_cmd = [ "make"; "test" ];
    build_timeout_sec = 300.0;
    test_timeout_sec = 300.0;
  }

let default ?(repo = default_repo_config ()) () : t =
  {
    repo;
    max_iterations = 20;
    time_budget_per_experiment_sec = 600.0;
    results_file = "research_results.tsv";
    cascade_name = "llama";
    system_prompt =
      "You are a code improvement researcher for an OCaml codebase (MASC MCP server). \
       Propose ONE focused, small change per experiment. Prioritize: \
       bug fixes > simplification > performance > readability. \
       Keep changes to 1-3 files, under 50 lines. All tests must pass. \
       CRITICAL: Only use functions that appear in the 'Public API signatures' section. \
       Do NOT invent module names or function names. If a function does not appear \
       in the .mli signatures provided, it does not exist. \
       The 'Code around' sections show actual code near TODOs — use this to write \
       precise patches that fit the existing style and indentation. \
       The 'patch' field should contain the COMPLETE new content for the target file, \
       or a unified diff (starting with '---'). \
       Respond ONLY with a JSON object: \
       {\"description\": \"...\", \"target_file\": \"...\", \"rationale\": \"...\", \"patch\": \"...\"}";
  }
