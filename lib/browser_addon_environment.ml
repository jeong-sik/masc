let operational_key = function
  | "PATH" | "HOME" | "TMPDIR" | "TMP" | "TEMP"
  | "USER" | "LOGNAME" | "LANG" | "LC_ALL" | "LC_CTYPE" | "TZ"
  | "XDG_CONFIG_HOME" | "XDG_DATA_HOME" | "XDG_CACHE_HOME" | "XDG_RUNTIME_DIR"
  | "DISPLAY" | "WAYLAND_DISPLAY" | "XAUTHORITY" | "DBUS_SESSION_BUS_ADDRESS"
  | "SSL_CERT_FILE" | "SSL_CERT_DIR" | "FONTCONFIG_FILE" | "FONTCONFIG_PATH" -> true
  | _ -> false

let project environment =
  Array.to_list environment
  |> List.filter (fun entry ->
    match String.index_opt entry '=' with
    | None -> false
    | Some index -> operational_key (String.sub entry 0 index))
  |> Array.of_list
