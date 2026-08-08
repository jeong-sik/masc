(** LLM endpoint discovery -- probes explicit typed endpoint declarations.

    @since 0.53.0 *)

let warn_probe_failure ~url ~phase detail =
  let json =
    `Assoc
      [ "event", `String "llm_provider_discovery_probe_failed"
      ; "url", `String url
      ; "phase", `String phase
      ; "detail", `String detail
      ]
  in
  Diag.debug "discovery" "%s" (Yojson.Safe.to_string json)
;;

(* Discovery types + JSON parsers moved to {!Discovery_parse}.  The
   transparent record-alias re-exports below preserve every existing
   [Discovery.model_info] / [Discovery.server_props] /
   [Discovery.slot_status] caller without forcing them to switch
   imports. *)
type model_info = Discovery_parse.model_info =
  { id : string
  ; owned_by : string
  }

type server_props = Discovery_parse.server_props =
  { total_slots : int
  ; ctx_size : int
  ; model : string
  }

type slot_status = Discovery_parse.slot_status =
  { total : int
  ; busy : int
  ; idle : int
  }

type endpoint_protocol =
  | Openai_compatible
  | Ollama_native

type endpoint =
  { url : string
  ; protocol : endpoint_protocol
  ; capabilities : Capabilities.capabilities
  }

let endpoint ~protocol ~capabilities url =
  { url = String.trim url; protocol; capabilities }
;;

type probe_failure =
  { phase : string
  ; detail : string
  }

type endpoint_status =
  { url : string
  ; protocol : endpoint_protocol
  ; healthy : bool
  ; models : model_info list
  ; props : server_props option
  ; slots : slot_status option
  ; capabilities : Capabilities.capabilities
  ; failures : probe_failure list
  }

let local_llm_url_env_var = "OAS_LOCAL_LLM_URL"
let llm_endpoints_env_var = "LLM_ENDPOINTS"
let ollama_host_env_var = "OLLAMA_HOST"
let default_ollama_endpoint = "http://127.0.0.1:11434"
let env_get_non_empty ~getenv name = getenv name |> Cli_common_env.trim_non_empty_opt
let default_endpoint = Constants.Endpoints.default_url

let resolve_default_endpoint ?(getenv = fun name -> Cli_common_env.get name) () =
  match env_get_non_empty ~getenv local_llm_url_env_var with
  | Some v -> v
  | None -> Constants.Endpoints.default_url
;;

let ollama_endpoint = default_ollama_endpoint

let resolve_ollama_endpoint ?(getenv = fun name -> Cli_common_env.get name) () =
  match env_get_non_empty ~getenv ollama_host_env_var with
  | Some url -> url
  | None -> default_ollama_endpoint
;;

let parse_llm_endpoints_env ?(getenv = fun name -> Cli_common_env.get name) () =
  match env_get_non_empty ~getenv llm_endpoints_env_var with
  | Some urls -> Cli_common_env.split_on_char_trim ',' urls
  | None -> []
;;

(* HTTP helpers moved to {!Discovery_http} so the exhaustive
   [Http_client.http_error] pattern match lives in one place.
   Re-export keeps the in-file probe call sites
   (lines ~250, 480, 487, 510) unchanged. *)
let get_json = Discovery_http.get_json
let probe_liveness = Discovery_http.probe_liveness

(* Parsers moved to {!Discovery_parse}; re-export so the in-file
   [probe_endpoint] call sites still type-check unchanged. *)
let parse_models = Discovery_parse.parse_models
let parse_props = Discovery_parse.parse_props
let parse_slots = Discovery_parse.parse_slots

(** Parse Ollama's typed [/api/tags] model list.

    The parser deliberately does not inspect chat templates, model names, or
    provider prose. A malformed item makes the endpoint probe fail explicitly
    instead of silently removing the model from discovery. *)
let parse_ollama_models tags_json =
  let models_json =
    match tags_json with
    | `Assoc fields -> List.assoc_opt "models" fields
    | _ -> None
  in
  match models_json with
  | None -> Error "response must be a JSON object with a models field"
  | Some (`List items) ->
    let model_name = function
      | `Assoc fields ->
        (match List.assoc_opt "name" fields with
         | Some (`String name) when String.trim name <> "" -> Ok name
         | Some (`String _) -> Error "name must be non-empty"
         | Some _ -> Error "name must be a string"
         | None -> Error "name is missing")
      | _ -> Error "model entry must be a JSON object"
    in
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match model_name item with
         | Ok name ->
           loop
             (index + 1)
             ({ id = name; owned_by = Provider_kind.to_string Provider_kind.Ollama }
              :: acc)
             rest
         | Error detail -> Error (Printf.sprintf "models[%d].%s" index detail))
    in
    loop 0 [] items
  | Some _ -> Error "models must be a JSON list"
;;

let probe_ollama_models ~sw ~net base_url =
  match get_json ~sw ~net (base_url ^ "/api/tags") with
  | Error detail -> Error detail
  | Ok tags_json -> parse_ollama_models tags_json
;;

let capabilities_with_props base props =
  match props with
  | Some (p : server_props) -> Capabilities.with_context_size base ~ctx_size:p.ctx_size
  | None -> base
;;

(* ── Probe ───────────────────────────────────────────────── *)

let probe_endpoint ~sw ~net (declared : endpoint) =
  let base = declared.url in
  let failure phase detail =
    warn_probe_failure ~url:base ~phase detail;
    { phase; detail }
  in
  let status ~healthy ~models ~props ~slots ~failures =
    { url = base
    ; protocol = declared.protocol
    ; healthy
    ; models
    ; props
    ; slots
    ; capabilities = capabilities_with_props declared.capabilities props
    ; failures
    }
  in
  if base = ""
  then
    status
      ~healthy:false
      ~models:[]
      ~props:None
      ~slots:None
      ~failures:[ failure "declaration" "endpoint URL is empty" ]
  else (
    match declared.protocol with
    | Ollama_native ->
      (match probe_ollama_models ~sw ~net base with
       | Ok models -> status ~healthy:true ~models ~props:None ~slots:None ~failures:[]
       | Error detail ->
         status
           ~healthy:false
           ~models:[]
           ~props:None
           ~slots:None
           ~failures:[ failure "ollama_tags" detail ])
    | Openai_compatible ->
      let liveness =
        match probe_liveness ~sw ~net (base ^ "/health") with
        | Ok () -> Ok ()
        | Error health_detail ->
          (match probe_liveness ~sw ~net base with
           | Ok () -> Ok ()
           | Error root_detail ->
             Error (Printf.sprintf "/health: %s; /: %s" health_detail root_detail))
      in
      (match liveness with
       | Error detail ->
         status
           ~healthy:false
           ~models:[]
           ~props:None
           ~slots:None
           ~failures:[ failure "health" detail ]
       | Ok () ->
         let probe parse target =
           match get_json ~sw ~net target with
           | Error _ as error -> error
           | Ok json -> parse json
         in
         let models_result, resolve_models = Eio.Promise.create () in
         let props_result, resolve_props = Eio.Promise.create () in
         let slots_result, resolve_slots = Eio.Promise.create () in
         Eio.Fiber.all
           [ (fun () ->
               Eio.Promise.resolve
                 resolve_models
                 (probe parse_models (base ^ "/v1/models")))
           ; (fun () ->
               Eio.Promise.resolve resolve_props (probe parse_props (base ^ "/props")))
           ; (fun () ->
               Eio.Promise.resolve resolve_slots (probe parse_slots (base ^ "/slots")))
           ];
         let models_result = Eio.Promise.await models_result in
         let props_result = Eio.Promise.await props_result in
         let slots_result = Eio.Promise.await slots_result in
         let models, models_valid, models_failure =
           match models_result with
           | Ok models -> models, true, None
           | Error detail -> [], false, Some (failure "models" detail)
         in
         let optional phase = function
           | Ok value -> Some value, None
           | Error detail -> None, Some (failure phase detail)
         in
         let props, props_failure = optional "props" props_result in
         let slots, slots_failure = optional "slots" slots_result in
         let failures =
           List.filter_map Fun.id [ models_failure; props_failure; slots_failure ]
         in
         status ~healthy:models_valid ~models ~props ~slots ~failures))
;;

(* ── Shared discovered context state ──────────────────────── *)

(** Snapshot of per-endpoint context and model-to-endpoint mapping,
    stored as a single atomic to prevent tearing between readers and
    writers.  [model_endpoints] maps each discovered model_id (from
    GET /v1/models) to the endpoint URL where it was found. *)
type _discovered_ctx_snapshot =
  { endpoint_ctxs : (string * int) list
  ; model_endpoints : (string * string) list
  ; per_slot_ctx : int option
  }

let _discovered_ctx : _discovered_ctx_snapshot Atomic.t =
  Atomic.make { endpoint_ctxs = []; model_endpoints = []; per_slot_ctx = None }
;;

let discovered_per_slot_context () = (Atomic.get _discovered_ctx).per_slot_ctx

(** Per-endpoint per-slot context map from last probe.
    Returns [(url, per_slot_ctx)] for each healthy endpoint. *)
let discovered_endpoint_contexts () = (Atomic.get _discovered_ctx).endpoint_ctxs

(** Look up per-slot context for a specific endpoint URL.
    Returns [None] if the endpoint was not probed or has no props. *)
let discovered_context_for_url (url : string) : int option =
  let normalized = String.trim url in
  List.assoc_opt normalized (Atomic.get _discovered_ctx).endpoint_ctxs
;;

(** Look up the endpoint URL that has [model_id] loaded.
    Uses data from the last {!refresh_and_sync} call. *)
let endpoint_for_model (model_id : string) : string option =
  List.assoc_opt model_id (Atomic.get _discovered_ctx).model_endpoints
;;

(** Look up [model_id] and return [(url, per_slot_ctx)].
    Returns [None] if the model is not found or its endpoint has no
    context data in the current snapshot. *)
let context_for_model (model_id : string) : (string * int) option =
  let snap = Atomic.get _discovered_ctx in
  match List.assoc_opt model_id snap.model_endpoints with
  | None -> None
  | Some url ->
    (match List.assoc_opt url snap.endpoint_ctxs with
     | Some ctx -> Some (url, ctx)
     | None -> None)
;;

(** Return the first model_id from the discovered model_endpoints index.
    Useful for resolving "auto" model IDs to concrete names discovered
    from the server's /v1/models endpoint. *)
let first_discovered_model_id () : string option =
  let snap = Atomic.get _discovered_ctx in
  match snap.model_endpoints with
  | (model_id, _) :: _ -> Some model_id
  | [] -> None
;;

(** Return the first model_id discovered on a specific endpoint URL.
    Prevents cross-provider contamination: e.g. ollama:auto should only
    resolve models found on the Ollama endpoint, not llama-server models. *)
let first_discovered_model_id_for_url (url : string) : string option =
  let snap = Atomic.get _discovered_ctx in
  List.find_map
    (fun (model_id, ep_url) -> if ep_url = url then Some model_id else None)
    snap.model_endpoints
;;

let discover ~sw ~net ~endpoints = Eio.Fiber.List.map (probe_endpoint ~sw ~net) endpoints

let refresh_and_sync ~sw ~net ~endpoints =
  let statuses = discover ~sw ~net ~endpoints in
  let healthy = List.filter (fun (s : endpoint_status) -> s.healthy) statuses in
  (* llama-server /props reports n_ctx as the per-slot context
     (server total / n_parallel), not the server total. Do NOT divide
     by total_slots again — that was a double-division bug that caused
     context to appear 4x smaller than actual (e.g. 65K → 16K). *)
  let per_slot_contexts =
    List.filter_map
      (fun (s : endpoint_status) ->
         match s.props with
         | Some p when p.ctx_size > 0 -> Some (s.url, p.ctx_size)
         | _ -> None)
      healthy
  in
  let ctx_values = List.map snd per_slot_contexts in
  let per_slot =
    match ctx_values with
    | [] -> None
    | ctxs -> Some (List.fold_left max 0 ctxs)
  in
  (* Build model_id → URL index from /v1/models responses *)
  let model_endpoints =
    List.concat_map
      (fun (s : endpoint_status) ->
         List.map (fun (m : model_info) -> m.id, s.url) s.models)
      healthy
  in
  Atomic.set
    _discovered_ctx
    { endpoint_ctxs = per_slot_contexts; model_endpoints; per_slot_ctx = per_slot };
  statuses
;;

(* ── JSON serialization ──────────────────────────────────── *)

let model_info_to_json (m : model_info) =
  `Assoc [ "id", `String m.id; "owned_by", `String m.owned_by ]
;;

let server_props_to_json (p : server_props) =
  `Assoc
    [ "total_slots", `Int p.total_slots
    ; "ctx_size", `Int p.ctx_size
    ; "model", `String p.model
    ]
;;

let slot_status_to_json (s : slot_status) =
  `Assoc [ "total", `Int s.total; "busy", `Int s.busy; "idle", `Int s.idle ]
;;

let capabilities_to_json (c : Capabilities.capabilities) =
  `Assoc
    [ "reasoning", `Bool c.supports_reasoning
    ; "tools", `Bool c.supports_tools
    ; "streaming", `Bool c.supports_native_streaming
    ; "multimodal", `Bool c.supports_multimodal_inputs
    ; "json_output", `Bool c.supports_response_format_json
    ]
;;

let endpoint_protocol_to_json = function
  | Openai_compatible -> `String "openai_compatible"
  | Ollama_native -> `String "ollama_native"
;;

let probe_failure_to_json failure =
  `Assoc [ "phase", `String failure.phase; "detail", `String failure.detail ]
;;

let endpoint_status_to_json (e : endpoint_status) =
  let fields =
    [ "url", `String e.url
    ; "protocol", endpoint_protocol_to_json e.protocol
    ; "healthy", `Bool e.healthy
    ; "models", `List (List.map model_info_to_json e.models)
    ; "capabilities", capabilities_to_json e.capabilities
    ; "failures", `List (List.map probe_failure_to_json e.failures)
    ]
  in
  let fields =
    match e.props with
    | Some p -> fields @ [ "props", server_props_to_json p ]
    | None -> fields
  in
  let fields =
    match e.slots with
    | Some s -> fields @ [ "slots", slot_status_to_json s ]
    | None -> fields
  in
  `Assoc fields
;;

let summary_to_json endpoints =
  let total_capacity =
    List.fold_left
      (fun acc (e : endpoint_status) ->
         match e.slots with
         | Some s -> acc + s.total
         | None -> acc)
      0
      endpoints
  in
  let available_capacity =
    List.fold_left
      (fun acc (e : endpoint_status) ->
         match e.slots with
         | Some s -> acc + s.idle
         | None -> acc)
      0
      endpoints
  in
  let active_requests =
    List.fold_left
      (fun acc (e : endpoint_status) ->
         match e.slots with
         | Some s -> acc + s.busy
         | None -> acc)
      0
      endpoints
  in
  `Assoc
    [ "total_capacity", `Int total_capacity
    ; "available_capacity", `Int available_capacity
    ; "active_requests", `Int active_requests
    ]
;;

let max_context_of_status (status : endpoint_status) =
  match status.props with
  | Some p when p.ctx_size > 0 -> Some p.ctx_size
  | _ -> status.capabilities.max_context_tokens
;;

[@@@coverage off]
(* === Inline tests === *)

(* --- default_endpoint --- *)

let%test "default_endpoint is localhost:8085" =
  default_endpoint = Constants.Endpoints.default_url
;;

(* --- parse_llm_endpoints_env (SSOT helper, #1002) --- *)

let no_env _ = None

let getenv_with_llm_endpoints value name =
  if name = llm_endpoints_env_var then Some value else None
;;

let%test "parse_llm_endpoints_env empty when unset" =
  parse_llm_endpoints_env ~getenv:no_env () = []
;;

let%test "parse_llm_endpoints_env empty when env is blank" =
  let res = parse_llm_endpoints_env ~getenv:(getenv_with_llm_endpoints "") () in
  res = []
;;

let%test "parse_llm_endpoints_env empty when env has only separators" =
  let res = parse_llm_endpoints_env ~getenv:(getenv_with_llm_endpoints " , , ") () in
  res = []
;;

let%test "parse_llm_endpoints_env preserves order and trims" =
  let res =
    parse_llm_endpoints_env
      ~getenv:(getenv_with_llm_endpoints "  http://a:8080 ,http://b:8081")
      ()
  in
  res = [ "http://a:8080"; "http://b:8081" ]
;;

(* --- parse_models --- *)

let%test "parse_models valid" =
  let json =
    `Assoc
      [ ( "data"
        , `List
            [ `Assoc [ "id", `String "dashscope-3.5-35b"; "owned_by", `String "local" ]
            ; `Assoc [ "id", `String "llama-4-scout"; "owned_by", `String "nous" ]
            ] )
      ]
  in
  match parse_models json with
  | Ok models -> List.length models = 2 && (List.hd models).id = "dashscope-3.5-35b"
  | Error _ -> false
;;

let%test "parse_models empty data" =
  let json = `Assoc [ "data", `List [] ] in
  parse_models json = Ok []
;;

let%test "parse_models rejects missing data" =
  let json = `Assoc [] in
  Result.is_error (parse_models json)
;;

let%test "parse_models rejects non-list data" =
  let json = `Assoc [ "data", `String "bad" ] in
  Result.is_error (parse_models json)
;;

let%test "parse_models rejects missing id instead of dropping the entry" =
  let json = `Assoc [ "data", `List [ `Assoc [ "owned_by", `String "local" ] ] ] in
  Result.is_error (parse_models json)
;;

let%test "parse_models rejects missing owned_by" =
  let json = `Assoc [ "data", `List [ `Assoc [ "id", `String "model1" ] ] ] in
  Result.is_error (parse_models json)
;;

(* --- parse_props --- *)

let%test "parse_props valid" =
  let json =
    `Assoc
      [ "total_slots", `Int 4
      ; ( "default_generation_settings"
        , `Assoc [ "n_ctx", `Int 8192; "model", `String "dashscope-3.5" ] )
      ]
  in
  match parse_props json with
  | Ok p -> p.total_slots = 4 && p.ctx_size = 8192 && p.model = "dashscope-3.5"
  | Error _ -> false
;;

let%test "parse_props rejects missing total_slots" =
  let json = `Assoc [] in
  Result.is_error (parse_props json)
;;

let%test "parse_props rejects non-integer total_slots" =
  let json = `Assoc [ "total_slots", `String "4" ] in
  Result.is_error (parse_props json)
;;

let%test "parse_props rejects missing generation settings" =
  let json = `Assoc [ "total_slots", `Int 2 ] in
  Result.is_error (parse_props json)
;;

let%test "parse_props rejects missing n_ctx" =
  let json =
    `Assoc
      [ "total_slots", `Int 1
      ; "default_generation_settings", `Assoc [ "model", `String "m" ]
      ]
  in
  Result.is_error (parse_props json)
;;

let%test "parse_props rejects missing model" =
  let json =
    `Assoc
      [ "total_slots", `Int 1
      ; "default_generation_settings", `Assoc [ "n_ctx", `Int 4096 ]
      ]
  in
  Result.is_error (parse_props json)
;;

(* --- parse_slots --- *)

let%test "parse_slots valid" =
  let json =
    `List
      [ `Assoc [ "is_processing", `Bool true ]
      ; `Assoc [ "is_processing", `Bool false ]
      ; `Assoc [ "is_processing", `Bool false ]
      ]
  in
  match parse_slots json with
  | Ok s -> s.total = 3 && s.busy = 1 && s.idle = 2
  | Error _ -> false
;;

let%test "parse_slots empty list is explicit zero capacity" =
  parse_slots (`List []) = Ok { total = 0; busy = 0; idle = 0 }
;;

let%test "parse_slots rejects non-list" = Result.is_error (parse_slots (`String "bad"))

let%test "parse_slots rejects an entry without is_processing" =
  let json = `List [ `Assoc [] ] in
  Result.is_error (parse_slots json)
;;

(* --- declared capabilities --- *)

let%test "endpoint preserves catalog-declared capabilities" =
  let declared = Capabilities.openai_compat_chat_extended_capabilities in
  let endpoint =
    endpoint ~protocol:Openai_compatible ~capabilities:declared "http://local:9000"
  in
  endpoint.capabilities = declared
;;

let%test "capabilities_with_props merges objective ctx_size" =
  let props = Some { total_slots = 4; ctx_size = 32768; model = "my-model" } in
  let caps = capabilities_with_props Capabilities.openai_compat_chat_capabilities props in
  caps.max_context_tokens = Some 32768
;;

(* --- JSON serialization --- *)

let%test "model_info_to_json" =
  let json = model_info_to_json { id = "m1"; owned_by = "local" } in
  let open Yojson.Safe.Util in
  json |> member "id" |> to_string = "m1"
  && json |> member "owned_by" |> to_string = "local"
;;

let%test "server_props_to_json" =
  let json =
    server_props_to_json { total_slots = 4; ctx_size = 8192; model = "dashscope" }
  in
  let open Yojson.Safe.Util in
  json |> member "total_slots" |> to_int = 4 && json |> member "ctx_size" |> to_int = 8192
;;

let%test "slot_status_to_json" =
  let json = slot_status_to_json { total = 4; busy = 1; idle = 3 } in
  let open Yojson.Safe.Util in
  json |> member "total" |> to_int = 4 && json |> member "busy" |> to_int = 1
;;

let%test "capabilities_to_json" =
  let json = capabilities_to_json Capabilities.default_capabilities in
  let open Yojson.Safe.Util in
  json |> member "tools" |> to_bool = false
;;

let%test "endpoint_status_to_json without props and slots" =
  let es =
    { url = Constants.Endpoints.default_url_localhost
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  let json = endpoint_status_to_json es in
  let open Yojson.Safe.Util in
  json |> member "url" |> to_string = Constants.Endpoints.default_url_localhost
  && json |> member "healthy" |> to_bool = true
;;

let%test "endpoint_status_to_json with props and slots" =
  let es =
    { url = Constants.Endpoints.default_url_localhost
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = [ { id = "m1"; owned_by = "local" } ]
    ; props = Some { total_slots = 4; ctx_size = 8192; model = "m1" }
    ; slots = Some { total = 4; busy = 1; idle = 3 }
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  let json = endpoint_status_to_json es in
  let open Yojson.Safe.Util in
  json |> member "props" |> member "total_slots" |> to_int = 4
  && json |> member "slots" |> member "busy" |> to_int = 1
;;

let%test "summary_to_json empty endpoints" =
  let json = summary_to_json [] in
  let open Yojson.Safe.Util in
  json |> member "total_capacity" |> to_int = 0
  && json |> member "available_capacity" |> to_int = 0
  && json |> member "active_requests" |> to_int = 0
;;

let%test "summary_to_json with slots" =
  let eps =
    [ { url = "a"
      ; protocol = Openai_compatible
      ; healthy = true
      ; models = []
      ; props = None
      ; slots = Some { total = 4; busy = 1; idle = 3 }
      ; capabilities = Capabilities.default_capabilities
      ; failures = []
      }
    ; { url = "b"
      ; protocol = Openai_compatible
      ; healthy = true
      ; models = []
      ; props = None
      ; slots = Some { total = 2; busy = 2; idle = 0 }
      ; capabilities = Capabilities.default_capabilities
      ; failures = []
      }
    ]
  in
  let json = summary_to_json eps in
  let open Yojson.Safe.Util in
  json |> member "total_capacity" |> to_int = 6
  && json |> member "available_capacity" |> to_int = 3
  && json |> member "active_requests" |> to_int = 3
;;

let%test "summary_to_json endpoint without slots ignored" =
  let eps =
    [ { url = "a"
      ; protocol = Openai_compatible
      ; healthy = false
      ; models = []
      ; props = None
      ; slots = None
      ; capabilities = Capabilities.default_capabilities
      ; failures = []
      }
    ]
  in
  let json = summary_to_json eps in
  let open Yojson.Safe.Util in
  json |> member "total_capacity" |> to_int = 0
;;

(* --- max_context_of_status --- *)

let%test "max_context_of_status from props" =
  let status =
    { url = "http://localhost"
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = []
    ; props = Some { total_slots = 4; ctx_size = 32768; model = "m" }
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  max_context_of_status status = Some 32768
;;

let%test "max_context_of_status from capabilities when no props" =
  let caps = { Capabilities.default_capabilities with max_context_tokens = Some 16384 } in
  let status =
    { url = "http://localhost"
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = caps
    ; failures = []
    }
  in
  max_context_of_status status = Some 16384
;;

let%test "max_context_of_status None when no info" =
  let status =
    { url = "http://localhost"
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = []
    ; props = None
    ; slots = None
    ; capabilities = Capabilities.default_capabilities
    ; failures = []
    }
  in
  max_context_of_status status = None
;;

let%test "max_context_of_status prefers props over capabilities" =
  let caps = { Capabilities.default_capabilities with max_context_tokens = Some 8192 } in
  let status =
    { url = "http://localhost"
    ; protocol = Openai_compatible
    ; healthy = true
    ; models = []
    ; props = Some { total_slots = 2; ctx_size = 65536; model = "m" }
    ; slots = None
    ; capabilities = caps
    ; failures = []
    }
  in
  max_context_of_status status = Some 65536
;;

(* --- typed Ollama model parser --- *)

let%test "parse_ollama_models accepts exact tags schema" =
  let json =
    `Assoc
      [ ( "models"
        , `List
            [ `Assoc [ "name", `String "qwen3.5" ]; `Assoc [ "name", `String "phi4" ] ] )
      ]
  in
  match parse_ollama_models json with
  | Ok models -> List.map (fun model -> model.id) models = [ "qwen3.5"; "phi4" ]
  | Error _ -> false
;;

let%test "parse_ollama_models rejects malformed item instead of dropping it" =
  let json = `Assoc [ "models", `List [ `Assoc [ "model", `String "qwen3.5" ] ] ] in
  match parse_ollama_models json with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "parse_ollama_models rejects a non-object response explicitly" =
  match parse_ollama_models (`List []) with
  | Error detail -> String.length detail > 0
  | Ok _ -> false
;;

(* --- discovered context state (atomic snapshot) --- *)

let%test "discovered_ctx snapshot: set and read both fields atomically" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       let snap =
         { endpoint_ctxs = [ "http://a:8085", 4096 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 4096
         }
       in
       Atomic.set _discovered_ctx snap;
       discovered_per_slot_context () = Some 4096
       && discovered_endpoint_contexts () = [ "http://a:8085", 4096 ])
;;

let%test "discovered_ctx snapshot: empty endpoints clears per_slot_ctx" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       (* Simulate a probe that previously found endpoints *)
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 8192 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 8192
         };
       (* Simulate a probe with no valid results *)
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []; model_endpoints = []; per_slot_ctx = None };
       discovered_per_slot_context () = None && discovered_endpoint_contexts () = [])
;;

let%test "discovered_ctx snapshot: max across multiple endpoints" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 4096; "http://b:8086", 8192 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 8192
         };
       discovered_per_slot_context () = Some 8192
       && List.length (discovered_endpoint_contexts ()) = 2)
;;

let%test "discovered_context_for_url returns per-endpoint value" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 4096; "http://b:8086", 8192 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 8192
         };
       discovered_context_for_url "http://a:8085" = Some 4096
       && discovered_context_for_url "http://b:8086" = Some 8192)
;;

let%test "discovered_context_for_url returns None for unknown endpoint" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 4096 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 4096
         };
       discovered_context_for_url "http://unknown:9999" = None)
;;

let%test "discovered_context_for_url trims whitespace" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 4096 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 4096
         };
       discovered_context_for_url "  http://a:8085  " = Some 4096)
;;

let%test "discovered_ctx initial state is empty" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []; model_endpoints = []; per_slot_ctx = None };
       discovered_per_slot_context () = None
       && discovered_endpoint_contexts () = []
       && discovered_context_for_url "http://any:8085" = None)
;;

(* --- model-to-endpoint index --- *)

let%test "endpoint_for_model returns url when model is indexed" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 32768 ]
         ; model_endpoints = [ "dashscope-3.5-9b", "http://a:8085" ]
         ; per_slot_ctx = Some 32768
         };
       endpoint_for_model "dashscope-3.5-9b" = Some "http://a:8085")
;;

let%test "endpoint_for_model returns None for unknown model" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 32768 ]
         ; model_endpoints = [ "dashscope-3.5-9b", "http://a:8085" ]
         ; per_slot_ctx = Some 32768
         };
       endpoint_for_model "nonexistent" = None)
;;

let%test "context_for_model returns url and per-slot ctx" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 32768; "http://b:8086", 8192 ]
         ; model_endpoints = [ "model-a", "http://a:8085"; "model-b", "http://b:8086" ]
         ; per_slot_ctx = Some 32768
         };
       context_for_model "model-a" = Some ("http://a:8085", 32768)
       && context_for_model "model-b" = Some ("http://b:8086", 8192))
;;

let%test "context_for_model returns None when model not indexed" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://a:8085", 32768 ]
         ; model_endpoints = []
         ; per_slot_ctx = Some 32768
         };
       context_for_model "any-model" = None)
;;

let%test "first_discovered_model_id returns None for empty snapshot" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []; model_endpoints = []; per_slot_ctx = None };
       first_discovered_model_id () = None)
;;

let%test "first_discovered_model_id returns first model_id from snapshot" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = [ "http://localhost:8085", 8192 ]
         ; model_endpoints =
             [ "model-a", "http://localhost:8085"; "model-b", "http://localhost:8086" ]
         ; per_slot_ctx = Some 8192
         };
       first_discovered_model_id () = Some "model-a")
;;

let%test "first_discovered_model_id_for_url filters by endpoint" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []
         ; model_endpoints =
             [ "llama-model", "http://127.0.0.1:8085"
             ; "ollama-model", "http://127.0.0.1:11434"
             ]
         ; per_slot_ctx = None
         };
       first_discovered_model_id_for_url "http://127.0.0.1:11434" = Some "ollama-model")
;;

let%test "first_discovered_model_id_for_url returns None for unknown url" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []
         ; model_endpoints = [ "llama-model", "http://127.0.0.1:8085" ]
         ; per_slot_ctx = None
         };
       first_discovered_model_id_for_url "http://127.0.0.1:11434" = None)
;;

let%test "first_discovered_model_id_for_url prevents cross-provider" =
  let old = Atomic.get _discovered_ctx in
  Fun.protect
    ~finally:(fun () -> Atomic.set _discovered_ctx old)
    (fun () ->
       Atomic.set
         _discovered_ctx
         { endpoint_ctxs = []
         ; model_endpoints =
             [ "dashscope-3.5-9b-local", "http://127.0.0.1:8085"
             ; "dashscope-3.5:9b-nvfp4", "http://127.0.0.1:11434"
             ]
         ; per_slot_ctx = None
         };
       (* ollama endpoint must NOT return the llama-server model *)
       first_discovered_model_id_for_url "http://127.0.0.1:8085"
       = Some "dashscope-3.5-9b-local"
       && first_discovered_model_id_for_url "http://127.0.0.1:11434"
          = Some "dashscope-3.5:9b-nvfp4")
;;
