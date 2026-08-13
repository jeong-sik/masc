(* RFC-0374 — the deterministic half of the capability probe lane.

   Deliberately has no dependency on the turn driver, the runners, the chat
   store, or the checkpoint store. That absence is the point of the module:
   it is what lets a caller ask about the tool surface without the question
   becoming part of the keeper's history.

   Every "does this reach the model" decision is delegated to
   [Keeper_tool_descriptor.keeper_model_names], which is the projection the
   real surface is built from. Re-deriving it here from
   [keeper_model_projection] alone looked equivalent and was not: that field
   is only consulted after [model_schema_errors] clears, so a descriptor with
   a broken schema is withheld from the model while its projection variant
   still says [Preferred_public_name]. A probe that read the variant directly
   would have reported such a tool as reachable. *)

type verdict =
  | Projected of { model_facing_name : string }
  | Not_a_descriptor
  | Operator_only
  | Aliased of { projected_by : string }
  | Withheld_by_schema_error of { errors : string list }

let verdict_to_string = function
  | Projected { model_facing_name } ->
    Printf.sprintf "projected as %s" model_facing_name
  | Not_a_descriptor -> "no descriptor declares this name"
  | Operator_only -> "operator-only, withheld from the keeper model"
  | Aliased { projected_by } ->
    Printf.sprintf "transport alias; projected by %s" projected_by
  | Withheld_by_schema_error { errors } ->
    Printf.sprintf
      "declared model-facing but withheld: %s"
      (String.concat "; " errors)
;;

(* Operator-authored probe lists name tools inconsistently -- a public name in
   one row, the internal name in the next -- so resolution accepts either.
   This is name resolution, not a fallback: both strings are declared by the
   same descriptor, so neither is a guess. *)
let declares name (d : Keeper_tool_descriptor.t) =
  String.equal d.public_name name || String.equal d.internal_name name
;;

let probe_surface ~tool =
  match List.find_opt (declares tool) (Keeper_tool_descriptor.all_descriptors ()) with
  | None -> Not_a_descriptor
  | Some descriptor ->
    (match Keeper_tool_descriptor.keeper_model_names descriptor with
     | model_facing_name :: _ -> Projected { model_facing_name }
     | [] ->
       (* The SSOT withholds it. Which of the two reasons applies is not
          recoverable from the empty list, so ask the same two predicates the
          SSOT asked, in the same order it asked them. *)
       (match
          ( Keeper_tool_descriptor.model_schema_errors descriptor
          , descriptor.keeper_model_projection )
        with
        | (_ :: _ as errors), _ -> Withheld_by_schema_error { errors }
        | [], Operator_only -> Operator_only
        | [], Transport_alias { projected_by } -> Aliased { projected_by }
        | [], (Preferred_public_name | Internal_name) ->
          (* keeper_model_names returns a name for these once the schema
             clears, so reaching here means the SSOT changed shape and this
             module has drifted from it. Say so rather than inventing a
             verdict. *)
          Withheld_by_schema_error
            { errors =
                [ "descriptor projects a model-facing name but the surface \
                   withheld it; Keeper_capability_probe has drifted from \
                   Keeper_tool_descriptor.keeper_model_names"
                ]
            }))
;;

let model_facing_names () =
  Keeper_tool_descriptor.model_visible_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;

(* ------------------------------------------------------------------ *)
(* Invocation (Agent Core lane)                                        *)
(* ------------------------------------------------------------------ *)

type invocation =
  | Tool_invoked of
      { tool : string
      ; elapsed_s : float
      }
  | Other_tool_invoked of
      { requested : string
      ; invoked : string list
      ; elapsed_s : float
      }
  | Replied_no_tool of
      { reply_bytes : int
      ; elapsed_s : float
      }
  | Provider_rejected of { detail : string }

let invocation_to_string = function
  | Tool_invoked { tool; elapsed_s } ->
    Printf.sprintf "invoked %s in %.1fs" tool elapsed_s
  | Other_tool_invoked { requested; invoked; elapsed_s } ->
    Printf.sprintf
      "called %s instead of %s in %.1fs"
      (String.concat ", " invoked)
      requested
      elapsed_s
  | Replied_no_tool { reply_bytes; elapsed_s } ->
    Printf.sprintf "replied %d B without calling a tool in %.1fs" reply_bytes elapsed_s
  | Provider_rejected { detail } -> Printf.sprintf "provider rejected: %s" detail
;;

type invocation_error =
  | Not_on_surface of verdict
  | Unresolvable_runtime of string
  | Not_agent_core_lane of string
  | Not_official_client_lane of string
  | Tools_only_via_mcp_bridge of string
  | Tool_schema_rejected of string

let invocation_error_to_string = function
  | Not_on_surface v -> verdict_to_string v
  | Unresolvable_runtime detail -> detail
  | Not_agent_core_lane label ->
    Printf.sprintf
      "%s is an official-client lane; use probe_official_client_invocation"
      label
  | Not_official_client_lane label ->
    Printf.sprintf "%s is an Agent Core lane; use probe_invocation" label
  | Tools_only_via_mcp_bridge label ->
    Printf.sprintf
      "%s declares no host-side tool list; its surface exists only behind the \
       per-turn MCP bridge, which this probe does not stand up"
      label
  | Tool_schema_rejected detail -> Printf.sprintf "tool schema rejected: %s" detail
;;

(* The wire form has to be the one a real turn sends, so it goes through
   [Tool.wire_json_of_schema] -- the function [Agent_turn.prepare_tools]
   reaches through [Tool.schema_to_json]. Hand-rolling the JSON here would make
   a probe that passes while the real turn's encoding has drifted, the failure
   this module exists to prevent.

   The first version of this used [Types.tool_schema_to_json], on the strength
   of a comment asserting it was the same encoder. It is not: that one is the
   storage encoding and emits "parameters" alongside "input_schema", which the
   OpenAI backend rejects as mutually exclusive before the request leaves the
   process. Every live probe returned [Provider_rejected] -- indistinguishable
   at a glance from a quota refusal, and the offline tests could not see it
   because none of them reach the encoder's consumer. *)
let wire_tool_of_schema (schema : Masc_domain.tool_schema) =
  Agent_core.Types.tool_schema_of_input_schema
    ~name:schema.name
    ~description:schema.description
    ~input_schema:schema.input_schema
    ()
  |> Result.map Agent_core.Tool.wire_json_of_schema
;;

let tool_use_names (response : Agent_core.Types.api_response) =
  List.filter_map
    (function
      | Agent_core.Types.ToolUse { name; _ } -> Some name
      | Agent_core.Types.Text _
      | Agent_core.Types.Thinking _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> None)
    response.content
;;

let reply_bytes (response : Agent_core.Types.api_response) =
  List.fold_left
    (fun acc block ->
      match block with
      | Agent_core.Types.Text t -> acc + String.length t
      | Agent_core.Types.Thinking _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.ToolUse _
      | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> acc)
    0
    response.content
;;

let probe_invocation ~sw ~net ?clock ~now ~runtime_id ~tool ~prompt () =
  match probe_surface ~tool with
  | (Not_a_descriptor | Operator_only | Aliased _ | Withheld_by_schema_error _) as v ->
    Error (Not_on_surface v)
  | Projected { model_facing_name } ->
    (* The lane has to be checked before the provider config is used. Every
       runtime resolves a provider config, including the official-client ones,
       so resolving one is not evidence that this path is the path that runtime
       actually takes. Probing claude_code over HTTP would answer a question
       nobody asked. *)
    (match Runtime.get_runtime_by_id runtime_id with
     | None ->
       Error (Unresolvable_runtime (Printf.sprintf "%s is not a configured runtime" runtime_id))
     | Some rt ->
       (match rt.Runtime.execution with
        | Runtime_execution.Codex_app_server _
        | Runtime_execution.Antigravity_cli _
        | Runtime_execution.Claude_code _ ->
          Error (Not_agent_core_lane (Runtime_execution.label rt.Runtime.execution))
        | Runtime_execution.Agent_core _ ->
    (match Runtime_agent_core_runner.resolve_runtime_providers ~runtime_id () with
     | Error detail -> Error (Unresolvable_runtime detail)
     | Ok [] ->
       Error (Unresolvable_runtime (Printf.sprintf "%s resolved no provider" runtime_id))
     | Ok (config :: _) ->
       let schemas =
         Keeper_tool_descriptor.model_visible_schemas ()
         |> List.filter (fun (s : Masc_domain.tool_schema) ->
           String.equal s.name model_facing_name)
       in
       (match schemas with
        | [] ->
          (* probe_surface said Projected, so model_visible_schemas must carry
             the name. Reaching here means the two have drifted apart. *)
          Error
            (Tool_schema_rejected
               (Printf.sprintf
                  "%s is projected but absent from model_visible_schemas"
                  model_facing_name))
        | schema :: _ ->
          (match wire_tool_of_schema schema with
           | Error detail -> Error (Tool_schema_rejected detail)
           | Ok tool_json ->
             let messages =
               [ { Agent_core.Types.role = Agent_core.Types.User
                 ; content = [ Agent_core.Types.Text prompt ]
                 ; name = None
                 ; tool_call_id = None
                 ; metadata = []
                 }
               ]
             in
             let started = now () in
             (match
                Keeper_provider_subcall.complete
                  ~sw
                  ~net
                  ?clock
                  ~config
                  ~messages
                  ~tools:[ tool_json ]
                  ()
              with
              | Error err ->
                (* Every arm is spelled out. A wildcard here would fold a new
                   transport failure into the same string as a quota rejection,
                   and telling those apart is the reason this lane exists. *)
                let detail =
                  match err with
                  | Llm_provider.Http_client.HttpError { code; body; _ } ->
                    Printf.sprintf "HTTP %d: %s" code (String.trim body)
                  | Llm_provider.Http_client.NetworkError { message; _ } ->
                    Printf.sprintf "network: %s" message
                  | Llm_provider.Http_client.TimeoutError { message; _ } ->
                    Printf.sprintf "timeout: %s" message
                  | Llm_provider.Http_client.AcceptRejected { reason } ->
                    Printf.sprintf "accept rejected: %s" reason
                  | Llm_provider.Http_client.ProviderTerminal { message; _ } ->
                    Printf.sprintf "provider terminal: %s" message
                  | Llm_provider.Http_client.ProviderFailure { message; _ } ->
                    Printf.sprintf "provider failure: %s" message
                in
                Ok (Provider_rejected { detail })
              | Ok response ->
                let elapsed_s = now () -. started in
                (match tool_use_names response with
                 | [] ->
                   Ok (Replied_no_tool { reply_bytes = reply_bytes response; elapsed_s })
                 | names when List.exists (String.equal model_facing_name) names ->
                   Ok (Tool_invoked { tool = model_facing_name; elapsed_s })
                 | invoked ->
                   Ok
                     (Other_tool_invoked
                        { requested = model_facing_name; invoked; elapsed_s }))))))))
;;

(* --- Official-client lanes --- *)

(* The tool MASC hands the spawned client. Its implementation is the
   observation: a call lands in [seen] before any transcript, stream frame, or
   response body is parsed, so a positive answer here cannot be a decoding
   artifact. The returned content is inert -- the probe asks whether the client
   can reach the tool, not what the tool would do. *)
let recording_dynamic_tool ~(schema : Masc_domain.tool_schema) ~seen =
  { Runtime_official_client_tool.name = schema.name
  ; description = schema.description
  ; input_schema = schema.input_schema
  ; call =
      (fun ~call_id:_ _arguments ->
        seen := schema.name :: !seen;
        { Runtime_official_client_tool.success = true
        ; content = "probe acknowledged; no side effect performed"
        ; abort_turn = None
        })
  }
;;

(* Both lanes answer the same four-way question, and both report the count of
   host-tool calls they admitted. Splitting only on the run itself keeps the
   classification identical across lanes, so a difference in the result is a
   difference in the runtime rather than in how the probe read it. *)
let classify_official_client_turn ~model_facing_name ~seen ~elapsed_s ~text
    ~dynamic_tool_calls =
  match !seen with
  | names when List.exists (String.equal model_facing_name) names ->
    Tool_invoked { tool = model_facing_name; elapsed_s }
  | [] when dynamic_tool_calls > 0 ->
    (* The client admitted a host-tool call the callback never saw. Only one
       tool was declared, so this is a transport-level disagreement, not the
       model choosing a different tool -- do not report it as either. *)
    Provider_rejected
      { detail =
          Printf.sprintf
            "client reported %d host-tool call(s) but no declared tool ran"
            dynamic_tool_calls
      }
  | [] -> Replied_no_tool { reply_bytes = String.length text; elapsed_s }
  | invoked -> Other_tool_invoked { requested = model_facing_name; invoked; elapsed_s }
;;

let probe_official_client_invocation ~mgr ~clock ~fs ~base_path ~now ~runtime_id
    ~tool ~prompt () =
  match probe_surface ~tool with
  | (Not_a_descriptor | Operator_only | Aliased _ | Withheld_by_schema_error _) as v ->
    Error (Not_on_surface v)
  | Projected { model_facing_name } ->
    (match Runtime.get_runtime_by_id runtime_id with
     | None ->
       Error
         (Unresolvable_runtime
            (Printf.sprintf "%s is not a configured runtime" runtime_id))
     | Some rt ->
       let schemas =
         Keeper_tool_descriptor.model_visible_schemas ()
         |> List.filter (fun (s : Masc_domain.tool_schema) ->
           String.equal s.name model_facing_name)
       in
       (match schemas with
        | [] ->
          Error
            (Tool_schema_rejected
               (Printf.sprintf
                  "%s is projected but absent from model_visible_schemas"
                  model_facing_name))
        | schema :: _ ->
          let seen = ref [] in
          let dynamic_tools = [ recording_dynamic_tool ~schema ~seen ] in
          let started = now () in
          (match rt.Runtime.execution with
           | Runtime_execution.Agent_core _ ->
             Error
               (Not_official_client_lane
                  (Runtime_execution.label rt.Runtime.execution))
           | Runtime_execution.Antigravity_cli _ ->
             Error
               (Tools_only_via_mcp_bridge
                  (Runtime_execution.label rt.Runtime.execution))
           | Runtime_execution.Claude_code exec ->
             (* Built from the same fields the keeper path builds it from, and
                the deadline resolved by the same function, so the probe
                measures the runtime a real turn would get rather than a
                lenient stand-in. Only [system_prompt] differs: the probe's
                prompt is the whole instruction.

                Session mode is left at its default -- a fresh session per
                probe, abandoned when the turn ends. *)
             let config : Runtime_claude_code.config =
               { cli_path = exec.cli_path
               ; cwd = base_path
               ; model = exec.model
               ; system_prompt = None
               ; admission_timeout_s = exec.timeout_s
               ; timeout_s =
                   (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
                    | None -> Some exec.timeout_s
                    | Some 0.0 -> None
                    | Some s -> Some s)
               }
             in
             (match
                Runtime_claude_code.run_turn
                  ~dynamic_tools
                  ~mgr
                  ~clock
                  ~cwd:Eio.Path.(fs / base_path)
                  config
                  ~prompt
              with
              | Error error ->
                Ok
                  (Provider_rejected
                     { detail = Runtime_claude_code.error_to_string error })
              | Ok (turn : Runtime_claude_code.turn_result) ->
                Ok
                  (classify_official_client_turn
                     ~model_facing_name
                     ~seen
                     ~elapsed_s:(now () -. started)
                     ~text:turn.text
                     ~dynamic_tool_calls:turn.dynamic_tool_calls))
           | Runtime_execution.Codex_app_server exec ->
             let config : Runtime_codex_app_server.config =
               { cli_path = exec.cli_path
               ; model = exec.model
               ; developer_instructions = None
               ; admission_timeout_s = exec.timeout_s
               ; timeout_s =
                   (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
                    | None -> Some exec.timeout_s
                    | Some 0.0 -> None
                    | Some s -> Some s)
               }
             in
             (match
                Runtime_codex_app_server.run_turn
                  ~dynamic_tools
                  ~mgr
                  ~clock
                  ~cwd:Eio.Path.(fs / base_path)
                  config
                  ~prompt
              with
              | Error error ->
                Ok
                  (Provider_rejected
                     { detail = Runtime_codex_app_server.error_to_string error })
              | Ok (turn : Runtime_codex_app_server.turn_result) ->
                Ok
                  (classify_official_client_turn
                     ~model_facing_name
                     ~seen
                     ~elapsed_s:(now () -. started)
                     ~text:turn.text
                     ~dynamic_tool_calls:turn.dynamic_tool_calls)))))
;;
