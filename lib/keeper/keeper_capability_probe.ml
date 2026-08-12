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
  | Tool_schema_rejected of string

let invocation_error_to_string = function
  | Not_on_surface v -> verdict_to_string v
  | Unresolvable_runtime detail -> detail
  | Not_agent_core_lane label ->
    Printf.sprintf
      "%s is an official-client lane; its session is keyed by keeper name and \
       this probe does not isolate one"
      label
  | Tool_schema_rejected detail -> Printf.sprintf "tool schema rejected: %s" detail
;;

(* The wire form has to be the one a real turn sends, so it goes through the
   same [tool_schema_to_json] that [Agent_turn.prepare_tools] uses. Hand-rolling
   the JSON here would make a probe that passes while the real turn's encoding
   has drifted -- the failure this module exists to prevent. *)
let wire_tool_of_schema (schema : Masc_domain.tool_schema) =
  Agent_core.Types.tool_schema_of_input_schema
    ~name:schema.name
    ~description:schema.description
    ~input_schema:schema.input_schema
    ()
  |> Result.map Agent_core.Types.tool_schema_to_json
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
