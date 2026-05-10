open Keeper_types
open Keeper_exec_shared

(* Issue #8490: Variant SSOT for fs write mode. Adding a constructor
   forces compilation in [fs_write_mode_to_string] and
   [fs_write_mode_dispatch] AND extends [valid_fs_write_mode_strings];
   the schema in [tool_shard.ml] mirrors the SSOT (cycle avoidance
   per #8480/#8484 pattern). The previous code used 5 hardcoded sites
   (parse default, validate, dispatch, label normalisation, schema)
   with an empty-string-as-overwrite back-compat — now expressed
   explicitly via [Option.value ~default:Overwrite]. *)
type fs_write_mode =
  | Overwrite
  | Append
  | Patch
    (** RFC-0006 Phase A.4: read-replace-write for the Anthropic Code
        [Edit] cognate. Caller supplies [old_string] + [new_string]
        (and optional [replace_all]) instead of [content]. *)

let fs_write_mode_to_string = function
  | Overwrite -> "overwrite"
  | Append -> "append"
  | Patch -> "patch"

(* Sound partial parser: canonical strings AND the back-compat empty
   string both decode to a real Variant. Whitespace-only treated as
   empty for the same back-compat reason. Anything else returns None
   so the caller decides the rejection message. *)
let fs_write_mode_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "overwrite" | "" -> Some Overwrite
  | "append" -> Some Append
  | "patch" -> Some Patch
  | _ -> None

let all_fs_write_modes = [ Overwrite; Append; Patch ]

let valid_fs_write_mode_strings =
  List.map fs_write_mode_to_string all_fs_write_modes

(** keeper_fs_read max_bytes clamp. [fs_read_default_max_bytes] is the
    canonical default; [Tool_shard_limits.keeper_fs_read_default_max_bytes]
    re-exports it at a leaf module so the tool schema in tool_shard.ml
    can reference the same value without creating a dependency cycle. *)
let fs_read_default_max_bytes = Tool_shard_limits.keeper_fs_read_default_max_bytes
let fs_read_min_max_bytes = 512
let fs_read_max_max_bytes = 200_000

(** Issue #10349 Phase 2: registry-canonical meta lookup.
    Eliminates identity drift by refusing to accept an externally-injected
    [keeper_meta]; the resolver asks the registry for the SSOT entry.
    A mismatch or missing entry increments the drift counter and surfaces
    a hard error so the caller cannot proceed with a stale/wrong identity. *)
let with_registry_meta ~(keeper_name : string) f =
  match Keeper_registry.find_by_name keeper_name with
  | None ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
      ~labels:[ "source_layer", "fs_resolver"; "field", "registry_missing" ]
      ();
    error_json
      (Printf.sprintf "keeper not found in registry: %s" keeper_name)
  | Some entry ->
    if not (String.equal entry.meta.name keeper_name) then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_path_resolver_identity_mismatch
        ~labels:[ "source_layer", "fs_resolver"; "field", "name_mismatch" ]
        ();
    f entry.meta
;;

let handle_keeper_fs_read
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name @@ fun meta ->
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:fs_read_default_max_bytes "max_bytes" args
    |> fun n -> max fs_read_min_max_bytes (min fs_read_max_max_bytes n)
  in
  let fallback_dir = keeper_default_read_root ~config ~meta in
  match playground_relative_unless_allowed_root ~config ~meta path with
  | Error e -> error_json e
  | Ok normalized ->
    match Keeper_alerting_path.resolve_keeper_read_path
      ~config
      ~allowed_paths:(keeper_effective_allowed_paths ~meta)
      ~raw_path:normalized
    with
    | Error (Not_found_relative { raw }) ->
      (* Path within root but doesn't exist — use structured error with suggestions *)
      let root = Keeper_alerting_path.project_root_of_config config in
      let target =
        if Filename.is_relative path then Filename.concat root path else path
      in
      missing_file_error_json ~config ~target ~fallback_dir
        ~error:(Keeper_alerting_path.rejection_to_user_message (Not_found_relative { raw }))
    | Error rej -> error_json (Keeper_alerting_path.rejection_to_user_message rej)
    | Ok target ->
    (* RFC-0006 Phase B-1: Docker keepers are always contained to their
       playground bundle on the host before any read-side I/O proceeds.
       The resolver-level allowed_paths check is augmented by this
       strict containment so host FS cannot leak through keeper_fs_read
       while keeper_bash is container-isolated. *)
    (match Keeper_sandbox_containment.check_read_target ~config ~meta ~target with
     | Error e -> error_json ~fields:[ "path", `String target ] e
     | Ok () ->
    (* Multi-repository Phase 2: repository-level access restriction.
       If the resolved path is under a registered repository, enforce
       keeper-to-repo mapping.  Paths outside all registered repos are
       allowed (playground general files). *)
    (match Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
       ~base_path:(Keeper_alerting_path.project_root_of_config config)
       ~path:target with
     | Error msg -> error_json ~fields:[ "path", `String target ] msg
     | Ok () ->
    (* RFC-0006 Phase B-2: Docker keepers route the actual byte read
       through [docker run --rm <image> cat <container_path>] so the
       container's mount restrictions are the load-bearing isolation.
       The host containment check above remains as defense-in-depth. *)
    if Keeper_docker_read.should_route_read ~meta then
      let timeout_sec = Env_config_exec_timeout.timeout_sec ~caller:Fs () in
      match
        Keeper_docker_read.read_file_in_container ?turn_sandbox_factory ~config ~meta
          ~host_path:target ~max_bytes ~timeout_sec ()
      with
      | Error msg ->
        error_json ~fields:[ "path", `String target ] msg
      | Ok body ->
        let total = String.length body in
        let truncated = total >= max_bytes in
        Yojson.Safe.to_string
          (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "bytes", `Int total
             ; "truncated", `Bool truncated
             ; "content", `String body
             ; "via", `String "docker"
             ])
    else
    (match Safe_ops.read_file_safe target with
     | Error e when String.starts_with ~prefix:file_not_found_prefix e ->
       missing_file_error_json ~config ~target ~fallback_dir ~error:e
     | Error e -> error_json ~fields:[ "path", `String target ] e
     | Ok content ->
        let total = String.length content in
        let truncated = total > max_bytes in
        let body = if truncated then String.sub content 0 max_bytes else content in
        Yojson.Safe.to_string
          (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "bytes", `Int total
             ; "truncated", `Bool truncated
             ; "content", `String body
             ]))))
;;

(* RFC-0006 Phase A.4: replace [old] with [new] in [text]. When
   [replace_all=false], requires exactly one occurrence so accidental
   multi-edits are rejected (mirrors Anthropic Edit semantics). *)
let apply_patch ~old_string ~new_string ~replace_all text =
  if old_string = "" then
    Error "old_string must be non-empty for mode=patch."
  else
    let count_occurrences ~needle haystack =
      let nlen = String.length needle in
      if nlen = 0 then 0
      else
        let hlen = String.length haystack in
        let rec loop i acc =
          if i + nlen > hlen then acc
          else if String.sub haystack i nlen = needle then
            loop (i + nlen) (acc + 1)
          else loop (i + 1) acc
        in
        loop 0 0
    in
    let occurrences = count_occurrences ~needle:old_string text in
    if occurrences = 0 then
      Error "old_string not found in file. Patch did not match anything."
    else if (not replace_all) && occurrences > 1 then
      Error
        (Printf.sprintf
           "old_string occurs %d times. Pass replace_all=true to apply to all, \
            or supply a more specific old_string."
           occurrences)
    else
      let buf = Buffer.create (String.length text) in
      let nlen = String.length old_string in
      let hlen = String.length text in
      let rec loop i =
        if i + nlen > hlen then Buffer.add_substring buf text i (hlen - i)
        else if String.sub text i nlen = old_string then begin
          Buffer.add_string buf new_string;
          if replace_all then loop (i + nlen)
          else Buffer.add_substring buf text (i + nlen) (hlen - i - nlen)
        end
        else begin
          Buffer.add_char buf text.[i];
          loop (i + 1)
        end
      in
      loop 0;
      Ok (Buffer.contents buf, occurrences)

exception Fs_edit_error of string

let raise_fs_edit_error ?fields message =
  raise (Fs_edit_error (error_json ?fields message))

let validate_write_target ~config ~meta ~target =
  match
    Keeper_sandbox_containment.check_write_target ~config ~meta ~target
  with
  | Ok () -> Ok ()
  | Error e -> Error (error_json ~fields:[ "path", `String target ] e)

let handle_keeper_fs_edit
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
      ~(keeper_name : string)
      ~(args : Yojson.Safe.t)
  =
  with_registry_meta ~keeper_name @@ fun meta ->
  let via_field =
    match turn_sandbox_factory with
    | Some _ -> [ ("via", `String "docker") ]
    | None -> []
  in
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let mode_raw =
    Safe_ops.json_string ~default:"overwrite" "mode" args
  in
  let mode_opt = fs_write_mode_of_string_opt mode_raw in
  (* Early validation: path is required for every mode. *)
  if String.trim path = "" then
    error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''."
  else match mode_opt with
  | None ->
    error_json (Printf.sprintf
      "mode must be one of [%s], got %S."
      (String.concat ", " valid_fs_write_mode_strings) mode_raw)
  | Some Patch ->
    let old_string = Safe_ops.json_string ~default:"" "old_string" args in
    let new_string = Safe_ops.json_string ~default:"" "new_string" args in
    let replace_all = Safe_ops.json_bool ~default:false "replace_all" args in
    if old_string = "" then
      error_json
        "mode=patch requires non-empty old_string. Good: \
         old_string='let x = 1'."
    else
      (match resolve_keeper_path ~config ~meta ~raw_path:path with
       | Error e -> error_json e
       | Ok target ->
         (match validate_write_target ~config ~meta ~target with
          | Error json -> json
          | Ok () ->
         (match Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
            ~base_path:(Keeper_alerting_path.project_root_of_config config)
            ~path:target with
          | Error msg -> error_json ~fields:[ "path", `String target ] msg
          | Ok () ->
         (try
            let current =
              try Fs_compat.load_file target
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | _ -> ""
            in
            if current = "" then
              error_json ~fields:[ "path", `String target ]
                "patch target file does not exist or is empty. Use \
                 mode=overwrite to create."
            else
              match
                apply_patch ~old_string ~new_string ~replace_all current
              with
              | Error msg ->
                error_json ~fields:[ "path", `String target ] msg
              | Ok (updated, occurrences) ->
                let write_result =
                  match
                    Keeper_sandbox_factory.resolve_opt
                      turn_sandbox_factory ~cwd:target
                  with
                  | Some runtime ->
                    Keeper_turn_sandbox_runtime.overwrite_file runtime
                      ~host_path:target ~content:updated
                      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Fs ()) ()
                  | None ->
                    Keeper_fs.save_atomic target updated
                in
                (match write_result with
                 | Error msg ->
                     raise_fs_edit_error ~fields:[ "path", `String target ] msg
                 | Ok () ->
                     Log.Keeper.info
                       "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=patch \
                        replace_all=%b occurrences=%d bytes=%d"
                       meta.name target replace_all occurrences
                       (String.length updated);
                     Yojson.Safe.to_string
                       (`Assoc
                           ([ "ok", `Bool true
                            ; "path", `String target
                            ; "mode", `String "patch"
                            ; "replace_all", `Bool replace_all
                            ; "occurrences", `Int occurrences
                            ; "bytes_written", `Int (String.length updated)
                            ]
                           @ via_field)))
          with
          | Fs_edit_error json -> json
          | Invalid_argument e ->
            error_json ~fields:[ "path", `String target ] e
          | Sys_error e -> error_json ~fields:[ "path", `String target ] e
          | Unix.Unix_error (err, _, _) ->
            error_json ~fields:[ "path", `String target ]
              (Unix.error_message err)))))
  | Some ((Overwrite | Append) as mode) ->
  let mode_label = fs_write_mode_to_string mode in
  if String.trim content = "" then
    error_json "content is required (non-empty). Writing 0 bytes is usually unintended."
  else
  match resolve_keeper_path ~config ~meta ~raw_path:path with
  | Error e -> error_json e
  | Ok target ->
    (match validate_write_target ~config ~meta ~target with
     | Error json -> json
     | Ok () ->
    (match Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
       ~base_path:(Keeper_alerting_path.project_root_of_config config)
       ~path:target with
     | Error msg -> error_json ~fields:[ "path", `String target ] msg
     | Ok () ->
    (try
       let write_result =
         match
           Keeper_sandbox_factory.resolve_opt
             turn_sandbox_factory ~cwd:target
         with
         | Some runtime ->
           (match mode with
            | Append ->
              Keeper_turn_sandbox_runtime.append_file runtime
                ~host_path:target ~content ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Fs ()) ()
            | Overwrite ->
              Keeper_turn_sandbox_runtime.overwrite_file runtime
                ~host_path:target ~content ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Fs ()) ()
            | Patch -> Ok ())
         | None ->
           (match mode with
            | Append ->
              let parent = Filename.dirname target in
              Fs_compat.mkdir_p parent;
              Fs_compat.append_file target content;
              Ok ()
            | Overwrite ->
              Keeper_fs.save_atomic target content
            | Patch -> Ok ())
       in
       match write_result with
       | Error msg ->
           raise_fs_edit_error ~fields:[ "path", `String target ] msg
       | Ok () ->
           Log.Keeper.info "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
             meta.name target mode_label
             (String.length content);
           Yojson.Safe.to_string
             (`Assoc
                 ([ "ok", `Bool true
                  ; "path", `String target
                  ; "mode", `String mode_label
                  ; "bytes_written", `Int (String.length content)
                  ]
                 @ via_field))
    with
    | Fs_edit_error json -> json
    | Invalid_argument e -> error_json ~fields:[ "path", `String target ] e
     | Sys_error e -> error_json ~fields:[ "path", `String target ] e
     | Unix.Unix_error (err, _, _) ->
       error_json ~fields:[ "path", `String target ] (Unix.error_message err))))
;;
