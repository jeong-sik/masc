(* Fusion — OAS 호출 공유 글루 (구현).
   계약/문서: fusion_oas.mli, docs/rfc/RFC-0251 §7

   OAS 범용 함수만 소비: Runtime_oas_runner(id→provider) → Runtime_agent(build).
   fusion 개념은 OAS에 노출하지 않는다. *)

let answer_text (resp : Agent_sdk.Types.api_response) : string =
  resp.content
  |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
  |> String.concat "\n"

let usage_of (resp : Agent_sdk.Types.api_response) : Fusion_types.usage =
  match resp.usage with
  | Some u ->
    { Fusion_types.input_tokens = u.Agent_sdk.Types.input_tokens
    ; output_tokens = u.Agent_sdk.Types.output_tokens
    }
  | None -> Fusion_types.zero_usage

let build_agent ~sw ~net ~system_prompt (model : string)
  : (Agent_sdk.Agent.t, Fusion_types.panel_failure) result
  =
  match Runtime_oas_runner.resolve_runtime_providers ~runtime_id:model () with
  | Error e -> Error (Fusion_types.Provider_error e)
  | Ok [] -> Error (Fusion_types.Provider_error (model ^ ": no provider config"))
  | Ok (provider_cfg :: _) ->
    (* v1: runtime이 여러 provider를 주면 첫 번째만(단일 provider 가정). *)
    let config =
      Runtime_agent.default_config ~name:model ~provider_cfg ~system_prompt ~tools:[]
    in
    (match Runtime_agent.build ~sw ~net ~config with
     | Ok agent -> Ok agent
     | Error e -> Error (Fusion_types.Provider_error (Agent_sdk.Error.to_string e)))
