open Masc_tui_core
open Json_decode_fields

let ( let* ) = Result.bind

type envelope_meta = {
  schema_version : int;
  instance_id : string;
  generated_at_unix : float;
}

let assoc_member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let has_field json key = Option.is_some (assoc_member_opt key json)

let reject_forbidden_field json key ~context =
  match json with
  | `Assoc fields ->
      if List.exists (fun (k, _) -> String.equal k key) fields then
        Error
          (Printf.sprintf "%s forbids legacy/unknown field %S" context key)
      else Ok ()
  | other -> field_type_error context "an object" other

let required_finite_float json key =
  match required_member json key with
  | Error _ as err -> err
  | Ok (`Float f) when Float.is_finite f -> Ok f
  | Ok (`Int i) -> Ok (Float.of_int i)
  | Ok (`Float _) ->
      Error (Printf.sprintf "field %S must be a finite number" key)
  | Ok bad -> field_type_error key "a finite number" bad

let optional_finite_float json key =
  match assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`Float f) when Float.is_finite f -> Ok (Some f)
  | Some (`Int i) -> Ok (Some (Float.of_int i))
  | Some (`Float _) ->
      Error (Printf.sprintf "field %S must be a finite number" key)
  | Some bad -> field_type_error key "a finite number or null" bad

let required_nonnegative_float json key =
  let* value = required_finite_float json key in
  if value < 0.0 then
    Error (Printf.sprintf "field %S must be non-negative" key)
  else Ok value

let required_nonblank_string json key =
  let* raw = required_string_field json key in
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    Error (Printf.sprintf "field %S must not be blank" key)
  else Ok trimmed

let optional_nonblank_string json key =
  let* raw = optional_string_field json key in
  match raw with
  | None -> Ok None
  | Some s ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then Ok None else Ok (Some trimmed)

let required_string_list json key =
  let* items = required_list_field json key in
  decode_list key
    (function
      | `String s -> Ok s
      | bad -> field_type_error key "a string" bad)
    items

let optional_string_list json key =
  let* items = optional_list_field json key in
  decode_list key
    (function
      | `String s -> Ok s
      | bad -> field_type_error key "a string" bad)
    items

let decode_enum ~field parse json =
  let* raw = required_string_field json field in
  match parse raw with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "unknown %s value %S" field raw)

let decode_optional_enum ~field parse json =
  let* raw = optional_nonblank_string json field in
  match raw with
  | None -> Ok None
  | Some word -> (
      match parse word with
      | Some v -> Ok (Some v)
      | None -> Error (Printf.sprintf "unknown %s value %S" field word))

let unwrap_v2_envelope json =
  match json with
  | `Assoc _ ->
      let* schema_version = required_int_field json "schema_version" in
      let* () =
        if schema_version < 1 then
          Error
            (Printf.sprintf "invalid envelope schema_version %d" schema_version)
        else Ok ()
      in
      let* instance_id = required_nonblank_string json "instance_id" in
      let* generated_at_unix =
        required_nonnegative_float json "generated_at_unix"
      in
      let* data = required_member json "data" in
      Ok ({ schema_version; instance_id; generated_at_unix }, data)
  | bad -> field_type_error "envelope" "an object" bad

let unwrap_v2_or_raw json =
  match json with
  | `Assoc _ ->
      if has_field json "schema_version" && has_field json "data" then
        let* meta, data = unwrap_v2_envelope json in
        Ok (Some meta, data)
      else Ok (None, json)
  | bad -> field_type_error "response" "an object" bad

let observed_of_json ~observed_at decode json key =
  match assoc_member_opt key json with
  | None -> Ok Observed.unreported
  | Some `Null -> Ok Observed.absent
  | Some raw ->
      let* value = decode raw in
      Ok (Observed.value ~observed_at value)

let observed_float ~observed_at json key =
  observed_of_json ~observed_at
    (function
      | `Float f when Float.is_finite f -> Ok f
      | `Int i -> Ok (Float.of_int i)
      | `Float _ -> Error (Printf.sprintf "field %S must be finite" key)
      | bad -> field_type_error key "a finite number" bad)
    json key

let observed_int ~observed_at json key =
  observed_of_json ~observed_at
    (function
      | `Int i -> Ok i
      | bad -> field_type_error key "an integer" bad)
    json key

let observed_string ~observed_at json key =
  observed_of_json ~observed_at
    (function
      | `String s -> Ok s
      | bad -> field_type_error key "a string" bad)
    json key

let observed_bool ~observed_at json key =
  observed_of_json ~observed_at
    (function
      | `Bool b -> Ok b
      | bad -> field_type_error key "a boolean" bad)
    json key

(* Pure civil date <-> days since 1970-01-01 (Howard Hinnant's algorithm). *)
let days_from_civil ~year ~month ~day =
  let y = if month <= 2 then year - 1 else year in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let m_adj = if month > 2 then month - 3 else month + 9 in
  let doy = ((153 * m_adj) + 2) / 5 + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe =
    (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365
  in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let day = doy - (((153 * mp) + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  let year = if month <= 2 then y + 1 else y in
  (year, month, day)

let is_leap_year y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0

let days_in_month ~year ~month =
  match month with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap_year year then 29 else 28
  | _ -> 0

let parse_digits s ~off ~len =
  if off < 0 || len <= 0 || off + len > String.length s then None
  else
    let rec loop idx acc =
      if idx = off + len then Some acc
      else
        let c = s.[idx] in
        if c >= '0' && c <= '9' then
          loop (idx + 1) ((acc * 10) + (Char.code c - Char.code '0'))
        else None
    in
    loop off 0

let parse_rfc3339_unix raw =
  let s = String.trim raw in
  let n = String.length s in
  if n < 20 then Error (Printf.sprintf "invalid RFC3339 timestamp %S" raw)
  else
    let sep = s.[10] in
    if
      s.[4] <> '-' || s.[7] <> '-'
      || (sep <> 'T' && sep <> 't' && sep <> ' ')
      || s.[13] <> ':' || s.[16] <> ':'
    then Error (Printf.sprintf "invalid RFC3339 timestamp %S" raw)
    else
      match
        ( parse_digits s ~off:0 ~len:4
        , parse_digits s ~off:5 ~len:2
        , parse_digits s ~off:8 ~len:2
        , parse_digits s ~off:11 ~len:2
        , parse_digits s ~off:14 ~len:2
        , parse_digits s ~off:17 ~len:2 )
      with
      | Some year, Some month, Some day, Some hour, Some minute, Some second ->
          let valid_date =
            month >= 1 && month <= 12 && day >= 1
            && day <= days_in_month ~year ~month
            && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59
            && second >= 0 && second <= 60
          in
          if not valid_date then
            Error (Printf.sprintf "out-of-range RFC3339 timestamp %S" raw)
          else
            let idx = ref 19 in
            let frac = ref 0.0 in
            let frac_ok = ref true in
            if !idx < n && s.[!idx] = '.' then begin
              incr idx;
              let start = !idx in
              let scale = ref 0.1 in
              while !idx < n && s.[!idx] >= '0' && s.[!idx] <= '9' do
                let d = float_of_int (Char.code s.[!idx] - Char.code '0') in
                frac := !frac +. (d *. !scale);
                scale := !scale *. 0.1;
                incr idx
              done;
              if !idx = start then frac_ok := false
            end;
            if not !frac_ok then
              Error (Printf.sprintf "invalid fractional seconds in %S" raw)
            else
              let tz_offset_sec =
                if !idx = n - 1 && (s.[!idx] = 'Z' || s.[!idx] = 'z') then Ok 0
                else if
                  !idx + 6 = n
                  && (s.[!idx] = '+' || s.[!idx] = '-')
                  && s.[!idx + 3] = ':'
                then
                  let sign = if s.[!idx] = '+' then 1 else -1 in
                  match
                    ( parse_digits s ~off:(!idx + 1) ~len:2
                    , parse_digits s ~off:(!idx + 4) ~len:2 )
                  with
                  | Some th, Some tm when th <= 23 && tm <= 59 ->
                      Ok (sign * ((th * 3600) + (tm * 60)))
                  | _ -> Error (Printf.sprintf "invalid timezone offset in %S" raw)
                else Error (Printf.sprintf "missing or invalid timezone in %S" raw)
              in
              let* tz = tz_offset_sec in
              let days = days_from_civil ~year ~month ~day in
              let secs =
                (Float.of_int days *. 86400.0)
                +. Float.of_int ((hour * 3600) + (minute * 60) + second - tz)
                +. !frac
              in
              Ok secs
      | _ -> Error (Printf.sprintf "invalid RFC3339 digits in %S" raw)

let format_unix_rfc3339 ts =
  if not (Float.is_finite ts) then "1970-01-01T00:00:00Z"
  else
    let whole = Int64.of_float (Float.floor ts) in
    let day_secs = 86400L in
    let days64 =
      if whole >= 0L then Int64.div whole day_secs
      else Int64.div (Int64.sub whole (Int64.sub day_secs 1L)) day_secs
    in
    let rem = Int64.to_int (Int64.sub whole (Int64.mul days64 day_secs)) in
    let year, month, day = civil_from_days (Int64.to_int days64) in
    let hour = rem / 3600 in
    let minute = (rem mod 3600) / 60 in
    let second = rem mod 60 in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" year month day hour minute
      second

let decode_timestamp_unix json key =
  match required_member json key with
  | Error _ as err -> err
  | Ok (`Float f) when Float.is_finite f -> Ok f
  | Ok (`Int i) -> Ok (Float.of_int i)
  | Ok (`String s) -> parse_rfc3339_unix s
  | Ok bad -> field_type_error key "a unix timestamp or RFC3339 string" bad

let decode_optional_timestamp_unix json key =
  match assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`Float f) when Float.is_finite f -> Ok (Some f)
  | Some (`Int i) -> Ok (Some (Float.of_int i))
  | Some (`String s) ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then Ok None
      else
        let* ts = parse_rfc3339_unix trimmed in
        Ok (Some ts)
  | Some bad ->
      field_type_error key "a unix timestamp, RFC3339 string, or null" bad

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char buf c
      else Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents buf

type workspace_identity = {
  instance_id : string option;
  base_path : string;
  masc_root : string;
  workspace_sha256 : string option;
}

type health_scope =
  | Public_health
  | Full_health of workspace_identity

type server_gc_stats = {
  live_words : int option;
  heap_words : int option;
  major_collections : int option;
  minor_collections : int option;
}

type server_health = {
  ok : bool;
  live : bool option;
  ready : bool option;
  phase : string option;
  status : string;
  version : string;
  binary_commit : string option;
  uptime_display : string option;
  uptime_sec : float option;
  scope : health_scope;
  gc : server_gc_stats option;
  active_keepers : int option;
}

let health_path = "/health"

let first_nonblank_str objs keys =
  let rec loop_objs = function
    | [] -> Ok None
    | obj :: rest_objs ->
        let rec loop_keys = function
          | [] -> loop_objs rest_objs
          | k :: rest_keys -> (
              match optional_nonblank_string obj k with
              | Ok (Some _ as v) -> Ok v
              | Ok None -> loop_keys rest_keys
              | Error _ as err -> err)
        in
        loop_keys keys
  in
  loop_objs objs

let decode_server_health json =
  let* () =
    match json with
    | `Assoc _ -> Ok ()
    | bad -> field_type_error "/health" "an object" bad
  in
  let* () =
    match assoc_member_opt "account_mode" json with
    | None | Some `Null -> Ok ()
    | Some _ ->
        Error
          "/health carries account_mode, which no workspace MASC server carries"
  in
  let* build = optional_object_field json "build" in
  let* paths = optional_object_field json "paths" in
  let* startup = optional_object_field json "startup" in
  let* gc_obj = optional_object_field json "gc" in
  let opt_list o = match o with Some x -> [ x ] | None -> [] in
  let* version_opt =
    first_nonblank_str (opt_list build @ [ json ])
      [ "release_version"; "version" ]
  in
  let* version =
    match version_opt with
    | Some v -> Ok v
    | None -> missing_field "version"
  in
  let* binary_commit =
    first_nonblank_str (opt_list build @ [ json ])
      [ "git_commit"; "binary_commit" ]
  in
  let* live =
    match optional_bool_field json "live" with
    | Ok (Some _ as v) -> Ok v
    | Ok None -> (
        match startup with
        | Some s -> optional_bool_field s "live"
        | None -> Ok None)
    | Error _ as err -> err
  in
  let* ready =
    match optional_bool_field json "ready" with
    | Ok (Some _ as v) -> Ok v
    | Ok None -> (
        match startup with
        | Some s -> optional_bool_field s "ready"
        | None -> Ok None)
    | Error _ as err -> err
  in
  let* phase =
    first_nonblank_str ([ json ] @ opt_list startup) [ "phase" ]
  in
  let* status =
    match optional_nonblank_string json "status" with
    | Ok (Some s) -> Ok s
    | Ok None -> (
        match (ready, phase, live) with
        | Some true, _, _ -> Ok "ready"
        | _, Some p, _ -> Ok p
        | _, None, Some true -> Ok "live"
        | Some false, None, (Some false | None) -> Ok "not_ready"
        | None, None, (Some false | None) -> Ok "ok")
    | Error _ as err -> err
  in
  let* ok =
    match optional_bool_field json "ok" with
    | Ok (Some b) -> Ok b
    | Ok None -> (
        match (ready, live) with
        | Some r, _ -> Ok r
        | None, Some l -> Ok l
        | None, None ->
            Ok
              (String.equal status "ok" || String.equal status "healthy"
             || String.equal status "ready"))
    | Error _ as err -> err
  in
  let* uptime_display, uptime_sec =
    match assoc_member_opt "uptime" json with
    | Some (`String s) ->
        let trimmed = String.trim s in
        let disp = if String.equal trimmed "" then None else Some trimmed in
        let* sec = optional_finite_float json "uptime_sec" in
        let* sec =
          match sec with
          | Some _ -> Ok sec
          | None -> optional_finite_float json "uptime_seconds"
        in
        Ok (disp, sec)
    | Some (`Float f) when Float.is_finite f -> Ok (None, Some f)
    | Some (`Int i) -> Ok (None, Some (Float.of_int i))
    | Some `Null | None ->
        let* sec = optional_finite_float json "uptime_sec" in
        let* sec =
          match sec with
          | Some _ -> Ok sec
          | None -> optional_finite_float json "uptime_seconds"
        in
        Ok (None, sec)
    | Some bad -> field_type_error "uptime" "a string or finite number" bad
  in
  let has_full_paths =
    Option.is_some paths
    || has_field json "effective_base_path"
    || has_field json "base_path"
  in
  let* scope =
    if not has_full_paths then
      (* Public unauthenticated [/health] carries [server]/[live]/[ready]/[phase]
         without workspace paths. Never fabricate a workspace identity. *)
      let* server_opt = optional_nonblank_string json "server" in
      match (server_opt, live, ready) with
      | None, None, None ->
          Error
            "/health response carries neither workspace paths nor public readiness fields"
      | _ -> Ok Public_health
    else
      let path_objs = opt_list paths @ [ json ] in
      let* base_path_opt =
        first_nonblank_str path_objs [ "effective_base_path"; "base_path" ]
      in
      let* base_path =
        match base_path_opt with
        | Some p -> Ok p
        | None -> missing_field "paths.effective_base_path"
      in
      let* masc_root_opt =
        first_nonblank_str path_objs [ "effective_masc_root"; "masc_root" ]
      in
      let* masc_root =
        match masc_root_opt with
        | Some p -> Ok p
        | None -> missing_field "paths.effective_masc_root"
      in
      let* instance_id =
        first_nonblank_str
          (opt_list build @ opt_list startup @ [ json ])
          [ "runtime_instance_id"; "instance_id" ]
      in
      let* workspace_sha256 =
        first_nonblank_str path_objs [ "workspace_sha256" ]
      in
      Ok
        (Full_health
           { instance_id; base_path; masc_root; workspace_sha256 })
  in
  let* active_keepers = optional_int_field json "active_keepers" in
  let* gc =
    match gc_obj with
    | None -> Ok None
    | Some g ->
        let* live_words = optional_int_field g "live_words" in
        let* heap_words = optional_int_field g "heap_words" in
        let* major_collections = optional_int_field g "major_collections" in
        let* minor_collections = optional_int_field g "minor_collections" in
        Ok (Some { live_words; heap_words; major_collections; minor_collections })
  in
  Ok
    {
      ok;
      live;
      ready;
      phase;
      status;
      version;
      binary_commit;
      uptime_display;
      uptime_sec;
      scope;
      gc;
      active_keepers;
    }

type api_error_code =
  | Invalid_param
  | Unauthorized
  | Not_found
  | Sandbox_telemetry_missing
  | Conflict_cas
  | Workspace_mismatch
  | Validation_failed
  | Store_unavailable
  | Other_code of string

type api_error = {
  code : api_error_code;
  message : string;
  field : string option;
  expected_instance : string option;
  observed_instance : string option;
  observed_workspace_sha256 : string option;
}

let api_error_code_of_string = function
  | "invalid_param" | "invalid_request" -> Invalid_param
  | "unauthorized" | "forbidden" -> Unauthorized
  | "not_found" -> Not_found
  | "sandbox_telemetry_missing" -> Sandbox_telemetry_missing
  | "conflict_cas" -> Conflict_cas
  | "workspace_mismatch" | "workspace_changed" -> Workspace_mismatch
  | "validation_failed" -> Validation_failed
  | "store_unavailable" -> Store_unavailable
  | other -> Other_code other

let api_error_code_to_string = function
  | Invalid_param -> "invalid_param"
  | Unauthorized -> "unauthorized"
  | Not_found -> "not_found"
  | Sandbox_telemetry_missing -> "sandbox_telemetry_missing"
  | Conflict_cas -> "conflict_cas"
  | Workspace_mismatch -> "workspace_mismatch"
  | Validation_failed -> "validation_failed"
  | Store_unavailable -> "store_unavailable"
  | Other_code s -> s

let decode_api_error json =
  let* target =
    match assoc_member_opt "error" json with
    | Some (`Assoc _ as inner) -> Ok inner
    | Some (`String _) | None -> Ok json
    | Some bad -> field_type_error "error" "an object or string" bad
  in
  let* code_str = required_nonblank_string target "code" in
  let* message =
    match optional_nonblank_string target "message" with
    | Ok (Some msg) -> Ok msg
    | Ok None -> (
        match optional_nonblank_string target "error" with
        | Ok (Some msg) -> Ok msg
        | Ok None -> Ok code_str
        | Error _ as err -> err)
    | Error _ as err -> err
  in
  let* field = optional_nonblank_string target "field" in
  let* expected_instance = optional_nonblank_string target "expected_instance" in
  let* observed_instance = optional_nonblank_string target "observed_instance" in
  let* observed_workspace_sha256 =
    optional_nonblank_string target "observed_workspace_sha256"
  in
  Ok
    {
      code = api_error_code_of_string code_str;
      message;
      field;
      expected_instance;
      observed_instance;
      observed_workspace_sha256;
    }
