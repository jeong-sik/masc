type source =
  | Current_meta
  | Trace_history
  | Runtime_manifest

type claim =
  { keeper_name : Keeper_id.Keeper_name.t
  ; source : source
  }

type owner =
  | Known of claim
  | Not_claimed_in_retained_catalog
  | Conflicting of claim list
  | Incomplete of claim list
  | Catalog_unavailable

type manifest_error =
  | Manifest_read_failed of Fs_compat.owned_regular_file_read_error
  | Manifest_empty
  | Manifest_invalid_json of
      { line_number : int
      ; detail : string
      }
  | Manifest_invalid_row of
      { line_number : int
      ; detail : string
      }
  | Manifest_identity_mismatch of
      { line_number : int
      ; observed_keeper : string
      ; observed_trace : string
      }

type gap =
  | Keeper_catalog_unavailable of string
  | Keeper_catalog_changed_during_resolution
  | Invalid_persisted_keeper_name of string
  | Keeper_meta_name_mismatch of
      { catalog_name : Keeper_id.Keeper_name.t
      ; metadata_name : string
      }
  | Keeper_meta_unavailable of
      { keeper_name : Keeper_id.Keeper_name.t
      ; detail : string
      }
  | Runtime_manifest_entry_unreadable of
      { keeper_name : Keeper_id.Keeper_name.t
      ; cause : manifest_error
      }

type t =
  { owner : owner
  ; gaps : gap list
  }

let source_priority = function
  | Current_meta -> 0
  | Trace_history -> 1
  | Runtime_manifest -> 2
;;

let stronger_source left right =
  if source_priority left <= source_priority right then left else right
;;

let meta_source trace_id (meta : Keeper_meta_contract.keeper_meta) =
  if Keeper_id.Trace_id.equal trace_id meta.runtime.trace_id
  then Some Current_meta
  else
    let claimed_by_history =
      List.exists
        (fun candidate ->
           match Keeper_id.Trace_id.of_string candidate with
           | Ok candidate -> Keeper_id.Trace_id.equal trace_id candidate
           | Error _ -> false)
        meta.runtime.trace_history
    in
    if claimed_by_history then Some Trace_history else None
;;

let manifest_source config trace_id keeper_name =
  let keeper = Keeper_id.Keeper_name.to_string keeper_name in
  let path =
    Keeper_runtime_manifest.path_for_trace
      config
      ~keeper_name:keeper
      ~trace_id:(Keeper_id.Trace_id.to_string trace_id)
  in
  let expected_keeper = Keeper_id.Keeper_name.to_string keeper_name in
  let expected_trace = Keeper_id.Trace_id.to_string trace_id in
  let row_identity = function
    | Keeper_runtime_manifest.Active_row row -> row.keeper_name, row.trace_id
    | Keeper_runtime_manifest.Unsupported_row (row, _) ->
      row.keeper_name, row.trace_id
  in
  let decode_rows contents =
    let rows =
      contents
      |> String.split_on_char '\n'
      |> List.mapi (fun index line -> index + 1, line)
      |> List.filter (fun (_, line) -> String.trim line <> "")
    in
    match rows with
    | [] -> Error Manifest_empty
    | rows ->
      List.fold_left
        (fun result (line_number, line) ->
           let open Result.Syntax in
           let* () = result in
           let* json =
             match Yojson.Safe.from_string line with
             | json -> Ok json
             | exception Yojson.Json_error detail ->
               Error (Manifest_invalid_json { line_number; detail })
           in
           let* row =
             Keeper_runtime_manifest.decode_persisted_row json
             |> Result.map_error (fun detail ->
                  Manifest_invalid_row { line_number; detail })
           in
           let observed_keeper, observed_trace = row_identity row in
           if
             String.equal expected_keeper observed_keeper
             && String.equal expected_trace observed_trace
           then Ok ()
           else
             Error
               (Manifest_identity_mismatch
                  { line_number; observed_keeper; observed_trace }))
        (Ok ())
        rows
  in
  match Fs_compat.load_owned_regular_file ~ownership_root:config.base_path path with
  | Ok (Some contents) ->
    (match decode_rows contents with
     | Ok () -> Some Runtime_manifest, []
     | Error cause ->
       None, [ Runtime_manifest_entry_unreadable { keeper_name; cause } ])
  | Ok None -> None, []
  | Error cause ->
    ( None
    , [ Runtime_manifest_entry_unreadable
          { keeper_name; cause = Manifest_read_failed cause }
      ] )
;;

let keeper_claim config trace_id keeper_name =
  let keeper = Keeper_id.Keeper_name.to_string keeper_name in
  let meta_path =
    Filename.concat
      (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename
         ~keeper_name:keeper
         Keeper_runtime_root_entry.Metadata)
  in
  let meta_source, meta_gaps =
    match
      Keeper_meta_store.read_meta_file_path_read_only
        ~ownership_root:config.Workspace.base_path
        meta_path
    with
    | Ok (Some meta)
      when String.equal meta.name (Keeper_id.Keeper_name.to_string keeper_name) ->
      meta_source trace_id meta, []
    | Ok (Some meta) ->
      ( None
      , [ Keeper_meta_name_mismatch
            { catalog_name = keeper_name; metadata_name = meta.name }
        ] )
    | Ok None -> None, []
    | Error rejection ->
      let detail =
        match rejection with
        | Keeper_meta_store.Unreadable detail
        | Keeper_meta_store.Not_current detail -> detail
      in
      None, [ Keeper_meta_unavailable { keeper_name; detail } ]
  in
  let manifest_source, manifest_gaps =
    manifest_source config trace_id keeper_name
  in
  let source =
    match meta_source, manifest_source with
    | Some left, Some right -> Some (stronger_source left right)
    | Some source, None | None, Some source -> Some source
    | None, None -> None
  in
  Option.map (fun source -> { keeper_name; source }) source,
  meta_gaps @ manifest_gaps
;;

type catalog_identity =
  | Catalog_missing
  | Catalog_directory of
      { device : int
      ; inode : int
      }

let catalog_identity config =
  let path = Workspace.keepers_runtime_dir config in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Catalog_missing
  | exception Unix.Unix_error (cause, _, _) ->
    Error
      (Printf.sprintf
         "failed to inspect retained Keeper catalog %s: %s"
         path
         (Unix.error_message cause))
  | { Unix.st_kind = Unix.S_DIR; st_dev; st_ino; _ } ->
    Ok (Catalog_directory { device = st_dev; inode = st_ino })
  | _ -> Error ("retained Keeper catalog is not a directory: " ^ path)
;;

let catalog_snapshot config =
  let open Result.Syntax in
  let* before = catalog_identity config in
  let* names = Keeper_meta_store.retained_keeper_names_read_only_result config in
  let* after = catalog_identity config in
  if before = after
  then Ok (before, names)
  else Error "retained Keeper catalog changed while listing"
;;

let sort_claims claims =
  List.sort
    (fun left right ->
       let by_keeper =
         String.compare
           (Keeper_id.Keeper_name.to_string left.keeper_name)
           (Keeper_id.Keeper_name.to_string right.keeper_name)
       in
       if by_keeper <> 0
       then by_keeper
       else Int.compare (source_priority left.source) (source_priority right.source))
    claims
;;

let collect_claims config trace_id names =
  let claims, gaps =
    List.fold_left
      (fun (claims, gaps) name ->
         match Keeper_id.Keeper_name.of_string name with
         | Error _ -> claims, Invalid_persisted_keeper_name name :: gaps
         | Ok keeper_name ->
           let claim, keeper_gaps = keeper_claim config trace_id keeper_name in
           Option.fold ~none:claims ~some:(fun claim -> claim :: claims) claim,
           List.rev_append keeper_gaps gaps)
      ([], [])
      names
  in
  sort_claims claims, List.rev gaps
;;

let unique_claims claims =
  claims
  |> sort_claims
  |> List.fold_left
       (fun unique claim ->
          match unique with
          | previous :: _
            when Keeper_id.Keeper_name.equal
                   previous.keeper_name
                   claim.keeper_name
                 && previous.source = claim.source ->
            unique
          | _ -> claim :: unique)
       []
  |> List.rev
;;

let resolve_with_after_claims ~after_claims config trace_id =
  match catalog_snapshot config with
  | Error detail ->
    { owner = Catalog_unavailable
    ; gaps = [ Keeper_catalog_unavailable detail ]
    }
  | Ok (initial_identity, names) ->
    let initial_claims, initial_gaps = collect_claims config trace_id names in
    after_claims ();
    let claims, gaps =
      match catalog_snapshot config with
      | Error detail ->
        initial_claims, initial_gaps @ [ Keeper_catalog_unavailable detail ]
      | Ok (current_identity, current_names) ->
        let current_claims, current_gaps =
          collect_claims config trace_id current_names
        in
        let changed =
          initial_identity <> current_identity
          || names <> current_names
          || initial_claims <> current_claims
        in
        ( unique_claims (initial_claims @ current_claims)
        , initial_gaps
          @ current_gaps
          @ if changed then [ Keeper_catalog_changed_during_resolution ] else [] )
    in
    { owner =
        (match gaps, claims with
         | _ :: _, claims -> Incomplete claims
         | [], [] -> Not_claimed_in_retained_catalog
         | [], [ claim ] -> Known claim
         | [], claims -> Conflicting claims)
    ; gaps
    }
;;

let resolve config trace_id =
  resolve_with_after_claims ~after_claims:(fun () -> ()) config trace_id
;;

module For_testing = struct
  let resolve = resolve_with_after_claims
end
