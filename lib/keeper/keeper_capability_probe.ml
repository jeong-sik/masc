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

(* ------------------------------------------------------------------ *)
(* Completion availability contract                                   *)
(* ------------------------------------------------------------------ *)

type official_client_lane =
  | Codex_app_server
  | Claude_code
[@@deriving show, eq]

type probe_lane =
  | Agent_core
  | Official_client of official_client_lane
  | Antigravity
[@@deriving show, eq]

type probe_target =
  { runtime_id : string
  ; provider_id : string
  ; binding_model_id : string
  ; configured_model_id : string option
  ; lane : probe_lane
  }
[@@deriving show, eq]

let probe_lane_of_execution = function
  | Runtime_execution.Agent_core _ -> Agent_core
  | Runtime_execution.Codex_app_server _ -> Official_client Codex_app_server
  | Runtime_execution.Claude_code _ -> Official_client Claude_code
  | Runtime_execution.Antigravity_cli _ -> Antigravity
;;

let probe_target_of_runtime (runtime : Runtime.t) =
  { runtime_id = runtime.id
  ; provider_id = runtime.provider.id
  ; binding_model_id = runtime.binding.model_id
  ; configured_model_id = Runtime_execution.model_id runtime.execution
  ; lane = probe_lane_of_execution runtime.execution
  }
;;

let dispatch_probe_target ~agent_core ~official_client ~antigravity target =
  match target.lane with
  | Agent_core -> agent_core target
  | Official_client _ -> official_client target
  | Antigravity -> antigravity target
;;

let probe_lane_to_string = function
  | Agent_core -> "agent_core"
  | Official_client Codex_app_server -> "codex_app_server"
  | Official_client Claude_code -> "claude_code"
  | Antigravity -> "antigravity"
;;

let probe_lane_of_string = function
  | "agent_core" -> Ok Agent_core
  | "codex_app_server" -> Ok (Official_client Codex_app_server)
  | "claude_code" -> Ok (Official_client Claude_code)
  | "antigravity" -> Ok Antigravity
  | value -> Error (Printf.sprintf "unknown completion probe lane %S" value)
;;

let non_blank ~field value =
  if String.equal (String.trim value) ""
  then Error (field ^ " must not be blank")
  else Ok value
;;

let ( >>= ) = Result.bind

let sorted_strings = List.sort String.compare

let exact_object ~context ~fields = function
  | `Assoc entries ->
    let actual = entries |> List.map fst |> sorted_strings in
    let expected = sorted_strings fields in
    if actual = expected
    then Ok entries
    else
      Error
        (Printf.sprintf
           "%s fields must be exactly [%s]; got [%s]"
           context
           (String.concat ", " expected)
           (String.concat ", " actual))
  | _ -> Error (context ^ " must be a JSON object")
;;

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" context name)
;;

let json_string ~context name fields =
  let ( let* ) = Result.bind in
  let* value = required_field ~context name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
;;

let json_int ~context name fields =
  let ( let* ) = Result.bind in
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an integer" context name)
;;

let json_float ~context name fields =
  let ( let* ) = Result.bind in
  let* value = required_field ~context name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
;;

let json_string_option ~context name fields =
  let ( let* ) = Result.bind in
  let* value = required_field ~context name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (Printf.sprintf "%s.%s must be a string or null" context name)
;;

module Probe_result = struct
  type completed_evidence =
    { response_bytes : int
    ; tool_invocations : int
    ; elapsed_s : float
    }
  [@@deriving show, eq]

  type not_run_reason =
    | Registered_only
    | Skipped_by_request
    | Live_probe_deferred
    | Runtime_not_registered
  [@@deriving show, eq]

  type t =
    | Completed of completed_evidence
    | Auth_failed of { detail : string }
    | Transport_failed of { detail : string }
    | Unsupported_lane of
        { lane : probe_lane
        ; detail : string
        }
    | Not_run of
        { reason : not_run_reason
        ; detail : string option
        }
  [@@deriving show, eq]

  let completed ~response_bytes ~tool_invocations ~elapsed_s =
    if response_bytes < 0
    then Error "completed.response_bytes must be non-negative"
    else if tool_invocations < 0
    then Error "completed.tool_invocations must be non-negative"
    else if (not (Float.is_finite elapsed_s)) || elapsed_s < 0.0
    then Error "completed.elapsed_s must be finite and non-negative"
    else if response_bytes = 0 && tool_invocations = 0
    then
      Error
        "completed requires observed response bytes or a tool invocation; registration is not evidence"
    else Ok (Completed { response_bytes; tool_invocations; elapsed_s })
  ;;

  let completed_of_invocation = function
    | Tool_invoked { elapsed_s; _ } ->
      completed ~response_bytes:0 ~tool_invocations:1 ~elapsed_s
    | Other_tool_invoked { invoked; elapsed_s; _ } ->
      completed
        ~response_bytes:0
        ~tool_invocations:(List.length invoked)
        ~elapsed_s
    | Replied_no_tool { reply_bytes; elapsed_s } ->
      completed ~response_bytes:reply_bytes ~tool_invocations:0 ~elapsed_s
    | Provider_rejected _ ->
      Error
        "Provider_rejected flattened auth and transport; preserve the typed failure before constructing Probe_result"
  ;;

  let failure constructor ~field ~detail =
    Result.map constructor (non_blank ~field detail)
  ;;

  let auth_failed ~detail =
    failure (fun detail -> Auth_failed { detail }) ~field:"auth_failed.detail" ~detail
  ;;

  let transport_failed ~detail =
    failure
      (fun detail -> Transport_failed { detail })
      ~field:"transport_failed.detail"
      ~detail
  ;;

  let unsupported_lane ~lane ~detail =
    failure
      (fun detail -> Unsupported_lane { lane; detail })
      ~field:"unsupported_lane.detail"
      ~detail
  ;;

  let not_run ~reason ?detail () = Not_run { reason; detail }

  let not_run_reason_to_string = function
    | Registered_only -> "registered_only"
    | Skipped_by_request -> "skipped_by_request"
    | Live_probe_deferred -> "live_probe_deferred"
    | Runtime_not_registered -> "runtime_not_registered"
  ;;

  let not_run_reason_of_string = function
    | "registered_only" -> Ok Registered_only
    | "skipped_by_request" -> Ok Skipped_by_request
    | "live_probe_deferred" -> Ok Live_probe_deferred
    | "runtime_not_registered" -> Ok Runtime_not_registered
    | value -> Error (Printf.sprintf "unknown not-run reason %S" value)
  ;;

  let to_yojson = function
    | Completed { response_bytes; tool_invocations; elapsed_s } ->
      `Assoc
        [ "status", `String "completed"
        ; "response_bytes", `Int response_bytes
        ; "tool_invocations", `Int tool_invocations
        ; "elapsed_s", `Float elapsed_s
        ]
    | Auth_failed { detail } ->
      `Assoc [ "status", `String "auth_failed"; "detail", `String detail ]
    | Transport_failed { detail } ->
      `Assoc [ "status", `String "transport_failed"; "detail", `String detail ]
    | Unsupported_lane { lane; detail } ->
      `Assoc
        [ "status", `String "unsupported_lane"
        ; "lane", `String (probe_lane_to_string lane)
        ; "detail", `String detail
        ]
    | Not_run { reason; detail } ->
      `Assoc
        [ "status", `String "not_run"
        ; "reason", `String (not_run_reason_to_string reason)
        ; ( "detail"
          , match detail with
            | None -> `Null
            | Some value -> `String value )
        ]
  ;;

  let of_yojson json =
    let ( let* ) = Result.bind in
    let* initial =
      match json with
      | `Assoc fields -> Ok fields
      | _ -> Error "probe result must be a JSON object"
    in
    let* status = json_string ~context:"probe_result" "status" initial in
    match status with
    | "completed" ->
      let* fields =
        exact_object
          ~context:"probe_result.completed"
          ~fields:[ "status"; "response_bytes"; "tool_invocations"; "elapsed_s" ]
          json
      in
      let* response_bytes =
        json_int ~context:"probe_result.completed" "response_bytes" fields
      in
      let* tool_invocations =
        json_int ~context:"probe_result.completed" "tool_invocations" fields
      in
      let* elapsed_s = json_float ~context:"probe_result.completed" "elapsed_s" fields in
      completed ~response_bytes ~tool_invocations ~elapsed_s
    | "auth_failed" | "transport_failed" ->
      let context = "probe_result." ^ status in
      let* fields =
        exact_object ~context ~fields:[ "status"; "detail" ] json
      in
      let* detail = json_string ~context "detail" fields in
      if String.equal status "auth_failed"
      then auth_failed ~detail
      else transport_failed ~detail
    | "unsupported_lane" ->
      let context = "probe_result.unsupported_lane" in
      let* fields =
        exact_object ~context ~fields:[ "status"; "lane"; "detail" ] json
      in
      let* lane = json_string ~context "lane" fields >>= probe_lane_of_string in
      let* detail = json_string ~context "detail" fields in
      unsupported_lane ~lane ~detail
    | "not_run" ->
      let context = "probe_result.not_run" in
      let* fields =
        exact_object ~context ~fields:[ "status"; "reason"; "detail" ] json
      in
      let* reason =
        json_string ~context "reason" fields >>= not_run_reason_of_string
      in
      let* detail = json_string_option ~context "detail" fields in
      Ok (not_run ~reason ?detail ())
    | value ->
      Error
        (Printf.sprintf
           "unknown completion probe status %S; expected completed, auth_failed, transport_failed, unsupported_lane, or not_run"
           value)
end

type completion_probe_observation =
  { target : probe_target
  ; requested_role : Runtime.runtime_role
  ; policy_eligibility : Runtime.runtime_role_eligibility
  ; result : Probe_result.t
  }
[@@deriving show, eq]

let completion_probe_observation ~config ~runtime ~requested_role ~result =
  let target = probe_target_of_runtime runtime in
  let policy_eligibility =
    Runtime.runtime_role_eligibility
      config
      ~target_ref:target.runtime_id
      ~role:requested_role
  in
  { target; requested_role; policy_eligibility; result }
;;

let runtime_role_of_string = function
  | "keeper-turn" -> Ok Runtime.Keeper_turn
  | "cross-verification" -> Ok Runtime.Cross_verification
  | "media-failover" -> Ok Runtime.Media_failover
  | "librarian" -> Ok Runtime.Librarian
  | "compaction" -> Ok Runtime.Compaction
  | "hitl-auto-judge" -> Ok Runtime.Hitl_auto_judge
  | "board-attention" -> Ok Runtime.Board_attention
  | value when String.starts_with ~prefix:"exact-output:" value ->
    let prefix_length = String.length "exact-output:" in
    let lane_id = String.sub value prefix_length (String.length value - prefix_length) in
    Result.map
      (fun lane_id -> Runtime.Other_exact_output_lane lane_id)
      (non_blank ~field:"requested_role exact-output lane" lane_id)
  | value -> Error (Printf.sprintf "unknown runtime role %S" value)
;;

let runtime_policy_to_string = function
  | Runtime_schema.Unrestricted -> "unrestricted"
  | Runtime_schema.Librarian_only -> "librarian-only"
;;

let runtime_policy_of_string = function
  | "unrestricted" -> Ok Runtime_schema.Unrestricted
  | "librarian-only" -> Ok Runtime_schema.Librarian_only
  | value -> Error (Printf.sprintf "unknown runtime role policy %S" value)
;;

let probe_target_to_yojson target =
  `Assoc
    [ "runtime_id", `String target.runtime_id
    ; "provider_id", `String target.provider_id
    ; "binding_model_id", `String target.binding_model_id
    ; ( "configured_model_id"
      , match target.configured_model_id with
        | None -> `Null
        | Some value -> `String value )
    ; "lane", `String (probe_lane_to_string target.lane)
    ]
;;

let probe_target_of_yojson json =
  let ( let* ) = Result.bind in
  let context = "completion_probe.target" in
  let* fields =
    exact_object
      ~context
      ~fields:
        [ "runtime_id"; "provider_id"; "binding_model_id"; "configured_model_id"; "lane" ]
      json
  in
  let* runtime_id = json_string ~context "runtime_id" fields >>= non_blank ~field:"runtime_id" in
  let* provider_id =
    json_string ~context "provider_id" fields >>= non_blank ~field:"provider_id"
  in
  let* binding_model_id =
    json_string ~context "binding_model_id" fields
    >>= non_blank ~field:"binding_model_id"
  in
  let* configured_model_id = json_string_option ~context "configured_model_id" fields in
  let* lane = json_string ~context "lane" fields >>= probe_lane_of_string in
  Ok { runtime_id; provider_id; binding_model_id; configured_model_id; lane }
;;

let eligibility_to_yojson = function
  | Runtime.Eligible -> `Assoc [ "status", `String "eligible" ]
  | Runtime.Unsupported { target_ref; policy; requested_role } ->
    `Assoc
      [ "status", `String "unsupported"
      ; "target_ref", `String target_ref
      ; "policy", `String (runtime_policy_to_string policy)
      ; "requested_role", `String (Runtime.runtime_role_to_string requested_role)
      ]
;;

let eligibility_of_yojson json =
  let ( let* ) = Result.bind in
  let* initial =
    match json with
    | `Assoc fields -> Ok fields
    | _ -> Error "completion_probe.policy_eligibility must be a JSON object"
  in
  let context = "completion_probe.policy_eligibility" in
  let* status = json_string ~context "status" initial in
  match status with
  | "eligible" ->
    let* _ = exact_object ~context ~fields:[ "status" ] json in
    Ok Runtime.Eligible
  | "unsupported" ->
    let* fields =
      exact_object
        ~context
        ~fields:[ "status"; "target_ref"; "policy"; "requested_role" ]
        json
    in
    let* target_ref = json_string ~context "target_ref" fields in
    let* policy = json_string ~context "policy" fields >>= runtime_policy_of_string in
    let* requested_role =
      json_string ~context "requested_role" fields >>= runtime_role_of_string
    in
    (match policy, requested_role with
     | Runtime_schema.Unrestricted, _ ->
       Error "unrestricted policy cannot produce unsupported eligibility"
     | Runtime_schema.Librarian_only, Runtime.Librarian ->
       Error "librarian-only policy cannot reject the librarian role"
     | Runtime_schema.Librarian_only, _ ->
       Ok (Runtime.Unsupported { target_ref; policy; requested_role }))
  | value -> Error (Printf.sprintf "unknown policy eligibility status %S" value)
;;

let completion_probe_schema = "masc.keeper.completion-probe.v1"

let completion_probe_observation_to_yojson observation =
  `Assoc
    [ "schema", `String completion_probe_schema
    ; "target", probe_target_to_yojson observation.target
    ; "requested_role", `String (Runtime.runtime_role_to_string observation.requested_role)
    ; "policy_eligibility", eligibility_to_yojson observation.policy_eligibility
    ; "result", Probe_result.to_yojson observation.result
    ]
;;

let completion_probe_observation_of_yojson json =
  let ( let* ) = Result.bind in
  let context = "completion_probe" in
  let* fields =
    exact_object
      ~context
      ~fields:[ "schema"; "target"; "requested_role"; "policy_eligibility"; "result" ]
      json
  in
  let* schema = json_string ~context "schema" fields in
  let* () =
    if String.equal schema completion_probe_schema
    then Ok ()
    else Error (Printf.sprintf "unsupported completion probe schema %S" schema)
  in
  let* target_json = required_field ~context "target" fields in
  let* target = probe_target_of_yojson target_json in
  let* requested_role =
    json_string ~context "requested_role" fields >>= runtime_role_of_string
  in
  let* eligibility_json = required_field ~context "policy_eligibility" fields in
  let* policy_eligibility = eligibility_of_yojson eligibility_json in
  let* () =
    match policy_eligibility with
    | Runtime.Eligible -> Ok ()
    | Runtime.Unsupported { target_ref; requested_role = policy_role; _ } ->
      if not (String.equal target_ref target.runtime_id)
      then Error "policy eligibility target_ref must equal target.runtime_id"
      else if not (Runtime.equal_runtime_role policy_role requested_role)
      then Error "policy eligibility requested_role must equal observation requested_role"
      else Ok ()
  in
  let* result_json = required_field ~context "result" fields in
  let* result = Probe_result.of_yojson result_json in
  Ok { target; requested_role; policy_eligibility; result }
;;

type invocation_error =
  | Not_on_surface of verdict
  | Unresolvable_runtime of string
  | Not_agent_core_lane of string
  | Not_official_client_lane of string
  | Tools_only_via_mcp_bridge of string
  | Not_antigravity_lane of string
  | Antigravity_home_unavailable of string
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
      "%s declares no host-side tool list; use probe_antigravity_invocation, \
       which publishes the MCP bridge the client reads"
      label
  | Not_antigravity_lane label ->
    Printf.sprintf "%s is not the antigravity lane" label
  | Antigravity_home_unavailable detail ->
    Printf.sprintf "antigravity probe home unavailable: %s" detail
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
    (* [_for_turn], not the bare resolver: the bare one yields the provider
       binding without the runtime's inference seed, and a probe that measures a
       request no keeper turn would send measures itself (masc#28473). *)
    (match Runtime_agent_core_runner.resolve_runtime_providers_for_turn ~runtime_id () with
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

(* --- Antigravity lane --- *)

(* The MCP wire shape the bridge advertises. Same three fields
   [Keeper_antigravity_runtime.tool_spec] publishes, so the client sees the
   probe tool in the form a real turn would show it. *)
let mcp_tool_spec (tool : Runtime_official_client_tool.dynamic_tool) =
  `Assoc
    [ "name", `String tool.name
    ; "description", `String tool.description
    ; "inputSchema", tool.input_schema
    ]
;;

(* An owner leaf no keeper can hold. [Runtime_antigravity_home] keys the HOME
   by owner, so this is the discardable session: its own credential copy,
   settings, and MCP config, none of which a keeper turn reads. The other two
   lanes get the same isolation for free by leaving their session mode at the
   default; this lane has to name it. *)
let antigravity_probe_owner_leaf = "capability-probe"

let probe_antigravity_invocation ~sw ~net ~secure_random ~mgr ~clock ~fs ~base_path ~now
    ~runtime_id ~tool ~prompt () =
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
       (match rt.Runtime.execution with
        | Runtime_execution.Agent_core _ | Runtime_execution.Claude_code _
        | Runtime_execution.Codex_app_server _ ->
          Error (Not_antigravity_lane (Runtime_execution.label rt.Runtime.execution))
        | Runtime_execution.Antigravity_cli exec ->
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
             let probe_tool = recording_dynamic_tool ~schema ~seen in
             let runtime_root = Common.masc_dir_from_base_path ~base_path in
             (match
                Runtime_antigravity_home.prepare
                  ~runtime_root
                  ~owner_leaf:antigravity_probe_owner_leaf
                  ~oauth_source:exec.oauth_source
              with
              | Error error ->
                Error
                  (Antigravity_home_unavailable
                     (Runtime_antigravity_home.error_to_string error))
              | Ok home ->
                (* Released with the switch so a probe cannot leave a live MCP
                   URL in a HOME the next probe reuses. *)
                Eio.Switch.on_release sw (fun () ->
                  ignore
                    (Eio.Cancel.protect (fun () ->
                       Runtime_antigravity_home.clear_mcp_config home)
                      : (unit, Runtime_antigravity_home.error) result));
                let bridge =
                  Runtime_official_client_mcp_http.start
                    ~sw
                    ~net
                    ~secure_random
                    ~server_name:"masc"
                    ~tool_specs:(fun () -> [ mcp_tool_spec probe_tool ])
                    ~call_tool:(fun ~name ~call_id ~arguments ->
                      if String.equal name probe_tool.name
                      then (
                        let result = probe_tool.call ~call_id arguments in
                        Some
                          { Runtime_official_client_mcp_http.outcome =
                              { Runtime_official_client_mcp.success = result.success
                              ; content = result.content
                              }
                          ; after_response_sent = (fun () -> ())
                          })
                      else None)
                    ()
                in
                (match
                   Runtime_antigravity_home.publish_mcp_config
                     home
                     (Runtime_official_client_mcp_http.mcp_config_json bridge)
                 with
                 | Error error ->
                   Error
                     (Antigravity_home_unavailable
                        (Runtime_antigravity_home.error_to_string error))
                 | Ok () ->
                   let config : Runtime_antigravity.config =
                     { cli_path = exec.cli_path
                     ; cwd = base_path
                     ; model = exec.model
                     ; agent = exec.agent
                     ; effort = exec.effort
                     ; execution_mode = Plan
                     ; sandbox = true
                     ; disable_slash_commands = true
                     ; admission_timeout_s = exec.timeout_s
                     ; timeout_s =
                         (match Runtime_inference.resolve_turn_timeout_s ~runtime_id with
                          | None -> Some exec.timeout_s
                          | Some 0.0 -> None
                          | Some s -> Some s)
                     }
                   in
                   let started = now () in
                   (match
                      Runtime_antigravity.run_turn
                        ~home_dir:(Runtime_antigravity_home.home_dir home)
                        ~mgr
                        ~clock
                        ~cwd:Eio.Path.(fs / base_path)
                        config
                        ~prompt
                    with
                    | Error error ->
                      Ok
                        (Provider_rejected
                           { detail = Runtime_antigravity.error_to_string error })
                    | Ok (turn : Runtime_antigravity.turn_result) ->
                      Ok
                        (classify_official_client_turn
                           ~model_facing_name
                           ~seen
                           ~elapsed_s:(now () -. started)
                           ~text:turn.text
                           ~dynamic_tool_calls:(List.length !seen))))))))
;;
