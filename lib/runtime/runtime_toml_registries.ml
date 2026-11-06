(** The registry tables of the Runtime TOML parser that sit beside the
    provider layers: SSH exec endpoints, egress allowlists (RFC-0415) and LSP
    servers. *)

open Runtime_toml_base
open Runtime_toml_providers
open Runtime_toml_models

(* --- [exec.ssh.endpoints] registry (Phase 1 SSH lane, spec §4.2) --- *)

let exec_ssh_endpoint_keys =
  [ "host"
  ; "user"
  ; "port"
  ; "identity_file"
  ; "known_hosts_file"
  ; "remote_root"
  ; "connect_timeout_sec"
  ; "max_concurrent_sessions"
  ; "env_allowlist"
  ; "capabilities"
  ; "private_home"
  ; "allowed_paths"
  ]
;;

(* Required endpoint strings reject surrounding whitespace rather than
   storing padding verbatim — symmetric with [exact_non_empty_string_opt_field]
   on the optional fields of the same record. *)
let exec_ssh_required_string ~(path : string) (tbl : Otoml.t) ~(key : string)
  : (string, parse_error list) result
  =
  match
    required_non_empty_string
      tbl
      ~path
      ~key
      ~message:(Printf.sprintf "endpoint requires non-empty '%s'" key)
  with
  | Error _ as error -> error
  | Ok value when value <> String.trim value ->
    Error
      (error
         (path ^ "." ^ key)
         (key ^ " must not have leading or trailing whitespace"))
  | Ok value -> Ok value
;;

(* The shim maps keeper paths under [remote_root] (spec §4.2 path mapping); a
   relative root would make that translation cwd-dependent, so the value is
   rejected at load — the same fail-closed shape as the [healthcheck.path must
   be absolute] check in [parse_provider]. *)
let exec_ssh_remote_root_field ~(path : string) (tbl : Otoml.t)
  : (string, parse_error list) result
  =
  (* Non-emptiness is proven by [exec_ssh_required_string], so the [0] index
     cannot raise. *)
  match exec_ssh_required_string ~path tbl ~key:"remote_root" with
  | Error _ as error -> error
  | Ok remote_root when Char.equal remote_root.[0] '/' -> Ok remote_root
  | Ok remote_root ->
    Error
      (error
         (path ^ ".remote_root")
         (Printf.sprintf "remote_root must be absolute, got %S" remote_root))
;;

(* ssh accepts ports 1..65535; [positive_int_opt_field] covers the lower
   bound, this adds the upper one so a typo is a load error instead of a
   dispatch-time ssh failure. *)
let exec_ssh_port_field ~(path : string) (tbl : Otoml.t)
  : (int option, parse_error list) result
  =
  match positive_int_opt_field ~path ~key:"port" tbl with
  | Error _ as error -> error
  | Ok (Some port) when port > 65535 ->
    Error
      (error
         (path ^ ".port")
         (Printf.sprintf "port must be in 1..65535; got %d" port))
  | Ok port -> Ok port
;;

(* One [allowed_paths] entry names an endpoint-side root that Execute path
   checks compare lexically (the endpoint may be another machine, so the host
   cannot resolve it). The entry must therefore already be in the form the
   comparison needs: absolute, with no empty, [.] or [..] segment (so no
   trailing or doubled '/'), and not [/] itself, which would lift the
   boundary entirely. *)
let exec_ssh_allowed_path_error (value : string) : string option =
  if String.equal value "" || not (Char.equal value.[0] '/')
  then Some "must be absolute"
  else if String.equal value "/"
  then Some "must not be the filesystem root"
  else (
    let segments =
      String.split_on_char '/' (String.sub value 1 (String.length value - 1))
    in
    if
      List.exists
        (fun segment ->
           String.equal segment ""
           || String.equal segment "."
           || String.equal segment "..")
        segments
    then Some "must be normalized (no empty, '.' or '..' segment, no trailing '/')"
    else None)
;;

(* The roots belong to the endpoint, not to one keeper: every keeper on it
   under [remote_root] may name them. A root that is [remote_root] or one of
   its ancestors would therefore let each keeper name the others' areas. *)
let exec_ssh_allowed_path_covers_remote_root ~remote_root value =
  let rec strip_trailing_slash dir =
    let n = String.length dir in
    if n > 1 && Char.equal dir.[n - 1] '/'
    then strip_trailing_slash (String.sub dir 0 (n - 1))
    else dir
  in
  let remote_root = strip_trailing_slash remote_root in
  String.equal value remote_root
  || String.starts_with ~prefix:(value ^ "/") remote_root
;;

let exec_ssh_allowed_paths_field ~(path : string) (tbl : Otoml.t)
  : (string list, parse_error list) result
  =
  match
    typed_find
      "an array of strings"
      path
      tbl
      "allowed_paths"
      (Otoml.get_array Otoml.get_string)
  with
  | Error _ as err -> err
  | Ok None -> Ok []
  | Ok (Some values) ->
    let entry_errors =
      List.concat
        (List.mapi
           (fun index value ->
              match exec_ssh_allowed_path_error value with
              | None -> []
              | Some reason ->
                error
                  (Printf.sprintf "%s.allowed_paths[%d]" path index)
                  (Printf.sprintf "allowed_paths entry %s, got %S" reason value))
           values)
    in
    (match entry_errors with
     | [] -> Ok values
     | _ :: _ -> Error entry_errors)
;;

(** Parse one [\[exec.ssh.endpoints.<name>\]] table. Every key must be one of
    {!exec_ssh_endpoint_keys}; any other key fails the load so a misspelled
    knob is never silently dropped. [host], [user], and [remote_root] are
    required non-empty strings and reject surrounding whitespace (padding is
    a typo, not a value); [remote_root] must additionally be absolute, since
    the shim's path mapping is defined against it. [port] must be in
    1..65535; every other key carries the spec default. The two file defaults
    resolve here, where the endpoint name is in scope, to base-relative paths
    with the name substituted (see {!Exec_ssh_endpoint}). Unknown
    [capabilities] values warn-and-ignore per the spec table — they are
    Phase 2 reservations, not Phase 1 knobs. Each [allowed_paths] entry must
    be absolute and normalized and not [/]; any other entry fails the load. *)
let parse_exec_ssh_endpoint ~(name : string) (tbl : Otoml.t)
  : (Exec_ssh_endpoint.t, parse_error list) result
  =
  let path = Ns.(path Exec) ("ssh.endpoints." ^ name) in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if List.mem key exec_ssh_endpoint_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown exec ssh endpoint key %S; expected %s"
                  key
                  (String.concat ", " exec_ssh_endpoint_keys)))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTableArray _ -> error path "endpoint must be a TOML table"
  in
  let host_result = exec_ssh_required_string ~path tbl ~key:"host" in
  let user_result = exec_ssh_required_string ~path tbl ~key:"user" in
  let destination_result =
    match host_result, user_result with
    | Ok host, Ok user ->
      Exec_ssh_endpoint.validate_destination ~host ~user
      |> Result.map_error (fun message -> error path message)
    | Error _, _ | _, Error _ -> Ok ()
  in
  let remote_root_result = exec_ssh_remote_root_field ~path tbl in
  let port_result = exec_ssh_port_field ~path tbl in
  let identity_file_result = exact_non_empty_string_opt_field ~path tbl "identity_file" in
  let known_hosts_file_result =
    exact_non_empty_string_opt_field ~path tbl "known_hosts_file"
  in
  let connect_timeout_sec_result =
    positive_int_opt_field ~path ~key:"connect_timeout_sec" tbl
  in
  let max_concurrent_sessions_result =
    positive_int_opt_field ~path ~key:"max_concurrent_sessions" tbl
  in
  let string_array_field key =
    Result.map
      (Option.value ~default:[])
      (typed_find
         "an array of strings"
         path
         tbl
         key
         (Otoml.get_array Otoml.get_string))
  in
  let env_allowlist_result = string_array_field "env_allowlist" in
  let capabilities_result = string_array_field "capabilities" in
  (* RFC-0422 §3.4: the operator's declaration that the account home is the
     keeper's alone. Absent is [false], so a shared account keeps the judge
     for every write until someone says otherwise in this file. *)
  let private_home_result =
    typed_find_or "a boolean" path tbl "private_home" Otoml.get_boolean ~default:false
  in
  let allowed_paths_result = exec_ssh_allowed_paths_field ~path tbl in
  (* Checked once both fields parsed, like [destination_result]: a field that
     failed already reports its own error. *)
  let allowed_paths_cover_result =
    match remote_root_result, allowed_paths_result with
    | Ok remote_root, Ok allowed_paths ->
      (match
         List.concat
           (List.mapi
              (fun index value ->
                 if exec_ssh_allowed_path_covers_remote_root ~remote_root value
                 then
                   error
                     (Printf.sprintf "%s.allowed_paths[%d]" path index)
                     (Printf.sprintf
                        "allowed_paths entry must not be remote_root or an ancestor of it, got %S"
                        value)
                 else [])
              allowed_paths)
       with
       | [] -> Ok ()
       | _ :: _ as cover_errors -> Error cover_errors)
    | Error _, _ | _, Error _ -> Ok ()
  in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let field_errors =
    errs host_result
    @ errs user_result
    @ errs destination_result
    @ errs remote_root_result
    @ errs port_result
    @ errs identity_file_result
    @ errs known_hosts_file_result
    @ errs connect_timeout_sec_result
    @ errs max_concurrent_sessions_result
    @ errs env_allowlist_result
    @ errs capabilities_result
    @ errs private_home_result
    @ errs allowed_paths_result
    @ errs allowed_paths_cover_result
  in
  match unknown_key_errors with
  | _ :: _ -> Error (unknown_key_errors @ field_errors)
  | [] ->
    (match
       ( host_result
       , user_result
       , destination_result
       , remote_root_result
       , port_result
       , identity_file_result
       , known_hosts_file_result
       , connect_timeout_sec_result
       , max_concurrent_sessions_result
       , env_allowlist_result
       , capabilities_result
       , private_home_result
       , allowed_paths_result
       , allowed_paths_cover_result )
     with
     | ( Ok host
       , Ok user
       , Ok ()
       , Ok remote_root
       , Ok port
       , Ok identity_file
       , Ok known_hosts_file
       , Ok connect_timeout_sec
       , Ok max_concurrent_sessions
       , Ok env_allowlist
       , Ok declared_capabilities
       , Ok private_home
       , Ok allowed_paths
       , Ok () ) ->
       let capabilities =
         List.filter
           (fun capability ->
              if List.mem capability Exec_ssh_endpoint.known_capabilities
              then true
              else (
                Log.Runtime.warn
                  "runtime_toml: %s.capabilities — unknown capability %S, ignoring"
                  path
                  capability;
                false))
           declared_capabilities
       in
       Ok
         { Exec_ssh_endpoint.name
         ; host
         ; user
         ; port = Option.value ~default:Exec_ssh_endpoint.default_port port
         ; identity_file =
             Option.value
               ~default:(Exec_ssh_endpoint.default_identity_file ~name)
               identity_file
         ; known_hosts_file =
             Option.value
               ~default:(Exec_ssh_endpoint.default_known_hosts_file ~name)
               known_hosts_file
         ; remote_root
         ; connect_timeout_sec =
             Option.value
               ~default:Exec_ssh_endpoint.default_connect_timeout_sec
               connect_timeout_sec
         ; max_concurrent_sessions =
             Option.value
               ~default:Exec_ssh_endpoint.default_max_concurrent_sessions
               max_concurrent_sessions
         ; env_allowlist
         ; capabilities
         ; private_home
         ; allowed_paths
         }
     (* [field_errors] is non-empty exactly when some field result is [Error],
        so this arm always carries at least one error. *)
     | ( (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _) ) -> Error field_errors)
;;

(* [exec] owns exactly [ssh] and [exec.ssh] owns exactly [endpoints]: the
   namespace is closed, so any sibling key is a typo the load names rather
   than silently dropping — the same fail-closed posture as unknown provider
   capabilities keys. *)
let exec_single_child ~(path : string) ~(child_key : string) (value : Otoml.t)
  : (Otoml.t option, parse_error list) result
  =
  match value with
  | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
    let stray, children =
      List.partition (fun (key, _) -> not (String.equal key child_key)) entries
    in
    let stray_errors =
      List.concat_map
        (fun (key, _) ->
           error
             (path ^ "." ^ key)
             (Printf.sprintf
                "unknown [%s] key %S; expected only [%s.%s]"
                path
                key
                path
                child_key))
        stray
    in
    (match stray_errors, children with
     | _ :: _, _ -> Error stray_errors
     | [], [] -> Ok None
     | [], [ (_, child) ] -> Ok (Some child)
     (* A repeated table key is rejected by the TOML parser itself, so more
        than one [child_key] entry cannot reach here; fail loud rather than
        silently picking one if that invariant ever breaks. *)
     | [], _ :: _ :: _ ->
       Error
         (error
            (path ^ "." ^ child_key)
            (Printf.sprintf "duplicate [%s.%s] table" path child_key)))
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ ->
    Error (error path (Printf.sprintf "[%s] must be a TOML table" path))
;;

(** Walk [\[exec.ssh.endpoints.*\]] tables into the endpoint registry. Each
    endpoint name passes {!validate_runtime_id_component} dot-free, matching
    provider ids. Absent [\[exec\]] section yields an empty registry. *)
(* [\[egress.keepers.<name>\]] — one keeper's allowlist (RFC-0415).

   Every rule is parsed here, at config load, rather than when a request
   arrives. A rule a resolver could read differently than [Egress_host] does
   is an operator mistake, and finding it while the file is being read is the
   difference between refusing to boot and serving a live allowlist with a
   hole in it. *)
let egress_keeper_keys = [ "allow" ]

let parse_egress_keeper ~(name : string) (tbl : Otoml.t)
  : (Egress_allowlist.t, parse_error list) result
  =
  let path = Ns.(path Egress) ("keepers." ^ name) in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if List.mem key egress_keeper_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown egress keeper key %S; expected %s"
                  key
                  (String.concat ", " egress_keeper_keys)))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> error path "expected a table"
  in
  match unknown_key_errors with
  | _ :: _ as errors -> Error errors
  | [] ->
    (match
       typed_find "an array of strings" path tbl "allow" (Otoml.get_array Otoml.get_string)
     with
     | Error errors -> Error errors
     | Ok None ->
       (* An entry that declares no [allow] is almost certainly a mistake, and
          the safe reading of it -- an allowlist that admits nothing -- is
          already what omitting the whole table gives. Refusing says which of
          the two the operator meant. *)
       error path "egress keeper table has no 'allow' array"
       |> fun errors -> Error errors
     | Ok (Some raws) ->
       let parsed =
         List.map
           (fun raw ->
              match Egress_host.rule_of_string raw with
              | Ok rule -> Ok rule
              | Error parse_error ->
                Error
                  (error
                     (path ^ ".allow")
                     (Printf.sprintf
                        "%S is not a host this lane will match: %s"
                        raw
                        (Egress_host.parse_error_to_string parse_error))))
           raws
       in
       let errors = List.concat_map (function Error e -> e | Ok _ -> []) parsed in
       (match errors with
        | _ :: _ -> Error errors
        | [] ->
          Ok
            { Egress_allowlist.keeper_name = name
            ; allow = List.filter_map (function Ok rule -> Some rule | Error _ -> None) parsed
            }))
;;

(** Walk [\[egress.keepers.*\]] into the allowlist registry. An absent
    [\[egress\]] section yields an empty registry, which is not permission:
    a keeper in the policy lane with no entry reaches nothing. *)
let parse_egress_allowlists (toml : Otoml.t)
  : (Egress_allowlist.t list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ Ns.(key Egress) ] with
  | None -> Ok []
  | Some egress_value ->
    (match exec_single_child ~path:(Ns.(key Egress)) ~child_key:"keepers" egress_value with
     | Error _ as error -> error
     | Ok None -> Ok []
     | Ok (Some keepers_value) ->
       (match keepers_value with
        | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
          partition_results (List.map (fun (name, tbl) -> parse_egress_keeper ~name tbl) entries)
        | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
        | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
        | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error (error (Ns.(path Egress) "keepers") "expected a table")))
;;

let parse_exec_endpoints (toml : Otoml.t)
  : (Exec_ssh_endpoint.t list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ Ns.(key Exec) ] with
  | None -> Ok []
  | Some exec_value ->
    (match exec_single_child ~path:(Ns.(key Exec)) ~child_key:"ssh" exec_value with
     | Error _ as error -> error
     | Ok None -> Ok []
     | Ok (Some ssh_value) ->
       (match exec_single_child ~path:(Ns.(key Exec) ^ ".ssh") ~child_key:"endpoints" ssh_value with
        | Error _ as error -> error
        | Ok None -> Ok []
        | Ok (Some endpoints_value) ->
          (match endpoints_value with
           | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
             partition_results
               (List.map
                  (fun (name, tbl) ->
                     match
                       validate_runtime_id_component
                         ~allow_dot:false
                         ~kind:"exec ssh endpoint"
                         ~path:(Ns.(path Exec) ("ssh.endpoints." ^ name))
                         name
                     with
                     | Error _ as error -> error
                     | Ok () -> parse_exec_ssh_endpoint ~name tbl)
                  entries)
           | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
           | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
           | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
           | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
             Error
               (error
                  (Ns.(path Exec) "ssh.endpoints")
                  "[exec.ssh.endpoints] must be a TOML table of endpoint tables"))))
;;

(* [lsp.servers]: the command that starts a language's server, keyed by the
   language's wire id. It replaces the client's table for that language and
   no other. A key that names no language and a value that is not a
   non-empty array of strings are refused at load: a server nobody can
   start is a typo, not a preference. *)
let parse_lsp_server ~(lang_id : string) (value : Otoml.t)
  : (string * (string * string list), parse_error list) result
  =
  let path = Ns.(path Lsp) ("servers." ^ lang_id) in
  match Lsp_process_manager.language_of_lang_id lang_id with
  | None ->
    Error
      (error
         path
         (Printf.sprintf
            "unknown language %S; expected one of %s"
            lang_id
            (String.concat
               ", "
               (List.map
                  Lsp_process_manager.lang_id_of_language
                  Lsp_process_manager.all_languages))))
  | Some _ ->
    (match value with
     | Otoml.TomlArray items ->
       let words =
         List.map
           (function
             | Otoml.TomlString word -> Some word
             | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
             | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
             | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
             | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> None)
           items
       in
       (match List.filter_map Fun.id words with
        | (executable :: _ as argv) when List.for_all Option.is_some words ->
          Ok (lang_id, (executable, argv))
        | _ ->
          Error
            (error
               path
               "expected a non-empty array of strings: the executable, then its arguments"))
     | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
     | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
     | Otoml.TomlLocalTime _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> Error
         (error path "expected an array of strings: the executable, then its arguments"))
;;

let parse_lsp_servers (toml : Otoml.t)
  : ((string * (string * string list)) list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ Ns.(key Lsp) ] with
  | None -> Ok []
  | Some lsp_value ->
    (match exec_single_child ~path:(Ns.(key Lsp)) ~child_key:"servers" lsp_value with
     | Error _ as error -> error
     | Ok None -> Ok []
     | Ok (Some servers_value) ->
       (match servers_value with
        | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
          partition_results
            (List.map (fun (lang_id, value) -> parse_lsp_server ~lang_id value) entries)
        | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
        | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
        | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error (error (Ns.(path Lsp) "servers") "expected a table of language = [\"command\", ...]")))
;;
