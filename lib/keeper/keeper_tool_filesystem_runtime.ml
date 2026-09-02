open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Result.Syntax

(* The write mode is defined once in [Keeper_tool_write_mode], shared with the
   remote-lane handler; the names below keep this module's surface. *)
type fs_write_mode = Keeper_tool_write_mode.t =
  | Overwrite
  | Append
  | Patch

let fs_write_mode_to_string = Keeper_tool_write_mode.to_string
let valid_fs_write_mode_strings = Keeper_tool_write_mode.valid_strings

(** Read max_bytes clamp. [read_file_default_max_bytes] is the
    canonical default; [Tool_shard_limits.read_file_default_max_bytes]
    re-exports it at a leaf module so the tool schema in tool_shard.ml
    can reference the same value without creating a dependency cycle. *)
let read_file_default_max_bytes = Tool_shard_limits.read_file_default_max_bytes

let read_file_min_max_bytes = 512
let read_file_max_max_bytes = Tool_shard_limits.read_file_max_max_bytes

(** Read line window. The Read descriptor (agent.read_file) exposes
    [offset]/[limit] as LINE coordinates — the shape mainstream Read tools
    train models on: [offset] is the 1-based first line, [limit] caps
    returned lines. [max_bytes] stays a byte budget on the returned content.
    The descriptor used to translate [limit] straight into [max_bytes], so a
    model asking for 200 lines received max(512, 200) = 512 bytes with
    [truncated=true] and could never read past the file head — live keepers
    re-issued the byte-identical Read for 200+ calls inside a single turn.
    [next_offset] in the payload is what makes forward progress expressible. *)
type read_line_window =
  { start_line : int (* 1-based first line to return *)
  ; max_lines : int option (* cap on returned lines; None = to EOF *)
  }

(* A window that starts at line 1 can only ever return bytes from the first
   [max_bytes] of the file (the response is byte-budgeted), so its fetch stays
   at [max_bytes]; only a window that starts deeper needs to scan further to
   locate its lines. *)
let read_window_fetch_bytes ~max_bytes = function
  | { start_line = 1; max_lines = _ } -> max_bytes
  | _ -> read_file_max_max_bytes
;;

(* Range violations are rejected loudly instead of being defaulted: a model
   that sent [limit=0] or [offset=-3] gets a payload naming the contract, so
   the next attempt can self-correct. *)
let read_line_window_of_args args =
  match Safe_ops.json_int_opt "offset" args, Safe_ops.json_int_opt "limit" args with
  | Some offset, _ when offset < 1 ->
    Error
      (Printf.sprintf
         "offset must be a 1-based line number (got %d). Read returns lines; \
          use next_offset from the previous response to continue."
         offset)
  | _, Some limit when limit < 1 ->
    Error
      (Printf.sprintf
         "limit must be a positive number of lines (got %d). Omit limit to \
          read up to the byte budget."
         limit)
  | offset, max_lines ->
    (* DET-OK: absent offset = the schema-declared default (line 1); range
       violations are rejected above — documented-default resolution. *)
    Ok { start_line = Option.value ~default:1 offset; max_lines }
;;

type read_window_slice =
  { window_content : string
  ; returned_lines : int
  ; next_offset : int option (* set iff content remains past the window *)
  ; window_truncated : bool
  ; last_line_partial : bool
    (* the byte budget cut inside the final returned line; [next_offset]
       already points past that line so retrying cannot loop on it *)
  }

(* Byte index where 1-based [line] starts in [content], or None when the
   scanned content ends before that line begins. *)
let rec line_start_index content len idx line =
  if line <= 1
  then Some idx
  else if idx >= len
  then None
  else (
    match String.index_from_opt content idx '\n' with
    | None -> None
    | Some nl -> line_start_index content len (nl + 1) (line - 1))
;;

let count_returned_lines capped =
  let len = String.length capped in
  if len = 0
  then 0
  else (
    let newlines = String.fold_left (fun n c -> if c = '\n' then n + 1 else n) 0 capped in
    if capped.[len - 1] = '\n' then newlines else newlines + 1)
;;

(* [scan_complete=false] means [content] is a byte-budgeted prefix of the
   file (sandbox fetch cut), so exhausting [content] does not prove EOF and
   line numbers past the scan horizon cannot be mapped. *)
let slice_read_window ~(window : read_line_window) ~max_bytes ~scan_complete content =
  let len = String.length content in
  match line_start_index content len 0 window.start_line with
  | None ->
    if scan_complete
    then
      Ok
        { window_content = ""
        ; returned_lines = 0
        ; next_offset = None
        ; window_truncated = false
        ; last_line_partial = false
        }
    else Error `Offset_beyond_scan
  | Some start ->
    let stop =
      match window.max_lines with
      | None -> len
      | Some lines ->
        let rec advance idx remaining =
          if remaining = 0 || idx >= len
          then idx
          else (
            match String.index_from_opt content idx '\n' with
            | None -> len
            | Some nl -> advance (nl + 1) (remaining - 1))
        in
        advance start lines
    in
    let raw = String.sub content start (stop - start) in
    let capped, last_line_partial =
      if String.length raw <= max_bytes
      then raw, false
      else (
        match String.rindex_from_opt raw (max_bytes - 1) '\n' with
        | Some nl -> String.sub raw 0 (nl + 1), false
        | None -> String.sub raw 0 max_bytes, true)
    in
    let returned_lines = count_returned_lines capped in
    let consumed_to = start + String.length capped in
    let more_in_scan = consumed_to < len in
    let more_beyond_scan = (not scan_complete) && consumed_to >= len in
    let window_truncated = more_in_scan || more_beyond_scan || last_line_partial in
    let next_offset =
      if window_truncated then Some (window.start_line + returned_lines) else None
    in
    Ok
      { window_content = capped
      ; returned_lines
      ; next_offset
      ; window_truncated
      ; last_line_partial
      }
;;

type read_file_resolution_error = Read_path_error of string

let string_opt_nonempty name json =
  match Safe_ops.json_string_opt name json with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
;;

(* The rejection names the cwds that would have worked.
   A keeper that guesses the host layout ("workspace/<org>/<repo>") gets the
   same "directory does not exist" as one that asked for a repo nobody
   materialized, and the two need opposite responses: retry with the right
   path, or stop asking. A live Keeper hit the first and kept retrying
   (#23442). The set is measured, not prescribed: whatever git checkouts sit
   under the keeper's workspace root, wherever the keeper put them. An empty
   set is reported as empty rather than omitted, because "no repository is
   materialized" is the answer to a different question than "you named the
   wrong one" — and by the same argument a scan that failed is a third answer
   and says so. *)
let available_cwd_hint ~config ~meta =
  let root = keeper_playground_root ~config ~meta in
  match Keeper_playground_checkouts.discover ~root with
  | Ok (Keeper_playground_checkouts.Complete []) ->
    " no repository is materialized for this keeper yet, so the workspace root \
     is the only cwd that exists"
  | Ok (Keeper_playground_checkouts.Complete checkouts) ->
    Printf.sprintf
      " available cwds: %s"
      (String.concat
         ", "
         (List.map
            (fun (c : Keeper_playground_checkouts.checkout) -> c.relative_path)
            checkouts))
  | Ok (Keeper_playground_checkouts.Partial { found; limit }) ->
    (* Presenting a truncated list as complete is worse than saying it is
       truncated: a keeper that cannot find its repo in a list that looks
       exhaustive concludes it should stop asking. *)
    Printf.sprintf
      " available cwds (partial, %s): %s"
      (Keeper_playground_checkouts.limit_to_string limit)
      (String.concat
         ", "
         (List.map
            (fun (c : Keeper_playground_checkouts.checkout) -> c.relative_path)
            found))
  | Error error ->
    Printf.sprintf
      " workspace checkout scan failed (%s); cwds could not be enumerated"
      (Keeper_playground_checkouts.scan_error_to_string error)
;;

let resolve_read_file_cwd ~(config : Workspace.config) ~(meta : keeper_meta) ~cwd =
  match cwd with
  | None -> Ok (keeper_default_read_root ~config ~meta)
  | Some raw_cwd ->
    (* File tools keep the logical projection for cwd: a keeper-visible
       relative cwd ("repos/<repo>") composed with a relative file_path is
       established Read vocabulary (test_keeper_visible_path_projection).
       Execute/search cwd goes through the strict no-projection resolvers
       instead (keeper_tool_execute_path). *)
    let* cwd = resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd in
    if safe_is_dir cwd
    then Ok cwd
    else if safe_file_exists cwd
    then Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)
    else
      Error
        (Printf.sprintf
           "cwd_not_directory: %s (directory does not exist; Read will not create \
            cwd);%s"
           cwd
           (available_cwd_hint ~config ~meta))
;;

let resolve_read_file_target
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~(raw_path : string)
  =
  let cwd = string_opt_nonempty "cwd" args in
  let raw_path = String.trim raw_path in
  if raw_path = ""
  then
    Error
      (Read_path_error
         (Keeper_alerting_path.rejection_to_user_message Keeper_alerting_path.Path_required))
  else
    let* cwd_abs =
      resolve_read_file_cwd ~config ~meta ~cwd
      |> Result.map_error (fun e -> Read_path_error e)
    in
    let candidate =
      if Filename.is_relative raw_path then Filename.concat cwd_abs raw_path else raw_path
    in
    resolve_projected_keeper_read_path
      ~config
      ~meta
      ~raw_for_error:raw_path
      ~projected_path:candidate
    |> Result.map_error (fun error -> Read_path_error error)
;;

type read_file_attempt =
  | Read_succeeded of string
  | Read_failed_payload of string
  | Read_failed_message of string

let handle_read_file_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:read_file_default_max_bytes "max_bytes" args
    |> fun n -> max read_file_min_max_bytes (min read_file_max_max_bytes n)
  in
  let cwd = string_opt_nonempty "cwd" args in
  match read_line_window_of_args args, resolve_read_file_target ~config ~meta ~args ~raw_path:path with
  | Error window_error, _ -> Keeper_tool_execution.failure (error_json window_error)
  | Ok _, Error (Read_path_error e) -> Keeper_tool_execution.failure (error_json e)
  | Ok window, Ok target ->
    let payload_of_slice ~via ~file_bytes ~scan_complete body =
      match slice_read_window ~window ~max_bytes ~scan_complete body with
      | Error `Offset_beyond_scan ->
        Read_failed_payload
          (error_json
             ~fields:
               [ "path", `String target
               ; "offset", `Int window.start_line
               ]
             (Printf.sprintf
                "offset %d is beyond the scanned window (%d bytes; the file \
                 continues past the scan budget). Read line ranges within the \
                 first %d bytes, or narrow the file another way (e.g. Grep)."
                window.start_line
                (String.length body)
                read_file_max_max_bytes))
      | Ok slice ->
        let optional_fields =
          List.concat
            [ (match slice.next_offset with
               | Some next -> [ "next_offset", `Int next ]
               | None -> [])
            ; (if slice.last_line_partial
               then [ "last_line_partial", `Bool true ]
               else [])
            ; (match file_bytes with
               | Some total -> [ "file_bytes", `Int total ]
               | None -> [])
            ; (match via with
               | Some via -> [ "via", `String via ]
               | None -> [])
            ]
        in
        Read_succeeded
          (Yojson.Safe.to_string
             (`Assoc
                 ([ "ok", `Bool true
                  ; "path", `String target
                  ; "bytes", `Int (String.length slice.window_content)
                  ; "truncated", `Bool slice.window_truncated
                  ; "offset", `Int window.start_line
                  ; "returned_lines", `Int slice.returned_lines
                  ; "content", `String slice.window_content
                  ]
                  @ optional_fields)))
    in
    let run_read () =
         (* RFC-0006 Phase B-1: Docker keepers are always contained to their
            playground bundle on the host before any read-side I/O proceeds.
            The resolver-level sandbox_roots check is augmented by this
            strict containment so host FS cannot leak through Read
            while Execute is container-isolated. *)
         let* () = Keeper_sandbox_containment.check_read_target ~config ~meta ~target in
         (* RFC-0006 Phase B-2: sandbox-backed keepers route the actual
            byte read through the backend read runner so the backend mount
            restrictions are the load-bearing isolation. The host containment
            check above remains as defense-in-depth. *)
         if Keeper_sandbox_read_runner.should_route_read ~meta
         then (
           let timeout_sec =
             Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ()
           in
           let fetch_bytes = read_window_fetch_bytes ~max_bytes window in
           let+ body =
             Keeper_sandbox_read_runner.read_file
               ?turn_sandbox_factory
               ~config
               ~meta
               ~host_path:target
               ~max_bytes:fetch_bytes
               ~timeout_sec
               ()
           in
           let scan_complete = String.length body < fetch_bytes in
           payload_of_slice
             ~via:(Some Keeper_sandbox_read_runner.backend_via)
             ~file_bytes:None
             ~scan_complete
             body)
         else (
           match Safe_ops.read_file_result target with
           | Error (Safe_ops.File_not_found _ as err) ->
             Ok
               (Read_failed_payload
                  (missing_file_error_json
                     ~cwd
                     ~raw_path:(Some path)
                     ~target
                     ~error:(Safe_ops.read_file_error_to_string err)))
           | Error err ->
             Ok (Read_failed_message (Safe_ops.read_file_error_to_string err))
           | Ok content ->
             Ok
               (payload_of_slice
                  ~via:None
                  ~file_bytes:(Some (String.length content))
                  ~scan_complete:true
                  content))
    in
    (match run_read () with
     | Ok (Read_succeeded json) -> Keeper_tool_execution.success json
     | Ok (Read_failed_payload payload) -> Keeper_tool_execution.failure payload
     | Ok (Read_failed_message msg) ->
       Keeper_tool_execution.failure
         (error_json ~fields:[ "path", `String target ] msg)
     | Error msg ->
       Keeper_tool_execution.failure
         (error_json ~fields:[ "path", `String target ] msg))
;;

(** Resolve a [path] when the tool caller omits [cwd]. The verifier
    tool_read_file path is supposed to be repository-relative, and
    most live tool calls in this codebase are produced by a
    Repository actor whose checkout lives at
    [<ownership_root>/<repo>/] (single well) or
    [<ownership_root>/<group>/<repo>/] (two-level well, e.g. the
    "repos/<repo>/" playground layout from issue #28950). The
    helper honours both layouts without guessing when the
    playground holds more than one.

    The returned pair is (cwd_abs, target_path) so the caller can
    apply the same [Filename.concat cwd_abs target_path] regardless
    of whether [path] already names the sub-repo as its first
    segment — the helper strips the redundant prefix when it
    descends.

    Descent rules (monotone: a deeper descent is taken only when
    every level is uniquely named):
    - 0 sub-dirs at depth-1: root itself is the repo, return
      [(ownership_root, path)].
    - 1 sub-dir at depth-1, 0 or several at depth-2: descend one
      level only. If the caller's [path] names the depth-1 sub-dir
      as its first segment, strip that prefix; otherwise return
      [(ownership_root, path)] (no guess when the first segment
      mismatches).
    - 1 sub-dir at depth-1 AND 1 sub-dir at depth-2: descend two
      levels. If the caller's [path] names "a/b" as its leading
      two segments, strip that leading two-segment prefix; if the
      path's first segment is "a" (single-level prefix) but not
      "a/b", strip "a" only and treat the rest as relative to the
      depth-1 dir — the caller named "a", so the reference stays
      literal instead of guessing "b"; otherwise (form A: bare
      repo-relative path like
      "lib/...") leave the path alone and treat it as relative to
      the depth-2 dir.
    - 2+ sub-dirs at depth-1: return [(ownership_root, path)]. A
      silent pick among them would be a lie.

    Returns [(ownership_root, path)] when:
    - the root cannot be read (no permission, race, ...);
    - the root itself is the repository (no sub-directory);
    - the root contains 2+ sub-directories at depth-1;
    - depth-2 is 2+ when depth-1 is 1;
    - the descent target exists but the path's first segment
      mismatches the depth-1 sub-dir name (single-level descent
      only — the helper does not guess which sub-dir).

    Exposed for testing so [test_owned_read_cwd] can pin the
    contract directly. *)
let default_owned_target ~ownership_root ~path =
  let entries ~root =
    match Sys.readdir root with
    | e -> Array.to_list e
    | exception _ -> []
  in
  let subdirs_of ~root ~skip =
    List.filter
      (fun name ->
        let p = Filename.concat root name in
        match Sys.is_directory p with
        | true -> not (String.equal name skip)
        | _ -> false)
      (entries ~root)
  in
  let strip_prefix prefix p =
    let plen = String.length prefix in
    if String.length p >= plen + 1
       && String.sub p 0 plen = prefix
       && p.[plen] = '/'
    then String.sub p (plen + 1) (String.length p - plen - 1)
    else p
  in
  let strip_two_segment_prefix a b p =
    let prefix = a ^ "/" ^ b in
    strip_prefix prefix p
  in
  let first_segment p =
    let stripped =
      if Filename.is_relative p then p else Filename.basename p
    in
    let seg =
      match String.split_on_char '/' stripped with
      | "" :: rest -> rest
      | rest -> rest
    in
    match seg with
    | first :: _ when not (String.equal first "") -> Some first
    | _ -> None
  in
  match subdirs_of ~root:ownership_root ~skip:(Filename.basename ownership_root) with
  | [] -> (ownership_root, path)
  | _ :: _ :: _ -> (ownership_root, path)
  | [ a ] ->
    let depth1 = Filename.concat ownership_root a in
    (match subdirs_of ~root:depth1 ~skip:a with
     | [ b ] ->
       let depth2 = Filename.concat depth1 b in
       let stripped = strip_two_segment_prefix a b path in
       let first = first_segment path in
       (match stripped, first with
        | s, _ when s <> path -> (depth2, s)
        | _, Some first when String.equal first a -> (depth1, strip_prefix a path)
        | _ -> (depth2, path))
     | _ ->
       (match first_segment path with
        | Some first when String.equal first a -> (depth1, strip_prefix a path)
        | _ -> (ownership_root, path)))
[@@coverage off]

let handle_owned_read_file_with_outcome
      ~ownership_root
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  let max_bytes = read_file_default_max_bytes in
  let cwd = string_opt_nonempty "cwd" args in
  let resolve_target () =
    if String.equal path ""
    then Error "path is required"
    else
      let cwd_abs, target_rel =
        match cwd with
        | None -> default_owned_target ~ownership_root ~path
        | Some cwd ->
          if Filename.is_relative cwd
          then (Filename.concat ownership_root cwd, path)
          else (cwd, path)
      in
      match Fs_compat.inspect_owned_directory_chain ~ownership_root cwd_abs with
      | Error rejection ->
        Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
      | Ok Fs_compat.Owned_directory_missing ->
        Error
          (Printf.sprintf
             "cwd_not_directory: %s (directory does not exist)"
             cwd_abs)
      | Ok (Fs_compat.Owned_directory _) ->
        let target =
          if Filename.is_relative target_rel
          then Filename.concat cwd_abs target_rel
          else target_rel
        in
        Ok target
  in
  match read_line_window_of_args args, resolve_target () with
  | Error window_error, _ -> Keeper_tool_execution.failure (error_json window_error)
  | Ok _, Error detail -> Keeper_tool_execution.failure (error_json detail)
  | Ok window, Ok target ->
    let fetch_bytes = read_window_fetch_bytes ~max_bytes window in
    (match
       Fs_compat.load_owned_regular_file_prefix
         ~ownership_root
         ~max_bytes:fetch_bytes
         target
     with
     | Error error ->
       Keeper_tool_execution.failure
         (error_json
            ~fields:[ "path", `String target ]
            (Fs_compat.owned_regular_file_read_error_to_string error))
     | Ok None ->
       Keeper_tool_execution.failure
         (missing_file_error_json
            ~cwd
            ~raw_path:(Some path)
            ~target
            ~error:"owned file is missing")
     | Ok (Some prefix) ->
       (match
          slice_read_window
            ~window
            ~max_bytes
            ~scan_complete:(not prefix.truncated)
            prefix.content
        with
        | Error `Offset_beyond_scan ->
          Keeper_tool_execution.failure
            (error_json
               ~fields:
                 [ "path", `String target
                 ; "offset", `Int window.start_line
                 ]
               (Printf.sprintf
                  "offset %d is beyond the scanned window (%d bytes)"
                  window.start_line
                  (String.length prefix.content)))
        | Ok slice ->
          let optional_fields =
            List.concat
              [ (match slice.next_offset with
                 | Some next -> [ "next_offset", `Int next ]
                 | None -> [])
              ; (if slice.last_line_partial
                 then [ "last_line_partial", `Bool true ]
                 else [])
              ]
          in
          Keeper_tool_execution.success
            (Yojson.Safe.to_string
               (`Assoc
                   ([ "ok", `Bool true
                    ; "path", `String target
                    ; "bytes", `Int (String.length slice.window_content)
                    ; "file_bytes", `Int prefix.file_size
                    ; "truncated", `Bool slice.window_truncated
                    ; "offset", `Int window.start_line
                    ; "returned_lines", `Int slice.returned_lines
                    ; "content", `String slice.window_content
                    ]
                    @ optional_fields)))))
;;

(* RFC-0378 §5.1 — resolve a write's file path to its attribution.

   This is the system's only [Code_address] mint: it anchors the path,
   recovers the owning repository (sandbox playground parse or
   registered local_path prefix), lexically collapses dot segments, and
   constructs the address. Attribution failure is a typed fact kind
   carried on the record as [Unaddressed { reason; attempted_path }] —
   not an exception. Total: never raises.

   Keeper writes inside the sandbox playground never appear under a
   registered repo's [local_path] (the playground clone path is opaque
   to [repositories.toml]), so the SSOT
   {!Playground_paths.parse_playground_repo_path} recovers the
   [(repo_id, rel)] pair first and the repository URL is looked up by
   id. This makes the sandbox/working-tree join work without forcing
   the operator to register every playground clone path. *)
(* RFC-0378 §5.1 / #28968: a write inside a linked git worktree must
   fold to the same [Code_address] as the main-tree write, with the
   checkout root carried as the [checkout] projection metadata
   (RFC-0378 §9's proposed representation: the measured
   [--show-toplevel] value).

   RFC-keeper-workspace-root-only §3.2 owns the mechanism: git itself
   answers "which checkout holds this file" — no path convention is
   special-cased (that RFC's deletion list explicitly bans new
   [.worktrees] literals), so worktrees outside the [.worktrees/]
   convention fold too. The fold applies only when git's
   [--git-common-dir] for the file equals the matched repo root's
   [.git]: that is git's own statement that the checkout is a linked
   worktree of THIS repository. A nested foreign clone (its own
   [.git]), a submodule ([.git/modules/...]), or any git failure
   (not a repo, timeout) leaves today's attribution untouched.
   Repository identity always comes from the registered catalog URL,
   never the measured origin — playground clones use local-path
   origins that do not canonicalise. *)
type worktree_fold_decision =
  | Fold_to of string
  | No_fold

(* One bounded git subprocess per (file directory, matched root); the
   resolver sits on the path-bearing tool post-hook, so per-call
   subprocess cost would tax every file-touching turn. Checkout roots
   do not move while a directory exists, so entries never expire; a
   catalog change alters [matched_root] and thereby the key. *)
let worktree_fold_memo : (string * string, worktree_fold_decision) Hashtbl.t =
  Hashtbl.create 64

let worktree_fold_memo_mutex = Stdlib.Mutex.create ()

let measured_worktree_fold ~matched_root ~file_dir =
  let key = (file_dir, matched_root) in
  let cached =
    Stdlib.Mutex.protect worktree_fold_memo_mutex (fun () ->
        Hashtbl.find_opt worktree_fold_memo key)
  in
  match cached with
  | Some decision -> decision
  | None ->
    let decision =
      match Repo_git.checkout_identity ~local_path:file_dir with
      | Error _ -> No_fold
      | Ok { Repo_git.toplevel; git_common_dir } ->
        if String.equal toplevel matched_root
        then No_fold
        else if String.equal git_common_dir (Filename.concat matched_root ".git")
        then Fold_to toplevel
        else No_fold
    in
    Stdlib.Mutex.protect worktree_fold_memo_mutex (fun () ->
        Hashtbl.replace worktree_fold_memo key decision);
    decision

(* The parsers hand back [rel] as the literal remainder of [abs], so
   chopping that suffix recovers the matched repository's filesystem
   root. A non-literal remainder (never produced today) skips folding
   rather than guessing. *)
let fs_root_of_rel ~abs ~rel =
  let suffix = "/" ^ rel in
  if String.length abs > String.length suffix
     && String.ends_with ~suffix abs
  then Some (String.sub abs 0 (String.length abs - String.length suffix))
  else None

let rel_and_checkout ~abs ~rel =
  match fs_root_of_rel ~abs ~rel with
  | None -> rel, None
  | Some matched_root ->
    (match
       measured_worktree_fold ~matched_root ~file_dir:(Filename.dirname abs)
     with
     | No_fold -> rel, None
     | Fold_to checkout_root ->
       let prefix = checkout_root ^ "/" in
       if String.length abs > String.length prefix
          && String.starts_with ~prefix abs
       then
         ( String.sub abs (String.length prefix)
             (String.length abs - String.length prefix)
         , Some checkout_root )
       else rel, None)

let resolve_write_attribution ~base_dir ~file_path =
  let abs =
    if Filename.is_relative file_path
    then Filename.concat base_dir file_path
    else file_path
  in
  let unaddressed reason =
    Agent_observation.Unaddressed { reason; attempted_path = file_path }
  in
  (* Lexical dot-segment collapse. [None] when the path escapes the
     repo root — such a path does not name a file of the matched repo,
     so it fails attribution rather than being repaired. *)
  let normalize_rel rel =
    let rec go acc = function
      | [] -> Some (List.rev acc)
      | ("" | ".") :: rest -> go acc rest
      | ".." :: rest ->
        (match acc with
         | [] -> None
         | _ :: tl -> go tl rest)
      | seg :: rest -> go (seg :: acc) rest
    in
    match go [] (String.split_on_char '/' rel) with
    | None | Some [] -> None
    | Some segs -> Some (String.concat "/" segs)
  in
  let mint ~rel ~repo_url =
    let url = String.trim repo_url in
    if url = ""
    then unaddressed Agent_observation.Unattributed.Blank_remote_url
    else
      match Agent_observation.canonical_url_of_remote url with
      | None ->
        unaddressed (Agent_observation.Unattributed.Unparseable_remote_url url)
      | Some slug ->
        let rel, checkout = rel_and_checkout ~abs ~rel in
        (match normalize_rel rel with
         | None -> unaddressed Agent_observation.Unattributed.Unregistered_path
         | Some rel ->
           (match Agent_observation.Code_address.v ~codebase:slug ~path:rel with
            | Ok address -> Agent_observation.Addressed { address; checkout }
            | Error invalid ->
              unaddressed (Agent_observation.Unattributed.Unmintable invalid)))
  in
  match
    Playground_paths.parse_playground_repo_path ~base_path:base_dir ~abs_path:abs
  with
  | Some (repo_id, rel) ->
    (match Repo_store.find_url_by_id ~base_path:base_dir repo_id with
     | Ok (Some url) -> mint ~rel ~repo_url:url
     | Ok None ->
       unaddressed (Agent_observation.Unattributed.Unregistered_repo_id repo_id)
     | Error _ ->
       unaddressed Agent_observation.Unattributed.Repository_catalog_unavailable)
  | None ->
    (match Repo_store.find_repo_by_path_prefix ~base_path:base_dir abs with
     | Ok (Some (repo, rel)) -> mint ~rel ~repo_url:repo.url
     | Ok None -> unaddressed Agent_observation.Unattributed.Unregistered_path
     | Error _ ->
       unaddressed Agent_observation.Unattributed.Repository_catalog_unavailable)
;;

let created_file_permissions = 0o644
let created_directory_permissions = 0o755

let same_file_resource (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let replacement_file_permissions ~parent_dir ~leaf =
  let target = Eio.Path.(parent_dir / leaf) in
  try
    let resource = Eio.Path.stat ~follow:false target in
    match resource.kind with
    | `Symbolic_link -> Ok created_file_permissions
    | `Regular_file -> Ok resource.perm
    | (`Block_device
      | `Character_special
      | `Directory
      | `Fifo
      | `Socket
      | `Unknown) as kind ->
      Error
        (Fmt.str
           "filesystem atomic replacement target must be a regular file, symbolic link, or missing entry; found %a"
           Eio.File.Stat.pp_kind
           kind)
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok created_file_permissions
;;

let load_open_file file =
  Eio.Buf_read.parse_exn ~max_size:max_int Eio.Buf_read.take_all file
;;

type created_directory_commit =
  { component : string
  ; target_effect : created_directory_target_effect
  ; primary_failure : created_directory_failure option
  ; child_sync : created_directory_sync_outcome
  ; parent_sync : created_directory_sync_outcome
  }

and created_directory_target_effect =
  | Directory_unchanged
  | Directory_created_validated
  | Directory_created_requested_mode
  | Directory_state_unknown

and created_directory_stage =
  | Create_directory
  | Inspect_created_directory
  | Acquire_directory_capability
  | Validate_directory_capability
  | Apply_directory_permissions

and created_directory_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

and created_directory_failure_cause =
  | Directory_posix_descriptor_unavailable
  | Directory_unexpected_resource_kind of Eio.File.Stat.kind
  | Directory_resource_identity_changed
  | Directory_operation_failed of created_directory_operation_failure

and created_directory_failure =
  { stage : created_directory_stage
  ; cause : created_directory_failure_cause
  }

and created_directory_sync_outcome =
  | Directory_sync_not_attempted
  | Directory_sync_succeeded
  | Directory_sync_failed of Fs_compat.capability_directory_sync_error

type created_directory_dispatch_fault =
  { fault_stage : created_directory_stage
  ; fault_exception : exn
  }

let created_directory_dispatch_fault_key
      : created_directory_dispatch_fault Eio.Fiber.key
  =
  Eio.Fiber.create_key ()
;;

type append_target_effect =
  | Append_target_unchanged
  | Append_target_extended_complete
  | Append_target_extended_partial
  | Append_target_extended_detached
  | Append_target_state_unknown

type append_write_outcome = Fs_compat.capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : Fs_compat.capability_append_failure option
  ; sync_failure : Fs_compat.capability_append_operation_failure option
  ; target_binding : Fs_compat.capability_append_target_binding
  }

type content_write_error =
  | Content_write_capability of
      { error : Fs_compat.capability_write_error
      ; created_parents : created_directory_commit list
      }
  | Content_write_directory of
      { failed_commit : created_directory_commit
      ; created_parents : created_directory_commit list
      }
  | Content_write_append of append_write_outcome

type content_publication =
  | Recovery_independent of (unit -> (unit, content_write_error) result)
  | Recovery_guarded of
      (Fs_compat.Publication_recovery.t
       -> (unit, content_write_error) result)

let append_capability ~on_cancelled file content =
  let outcome =
    Eio.Cancel.protect (fun () ->
      Fs_compat.append_capability_observed file content)
  in
  (try Eio.Fiber.check () with
   | Eio.Cancel.Cancelled _ as cancellation ->
     on_cancelled outcome;
     raise cancellation);
  match outcome.write_failure, outcome.sync_failure, outcome.target_binding with
  | None, None, Fs_compat.Capability_append_target_verified -> Ok ()
  | ( None
    , None
    , Fs_compat.Capability_append_target_not_checked )
    when outcome.requested_bytes = 0 -> Ok ()
  | _ -> Error (Content_write_append outcome)
;;

let created_directory_operation stage f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      { stage
      ; cause = Directory_operation_failed { exception_; backtrace }
      }
;;

let sync_created_directory directory =
  match Fs_compat.sync_directory_capability directory with
  | Ok () -> Directory_sync_succeeded
  | Error error -> Directory_sync_failed error
;;

let create_and_commit_directory_component
      ~sw
      ~permissions
      ~parent_dir
      ~component
  =
  let dispatch_fault = Eio.Fiber.get created_directory_dispatch_fault_key in
  let run_directory_operation =
    match dispatch_fault with
    | None -> created_directory_operation
    | Some fault ->
      (fun stage f ->
         created_directory_operation stage (fun () ->
           if fault.fault_stage = stage then raise fault.fault_exception;
           f ()))
  in
  let unchanged primary_failure =
    ( None
    , { component
      ; target_effect = Directory_unchanged
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync = Directory_sync_not_attempted
      } )
  in
  let created_without_child ~target_effect primary_failure =
    let parent_sync = sync_created_directory parent_dir in
    ( None
    , { component
      ; target_effect
      ; primary_failure = Some primary_failure
      ; child_sync = Directory_sync_not_attempted
      ; parent_sync
      } )
  in
  let child = Eio.Path.(parent_dir / component) in
  match
    run_directory_operation Create_directory (fun () ->
      Eio.Path.mkdir ~perm:0o700 child)
  with
  | Error primary_failure -> unchanged primary_failure
  | Ok () ->
    (match
       run_directory_operation Inspect_created_directory (fun () ->
         Eio.Path.stat ~follow:false child)
     with
     | Error primary_failure ->
       created_without_child
         ~target_effect:Directory_state_unknown
         primary_failure
     | Ok created when created.kind <> `Directory ->
       created_without_child
         ~target_effect:Directory_state_unknown
         { stage = Inspect_created_directory
         ; cause = Directory_unexpected_resource_kind created.kind
         }
     | Ok created ->
       (match
          run_directory_operation Acquire_directory_capability (fun () ->
            Eio.Path.open_dir ~sw child)
        with
        | Error primary_failure ->
          created_without_child
            ~target_effect:Directory_state_unknown
            primary_failure
        | Ok child_dir ->
          let directory_file =
            run_directory_operation Acquire_directory_capability (fun () ->
              Eio.Path.open_in ~sw Eio.Path.(child_dir / "."))
          in
          let validation =
            match directory_file with
            | Error _ as error -> error
            | Ok directory_file ->
              (match
                 run_directory_operation
                   Validate_directory_capability
                   (fun () ->
                      Eio.Path.stat ~follow:false child, Eio.File.stat directory_file)
               with
               | Error _ as error -> error
               | Ok (lexical, opened)
              when lexical.kind <> `Directory || opened.kind <> `Directory ->
                 let kind =
                   if lexical.kind <> `Directory then lexical.kind else opened.kind
                 in
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_unexpected_resource_kind kind
                   }
               | Ok (lexical, opened)
              when not (same_file_resource created lexical)
                   || not (same_file_resource lexical opened) ->
                 Error
                   { stage = Validate_directory_capability
                   ; cause = Directory_resource_identity_changed
                   }
               | Ok _ -> Ok ())
          in
          (match validation with
           | Error primary_failure ->
             let parent_sync = sync_created_directory parent_dir in
             ( None
             , { component
               ; target_effect = Directory_state_unknown
               ; primary_failure = Some primary_failure
               ; child_sync = Directory_sync_not_attempted
               ; parent_sync
               } )
           | Ok () ->
             let permissions_result =
               match directory_file with
               | Error failure -> Error failure
               | Ok directory_file ->
                 (match Eio_unix.Resource.fd_opt directory_file with
               | None ->
                 Error
                   { stage = Apply_directory_permissions
                   ; cause = Directory_posix_descriptor_unavailable
                   }
               | Some fd ->
                 run_directory_operation Apply_directory_permissions (fun () ->
                   Eio_unix.run_in_systhread
                     ~label:"keeper-fs-created-directory-fchmod"
                     (fun () ->
                        Eio_unix.Fd.use_exn
                          "keeper-fs-created-directory-fchmod"
                          fd
                          (fun unix_fd -> Unix.fchmod unix_fd permissions));
                   Eio.Fiber.check ()))
             in
             let child_sync = sync_created_directory child_dir in
             let parent_sync = sync_created_directory parent_dir in
             let target_effect, primary_failure =
               match permissions_result with
               | Ok () -> Directory_created_requested_mode, None
               | Error failure -> Directory_created_validated, Some failure
             in
             let child_dir =
               match primary_failure, child_sync, parent_sync with
               | None, Directory_sync_succeeded, Directory_sync_succeeded ->
                 Some child_dir
               | ( Some _
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ )
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , (Directory_sync_not_attempted | Directory_sync_failed _)
                 , ( Directory_sync_not_attempted
                   | Directory_sync_succeeded
                   | Directory_sync_failed _ ) )
               | ( None
                 , Directory_sync_succeeded
                 , (Directory_sync_not_attempted | Directory_sync_failed _) ) ->
                 None
             in
             ( child_dir
             , { component
               ; target_effect
               ; primary_failure
               ; child_sync
               ; parent_sync
               } ))))
;;

let with_created_parent_directories
      ~on_interrupted
      ~permissions
      parent_dir
      missing_parents
      f
  =
  let rec loop created_parents_rev parent_dir missing_parents =
    match missing_parents with
    | [] -> f ~created_parents:(List.rev created_parents_rev) parent_dir
    | component :: rest ->
      Eio.Switch.run @@ fun sw ->
      let child_dir, commit =
        Eio.Cancel.protect (fun () ->
          create_and_commit_directory_component
            ~sw
            ~permissions
            ~parent_dir
            ~component)
      in
      (try Eio.Fiber.check () with
       | Eio.Cancel.Cancelled _ as cancellation ->
         on_interrupted commit;
         raise cancellation);
      (match child_dir with
       | None ->
         Error
           (Content_write_directory
              { failed_commit = commit
              ; created_parents = List.rev created_parents_rev
              })
       | Some child_dir ->
         (try loop (commit :: created_parents_rev) child_dir rest with
          | exception_ ->
            let backtrace = Printexc.get_raw_backtrace () in
            on_interrupted commit;
            Printexc.raise_with_backtrace exception_ backtrace))
  in
  loop [] parent_dir missing_parents
;;

let rec with_deepest_existing_parent
          parent_dir
          traversed_components_rev
          remaining_components
          f
  =
  match remaining_components with
  | [] ->
    f
      ~parent_dir
      ~parent_components:(List.rev traversed_components_rev)
      ~missing_parents:[]
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Ok child_dir ->
       with_deepest_existing_parent
         child_dir
         (component :: traversed_components_rev)
         rest
         f
     | Error `Missing ->
       f
         ~parent_dir
         ~parent_components:(List.rev traversed_components_rev)
         ~missing_parents:remaining_components)
;;

let rec with_open_directory_components ~on_missing parent_dir components f =
  match components with
  | [] -> f parent_dir
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Error `Missing -> on_missing ()
     | Ok child_dir ->
       with_open_directory_components ~on_missing child_dir rest f)
;;

let rec split_leaf_components = function
  | [] -> None
  | [ leaf ] -> Some ([], leaf)
  | component :: rest ->
    Option.map
      (fun (parent, leaf) -> component :: parent, leaf)
      (split_leaf_components rest)
;;

let with_confined_write_parent confined f =
  match Fs_compat.get_fs_opt () with
  | None ->
    Error
      "filesystem capability unavailable: Eio filesystem was not installed at runtime startup"
  | Some fs ->
    (try
       let anchor_root = Keeper_alerting_path.confined_anchor_root confined in
       let root_relative_path =
         Keeper_alerting_path.confined_root_relative_path confined
       in
       let target_components =
         Keeper_alerting_path.confined_relative_components confined
       in
       let with_root root_dir =
         let* () =
           Keeper_alerting_path.verify_confined_root_capability confined root_dir
         in
         match split_leaf_components target_components with
         | None -> Error "filesystem target has no writable leaf"
         | Some (parent_components, leaf) ->
           with_deepest_existing_parent
             root_dir
             []
             parent_components
             (fun ~parent_dir ~parent_components ~missing_parents ->
                f
                  ~root_dir
                  ~parent_dir
                  ~parent_components
                  ~missing_parents
                  ~leaf)
       in
       Eio.Path.with_open_dir Eio.Path.(fs / anchor_root) @@ fun anchor_dir ->
       if String.equal root_relative_path "."
       then with_root anchor_dir
       else
         Eio.Path.with_open_dir Eio.Path.(anchor_dir / root_relative_path)
         @@ fun root_dir ->
         with_root root_dir
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ as exn -> Error (Printexc.to_string exn))
;;

let check_invariant_sandbox_isolation
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~confined
  =
  let target = Keeper_alerting_path.confined_containment_path confined in
  match turn_sandbox_factory with
  | None -> Ok ()
  | Some factory ->
    let cwd = Filename.dirname target in
    (match Keeper_sandbox_factory.resolve_opt (Some factory) ~cwd with
     (* No guest root to check against; the call itself is refused where it
        would run. No turn runtime exists to scope the isolation invariant to
        ([Remote_ssh_profile] included: its calls are scoped on the remote
        side, not against a local guest root). *)
     | No_factory | Remote_ssh_profile -> Ok ()
     | Runtime { runtime; _ } ->
       let host_root = Keeper_turn_sandbox_runtime.host_root runtime in
       Keeper_invariant.sandbox_isolation
         ~sandbox_roots:[ host_root ]
         ~sandbox_paths:[ target ])
;;

(* Invert the recorded Gate effect back into the write mode that produced
   it. Only the modes this module can reproduce exactly are accepted; an
   unrecognised effect yields [None] so a caller replays nothing rather than
   silently downgrading, say, an approved append into an overwrite. *)
let fs_write_mode_of_gate_effect_operation raw =
  let spelled operation =
    String.equal raw (Keeper_alerting_path.path_effect_operation_to_string operation)
  in
  if spelled Keeper_alerting_path.Atomic_replace_entry
  then Some Overwrite
  else if spelled Keeper_alerting_path.Append_pinned_resource
  then Some Append
  else if spelled Keeper_alerting_path.Patch_then_atomic_replace_entry
  then Some Patch
  else None
;;

(* Rebuild the write arguments from a recorded Gate input. The Gate input
   carries the resolved target under [requested_target] and the mode inside
   the effect; the handler reads both from the argument object. Only fields
   the approval carried are emitted, so a content write cannot gain edit
   fields. *)
let replay_args_of_gate_input input =
  let ( let* ) = Result.bind in
  match input with
  | `Assoc fields ->
    let field name = List.assoc_opt name fields in
    let* target =
      match field "requested_target" with
      | Some (`String target) -> Ok target
      | Some _ -> Error "approved Gate input has a non-string requested_target"
      | None -> Error "approved Gate input has no requested_target"
    in
    let* mode =
      match field "effect" with
      | Some (`Assoc effect_fields) ->
        (match List.assoc_opt "operation" effect_fields with
         | Some (`String operation) ->
           (match fs_write_mode_of_gate_effect_operation operation with
            | Some mode -> Ok mode
            | None ->
              Error ("approved Gate effect is not replayable: " ^ operation))
         | _ -> Error "approved Gate effect has no operation")
      | _ -> Error "approved Gate input has no effect"
    in
    let carried =
      List.filter_map
        (fun name -> Option.map (fun value -> name, value) (field name))
        [ "content"; "old_string"; "new_string"; "replace_all" ]
    in
    Ok
      (`Assoc
         (("path", `String target)
          :: ("mode", `String (fs_write_mode_to_string mode))
          :: carried))
  | _ -> Error "approved Gate input is not a JSON object"
;;

(* The opaque Gate operation identity for every local write this module
   performs. The Gate never parses it; consumers that must recognise the
   same effect read it from here instead of repeating the literal. *)
let gate_operation = "filesystem_write"

let file_write_gate_input
      ~gate_effect
      ~requested_target
      ~content
      ?old_string
      ?new_string
      ?replace_all
      ()
  =
  let optional_string name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  let optional_bool name = function
    | None -> []
    | Some value -> [ name, `Bool value ]
  in
  `Assoc
    ([ "effect", Keeper_alerting_path.path_effect_to_yojson gate_effect
     ; "requested_target", `String requested_target
     ; "content", `String content
     ]
     @ optional_string "old_string" old_string
     @ optional_string "new_string" new_string
     @ optional_bool "replace_all" replace_all)
;;

let decide_file_write
      ~config
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~input
      ()
  =
  Keeper_gate.decide
    ?cycle_grant:gate_grant
    ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
    { keeper_name = meta.name
    ; operation = gate_operation
    ; input
    ; sandbox_profile = None
    ; base_path = config.Workspace.base_path
    ; causal_context = Option.map (fun current -> current ()) gate_context
    ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; continuation_channel
    }
;;

let confined_write_is_keeper_playground
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      confined
  =
  let normalized path =
    Keeper_alerting_path.normalize_path_for_check_stripped path
  in
  String.equal
    (normalized (Keeper_alerting_path.confined_root confined))
    (normalized (Keeper_sandbox.host_root_abs_of_meta ~config meta))
;;

type file_write_attempt =
  | Write_succeeded of
      { payload : string
      ; file_change_evidence : Keeper_file_change_evidence.t option
      }
  | Write_authorized of Keeper_gate.authorization * file_write_attempt
  | Write_deferred of Keeper_gate_deferred_payload.t
  | Write_failed of
      { payload : string
      ; class_ : Tool_result.tool_failure_class
      }
  | Write_failed_data of
      { message : string
      ; data : Yojson.Safe.t
      ; class_ : Tool_result.tool_failure_class
      }

let capability_write_failure_json
      (failure : Fs_compat.capability_write_failure)
  =
  let cause_fields =
    match failure.cause with
    | Fs_compat.Payload_write_failed { bytes_written; _ } ->
      [ "bytes_written", `Int bytes_written ]
    | ( Fs_compat.Invalid_leaf _
      | Fs_compat.Invalid_recovery_target _
      | Fs_compat.Mutation_contended
      | Fs_compat.Posix_descriptor_unavailable
      | Fs_compat.Unexpected_resource_kind _
      | Fs_compat.Resource_identity_unavailable
      | Fs_compat.Resource_identity_changed
      | Fs_compat.Operation_failed _ ) -> []
  in
  `Assoc
    ([ ( "stage"
       , `String (Fs_compat.capability_write_stage_to_string failure.stage) )
     ; ( "cause"
       , `String (Fs_compat.capability_write_cause_to_string failure.cause) )
     ]
     @ cause_fields)
;;

let capability_recovery_failure_json failure =
  `Assoc
    [ ( "phase"
      , `String
          (Fs_compat.capability_recovery_phase_to_string
             (Fs_compat.capability_recovery_failure_phase failure)) )
    ; ( "effect"
      , `String
          (Fs_compat.capability_recovery_effect_to_string
             (Fs_compat.capability_recovery_failure_effect failure)) )
    ; "detail", `String (Fs_compat.capability_recovery_failure_to_string failure)
    ]
;;

let capability_write_primary_failure_json = function
  | Fs_compat.Write_primary_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_primary_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    `Assoc
      [ "kind", `String "recovery_access"
      ; "failure", `String "recovery_access_not_available"
      ]
;;

let capability_write_cleanup_failure_json = function
  | Fs_compat.Write_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "write"
      ; "failure", capability_write_failure_json failure
      ]
  | Fs_compat.Recovery_cleanup_failure failure ->
    `Assoc
      [ "kind", `String "recovery"
      ; "failure", capability_recovery_failure_json failure
      ]
;;

let observe_capability_write_failure_backtrace
      ~keeper_name
      ~target
      (failure : Fs_compat.capability_write_failure)
  =
  match failure.Fs_compat.cause with
  | Fs_compat.Operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | Fs_compat.Payload_write_failed { exception_; backtrace; bytes_written } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem payload write failed path=%s stage=%s bytes_written=%d error=%s backtrace=%s"
      target
      (Fs_compat.capability_write_stage_to_string failure.stage)
      bytes_written
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Invalid_leaf _
    | Fs_compat.Invalid_recovery_target _
    | Fs_compat.Mutation_contended
    | Fs_compat.Posix_descriptor_unavailable
    | Fs_compat.Unexpected_resource_kind _
    | Fs_compat.Resource_identity_unavailable
    | Fs_compat.Resource_identity_changed ) -> ()
;;

let observe_capability_recovery_failure ~keeper_name ~target failure =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: filesystem recovery transition failed path=%s phase=%s effect=%s failure=%s"
    target
    (Fs_compat.capability_recovery_phase_to_string
       (Fs_compat.capability_recovery_failure_phase failure))
    (Fs_compat.capability_recovery_effect_to_string
       (Fs_compat.capability_recovery_failure_effect failure))
    (Fs_compat.capability_recovery_failure_to_string failure)
;;

let observe_capability_write_primary_failure ~keeper_name ~target = function
  | Fs_compat.Write_primary_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_primary_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
  | Fs_compat.Recovery_access_primary_failure
      Fs_compat.Recovery_access_not_available ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: filesystem recovery access unavailable path=%s"
      target
;;

let observe_capability_write_cleanup_failure ~keeper_name ~target = function
  | Fs_compat.Write_cleanup_failure failure ->
    observe_capability_write_failure_backtrace ~keeper_name ~target failure
  | Fs_compat.Recovery_cleanup_failure failure ->
    observe_capability_recovery_failure ~keeper_name ~target failure
;;

let observe_capability_write_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_write_error)
  =
  observe_capability_write_primary_failure
    ~keeper_name
    ~target
    error.Fs_compat.primary_failure;
  List.iter
    (observe_capability_write_cleanup_failure ~keeper_name ~target)
    error.cleanup_failures
;;

let observe_capability_directory_sync_error
      ~keeper_name
      ~target
      (error : Fs_compat.capability_directory_sync_error)
  =
  observe_capability_write_failure_backtrace
    ~keeper_name
    ~target
    error.failure;
  List.iter
    (observe_capability_write_failure_backtrace ~keeper_name ~target)
    error.cleanup_failures
;;

let created_directory_stage_to_string = function
  | Create_directory -> "create_directory"
  | Inspect_created_directory -> "inspect_created_directory"
  | Acquire_directory_capability -> "acquire_directory_capability"
  | Validate_directory_capability -> "validate_directory_capability"
  | Apply_directory_permissions -> "apply_directory_permissions"
;;

let created_directory_target_effect_to_string = function
  | Directory_unchanged -> "directory_unchanged"
  | Directory_created_validated -> "directory_created_validated"
  | Directory_created_requested_mode -> "directory_created_requested_mode"
  | Directory_state_unknown -> "directory_state_unknown"
;;

let created_directory_failure_cause_to_string = function
  | Directory_posix_descriptor_unavailable -> "POSIX descriptor unavailable"
  | Directory_unexpected_resource_kind kind ->
    Format.asprintf "unexpected resource kind: %a" Eio.File.Stat.pp_kind kind
  | Directory_resource_identity_changed -> "directory resource identity changed"
  | Directory_operation_failed { exception_; _ } -> Printexc.to_string exception_
;;

let created_directory_failure_json failure =
  `Assoc
    [ "stage", `String (created_directory_stage_to_string failure.stage)
    ; "cause", `String (created_directory_failure_cause_to_string failure.cause)
    ]
;;

let created_directory_sync_outcome_json = function
  | Directory_sync_not_attempted -> `Assoc [ "status", `String "not_attempted" ]
  | Directory_sync_succeeded -> `Assoc [ "status", `String "succeeded" ]
  | Directory_sync_failed error ->
    `Assoc
      [ "status", `String "failed"
      ; "failure", capability_write_failure_json error.failure
      ; ( "cleanup_failures"
        , `List (List.map capability_write_failure_json error.cleanup_failures) )
      ]
;;

let created_directory_commit_json commit =
  `Assoc
    [ "component", `String commit.component
    ; ( "target_effect"
      , `String (created_directory_target_effect_to_string commit.target_effect) )
    ; ( "primary_failure"
      , match commit.primary_failure with
        | None -> `Null
        | Some failure -> created_directory_failure_json failure )
    ; "child_sync", created_directory_sync_outcome_json commit.child_sync
    ; "parent_sync", created_directory_sync_outcome_json commit.parent_sync
    ]
;;

let created_parent_effects_json created_parents =
  `List (List.map created_directory_commit_json created_parents)
;;

let created_directory_sync_observation_json = function
  | Directory_sync_not_attempted -> `String "not_attempted"
  | Directory_sync_succeeded -> `String "succeeded"
  | Directory_sync_failed _ -> `String "failed"
;;

let created_parent_effect_observation_json commit =
  `Assoc
    [ ( "target_effect"
      , `String (created_directory_target_effect_to_string commit.target_effect) )
    ; "child_sync", created_directory_sync_observation_json commit.child_sync
    ; "parent_sync", created_directory_sync_observation_json commit.parent_sync
    ]
;;

let created_parent_effect_observations_json created_parents =
  `List (List.map created_parent_effect_observation_json created_parents)
;;

let capability_write_error_payload
      ~target
      ~created_parents
      (error : Fs_compat.capability_write_error)
  =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_write_operation"
        , `String
            (Fs_compat.capability_write_operation_to_string error.operation) )
      ; ( "filesystem_target_effect"
        , `String
            (Fs_compat.capability_write_target_effect_to_string
               error.target_effect) )
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; ( "filesystem_primary_failure"
        , capability_write_primary_failure_json error.primary_failure )
      ; ( "filesystem_cleanup_failures"
        , `List
            (List.map
               capability_write_cleanup_failure_json
               error.cleanup_failures) )
      ]
    "Filesystem publication failed; target effect and cleanup outcome are reported explicitly."
;;

let created_directory_commit_payload ~target ~created_parents commit =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; "filesystem_directory_component", `String commit.component
      ; ( "filesystem_directory_target_effect"
        , `String
            (created_directory_target_effect_to_string commit.target_effect) )
      ; ( "filesystem_directory_primary_failure"
        , match commit.primary_failure with
          | None -> `Null
          | Some failure -> created_directory_failure_json failure )
      ; ( "filesystem_directory_child_sync"
        , created_directory_sync_outcome_json commit.child_sync )
      ; ( "filesystem_directory_parent_sync"
        , created_directory_sync_outcome_json commit.parent_sync )
      ]
    "Filesystem parent directory publication failed; creation effect and durability outcomes are reported explicitly."
;;

let observe_created_directory_failure_backtrace
      ~keeper_name
      ~target
      failure
  =
  match failure.cause with
  | Directory_operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: directory publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (created_directory_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Directory_posix_descriptor_unavailable
    | Directory_unexpected_resource_kind _
    | Directory_resource_identity_changed ) -> ()
;;

let observe_created_directory_sync_outcome ~keeper_name ~target = function
  | Directory_sync_not_attempted | Directory_sync_succeeded -> ()
  | Directory_sync_failed error ->
    observe_capability_directory_sync_error ~keeper_name ~target error
;;

let observe_created_directory_commit ~keeper_name ~target commit =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: directory publication outcome path=%s component=%s target_effect=%s child_sync=%s parent_sync=%s"
    target
    commit.component
    (created_directory_target_effect_to_string commit.target_effect)
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.child_sync))
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.parent_sync));
  Option.iter
    (observe_created_directory_failure_backtrace ~keeper_name ~target)
    commit.primary_failure;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.child_sync;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.parent_sync
;;

let append_target_effect_to_string = function
  | Append_target_unchanged -> "target_unchanged"
  | Append_target_extended_complete -> "target_extended_complete"
  | Append_target_extended_partial -> "target_extended_partial"
  | Append_target_extended_detached -> "target_extended_detached"
  | Append_target_state_unknown -> "target_state_unknown"
;;

let capability_append_open_error_kind = function
  | Fs_compat.Capability_append_open_invalid_leaf _ -> "invalid_leaf"
  | Fs_compat.Capability_append_open_missing -> "missing"
  | Fs_compat.Capability_append_open_failed _ -> "operation_failed"
;;

let capability_append_open_error_payload ~target error =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_open_failure"
        , `Assoc
            [ ( "kind"
              , `String (capability_append_open_error_kind error) )
            ; ( "cause"
              , `String
                  (Fs_compat.capability_append_open_error_to_string error) )
            ] )
      ]
    "Filesystem append capability acquisition failed explicitly."
;;

let observe_capability_append_open_error ~keeper_name ~target error =
  match error with
  | Fs_compat.Capability_append_open_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition failed path=%s error=%s backtrace=%s"
      target
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Fs_compat.Capability_append_open_invalid_leaf _
    | Fs_compat.Capability_append_open_missing ) ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append capability acquisition rejected path=%s kind=%s"
      target
      (capability_append_open_error_kind error)
;;

let append_target_effect outcome =
  match outcome.target_binding with
  | Fs_compat.Capability_append_target_not_checked
    when outcome.bytes_written = 0 -> Append_target_unchanged
  | Fs_compat.Capability_append_target_verified ->
    if outcome.bytes_written = 0
    then Append_target_unchanged
    else if
      outcome.bytes_written = outcome.requested_bytes
      && Option.is_none outcome.write_failure
    then Append_target_extended_complete
    else Append_target_extended_partial
  | Fs_compat.Capability_append_target_changed ->
    if outcome.bytes_written = 0
    then Append_target_state_unknown
    else Append_target_extended_detached
  | ( Fs_compat.Capability_append_target_not_checked
    | Fs_compat.Capability_append_target_check_failed _ ) ->
    Append_target_state_unknown
;;

let append_target_binding_json = function
  | Fs_compat.Capability_append_target_not_checked ->
    `Assoc [ "status", `String "not_checked" ]
  | Fs_compat.Capability_append_target_verified ->
    `Assoc [ "status", `String "verified" ]
  | Fs_compat.Capability_append_target_changed ->
    `Assoc [ "status", `String "changed" ]
  | Fs_compat.Capability_append_target_check_failed { exception_; _ } ->
    `Assoc
      [ "status", `String "check_failed"
      ; "cause", `String (Printexc.to_string exception_)
      ]
;;

let append_write_outcome_payload ~target outcome =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_append_target_effect"
        , `String
            (append_target_effect_to_string (append_target_effect outcome)) )
      ; ( "filesystem_append_target_binding"
        , append_target_binding_json outcome.target_binding )
      ; ( "filesystem_append_failure"
        , match outcome.write_failure with
          | None -> `Null
          | Some failure ->
            `String (Fs_compat.capability_append_failure_to_string failure) )
      ; ( "filesystem_append_sync_failure"
        , match outcome.sync_failure with
          | None -> `Null
          | Some { exception_; _ } -> `String (Printexc.to_string exception_) )
      ]
    "Filesystem append did not complete normally; exact written bytes and sync outcome are reported explicitly."
;;

let observe_append_write_outcome ~keeper_name ~target outcome =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: append publication outcome path=%s requested_bytes=%d bytes_written=%d target_effect=%s failure=%s"
    target
    outcome.requested_bytes
    outcome.bytes_written
    (append_target_effect_to_string (append_target_effect outcome))
    (match outcome.write_failure with
     | None -> "none"
     | Some failure -> Fs_compat.capability_append_failure_to_string failure);
  (match outcome.write_failure with
   | Some
       (Fs_compat.Capability_append_operation_failed
         { exception_; backtrace }) ->
     Log.Keeper.error
       ~keeper_name
       "WRITE_AUDIT: append write failed path=%s error=%s backtrace=%s"
       target
       (Printexc.to_string exception_)
       (Printexc.raw_backtrace_to_string backtrace)
   | ( None
     | Some Fs_compat.Capability_append_posix_descriptor_unavailable
     | Some Fs_compat.Capability_append_mutation_contended ) -> ());
  let observe_operation_failure
        label
        (failure : Fs_compat.capability_append_operation_failure)
    =
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: append %s failed path=%s error=%s backtrace=%s"
      label
      target
      (Printexc.to_string failure.exception_)
      (Printexc.raw_backtrace_to_string failure.backtrace)
  in
  Option.iter (observe_operation_failure "sync") outcome.sync_failure;
  (match outcome.target_binding with
   | Fs_compat.Capability_append_target_check_failed failure ->
     observe_operation_failure "target identity check" failure
   | ( Fs_compat.Capability_append_target_not_checked
     | Fs_compat.Capability_append_target_verified
     | Fs_compat.Capability_append_target_changed ) -> ())
;;

let rec file_write_attempt_to_execution = function
  | Write_succeeded { payload; file_change_evidence } ->
    let execution = Keeper_tool_execution.success payload in
    (match file_change_evidence with
     | Some evidence ->
       Keeper_tool_execution.with_file_change_evidence evidence execution
     | None -> execution)
  | Write_authorized (authorization, attempt) ->
    file_write_attempt_to_execution attempt
    |> Keeper_tool_execution.with_gate_authorization authorization
  | Write_deferred deferred ->
    Keeper_gate_deferred_payload.to_execution deferred
  | Write_failed { payload; class_ } -> Keeper_tool_execution.failure ~class_ payload
  | Write_failed_data { message; data; class_ } ->
    Keeper_tool_execution.failure_data ~class_ ~message data
;;

let publication_recovery_unavailable_attempt unavailable =
  Write_failed_data
    { message =
        Keeper_publication_recovery_availability.unavailable_to_string unavailable
    ; data =
        Keeper_publication_recovery_availability.unavailable_to_yojson unavailable
    ; class_ = Tool_result.Runtime_failure
    }
;;

type publication_write_execution =
  | Publication_write_completed
  | Publication_write_effect_observed
  | Publication_write_not_executed
  | Publication_write_indeterminate

type publication_callback_observation =
  { execution : publication_write_execution
  ; publication_result : Yojson.Safe.t
  }

let publication_recovery_cleanup_failed_attempt
      ~keeper_name
      ~target
      ~execution
      ~publication_result
      release_failure
  =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: publication recovery lane release failed after callback path=%s write_execution=%s evidence=%s"
    target
    (match execution with
     | Publication_write_completed -> "completed"
     | Publication_write_effect_observed -> "effect_observed"
     | Publication_write_not_executed -> "not_executed"
     | Publication_write_indeterminate -> "indeterminate")
    (Fs_compat.Publication_recovery.lane_release_failure_to_string
       release_failure);
  let message, write_executed =
    match execution with
    | Publication_write_completed ->
      ( "filesystem publication committed, but publication recovery lane cleanup failed"
      , `Bool true )
    | Publication_write_effect_observed ->
      ( "filesystem publication produced an observable filesystem effect before the publication callback and recovery lane cleanup both failed"
      , `Bool true )
    | Publication_write_not_executed ->
      ( "filesystem publication left the target unchanged, but publication recovery lane cleanup failed"
      , `Bool false )
    | Publication_write_indeterminate ->
      ( "filesystem publication callback and publication recovery lane cleanup both failed"
      , `Null )
  in
  Write_failed_data
    { message
    ; data =
        `Assoc
          [ "error", `String "publication_recovery_cleanup_failed"
          ; "failure_class", `String "runtime_failure"
          ; "state", `String "lane_release_failed"
          ; "detail"
          , `String "publication recovery lane cleanup failed after the publication callback returned"
          ; "write_executed", write_executed
          ; "keeper_active", `Bool true
          ; "publication_result", publication_result
          ]
    ; class_ = Tool_result.Runtime_failure
    }
;;

let finish_recovery_guarded_write
      ~keeper_name
      ~target
      ~observe_result
      ~finish
      outcome
  =
  match outcome with
  | Fs_compat.Publication_recovery.Lane_released result -> finish result
  | Fs_compat.Publication_recovery.Lane_release_failed
      { value; release_failure } ->
    let observation = observe_result value in
    let publication_result =
      match finish value with
      | Ok _ -> observation.publication_result
      | Error message ->
        Log.Keeper.error
          ~keeper_name
          "WRITE_AUDIT: publication callback result projection failed before lane release evidence path=%s error=%s"
          target
          message;
        `Assoc
          [ "outcome", `String "projection_failure"
          ; "callback_result", observation.publication_result
          ]
    in
    Ok
      (publication_recovery_cleanup_failed_attempt
         ~keeper_name
         ~target
         ~execution:observation.execution
         ~publication_result
         release_failure)
;;

type publication_effect_observation =
  | Publication_effect_absent
  | Publication_effect_observed
  | Publication_effect_indeterminate

let join_publication_effect_observation left right =
  match left, right with
  | Publication_effect_observed, _ | _, Publication_effect_observed ->
    Publication_effect_observed
  | Publication_effect_indeterminate, _ | _, Publication_effect_indeterminate ->
    Publication_effect_indeterminate
  | Publication_effect_absent, Publication_effect_absent ->
    Publication_effect_absent
;;

let publication_execution_of_effect_observation = function
  | Publication_effect_absent -> Publication_write_not_executed
  | Publication_effect_observed -> Publication_write_effect_observed
  | Publication_effect_indeterminate -> Publication_write_indeterminate
;;

let publication_effect_observation_of_target_effect = function
  | Fs_compat.Target_unchanged -> Publication_effect_absent
  | ( Fs_compat.Target_created
    | Fs_compat.Target_created_incomplete
    | Fs_compat.Target_replaced ) ->
    Publication_effect_observed
  | Fs_compat.Target_state_unknown -> Publication_effect_indeterminate
;;

let publication_effect_observation_of_directory_target_effect = function
  | Directory_unchanged -> Publication_effect_absent
  | (Directory_created_validated | Directory_created_requested_mode) ->
    Publication_effect_observed
  | Directory_state_unknown -> Publication_effect_indeterminate
;;

let publication_effect_observation_of_created_parents created_parents =
  List.fold_left
    (fun observation commit ->
       join_publication_effect_observation
         observation
         (publication_effect_observation_of_directory_target_effect
            commit.target_effect))
    Publication_effect_absent
    created_parents
;;

let publication_execution_of_error_effect ~primary ~created_parents =
  join_publication_effect_observation
    primary
    (publication_effect_observation_of_created_parents created_parents)
  |> publication_execution_of_effect_observation
;;

let content_write_observation = function
  | Ok () ->
    { execution = Publication_write_completed
    ; publication_result = `Assoc [ "outcome", `String "success" ]
    }
  | Error (Content_write_capability { error; created_parents }) ->
    { execution =
        publication_execution_of_error_effect
          ~primary:
            (publication_effect_observation_of_target_effect error.target_effect)
          ~created_parents
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_target_effect"
            , `String
                (Fs_compat.capability_write_target_effect_to_string
                   error.target_effect) )
          ; ( "filesystem_created_parent_effects"
            , created_parent_effect_observations_json created_parents )
          ]
    }
  | Error (Content_write_directory { failed_commit; created_parents }) ->
    { execution =
        publication_execution_of_error_effect
          ~primary:
            (publication_effect_observation_of_directory_target_effect
               failed_commit.target_effect)
          ~created_parents
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_directory_target_effect"
            , `String
                (created_directory_target_effect_to_string
                   failed_commit.target_effect) )
          ; ( "filesystem_created_parent_effects"
            , created_parent_effect_observations_json created_parents )
          ]
    }
  | Error (Content_write_append outcome) ->
    let target_effect = append_target_effect outcome in
    let execution =
      match target_effect with
      | Append_target_unchanged -> Publication_write_not_executed
      | ( Append_target_extended_complete
        | Append_target_extended_partial
        | Append_target_extended_detached ) ->
        Publication_write_effect_observed
      | Append_target_state_unknown -> Publication_write_indeterminate
    in
    { execution
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_append_target_effect"
            , `String (append_target_effect_to_string target_effect) )
          ]
    }
;;

let handle_file_write_with_outcome
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(args : Yojson.Safe.t)
      ()
  =
  (* A tree the endpoint owns is not on this host: every capability below
     would write the bookkeeping bundle and miss the tree. Those writes go
     through the remote lane. *)
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Endpoint_owned ->
    Keeper_tool_filesystem_remote_write.handle
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
  | Keeper_types_profile_sandbox.Shared_mount ->
  let via_field =
    match turn_sandbox_factory with
    | Some _ ->
      [ ( "via"
        , `String
            (Keeper_sandbox_runner.route_label
               Keeper_sandbox_runner.Sandbox_backend) )
      ]
    | None -> []
  in
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  (* Absent, non-string and unknown modes are all rejected; see
     [Keeper_tool_write_mode.of_args] for why there is no default. *)
  let mode_result = Keeper_tool_write_mode.of_args args in
  let after_gate ~confined ~target ~input continue =
    if confined_write_is_keeper_playground ~config ~meta confined
    then (
      Log.Keeper.info
        ~keeper_name:meta.name
        "internal playground write authorized by confined capability path=%s"
        target;
      continue ())
    else
      match
        decide_file_write
          ~config
          ~meta
          ?continuation_channel
          ?gate_context
          ?gate_grant
          ~input
          ()
      with
      | Keeper_gate.Deferred { approval_id; reason; audit_receipts } ->
        Ok
          (Write_deferred
             (Keeper_gate_deferred_payload.create
                ~operation:gate_operation
                ~approval_id
                ~reason
                ~audit_receipts
                ~context:(`Assoc [ "path", `String target ])
                ()))
      | Keeper_gate.Unavailable reason ->
        Ok
          (Write_failed
             { payload =
                 error_json
                   ~fields:
                     [ "path", `String target
                     ; "error", `String "gate_unavailable"
                     ; "gate_reason"
                     , `String (Keeper_gate.unavailable_reason_to_string reason)
                     ]
                   "External effect was not executed because the Gate could not durably record its decision state. This Keeper remains active and may continue other work."
             ; class_ = Tool_result.Runtime_failure
             })
      | Keeper_gate.Allow authorization ->
        Log.Keeper.info
          ~keeper_name:meta.name
          "external effect authorized operation=filesystem_write source=%s"
          (Keeper_gate.authorization_source_to_string authorization.source);
        (match continue () with
         | Ok attempt -> Ok (Write_authorized (authorization, attempt))
         | Error message ->
           Ok
             (Write_authorized
                ( authorization
                , Write_failed
                    { payload = error_json ~fields:[ "path", `String target ] message
                    ; class_ = Tool_result.Runtime_failure
                    } )))
  in
  let protect_write ~target f =
    try f () with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (reason, cancellation)) as e ->
      let interrupted_primary =
        match cancellation.interrupted_primary_failure with
        | None -> `Null
        | Some failure -> capability_write_primary_failure_json failure
      in
      let interrupted_recovery =
        match cancellation.interrupted_recovery with
        | None -> `Null
        | Some failure -> capability_recovery_failure_json failure
      in
      Log.Keeper.error
        ~keeper_name:meta.name
        "WRITE_AUDIT: filesystem publication cancelled after observable state transition path=%s operation=%s target_effect=%s interrupted_primary=%s interrupted_recovery=%s cleanup_failures=%s reason=%s"
        target
        (Fs_compat.capability_write_operation_to_string cancellation.operation)
        (Fs_compat.capability_write_target_effect_to_string
           cancellation.target_effect)
        (Yojson.Safe.to_string interrupted_primary)
        (Yojson.Safe.to_string interrupted_recovery)
        (Yojson.Safe.to_string
           (`List
               (List.map
                  capability_write_cleanup_failure_json
                  cancellation.cleanup_failures)))
        (Printexc.to_string reason);
      Option.iter
        (observe_capability_write_primary_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_primary_failure;
      Option.iter
        (observe_capability_recovery_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_recovery;
      List.iter
        (observe_capability_write_cleanup_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.cleanup_failures;
      raise e
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Io _ as e ->
      Ok
        (Write_failed
           { payload =
               error_json ~fields:[ "path", `String target ] (Printexc.to_string e)
           ; class_ = Tool_result.Runtime_failure
           })
    | Invalid_argument e | Sys_error e ->
      Ok
        (Write_failed
           { payload = error_json ~fields:[ "path", `String target ] e
           ; class_ = Tool_result.Runtime_failure
           })
    | Unix.Unix_error (err, _, _) ->
      Ok
        (Write_failed
           { payload =
               error_json
                 ~fields:[ "path", `String target ]
                 (Unix.error_message err)
           ; class_ = Tool_result.Runtime_failure
           })
  in
  let finish_content_write ~confined ~target ~mode ~gate_effect write =
    let mode_label = fs_write_mode_to_string mode in
    let input =
      file_write_gate_input
        ~gate_effect
        ~requested_target:target
        ~content
        ()
    in
    after_gate ~confined ~target ~input
    @@ fun () ->
    protect_write ~target
    @@ fun () ->
    let finish_write_result result =
      match result with
    | Error (Content_write_capability { error; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_capability_write_error ~keeper_name:meta.name ~target error;
      Ok
        (Write_failed
           { payload = capability_write_error_payload ~target ~created_parents error
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_directory { failed_commit; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_created_directory_commit
        ~keeper_name:meta.name
        ~target
        failed_commit;
      Ok
        (Write_failed
           { payload =
               created_directory_commit_payload
                 ~target
                 ~created_parents
                 failed_commit
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_append outcome) ->
      observe_append_write_outcome
        ~keeper_name:meta.name
        ~target
        outcome;
      Ok
        (Write_failed
           { payload = append_write_outcome_payload ~target outcome
           ; class_ = Tool_result.Runtime_failure
           })
    | Ok () ->
      Log.Keeper.info
        "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
        meta.name
        target
        mode_label
        (String.length content);
      Ok
        (Write_succeeded
           { payload =
               Yojson.Safe.to_string
                 (`Assoc
                     ([ "ok", `Bool true
                      ; "path", `String target
                      ; "mode", `String mode_label
                      ; "bytes_written", `Int (String.length content)
                      ]
                      @ via_field))
           ; file_change_evidence =
               (match mode with
                | Overwrite -> Some (Keeper_file_change_evidence.written content)
                | Append | Patch -> None)
           })
    in
    match write with
    | Recovery_independent operation -> finish_write_result (operation ())
    | Recovery_guarded operation ->
      (match
         Keeper_publication_recovery_availability.with_access
           publication_recovery
           operation
       with
       | Ok outcome ->
         finish_recovery_guarded_write
           ~keeper_name:meta.name
           ~target
           ~observe_result:content_write_observation
           ~finish:finish_write_result
           outcome
       | Error unavailable ->
         Ok (publication_recovery_unavailable_attempt unavailable))
  in
  let parent_effect_scope ~parent_dir ~parent_components ~missing_parents =
    Keeper_alerting_path.path_effect_parent_scope
      ~parent_components
      ~resource:(Eio.Path.stat ~follow:true parent_dir)
      ~create_missing_parents:missing_parents
      ~created_directory_permissions
    |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
  in
  let handle_atomic_content_write ~mode ~make_effect =
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Lexical_entry
        ~raw_path:path
    with
    | Error msg -> Keeper_tool_execution.failure (error_json msg)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_confined_write_parent confined
        @@ fun ~root_dir:_ ~parent_dir ~parent_components ~missing_parents ~leaf ->
        let* parent =
          parent_effect_scope ~parent_dir ~parent_components ~missing_parents
        in
        let* result_file_permissions =
          if missing_parents = []
          then replacement_file_permissions ~parent_dir ~leaf
          else Ok created_file_permissions
        in
        let* projection =
          make_effect ~parent ~result_file_permissions confined
          |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
        in
        let gate_effect =
          Keeper_alerting_path.atomic_replace_gate_effect projection
        in
        let recovery_target =
          Keeper_alerting_path.atomic_replace_recovery_target projection
        in
        finish_content_write
          ~confined
          ~target
          ~mode
          ~gate_effect
          (Recovery_guarded
             (fun publication_recovery_access ->
                with_created_parent_directories
                  ~on_interrupted:
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                  ~permissions:created_directory_permissions
                  parent_dir
                  missing_parents
                @@ fun ~created_parents final_parent ->
                Fs_compat.replace_capability_file
                  ~recovery:publication_recovery_access
                  ~parent:final_parent
                  ~target:recovery_target
                  content
                |> Result.map_error (fun error ->
                  Content_write_capability { error; created_parents })))
      in
      (match
         Keeper_external_resource_lease.with_lease
           (Keeper_external_resource_lease.File_path target)
           run
       with
       | Ok attempt -> file_write_attempt_to_execution attempt
       | Error msg ->
         Keeper_tool_execution.failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  let handle_append () =
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Follow_referent
        ~raw_path:path
    with
    | Error msg -> Keeper_tool_execution.failure (error_json msg)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_confined_write_parent confined
        @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf ->
        let create_missing_entry () =
          let* parent =
            parent_effect_scope ~parent_dir ~parent_components ~missing_parents
          in
          let* gate_effect =
            Keeper_alerting_path.create_entry_exclusive_effect
              ~parent
              ~result_file_permissions:created_file_permissions
              confined
            |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
          in
          finish_content_write
            ~confined
            ~target
            ~mode:Append
            ~gate_effect
            (Recovery_independent
               (fun () ->
                  with_created_parent_directories
                    ~on_interrupted:
                      (observe_created_directory_commit
                         ~keeper_name:meta.name
                         ~target)
                    ~permissions:created_directory_permissions
                    parent_dir
                    missing_parents
                  @@ fun ~created_parents final_parent ->
                  Fs_compat.create_capability_file_exclusive
                    ~parent:final_parent
                    ~leaf
                    ~permissions:created_file_permissions
                    content
                  |> Result.map_error (fun error ->
                    Content_write_capability { error; created_parents })))
        in
        if missing_parents <> []
        then create_missing_entry ()
        else
          let endpoint_components =
            Keeper_alerting_path.confined_endpoint_components confined
          in
          (match split_leaf_components endpoint_components with
           | None -> Error "filesystem append endpoint has no writable leaf"
           | Some (endpoint_parent_components, endpoint_leaf) ->
             with_open_directory_components
               ~on_missing:(fun () ->
                 Error "filesystem append endpoint parent does not exist")
               root_dir
               endpoint_parent_components
             @@ fun endpoint_parent_dir ->
             Eio.Switch.run @@ fun sw ->
             (match
                Fs_compat.open_capability_append_file
                  ~sw
                  ~parent:endpoint_parent_dir
                  ~leaf:endpoint_leaf
              with
              | Error Fs_compat.Capability_append_open_missing ->
                create_missing_entry ()
              | Error open_error ->
                observe_capability_append_open_error
                  ~keeper_name:meta.name
                  ~target
                  open_error;
                Ok
                  (Write_failed
                     { payload =
                         capability_append_open_error_payload
                           ~target
                           open_error
                     ; class_ = Tool_result.Runtime_failure
                     })
              | Ok file ->
                let stat = Fs_compat.capability_append_file_stat file in
                if stat.kind <> `Regular_file
                then Error "filesystem append target is not a regular file"
                else
                  let* gate_effect =
                    Keeper_alerting_path.append_pinned_resource_effect
                      confined
                      stat
                    |> Result.map_error
                         Keeper_alerting_path.path_effect_projection_error_to_string
                  in
                  finish_content_write
                    ~confined
                    ~target
                    ~mode:Append
                    ~gate_effect
                    (Recovery_independent
                       (fun () ->
                          append_capability
                            ~on_cancelled:
                              (observe_append_write_outcome
                                 ~keeper_name:meta.name
                                 ~target)
                            file
                            content))))
      in
      (match
         Keeper_external_resource_lease.with_lease
           (Keeper_external_resource_lease.File_path target)
           run
       with
       | Ok attempt -> file_write_attempt_to_execution attempt
       | Error msg ->
         Keeper_tool_execution.failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  if String.trim path = ""
  then
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''.")
  else (
    match mode_result with
    | Error mode_raw ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json (Keeper_tool_write_mode.rejection_message mode_raw))
    | Ok Patch ->
      let old_string = Safe_ops.json_string ~default:"" "old_string" args in
      let new_string = Safe_ops.json_string ~default:"" "new_string" args in
      let replace_all = Safe_ops.json_bool ~default:false "replace_all" args in
      if old_string = ""
      then
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json
             "mode=patch requires non-empty old_string. Good: old_string='let x = 1'.")
      else
        (match
           resolve_keeper_confined_write_path
             ~config
             ~meta
             ~endpoint:Keeper_alerting_path.Follow_referent
             ~raw_path:path
         with
         | Error msg -> Keeper_tool_execution.failure (error_json msg)
         | Ok confined ->
              let target = Keeper_alerting_path.confined_host_path confined in
              let finish_write
                    ~gate_effect
                    ~updated
                    ~occurrence_count
                    ~line_occurrences
                    write
                =
                let input =
                  file_write_gate_input
                    ~gate_effect
                    ~requested_target:target
                    ~content:updated
                    ~old_string
                    ~new_string
                    ~replace_all
                    ()
                in
                after_gate ~confined ~target ~input
                @@ fun () ->
                protect_write ~target
                @@ fun () ->
                let finish_write_result result =
                  match result with
                | Error (Content_write_capability { error; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_capability_write_error
                    ~keeper_name:meta.name
                    ~target
                    error;
                  Ok
                    (Write_failed
                       { payload =
                           capability_write_error_payload
                             ~target
                             ~created_parents
                             error
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error
                    (Content_write_directory { failed_commit; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_created_directory_commit
                    ~keeper_name:meta.name
                    ~target
                    failed_commit;
                  Ok
                    (Write_failed
                       { payload =
                           created_directory_commit_payload
                             ~target
                             ~created_parents
                             failed_commit
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error (Content_write_append outcome) ->
                  observe_append_write_outcome
                    ~keeper_name:meta.name
                    ~target
                    outcome;
                  Ok
                    (Write_failed
                       { payload = append_write_outcome_payload ~target outcome
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Ok () ->
                  Log.Keeper.info
                    "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=patch replace_all=%b \
                     occurrences=%d bytes=%d"
                    meta.name
                    target
                    replace_all
                    occurrence_count
                    (String.length updated);
                  Ok
                    (Write_succeeded
                       { payload =
                           Yojson.Safe.to_string
                             (`Assoc
                                 ([ "ok", `Bool true
                                  ; "path", `String target
                                  ; "mode", `String "patch"
                                  ; "replace_all", `Bool replace_all
                                  ; "occurrences", `Int occurrence_count
                                  ; "bytes_written", `Int (String.length updated)
                                  ]
                                  @ via_field))
                       ; file_change_evidence =
                           Some
                             (match line_occurrences with
                              | Some occurrences ->
                                Keeper_file_change_evidence.edited occurrences
                              | None ->
                                Keeper_file_change_evidence.edited_ranges_omitted
                                  ~occurrence_count)
                       })
                in
                match
                  Keeper_publication_recovery_availability.with_access
                    publication_recovery
                    (fun publication_recovery_access ->
                       write publication_recovery_access updated)
                with
                | Ok outcome ->
                  finish_recovery_guarded_write
                    ~keeper_name:meta.name
                    ~target
                    ~observe_result:content_write_observation
                    ~finish:finish_write_result
                    outcome
                | Error unavailable ->
                  Ok (publication_recovery_unavailable_attempt unavailable)
              in
              let patch_current
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    current
                    write
                =
                let* (application : Keeper_tool_patch.patch_application) =
                  Keeper_tool_patch.apply_patch ~old_string ~new_string ~replace_all current
                in
                let* projection =
                  Keeper_alerting_path.patch_then_atomic_replace_effect
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    confined
                  |> Result.map_error
                       Keeper_alerting_path.path_effect_projection_error_to_string
                in
                let gate_effect =
                  Keeper_alerting_path.atomic_replace_gate_effect projection
                in
                let recovery_target =
                  Keeper_alerting_path.atomic_replace_recovery_target projection
                in
                finish_write
                  ~gate_effect
                  ~updated:application.updated
                  ~occurrence_count:application.occurrence_count
                  ~line_occurrences:application.line_occurrences
                  (fun publication_recovery_access updated ->
                     write
                       ~recovery_target
                       publication_recovery_access
                       updated)
              in
              let missing_target () =
                Ok
                  (Write_failed
                     { payload =
                         error_json
                           ~fields:[ "path", `String target ]
                           "patch target file does not exist. Use mode=overwrite to create it."
                     ; class_ = Tool_result.Workflow_rejection
                     })
              in
              let run () =
                let* () =
                  check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
                in
                with_confined_write_parent confined
                @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf ->
                if missing_parents <> []
                then missing_target ()
                else
                  let endpoint_components =
                    Keeper_alerting_path.confined_endpoint_components confined
                  in
                  (match split_leaf_components endpoint_components with
                   | None -> Error "filesystem patch source has no readable leaf"
                   | Some (source_parent_components, source_leaf) ->
                     with_open_directory_components
                       ~on_missing:missing_target
                       root_dir
                       source_parent_components
                     @@ fun source_parent_dir ->
                     Eio.Switch.run @@ fun sw ->
                     (match
                        try
                          Ok
                            (Eio.Path.open_in
                               ~sw
                               Eio.Path.(source_parent_dir / source_leaf))
                        with
                        | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
                          Error `Missing
                      with
                      | Error `Missing -> missing_target ()
                      | Ok source_file ->
                        let source_resource = Eio.File.stat source_file in
                        if source_resource.kind <> `Regular_file
                        then
                          Error
                            (Fmt.str
                               "filesystem patch target must resolve to a regular file; found %a"
                               Eio.File.Stat.pp_kind
                               source_resource.kind)
                        else
                          let current = load_open_file source_file in
                          let* result_file_permissions =
                            replacement_file_permissions ~parent_dir ~leaf
                          in
                          let* parent =
                            parent_effect_scope
                              ~parent_dir
                              ~parent_components
                              ~missing_parents:[]
                          in
                          patch_current
                            ~parent
                            ~source_resource
                            ~result_file_permissions
                            current
                            (fun ~recovery_target publication_recovery_access updated ->
                               Fs_compat.replace_capability_file
                                 ~recovery:publication_recovery_access
                                 ~parent:parent_dir
                                 ~target:recovery_target
                                 updated
                               |> Result.map_error (fun error ->
                                 Content_write_capability
                                   { error; created_parents = [] }))))
              in
              (match
                 Keeper_external_resource_lease.with_lease
                   (Keeper_external_resource_lease.File_path target)
                   run
               with
               | Ok attempt -> file_write_attempt_to_execution attempt
               | Error msg ->
                 Keeper_tool_execution.failure
                   (error_json ~fields:[ "path", `String target ] msg)))
    | Ok Overwrite ->
      handle_atomic_content_write
        ~mode:Overwrite
        ~make_effect:Keeper_alerting_path.atomic_replace_effect
    | Ok Append -> handle_append ()
  )
;;

module For_testing = struct
  type created_directory_fault_stage =
    | Before_create_directory
    | Before_inspect_created_directory
    | Before_apply_directory_permissions

  type created_directory_fault = created_directory_dispatch_fault

  let created_directory_fault ~stage ~exception_ =
    let fault_stage =
      match stage with
      | Before_create_directory -> Create_directory
      | Before_inspect_created_directory -> Inspect_created_directory
      | Before_apply_directory_permissions -> Apply_directory_permissions
    in
    { fault_stage; fault_exception = exception_ }
  ;;

  let with_created_directory_fault fault f =
    Eio.Fiber.with_binding created_directory_dispatch_fault_key fault f
  ;;
end
