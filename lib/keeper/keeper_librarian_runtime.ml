(** Keeper_librarian_runtime — LLM invocation wrapper for the librarian.

    Uses the default runtime's provider config via [Llm_provider.Complete]
    and parses the response with [Keeper_librarian.episode_of_output].
    Eio resources are obtained from fiber-local [Eio_context] so callers
    outside the immediate Eio fiber do not need to thread [sw]/[net]
    explicitly. *)

open Keeper_memory_os_types

let response_text (response : Agent_sdk.Types.api_response) : string option =
  let text =
    response.content
    |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> String.concat "\n"
    |> String.trim
  in
  if text = "" then None else Some text
;;

let librarian_prompt_messages (prompt : string) : Agent_sdk.Types.message list =
  let open Agent_sdk.Types in
  [ { role = System
    ; content = [ Text "You are a structured JSON librarian. Output ONLY valid JSON matching the requested schema." ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ; { role = User
    ; content = [ Text prompt ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ]
;;

let provider_for_librarian (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    Llm_provider.Provider_config.max_tokens = Some 2048
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.Off
  ; output_schema = None
  }
;;

let make ~trace_id ~generation () : Keeper_compact_policy.librarian_callback option =
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net ->
    let clock = Eio_context.get_clock_opt () in
    (match Runtime.get_default_runtime () with
     | Some runtime ->
       let provider_cfg = runtime.Runtime.provider_config in
       if not (Keeper_memory_llm_summary.is_direct_completion_provider provider_cfg)
       then (
         Log.Keeper.warn
           "librarian runtime skipped: provider %s does not support direct completion"
           provider_cfg.Llm_provider.Provider_config.model_id;
         None)
       else (
         let provider_cfg = provider_for_librarian provider_cfg in
         Some
           (fun messages ->
              let inp : Keeper_librarian.input =
                { Keeper_librarian.trace_id; generation; messages }
              in
              let prompt = Keeper_librarian.prompt_of_input inp in
              let llm_messages = librarian_prompt_messages prompt in
              (match
                 Llm_provider.Complete.complete
                   ~sw
                   ~net
                   ?clock
                   ~config:provider_cfg
                   ~messages:llm_messages
                   ()
               with
               | Ok response ->
                 (match response_text response with
                  | Some raw -> Keeper_librarian.episode_of_output inp raw
                  | None ->
                    Log.Keeper.warn
                      "librarian empty response trace_id=%s generation=%d"
                      trace_id
                      generation;
                    None)
               | Error err ->
                 Log.Keeper.warn
                   "librarian LLM call failed trace_id=%s generation=%d: %s"
                   trace_id
                   generation
                   (match err with
                    | Llm_provider.Http_client.NetworkError { message; _ } -> message
                    | Llm_provider.Http_client.TimeoutError { message; phase } ->
                      Printf.sprintf
                        "provider timeout: %s: %s"
                        (Llm_provider.Http_client.timeout_phase_to_label phase)
                        message
                    | Llm_provider.Http_client.AcceptRejected { reason } -> reason
                    | Llm_provider.Http_client.ProviderTerminal { message; _ } ->
                      Printf.sprintf "provider terminal: %s" message
                    | Llm_provider.Http_client.ProviderFailure { kind; message } ->
                      Llm_provider.Http_client.provider_failure_to_string ~kind ~message
                    | Llm_provider.Http_client.HttpError { code; body } ->
                      Printf.sprintf
                        "HTTP %d: %s"
                        code
                        (if String.length body > 200
                         then String.sub body 0 200 ^ "..."
                         else body));
                 None)))
     | None ->
       Log.Keeper.warn "librarian runtime skipped: no default runtime configured";
       None)
  | _ ->
    Log.Keeper.warn "librarian runtime skipped: Eio context unavailable";
    None
;;
