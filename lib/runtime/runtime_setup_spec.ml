type choice = Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Claude_code | Codex | Antigravity | Muse
type http_kind = Openai_compat | Anthropic | Kimi | Glm | Ollama_kind
type credential = Env_reference of string | File_reference of string
type transport =
  | Http of {endpoint:string; credential:credential option;
      kind:http_kind; request_path:string option}
  | Client of {command:string; oauth:string option; timeout:float option; account_home:string option}
type t = {choice:choice; model:string; context:int; tools:bool; streaming:bool;
  supports_image_input:bool option;
  transport:transport; canonical_spec:string; declared_provider_id:string option; requested_provider_id:string option}
type error = Invalid_spec of string
let error_message (Invalid_spec field) = "Invalid runtime setup specification: " ^ field
let ( let* ) = Result.bind
let invalid field = Error (Invalid_spec field)
let choice_name = function Ollama -> "ollama" | Llama_cpp -> "llama_cpp" | Vllm -> "vllm"
  | Openai_compatible -> "openai_compatible" | Messages -> "messages" | Claude_code -> "claude_code"
  | Codex -> "codex" | Antigravity -> "antigravity" | Muse -> "muse"
let protocol = function Ollama -> "ollama-http" | Messages -> "messages-http"
  | Claude_code -> "claude-code" | Codex -> "codex-app-server" | Antigravity -> "antigravity-cli"
  | Muse -> "muse-serve"
  | Llama_cpp | Vllm | Openai_compatible -> "openai-compatible-http"
let http = function Ollama | Llama_cpp | Vllm | Openai_compatible | Messages -> true | _ -> false
let safe_text value = value <> "" && String.trim value = value
  && not (String.exists (function '\000'..'\031' | '\127' -> true | _ -> false) value)
let required fields key = match List.assoc_opt key fields with
  | Some (`String value) when safe_text value -> Ok value | _ -> invalid key
let optional fields key = match List.assoc_opt key fields with
  | None | Some (`String "") -> Ok None
  | Some (`String value) when safe_text value -> Ok (Some value)
  | _ -> invalid key
let bool fields key = match List.assoc_opt key fields with Some (`Bool value) -> Ok value | _ -> invalid key
let env_name value =
  let first = function 'A'..'Z' | 'a'..'z' | '_' -> true | _ -> false in
  let rest c = first c || (c >= '0' && c <= '9') in
  String.length value > 0 && first value.[0] && String.for_all rest value
let valid_endpoint value =
  try
    let uri = Uri.of_string value in
    List.mem (Uri.scheme uri) [Some "http";Some "https"] && Uri.host uri <> None
    && Uri.userinfo uri = None && Uri.query uri = [] && Uri.fragment uri = None
    && (match Uri.port uri with None -> true | Some port -> port >= 1 && port <= 65535)
  with Invalid_argument _ -> false
(* Match pathlib's lexical POSIX File spelling without resolving symlinks or
   reading a credential. Parent traversal remains explicit, as in the input. *)
let reference_path path =
  let prefix = if String.starts_with ~prefix:"//" path && not (String.starts_with ~prefix:"///" path) then "//" else "/" in
  prefix ^ String.concat "/" (List.filter (fun part -> part <> "" && part <> ".") (String.split_on_char '/' path))
(* The operator's endpoint is one AGENT_CORE has no provider row for, so the
   deployment has to name the dialect itself; [protocol] only names the request
   shape. Same spellings as the catalog's own [kind]. *)
let wire_kind_name = function
  | Openai_compat -> "openai_compat"
  | Anthropic -> "anthropic"
  | Kimi -> "kimi"
  | Glm -> "glm"
  | Ollama_kind -> "ollama"

let schema_kind = function
  | Openai_compat -> Runtime_schema.OpenAI_compat | Anthropic -> Anthropic
  | Kimi -> Kimi | Glm -> Glm | Ollama_kind -> Ollama
let effective_path ~endpoint ~kind request_path =
  let kind = schema_kind kind in
  match request_path with
  | None -> Runtime_adapter.default_http_request_path ~kind ~base_url:endpoint
  | Some request_path -> Runtime_adapter.normalize_http_request_path ~kind ~base_url:endpoint ~request_path

(* Identity comes from the parsed connection, not from the text that produced
   it. Hashing the raw field bag made a field left out and the same field
   written with its default two different connections, and the inventory fills
   [provider_kind] on every round trip -- so adding an endpoint and
   reconfiguring it answered with two ids for one endpoint, and the second
   arrived as a duplicate row beside a stale one.

   Destructured exhaustively with warning 9 forced on, because the failure in
   the other direction is worse: a field added to [t] and forgotten here would
   give two different connections one id, and an overwritten row is invisible
   where a duplicate row is not. *)
let[@warning "+9"] transport_json transport =
  let credential_json = function
    | None -> `Null
    | Some (Env_reference name) -> `List [`String "env"; `String name]
    | Some (File_reference path) -> `List [`String "file"; `String path] in
  (* Destructured, not field-accessed: warning 9 fires on a record pattern and
     says nothing about [h.endpoint], so a fourth field on either constructor
     would drop out of the identity the same way a seventh on [t] would. *)
  match transport with
    | Http {endpoint; kind; credential; request_path} ->
      ["endpoint",`String endpoint; "kind",`String (wire_kind_name kind);
              "credential", credential_json credential]
      @ (match request_path with None -> [] | Some path -> ["request_path", `String path])
      |> fun fields -> `Assoc fields
    | Client {command; oauth; timeout; account_home} ->
      ["command",`String command;
              "oauth",(match oauth with None -> `Null | Some path -> `String path);
              "timeout",(match timeout with None -> `Null | Some value -> `Float value)]
      @ (match account_home with None -> [] | Some home -> ["account_home", `String home])
      |> fun fields -> `Assoc fields

let[@warning "+9"] canonical_spec_of
      ({ choice; model; context; tools; streaming; supports_image_input; transport;
         canonical_spec = _; declared_provider_id = _; requested_provider_id = _ } : t)
  =
  Yojson.Safe.to_string (`Assoc ([
    "choice",`String (choice_name choice); "model",`String model;
    "max_context",`Int context; "tools",`Bool tools; "streaming",`Bool streaming;
    "transport", transport_json transport]
    @ (match supports_image_input with None -> [] | Some value -> ["supports_image_input", `Bool value])))

let of_json ?home_dir = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) ->
    let* name = required fields "choice" in
    let* choice = match name with
      | "ollama" -> Ok Ollama | "llama_cpp" -> Ok Llama_cpp | "vllm" -> Ok Vllm
      | "openai_compatible" -> Ok Openai_compatible | "messages" -> Ok Messages
      | "claude_code" -> Ok Claude_code | "codex" -> Ok Codex | "antigravity" -> Ok Antigravity
      | "muse" -> Ok Muse
      | _ -> invalid "choice" in
    let allowed = ["choice";"model";"max_context";"tools";"streaming";"supports_image_input";"existing_provider_id"]
      @ (if http choice then ["endpoint";"api_key_env";"credential_file";"provider_kind";"request_path"] else ["command"])
      @ (match choice with Claude_code | Codex | Muse -> ["account_home"] | _ -> [])
      @ (if choice = Antigravity then ["credential_file";"timeout_s"] else []) in
    let* () = if List.for_all (fun (key,_) -> List.mem key allowed) fields then Ok () else invalid "unexpected fields" in
    let* requested_provider_id = optional fields "existing_provider_id" in
    let* model = required fields "model" in
    let* context = match List.assoc_opt "max_context" fields with Some (`Int value) when value > 0 -> Ok value | _ -> invalid "max_context" in
    let* tools = bool fields "tools" in let* streaming = bool fields "streaming" in
    let* supports_image_input = match List.assoc_opt "supports_image_input" fields with
      | None -> Ok None
      | Some (`Bool value) -> Ok (Some value)
      | _ -> invalid "supports_image_input" in
    let* transport = if http choice then (
      let* endpoint = required fields "endpoint" in
      let* () = if valid_endpoint endpoint then Ok () else invalid "endpoint" in
      let* env = optional fields "api_key_env" in
      let* file = if List.mem_assoc "credential_file" fields then required fields "credential_file" |> Result.map Option.some else Ok None in
      let* credential = match file,env with
        | Some path,None when not (Filename.is_relative path) -> Ok (Some (File_reference (reference_path path)))
        | None,Some name when env_name name -> Ok (Some (Env_reference name))
        | None,None -> Ok None | _ -> invalid "credential reference" in
      let* kind = optional fields "provider_kind" in
      let* kind = match choice,kind with
        | Ollama,(None | Some "ollama") -> Ok Ollama_kind
        | Messages,Some "anthropic" -> Ok Anthropic | Messages,Some "kimi" -> Ok Kimi
        | (Llama_cpp | Vllm | Openai_compatible),(None | Some "openai_compat") -> Ok Openai_compat
        | (Llama_cpp | Vllm | Openai_compatible),Some "glm" -> Ok Glm
        | _ -> invalid "provider_kind" in
      let* request_path = match List.assoc_opt "request_path" fields with
        | None -> Ok None
        | Some (`String value) when safe_text value ->
          let uri = Uri.of_string value in
          if value.[0] = '/' && Uri.scheme uri = None && Uri.host uri = None
             && Uri.query uri = [] && Uri.fragment uri = None
             && not (String.contains value ' ')
          then
            let path = effective_path ~endpoint ~kind (Some value) in
            if Llm_provider.Provider_config.request_path_targets_responses_api path
               && kind <> Openai_compat then invalid "request_path dialect"
            else Ok (if path = effective_path ~endpoint ~kind None then None else Some path)
          else invalid "request_path"
        | Some _ -> invalid "request_path" in
      Ok (Http {endpoint;credential;kind;request_path}))
    else (
      let* command = if List.mem_assoc "command" fields then required fields "command"
        else Ok (match choice with Claude_code -> "claude" | Codex -> "codex" | Muse -> "muse" | _ -> "agy") in
      let* account_home =
        if List.mem_assoc "account_home" fields
        then required fields "account_home" |> Result.map Option.some
        else Ok None in
      let* account_home = match account_home,choice with
        | None,Muse -> invalid "account_home"
        | None,_ -> Ok None
        | Some home,_ when Runtime_account_home.is_valid home -> Ok (Some home)
        | Some _,_ -> invalid "account_home" in
      let* oauth,timeout = if choice <> Antigravity then Ok (None,None) else (
        let* path = required fields "credential_file" in
        let path = match home_dir with
          | Some home when String.starts_with ~prefix:"~/" path -> Filename.concat home (String.sub path 2 (String.length path - 2))
          | Some home when path = "~" -> home | _ -> path in
        let* () = if Filename.is_relative path then invalid "credential_file" else Ok () in
        let* timeout = match List.assoc_opt "timeout_s" fields with
          | Some (`Int value) when value > 0 -> Ok (float_of_int value)
          | Some (`Float value) when Float.is_finite value && value > 0. -> Ok value
          | _ -> invalid "timeout_s" in Ok (Some (reference_path path),Some timeout)) in
      Ok (Client {command;oauth;timeout;account_home})) in
    let parsed = {choice;model;context;tools;streaming;supports_image_input;transport;
      canonical_spec="";declared_provider_id=None;requested_provider_id} in
    Ok {parsed with canonical_spec = canonical_spec_of parsed}
  | _ -> invalid "object or duplicate fields"
(* Mirrors the loader's rule: a protocol that already determines the dialect
   refuses a restated one rather than ignoring it, so the wizard writes [kind]
   only where it will be read. Listed per choice so a new transport has to
   decide rather than inherit a catch-all. *)
let protocol_fixes_dialect = function
  | Ollama -> true
  | Llama_cpp | Vllm | Openai_compatible | Messages -> false
  | Claude_code | Codex | Antigravity | Muse -> true

let quoted value = Yojson.Safe.to_string (`String value)
let table ?(array=false) path fields =
  "\n" ^ (if array then "[[" else "[") ^ String.concat "." (List.map quoted path)
  ^ (if array then "]]\n" else "]\n")
  ^ String.concat "" (List.map (fun (key,value) -> quoted key ^ " = " ^ Yojson.Safe.to_string value ^ "\n") fields)
type rendered = {runtime_id:string;runtime_toml:string}
(* [--setup-lanes] points the exact-output lanes at the connection set up here
   when it is an HTTP one. An exact slot whose provider declares no
   [exact-body-timeout-s] is left out at boot and cannot be added by a save
   (rule 3, #38779), so the connection declares one. The wizard has no
   measurement of the operator's endpoint to size it from, so it writes the
   value the seed runtime.toml gives its own exact-slot providers; the
   operator narrows it in the file. *)
let setup_exact_body_timeout_s = 1200.0
(* The provider identifies a connection/account; the model identifies a full
   declaration, including its context window. Adding a model or a window on
   the same account therefore adds a binding under the same provider. A model
   name keeps the characters a model id admits; any other character (a UTF-8
   sequence, not a byte) becomes one '-'. *)
let answers_hash_length = 8
let answers_hash answers =
  String.sub Digestif.SHA256.(to_hex (digest_string answers)) 0 answers_hash_length
let provider_id spec =
  match spec.declared_provider_id with
  | Some id -> id
  | None ->
    let identity = Yojson.Safe.to_string (`Assoc [
      "choice", `String (choice_name spec.choice);
      "transport", transport_json spec.transport]) in
    choice_name spec.choice ^ "_" ^ answers_hash identity
let account_home_matches choice left right =
  let effective = match choice with
    | Claude_code -> Runtime_claude_code.effective_account_home
    | Codex -> Runtime_codex_app_server.effective_account_home
    | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Antigravity | Muse -> Fun.id in
  effective left = effective right
let connection_matches spec (provider : Runtime_schema.provider) =
  let credential_matches expected = match expected, provider.credentials with
    | None, None -> true
    | Some (Env_reference name), Some (Runtime_schema.Env configured) -> name=configured
    | Some (File_reference path), Some (Runtime_schema.File configured) -> path=configured
    | _ -> false in
  let connection_matches = match spec.transport, provider.transport with
    | Client client, Runtime_schema.Cli command ->
      client.command=command && account_home_matches spec.choice client.account_home provider.account_home
      && credential_matches (Option.map (fun path -> File_reference path) client.oauth)
      && (match client.timeout, provider.antigravity_cli with
          | None, None -> true
          | Some timeout, Some options -> timeout=options.timeout_s
          | _ -> false)
    | Http connection, Runtime_schema.Http endpoint ->
      let kind = schema_kind connection.kind in
      connection.endpoint=endpoint && credential_matches connection.credential
      && (match Runtime_adapter.http_protocol_metadata provider with
          | Ok (configured, path) -> configured=kind
            && path=effective_path ~endpoint ~kind:connection.kind connection.request_path
          | Error _ -> false)
    | Client _, Runtime_schema.Http _ | Http _, Runtime_schema.Cli _ -> false in
  provider.protocol=protocol spec.choice && connection_matches
type reuse_eligibility = Eligible | Disabled | Interactive_cli
let reuse_eligibility (provider : Runtime_schema.provider) =
  if not provider.enabled then Disabled else
  match provider.transport with
  | Runtime_schema.Cli _ when not provider.is_non_interactive -> Interactive_cli
  | Runtime_schema.Cli _ | Runtime_schema.Http _ -> Eligible
let reuse_refusal = function
  | Eligible -> "provider connection changed"
  | Disabled -> "provider is disabled"
  | Interactive_cli -> "CLI provider must declare is-non-interactive = true"
let for_provider spec (provider : Runtime_schema.provider) =
  if reuse_eligibility provider = Eligible && connection_matches spec provider
  then Some {spec with declared_provider_id=Some provider.id} else None
let resolve_provider spec providers =
  let selected = match spec.declared_provider_id with
    | Some _ as selected -> selected | None -> spec.requested_provider_id in
  match selected with
  | Some id ->
    (match List.find_opt (fun (p:Runtime_schema.provider) -> p.id=id) providers with
     | Some provider -> (match for_provider spec provider with
         | Some bound -> Ok bound | None -> invalid (reuse_refusal (reuse_eligibility provider)))
     | None -> invalid "selected provider is absent")
  | None ->
    let matches = List.filter (connection_matches spec) providers in
    let enabled = List.filter (fun provider -> reuse_eligibility provider = Eligible) matches in
    let generated = provider_id spec in
    let enabled = match List.find_opt (fun (p:Runtime_schema.provider) -> p.id=generated) enabled with
      | Some provider -> [provider] | None -> enabled in
    (match enabled, matches with
     | [provider], _ -> Ok {spec with declared_provider_id=Some provider.id}
     | [], provider :: _ -> invalid (reuse_refusal (reuse_eligibility provider))
     | _ :: _ :: _, _ -> invalid "matching providers are ambiguous"
     | [], [] ->
       if List.exists (fun (p:Runtime_schema.provider) -> p.id=generated) providers
       then invalid "generated provider identity is already declared" else Ok spec)
let model_id_character decoded =
  let c = Uchar.utf_decode_uchar decoded in
  if Uchar.is_char c then
    match Uchar.to_char c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' as kept -> kept
    | _ -> '-'
  else '-'
let model_id_text model =
  let text = Buffer.create (String.length model) in
  let rec copy index =
    if index < String.length model then begin
      let decoded = String.get_utf_8_uchar model index in
      Buffer.add_char text (model_id_character decoded);
      copy (index + Uchar.utf_decode_length decoded)
    end in
  copy 0;
  Buffer.contents text
let render ?(include_provider=true) ?(wizard_default=true) spec =
  let provider = provider_id spec in
  let hash = answers_hash (Yojson.Safe.to_string (`List [`String provider; `String spec.canonical_spec])) in
  let model_key = model_id_text spec.model ^ "_" ^ hash in
  let runtime_id = provider ^ "." ^ model_key in
  let fields = ["display-name",`String provider;"protocol",`String (protocol spec.choice)] in
  let transport_fields,credential = match spec.transport with
    | Http h ->
      (if protocol_fixes_dialect spec.choice then [] else ["kind",`String (wire_kind_name h.kind)])
      @ (match h.request_path with None -> [] | Some path -> ["request-path", `String path])
      @ ["endpoint",`String h.endpoint;
         Runtime_schema.exact_body_timeout_s_key,`Float setup_exact_body_timeout_s],h.credential
    | Client c -> ["command",`String c.command;"is-non-interactive",`Bool true]
      @ (match c.timeout with None -> [] | Some timeout -> ["timeout-s",`Float timeout])
      @ (match c.account_home with None -> [] | Some home -> ["account-home", `String home]),
      Option.map (fun path -> File_reference path) c.oauth in
  let runtime = table [Runtime_toml_namespace.(key Providers);provider] (fields @ transport_fields) in
  let runtime = runtime ^ (if http spec.choice then table [Runtime_toml_namespace.(key Providers);provider;"healthcheck"]
      ["path",`String (if spec.choice=Ollama then "/api/tags" else "/models")] else "") in
  let runtime = runtime ^ (match credential with
    | Some (File_reference path) -> table [Runtime_toml_namespace.(key Providers);provider;"credentials"] ["type",`String "file";"path",`String path]
    | Some (Env_reference name) -> table [Runtime_toml_namespace.(key Providers);provider;"credentials"] ["type",`String "env";"key",`String name]
    | None -> "") in
  let runtime = (if include_provider then runtime else "")
    ^ table [Runtime_toml_namespace.(key Models);model_key] (["api-name",`String spec.model;"max-context",`Int spec.context;
    "tools-support",`Bool spec.tools;"streaming",`Bool spec.streaming])
    (* Setup declares model capabilities explicitly, including on connections
       with generated provider IDs that no catalog entry can name. Discovery
       has not verified a reasoning stream, so it is declared off. *)
    ^ table [Runtime_toml_namespace.(key Models);model_key;"capabilities"]
        (["reasoning-streaming-format",`String "none"]
         @ (match spec.supports_image_input with None -> [] | Some value -> ["supports-image-input", `Bool value]))
    ^ table [provider;model_key] (["max-context", `Int spec.context]
        @ (if wizard_default then ["wizard-default",`Bool true] else [])
        @ if spec.choice=Ollama then ["num-ctx",`Int spec.context] else []) in
  {runtime_id;runtime_toml=runtime}
let render_json value = `Assoc ["runtime_id",`String value.runtime_id;"runtime_toml",`String value.runtime_toml]

let model_id spec = spec.model
