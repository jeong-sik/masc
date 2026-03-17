(** Llm_transport — UTF-8 sanitization, endpoint resolution, and legacy JSON encoding.

    Request building, HTTP execution, response parsing, and provider dispatch
    have been delegated to {!Llm_provider_bridge} (cohttp-eio via OAS).

    @since 2.103.0 — trimmed for v0.49 transport delegation *)

open Printf
open Llm_types

(* ================================================================ *)
(* UTF-8 Sanitization                                               *)
(* ================================================================ *)

let sanitize_text_utf8 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then (
        Buffer.add_substring buf s i dlen;
        loop (i + dlen))
      else (
        Buffer.add_string buf "\xEF\xBF\xBD";
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let sanitize_message_utf8 (m : message) : message =
  {
    m with
    content = [Agent_sdk.Types.Text (sanitize_text_utf8 (text_of_message m))];
    name = Option.map sanitize_text_utf8 m.name;
    tool_call_id = Option.map sanitize_text_utf8 m.tool_call_id;
  }

let sanitize_messages_utf8 (msgs : message list) : message list =
  List.map sanitize_message_utf8 msgs

(* ================================================================ *)
(* Legacy JSON Encoding — kept for cache fingerprinting             *)
(* ================================================================ *)

let message_to_openai_json (m : message) : Yojson.Safe.t =
  let base = [
    ("role", `String (string_of_role m.role));
    ("content", `String (text_of_message m));
  ] in
  let with_name = match m.name with
    | Some n -> ("name", `String n) :: base
    | None -> base
  in
  let with_id = match m.tool_call_id with
    | Some id -> ("tool_call_id", `String id) :: with_name
    | None -> with_name
  in
  `Assoc with_id

(* ================================================================ *)
(* API Key & Endpoint Resolution                                    *)
(* ================================================================ *)

let get_api_key (spec : model_spec) : string =
  match spec.api_key_env with
  | Some env_var -> Sys.getenv_opt env_var |> Option.value ~default:""
  | None -> ""

let fetch_vertex_adc_access_token () =
  let manual_override = Sys.getenv_opt "MASC_VERTEX_ACCESS_TOKEN" |> Option.value ~default:"" |> String.trim in
  if manual_override <> "" then Ok manual_override
  else
    let status, output =
      Process_eio.run_argv_with_status
        ~timeout_sec:Env_config_runtime.Timeout.gcloud_auth_sec
        [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
    in
    match status with
    | Unix.WEXITED 0 ->
        let token = String.trim output in
        if token = "" then
          Error "Gemini Vertex ADC unavailable; run gcloud auth application-default login"
        else Ok token
    | _ ->
        Error "Gemini Vertex ADC unavailable; run gcloud auth application-default login"

let resolve_openai_compatible_endpoint (spec : model_spec) =
  match spec.provider with
  | Gemini -> (
      match Provider_adapter.resolve_gemini_direct_auth () with
      | Provider_adapter.Gemini_vertex_adc { project; location } -> (
          match fetch_vertex_adc_access_token () with
          | Ok access_token ->
              Ok
                ( Provider_adapter.gemini_vertex_openai_base_url ~project ~location,
                  "/chat/completions",
                  [ ("Authorization", sprintf "Bearer %s" access_token) ] )
          | Error _ as e -> e)
      | Provider_adapter.Gemini_api_key ->
          let api_key = get_api_key spec in
          if api_key = "" then
            Error
              "Gemini auth unavailable; set GOOGLE_CLOUD_PROJECT for Vertex ADC or GEMINI_API_KEY"
          else
            Ok
              ( spec.api_url,
                "/v1beta/openai/chat/completions",
                [ ("Authorization", sprintf "Bearer %s" api_key) ] )
      | Provider_adapter.Gemini_auth_missing message -> Error message)
  | OpenAI ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "OPENAI_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/v1/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | Glm_cloud ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "ZAI_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/api/coding/paas/v4/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | OpenRouter ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "OPENROUTER_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/v1/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | Claude ->
      Error "Claude uses Anthropic provider via Llm_provider_bridge"
  | Llama -> Ok (spec.api_url, "/v1/chat/completions", [])
  | Custom _ ->
      let auth_headers =
        match get_api_key spec with
        | "" -> []
        | api_key -> [ ("Authorization", sprintf "Bearer %s" api_key) ]
      in
      Ok (spec.api_url, "/v1/chat/completions", auth_headers)
