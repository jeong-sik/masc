type parse_error =
  { path : string
  ; message : string
  }
[@@deriving show]

(* --- Error accumulation --- *)

let error path message = [ { path; message } ]

let unknown_table_keys ~(path : string) ~(expected : string list) (entries : (string * Otoml.t) list) =
  List.concat_map
    (fun (key, _) ->
       if List.mem key expected
       then []
       else
         error
           (path ^ "." ^ key)
           (Printf.sprintf
              "unknown [%s] key %S; expected %s"
              path
              key
              (String.concat ", " expected)))
    entries
;;

(** [typed_find kind path tbl key getter] wraps [Otoml.find_opt] so that a
    type mismatch produces a structured [parse_error] instead of raising
    [Otoml.Type_error] past the parser boundary. *)
let typed_find (kind : string) (path : string) (tbl : Otoml.t) (key : string) getter
  : ('a option, parse_error list) result
  =
  try Ok (Otoml.find_opt tbl getter [ key ]) with
  | Otoml.Type_error msg ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf "%s must be %s; got %s" key kind msg))
;;

(** [typed_find_or kind path tbl key getter ~default] is {!typed_find} for a
    key whose absence means [default]. *)
let typed_find_or
      (kind : string)
      (path : string)
      (tbl : Otoml.t)
      (key : string)
      getter
      ~default
  : ('a, parse_error list) result
  =
  Result.map (Option.value ~default) (typed_find kind path tbl key getter)
;;

let strict_float_find (path : string) (tbl : Otoml.t) (key : string)
  : (float option, parse_error list) result
  =
  match Otoml.find_opt tbl Fun.id [ key ] with
  | None -> Ok None
  | Some (Otoml.TomlFloat value) -> Ok (Some value)
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlBoolean _)
  | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
  | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
  | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error (error (path ^ "." ^ key) (key ^ " must be a float"))
;;

let positive_finite_float_opt_field
      ~(path : string)
      ~(key : string)
      (value_result : (float option, parse_error list) result)
  : (float option, parse_error list) result
  =
  match value_result with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value > 0.0 && Float.is_finite value -> Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf
            "%s must be a positive finite float; got %g"
            key
            value))
;;

let required_non_empty_string
      ?(trim_result = false)
      (tbl : Otoml.t)
      ~(path : string)
      ~(key : string)
      ~(message : string)
  : (string, parse_error list) result
  =
  match typed_find "a string" path tbl key Otoml.get_string with
  | Error errors -> Error errors
  | Ok (Some value) when String.trim value <> "" ->
    Ok (if trim_result then String.trim value else value)
  | Ok (Some _ | None) -> Error (error (path ^ "." ^ key) message)
;;

(* Partition a list of per-entry parse results into a single
   collected result. Either every entry parsed (return [Ok all]),
   or at least one entry failed (return [Error] with every error
   concatenated). Removes the historical two-pass pattern where the
   success branch carried a dead [Error _ -> None] arm guarded by a
   prior [if errs <> []]: with this helper the dead arm cannot be
   written, so a future caller cannot accidentally re-introduce a
   silent drop. *)
let partition_results
  (results : ('a, parse_error list) result list)
  : ('a list, parse_error list) result
  =
  let oks, errs =
    List.partition_map
      (function
        | Ok x -> Either.Left x
        | Error e -> Either.Right e)
      results
  in
  if errs <> [] then Error (List.concat errs) else Ok oks
;;

(* --- Protocol string -> Runtime_schema.api_format --- *)

type editor_transport = Runtime_protocol.editor_transport = Endpoint | Command

type editor_semantics = Runtime_protocol.editor_semantics = Http_provider | Official_client

type editor_credential_policy = Runtime_protocol.editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol = Runtime_protocol.editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

let editor_protocols = Runtime_protocol.editor_protocols
let api_format_of_protocol = Runtime_protocol.api_format_of_protocol

(* --- Transport extraction --- *)

let transport_of_provider ~(path : string) (tbl : Otoml.t) (id : string)
  : (Runtime_schema.transport, parse_error list) result
  =
  match
    ( typed_find "a string" path tbl "endpoint" Otoml.get_string
    , typed_find "a string" path tbl "command" Otoml.get_string )
  with
  | Error endpoint_errors, Error command_errors -> Error (endpoint_errors @ command_errors)
  | Error errors, Ok _ | Ok _, Error errors -> Error errors
  | Ok (Some url), Ok None -> Ok (Runtime_schema.Http url)
  | Ok None, Ok (Some cmd) -> Ok (Runtime_schema.Cli cmd)
  | Ok (Some _), Ok (Some _) ->
    Error
      (error
         path
         (Printf.sprintf "provider %s: cannot specify both 'endpoint' and 'command'" id))
  | Ok None, Ok None ->
    Error
      (error
         path
         (Printf.sprintf "provider %s: must specify either 'endpoint' or 'command'" id))
;;

module Ns = Runtime_toml_namespace

let obsolete_top_level_namespaces = [ "system"; "routes"; "profiles" ]

(* A provider's bindings are a top-level table named after its id, so the id
   may not be a table another reader owns: [Runtime_toml_namespace] for the
   tables with a reader of their own, the keeper runtime settings'
   namespaces from their registry, and the obsolete tables this loader still
   refuses. Only provider ids become top-level tables; a model id sits under
   [[models]] and inside [[<provider>.<model>]], and an SSH endpoint under
   [[exec.ssh.endpoints]], so neither can collide and neither is checked. *)
let reserved_provider_ids =
  List.map Ns.key Ns.all
  @ Keeper_runtime_config.owned_namespaces
  @ obsolete_top_level_namespaces
;;

let is_reserved name = List.exists (String.equal name) reserved_provider_ids

(* Provider ids stay dot-free: a Runtime id is the literal string
   "<provider>.<model>", so a dot inside the provider id would make that
   compound ambiguous. Model ids admit '.' because they carry upstream API
   model names verbatim (gpt-5.3-codex-spark, mimo-v2.5), written as quoted
   TOML keys that Otoml already parses. *)
let valid_runtime_id_component ~allow_dot value =
  let length = String.length value in
  length > 0
  &&
  let rec loop index =
    if index = length
    then true
    else (
      match value.[index] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> loop (index + 1)
      | '.' when allow_dot -> loop (index + 1)
      | _ -> false)
  in
  loop 0
;;

let runtime_id_charset ~allow_dot =
  if allow_dot then "[A-Za-z0-9._-]+" else "[A-Za-z0-9_-]+"
;;

let validate_runtime_id_component ~allow_dot ~kind ~path value =
  if valid_runtime_id_component ~allow_dot value
  then Ok ()
  else
    Error
      (error
         path
         (Printf.sprintf "%s id must match %s" kind (runtime_id_charset ~allow_dot)))
;;

let validate_provider_id ~path value =
  match validate_runtime_id_component ~allow_dot:false ~kind:"provider" ~path value with
  | Error _ as refused -> refused
  | Ok () when is_reserved value ->
    Error
      (error
         path
         (Printf.sprintf
            "provider id %S collides with a reserved top-level runtime.toml namespace"
            value))
  | Ok () -> Ok ()
;;
