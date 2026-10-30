type load_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Trigger_policy_invalid of { path : string; detail : string }

module type CONNECTOR = sig
  type policy

  val table : string
  val parse : string -> (policy, string) result
  val default : policy
end

module Make (C : CONNECTOR) = struct
  type load =
    | Runtime_toml_missing
    | Trigger_policy_missing
    | Trigger_policy_loaded of C.policy

  let load_from_toml ~path =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Runtime_toml_missing
    | exception Unix.Unix_error (code, _, _) ->
      Error (Runtime_toml_unreadable { path; detail = Unix.error_message code })
    | _ ->
      (match Safe_ops.read_file_safe path with
       | Error detail -> Error (Runtime_toml_unreadable { path; detail })
       | Ok content ->
         (match Otoml.Parser.from_string_result content with
          | Error detail -> Error (Runtime_toml_invalid { path; detail })
          | Ok toml ->
            (match
               Field_resolution.resolve_string toml [ C.table; "trigger_policy" ]
             with
             | Field_resolution.Missing -> Ok Trigger_policy_missing
             | Field_resolution.Type_mismatch { expected; message; _ } ->
               Error
                 (Trigger_policy_invalid
                    { path
                    ; detail = Printf.sprintf "expected %s: %s" expected message
                    })
             | Field_resolution.Present raw ->
               let raw = String.trim raw in
               if String.equal raw ""
               then Ok Trigger_policy_missing
               else
                 (match C.parse raw with
                  | Ok policy -> Ok (Trigger_policy_loaded policy)
                  | Error detail ->
                    Error (Trigger_policy_invalid { path; detail })))))
  ;;

  let resolve () =
    let resolution = Config_dir_resolver.resolve () in
    let toml_path =
      Filename.concat
        resolution.Config_dir_resolver.config_root.path
        Config_dir_resolver.runtime_toml_filename
    in
    match load_from_toml ~path:toml_path with
    | Error _ as error -> error
    | Ok (Trigger_policy_loaded policy) -> Ok policy
    | Ok (Runtime_toml_missing | Trigger_policy_missing) -> Ok C.default
  ;;
end
