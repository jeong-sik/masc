(** See [verification_authority_tools.mli]. *)

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | Git_status

let tool_name = function
  | Read_file -> "verification_read_file"
  | Git_status -> "verification_git_status"
;;

let all_tools = [ Read_file; Git_status ]

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

(* ================================================================ *)
(* Schemas                                                          *)
(* ================================================================ *)

let path_property description =
  ( "path"
  , `Assoc [ "type", `String "string"; "description", `String description ] )
;;

let schema_of_tool tool : Types_core.tool_schema =
  match tool with
  | Git_status ->
    { name = tool_name Git_status
    ; description =
        "Report which files in the producer's checkout differ from the last \
         commit. Answers whether the work under review reached a commit or only \
         exists in a working tree that the next task can discard. The evidence \
         snapshot cannot answer this: it records file contents at submission, \
         not whether those contents are durable."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ path_property
                    "Producer-relative path of the checkout to inspect, for \
                     example \"masc\". Use \"\" for the producer root itself."
                ] )
          ; "required", `List [ `String "path" ]
          ]
    }
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

(* The argv is a constant. The model supplies a directory to run in and nothing
   else, so a write subcommand is not something this tool rejects — it is
   something the tool cannot express. An argv whitelist would put the same
   guarantee behind a string comparison that has to stay correct as Git grows
   subcommands; this way the type of the input is a path. *)
let git_status_argv = [ "--no-optional-locks"; "status"; "--porcelain=v1" ]

(* [Repo_git.run_git] drops blank lines, so an empty result and a clean tree
   are the same list. Saying "clean" is a claim about the tree; the caller has
   to be able to tell that from a Git invocation that returned nothing because
   it failed, and [run_git] already separates those into [Error]. *)
let git_status t ~relative =
  let target = absolute_of_relative t relative in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:t.ownership_root target with
  | Error rejection ->
    Error
      (Printf.sprintf "%s: %s"
         (if String.equal relative "" then "." else relative)
         (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok Fs_compat.Owned_directory_missing ->
    Error
      (Printf.sprintf "%s: no such directory in the producer's tree"
         (if String.equal relative "" then "." else relative))
  | Ok (Fs_compat.Owned_directory _) ->
    (match Repo_git.run_git ~cwd:target git_status_argv with
     | Error message -> Error (Printf.sprintf "%s: %s" relative message)
     | Ok [] ->
       Ok
         (Printf.sprintf
            "%s: working tree clean — every tracked change is committed"
            (if String.equal relative "" then "." else relative))
     | Ok lines ->
       Ok
         (Printf.sprintf
            "%s: %d path(s) differ from the last commit\n%s"
            (if String.equal relative "" then "." else relative)
            (List.length lines)
            (String.concat "\n" lines)))
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
    (* The tool addresses the producer's tree by a [path] argument. The match
       on [tool] stays exhaustive, so a new tool with a different input fails
       to compile here rather than silently reading a missing key. *)
    (match Json_util.require_string args "path" with
     | Error detail ->
       log_lookup t ~name ~argument:"" ~outcome:Invalid_argument;
       Error detail
     | Ok relative ->
       let result =
         match tool with
         | Read_file -> read_file t ~relative
         | Git_status -> git_status t ~relative
       in
       log_lookup t ~name ~argument:relative
         ~outcome:(match result with Ok _ -> Resolved | Error _ -> Rejected);
       result)
;;
