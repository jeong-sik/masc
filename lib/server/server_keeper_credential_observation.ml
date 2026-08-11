let default_timeout_sec = 5.0

let observe_with_runner ~run ~hostname =
  Gh_auth_status.observe ~run ~hostname
;;

let run_process ?timeout_sec ?env argv =
  try
    let _status, stdout, _stderr =
      Process_eio.run_argv_with_status_split
        ?timeout_sec
        ?env
        (Array.to_list argv)
    in
    (* gh can return a non-zero status for an account-level auth failure while
       still returning the JSON rows that decide the typed verdict. *)
    Ok stdout
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "gh auth status process failed: %s"
         (Printexc.to_string exn))
;;

let observe ?(timeout_sec = default_timeout_sec) ~base_path ~keeper_name ~hostname
      ()
  =
  let run =
    match
      Keeper_secret_projection.local_env_for_keeper
        ~base_path
        ~keeper_name
        ()
    with
    | Error detail ->
      fun _argv -> Error ("secret projection failed: " ^ detail)
    | Ok env ->
      fun argv -> run_process ~timeout_sec ?env argv
  in
  observe_with_runner ~run ~hostname
;;

let source_to_string = function
  | Gh_auth_status.Keyring -> "keyring"
  | Gh_auth_status.Environment name -> name
  | Gh_auth_status.Config_file path -> path
;;

let active_entry_for_host (parsed : Gh_auth_status.t) hostname =
  let hostname = String.lowercase_ascii (String.trim hostname) in
  match
    List.filter
      (fun (entry : Gh_auth_status.entry) ->
         entry.active && String.equal entry.host hostname)
      parsed.entries
  with
  | [ entry ] -> Some entry
  | [] | _ :: _ -> None
;;

let option_string_json = function
  | Some value -> `String value
  | None -> `Null
;;

let option_strings_json = function
  | Some values -> `List (List.map (fun value -> `String value) values)
  | None -> `Null
;;

let next_action verdict active_entry =
  match verdict with
  | Gh_auth_status.Authenticated -> "none"
  | Gh_auth_status.Unauthenticated -> "gh auth login"
  | Gh_auth_status.Unknown -> "inspect gh auth status"
  | Gh_auth_status.Shadowed ->
    (match active_entry with
     | Some { Gh_auth_status.source = Gh_auth_status.Environment name; _ } ->
       "unset " ^ name
     | Some _ | None -> "unset the projected GitHub token")
;;

let surface_json ~hostname ~probed_at parsed =
  let verdict = Gh_auth_status.verdict_for_host parsed ~hostname in
  let active_entry = active_entry_for_host parsed hostname in
  `Assoc
    [ "schema", `String "masc.credential_surface.v1"
    ; "host", `String (String.lowercase_ascii (String.trim hostname))
    ; "status", `String (Gh_auth_status.verdict_to_string verdict)
    ; ( "account"
      , option_string_json
          (Option.map
             (fun (entry : Gh_auth_status.entry) -> entry.account)
             active_entry
           |> Option.join) )
    ; ( "token_source"
      , option_string_json
          (Option.map
             (fun (entry : Gh_auth_status.entry) -> source_to_string entry.source)
             active_entry) )
    ; ( "scopes"
      , option_strings_json
          (Option.map
             (fun (entry : Gh_auth_status.entry) -> entry.scopes)
             active_entry
           |> Option.join) )
    ; "probed_at", `Float probed_at
    ; "next_action", `String (next_action verdict active_entry)
    ]
;;

module For_testing = struct
  let observe_with_runner = observe_with_runner
end
