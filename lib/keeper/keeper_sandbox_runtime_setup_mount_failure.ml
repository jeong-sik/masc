let find_char_from s ch pos =
  let rec loop i =
    if i >= String.length s
    then None
    else if Char.equal s.[i] ch
    then Some i
    else loop (i + 1)
  in
  loop pos
;;

let max_docker_mount_path_log_len = 4096

let docker_mount_failure_looks_daemon_originated output =
  String_util.contains_substring output "error during container init"
  &&
  (String_util.contains_substring output "Error response from daemon"
   || String_util.contains_substring output "OCI runtime create failed"
   || String_util.contains_substring output "runc create failed")
;;

let extract_quoted_value_after output marker =
  match String_util.find_substring output marker with
  | None -> None
  | Some marker_at ->
    let quote_at = marker_at + String.length marker in
    if quote_at >= String.length output || not (Char.equal output.[quote_at] '"')
    then None
    else (
      let value_start = quote_at + 1 in
      let value_end =
        match find_char_from output '"' value_start with
        | Some i -> i
        | None -> String.length output
      in
      if value_end <= value_start
      then None
      else
        let value_len = value_end - value_start in
        let bounded_len = min value_len max_docker_mount_path_log_len in
        Some (String.sub output value_start bounded_len))
;;

let docker_mount_failure_path output =
  if not (docker_mount_failure_looks_daemon_originated output)
  then None
  else (
    match extract_quoted_value_after output "error mounting " with
    | Some _ as path -> path
    | None -> extract_quoted_value_after output "mount_path=")
;;

let docker_output_mentions_mount_failure output =
  Option.is_some (docker_mount_failure_path output)
;;

let docker_failure_output_for_log output =
  if docker_output_mentions_mount_failure output
  then Exec_policy.truncate_for_log ~max_len:4096 output
  else Exec_policy.truncate_for_log output
;;

let optional_context_field key = function
  | None -> []
  | Some value when String.trim value = "" -> []
  | Some value -> [ Printf.sprintf "%s=%S" key value ]
;;

let docker_mount_failure_context_suffix
      ?base_path_hash
      ?keeper_name
      ?image
      ?status_label
      ?container_kind
      ?network_label
      output
  =
  match docker_mount_failure_path output with
  | None -> ""
  | Some mount_path ->
    let fields =
      [ "docker_mount_failure=true"; Printf.sprintf "mount_path=%S" mount_path ]
      @ optional_context_field "base_path_hash" base_path_hash
      @ optional_context_field "keeper" keeper_name
      @ optional_context_field "image" image
      @ optional_context_field "status" status_label
      @ optional_context_field "container_kind" container_kind
      @ optional_context_field "network" network_label
    in
    " " ^ String.concat " " fields
;;

let optional_json_string_field key = function
  | None -> []
  | Some value when String.trim value = "" -> []
  | Some value -> [ key, `String value ]
;;

let docker_mount_failure_details
      ?image
      ?status_label
      ?container_kind
      ?network_label
      ~base_path_hash
      ~keeper_name
      ~output
      ()
  =
  match docker_mount_failure_path output with
  | None -> None
  | Some mount_path ->
    Some
      (`Assoc
        ([ "event", `String "keeper_docker_mount_failure"
         ; "mount_path", `String mount_path
         ; "base_path_hash", `String base_path_hash
         ; "keeper", `String keeper_name
         ; "output_excerpt", `String (docker_failure_output_for_log output)
         ]
         @ optional_json_string_field "image" image
         @ optional_json_string_field "status" status_label
         @ optional_json_string_field "container_kind" container_kind
         @ optional_json_string_field "network" network_label))
;;
