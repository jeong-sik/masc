[@@@warning "-32-33-69"]

include Server_trpg_rest_actor

let split_csv_nonempty (raw : string) : string list =
  let pieces =
    raw
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 8 in
  let out_rev =
    List.fold_left
      (fun acc item ->
        if Hashtbl.mem seen item then acc
        else (
          Hashtbl.replace seen item true;
          item :: acc))
      []
      pieces
  in
  List.rev out_rev

let has_nonempty_env name =
  match Sys.getenv_opt name with
  | Some value -> String.trim value <> ""
  | None -> false

let trpg_default_fast_keeper_models () : string list =
  let glm_available = has_nonempty_env "ZAI_API_KEY" in
  let gemini_available = has_nonempty_env "GEMINI_API_KEY" in
  let llama_models =
    match Provider_adapter.explicit_llama_model_label_result () with
    | Ok label -> [ label ]
    | Error _ -> []
  in
  let glm_model =
    let m = Env_config_governance.Llm.default_model in
    if m = "" then "auto" else m
  in
  let glm_label = Printf.sprintf "glm:%s" glm_model in
  let gemini_label = Printf.sprintf "gemini:%s" Env_config_governance.Gemini.flash_model in
  match (glm_available, gemini_available) with
  | true, true -> [ glm_label; gemini_label ] @ llama_models
  | true, false -> [ glm_label ] @ llama_models
  | false, true -> [ gemini_label ] @ llama_models
  | false, false -> llama_models

let trpg_keeper_models_override_csv () : string option =
  match Sys.getenv_opt "MASC_TRPG_KEEPER_MODELS" with
  | Some raw -> Some raw
  | None -> Sys.getenv_opt "KEEPER_MODELS"

let trpg_keeper_models_for_round () : string list =
  let configured_opt =
    match trpg_keeper_models_override_csv () with
    | Some raw ->
        let parsed = split_csv_nonempty raw in
        if parsed = [] then None else Some parsed
    | None -> None
  in
  let chosen =
    match configured_opt with
    | Some models -> models
    | None -> trpg_default_fast_keeper_models ()
  in
  match Keeper_types.model_specs_of_strings chosen with
  | Ok _ -> chosen
  | Error e ->
      if chosen <> [] then
        Log.Trpg.info "invalid keeper model override ignored: %s" e;
      []

let trim_trailing_slashes (raw : string) : string =
  let rec loop value =
    let len = String.length value in
    if len > 0 && value.[len - 1] = '/' then
      loop (String.sub value 0 (len - 1))
    else
      value
  in
  loop (String.trim raw)

let trpg_json_assoc_find (key : string) = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let trpg_json_string_fields (keys : string list) (json : Yojson.Safe.t) : string option =
  let rec pick = function
    | [] -> None
    | key :: rest -> (
        match trpg_json_assoc_find key json with
        | Some (`String value) ->
            let trimmed = String.trim value in
            if trimmed = "" then pick rest else Some trimmed
        | _ -> pick rest)
  in
  pick keys

let trpg_json_string_list_field (key : string) = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List rows) ->
          rows
          |> List.filter_map (function
               | `String value ->
                   let trimmed = String.trim value in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
      | _ -> [])
  | _ -> []

let trpg_http_get_json_via_curl ?(timeout_sec = 2) (url : string) :
    (Yojson.Safe.t, string) result =
  let argv = ["curl"; "-sS"; "--max-time"; string_of_int timeout_sec; url] in
  try
    let status, raw =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Float.of_int timeout_sec +. 1.0)
        argv
    in
    match status with
    | Unix.WEXITED 0 -> (
        if String.trim raw = "" then Error "empty response"
        else
          try Ok (Yojson.Safe.from_string raw)
          with Yojson.Json_error msg ->
            Error (Printf.sprintf "invalid json: %s" msg))
    | Unix.WEXITED 7 -> Error "connection refused"
    | Unix.WEXITED 28 -> Error "request timed out"
    | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
    | Unix.WSIGNALED sig_num ->
        Error (Printf.sprintf "curl killed by signal %d" sig_num)
    | Unix.WSTOPPED _ -> Error "curl stopped unexpectedly"
  with exn ->
    Error (Printf.sprintf "http error: %s" (Printexc.to_string exn))

let trpg_custom_endpoint_urls_from_specs (specs : string list) : string list =
  specs
  |> List.filter_map (fun spec ->
         let spec = String.trim spec in
         if not (String.starts_with ~prefix:"custom:" spec) then None
         else
           match String.index_opt spec '@' with
           | Some at_idx when at_idx + 1 < String.length spec ->
               let url =
                 String.sub spec (at_idx + 1) (String.length spec - at_idx - 1)
                 |> trim_trailing_slashes
               in
               if url = "" then None else Some url
           | _ -> None)
  |> String.concat ","
  |> split_csv_nonempty

let trpg_string_contains ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let trpg_parse_flag_value ~(flag : string) (command : string) : string option =
  let trimmed = String.trim command in
  let with_equals = flag ^ "=" in
  let len = String.length trimmed in
  let rec find_equals idx =
    if idx >= len then None
    else if
      idx + String.length with_equals <= len
      && String.sub trimmed idx (String.length with_equals) = with_equals
    then
      let start = idx + String.length with_equals in
      let rec stop j =
        if j >= len then j
        else
          match trimmed.[j] with
          | ' ' | '\t' | '\n' | '\r' -> j
          | _ -> stop (j + 1)
      in
      let value = String.sub trimmed start (stop start - start) |> String.trim in
      if value = "" then None else Some value
    else find_equals (idx + 1)
  in
  match find_equals 0 with
  | Some _ as value -> value
  | None ->
      let with_space = flag ^ " " in
      let rec find_space idx =
        if idx >= len then None
        else if
          idx + String.length with_space <= len
          && String.sub trimmed idx (String.length with_space) = with_space
        then
          let start = idx + String.length with_space in
          let rec skip_spaces j =
            if j < len && (trimmed.[j] = ' ' || trimmed.[j] = '\t') then
              skip_spaces (j + 1)
            else
              j
          in
          let start = skip_spaces start in
          let rec stop j =
            if j >= len then j
            else
              match trimmed.[j] with
              | ' ' | '\t' | '\n' | '\r' -> j
              | _ -> stop (j + 1)
          in
          let value = String.sub trimmed start (stop start - start) |> String.trim in
          if value = "" then None else Some value
        else find_space (idx + 1)
      in
      find_space 0

let trpg_running_llama_cpp_urls () : string list =
  try
    let status, raw =
      Process_eio.run_argv_with_status ~timeout_sec:2.5 ["ps"; "ax"; "-o"; "command="]
    in
    match status with
    | Unix.WEXITED 0 ->
        raw
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let trimmed = String.trim line in
               if trimmed = "" || not (trpg_string_contains ~needle:"llama-server" trimmed)
               then None
               else
                 match trpg_parse_flag_value ~flag:"--port" trimmed with
                 | Some port when String.for_all (function '0' .. '9' -> true | _ -> false) port
                   ->
                     Some (Printf.sprintf "http://127.0.0.1:%s" port)
                 | _ -> None
               )
        |> String.concat ","
        |> split_csv_nonempty
    | _ -> []
  with _ -> []

let trpg_openai_compatible_urls () : string list =
  let env_urls =
    match Sys.getenv_opt "MASC_TRPG_CUSTOM_MODEL_ENDPOINTS" with
    | Some raw -> split_csv_nonempty raw |> List.map trim_trailing_slashes
    | None -> []
  in
  let spec_urls =
    trpg_keeper_models_for_round () |> trpg_custom_endpoint_urls_from_specs
  in
  let llama_cpp_urls = trpg_running_llama_cpp_urls () in
  env_urls @ spec_urls @ llama_cpp_urls
  |> List.map trim_trailing_slashes
  |> String.concat ","
  |> split_csv_nonempty

let trpg_discover_openai_compatible_models (base_url : string) :
    (string list, string) result =
  let base_url = trim_trailing_slashes base_url in
  let url = base_url ^ "/v1/models" in
  match trpg_http_get_json_via_curl url with
  | Error err -> Error err
  | Ok json ->
      let named_rows =
        let gather key =
          match trpg_json_assoc_find key json with
          | Some (`List entries) ->
              entries
              |> List.filter_map (fun entry ->
                     trpg_json_string_fields ["id"; "name"; "model"] entry)
          | _ -> []
        in
        gather "data" @ gather "models"
      in
      let names = split_csv_nonempty (String.concat "," named_rows) in
      if names = [] then Error "model ids not found in /v1/models"
      else
        Ok
          (List.map
             (fun model_id -> Printf.sprintf "custom:%s@%s" model_id base_url)
             names)

let trpg_discover_local_llama_models () : (string list, string) result =
  match trpg_discover_openai_compatible_models Env_config.Llama.server_url with
  | Ok specs ->
      Ok
        (specs
        |> List.map (fun spec ->
               match String.index_opt spec ':' with
               | Some idx when idx + 1 < String.length spec ->
                   let tail =
                     String.sub spec (idx + 1) (String.length spec - idx - 1)
                   in
                   (match String.index_opt tail '@' with
                   | Some at_idx when at_idx > 0 ->
                       "llama:" ^ String.sub tail 0 at_idx
                   | _ -> spec)
               | _ -> spec))
  | Error err -> Error err

let trpg_available_models_json_collect
    ?(warnings : string list = [])
    ?(include_live = true)
    () : Yojson.Safe.t =
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 64 in
  let models_rev = ref [] in
  let warnings_rev = ref [] in
  let add_warning message =
    let trimmed = String.trim message in
    if trimmed <> "" then warnings_rev := trimmed :: !warnings_rev
  in
  let add_model ~spec ~source ~status ?detail () =
    let spec = String.trim spec in
    if spec = "" || Hashtbl.mem seen spec then ()
    else (
      Hashtbl.replace seen spec true;
      let fields =
        [
          ("spec", `String spec);
          ("source", `String source);
          ("status", `String status);
        ]
      in
      let fields =
        match detail with
        | Some detail when String.trim detail <> "" ->
            ("detail", `String (String.trim detail)) :: fields
        | _ -> fields
      in
      models_rev := `Assoc (List.rev fields) :: !models_rev)
  in
  let configured_override =
    match trpg_keeper_models_override_csv () with
    | Some raw -> split_csv_nonempty raw
    | None -> []
  in
  let default_models = trpg_default_fast_keeper_models () in
  let effective_models = trpg_keeper_models_for_round () in
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-default" ~status:"default" ())
    default_models;
  List.iter
    (fun spec -> add_model ~spec ~source:"env-override" ~status:"override" ())
    configured_override;
  List.iter
    (fun spec -> add_model ~spec ~source:"runtime-effective" ~status:"selected" ())
    effective_models;
  List.iter add_warning warnings;
  if include_live then (
    List.iter
      (fun base_url ->
        match trpg_discover_openai_compatible_models base_url with
        | Ok specs ->
            List.iter
              (fun spec ->
                add_model ~spec ~source:"openai-compatible" ~status:"live"
                  ~detail:base_url ())
              specs
        | Error err ->
            add_warning
              (Printf.sprintf "openai-compatible %s 조회 실패: %s" base_url err))
      (trpg_openai_compatible_urls ());
    match trpg_discover_local_llama_models () with
    | Ok specs ->
        List.iter
          (fun spec ->
            add_model ~spec ~source:"llama" ~status:"live"
              ~detail:Env_config.Llama.server_url ())
          specs
    | Error err ->
        add_warning
          (Printf.sprintf "llama %s 조회 실패: %s" Env_config.Llama.server_url err));
  `Assoc
    [
      ("ok", `Bool true);
      ( "effective_models",
        `List (List.map (fun spec -> `String spec) effective_models) );
      ( "configured_override",
        `List (List.map (fun spec -> `String spec) configured_override) );
      ("models", `List (List.rev !models_rev));
      ("warnings", `List (List.rev_map (fun item -> `String item) !warnings_rev));
    ]

let trpg_available_models_json_uncached () : Yojson.Safe.t =
  trpg_available_models_json_collect ()

let trpg_available_models_json_base ?(warnings : string list = []) () : Yojson.Safe.t =
  trpg_available_models_json_collect ~warnings ~include_live:false ()

type trpg_model_catalog_cache = {
  mutex : Eio.Mutex.t;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
}

let trpg_model_catalog_cache_ttl_sec = 15.0

let trpg_model_catalog_cache : trpg_model_catalog_cache =
  {
    mutex = Eio.Mutex.create ();
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
  }

let trpg_available_models_json () : Yojson.Safe.t =
  let now = Unix.gettimeofday () in
  let cached, should_refresh =
    Eio.Mutex.use_rw ~protect:true trpg_model_catalog_cache.mutex (fun () ->
      let snapshot = trpg_model_catalog_cache.cached_json in
      let fresh_snapshot =
        match trpg_model_catalog_cache.cached_json with
        | Some json
          when now -. trpg_model_catalog_cache.cached_at
               < trpg_model_catalog_cache_ttl_sec ->
            Some json
        | _ -> None
      in
      let should_refresh =
        match fresh_snapshot with
        | Some _ -> false
        | None when trpg_model_catalog_cache.refresh_in_flight -> false
        | None ->
            trpg_model_catalog_cache.refresh_in_flight <- true;
            true
      in
      ((match fresh_snapshot with Some json -> Some json | None -> snapshot), should_refresh))
  in
  match (cached, should_refresh) with
  | Some json, false -> json
  | None, false ->
      trpg_available_models_json_base
        ~warnings:["가용 모델 조회 중입니다. 잠시 후 다시 시도하세요."] ()
  | cached_snapshot, true ->
      let fallback_json =
        Fun.protect
          ~finally:(fun () ->
            Eio.Mutex.use_rw ~protect:true trpg_model_catalog_cache.mutex (fun () ->
              trpg_model_catalog_cache.refresh_in_flight <- false))
          (fun () ->
            let outcome =
              try Ok (trpg_available_models_json_uncached ())
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn)
            in
            match outcome with
            | Ok fresh -> fresh
            | Error err -> (
                match cached_snapshot with
                | Some stale ->
                    stale
                | None ->
                    trpg_available_models_json_base
                      ~warnings:[Printf.sprintf "가용 모델 조회 실패: %s" err] ()))
      in
      Eio.Mutex.use_rw ~protect:true trpg_model_catalog_cache.mutex (fun () ->
        trpg_model_catalog_cache.cached_json <- Some fallback_json;
        trpg_model_catalog_cache.cached_at <- Unix.gettimeofday ());
      fallback_json

