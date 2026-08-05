(** See [verification_authority_tools.mli]. *)

(* Bounds. Both are limits on how much one tool call may return, not policy
   about what the judge may look at: the judge can page through a directory by
   naming subdirectories, and can ask for a shorter log. *)
let max_directory_entries = 200
let max_git_log_commits = 50

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | List_dir
  | Git_status
  | Git_log

let tool_name = function
  | Read_file -> "verification_read_file"
  | List_dir -> "verification_list_dir"
  | Git_status -> "verification_git_status"
  | Git_log -> "verification_git_log"
;;

let all_tools = [ Read_file; List_dir; Git_status; Git_log ]

let tool_of_name name =
  List.find_opt (fun tool -> String.equal (tool_name tool) name) all_tools
;;

type t = { ownership_root : string }

let create ~base_path ~producer =
  let project_root = Workspace_verification_store.project_root_of_base_path base_path in
  let ownership_root =
    Keeper_sandbox_config.host_root_abs_of_agent ~base_path:project_root
      ~agent_name:producer
    |> Env_config_core.strip_trailing_slashes
  in
  { ownership_root }
;;

let ownership_root t = t.ownership_root

(* A producer-relative path becomes an absolute one by folding its segments
   onto the ownership root. Empty segments are dropped so ["a//b"] and ["a/b"]
   name the same file and [""] names the root itself. [.] and [..] are left
   alone here on purpose: [Fs_compat]'s ownership chain already refuses them,
   and a second refusal in this module would be a second place to keep the
   containment rule correct. *)
let absolute_of_relative t relative =
  String.split_on_char '/' relative
  |> List.filter (fun segment -> not (String.equal segment ""))
  |> List.fold_left Filename.concat t.ownership_root
;;

let relative_of_absolute t absolute =
  let root_length = String.length t.ownership_root in
  if
    String.length absolute > root_length
    && String.equal (String.sub absolute 0 root_length) t.ownership_root
  then String.sub absolute (root_length + 1) (String.length absolute - root_length - 1)
  else absolute
;;

(* ================================================================ *)
(* Schemas                                                          *)
(* ================================================================ *)

let path_property description =
  ( "path"
  , `Assoc [ "type", `String "string"; "description", `String description ] )
;;

let schema_of_tool tool : Types_core.tool_schema =
  match tool with
  | Read_file ->
    { name = tool_name Read_file
    ; description =
        "Read a file from the producer's tree. The path is relative to the \
         producer's root, the same way an artifact: evidence reference is. Reads \
         the same byte prefix the evidence snapshot reads, so a file that was \
         truncated in the snapshot is truncated here too."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ path_property
                    "Producer-relative file path, for example \
                     \"lib/keeper/keeper_turn.ml\"."
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  | List_dir ->
    { name = tool_name List_dir
    ; description =
        Printf.sprintf
          "List one directory in the producer's tree. Returns at most %d entries, \
           each marked as a file or a directory. Use \"\" for the producer's root."
          max_directory_entries
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ path_property
                    "Producer-relative directory path. \"\" is the producer's root."
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
  | Git_status ->
    { name = tool_name Git_status
    ; description =
        "Report whether the producer's tree has uncommitted changes, as git \
         porcelain-v1 lines. An approved change that appears only here and not in \
         the log exists solely in a working tree."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  | Git_log ->
    { name = tool_name Git_log
    ; description =
        Printf.sprintf
          "List the producer's most recent commits as \"HASH subject\" lines. \
           limit is capped at %d."
          max_git_log_commits
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            (Printf.sprintf "How many commits to list (1 to %d)."
                               max_git_log_commits) )
                      ] )
                ] )
          ; "required", `List [ `String "limit" ]
          ]
    }
;;

let schemas _t = List.map schema_of_tool all_tools

(* ================================================================ *)
(* Implementations                                                  *)
(* ================================================================ *)

let read_file t ~relative =
  let target = absolute_of_relative t relative in
  match Workspace_verification_store.read_regular_file_prefix ~ownership_root:t.ownership_root target with
  | Error failure ->
    Error
      (Printf.sprintf "%s: %s" relative
         (Workspace_verification_store.evidence_read_failure_code failure))
  | Ok (content, bytes, truncated) ->
    Ok
      (Printf.sprintf "%s (%d bytes%s)\n%s" relative bytes
         (if truncated then ", truncated" else "")
         content)
;;

let entry_line t ~directory ~name =
  let absolute = Filename.concat directory name in
  let kind =
    match Unix.lstat absolute with
    | stat -> Fs_compat.file_kind_to_string stat.Unix.st_kind
    | exception Unix.Unix_error (error, _, _) ->
      Printf.sprintf "unreadable(%s)" (Unix.error_message error)
  in
  Printf.sprintf "%s\t%s" kind (relative_of_absolute t absolute)
;;

let list_dir t ~relative =
  let target = absolute_of_relative t relative in
  match
    Fs_compat.inspect_owned_directory_chain ~ownership_root:t.ownership_root target
  with
  | Error rejection ->
    Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
  | Ok Fs_compat.Owned_directory_missing ->
    Error (Printf.sprintf "%s: directory does not exist" relative)
  | Ok (Fs_compat.Owned_directory _) ->
    let entries = Fs_compat.read_dir target in
    let total = List.length entries in
    let shown = List.filteri (fun index _ -> index < max_directory_entries) entries in
    let lines = List.map (fun name -> entry_line t ~directory:target ~name) shown in
    let header =
      if total > max_directory_entries
      then
        Printf.sprintf "%d entries, showing the first %d" total max_directory_entries
      else Printf.sprintf "%d entries" total
    in
    Ok (String.concat "\n" (header :: lines))
;;

(* Read-only git, expressed as fixed argv. The evaluator supplies no
   subcommand, so a mutating one is not rejected — there is no argument that
   could carry it. [--no-optional-locks] keeps a concurrent keeper's index from
   being touched by a review. *)
let run_read_only_git t arguments =
  match Repo_git.run_git ~cwd:t.ownership_root ("--no-optional-locks" :: arguments) with
  | Error detail -> Error detail
  | Ok [] -> Ok "(no output)"
  | Ok lines -> Ok (String.concat "\n" lines)
;;

let git_status t = run_read_only_git t [ "status"; "--porcelain=v1" ]

let git_log t ~limit =
  if limit < 1 || limit > max_git_log_commits
  then
    Error
      (Printf.sprintf "limit must be between 1 and %d, got %d" max_git_log_commits limit)
  else
    run_read_only_git t [ "log"; "--oneline"; "--no-decorate"; "-n"; string_of_int limit ]
;;

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

let dispatch t ~name ~args =
  match tool_of_name name with
  | None ->
    Error
      (Printf.sprintf "unknown tool %s; this review offers %s" name
         (String.concat ", " (List.map tool_name all_tools)))
  | Some Read_file ->
    (match Json_util.require_string args "path" with
     | Error detail -> Error detail
     | Ok relative -> read_file t ~relative)
  | Some List_dir ->
    (match Json_util.require_string args "path" with
     | Error detail -> Error detail
     | Ok relative -> list_dir t ~relative)
  | Some Git_status -> git_status t
  | Some Git_log ->
    (match Json_util.require_int args "limit" with
     | Error detail -> Error detail
     | Ok limit -> git_log t ~limit)
;;
