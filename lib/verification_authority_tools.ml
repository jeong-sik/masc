(** See [verification_authority_tools.mli]. *)

(* How many entries one listing may return. A bound on the answer, not on what
   the judge may look at: deeper paths are reached by naming a subdirectory. *)
let max_directory_entries = 200

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | List_dir

let tool_name = function
  | Read_file -> "verification_read_file"
  | List_dir -> "verification_list_dir"
;;

let all_tools = [ Read_file; List_dir ]

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
    (* The chain check and the read are two syscalls, so the directory can
       become unreadable in between, and a subdirectory the producer created
       unreadable fails here too. Either way the judge gets a tool error it can
       route around; letting the exception out would abort the whole review
       over one unreadable directory. *)
    (match Fs_compat.read_dir target with
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       Error (Printf.sprintf "%s: %s" relative (Printexc.to_string exn))
     | entries ->
    let total = List.length entries in
    let shown = List.filteri (fun index _ -> index < max_directory_entries) entries in
    let lines = List.map (fun name -> entry_line t ~directory:target ~name) shown in
    let header =
      if total > max_directory_entries
      then
        Printf.sprintf "%d entries, showing the first %d" total max_directory_entries
      else Printf.sprintf "%d entries" total
    in
    Ok (String.concat "\n" (header :: lines)))
;;

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(* How one lookup ended. A closed sum rather than a string because the log
   level is derived from it: a rejected lookup reported at the same level as a
   resolved one is invisible in exactly the case an operator needs to see. *)
type lookup_outcome =
  | Resolved
  | Rejected
  | Unknown_tool
  | Invalid_argument

let lookup_outcome_label = function
  | Resolved -> "resolved"
  | Rejected -> "rejected"
  | Unknown_tool -> "unknown_tool"
  | Invalid_argument -> "invalid_argument"
;;

let lookup_outcome_level = function
  | Resolved -> Log.Info
  | Rejected | Unknown_tool | Invalid_argument -> Log.Warn
;;

(* What the judge looked at, and whether it got an answer. An operator reading
   the logs otherwise cannot tell a review that inspected the tree from one that
   only read the submitted snapshot, and that difference is the whole point of
   this surface. Content is never logged — only the path asked for, which is
   already the model's own argument. *)
let log_lookup t ~name ~argument ~outcome =
  Log.Task.emit
    (lookup_outcome_level outcome)
    (Printf.sprintf
       "[verification-lookup] tool=%s root=%s argument=%s outcome=%s"
       name
       t.ownership_root
       argument
       (lookup_outcome_label outcome))
;;

let dispatch t ~name ~args =
  match tool_of_name name with
  | None ->
    let detail =
      Printf.sprintf "unknown tool %s; this review offers %s" name
        (String.concat ", " (List.map tool_name all_tools))
    in
    log_lookup t ~name ~argument:"" ~outcome:Unknown_tool;
    Error detail
  | Some tool ->
    (* Both tools address the producer's tree by the same [path] argument. The
       match on [tool] stays exhaustive, so a tool that takes something else
       fails to compile here rather than silently reading a missing key. *)
    (match Json_util.require_string args "path" with
     | Error detail ->
       log_lookup t ~name ~argument:"" ~outcome:Invalid_argument;
       Error detail
     | Ok relative ->
       let result =
         match tool with
         | Read_file -> read_file t ~relative
         | List_dir -> list_dir t ~relative
       in
       log_lookup t ~name ~argument:relative
         ~outcome:(match result with Ok _ -> Resolved | Error _ -> Rejected);
       result)
;;
