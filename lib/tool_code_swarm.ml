(** Tool_code_swarm — MCP dispatch for code swarm operations.

    Three tools: plan, verify, merge.
    Uses Code_swarm_plan for business logic.

    @since 2.100.0 *)

open Tool_args

(* Context — same shape as Tool_worktree *)
type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_plan ctx args =
  let pattern = get_string args "pattern" "" in
  let file_glob = get_string args "file_glob" "*.ml" in
  let max_workers = get_int args "max_workers" 3 in
  let exclude_files = get_string_list args "exclude_files" in
  if pattern = "" then (false, "pattern is required")
  else
    match
      Code_swarm_plan.create_plan ~base_path:ctx.config.base_path ~pattern
        ~file_glob ~max_workers ~exclude_files
    with
    | Ok plan ->
        let json = Code_swarm_plan.plan_to_json plan in
        (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, e)

let handle_verify ctx args =
  let plan_id = get_string args "plan_id" "" in
  let verify_model = get_string_opt args "verify_model" in
  if plan_id = "" then (false, "plan_id is required")
  else
    match
      Code_swarm_plan.verify_plan ~base_path:ctx.config.base_path ~plan_id
        ~verify_model
    with
    | Ok vr ->
        let json = Code_swarm_plan.verify_result_to_json vr in
        (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, e)

let handle_merge ctx args =
  let plan_id = get_string args "plan_id" "" in
  let strategy = get_string args "strategy" "sequential" in
  let auto_pr = get_bool args "auto_pr" false in
  let build_verify = get_bool args "build_verify" true in
  let require_all_pass = get_bool args "require_all_pass" true in
  if plan_id = "" then (false, "plan_id is required")
  else
    match
      Code_swarm_plan.merge_workers ~base_path:ctx.config.base_path ~plan_id
        ~strategy ~auto_pr ~build_verify ~require_all_pass
    with
    | Ok mr ->
        let json = Code_swarm_plan.merge_result_to_json mr in
        (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, e)

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_code_swarm_plan" -> Some (handle_plan ctx args)
  | "masc_code_swarm_verify" -> Some (handle_verify ctx args)
  | "masc_code_swarm_merge" -> Some (handle_merge ctx args)
  | _ -> None

(* ================================================================ *)
(* Schemas                                                          *)
(* ================================================================ *)

let schemas : Types.tool_schema list =
  [
    {
      name = "masc_code_swarm_plan";
      description =
        "Plan a code swarm: grep for a pattern across files, split matches \
         into N workers for parallel modification. Returns a plan with \
         worker assignments and worktree branches. Use with team_session to \
         spawn workers.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "pattern",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Grep pattern (extended regex) to find in files" );
                      ] );
                  ( "file_glob",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String "File glob pattern (e.g., '*.ml', 'lib/*.ml')"
                        );
                        ("default", `String "*.ml");
                      ] );
                  ( "max_workers",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Maximum workers (hard limit 5)" );
                        ("default", `Int 3);
                      ] );
                  ( "exclude_files",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items", `Assoc [ ("type", `String "string") ] );
                        ( "description",
                          `String
                            "Files to exclude from the plan (relative paths)"
                        );
                      ] );
                ] );
            ("required", `List [ `String "pattern" ]);
          ];
    };
    {
      name = "masc_code_swarm_verify";
      description =
        "Verify code swarm results: collect git diffs from each worker's \
         worktree, send to a cheap MODEL for PASS/WARN/FAIL verdict. Checks \
         scope creep, syntax validity, and behavior preservation.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "plan_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String "Plan ID from masc_code_swarm_plan" );
                      ] );
                  ( "verify_model",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Model spec for verification (e.g., \
                             'glm:auto'). Uses default verifier if \
                             omitted." );
                      ] );
                ] );
            ("required", `List [ `String "plan_id" ]);
          ];
    };
    {
      name = "masc_code_swarm_merge";
      description =
        "Merge verified code swarm results: cherry-pick passing workers into \
         a merged branch, run dune build, optionally create a draft PR. \
         Workers that failed verification are excluded. Cleans up worker \
         worktrees after merge.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "plan_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String "Plan ID from masc_code_swarm_plan" );
                      ] );
                  ( "strategy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List [ `String "sequential"; `String "octopus" ] );
                        ( "description",
                          `String
                            "Merge strategy: sequential cherry-pick or \
                             octopus merge" );
                        ("default", `String "sequential");
                      ] );
                  ( "auto_pr",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Create a draft PR after successful merge" );
                        ("default", `Bool false);
                      ] );
                  ( "build_verify",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String "Run dune build after merge to verify" );
                        ("default", `Bool true);
                      ] );
                  ( "require_all_pass",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "If true, exclude FAIL workers from merge \
                             (default true)" );
                        ("default", `Bool true);
                      ] );
                ] );
            ("required", `List [ `String "plan_id" ]);
          ];
    };
  ]
