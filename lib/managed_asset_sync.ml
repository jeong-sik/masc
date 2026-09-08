(* See managed_asset_sync.mli. Machinery moved out of Prompt_defaults
   (#20929) and parameterized over the embedded subtree it owns. *)

type domain =
  | Prompts
  | Tools
  | Mcp

let prefix = function
  | Prompts -> "prompts/"
  | Tools -> "tools/"
  | Mcp -> "mcp/"
;;

(* One schema string per domain, written into the runtime manifest so a
   reader of the runtime directory can tell which domain owns it. *)
let manifest_schema = function
  | Prompts -> "masc.prompt-managed-assets.v1"
  | Tools -> "masc.tool-managed-assets.v1"
  | Mcp -> "masc.mcp-managed-assets.v1"
;;

(* The noun used in operator-facing error messages. *)
let noun = function
  | Prompts -> "prompt"
  | Tools -> "tool"
  | Mcp -> "mcp"
;;

(* The runtime manifest, named the way the domain sees it. It is the only
   manifest there is: no source file declares the managed set (#31283), the
   embedded tree is the set, and this file is the sync's record of it. *)
let manifest_path domain = prefix domain ^ "managed-assets.json"

module String_set = Set.Make (String)

type sync_result =
  { copied : string list
  ; overwritten : string list
  ; removed : string list
  ; failed : (string * string) list
  }

let read_file_opt = Fs_compat.load_file_opt

let relative_asset_path rel =
  let parts = String.split_on_char '/' rel in
  rel <> ""
  && Filename.is_relative rel
  && List.for_all (fun part -> part <> "" && part <> "." && part <> "..") parts
;;

let runtime_manifest_content ~domain current =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [ "managed_by", `String "MASC"
       ; "schema", `String (manifest_schema domain)
       ; "paths", `List (List.map (fun rel -> `String rel) (String_set.elements current))
       ])
  ^ "\n"
;;

(* The paths the previous pass recorded as this distribution's. What a pass
   may delete is drawn from here, never from the directory listing: a file
   the operator put beside the managed ones was in no manifest, so it is
   not masc's to remove, and the registry reads it like any other prompt.
   No manifest means no owned paths, so a first pass deletes nothing. A
   manifest that does not read, or that another domain wrote, is reported
   and also yields nothing to delete. *)
let previously_owned ~domain ~dest_dir =
  let path = Filename.concat dest_dir "managed-assets.json" in
  match read_file_opt path with
  | None -> Ok String_set.empty
  | Some content ->
    (match Yojson.Safe.from_string content with
     | exception Yojson.Json_error message ->
       Error (Printf.sprintf "runtime manifest is not JSON: %s" message)
     | `Assoc fields ->
       (match List.assoc_opt "schema" fields, List.assoc_opt "paths" fields with
        | Some (`String schema), _ when not (String.equal schema (manifest_schema domain)) ->
          Error
            (Printf.sprintf
               "runtime manifest schema %S is not %S"
               schema
               (manifest_schema domain))
        | Some (`String _), Some (`List paths) ->
          List.fold_left
            (fun acc entry ->
              match acc, entry with
              | Error _, _ -> acc
              | Ok owned, `String rel when relative_asset_path rel ->
                Ok (String_set.add rel owned)
              | Ok _, `String rel ->
                Error (Printf.sprintf "runtime manifest lists an unsafe path: %s" rel)
              | Ok _, _ -> Error "runtime manifest paths must be strings")
            (Ok String_set.empty)
            paths
        | _ -> Error "runtime manifest lacks a schema string or a paths list")
     | _ -> Error "runtime manifest must be a JSON object")
;;

let current_assets ~domain files =
  let asset_prefix = prefix domain in
  let prefix_len = String.length asset_prefix in
  List.filter_map
    (fun rel ->
      if not (String.starts_with ~prefix:asset_prefix rel)
      then None
      else Some (rel, String.sub rel prefix_len (String.length rel - prefix_len)))
    files
;;

let owned_parent_state ~dest_dir dest =
  let parent = Filename.dirname dest in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:dest_dir parent with
  | Error rejection ->
    Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
  | Ok Fs_compat.Owned_directory_missing -> Ok `Missing
  | Ok (Fs_compat.Owned_directory _) -> Ok `Directory
;;

let prepare_owned_parent ~domain ~dest_dir dest =
  match owned_parent_state ~dest_dir dest with
  | Error _ as error -> error
  | Ok `Directory -> Ok ()
  | Ok `Missing ->
    Fs_compat.mkdir_p (Filename.dirname dest);
    (match owned_parent_state ~dest_dir dest with
     | Ok `Directory -> Ok ()
     | Ok `Missing ->
       Error
         (Printf.sprintf
            "managed %s asset parent remained missing after creation"
            (noun domain))
     | Error _ as error -> error)
;;

let writable_leaf_state ~domain dest =
  match Fs_compat.exact_path_kind ~follow:false dest with
  | Fs_compat.Exact_missing -> Ok `Missing
  | Fs_compat.Exact_kind Unix.S_REG -> Ok `Regular
  | Fs_compat.Exact_kind Unix.S_LNK -> Ok `Symlink
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
    Error
      (Printf.sprintf "managed %s asset leaf is not a regular file" (noun domain))
;;

let remove_runtime_asset ~domain ~dest_dir runtime_rel acc =
  let embedded_rel = prefix domain ^ runtime_rel in
  let dest = Filename.concat dest_dir runtime_rel in
  try
    match owned_parent_state ~dest_dir dest with
    | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
    | Ok `Missing -> acc
    | Ok `Directory ->
      (match Fs_compat.exact_path_kind ~follow:false dest with
       | Fs_compat.Exact_missing -> acc
       | Fs_compat.Exact_kind Unix.S_REG
       | Fs_compat.Exact_kind Unix.S_LNK ->
         Sys.remove dest;
         { acc with removed = embedded_rel :: acc.removed }
       | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
         { acc with
           failed =
             ( embedded_rel
             , Printf.sprintf
                 "managed %s asset leaf is neither a regular file nor a symbolic link"
                 (noun domain) )
             :: acc.failed
         })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
  | Unix.Unix_error (error, operation, argument) ->
    { acc with
      failed =
        ( embedded_rel
        , Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error) )
        :: acc.failed
    }
;;

let write_runtime_manifest ~domain ~dest_dir content acc =
  let dest = Filename.concat dest_dir "managed-assets.json" in
  try
    match prepare_owned_parent ~domain ~dest_dir dest with
    | Error msg -> { acc with failed = (manifest_path domain, msg) :: acc.failed }
    | Ok () ->
      (match writable_leaf_state ~domain dest with
       | Error msg -> { acc with failed = (manifest_path domain, msg) :: acc.failed }
       | Ok _ ->
         (match read_file_opt dest with
          | Some current when String.equal current content -> acc
          | _ ->
            (match Fs_compat.save_file_atomic dest content with
             | Ok () -> acc
             | Error msg ->
               { acc with failed = (manifest_path domain, msg) :: acc.failed })))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> { acc with failed = (manifest_path domain, msg) :: acc.failed }
  | Unix.Unix_error (error, operation, argument) ->
    { acc with
      failed =
        ( manifest_path domain
        , Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error) )
        :: acc.failed
    }
;;

let runtime_asset_paths ~domain ~dest_dir =
  let rec collect relative acc =
    let path =
      if String.equal relative "" then dest_dir else Filename.concat dest_dir relative
    in
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path
      |> Array.to_list
      |> List.sort String.compare
      |> List.fold_left
           (fun result name ->
             match result with
             | Error _ as error -> error
             | Ok acc ->
               let child =
                 if String.equal relative "" then name else Filename.concat relative name
               in
               collect child acc)
           (Ok acc)
    | { Unix.st_kind = Unix.S_REG | Unix.S_LNK; _ } ->
      if String.equal relative "managed-assets.json"
      then Ok acc
      else if relative_asset_path relative
      then Ok (String_set.add relative acc)
      else
        Error
          (Printf.sprintf "unsafe runtime %s asset path: %s" (noun domain) relative)
    | { Unix.st_kind = Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
      Error
        (Printf.sprintf "runtime %s asset is not a file: %s" (noun domain) relative)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) when String.equal relative "" ->
      Ok acc
    | exception Unix.Unix_error (error, operation, argument) ->
      Error (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
  in
  collect "" String_set.empty
;;

let sync_current_asset ~domain ~read ~dest_dir acc (embedded_rel, runtime_rel) =
  if not (relative_asset_path runtime_rel)
  then
    { acc with
      failed =
        ( embedded_rel
        , Printf.sprintf "unsafe embedded %s asset path" (noun domain) )
        :: acc.failed
    }
  else (
    match read embedded_rel with
    | None ->
      { acc with failed = (embedded_rel, "embedded asset unreadable") :: acc.failed }
    | Some content ->
      let dest = Filename.concat dest_dir runtime_rel in
      (try
         match prepare_owned_parent ~domain ~dest_dir dest with
         | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
         | Ok () ->
           (match writable_leaf_state ~domain dest with
            | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
            | Ok ((`Missing | `Regular | `Symlink) as leaf_state) ->
              let existing = read_file_opt dest in
              (match existing with
               | Some current when String.equal current content -> acc
               | _ ->
                 (match Fs_compat.save_file_atomic dest content with
                  | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
                  | Ok () ->
                    if leaf_state = `Missing
                    then { acc with copied = embedded_rel :: acc.copied }
                    else { acc with overwritten = embedded_rel :: acc.overwritten })))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | Sys_error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
       | Unix.Unix_error (error, operation, argument) ->
         { acc with
           failed =
             ( embedded_rel
             , Printf.sprintf
                 "%s(%s): %s"
                 operation
                 argument
                 (Unix.error_message error) )
             :: acc.failed
         }))
;;

let sync ~domain ~read ~files ~dest_dir () =
  let assets = current_assets ~domain files in
  let initial = { copied = []; overwritten = []; removed = []; failed = [] } in
  let current =
    List.fold_left (fun acc (_, rel) -> String_set.add rel acc) String_set.empty assets
  in
  let invalid_paths =
    List.filter_map
      (fun (embedded_rel, runtime_rel) ->
        if relative_asset_path runtime_rel then None
        else
          Some
            ( embedded_rel
            , Printf.sprintf "unsafe embedded %s asset path" (noun domain) ))
      assets
  in
  (* The embedded tree is the managed set. Until #31283 a hand-written
     [managed-assets.json] beside the assets declared the same list a second
     time, and five releases in a row shipped with a file on one side and not
     the other -- the boot then refused the domain and every asset added
     since stayed out of the runtime directory. With one source there is
     nothing to disagree with.

     What that comparison also caught was an empty embedded set: a crunch
     step that lost the tree. Without a second list that case is caught on
     its own, and refused, because every domain ships assets and projecting
     an empty set would delete the operator's whole runtime directory. *)
  (* Validate the complete authority set before removing absent runtime files
     or writing even a valid asset that precedes an invalid one. *)
  if invalid_paths <> [] then { initial with failed = invalid_paths }
  else if String_set.is_empty current
  then
    { initial with
      failed =
        [ ( prefix domain
          , Printf.sprintf
              "embedded %s asset set is empty; refusing to project an empty tree"
              (noun domain) )
        ]
    }
  else (
    match runtime_asset_paths ~domain ~dest_dir with
    | Error msg -> { initial with failed = [ prefix domain, msg ] }
    | Ok runtime ->
      let owned_before, manifest_failure =
        match previously_owned ~domain ~dest_dir with
        | Ok owned -> owned, []
        | Error msg -> String_set.empty, [ manifest_path domain, msg ]
      in
      (* Retired: recorded as masc's by the previous pass and no longer
         shipped. The listing only says which of those are still here. *)
      let removable = String_set.inter runtime (String_set.diff owned_before current) in
      let purged =
        String_set.fold
          (remove_runtime_asset ~domain ~dest_dir)
          removable
          { initial with failed = manifest_failure }
      in
      List.fold_left (sync_current_asset ~domain ~read ~dest_dir) purged assets
      |> write_runtime_manifest
           ~domain
           ~dest_dir
           (runtime_manifest_content ~domain current))
;;

(* Two lines, two budgets. The bootstrap used to concatenate copied,
   overwritten and removed into one sample and cut it at ten: a version bump
   copies enough assets to fill that sample on its own, so the removed paths
   never reached the line and the operator got a count with no names. A
   removal is a distribution asset retiring, and the name is what tells the
   operator which one. *)
let sample_budget = 10

let sample paths =
  let rec take n = function
    | [] -> []
    | _ when n = 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let shown = take sample_budget paths in
  let omitted = List.length paths - List.length shown in
  ( String.concat ", " shown
  , if omitted > 0 then Printf.sprintf ", and %d more" omitted else "" )
;;

(* Overwritten carries names, copied does not, and the asymmetry is the
   point. A copy is a file the operator never had; a version bump makes
   dozens and the paths say nothing they wanted to know. An overwrite is a
   file that was already there and differed, which for these three domains
   means one thing: somebody edited it and the edit is now gone. That is the
   same reason [removed] was given names -- an operator's file disappearing
   is the whole message, and a count cannot deliver it.

   [prompts/keeper.md] is the case this was written for. It is 23 KB of
   system prompt sitting in the operator's own config root beside
   runtime.toml, at the same permissions, with nothing in the file or its
   name to say masc converges it. An operator who edits it gets it back from
   the binary at the next boot and, before this line, "1 overwritten". *)
let distribution_line ~label result =
  match result.copied, result.overwritten with
  | [], [] -> None
  | copied, overwritten ->
    let named =
      match overwritten with
      | [] -> ""
      | paths ->
        let shown, more = sample paths in
        Printf.sprintf " (%s%s)" shown more
    in
    Some
      (Printf.sprintf
         "%s assets synced from binary: %d copied, %d overwritten%s"
         label
         (List.length copied)
         (List.length overwritten)
         named)
;;

let removed_line ~label result =
  match result.removed with
  | [] -> None
  | removed ->
    let shown, more = sample removed in
    Some
      (Printf.sprintf
         "%s assets retired from the runtime directory (recorded by the \
          previous sync, no longer embedded): %s%s"
         label
         shown
         more)
;;
