let () =
  let rec options instance directories = function
    | "--instance"::value::rest when Option.is_none instance -> options (Some value) directories rest
    | "--slot"::directory::rest -> options instance (directory::directories) rest
    | "--"::command::arguments ->
        (match instance with
         | Some instance_id -> Native_addon_lease.exec ~instance_id ~directories ~command ~arguments
         | None -> Error (Native_addon_lease.Invalid_claim "--instance is required"))
    | _ -> Error (Native_addon_lease.Invalid_claim "usage: masc-native-addon-launcher --instance ID --slot PRIVATE_DIR [--slot PRIVATE_DIR] -- COMMAND [ARG ...]") in
  match options None [] (List.tl (Array.to_list Sys.argv)) with
  | Ok () -> ()
  | Error error -> prerr_endline (Native_addon_lease.error_to_string error);exit 1
