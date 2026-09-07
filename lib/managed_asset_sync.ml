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

(* One schema string per domain: a tools manifest pasted into prompts/ (or
   the other way around) is a validation error, not a silent sync. *)
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

let managed_asset_paths ~domain content =
  try
    match Yojson.Safe.from_string content with
    | `Assoc fields ->
      (match List.assoc_opt "schema" fields, List.assoc_opt "paths" fields with
       | Some (`String schema), Some (`List values)
         when String.equal schema (manifest_schema domain) ->
         let rec collect seen = function
           | [] -> Ok seen
           | `String rel :: rest when relative_asset_path rel ->
             if String_set.mem rel seen
             then
               Error
                 (Printf.sprintf "duplicate managed %s asset: %s" (noun domain) rel)
             else collect (String_set.add rel seen) rest
           | `String rel :: _ ->
             Error
               (Printf.sprintf "unsafe managed %s asset path: %s" (noun domain) rel)
           | _ ->
             Error
               (Printf.sprintf "managed %s asset paths must be strings" (noun domain))
         in
         collect String_set.empty values
       | Some (`String schema), _ ->
         Error
           (Printf.sprintf
              "unsupported managed %s asset schema: %s"
              (noun domain)
              schema)
       | _ ->
         Error
           (Printf.sprintf
              "managed %s asset manifest is missing schema or paths"
              (noun domain)))
    | _ ->
      Error
        (Printf.sprintf
           "managed %s asset manifest must be a JSON object"
           (noun domain))
  with
  | Yojson.Json_error msg ->
    Error (Printf.sprintf "invalid managed %s asset manifest: %s" (noun domain) msg)
;;

let current_assets ~domain files =
  let asset_prefix = prefix domain in
  let prefix_len = String.length asset_prefix in
  List.filter_map
    (fun rel ->
      if String.equal rel (manifest_path domain)
         || not (String.starts_with ~prefix:asset_prefix rel)
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
  match read (manifest_path domain) with
  | None ->
    { initial with
      failed = [ manifest_path domain, "embedded managed-assets manifest unreadable" ]
    }
  | Some content ->
    (match managed_asset_paths ~domain content with
     | Error msg -> { initial with failed = [ manifest_path domain, msg ] }
     | Ok managed ->
       let current =
         List.fold_left
           (fun acc (_, rel) -> String_set.add rel acc)
           String_set.empty
           assets
       in
       (* An empty embedded set with a non-empty manifest means the crunch
          step lost the tree; an empty set with an empty manifest is the
          valid state of a domain before its first migrated asset. *)
       if String_set.is_empty current && not (String_set.is_empty managed)
       then
         { initial with
           failed =
             [ ( manifest_path domain
               , Printf.sprintf "embedded %s asset set is empty" (noun domain) )
             ]
         }
       else (
         let missing = String_set.diff current managed in
         let extra = String_set.diff managed current in
         if not (String_set.is_empty missing && String_set.is_empty extra)
         then (
           (* Both sides live inside this binary: [current] is what the crunch
              step embedded, [managed] is what the embedded manifest declares.
              They disagree two ways. A half-built binary is one. The other,
              and the one that actually happens, is a source tree whose
              manifest was not updated alongside the asset: then the binary is
              built correctly and rebuilding reproduces the same mismatch.
              Measured 2026-09-06 -- #33472 and #33639 each added tool TOMLs
              without their manifest line, and every boot since told an
              operator to rebuild, which could not have worked. So name both
              directions and both remedies. The previous wording ("manifest differs
              from current assets") left the reader to guess whether the
              runtime directory, the source tree, or the build was at fault;
              one 2026-08-25 recovery attempt spent half an hour on that
              guess while the server stayed down. *)
           let render set =
             if String_set.is_empty set
             then "(none)"
             else String.concat ", " (String_set.elements set)
           in
           { initial with
             failed =
               [ ( manifest_path domain
                 , Printf.sprintf
                     "the embedded %s set and its %s do not match. Either the \
                      manifest is missing a line for the asset beside it (edit %s \
                      and rebuild), or this binary is half-built (rebuild). \
                      Embedded but unlisted: %s. Listed but not embedded: %s."
                     (noun domain)
                     (manifest_path domain)
                     (manifest_path domain)
                     (render missing)
                     (render extra) )
               ]
           })
         else (
           match runtime_asset_paths ~domain ~dest_dir with
           | Error msg -> { initial with failed = [ manifest_path domain, msg ] }
           | Ok runtime ->
             let removable = String_set.diff runtime current in
             let purged =
               String_set.fold (remove_runtime_asset ~domain ~dest_dir) removable initial
             in
             List.fold_left (sync_current_asset ~domain ~read ~dest_dir) purged assets
             |> write_runtime_manifest ~domain ~dest_dir content)))
;;

(* Two lines, two budgets. The bootstrap used to concatenate copied,
   overwritten and removed into one sample and cut it at ten: a version bump
   copies enough assets to fill that sample on its own, so the removed paths
   never reached the line and the operator got a count with no names. For
   [Tools] those names are the whole message — a definition an operator put
   in the runtime directory is deleted at the next boot, because tool
   definitions have no runtime edit layer. *)
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

let distribution_line ~label result =
  match result.copied, result.overwritten with
  | [], [] -> None
  | copied, overwritten ->
    Some
      (Printf.sprintf
         "%s assets synced from binary: %d copied, %d overwritten"
         label
         (List.length copied)
         (List.length overwritten))
;;

let removed_line ~label result =
  match result.removed with
  | [] -> None
  | removed ->
    let shown, more = sample removed in
    Some
      (Printf.sprintf
         "%s assets deleted from the runtime directory (not in the embedded \
          manifest): %s%s"
         label
         shown
         more)
;;
