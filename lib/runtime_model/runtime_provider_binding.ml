(** Provider identity helpers shared across {!Runtime_config} submodules.

    Extracted from the original [runtime_config.ml] godfile to give the
    parsing/selection/resolve/strategy submodules a stable lowest layer.
    Surface is unchanged: {!Runtime_config} re-exports every function in
    this module so external callers continue to use the facade.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding

let normalize_provider_id provider_id =
  String.trim provider_id
  |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)
;;

let binding_auth_is_no_auth (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Api_key
  | Runtime_binding.Setup_token -> false
;;

let binding_base_url_is_loopback (binding : Runtime_binding.t) =
  let base_url = String.trim binding.Runtime_binding.base_url in
  if base_url = ""
  then false
  else Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_binding (binding : Runtime_binding.t) =
  if binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
  then "local"
  else "direct_api"
;;

let is_binding_local_openai_runtime (binding : Runtime_binding.t) =
  binding.Runtime_binding.kind = Llm_provider.Provider_config.OpenAI_compat
  && String.equal (runtime_kind_of_binding binding) "local"
;;

let default_local_openai_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt is_binding_local_openai_runtime
  |> Option.map (fun binding -> binding.Runtime_binding.id)
;;

let local_runtime_label runtime_id =
  match default_local_openai_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ runtime_id
  | None -> runtime_id
;;

let default_headers_for_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let base = [ ("Content-Type", "application/json") ] in
  match kind with
  | Anthropic -> ("anthropic-version", "2023-06-01") :: base
  | OpenAI_compat | Ollama | Gemini | Glm | Kimi -> base
;;

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path then
    String.sub path 0 (String.length path - 1)
  else path

let is_digit c = c >= '0' && c <= '9'

let is_version_segment s =
  let len = String.length s in
  len >= 2
  && s.[0] = 'v'
  && let rec all_digits i =
       i >= len || (is_digit s.[i] && all_digits (i + 1))
     in
     all_digits 1

let last_path_segment path =
  match String.rindex_opt path '/' with
  | Some idx -> String.sub path (idx + 1) (String.length path - idx - 1)
  | None -> path

let strip_leading_version request_path =
  let len = String.length request_path in
  if len >= 4 && request_path.[0] = '/' && request_path.[1] = 'v'
     && is_digit request_path.[2]
  then
    let rec find_slash i =
      if i >= len then len
      else if request_path.[i] = '/' then i
      else find_slash (i + 1)
    in
    let slash_pos = find_slash 2 in
    String.sub request_path slash_pos (len - slash_pos)
  else
    request_path

let normalize_openai_compat_request_path ~base_url ~request_path =
  let request_path =
    match String.trim request_path with
    | "" -> Masc_network_defaults.openai_chat_completions_path
    | path -> path
  in
  let base_path =
    Uri.path (Uri.of_string base_url) |> trim_trailing_slash
  in
  if base_path = "" || base_path = "/" then
    request_path
  else
    let duplicated_prefix = base_path ^ "/" in
    if String.starts_with ~prefix:duplicated_prefix request_path then
      let suffix_start = String.length base_path + 1 in
      "/"
      ^ String.sub request_path suffix_start
          (String.length request_path - suffix_start)
    else if is_version_segment (last_path_segment base_path)
         && String.length request_path >= 4
         && request_path.[0] = '/'
         && request_path.[1] = 'v'
         && is_digit request_path.[2]
    then
      strip_leading_version request_path
    else
      request_path
