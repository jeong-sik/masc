open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

type config_target =
  | Target_runtime
  | Target_keeper of string
  | Target_keeper_create

let tui_preferences_path = "/api/v1/tui/preferences"

let config_schema_path = function
  | Target_runtime -> "/api/v1/config/schema?target=runtime"
  | Target_keeper name ->
      "/api/v1/config/schema?target=" ^ percent_encode ("keeper:" ^ name)
  | Target_keeper_create -> "/api/v1/config/schema?target=keeper_create"

let config_patch_path = "/api/v1/config/patch"

type tui_preferences = {
  theme : string option;
  language : Say.lang option;
  board_sort : string option;
  reduce_motion : bool option;
  hints_visible : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
  audio_input_device : string option;
}

type tui_preference_change =
  | Pref_theme of string option
  | Pref_language of Say.lang
  | Pref_board_sort of string
  | Pref_chat_visited of string

let decode_tui_preferences json =
  let* _, body = unwrap_v2_or_raw json in
  let* theme = optional_nonblank_string body "theme" in
  let* language = decode_optional_enum ~field:"language" Say.lang_of_code body in
  let* board_sort = optional_nonblank_string body "board_sort" in
  let* reduce_motion = optional_bool_field body "reduce_motion" in
  let* hints_visible = optional_bool_field body "hints_visible" in
  let* coalesce_queued_input =
    optional_bool_field body "coalesce_queued_input"
  in
  let* send_on_stop = optional_bool_field body "send_on_stop" in
  let* audio_input_device = optional_nonblank_string body "audio_input_device" in
  Ok
    {
      theme;
      language;
      board_sort;
      reduce_motion;
      hints_visible;
      coalesce_queued_input;
      send_on_stop;
      audio_input_device;
    }

let encode_tui_preference_change = function
  | Pref_theme None ->
      `Assoc [ ("change", `String "theme"); ("theme", `Null) ]
  | Pref_theme (Some name) ->
      `Assoc [ ("change", `String "theme"); ("theme", `String name) ]
  | Pref_language lang ->
      `Assoc
        [
          ("change", `String "language");
          ("language", `String (Say.lang_code lang));
        ]
  | Pref_board_sort sort ->
      (* [lib/tui_preference.ml] reads key ["sort"] for ["change": "board_sort"]. *)
      `Assoc [ ("change", `String "board_sort"); ("sort", `String sort) ]
  | Pref_chat_visited keeper ->
      `Assoc [ ("change", `String "chat_visited"); ("keeper", `String keeper) ]

type config_category =
  | Cat_general_ui
  | Cat_providers_models
  | Cat_routing_failover
  | Cat_keepers_companies
  | Cat_sandbox_ssh
  | Cat_voice_integrations
  | Cat_board_memory_candle

let category_of_settings_tab = function
  | Nav.Settings_general_ui -> Cat_general_ui
  | Nav.Settings_providers_models -> Cat_providers_models
  | Nav.Settings_routing_failover -> Cat_routing_failover
  | Nav.Settings_keepers_companies -> Cat_keepers_companies
  | Nav.Settings_sandbox_ssh -> Cat_sandbox_ssh
  | Nav.Settings_voice_integrations -> Cat_voice_integrations
  | Nav.Settings_board_memory_candle -> Cat_board_memory_candle

let settings_tab_of_category = function
  | Cat_general_ui -> Nav.Settings_general_ui
  | Cat_providers_models -> Nav.Settings_providers_models
  | Cat_routing_failover -> Nav.Settings_routing_failover
  | Cat_keepers_companies -> Nav.Settings_keepers_companies
  | Cat_sandbox_ssh -> Nav.Settings_sandbox_ssh
  | Cat_voice_integrations -> Nav.Settings_voice_integrations
  | Cat_board_memory_candle -> Nav.Settings_board_memory_candle

let config_category_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "general_ui" | "general_server" | "observability_ops" -> Some Cat_general_ui
  | "providers_models" | "providers_accounts" | "runtime_providers" ->
      Some Cat_providers_models
  | "routing_failover" | "runtime_cascades" -> Some Cat_routing_failover
  | "keepers_companies" | "keepers_fleet" | "keepers_autonomy" ->
      Some Cat_keepers_companies
  | "sandbox_ssh" | "sandbox_ssh_microvm" | "sandbox_infra" ->
      Some Cat_sandbox_ssh
  | "voice_integrations" | "voice_audio" | "connectors" | "economy_connectors" ->
      Some Cat_voice_integrations
  | "board_memory_candle" | "memory_librarian" | "board_candle"
  | "memory_knowledge" ->
      Some Cat_board_memory_candle
  | _ -> None

let config_category_to_string = function
  | Cat_general_ui -> "general_ui"
  | Cat_providers_models -> "providers_models"
  | Cat_routing_failover -> "routing_failover"
  | Cat_keepers_companies -> "keepers_companies"
  | Cat_sandbox_ssh -> "sandbox_ssh"
  | Cat_voice_integrations -> "voice_integrations"
  | Cat_board_memory_candle -> "board_memory_candle"

type provenance =
  | Prov_default
  | Prov_global
  | Prov_project
  | Prov_keeper
  | Prov_env_override

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

type secret_source =
  | Secret_env of string
  | Secret_inline_redacted
  | Secret_unset

type field_kind =
  | Field_bool
  | Field_int of { min : int option; max : int option }
  | Field_float of { min : float option; max : float option }
  | Field_string
  | Field_enum of string list
  | Field_string_list
  | Field_structured
  | Field_secret

type field_value =
  | Val_bool of bool
  | Val_int of int
  | Val_float of float
  | Val_string of string
  | Val_string_list of string list
  | Val_structured of Yojson.Safe.t
  | Val_secret of { configured : bool; source : secret_source }
  | Val_null

type schema_field = {
  table : string;
  key : string;
  full_key : string;
  label : string;
  env : string option;
  description : string option;
  kind : field_kind;
  value : field_value;
  default_value : field_value option;
  provenance : provenance;
  reload_scope : reload_scope;
  secret : bool;
  writable : bool;
}

type schema_section = {
  id : string;
  category : config_category;
  title : string;
  fields : schema_field list;
}

type config_schema = {
  target : config_target;
  keeper : string option;
  file_exists : bool;
  file_sha256 : string;
  sections : schema_section list;
}

let provenance_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "default" -> Some Prov_default
  | "global" -> Some Prov_global
  | "project" | "runtime_toml" -> Some Prov_project
  | "keeper" | "keeper_toml" -> Some Prov_keeper
  | "env_override" -> Some Prov_env_override
  | _ -> None

let reload_scope_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "hot_reload" | "live_applied" -> Some Hot_reload
  | "next_turn" -> Some Next_turn
  | "restart_required" -> Some Restart_required
  | _ -> None

let reload_scope_to_string = function
  | Hot_reload -> "hot_reload"
  | Next_turn -> "next_turn"
  | Restart_required -> "restart_required"

let decode_secret_state json =
  match json with
  | `Assoc _ ->
      let* kind = required_nonblank_string json "kind" in
      let* () =
        if String.equal kind "secret_state" then Ok ()
        else
          Error
            (Printf.sprintf
               "secret field must have kind=\"secret_state\", got %S" kind)
      in
      let* configured = required_bool_field json "configured" in
      let* source_opt = optional_nonblank_string json "source" in
      let* source =
        match source_opt with
        | None | Some "unset" -> Ok Secret_unset
        | Some "inline_redacted" -> Ok Secret_inline_redacted
        | Some s when String.starts_with ~prefix:"env:" s ->
            let var_name = String.sub s 4 (String.length s - 4) in
            if String.equal (String.trim var_name) "" then
              Error "secret env source must name an environment variable"
            else Ok (Secret_env var_name)
        | Some other ->
            Error (Printf.sprintf "unknown secret source %S" other)
      in
      Ok (Val_secret { configured; source })
  | `String _ ->
      Error
        "secret redaction violation: raw string value is forbidden for secret field"
  | bad -> field_type_error "secret value" "a secret_state object" bad

let decode_int_range json =
  match optional_object_field json "range" with
  | Error _ as err -> err
  | Ok None -> Ok (None, None)
  | Ok (Some r) ->
      let* min_v = optional_int_field r "min_inclusive" in
      let* max_v = optional_int_field r "max_inclusive" in
      Ok (min_v, max_v)

let decode_float_range json =
  match optional_object_field json "range" with
  | Error _ as err -> err
  | Ok None -> Ok (None, None)
  | Ok (Some r) ->
      let* min_inc = optional_finite_float r "min_inclusive" in
      let* min_exc = optional_finite_float r "min_exclusive" in
      let min_v = match min_inc with Some _ as v -> v | None -> min_exc in
      let* max_v = optional_finite_float r "max_inclusive" in
      Ok (min_v, max_v)

let decode_field_kind json =
  let* type_str = required_nonblank_string json "type" in
  match String.lowercase_ascii type_str with
  | "boolean" | "bool" -> Ok Field_bool
  | "integer" | "int" ->
      let* min, max = decode_int_range json in
      Ok (Field_int { min; max })
  | "float" ->
      let* min, max = decode_float_range json in
      Ok (Field_float { min; max })
  | "string" -> Ok Field_string
  | "enum" ->
      let* options = required_string_list json "enum_values" in
      if options = [] then Error "enum field must list at least one option"
      else Ok (Field_enum options)
  | "string_list" -> Ok Field_string_list
  | "structured" | "table_array" -> Ok Field_structured
  | "secret" | "secret_ref" -> Ok Field_secret
  | other -> Error (Printf.sprintf "unknown config field type %S" other)

let is_secret_kind = function
  | Field_secret -> true
  | Field_bool | Field_int _ | Field_float _ | Field_string | Field_enum _
  | Field_string_list | Field_structured ->
      false

let parse_bool_string s =
  match String.lowercase_ascii (String.trim s) with
  | "true" -> Some true
  | "false" -> Some false
  | _ -> None

let is_unset_display_string s =
  match String.lowercase_ascii (String.trim s) with
  | "" | "(none)" | "none" | "(unset)" | "unset" | "(empty)" | "<none>"
  | "<unset>" ->
      true
  | lower ->
      String.starts_with ~prefix:"unset " lower
      || String.starts_with ~prefix:"unset(" lower

let decode_field_value ~kind ~secret ~allow_display_string raw =
  let is_secret = secret || is_secret_kind kind in
  if is_secret then decode_secret_state raw
  else
    match (kind, raw) with
    | _, `Null -> Ok Val_null
    | Field_bool, `Bool b -> Ok (Val_bool b)
    | Field_bool, `String s -> (
        match parse_bool_string s with
        | Some b -> Ok (Val_bool b)
        | None when is_unset_display_string s -> Ok Val_null
        | None when allow_display_string -> Ok (Val_string s)
        | None -> Error (Printf.sprintf "invalid boolean display string %S" s))
    | Field_int _, `Int i -> Ok (Val_int i)
    | Field_int _, `String s -> (
        match int_of_string_opt (String.trim s) with
        | Some i -> Ok (Val_int i)
        | None when is_unset_display_string s -> Ok Val_null
        | None when allow_display_string -> Ok (Val_string s)
        | None -> Error (Printf.sprintf "invalid integer display string %S" s))
    | Field_float _, `Float f when Float.is_finite f -> Ok (Val_float f)
    | Field_float _, `Int i -> Ok (Val_float (Float.of_int i))
    | Field_float _, `String s -> (
        match float_of_string_opt (String.trim s) with
        | Some f when Float.is_finite f -> Ok (Val_float f)
        | Some _ | None ->
            if is_unset_display_string s then Ok Val_null
            else if allow_display_string then Ok (Val_string s)
            else Error (Printf.sprintf "invalid float display string %S" s))
    | Field_string, `String s -> Ok (Val_string s)
    | Field_enum options, `String s ->
        if List.mem s options then Ok (Val_string s)
        else if is_unset_display_string s then Ok Val_null
        else if allow_display_string then Ok (Val_string s)
        else Error (Printf.sprintf "enum value %S is not in allowed options" s)
    | Field_string_list, `List items ->
        let* strs =
          decode_list "current_value"
            (function
              | `String s -> Ok s
              | bad -> field_type_error "string_list element" "a string" bad)
            items
        in
        Ok (Val_string_list strs)
    | Field_string_list, `String s when is_unset_display_string s -> Ok Val_null
    | Field_string_list, `String s when allow_display_string ->
        Ok (Val_string s)
    | Field_structured, (`Assoc _ | `List _ | `String _ as v) ->
        Ok (Val_structured v)
    | Field_secret, _ -> decode_secret_state raw
    | (Field_bool | Field_int _ | Field_float _ | Field_string | Field_enum _
       | Field_string_list | Field_structured),
      bad ->
        field_type_error "field value" "matching field type" bad

let is_safe_secret_default_display s =
  match String.lowercase_ascii (String.trim s) with
  | "" | "(unset)" | "unset" | "(none)" | "none" | "(empty)" | "empty"
  | "[redacted]" | "redacted" | "(redacted)" | "<unset>" | "<none>" ->
      true
  | _ -> false

type field_entity_meta = {
  entity_group : string option;
  entity_title : string option;
  sub_group : string option;
}

let decode_schema_field_with_meta json =
  (* [table] may be empty [""] for root-level or env-only registry settings. *)
  let* table = required_string_field json "table" in
  let* key = required_nonblank_string json "key" in
  let* full_key =
    match optional_nonblank_string json "full_key" with
    | Ok (Some fk) -> Ok fk
    | Ok None ->
        Ok (if String.equal table "" then key else table ^ "." ^ key)
    | Error _ as err -> err
  in
  let* label =
    match optional_nonblank_string json "label" with
    | Ok (Some l) -> Ok l
    | Ok None -> Ok full_key
    | Error _ as err -> err
  in
  let* entity_group = optional_nonblank_string json "entity_group" in
  let* entity_title = optional_nonblank_string json "entity_title" in
  let* sub_group = optional_nonblank_string json "sub_group" in
  let* env = optional_nonblank_string json "env" in
  let* description = optional_nonblank_string json "description" in
  let* kind = decode_field_kind json in
  let* secret = required_bool_field json "secret" in
  let* writable = required_bool_field json "writable" in
  let* raw_val = required_member json "current_value" in
  let is_secret = secret || is_secret_kind kind in
  let* value =
    decode_field_value ~kind ~secret ~allow_display_string:(not is_secret)
      raw_val
  in
  let* default_value =
    if not (has_field json "default_value") then Ok None
    else
      match member "default_value" json with
      | `Null -> Ok None
      | `String s when is_secret ->
          if is_safe_secret_default_display s then Ok None
          else
            Error
              "secret redaction violation: raw string value is forbidden for secret field"
      | raw_def ->
          let* dv =
            decode_field_value ~kind ~secret ~allow_display_string:true raw_def
          in
          Ok (Some dv)
  in
  let* provenance = decode_enum ~field:"provenance" provenance_of_string json in
  let* reload_scope =
    decode_enum ~field:"reload_scope" reload_scope_of_string json
  in
  let field =
    {
      table;
      key;
      full_key;
      label;
      env;
      description;
      kind;
      value;
      default_value;
      provenance;
      reload_scope;
      secret = secret || is_secret_kind kind;
      writable;
    }
  in
  let meta_opt =
    match (entity_group, entity_title, sub_group) with
    | None, None, None -> None
    | _ -> Some (full_key, { entity_group; entity_title; sub_group })
  in
  Ok (field, meta_opt)

let decode_schema_section_with_meta json =
  let* id = required_nonblank_string json "id" in
  let* category =
    match config_category_of_string id with
    | Some c -> Ok c
    | None -> Error (Printf.sprintf "unknown config category id %S" id)
  in
  let* title = required_nonblank_string json "title" in
  let* field_items = required_list_field json "fields" in
  let* decoded = decode_list "fields" decode_schema_field_with_meta field_items in
  let fields = List.map fst decoded in
  let metas = List.filter_map snd decoded in
  Ok ({ id; category; title; fields }, metas)

let decode_target json =
  match required_member json "target" with
  | Error _ as err -> err
  | Ok (`String "runtime") -> Ok Target_runtime
  | Ok (`String "keeper_create") -> Ok Target_keeper_create
  | Ok (`String s) when String.starts_with ~prefix:"keeper:" s ->
      let name = String.trim (String.sub s 7 (String.length s - 7)) in
      if String.equal name "" then
        Error "keeper config target must specify a non-empty keeper name"
      else Ok (Target_keeper name)
  | Ok (`Assoc _ as obj) -> (
      let* kind = required_nonblank_string obj "kind" in
      match kind with
      | "runtime" | "runtime_toml" -> Ok Target_runtime
      | "keeper" | "keeper_toml" ->
          let* keeper = required_nonblank_string obj "keeper" in
          Ok (Target_keeper keeper)
      | "keeper_create" -> Ok Target_keeper_create
      | other -> Error (Printf.sprintf "unknown config target kind %S" other))
  | Ok bad -> field_type_error "target" "a config target string or object" bad

let decode_config_schema_with_meta json =
  let* _, body = unwrap_v2_or_raw json in
  let* target = decode_target body in
  let* keeper = optional_nonblank_string body "keeper" in
  let* file_exists = required_bool_field body "file_exists" in
  let* file_sha256 = required_nonblank_string body "file_sha256" in
  let* cat_items = required_list_field body "categories" in
  let* decoded =
    decode_list "categories" decode_schema_section_with_meta cat_items
  in
  let sections = List.map fst decoded in
  let metas = List.concat_map snd decoded in
  Ok ({ target; keeper; file_exists; file_sha256; sections }, metas)

let decode_config_schema json =
  Result.map fst (decode_config_schema_with_meta json)

let strip_quotes s =
  let t = String.trim s in
  let len = String.length t in
  if
    len >= 2
    && ((t.[0] = '"' && t.[len - 1] = '"') || (t.[0] = '\'' && t.[len - 1] = '\''))
  then String.sub t 1 (len - 2)
  else t

let split_dotted_segments raw =
  let trimmed = String.trim raw in
  let len = String.length trimmed in
  if len = 0 then []
  else
    let buf = Buffer.create len in
    let acc = ref [] in
    let in_dq = ref false in
    let in_sq = ref false in
    let escaped = ref false in
    for i = 0 to len - 1 do
      let c = trimmed.[i] in
      if !escaped then (
        Buffer.add_char buf c;
        escaped := false)
      else if !in_dq then (
        Buffer.add_char buf c;
        if c = '\\' then escaped := true else if c = '"' then in_dq := false)
      else if !in_sq then (
        Buffer.add_char buf c;
        if c = '\'' then in_sq := false)
      else
        match c with
        | '"' ->
            in_dq := true;
            Buffer.add_char buf c
        | '\'' ->
            in_sq := true;
            Buffer.add_char buf c
        | '.' ->
            acc := strip_quotes (Buffer.contents buf) :: !acc;
            Buffer.clear buf
        | _ -> Buffer.add_char buf c
    done;
    acc := strip_quotes (Buffer.contents buf) :: !acc;
    List.rev !acc

let title_case_key raw =
  let clean = strip_quotes raw in
  let parts =
    String.split_on_char '_' clean
    |> List.concat_map (String.split_on_char '-')
    |> List.filter (fun s -> not (String.equal s ""))
  in
  match parts with
  | [] -> clean
  | _ ->
      List.map
        (fun w ->
          let lw = String.lowercase_ascii w in
          match lw with
          | "api" | "url" | "ssh" | "tts" | "stt" | "ui" | "cli" | "id" | "tls"
          | "http" | "mcp" | "vm" | "gc" | "ms" ->
              String.uppercase_ascii lw
          | _ -> String.capitalize_ascii lw)
        parts
      |> String.concat " "

let table_last_segment table =
  match List.rev (split_dotted_segments table) with
  | last :: _ -> String.lowercase_ascii last
  | [] -> ""

let non_provider_top_tables =
  [
    "providers";
    "models";
    "model_sets";
    "runtime";
    "exec";
    "sandbox";
    "voice";
    "slack";
    "discord";
    "browser";
    "fusion";
    "tui";
    "turn";
    "wire_capture";
    "memory";
    "board";
    "candle";
    "keeper";
    "typesafeai";
    "web_search";
    "skills";
    "repositories";
    "otel";
    "metrics";
  ]

let field_sub_group (f : schema_field) =
  let segs = split_dotted_segments f.table in
  match segs with
  | top :: model_id :: _
    when (not (String.equal top ""))
         && (not (String.equal model_id ""))
         && not (List.mem (String.lowercase_ascii top) non_provider_top_tables)
    ->
      Some ("binding:" ^ model_id)
  | _ -> (
      let sub =
        match List.rev segs with
        | last :: _ -> String.lowercase_ascii last
        | [] -> ""
      in
      match sub with
      | "credentials" | "headers" | "healthcheck" | "usage-read" | "usage_read"
      | "capabilities" ->
          Some sub
      | _ -> None)

let sub_group_label ~lang sg =
  if String.starts_with ~prefix:"binding:" sg then
    let model_id = strip_quotes (String.sub sg 8 (String.length sg - 8)) in
    if String.equal model_id "" then
      Say.resolve lang (Say.make ~ko:"모델 바인딩" ~en:"Model Bindings")
    else
      Say.resolve lang
        (Say.make
           ~ko:("모델 바인딩 · " ^ model_id)
           ~en:("Model Binding · " ^ model_id))
  else
    match sg with
    | "credentials" ->
        Say.resolve lang (Say.make ~ko:"인증 Credentials" ~en:"Credentials")
    | "headers" ->
        Say.resolve lang (Say.make ~ko:"커스텀 헤더 Headers" ~en:"Custom Headers")
    | "healthcheck" ->
        Say.resolve lang (Say.make ~ko:"헬스체크 Healthcheck" ~en:"Healthcheck")
    | "usage-read" | "usage_read" ->
        Say.resolve lang (Say.make ~ko:"사용량 조회 Usage Poll" ~en:"Usage Polling")
    | "capabilities" ->
        Say.resolve lang (Say.make ~ko:"모델 기능 Capabilities" ~en:"Capabilities")
    | "model_bindings" ->
        Say.resolve lang (Say.make ~ko:"모델 바인딩" ~en:"Model Bindings")
    | other -> title_case_key other

let field_leaf_label ~lang (f : schema_field) =
  let pick ~ko ~en = Say.resolve lang (Say.make ~ko ~en) in
  let sub = table_last_segment f.table in
  let clean_key = strip_quotes f.key in
  let leaf = String.lowercase_ascii clean_key in
  match (sub, leaf) with
  | "credentials", "type" -> pick ~ko:"인증 방식" ~en:"Auth Type"
  | "auth", ("mode" | "type") -> pick ~ko:"인증 방식" ~en:"Auth Mode"
  | ("credentials" | "auth"), ("key" | "api-key" | "api_key" | "env") ->
      pick ~ko:"인증 키 / 환경변수" ~en:"API Key / Env"
  | ("credentials" | "auth"), ("token-path" | "token_path") ->
      pick ~ko:"토큰 경로" ~en:"Token Path"
  | "headers", _ ->
      pick
        ~ko:(Printf.sprintf "커스텀 헤더 (%s)" clean_key)
        ~en:(Printf.sprintf "Header (%s)" clean_key)
  | "healthcheck", "path" -> pick ~ko:"헬스체크 경로" ~en:"Healthcheck Path"
  | "healthcheck", ("interval-s" | "interval_s") ->
      pick ~ko:"헬스체크 주기 (초)" ~en:"Check Interval (s)"
  | ("usage-read" | "usage_read"), "url" ->
      pick ~ko:"사용량 조회 URL" ~en:"Usage Poll URL"
  | ("usage-read" | "usage_read"), ("kind" | "type") ->
      pick ~ko:"사용량 파서" ~en:"Usage Format"
  | "capabilities", "tools" -> pick ~ko:"도구 호출 지원" ~en:"Tool Calling"
  | "capabilities", "streaming" -> pick ~ko:"스트리밍 지원" ~en:"Streaming"
  | "capabilities", "vision" -> pick ~ko:"비전(이미지) 지원" ~en:"Vision"
  | "capabilities", ("prompt-caching" | "prompt_caching") ->
      pick ~ko:"프롬프트 캐싱" ~en:"Prompt Caching"
  | _, ("display-name" | "display_name") ->
      pick ~ko:"표시 이름" ~en:"Display Name"
  | _, "protocol" -> pick ~ko:"프로토콜" ~en:"Protocol"
  | _, ("endpoint" | "endpoint_url" | "base_url" | "base-url") ->
      pick ~ko:"엔드포인트 URL" ~en:"Endpoint URL"
  | _, "command" -> pick ~ko:"실행 명령" ~en:"CLI Command"
  | _, "args" -> pick ~ko:"실행 인자" ~en:"CLI Args"
  | _, ("connect-timeout-s" | "connect_timeout_s") ->
      pick ~ko:"연결 타임아웃 (초)" ~en:"Connect Timeout (s)"
  | _, ("exact-body-timeout-s" | "exact_body_timeout_s") ->
      pick ~ko:"본문 타임아웃 (초)" ~en:"Body Timeout (s)"
  | _, ("timeout-s" | "timeout_s" | "request-timeout-s" | "request_timeout_s") ->
      pick ~ko:"요청 타임아웃 (초)" ~en:"Request Timeout (s)"
  | _, ("max-retries" | "max_retries") ->
      pick ~ko:"최대 재시도" ~en:"Max Retries"
  | _, "enabled" -> pick ~ko:"활성화" ~en:"Enabled"
  | _, ("api-name" | "api_name" | "model") ->
      pick ~ko:"API 모델명" ~en:"API Model ID"
  | _, ("max-context" | "max_context" | "context-window" | "context_window") ->
      pick ~ko:"최대 컨텍스트" ~en:"Max Context"
  | _, ("max-output-tokens" | "max_output_tokens") ->
      pick ~ko:"최대 출력 토큰" ~en:"Max Output Tokens"
  | _, "temperature" -> pick ~ko:"온도 (Temperature)" ~en:"Temperature"
  | _, ("reasoning-effort" | "reasoning_effort") ->
      pick ~ko:"추론 강도" ~en:"Reasoning Effort"
  | "runtime", "default" -> pick ~ko:"기본 실행 경로" ~en:"Default Runtime"
  | "runtime", "media_failover" ->
      pick ~ko:"미디어 페일오버" ~en:"Media Failover"
  | _, ("candidates" | "order" | "members") ->
      pick ~ko:"후보 순서" ~en:"Failover Order"
  | _, "host" -> pick ~ko:"호스트" ~en:"Host"
  | _, "port" -> pick ~ko:"포트" ~en:"Port"
  | _, ("user" | "unix_user") -> pick ~ko:"계정" ~en:"User"
  | _, "max_sessions" ->
      pick ~ko:"최대 동시 세션" ~en:"Max Sessions"
  | _, ("max-concurrent" | "max_concurrent") ->
      pick ~ko:"최대 동시 실행" ~en:"Max Concurrent"
  | _, "tts_provider" -> pick ~ko:"TTS 엔진" ~en:"TTS Provider"
  | _, "voice_id" -> pick ~ko:"음성 ID" ~en:"Voice ID"
  | _, "model_id" -> pick ~ko:"모델 ID" ~en:"Model ID"
  | _, "theme" -> pick ~ko:"테마" ~en:"Theme"
  | _, "locale" -> pick ~ko:"언어" ~en:"Locale"
  | _, "refresh_ms" -> pick ~ko:"갱신 주기 (ms)" ~en:"Refresh (ms)"
  | _, "activation_mode" -> pick ~ko:"활성화 모드" ~en:"Activation Mode"
  | _, "instructions" -> pick ~ko:"시스템 지시문" ~en:"Instructions"
  | _, "sandbox_profile" -> pick ~ko:"샌드박스 프로필" ~en:"Sandbox Profile"
  | _, "network_mode" -> pick ~ko:"네트워크 모드" ~en:"Network Mode"
  | _, "microvm_backend" -> pick ~ko:"microVM 백엔드" ~en:"microVM Backend"
  | _, "remote_endpoint" -> pick ~ko:"원격 SSH 엔드포인트" ~en:"Remote Endpoint"
  | _, "mention_targets" -> pick ~ko:"멘션 대상" ~en:"Mention Targets"
  | _, "board_interests" -> pick ~ko:"관심 보드" ~en:"Board Interests"
  | _ ->
      if
        not (String.equal f.label "")
        && not (String.equal f.label f.full_key)
        && not (String.contains f.label '.')
      then f.label
      else title_case_key clean_key

type patch_op =
  | Set_scalar of { table : string; key : string; value : string }
  | Set_int of { table : string; key : string; value : int }
  | Set_float of { table : string; key : string; value : float }
  | Set_bool of { table : string; key : string; value : bool }
  | Set_string_array of { table : string; key : string; values : string list }
  | Remove_key of { table : string; key : string }

type patch_request = {
  target : config_target;
  keeper_name : string option;
  expected_sha256 : string option;
  dry_run : bool;
  ops : patch_op list;
}

type diff_hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  header : string;
  lines : string list;
}

type patch_response = {
  applied : bool;
  dry_run : bool;
  target : string;
  changed : bool;
  before_sha256 : string;
  new_sha256 : string;
  snapshot_id : string option;
  snapshot_path : string option;
  reload_scope : reload_scope;
  unified_diff : string;
  diff_hunks : diff_hunk list;
  validation_warnings : string list;
}

let encode_target = function
  | Target_runtime -> `String "runtime"
  | Target_keeper name -> `String ("keeper:" ^ name)
  | Target_keeper_create -> `String "keeper_create"

let encode_patch_op = function
  | Set_scalar { table; key; value } ->
      `Assoc
        [
          ("op", `String "set_scalar");
          ("table", `String table);
          ("key", `String key);
          ("value", `String value);
        ]
  | Set_int { table; key; value } ->
      `Assoc
        [
          ("op", `String "set_int");
          ("table", `String table);
          ("key", `String key);
          ("value", `Int value);
        ]
  | Set_float { table; key; value } ->
      `Assoc
        [
          ("op", `String "set_float");
          ("table", `String table);
          ("key", `String key);
          ("value", `Float value);
        ]
  | Set_bool { table; key; value } ->
      `Assoc
        [
          ("op", `String "set_bool");
          ("table", `String table);
          ("key", `String key);
          ("value", `Bool value);
        ]
  | Set_string_array { table; key; values } ->
      (* Server parses all set_* ops from the single ["value"] field. *)
      `Assoc
        [
          ("op", `String "set_string_array");
          ("table", `String table);
          ("key", `String key);
          ("value", `List (List.map (fun v -> `String v) values));
        ]
  | Remove_key { table; key } ->
      `Assoc
        [
          ("op", `String "remove_key");
          ("table", `String table);
          ("key", `String key);
        ]

let encode_patch_request req =
  let sha_json =
    match req.expected_sha256 with None -> `Null | Some s -> `String s
  in
  let keeper_field =
    match req.keeper_name with
    | None -> []
    | Some k -> [ ("keeper_name", `String k) ]
  in
  `Assoc
    ([
       ("target", encode_target req.target);
       ("expected_sha256", sha_json);
       ("dry_run", `Bool req.dry_run);
       ("ops", `List (List.map encode_patch_op req.ops));
     ]
    @ keeper_field)

let decode_diff_hunk json =
  let* old_start = required_nonnegative_int_field json "old_start" in
  let* old_count = required_nonnegative_int_field json "old_count" in
  let* new_start = required_nonnegative_int_field json "new_start" in
  let* new_count = required_nonnegative_int_field json "new_count" in
  let* header = required_string_field json "header" in
  let* lines = required_string_list json "lines" in
  Ok { old_start; old_count; new_start; new_count; header; lines }

let decode_patch_response json =
  let* _, body = unwrap_v2_or_raw json in
  let* applied = required_bool_field body "applied" in
  let* dry_run = required_bool_field body "dry_run" in
  let* target = required_nonblank_string body "target" in
  let* changed = required_bool_field body "changed" in
  let* before_sha256 = required_nonblank_string body "before_sha256" in
  let* new_sha256 = required_nonblank_string body "new_sha256" in
  let* snapshot_id = optional_nonblank_string body "snapshot_id" in
  let* snapshot_path = optional_nonblank_string body "snapshot_path" in
  let* reload_scope =
    decode_enum ~field:"reload_scope" reload_scope_of_string body
  in
  let* unified_diff = required_string_field body "unified_diff" in
  let* hunk_items = required_list_field body "diff_hunks" in
  let* diff_hunks = decode_list "diff_hunks" decode_diff_hunk hunk_items in
  let* validation_warnings =
    optional_string_list body "validation_warnings"
  in
  Ok
    {
      applied;
      dry_run;
      target;
      changed;
      before_sha256;
      new_sha256;
      snapshot_id;
      snapshot_path;
      reload_scope;
      unified_diff;
      diff_hunks;
      validation_warnings;
    }
