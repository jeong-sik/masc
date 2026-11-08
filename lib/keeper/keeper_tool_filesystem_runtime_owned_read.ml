open Keeper_tool_shared_runtime
open Result.Syntax
open Keeper_tool_read_window
open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared
open Keeper_tool_filesystem_runtime_read

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
    (* An unreadable directory is an empty one for this walk; a cancelled
       fiber is not, and a wildcard here answered [[]] for both. *)
    | exception (Eio.Cancel.Cancelled _ as error) -> raise error
    | exception _ -> []
  in
  let subdirs_of ~root ~skip =
    List.filter
      (fun name ->
        let p = Filename.concat root name in
        Sys.is_directory p && not (String.equal name skip))
      (entries ~root)
  in
  let strip_prefix prefix p =
    let plen = String.length prefix in
    if String.length p > plen
       && String.starts_with ~prefix p
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

(* A refusal names the caller's path or cwd: an empty path, or a cwd outside
   the ownership root, not a directory, or missing. With no cwd the directory
   is the default this module picked, so its absence is not the caller's. *)
let resolve_owned_read_target ~ownership_root ~path ~cwd =
  if String.equal path ""
  then Error (Keeper_alerting_path.refusal_of_rejection Keeper_alerting_path.Path_required)
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
      let reason =
        match cwd with
        | Some _ -> Keeper_alerting_path.Caller_cwd_rejected rejection
        | None -> Keeper_alerting_path.Default_cwd_rejected rejection
      in
      Error (Keeper_alerting_path.owned_read_target_refusal reason)
    | Ok Fs_compat.Owned_directory_missing ->
      let reason =
        match cwd with
        | Some _ -> Keeper_alerting_path.Caller_cwd_missing { cwd = cwd_abs }
        | None -> Keeper_alerting_path.Default_cwd_missing { cwd = cwd_abs }
      in
      Error (Keeper_alerting_path.owned_read_target_refusal reason)
    | Ok (Fs_compat.Owned_directory _) ->
      let target =
        if Filename.is_relative target_rel
        then Filename.concat cwd_abs target_rel
        else target_rel
      in
      Ok target
;;

let read_owned_bytes ~ownership_root ~path ?cwd ~max_bytes () =
  let* target =
    resolve_owned_read_target ~ownership_root ~path ~cwd
    |> Result.map_error (fun (refusal : Keeper_alerting_path.path_refusal) -> refusal.message)
  in
  match Fs_compat.load_owned_regular_file_prefix ~ownership_root ~max_bytes target with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok None -> Error "owned file is missing"
  | Ok (Some prefix) -> Ok prefix.content
;;

(* A path that crosses the ownership boundary or names no regular file is the
   caller's to correct; a file that changed under the read or an I/O error is
   the runtime's. *)
let owned_read_failure_class (error : Fs_compat.owned_regular_file_read_error) =
  match error.failure with
  | Fs_compat.Ownership_boundary_rejected _ | Fs_compat.Path_is_not_regular_file _
     | Fs_compat.Owned_path_owner_mismatch _
     | Fs_compat.Owned_path_writable_by_others _ ->
    Tool_result.Policy_rejection
  | Fs_compat.Filesystem_identity_changed _ | Fs_compat.Owned_file_operation_failed _ ->
    Tool_result.Runtime_failure
;;

let handle_owned_read_file_with_outcome
      ~ownership_root
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  let max_bytes = read_file_default_max_bytes in
  let cwd = string_opt_nonempty "cwd" args in
  let read_target =
    let* window = read_line_window_of_args args |> Result.map_error (fun e -> `Window e) in
    let* target = resolve_owned_read_target ~ownership_root ~path ~cwd
      |> Result.map_error (fun refusal -> `Path refusal) in
    Ok (window, target)
  in
  match read_target with
  | Error (`Window window_error) ->
    Keeper_tool_execution.failure ~class_:Tool_result.Policy_rejection (error_json window_error)
  | Error (`Path (refusal : Keeper_alerting_path.path_refusal)) ->
    Keeper_tool_execution.failure ~class_:refusal.failure_class (error_json refusal.message)
  | Ok (window, target) ->
    let fetch_bytes = read_window_fetch_bytes ~max_bytes window in
    (match
       Fs_compat.load_owned_regular_file_prefix
         ~ownership_root
         ~max_bytes:fetch_bytes
         target
     with
     | Error error ->
       Keeper_tool_execution.failure
         ~class_:(owned_read_failure_class error)
         (error_json
            ~fields:[ "path", `String target ]
            (Fs_compat.owned_regular_file_read_error_to_string error))
     | Ok None ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Policy_rejection
         (missing_file_error_json
            ~cwd
            ~raw_path:(Some path)
            ~target
            ~error:"owned file is missing")
     | Ok (Some prefix) ->
       (match
          slice_read_window
            ~window
            ~first_line:1
            ~max_bytes
            ~scan_complete:(not prefix.truncated)
            prefix.content
        with
        (* Only a truncated prefix gets here: a complete scan turns a line past
           EOF into an empty window. The line may exist past the prefix, and no
           offset the caller picks reaches it (#38609). *)
        | Error `Offset_beyond_scan ->
          Keeper_tool_execution.failure
            ~class_:Tool_result.Runtime_failure
            (error_json
               ~fields:
                 [ "path", `String target
                 ; "offset", `Int window.start_line
                 ]
               (fs_guidance_text
                  (Offset_beyond_window
                     { offset = window.start_line
                     ; window_bytes = String.length prefix.content
                     })))
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
          Keeper_tool_execution.success_data
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
                 @ optional_fields))))
;;
