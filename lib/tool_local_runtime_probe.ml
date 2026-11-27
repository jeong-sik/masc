(** Tool_local_runtime_probe -- native Ollama timing and warm-state diagnostics. *)

include Tool_local_runtime_http

type ollama_loaded_model = {
  name : string option;
  model : string option;
  size_vram_bytes : int option;
  context_length : int option;
  expires_at : string option;
}

type ollama_probe_run = {
  run_index : int;
  http_status : int option;
  wall_clock_ms : int;
  total_duration_ms : float option;
  load_duration_ms : float option;
  prompt_eval_count : int option;
  prompt_eval_duration_ms : float option;
  prompt_tokens_per_second : float option;
  eval_count : int option;
  eval_duration_ms : float option;
  generation_tokens_per_second : float option;
  done_flag : bool option;
  done_reason : string option;
  thinking_present : bool;
  response_preview : string option;
  response_chars : int option;
  error : string option;
}

type ollama_probe_think_mode =
  | Think_auto
  | Think_disabled
  | Think_enabled

type generate_probe_skip_reason =
  | No_effective_model
  | Status_only
  | Ps_preflight_error
  | Model_unloaded
  | Policy_skip

type generate_probe_decision =
  | Run_generate_probe
  | Skip_generate_probe of generate_probe_skip_reason


let validate_timeout_sec value =
  if value > 0 then
    Ok value
  else
    Error
      (Printf.sprintf "timeout_sec must be a positive integer (got %d)" value)

(* #24851 removed the silent [3, 300] rewrite from [timeout_sec] because a
   diagnostic tool that answers a different question than it was asked is
   worse than one that refuses. The same argument covers the knobs beside it:
   a caller asking for 10 runs and getting 4 back under an ok response cannot
   tell the difference from having got 10. These bound the same way -- state
   the range, accept inside it, reject outside it -- so the range appears in
   the schema, in the rejection text, and in one place in code (#25006). *)
let validate_in_range ~field ~min_value ~max_value value =
  if value >= min_value && value <= max_value then
    Ok value
  else
    Error
      (Printf.sprintf
         "%s must be an integer in [%d, %d] (got %d)"
         field
         min_value
         max_value
         value)

let probe_runs_min = 1
let probe_runs_max = 4
let max_tokens_min = 1
let max_tokens_max = 128
let ps_timeout_sec_min = 1
let ps_timeout_sec_max = 30

let validate_probe_runs =
  validate_in_range ~field:"probe_runs" ~min_value:probe_runs_min
    ~max_value:probe_runs_max

let validate_max_tokens =
  validate_in_range ~field:"max_tokens" ~min_value:max_tokens_min
    ~max_value:max_tokens_max

let validate_ps_timeout_sec =
  validate_in_range ~field:"ps_timeout_sec" ~min_value:ps_timeout_sec_min
    ~max_value:ps_timeout_sec_max

let normalize_ollama_server_url raw =
  String.trim raw |> Masc_network_defaults.trim_trailing_slashes

let ipv4_link_local_prefix = Ipaddr.V4.Prefix.of_string_exn "169.254.0.0/16"
let ipv6_link_local_prefix = Ipaddr.V6.Prefix.of_string_exn "fe80::/10"
let ipv6_nat64_well_known = Ipaddr.V6.Prefix.of_string_exn "64:ff9b::/96"
let ipv6_aws_imds = Ipaddr.V6.of_string_exn "fd00:ec2::254"

let is_disallowed_ollama_v4 v4 =
  Ipaddr.V4.Prefix.(mem v4 relative)
  || Ipaddr.V4.Prefix.mem v4 ipv4_link_local_prefix

let nat64_embedded_v4 v6 =
  Ipaddr.V4.of_octets_exn ~off:12 (Ipaddr.V6.to_octets v6)

let is_disallowed_ollama_ip = function
  | Ipaddr.V4 v4 -> is_disallowed_ollama_v4 v4
  | Ipaddr.V6 v6 ->
      Ipaddr.V6.compare v6 Ipaddr.V6.unspecified = 0
      || Ipaddr.V6.Prefix.mem v6 ipv6_link_local_prefix
      || Ipaddr.V6.compare v6 ipv6_aws_imds = 0
      || (Ipaddr.V6.Prefix.mem v6 ipv6_nat64_well_known
          && is_disallowed_ollama_v4 (nat64_embedded_v4 v6))
      || (match Ipaddr.v4_of_v6 v6 with
          | Some v4 -> is_disallowed_ollama_v4 v4
          | None -> false)

let is_ascii_digit = function '0' .. '9' -> true | _ -> false
let is_ascii_hex = function '0' .. '9' | 'a' .. 'f' -> true | _ -> false
let is_ascii_alpha = function 'a' .. 'z' -> true | _ -> false

let is_valid_dns_label label =
  let len = String.length label in
  len > 0
  && not (Char.equal label.[0] '-')
  && not (Char.equal label.[len - 1] '-')
  && String.for_all
       (fun ch -> is_ascii_alpha ch || is_ascii_digit ch || Char.equal ch '-')
       label

(* Matches any label that inet_aton / curl can parse as a decimal, octal, or
   0x-hex IPv4 component (e.g. 2852039166, 0xa9fea9fe, 0251, 43518). *)
let is_numeric_ipv4_label label =
  let len = String.length label in
  if len = 0 then false
  else if len >= 2 && Char.equal label.[0] '0' && Char.equal label.[1] 'x' then
    let rec all_hex i =
      if i >= len then true
      else is_ascii_hex label.[i] && all_hex (i + 1)
    in
    all_hex 2
  else
    String.for_all is_ascii_digit label

(* Reject non-canonical numeric/hex/octal/shorthand IPv4 spellings, malformed
   or zone-scoped IPv6 literals, empty labels, and invalid DNS characters.
   Non-IP DNS hostnames must consist of valid labels and contain at least one
   non-numeric (alphabetic) label. *)
let is_non_canonical_or_invalid_hostname ~bracketed bare =
  if bracketed || String.contains bare ':' || String.contains bare '%' then true
  else
    let labels = String.split_on_char '.' bare in
    match labels with
    | [] -> true
    | _ ->
        List.exists (fun label -> not (is_valid_dns_label label)) labels
        || List.for_all is_numeric_ipv4_label labels

let strip_ipv6_brackets s =
  if String.length s >= 2
     && Char.equal s.[0] '['
     && Char.equal s.[String.length s - 1] ']'
  then (true, String.sub s 1 (String.length s - 2))
  else (false, s)

let authority_has_percent url =
  match String.index_opt url ':' with
  | None -> false
  | Some idx ->
      let start = idx + 3 in
      if start >= String.length url then false
      else
        let stop =
          match String.index_from_opt url start '/' with
          | Some slash -> slash
          | None -> String.length url
        in
        let rec scan i =
          if i >= stop then false
          else Char.equal url.[i] '%' || scan (i + 1)
        in
        scan start

let is_disallowed_ollama_host host =
  let lower = String.lowercase_ascii (String.trim host) in
  let dotless =
    if String.ends_with ~suffix:"." lower then
      String.sub lower 0 (String.length lower - 1)
    else lower
  in
  if String.equal dotless "metadata.google.internal"
     || String.equal dotless "metadata.goog"
  then true
  else
    let bracketed, bare = strip_ipv6_brackets dotless in
    match Ipaddr.of_string bare with
    | Error _ -> is_non_canonical_or_invalid_hostname ~bracketed bare
    | Ok ip -> is_disallowed_ollama_ip ip

let validate_ollama_server_url raw =
  let normalized = normalize_ollama_server_url raw in
  if String.equal normalized "" then
    Error "server_url must not be empty"
  else if String.exists (fun ch -> let code = Char.code ch in code <= 0x20 || code = 0x7f) normalized then
    Error "server_url must not contain spaces or control characters"
  else if authority_has_percent normalized then
    Error "server_url host must not contain percent-encoding"
  else
    let uri = Uri.of_string normalized in
    match Uri.scheme uri with
    | Some ("http" | "https") ->
        (match Uri.host uri with
         | None -> Error "server_url must include a host"
         | Some host when String.equal (String.trim host) "" ->
             Error "server_url must include a host"
         | Some host when is_disallowed_ollama_host host ->
             Error "server_url host is not allowed (link-local, metadata, unspecified, or non-canonical numeric address)"
         | Some _ ->
             if Option.is_some (Uri.userinfo uri) then
               Error "server_url must not include userinfo"
             else if Uri.query uri <> [] then
               Error "server_url must not include a query string"
             else if Option.is_some (Uri.fragment uri) then
               Error "server_url must not include a fragment"
             else if List.exists (String.equal "..") (String.split_on_char '/' (Uri.path uri)) then
               Error "server_url path must not contain '..'"
             else
               (match Uri.port uri with
                | Some p when p < 1 || p > 65535 ->
                    Error "server_url port must be between 1 and 65535"
                | Some _ | None -> Ok normalized))
    | Some _ | None ->
        Error "server_url must use http or https scheme"

let resolve_ollama_host_addrs ~host ~port =
  let service = Int.to_string port in
  match Eio_context.get_net_opt () with
  | Some net ->
      (try
         let addrs =
           Eio_context.run_on_owner_domain (fun () ->
             Eio.Net.getaddrinfo_stream ~service net host)
         in
         let ips =
           List.filter_map
             (function
               | `Tcp (ip, _) -> Some (Outbound_address.ipaddr_of_eio ip)
               | `Unix _ -> None)
             addrs
         in
         Ok ips
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
           Error
             (Printf.sprintf "could not resolve host %s: %s" host
                (Printexc.to_string exn)))
  | None ->
      Eio_guard.run_in_systhread ~label:"ollama-probe-dns" (fun () ->
        try
          let infos =
            Unix.getaddrinfo host service [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
          in
          let ips =
            List.filter_map
              (fun (info : Unix.addr_info) ->
                match info.Unix.ai_addr with
                | Unix.ADDR_INET (inet, _) ->
                    Ipaddr.of_string (Unix.string_of_inet_addr inet)
                    |> Result.to_option
                | Unix.ADDR_UNIX _ -> None)
              infos
          in
          Ok ips
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            Error
              (Printf.sprintf "could not resolve host %s: %s" host
                 (Printexc.to_string exn)))

let pin_ollama_resolution ~resolve server_url =
  let uri = Uri.of_string server_url in
  match Uri.host uri with
  | None -> Error "server_url must include a host"
  | Some host ->
      let trimmed = String.trim host in
      if String.equal trimmed "" then Error "server_url must include a host"
      else
        let _bracketed, bare = strip_ipv6_brackets trimmed in
        let bare_dotless =
          if String.ends_with ~suffix:"." bare then
            String.sub bare 0 (String.length bare - 1)
          else bare
        in
        match Ipaddr.of_string bare_dotless with
        | Ok ip ->
            if is_disallowed_ollama_ip ip then
              Error
                "server_url host is not allowed (link-local, metadata, or unspecified address)"
            else
              (* An IP literal names its own address; curl makes no DNS lookup. *)
              Ok None
        | Error _ ->
            let port = Outbound_address.port_of_uri uri in
            (match resolve ~host:trimmed ~port with
             | Error _ as err -> err
             | Ok [] -> Error (Printf.sprintf "could not resolve host %s" trimmed)
             | Ok (first_address :: other_addresses as ips) ->
                 if List.exists is_disallowed_ollama_ip ips then
                   Error
                     "server_url resolved to a disallowed address (link-local, metadata, or unspecified address)"
                 else
                   Ok
                     (Some
                        { host = trimmed
                        ; port
                        ; first_address
                        ; other_addresses
                        }))

let resolve_ollama_pinned_resolution server_url =
  pin_ollama_resolution ~resolve:resolve_ollama_host_addrs server_url

module For_testing = struct
  let pin_ollama_resolution = pin_ollama_resolution
end

let ollama_ps_url server_url =
  normalize_ollama_server_url server_url
  ^ Masc_network_defaults.ollama_api_ps_path

let ollama_generate_url server_url =
  normalize_ollama_server_url server_url
  ^ Masc_network_defaults.ollama_api_generate_path

let ollama_http_error operation http_status =
  match http_status with
  | Some code -> Printf.sprintf "ollama %s returned http %d" operation code
  | None -> Printf.sprintf "ollama %s returned http unknown" operation

let ns_to_ms value =
  value |> Option.map (fun ns -> Stdlib.Float.of_int ns /. 1_000_000.0)

let tok_per_second ~count ~duration_ms =
  match count, duration_ms with
  | Some token_count, Some elapsed_ms when token_count > 0 && Stdlib.Float.compare elapsed_ms 0.0 > 0 ->
      Some (Stdlib.Float.of_int token_count /. (elapsed_ms /. 1000.0))
  | _ -> None

let collapse_preview text =
  text
  |> String.map (function '\n' | '\r' | '\t' -> ' ' | ch -> ch)
  |> String.trim

let truncate_text ?(max_len = 160) text =
  String_util.to_string (String_util.utf8_safe ~max_bytes:max_len ~suffix:"...[truncated]" text)

let ollama_probe_think_mode_to_string = function
  | Think_auto -> "auto"
  | Think_disabled -> "disabled"
  | Think_enabled -> "enabled"

let ollama_probe_think_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "auto" -> Some Think_auto
  | "false" | "disabled" | "off" | "no" -> Some Think_disabled
  | "true" | "enabled" | "on" | "yes" -> Some Think_enabled
  | _ -> None

let effective_think_enabled = function
  | Think_enabled -> true
  | Think_auto | Think_disabled -> false

let generate_probe_skip_reason_to_string = function
  | No_effective_model -> "no_effective_model"
  | Status_only -> "status_only"
  | Ps_preflight_error -> "ps_error"
  | Model_unloaded -> "model_unloaded"
  | Policy_skip -> "policy_skip"

let generate_probe_decision_to_string = function
  | Run_generate_probe -> "run_generate"
  | Skip_generate_probe reason -> generate_probe_skip_reason_to_string reason

let string_or_fallback candidates =
  let rec loop = function
    | [] -> None
    | getter :: rest -> (
        match getter () with Some _ as value -> value | None -> loop rest)
  in
  loop candidates

let loaded_model_name (model : ollama_loaded_model) =
  string_or_fallback
    [
      (fun () -> model.name);
      (fun () -> model.model);
    ]

let ollama_loaded_model_to_yojson (model : ollama_loaded_model) =
  `Assoc
    [
      ("name", Json_util.string_opt_to_json model.name);
      ("model", Json_util.string_opt_to_json model.model);
      ("size_vram_bytes", Json_util.int_opt_to_json model.size_vram_bytes);
      ("context_length", Json_util.int_opt_to_json model.context_length);
      ("expires_at", Json_util.string_opt_to_json model.expires_at);
    ]

let ollama_probe_run_to_yojson (run : ollama_probe_run) =
  `Assoc
    [
      ("run_index", `Int run.run_index);
      ("http_status", Json_util.int_opt_to_json run.http_status);
      ("wall_clock_ms", `Int run.wall_clock_ms);
      ("total_duration_ms", Json_util.float_opt_to_json run.total_duration_ms);
      ("load_duration_ms", Json_util.float_opt_to_json run.load_duration_ms);
      ("prompt_eval_count", Json_util.int_opt_to_json run.prompt_eval_count);
      ("prompt_eval_duration_ms", Json_util.float_opt_to_json run.prompt_eval_duration_ms);
      ("prompt_tokens_per_second", Json_util.float_opt_to_json run.prompt_tokens_per_second);
      ("eval_count", Json_util.int_opt_to_json run.eval_count);
      ("eval_duration_ms", Json_util.float_opt_to_json run.eval_duration_ms);
      ("generation_tokens_per_second", Json_util.float_opt_to_json run.generation_tokens_per_second);
      ("done", Json_util.bool_opt_to_json run.done_flag);
      ("done_reason", Json_util.string_opt_to_json run.done_reason);
      ("thinking_present", `Bool run.thinking_present);
      ("response_preview", Json_util.string_opt_to_json run.response_preview);
      ("response_chars", Json_util.int_opt_to_json run.response_chars);
      ("error", Json_util.string_opt_to_json run.error);
    ]

let ollama_loaded_models_of_ps_json json =
  let items =
    match json with
    | `Assoc _ -> (
        match Json_util.assoc_member_opt "models" json with
        | Some (`List models) -> models
        | _ -> [])
    | `List models -> models
    | _ -> []
  in
  items
  |> List.map (fun item ->
         {
           name = string_or_fallback [ (fun () -> string_member item "name"); (fun () -> string_member item "id") ];
           model =
             string_or_fallback
               [
                 (fun () -> string_member item "model");
                 (fun () -> string_member item "name");
                 (fun () -> string_member item "id");
               ];
           size_vram_bytes = int_member item "size_vram";
           context_length = int_member item "context_length";
           expires_at = string_member item "expires_at";
         })
  |> List.map ollama_loaded_model_to_yojson

let prompt_eval_duration_ms_of_run_json json =
  match Json_util.assoc_member_opt "prompt_eval_duration_ms" json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (Stdlib.Float.of_int value)
  | Some (`Intlit value) -> Option.map Stdlib.Float.of_int (parse_int_opt value)
  | _ -> None

let ollama_probe_run_of_generate_json ~run_index ~http_status ~wall_clock_ms json =
  let duration_ms key = int_member json key |> ns_to_ms in
  let response =
    match Json_util.get_string json "response" with
    | Some value ->
        let preview = value |> collapse_preview |> truncate_text in
        Some preview
    | None -> None
  in
  let response_chars =
    match Json_util.get_string json "response" with
    | Some value -> Some (String.length value)
    | None -> None
  in
  let prompt_eval_count = int_member json "prompt_eval_count" in
  let prompt_eval_duration_ms = duration_ms "prompt_eval_duration" in
  let eval_count = int_member json "eval_count" in
  let eval_duration_ms = duration_ms "eval_duration" in
  {
    run_index;
    http_status;
    wall_clock_ms;
    total_duration_ms = duration_ms "total_duration";
    load_duration_ms = duration_ms "load_duration";
    prompt_eval_count;
    prompt_eval_duration_ms;
    prompt_tokens_per_second =
      tok_per_second ~count:prompt_eval_count ~duration_ms:prompt_eval_duration_ms;
    eval_count;
    eval_duration_ms;
    generation_tokens_per_second =
      tok_per_second ~count:eval_count ~duration_ms:eval_duration_ms;
    done_flag = Json_util.get_bool json "done" ;
    done_reason = string_member json "done_reason";
    thinking_present =
      (match Json_util.assoc_member_opt "thinking" json with
      | Some `Null -> false
      | Some (`String value) -> not (String.equal (String.trim value) "")
      | Some (`List []) -> false
      | Some (`Assoc []) -> false
      | Some _ -> true
      | None -> false);
    response_preview = response;
    response_chars;
    error = None;
  }

let failed_probe_run ~run_index ~http_status ~wall_clock_ms ~error =
  {
    run_index;
    http_status;
    wall_clock_ms;
    total_duration_ms = None;
    load_duration_ms = None;
    prompt_eval_count = None;
    prompt_eval_duration_ms = None;
    prompt_tokens_per_second = None;
    eval_count = None;
    eval_duration_ms = None;
    generation_tokens_per_second = None;
    done_flag = None;
    done_reason = None;
    thinking_present = false;
    response_preview = None;
    response_chars = None;
    error = Some error;
  }

let kv_cache_assessment_json run_jsons =
  let runs =
    run_jsons
    |> List.filter_map (fun json ->
           match prompt_eval_duration_ms_of_run_json json with
           | Some duration_ms ->
               let run_index =
                 match Json_util.assoc_member_opt "run_index" json with
                 | Some (`Int value) -> Some value
                 | Some (`Intlit value) -> parse_int_opt value
                 | _ -> None
               in
               Some (run_index, duration_ms)
           | None -> None)
  in
  match runs with
  | [] | [ _ ] ->
      `Assoc
        [
          ("signal", `String "insufficient_data");
          ("baseline_run_index", `Null);
          ("best_repeat_run_index", `Null);
          ("baseline_prompt_eval_duration_ms", `Null);
          ("best_repeat_prompt_eval_duration_ms", `Null);
          ("prompt_eval_duration_reduction_ratio", `Null);
          ( "note",
            `String
              "Need at least two successful runs with prompt_eval_duration_ms to infer repeated-prefix reuse." );
        ]
  | (baseline_run_index, baseline_ms) :: rest ->
      let best_repeat_run_index, best_repeat_ms =
        match rest with
        | first_repeat :: remaining_repeats ->
            List.fold_left
              (fun ((_best_idx, best_ms) as best) candidate ->
                let _candidate_idx, candidate_ms = candidate in
                if Stdlib.Float.compare candidate_ms best_ms < 0 then
                  candidate
                else
                  best)
              first_repeat remaining_repeats
        | [] -> (None, baseline_ms)
      in
      let reduction_ratio =
        if Stdlib.Float.compare baseline_ms 0.0 > 0 then
          Some ((baseline_ms -. best_repeat_ms) /. baseline_ms)
        else
          None
      in
      let signal, note =
        match reduction_ratio with
        | Some ratio when Stdlib.Float.compare ratio 0.35 >= 0 ->
            ( "likely_reused",
              "Prompt evaluation time dropped materially on a repeated prompt. Timing suggests warm repeated-prefix reuse." )
        | Some ratio when Stdlib.Float.compare ratio 0.15 >= 0 ->
            ( "possible_reuse",
              "Prompt evaluation time improved on a repeated prompt, but not enough to treat as a strong signal." )
        | Some _ ->
            ( "no_visible_reuse",
              "Repeated prompt evaluation time did not improve enough to show an obvious reuse signal." )
        | None ->
            ( "insufficient_data",
              "Prompt evaluation duration was missing or zero, so reuse could not be inferred." )
      in
      `Assoc
        [
          ("signal", `String signal);
          ("baseline_run_index", Json_util.int_opt_to_json baseline_run_index);
          ("best_repeat_run_index", Json_util.int_opt_to_json best_repeat_run_index);
          ("baseline_prompt_eval_duration_ms", `Float baseline_ms);
          ("best_repeat_prompt_eval_duration_ms", `Float best_repeat_ms);
          ("prompt_eval_duration_reduction_ratio", Json_util.float_opt_to_json reduction_ratio);
          ("note", `String note);
          ( "limitation",
            `String
              "Inference only: stable Ollama APIs expose warm state and timings, not direct KV occupancy or hit-rate." );
        ]

let default_probe_prompt () =
  let line =
    "This is a repeated-prefix timing probe for Ollama native generate. Respond with exactly READY."
  in
  String.concat "\n"
    [
      line;
      line;
      line;
      line;
      line;
      line;
      line;
      line;
    ]

let fetch_ollama_ps ?(timeout_sec = 8) ?pinned_resolution ~server_url () =
  let url = ollama_ps_url server_url in
  match http_get_json_with_status ~timeout_sec ?pinned_resolution url with
  | Ok (http_status, json) ->
      if not (Option.equal Int.equal http_status (Some 200)) then
        (http_status, [], Some (ollama_http_error "ps" http_status))
      else
        let models =
          ollama_loaded_models_of_ps_json json
          |> List.filter_map (fun item ->
                 match item with
                 | `Assoc _ -> (
                     Some
                       {
                         name = Json_util.get_string item "name";
                         model = Json_util.get_string item "model";
                         size_vram_bytes = int_member item "size_vram_bytes";
                         context_length = int_member item "context_length";
                         expires_at = Json_util.get_string item "expires_at";
                       })
                 | _ -> None)
        in
        (http_status, models, None)
  | Error err -> (None, [], Some err)

let select_effective_model ~requested_model loaded_models =
  match Option.bind requested_model String_util.trim_nonempty with
  | Some _ as result -> result
  | None ->
    (match loaded_models with
     | model :: _ -> loaded_model_name model
     | [] -> String_util.trim_nonempty Env_config_runtime.Ollama.default_model)

let model_is_loaded model_id loaded_models =
  List.exists
    (fun loaded ->
      match loaded_model_name loaded with
      | Some candidate -> String.equal candidate model_id
      | None -> false)
    loaded_models

let decide_generate_probe ~effective_model ~before_status ~before_error
    ~run_generate ~generate_when_unloaded ~effective_model_loaded_before =
  match effective_model with
  | None -> Skip_generate_probe No_effective_model
  | Some _ when not run_generate -> Skip_generate_probe Status_only
  | Some _ when Option.is_some before_error -> Skip_generate_probe Ps_preflight_error
  | Some _ -> (
      match before_status with
      | Some 200 ->
          if generate_when_unloaded || effective_model_loaded_before then
            Run_generate_probe
          else
            Skip_generate_probe Model_unloaded
      | _ ->
          if generate_when_unloaded || effective_model_loaded_before then
            Run_generate_probe
          else
            Skip_generate_probe Policy_skip)

let request_body_json ~think_enabled ~keep_alive ~model_id ~prompt ~max_tokens =
  let fields =
    [
      Some ("model", `String model_id);
      Some ("prompt", `String prompt);
      Some ("stream", `Bool false);
      Some ("think", `Bool think_enabled);
      (match Option.bind keep_alive String_util.trim_nonempty with
      | Some value -> Some ("keep_alive", `String value)
      | None -> None);
      Some
        ( "options",
          `Assoc
            [
              ("temperature", `Float 0.0);
              ("num_predict", `Int max_tokens);
            ] );
    ]
    |> List.filter_map Stdlib.Fun.id
  in
  `Assoc fields |> Yojson.Safe.to_string

let run_single_probe ~pinned_resolution ~think_enabled ~keep_alive ~server_url
    ~model_id ~prompt ~max_tokens ~timeout_sec ~run_index =
  let url = ollama_generate_url server_url in
  let started = Time_compat.now () in
  match
    http_post_json_text_with_status_with_headers ~timeout_sec ?pinned_resolution
      ~url
      ~body_json:
        (request_body_json ~think_enabled ~keep_alive ~model_id ~prompt
           ~max_tokens)
      ()
  with
  | Error err ->
      failed_probe_run ~run_index ~http_status:None
        ~wall_clock_ms:(Stdlib.Int.of_float ((Time_compat.now () -. started) *. 1000.0))
        ~error:err
  | Ok (http_status, payload) ->
      let wall_clock_ms =
        Stdlib.Int.of_float ((Time_compat.now () -. started) *. 1000.0)
      in
      if not (Option.equal Int.equal http_status (Some 200)) then
        failed_probe_run ~run_index ~http_status ~wall_clock_ms
          ~error:
            (Printf.sprintf "ollama generate returned http %s"
               (match http_status with
               | Some code -> Int.to_string code
               | None -> "unknown"))
      else
        match Yojson.Safe.from_string payload with
        | exception Yojson.Json_error msg ->
            failed_probe_run ~run_index ~http_status ~wall_clock_ms
              ~error:("invalid ollama generate json: " ^ msg)
        | json ->
            ollama_probe_run_of_generate_json ~run_index ~http_status
              ~wall_clock_ms json

let runtime_ollama_probe_json ?server_url ?model ?prompt ?(probe_runs = 2)
    ?keep_alive ?(max_tokens = 16) ?(think_mode = Think_auto)
    ?(timeout_sec = 6) ?(ps_timeout_sec = 2) ?(generate_when_unloaded = true)
    ?(run_generate = true) () =
  let accept validate value =
    match validate value with
    | Ok accepted -> accepted
    | Error message -> invalid_arg message
  in
  let server_url =
    Option.bind server_url String_util.trim_nonempty
    |> Option.value ~default:Env_config_runtime.Ollama.server_url
    |> accept validate_ollama_server_url
  in
  let prompt =
    Option.bind prompt String_util.trim_nonempty |> Option.value ~default:(default_probe_prompt ())
  in
  let probe_runs = accept validate_probe_runs probe_runs in
  let max_tokens = accept validate_max_tokens max_tokens in
  let timeout_sec = accept validate_timeout_sec timeout_sec in
  let ps_timeout_sec = accept validate_ps_timeout_sec ps_timeout_sec in
  let think_enabled = effective_think_enabled think_mode in
  let pinned_resolution, resolution_error =
    match resolve_ollama_pinned_resolution server_url with
    | Ok pinned -> (pinned, None)
    | Error err -> (None, Some err)
  in
  let before_status, loaded_before, before_error =
    match resolution_error with
    | Some err -> (None, [], Some err)
    | None ->
        fetch_ollama_ps ~timeout_sec:ps_timeout_sec ?pinned_resolution ~server_url ()
  in
  let effective_model = select_effective_model ~requested_model:model loaded_before in
  let effective_model_loaded_before =
    match effective_model with
    | Some model_id -> model_is_loaded model_id loaded_before
    | None -> false
  in
  let generate_decision =
    decide_generate_probe ~effective_model ~before_status ~before_error
      ~run_generate ~generate_when_unloaded ~effective_model_loaded_before
  in
  let runs, run_errors =
    match generate_decision, effective_model with
    | Skip_generate_probe No_effective_model, _ ->
        ( [],
          [
            "No Ollama model was requested, loaded, or configured via OLLAMA_DEFAULT_MODEL.";
          ] )
    | (Skip_generate_probe (Status_only), _) | (Skip_generate_probe (Ps_preflight_error), _)
    | (Skip_generate_probe (Model_unloaded), _) | (Skip_generate_probe (Policy_skip), _) -> ([], [])
    | Run_generate_probe, None ->
        ([],
         [
           "No Ollama model was requested, loaded, or configured via OLLAMA_DEFAULT_MODEL.";
         ])
    | Run_generate_probe, Some model_id ->
        let completed_runs =
          List.init probe_runs (fun idx -> idx + 1)
          |> List.map (fun run_index ->
                 run_single_probe ~pinned_resolution ~think_enabled ~keep_alive ~server_url
                   ~model_id ~prompt ~max_tokens ~timeout_sec ~run_index)
        in
        let run_errors =
          completed_runs
          |> List.filter_map (fun run -> run.error)
        in
        (completed_runs, run_errors)
  in
  let generate_skip_reason =
    match generate_decision with
    | Run_generate_probe -> None
    | Skip_generate_probe reason ->
        Some (generate_probe_skip_reason_to_string reason)
  in
  let generate_skipped_unloaded_model =
    match generate_decision with
    | Skip_generate_probe Model_unloaded -> true
    | Skip_generate_probe (No_effective_model | (Status_only | (Ps_preflight_error | Policy_skip)))
    | Run_generate_probe -> false
  in
  let after_status, loaded_after, after_error =
    match resolution_error with
    | Some _ -> (None, [], None)
    | None ->
        fetch_ollama_ps ~timeout_sec:ps_timeout_sec ?pinned_resolution ~server_url ()
  in
  let runs_json = List.map ollama_probe_run_to_yojson runs in
  let kv_cache_assessment = kv_cache_assessment_json runs_json in
  let effective_model_loaded_after =
    match effective_model with
    | Some model_id -> model_is_loaded model_id loaded_after
    | None -> false
  in
  let observations =
    []
    |> (fun items ->
         if effective_model_loaded_before then
           "Effective model was already loaded before the probe according to /api/ps."
           :: items
         else items)
    |> (fun items ->
         if not effective_model_loaded_before && effective_model_loaded_after then
           "Probe appears to have loaded the model into Ollama residency."
           :: items
         else items)
    |> (fun items ->
         if generate_skipped_unloaded_model then
           "Skipped /api/generate because the effective model was not loaded; dashboard probes avoid cold-loading Ollama models."
           :: items
         else items)
    |> (fun items ->
         if not run_generate then
           "Skipped /api/generate because run_generate=false; this is a status-only Ollama residency probe."
           :: items
         else items)
    |> (fun items ->
         match runs with
         | first :: _ when Stdlib.Float.compare (Option.value ~default:0.0 first.load_duration_ms) 1000.0 >= 0 ->
             "First run reported a noticeable load_duration_ms, suggesting a colder path."
             :: items
         | first :: _ when Stdlib.Float.compare (Option.value ~default:Stdlib.max_float first.load_duration_ms) 100.0 <= 0 ->
             "First run load_duration_ms was small, which is consistent with a warm model."
             :: items
         | _ -> items)
    |> (fun items ->
         match Json_util.assoc_member_opt "signal" kv_cache_assessment with
         | Some (`String "likely_reused") ->
             "Repeated prompt_eval_duration_ms dropped enough to suggest repeated-prefix reuse."
             :: items
         | Some (`String "possible_reuse") ->
             "Repeated prompt_eval_duration_ms improved, but the signal is moderate rather than decisive."
             :: items
         | Some (`String "no_visible_reuse") ->
             "Repeated prompt_eval_duration_ms did not show a strong reuse improvement."
             :: items
         | _ -> items)
    |> List.rev
  in
  let errors =
    List.filter_map (fun item -> item) [ before_error; after_error ] @ run_errors
  in
  `Assoc
    [
      ("source", `String "ollama native runtime");
      ("server_url", `String server_url);
      ("ps_endpoint", `String (ollama_ps_url server_url));
      ("generate_endpoint", `String (ollama_generate_url server_url));
      ("configured_default_model", Json_util.string_opt_to_json (String_util.trim_nonempty Env_config_runtime.Ollama.default_model));
      ("requested_model", Json_util.string_opt_to_json (Option.bind model String_util.trim_nonempty));
      ("effective_model", Json_util.string_opt_to_json effective_model);
      ("probe_runs_requested", `Int probe_runs);
      ("probe_runs_completed", `Int (List.length runs));
      ("run_generate", `Bool run_generate);
      ("generate_when_unloaded", `Bool generate_when_unloaded);
      ("generate_skip_reason", Json_util.string_opt_to_json generate_skip_reason);
      ("generate_skipped_unloaded_model", `Bool generate_skipped_unloaded_model);
      ("keep_alive", Json_util.string_opt_to_json (Option.bind keep_alive String_util.trim_nonempty));
      ("max_tokens", `Int max_tokens);
      ("think_mode", `String (ollama_probe_think_mode_to_string think_mode));
      ("think", `Bool think_enabled);
      ("timeout_sec", `Int timeout_sec);
      ("ps_timeout_sec", `Int ps_timeout_sec);
      ("prompt_chars", `Int (String.length prompt));
      ("prompt_preview", `String (prompt |> collapse_preview |> truncate_text ~max_len:200));
      ("ps_http_status_before", Json_util.int_opt_to_json before_status);
      ("ps_http_status_after", Json_util.int_opt_to_json after_status);
      ("loaded_models_before", `List (List.map ollama_loaded_model_to_yojson loaded_before));
      ("loaded_models_after", `List (List.map ollama_loaded_model_to_yojson loaded_after));
      ("model_loaded_before_probe", `Bool effective_model_loaded_before);
      ("model_loaded_after_probe", `Bool effective_model_loaded_after);
      ("runs", `List runs_json);
      ("kv_cache_assessment", kv_cache_assessment);
      ("observations", `List (List.map (fun item -> `String item) observations));
      ("errors", `List (List.map (fun item -> `String item) errors));
      ( "limitations",
        `List
          [
            `String
              "This probe can observe warm-state and timing deltas, but not direct KV cache occupancy or hit-rate.";
            `String
              "A repeated-prefix signal is inference from prompt_eval_duration_ms, not a stable Ollama-native cache metric.";
          ] );
      ("probe_ok", `Bool (Stdlib.List.length errors = 0 && (Stdlib.List.length runs > 0 || not run_generate)));
    ]
