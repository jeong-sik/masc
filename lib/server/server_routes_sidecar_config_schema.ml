(** Sidecar config schema fetching and TOML rendering.

    Extracted from [server_routes_http_routes_sidecar.ml] during godfile
    decomposition. Pure schema/config utilities: schema cache, TOML
    serialization, type coercion, config path resolution. *)

(* ─── Schema cache ──────────────────────────────────────────────────────── *)

(** Per-process schema cache. The Pydantic [BotConfig.model_json_schema]
    output only changes when sidecar source changes, which requires a
    backend restart in practice (we don't hot-reload Python). So a
    per-id cache keyed by id is safe for the lifetime of this process. *)
let schema_cache : (string, string) Hashtbl.t = Hashtbl.create 8

(** Reset the cache; only used by tests. *)
let reset_schema_cache () = Hashtbl.reset schema_cache

(** Pick a Python interpreter for a given sidecar id.

    Discord-bot uses [uv] (project has pyproject.toml + uv.lock). The
    other 3 ship a hand-managed [.venv/]. We prefer the venv path when
    it exists because it sidesteps a [uv] dependency on the host running
    the backend. *)
let python_argv_for sidecar_dir =
  let venv_python = Filename.concat sidecar_dir ".venv/bin/python" in
  if Sys.file_exists venv_python
  then [ venv_python; "-m"; "src.schema_dump" ]
  else [ "uv"; "run"; "--directory"; sidecar_dir; "python"; "-m"; "src.schema_dump" ]
;;

let fetch_schema ?base_path id =
  match Hashtbl.find_opt schema_cache id with
  | Some cached -> Ok cached
  | None ->
    (match Server_routes_http_sidecar_paths.runtime_sidecar_dir_result ?base_path id with
     | Error _ as error -> error
     | Ok sidecar_dir ->
       let argv = python_argv_for sidecar_dir in
       let status, stdout =
         Masc_exec.Exec_gate.run_argv_with_status
           ~actor:`System_spawn
           ~raw_source:(String.concat " " argv)
           ~summary:"python schema dump"
           ~timeout_sec:Env_config_runtime.Sidecar.schema_generation_timeout_sec
           ~cwd:sidecar_dir
           argv
       in
       (match status with
        | Unix.WEXITED 0 ->
          let trimmed = String.trim stdout in
          Hashtbl.replace schema_cache id trimmed;
          Ok trimmed
        | _ ->
          Error
            "schema_dump failed; ensure the sidecar's Python deps are installed (run \
             `./run.sh start` once or `uv sync`)"))
;;

(* ─── TOML rendering ──────────────────────────────────────────────────── *)

(** ---- Config write (PUT) ----

    The dashboard config form (ConnectorConfigForm) submits the editor
    state as JSON. We whitelist keys against the sidecar's own schema
    (so only BotConfig-known names reach disk), coerce each value to
    its schema-declared TOML type, and atomically rewrite the runtime
    TOML at [.gate/runtime/<id>/config.toml].

    The sidecar picks this file up on next start (Pydantic
    [TomlConfigSettingsSource] sits in the source priority list below
    env but above field defaults). We do not hot-reload a running
    sidecar — that is the operator's job. *)

type toml_value =
  | Tstring of string
  | Tint of int
  | Tfloat of float
  | Tbool of bool

(** Hard cap on any single value the dashboard can write, so a
    runaway client can't balloon the TOML. Typical fields (tokens,
    URLs, numeric knobs) are well under this. *)
let max_value_bytes = 8192

let escape_toml_string s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter
    (fun c ->
       match c with
       | '\\' -> Buffer.add_string buf "\\\\"
       | '"' -> Buffer.add_string buf "\\\""
       | '\n' -> Buffer.add_string buf "\\n"
       | '\r' -> Buffer.add_string buf "\\r"
       | '\t' -> Buffer.add_string buf "\\t"
       | c when Char.code c < 0x20 -> Printf.bprintf buf "\\u%04x" (Char.code c)
       | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let render_value = function
  | Tstring s -> Printf.sprintf "\"%s\"" (escape_toml_string s)
  | Tint n -> string_of_int n
  | Tfloat f -> Printf.sprintf "%g" f
  | Tbool true -> "true"
  | Tbool false -> "false"
;;

let render_toml (pairs : (string * toml_value) list) : string =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  let lines =
    List.map (fun (k, v) -> Printf.sprintf "%s = %s" k (render_value v)) sorted
  in
  String.concat "\n" lines ^ "\n"
;;

type declared_type =
  [ `String
  | `Integer
  | `Number
  | `Boolean
  ]

let parse_declared_type json : declared_type option =
  match json with
  | `Assoc _ ->
    (match Json_util.assoc_member_opt "type" json with
     | Some (`String "string") -> Some `String
     | Some (`String "integer") -> Some `Integer
     | Some (`String "number") -> Some `Number
     | Some (`String "boolean") -> Some `Boolean
     | _ -> None)
  | _ -> None
;;

type schema_field_types_error =
  | Schema_fetch_error of string
  | Schema_json_parse_error of { message : string; body_preview : string }
  | Schema_unexpected_error of { message : string; body_preview : string }

let schema_field_types_error_kind = function
  | Schema_fetch_error _ -> "fetch_schema_error"
  | Schema_json_parse_error _ -> "json_parse_error"
  | Schema_unexpected_error _ -> "other"
;;

let schema_field_types_error_to_string = function
  | Schema_fetch_error message -> message
  | Schema_json_parse_error { message; body_preview } ->
    Printf.sprintf "json_parse_error: %s (body_preview=%S)" message body_preview
  | Schema_unexpected_error { message; body_preview } ->
    Printf.sprintf "other: %s (body_preview=%S)" message body_preview
;;

let body_preview json_str =
  let preview_len = min 200 (String.length json_str) in
  String.sub json_str 0 preview_len
;;

let schema_field_types_of_json json =
  match Json_util.assoc_member_opt "properties" json with
  | Some (`Assoc assoc) ->
    List.filter_map
      (fun (k, v) -> Option.map (fun typ -> k, typ) (parse_declared_type v))
      assoc
  | _ -> []
;;

let schema_field_types_result ?base_path id : ((string * declared_type) list, schema_field_types_error) result =
  match fetch_schema ?base_path id with
  | Error message -> Error (Schema_fetch_error message)
  | Ok json_str ->
    (match Yojson.Safe.from_string json_str with
     | json -> Ok (schema_field_types_of_json json)
     | exception Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e)
     | exception Yojson.Json_error msg ->
       Error (Schema_json_parse_error { message = msg; body_preview = body_preview json_str })
     | exception exn ->
       Error
         (Schema_unexpected_error
            { message = Printexc.to_string exn; body_preview = body_preview json_str }))
;;

let observe_schema_field_types_error ~id error =
  let error_kind = schema_field_types_error_kind error in
  Log.Server.warn
    "[sidecar.schema_field_types] id=%s %s"
    id
    (schema_field_types_error_to_string error);
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_sidecar_schema_field_types_failures
    ~labels:[ "error_kind", error_kind ]
    ();
  (match error with
   | Schema_json_parse_error _ | Schema_unexpected_error _ ->
     Otel_metric_store.inc_counter
       Otel_metric_store.metric_sidecar_schema_field_types_json_parse_failures
       ~labels:[ "error_kind", error_kind ]
       ()
   | Schema_fetch_error _ -> ())
;;

let schema_field_types ?base_path id : (string * declared_type) list =
  match schema_field_types_result ?base_path id with
  | Ok fields -> fields
  | Error error ->
    observe_schema_field_types_error ~id error;
    []
;;

let coerce_value (typ : declared_type) (raw : string) : (toml_value, string) result =
  if String.length raw > max_value_bytes
  then Error (Printf.sprintf "value too long (>%d bytes)" max_value_bytes)
  else (
    match typ with
    | `String -> Ok (Tstring raw)
    | `Integer ->
      (match int_of_string_opt (String.trim raw) with
       | Some n -> Ok (Tint n)
       | None -> Error (Printf.sprintf "expected integer, got %S" raw))
    | `Number ->
      (match float_of_string_opt (String.trim raw) with
       | Some n -> Ok (Tfloat n)
       | None -> Error (Printf.sprintf "expected number, got %S" raw))
    | `Boolean ->
      (match String.lowercase_ascii (String.trim raw) with
       | "true" | "1" -> Ok (Tbool true)
       | "false" | "0" -> Ok (Tbool false)
       | _ -> Error (Printf.sprintf "expected true/false, got %S" raw)))
;;

(* ─── Config path / body parsing ──────────────────────────────────────── *)

let config_toml_path ~base_path id =
  Filename.concat base_path (Printf.sprintf ".gate/runtime/%s/config.toml" id)
;;

(** Parse a JSON body of the form [{"<KEY>": "<VALUE>", ...}] into a
    list of pairs. All values are expected as JSON strings (the
    dashboard form emits them that way) — richer JSON types are
    converted to their string form so type coercion runs downstream
    from the same path. *)
let parse_body_pairs body_str : ((string * string) list, string) result =
  match Yojson.Safe.from_string body_str with
  | `Assoc assoc ->
    let pairs =
      List.map
        (fun (k, v) ->
           let s =
             match v with
             | `String s -> s
             | `Int i -> string_of_int i
             | `Float f -> Printf.sprintf "%g" f
             | `Bool b -> if b then "true" else "false"
             | `Null -> ""
             | _ -> Yojson.Safe.to_string v
           in
           k, s)
        assoc
    in
    Ok pairs
  | _ -> Error "body must be a JSON object"
  | exception Yojson.Json_error _ -> Error "body is not valid JSON"
;;
