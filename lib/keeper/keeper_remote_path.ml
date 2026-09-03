(** Bidirectional path translation for the remote execution lane.

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
      are never used by the remote lane.
    - Host control/telemetry, explicitly divergent: [keeper_sandbox_control].
      It reports and manages the local bookkeeping bundle; endpoint readiness
      and remote lifecycle belong to the preflight/bootstrap layer.

    Every current call site belongs to one of those categories. New remote I/O
    must use this module instead of adding another prefix rewrite.

    The endpoint is named by its [remote_root] alone: the OpenSSH registry
    entry and an Apple [container] guest's work volume both project to
    [<remote_root>/<keeper>], and nothing here depends on the transport. *)

let normalize_host path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes
;;

(* Remote-namespace strings must never be resolved against the host
   filesystem: realpath substitutes host symlinks and macOS firmlinks into
   them (on macOS, /home/x resolves to /System/Volumes/Data/home/x), and the
   substituted path is what the shim then fails to find on the endpoint. The
   endpoint owns real resolution — its cwd jail runs realpath there — so the
   host side only cleans dot segments lexically. *)
let normalize_remote path =
  Masc_exec.Path_scope.lexical_normalize_abs path
  |> Keeper_alerting_path.strip_trailing_slashes
;;

(* Keeper-relative logical path: same lexical discipline, without
   absolutizing. Leading [..] segments survive so escape detection below
   still sees them. *)
let normalize_logical path =
  let parts = String.split_on_char '/' path in
  let stack =
    List.fold_left
      (fun stack part ->
        match part, stack with
        | ("" | "."), _ -> stack
        | "..", top :: rest when top <> ".." -> rest
        | part, _ -> part :: stack)
      [] parts
  in
  String.concat "/" (List.rev stack)
;;

let safe_keeper keeper = Playground_paths.sanitize_keeper_name keeper

let host_root ~base_path ~keeper =
  Filename.concat base_path (Playground_paths.bundle_root (safe_keeper keeper))
  |> normalize_host
;;

let keeper_remote_root ~remote_root ~keeper =
  Filename.concat remote_root (safe_keeper keeper) |> normalize_remote
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

let host_to_remote ~base_path ~remote_root ~keeper path =
  let hroot = host_root ~base_path ~keeper in
  let rroot = keeper_remote_root ~remote_root ~keeper in
  if Filename.is_relative path
  then
    let logical = normalize_logical path in
    if String.equal logical ""
    then Ok rroot
    else if String.equal logical ".."
            || String.starts_with ~prefix:(".." ^ Filename.dir_sep) logical
    then
      Error
        (Printf.sprintf
           "remote_ssh_path_jail_violation: keeper-relative path %s escapes %s"
           path hroot)
    else Ok (Filename.concat rroot logical)
  else
    let remote_candidate = normalize_remote path in
    if at_or_below ~root:rroot remote_candidate
    then Ok remote_candidate
    else
      (* Not endpoint-namespace: read it as a host bookkeeping path, where
         resolving against the host filesystem is the correct comparison. *)
      let host_candidate = normalize_host path in
      if at_or_below ~root:hroot host_candidate
      then
        let suffix = suffix_below ~root:hroot host_candidate in
        if String.equal suffix "" then Ok rroot else Ok (Filename.concat rroot suffix)
      else
        Error
          (Printf.sprintf
             "remote_ssh_path_jail_violation: %s is outside keeper playground %s"
             path hroot)
;;

let remote_to_logical ~remote_root ~keeper path =
  let rroot = keeper_remote_root ~remote_root ~keeper in
  let normalized = normalize_remote path in
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

let rewrite_output ~base_path ~remote_root ~keeper text =
  replace_root
    ~remote:(keeper_remote_root ~remote_root ~keeper)
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

let stream ~base_path ~remote_root ~keeper ~emit =
  let remote = keeper_remote_root ~remote_root ~keeper in
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

(* Bytes that need no rewriting accumulate into one run and leave as one [emit],
   rather than one [emit] per byte. The emitted sequence is unchanged when
   concatenated; what changes is how many pieces it arrives in, and each piece
   downstream is an SSE frame, so a short line used to become as many frames as
   it had characters. *)
let flush_stream ~finish stream =
  let literal = Buffer.create 256 in
  let emit_literal () =
    if Buffer.length literal > 0
    then (
      stream.emit (Buffer.contents literal);
      Buffer.clear literal)
  in
  let rec loop () =
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
        emit_literal ();
        stream.previous <- Some stream.remote.[remote_len - 1];
        consume stream remote_len;
        stream.emit stream.host;
        loop ())
      else if (not finish) && pending_len <= remote_len
              && prefix_of ~prefix:stream.remote stream.pending
      then ()
      else (
        let c = stream.pending.[0] in
        stream.previous <- Some c;
        consume stream 1;
        Buffer.add_char literal c;
        loop ())
  in
  loop ();
  emit_literal ()
;;

let rewrite_stream_chunk stream chunk =
  stream.pending <- stream.pending ^ chunk;
  flush_stream ~finish:false stream
;;

let finish_stream stream = flush_stream ~finish:true stream
;;
