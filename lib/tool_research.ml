(** Tool_research — MCP tool for the code research loop.

    Exposes Research_loop as a MASC tool:
    - masc_research_start: kick off an automated code improvement loop
    - masc_research_status: check running experiment results *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_research_start";
    description = "Start an automated code improvement research loop. \
Uses OAS cascade to route LLM calls (local or cloud providers). \
Proposes small code improvements, tests them in isolated git worktrees, \
and keeps changes that pass all tests. Results logged to research_results.tsv.";
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
          ("description", `String "OAS cascade profile name (default: research)");
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
  sw : Eio.Switch.t;
  net : Eio_context.eio_net;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
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
      |> Option.value ~default:"research"
    in
    let config = Research_config.default
      ~repo:(Research_config.default_repo_config ~path:repo_path ())
      ()
    in
    let temperature = Cascade_inference.resolve_temperature
      ~cascade_name ~fallback:(fun () -> 0.7)
    in
    let config = { config with
      max_iterations;
      cascade_name;
      temperature;
      results_file = Printf.sprintf "%s/research_results.tsv" repo_path;
    } in
    let results = Research_loop.run ~sw:ctx.sw ~net:ctx.net ~clock:ctx.clock ~config in
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
      let content = Fs_compat.load_file results_file in
      Some (true, content)
    end else
      Some (true, "No research results found. Run masc_research_start first.")

  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_research
           ~input_schema:s.input_schema
           ()))
    schemas
