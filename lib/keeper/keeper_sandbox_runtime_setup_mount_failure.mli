val find_char_from : string -> Char.t -> int -> int option
val max_docker_mount_path_log_len : int
val docker_mount_failure_looks_daemon_originated : string -> bool
val extract_quoted_value_after : string -> string -> string option
val docker_mount_failure_path : string -> string option
val docker_output_mentions_mount_failure : string -> bool
val docker_failure_output_for_log : string -> string
val optional_context_field : string -> string option -> string list
val docker_mount_failure_context_suffix :
  ?base_path_hash:string ->
  ?keeper_name:string ->
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string -> ?network_label:string -> string -> string
val optional_json_string_field :
  'a -> string option -> ('a * [> `String of string ]) list
val docker_mount_failure_details :
  ?image:string ->
  ?status_label:string ->
  ?container_kind:string ->
  ?network_label:string ->
  base_path_hash:string ->
  keeper_name:string ->
  output:string ->
  unit -> [> `Assoc of (string * [> `String of string ]) list ] option
