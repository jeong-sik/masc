let secret_root ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat base_path ".masc") "secrets")
    keeper_name
;;

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some index -> String.sub entry 0 index
;;

let read_trimmed path =
  if not (Sys.file_exists path)
  then None
  else
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Some (String.trim (In_channel.input_all channel)))
;;

let local_env_for_keeper ?host_env ~base_path ~keeper_name () =
  let env = Option.value ~default:(Unix.environment ()) host_env in
  let token_path =
    Filename.concat (Filename.concat (secret_root ~base_path ~keeper_name) "env") "GH_TOKEN"
  in
  match read_trimmed token_path with
  | None -> Ok (Some env)
  | Some token ->
    let without_token =
      Array.to_list env
      |> List.filter (fun entry -> not (String.equal (env_key entry) "GH_TOKEN"))
      |> Array.of_list
    in
    Ok (Some (Array.append [| "GH_TOKEN=" ^ token |] without_token))
;;
