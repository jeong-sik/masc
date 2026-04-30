(** Cascade FSM — pure decision logic for multi-provider failover.

    @since 0.120.0 *)

(* ── Types ──────────────────────────────────────── *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of { response : Llm_provider.Types.api_response; reason : string }
  | Slot_full

type decision =
  | Accept of Llm_provider.Types.api_response
  | Accept_on_exhaustion of { response : Llm_provider.Types.api_response; reason : string }
  | Try_next of { last_err : Llm_provider.Http_client.http_error option }
  | Exhausted of { last_err : Llm_provider.Http_client.http_error option }

(* ── Decision function ──────────────────────────── *)

let decide ~accept_on_exhaustion ~is_last outcome =
  match outcome with
  | Call_ok resp ->
    Accept resp
  | Slot_full ->
    Try_next
      {
        last_err =
          Some
            (Llm_provider.Http_client.NetworkError
               {
                 message = "slot full, cascading to next provider";
                 kind = Llm_provider.Http_client.Local_resource_exhaustion;
               });
      }
  | Accept_rejected { response; reason } ->
    if is_last && accept_on_exhaustion then
      Accept_on_exhaustion { response; reason }
    else if is_last then
      Exhausted { last_err = Some (Llm_provider.Http_client.AcceptRejected { reason }) }
    else
      Try_next { last_err = Some (Llm_provider.Http_client.AcceptRejected { reason }) }
  | Call_err err ->
    let should_cascade = Cascade_health_filter.should_cascade_to_next err in
    if should_cascade then
      Try_next { last_err = Some err }
    else
      Exhausted { last_err = Some err }

(* ── Error formatting ───────────────────────────── *)

let format_exhausted_error last_err =
  let msg = match last_err with
    | Some (Llm_provider.Http_client.HttpError { code; body }) ->
      Printf.sprintf "HTTP %d: %s" code
        (String_util.utf8_safe
           ~max_bytes:(Llm_provider.Constants.Truncation.max_error_body_length + 3)
           ~suffix:"..." body
         |> String_util.to_string)
    | Some (Llm_provider.Http_client.AcceptRejected { reason }) -> reason
    | Some (Llm_provider.Http_client.CliTransportRequired { kind }) ->
      Printf.sprintf "%s provider requires a CLI transport" kind
    | Some (Llm_provider.Http_client.NetworkError { message; _ }) -> message
    | Some (Llm_provider.Http_client.ProviderTerminal _ as err) ->
      (* Mirror the rendering shape used elsewhere on main HEAD
         (tool_local_runtime_bench / verify): "provider terminal:
         <kind>: <message>". The boundary adapter
         [Oas_compat.Http_client.error_message] supplies that exact
         format, so future variant additions only break the adapter. *)
      Oas_compat.Http_client.error_message err
    | Some (Llm_provider.Http_client.ProviderFailure _ as err) ->
      Oas_compat.Http_client.error_message err
    | None -> "No providers available"
  in
  let network_error_kind =
    match last_err with
    | Some (Llm_provider.Http_client.NetworkError { kind; _ }) -> kind
    | _ -> Unknown
  in
  match last_err with
  | Some (Llm_provider.Http_client.AcceptRejected _ as err) -> err
  | _ ->
    Llm_provider.Http_client.NetworkError
      {
        message = Printf.sprintf "All models failed: %s" msg;
        kind = network_error_kind;
      }

(* ── Inline tests ───────────────────────────────── *)
