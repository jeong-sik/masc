(** Bidirectional path translation for the SSH remote execution lane.

    [host_root_abs_of_meta] call-site classification (Task 7 audit):

    - Logical-path only, unchanged: [keeper_sandbox_repo_path],
      [keeper_turn_helpers], [keeper_agent_run], [keeper_sandbox] location
      bundles, and [keeper_tool_shared_runtime] input resolution. These values
      describe the keeper-visible bookkeeping namespace; they do not perform
      remote I/O.
    - Remote-proxied: [keeper_tool_execute_runtime],
      [keeper_sandbox_read_backend], [keeper_workspace_read_ops], and
      [keeper_tool_filesystem_runtime]. Commands and structured reads translate
      through this module before reaching the shim.
    - Docker-only, explicitly divergent: [keeper_sandbox_docker],
      [keeper_sandbox_docker_container_name], [keeper_sandbox_factory], and
      [keeper_turn_sandbox_runtime]. Their host roots are bind-mount inputs and
      are never used by [Remote_ssh].
    - Host control/telemetry, explicitly divergent: [keeper_sandbox_control].
      It reports and manages the local bookkeeping bundle; endpoint readiness
      and remote lifecycle belong to the SSH preflight/bootstrap layer.

    Every current call site belongs to one of those categories. New remote I/O
    must use this module instead of adding another prefix rewrite. *)

let normalize path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes
;;

let safe_keeper keeper = Playground_paths.sanitize_keeper_name keeper

let host_root ~base_path ~keeper =
  Filename.concat base_path (Playground_paths.bundle_root (safe_keeper keeper))
  |> normalize
;;

let remote_root ~(endpoint : Exec_ssh_endpoint.t) ~keeper =
  Filename.concat endpoint.remote_root (safe_keeper keeper) |> normalize
;;

let at_or_below ~root path =
  String.equal root path
  || String.starts_with ~prefix:(root ^ Filename.dir_sep) path
;;

let suffix_below ~root path =
  if String.equal root path
  then ""
  else
    String.sub path (String.length root + 1)
      (String.length path - String.length root - 1)
;;

let host_to_remote ~base_path ~(endpoint : Exec_ssh_endpoint.t) ~keeper path =
  let hroot = host_root ~base_path ~keeper in
  let rroot = remote_root ~endpoint ~keeper in
  if Filename.is_relative path
  then
    let logical =
      let normalized = normalize path in
      if String.starts_with ~prefix:("." ^ Filename.dir_sep) normalized
      then
        String.sub normalized 2 (String.length normalized - 2)
      else normalized
    in
    if String.equal logical "." || String.equal logical ""
    then Ok rroot
    else if String.equal logical ".."
            || String.starts_with ~prefix:(".." ^ Filename.dir_sep) logical
    then
      Error
        (Printf.sprintf
           "remote_ssh_path_jail_violation: keeper-relative path %s escapes %s"
           path hroot)
    else Ok (Filename.concat rroot logical |> normalize)
  else
    let path = normalize path in
    if at_or_below ~root:rroot path
    then Ok path
    else if at_or_below ~root:hroot path
    then
      let suffix = suffix_below ~root:hroot path in
      if String.equal suffix "" then Ok rroot else Ok (Filename.concat rroot suffix)
    else
      Error
        (Printf.sprintf
           "remote_ssh_path_jail_violation: %s is outside keeper playground %s"
           path hroot)
;;

let remote_to_logical ~(endpoint : Exec_ssh_endpoint.t) ~keeper path =
  let rroot = remote_root ~endpoint ~keeper in
  let normalized = normalize path in
  if String.equal normalized rroot
  then "."
  else if at_or_below ~root:rroot normalized
  then suffix_below ~root:rroot normalized
  else path
;;

let path_component_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
  | _ -> false
;;

let replace_root ~remote ~host text =
  let remote_len = String.length remote in
  let text_len = String.length text in
  let out = Buffer.create text_len in
  let rec loop offset =
    if offset >= text_len
    then ()
    else if offset + remote_len <= text_len
            && String.sub text offset remote_len = remote
            && (offset = 0 || not (path_component_char text.[offset - 1]))
            && (offset + remote_len = text_len
                || not (path_component_char text.[offset + remote_len]))
    then (
      Buffer.add_string out host;
      loop (offset + remote_len))
    else (
      Buffer.add_char out text.[offset];
      loop (offset + 1))
  in
  loop 0;
  Buffer.contents out
;;

let rewrite_output ~base_path ~(endpoint : Exec_ssh_endpoint.t) ~keeper text =
  replace_root
    ~remote:(remote_root ~endpoint ~keeper)
    ~host:(host_root ~base_path ~keeper)
    text
;;

type stream =
  { remote : string
  ; host : string
  ; emit : string -> unit
  ; mutable pending : string
  ; mutable previous : char option
  }

let stream ~base_path ~(endpoint : Exec_ssh_endpoint.t) ~keeper ~emit =
  let remote = remote_root ~endpoint ~keeper in
  { remote
  ; host = host_root ~base_path ~keeper
  ; emit
  ; pending = ""
  ; previous = None
  }
;;

let prefix_of ~prefix text =
  String.length text <= String.length prefix
  && String.sub prefix 0 (String.length text) = text
;;

let consume stream count =
  stream.pending <-
    String.sub stream.pending count (String.length stream.pending - count)
;;

let rec flush_stream ~finish stream =
  if stream.pending = ""
  then ()
  else
    let remote_len = String.length stream.remote in
    let pending_len = String.length stream.pending in
    let starts_remote =
      pending_len >= remote_len
      && String.sub stream.pending 0 remote_len = stream.remote
    in
    let before_boundary =
      match stream.previous with
      | None -> true
      | Some c -> not (path_component_char c)
    in
    let after_boundary =
      if pending_len > remote_len
      then not (path_component_char stream.pending.[remote_len])
      else finish && pending_len = remote_len
    in
    if starts_remote && before_boundary && after_boundary
    then (
      stream.previous <- Some stream.remote.[remote_len - 1];
      consume stream remote_len;
      stream.emit stream.host;
      flush_stream ~finish stream)
    else if (not finish) && pending_len <= remote_len
            && prefix_of ~prefix:stream.remote stream.pending
    then ()
    else (
      let c = stream.pending.[0] in
      stream.previous <- Some c;
      consume stream 1;
      stream.emit (String.make 1 c);
      flush_stream ~finish stream)
;;

let rewrite_stream_chunk stream chunk =
  stream.pending <- stream.pending ^ chunk;
  flush_stream ~finish:false stream
;;

let finish_stream stream = flush_stream ~finish:true stream
;;
