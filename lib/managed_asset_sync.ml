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
  | Prompts -> "masc.prompt-managed-assets.v2"
  | Tools -> "masc.tool-managed-assets.v2"
  | Mcp -> "masc.mcp-managed-assets.v2"
;;

let all_domains = [ Prompts; Tools; Mcp ]

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
module String_map = Map.Make (String)

type edit_layer =
  | No_edit_layer
  | Prompt_overrides of
      (file:string -> embedded:string -> edited:string -> Prompt_registry.file_edit_promotion)

type operator_edit_outcome =
  | Promoted_to_override of { key : string }
  | Promoted_reset_failed of
      { key : string
      ; reason : string
      }
  | Kept_override_exists of { key : string }
  | Kept_not_promotable of { reason : string }
  | Discarded

type operator_edit =
  { path : string
  ; outcome : operator_edit_outcome
  }

type sync_result =
  { copied : string list
  ; overwritten : string list
  ; removed : string list
  ; operator_edits : operator_edit list
  ; failed : (string * string) list
  }

let sha256_hex content = Digestif.SHA256.(digest_string content |> to_hex)

let read_file_opt = Fs_compat.load_file_opt

let relative_asset_path rel =
  let parts = String.split_on_char '/' rel in
  rel <> ""
  && Filename.is_relative rel
  && List.for_all (fun part -> part <> "" && part <> "." && part <> "..") parts
;;

let runtime_manifest_content ~domain current digests =
  Yojson.Safe.pretty_to_string
    (`Assoc
       [ "managed_by", `String "MASC"
       ; "schema", `String (manifest_schema domain)
       ; "paths", `List (List.map (fun rel -> `String rel) (String_set.elements current))
       ; ( "sha256"
         , `Assoc
             (String_map.bindings digests
              |> List.map (fun (rel, digest) -> rel, `String digest)) )
       ])
  ^ "\n"
;;

type manifest_record =
  { owned : String_set.t
  ; digests : string String_map.t
  }

let no_record = { owned = String_set.empty; digests = String_map.empty }

(* [sha256] maps a listed path to the digest of the bytes the pass that
   wrote the manifest left there. *)
let parse_digests ~owned entries =
  List.fold_left
    (fun acc (rel, value) ->
      match acc, value with
      | Error _, _ -> acc
      | Ok _, _ when not (String_set.mem rel owned) ->
        Error (Printf.sprintf "runtime manifest has a digest for an unlisted path: %s" rel)
      | Ok digests, `String _ when String_map.mem rel digests ->
        Error (Printf.sprintf "runtime manifest lists the digest of %s twice" rel)
      | Ok digests, `String digest -> Ok (String_map.add rel digest digests)
      | Ok _, _ -> Error "runtime manifest digests must be strings")
    (Ok String_map.empty)
    entries
;;

(* The paths the previous pass recorded as this distribution's. What a pass
   may delete is drawn from here, never from the directory listing: a file
   the operator put beside the managed ones was in no manifest, so it is
   not masc's to remove, and the registry reads it like any other prompt.
   No manifest means no owned paths, so a first pass deletes nothing. A
   manifest that does not read, or that another domain wrote, is reported
   and also yields nothing to delete. A manifest under any schema no domain
   writes now is read as no manifest. *)
let previously_owned ~domain ~dest_dir =
  let path = Filename.concat dest_dir "managed-assets.json" in
  match read_file_opt path with
  | exception Sys_error message -> Error ("runtime manifest unreadable: " ^ message)
  | exception Unix.Unix_error (error, operation, argument) ->
    Error
      (Printf.sprintf
         "runtime manifest unreadable: %s(%s): %s"
         operation
         argument
         (Unix.error_message error))
  | None -> Ok no_record
  | Some content ->
    (match Yojson.Safe.from_string content with
     | exception Yojson.Json_error message ->
       Error (Printf.sprintf "runtime manifest is not JSON: %s" message)
     | `Assoc fields ->
       let owned paths =
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
       in
       let foreign schema =
         List.exists
           (fun other -> other <> domain && String.equal schema (manifest_schema other))
           all_domains
       in
       (match
          ( List.assoc_opt "schema" fields
          , List.assoc_opt "paths" fields
          , List.assoc_opt "sha256" fields )
        with
        | Some (`String schema), paths, digests
          when String.equal schema (manifest_schema domain) ->
          (match paths, digests with
           | Some (`List paths), Some (`Assoc entries) ->
             Result.bind (owned paths) (fun owned ->
               Result.map (fun digests -> { owned; digests }) (parse_digests ~owned entries))
           | _, _ -> Error "runtime manifest lacks a paths list or a sha256 object")
        | Some (`String schema), _, _ when foreign schema ->
          Error
            (Printf.sprintf
               "runtime manifest schema %S is not %S"
               schema
               (manifest_schema domain))
        | Some (`String _), _, _ -> Ok no_record
        | (Some _ | None), _, _ -> Error "runtime manifest lacks a schema string")
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

(* A runtime file that differs from the embedded copy is one of two things.
   If it still reads as the bytes the previous pass wrote -- its digest is
   the recorded one -- the embedded copy moved and the file is stale. If it
   does not, somebody edited it after that pass. With no recorded digest
   the two cannot be told apart, and the file is treated as stale. *)
let edited_since_recorded ~recorded ~runtime_rel current =
  match String_map.find_opt runtime_rel recorded with
  | Some digest -> not (String.equal digest (sha256_hex current))
  | None -> false
;;

(* Returns the pass so far and the digests to record: for [runtime_rel],
   the embedded copy's when the file holds it after this pass, and the
   previous record when an edit was kept or the write failed. *)
let sync_current_asset
      ~domain
      ~edit_layer
      ~recorded
      ~read
      ~dest_dir
      (acc, digests)
      (embedded_rel, runtime_rel)
  =
  let previous = String_map.find_opt runtime_rel recorded in
  let record digest =
    match digest with
    | Some digest -> String_map.add runtime_rel digest digests
    | None -> digests
  in
  let fail acc msg = { acc with failed = (embedded_rel, msg) :: acc.failed }, record previous in
  if not (relative_asset_path runtime_rel)
  then fail acc (Printf.sprintf "unsafe embedded %s asset path" (noun domain))
  else (
    match read embedded_rel with
    | None -> fail acc "embedded asset unreadable"
    | Some content ->
      let dest = Filename.concat dest_dir runtime_rel in
      let embedded_digest = sha256_hex content in
      (* [written] is the pass once the file holds the embedded copy;
         [unwritten] is what it reports when the write fails. *)
      let install ~written ~unwritten =
        match Fs_compat.save_file_atomic dest content with
        | Error msg -> fail unwritten msg
        | Ok () -> written, record (Some embedded_digest)
      in
      let with_edit outcome acc =
        { acc with operator_edits = { path = embedded_rel; outcome } :: acc.operator_edits }
      in
      (try
         match prepare_owned_parent ~domain ~dest_dir dest with
         | Error msg -> fail acc msg
         | Ok () ->
           (match writable_leaf_state ~domain dest with
            | Error msg -> fail acc msg
            | Ok ((`Missing | `Regular | `Symlink) as leaf_state) ->
              (match read_file_opt dest with
               | Some current when String.equal current content ->
                 acc, record (Some embedded_digest)
               | None ->
                 install
                   ~written:
                     (if leaf_state = `Missing
                      then { acc with copied = embedded_rel :: acc.copied }
                      else { acc with overwritten = embedded_rel :: acc.overwritten })
                   ~unwritten:acc
               | Some current when not (edited_since_recorded ~recorded ~runtime_rel current)
                 ->
                 install
                   ~written:{ acc with overwritten = embedded_rel :: acc.overwritten }
                   ~unwritten:acc
               | Some current ->
                 (match edit_layer with
                  | No_edit_layer ->
                    install ~written:(with_edit Discarded acc) ~unwritten:acc
                  | Prompt_overrides promote ->
                    (match promote ~file:runtime_rel ~embedded:content ~edited:current with
                     | Prompt_registry.Promoted { key } ->
                       (* The override is saved before the file is reset, so
                          a failed reset leaves the edit in two places, never
                          in none, and the next pass finds the same text
                          saved and resets the file then. *)
                       (match Fs_compat.save_file_atomic dest content with
                        | Ok () ->
                          ( with_edit (Promoted_to_override { key }) acc
                          , record (Some embedded_digest) )
                        | Error reason ->
                          ( with_edit (Promoted_reset_failed { key; reason }) acc
                          , record previous ))
                     | Prompt_registry.Override_exists { key } ->
                       with_edit (Kept_override_exists { key }) acc, record previous
                     | Prompt_registry.Not_promotable { reason } ->
                       with_edit (Kept_not_promotable { reason }) acc, record previous))))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | Sys_error msg -> fail acc msg
       | Unix.Unix_error (error, operation, argument) ->
         fail
           acc
           (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))))
;;

let sync ~domain ~edit_layer ~read ~files ~dest_dir () =
  let assets = current_assets ~domain files in
  let initial =
    { copied = []; overwritten = []; removed = []; operator_edits = []; failed = [] }
  in
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
     an empty set would retire every asset the previous manifest lists. *)
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
      let { owned = owned_before; digests = recorded }, manifest_failure =
        match previously_owned ~domain ~dest_dir with
        | Ok record -> record, []
        | Error msg -> no_record, [ manifest_path domain, msg ]
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
      let synced, digests =
        List.fold_left
          (sync_current_asset ~domain ~edit_layer ~recorded ~read ~dest_dir)
          (purged, String_map.empty)
          assets
      in
      (* A manifest this pass could not read stays as it is. Rewriting it
         would make the next boot read clean, so the failure would show
         once and the paths it recorded would be nobody's to retire.
         Left in place, the same line comes back every boot until the
         operator repairs or removes the file, and the next pass then
         starts from what it says. *)
      match manifest_failure with
      | _ :: _ -> synced
      | [] ->
        write_runtime_manifest
          ~domain
          ~dest_dir
          (runtime_manifest_content ~domain current digests)
          synced)
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

(* Overwritten carries names, copied does not. A copy is a file the
   operator never had; a version bump makes dozens and the paths say nothing
   they wanted to know. An overwrite replaced a file that was already there
   and differed: the embedded copy moved, or the file was edited while no
   digest was recorded for it. The names say which files. An edit the
   recorded digest does reveal is an [operator_edit] and has its own line. *)
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

let operator_edit_line ~label { path; outcome } =
  match outcome with
  | Promoted_to_override { key } ->
    Printf.sprintf
      "%s asset %s was edited after the last sync; the edited text is now the \
       saved override for prompt %s (prompt_overrides.json) and the file is back \
       to the distribution copy"
      label
      path
      key
  | Promoted_reset_failed { key; reason } ->
    Printf.sprintf
      "%s asset %s was edited after the last sync; the edited text is now the \
       saved override for prompt %s, but resetting the file failed (%s). The \
       file still holds the edit and the next boot resets it; fix the write \
       failure or delete the file"
      label
      path
      key
      reason
  | Kept_override_exists { key } ->
    Printf.sprintf
      "%s asset %s was edited after the last sync, and prompt %s already has a \
       saved override; the file is left as edited and the distribution copy is \
       not installed until the file is deleted or matches it"
      label
      path
      key
  | Kept_not_promotable { reason } ->
    Printf.sprintf
      "%s asset %s was edited after the last sync and cannot become a prompt \
       override (%s); the file is left as edited and the distribution copy is \
       not installed until the file is deleted or matches it"
      label
      path
      reason
  | Discarded ->
    Printf.sprintf
      "%s asset %s was edited after the last sync; %s definitions have no \
       runtime edit layer, so the edit was replaced with the distribution copy"
      label
      path
      label
;;

let operator_edit_lines ~label result =
  List.rev_map (operator_edit_line ~label) result.operator_edits
;;
