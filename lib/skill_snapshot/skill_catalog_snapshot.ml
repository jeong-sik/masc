type package_id = Skill_reference.package_id

type package_id_error = Skill_reference.package_id_error =
  | Empty_package_id
  | Current_directory_package_id
  | Parent_directory_package_id
  | Package_id_contains_separator
  | Package_id_contains_nul

type content_revision = Skill_reference.content_revision
type config_source_revision = string
type config_revision = string
type catalog_revision = string
type snapshot_revision = string

type revision_error = Skill_reference.revision_error =
  | Invalid_revision_length of { actual : int }
  | Invalid_revision_character of { index : int; found : char }

type identity = Skill_reference.identity

type source_operation =
  | Inspect_source
  | Read_source_directory

type source_observation =
  | Source_ready of
      { resolved_path : string
      ; candidates : int
      }
  | Source_missing of { resolved_path : string }
  | Source_not_directory of
      { resolved_path : string
      ; kind : Unix.file_kind
      }
  | Source_unavailable of
      { resolved_path : string
      ; operation : source_operation
      ; detail : string
      }
  | Source_unresolved of Skill_source_config.resolution

type candidate =
  | Candidate_document of
      { directory : string
      ; source_text : string
      }
  | Candidate_unreadable of
      { directory : string
      ; path : string
      ; detail : string
      }

type source_scan =
  { source : Skill_source_config.resolved_source
  ; observation : source_observation
  ; candidates : candidate list
  }

type entry =
  { identity : identity
  ; source_index : int
  ; directory : string
  ; document : Agent_core.Skill_document.t
  ; content_revision : content_revision
  }

type rejection_reason =
  | Document_rejected of Agent_core.Skill_document.diagnostic list
  | Document_unreadable of
      { path : string
      ; detail : string
      }
  | Exact_identity_duplicate of { first_directory : string }
  | Invalid_package_id of package_id_error

type rejection =
  { source_index : int
  ; source_id : Skill_source_config.source_id
  ; package_id : package_id option
  ; directory : string
  ; content_revision : content_revision option
  ; reason : rejection_reason
  }

type shadow =
  { winner : identity
  ; shadowed : identity
  }

type config_state =
  | Configured of
      { config : Skill_source_config.t
      ; revision : config_revision
      }
  | Config_rejected of
      { source_revision : config_source_revision
      ; diagnostics : Skill_source_config.diagnostic list
      }
  | Config_unreadable of { detail : string }

type t =
  { config_state : config_state
  ; sources : source_scan list
  ; entries : entry list
  ; effective_entries : entry list
  ; rejections : rejection list
  ; shadows : shadow list
  ; catalog_revision : catalog_revision
  ; snapshot_revision : snapshot_revision
  }

type build_error =
  | Missing_source_scan of Skill_source_config.source_id
  | Duplicate_source_scan of Skill_source_config.source_id
  | Unexpected_source_scan of Skill_source_config.source_id
  | Source_scan_config_mismatch of Skill_source_config.source_id

type reference_resolution_error =
  | Identity_not_found of identity
  | Content_revision_mismatch of
      { identity : identity
      ; requested : content_revision
      ; observed : content_revision
      }

let package_id_of_directory = Skill_reference.package_id_of_directory
let package_id_to_string = Skill_reference.package_id_to_string
let make_identity = Skill_reference.make_identity
let content_revision_to_string = Skill_reference.content_revision_to_string
let config_source_revision_to_string revision = revision
let config_revision_to_string revision = revision
let catalog_revision_to_string revision = revision
let snapshot_revision_to_string revision = revision
let equal_snapshot_revision = String.equal

let revision_of_string value =
  Result.map (fun () -> value) (Skill_reference.validate_revision_string value)
;;

let content_revision_of_string = Skill_reference.content_revision_of_string
let snapshot_revision_of_string value = revision_of_string value

let digest_fields fields =
  let buffer = Buffer.create (List.length fields) in
  List.iter
    (fun (tag, value) ->
       Buffer.add_string buffer (string_of_int (String.length tag));
       Buffer.add_char buffer ':';
       Buffer.add_string buffer tag;
       Buffer.add_string buffer (string_of_int (String.length value));
       Buffer.add_char buffer ':';
       Buffer.add_string buffer value)
    fields;
  Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer)))
;;

let content_revision = Skill_reference.content_revision_of_source_text
let config_source_revision source_text = digest_fields [ "skill_config_source", source_text ]

let identity_key (identity : identity) =
  ( Skill_source_config.source_id_to_string identity.source_id
  , Skill_reference.package_id_to_string identity.package_id
  , identity.name )
;;

let identity_to_yojson = Skill_reference.identity_to_yojson

let source_operation_to_string = function
  | Inspect_source -> "inspect_source"
  | Read_source_directory -> "read_source_directory"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular_file"
  | S_DIR -> "directory"
  | S_CHR -> "character_device"
  | S_BLK -> "block_device"
  | S_LNK -> "symbolic_link"
  | S_FIFO -> "fifo"
  | S_SOCK -> "socket"
;;

let resolution_to_private_yojson = function
  | Skill_source_config.Resolved path ->
    `Assoc [ "kind", `String "resolved"; "path", `String path ]
  | Anchor_unavailable anchor ->
    `Assoc
      [ "kind", `String "anchor_unavailable"
      ; "anchor", `String (Skill_source_config.anchor_to_string anchor)
      ]
  | Anchor_invalid { anchor; rejection } ->
    `Assoc
      [ "kind", `String "anchor_invalid"
      ; "anchor", `String (Skill_source_config.anchor_to_string anchor)
      ; ( "reason"
        , `String (Skill_source_config.anchor_rejection_to_string rejection) )
      ]
  | Path_rejected rejection ->
    `Assoc
      [ "kind", `String "path_rejected"
      ; ( "reason"
        , `String (Skill_source_config.path_rejection_to_string rejection) )
      ]
;;

let source_observation_to_private_yojson = function
  | Source_ready { resolved_path; candidates } ->
    `Assoc
      [ "kind", `String "ready"
      ; "resolved_path", `String resolved_path
      ; "candidates", `Int candidates
      ]
  | Source_missing { resolved_path } ->
    `Assoc [ "kind", `String "missing"; "resolved_path", `String resolved_path ]
  | Source_not_directory { resolved_path; kind } ->
    `Assoc
      [ "kind", `String "not_directory"
      ; "resolved_path", `String resolved_path
      ; "file_kind", `String (file_kind_to_string kind)
      ]
  | Source_unavailable { resolved_path; operation; detail } ->
    `Assoc
      [ "kind", `String "unavailable"
      ; "resolved_path", `String resolved_path
      ; "operation", `String (source_operation_to_string operation)
      ; "detail", `String detail
      ]
  | Source_unresolved resolution -> resolution_to_private_yojson resolution
;;

let source_to_private_yojson (scan : source_scan) =
  `Assoc
    [ ( "source_id"
      , `String
          (Skill_source_config.source_id_to_string scan.source.source.id) )
    ; "observation", source_observation_to_private_yojson scan.observation
    ]
;;

let rejection_reason_to_private_yojson = function
  | Document_rejected diagnostics ->
    `Assoc
      [ "kind", `String "document_rejected"
      ; ( "diagnostics"
        , `List
            (List.map Agent_core.Skill_document.diagnostic_to_yojson diagnostics) )
      ]
  | Document_unreadable { path; detail } ->
    `Assoc
      [ "kind", `String "document_unreadable"
      ; "path", `String path
      ; "detail", `String detail
      ]
  | Exact_identity_duplicate { first_directory } ->
    `Assoc
      [ "kind", `String "exact_identity_duplicate"
      ; "first_directory", `String first_directory
      ]
  | Invalid_package_id _ -> `Assoc [ "kind", `String "invalid_package_id" ]
;;

let rejection_to_private_yojson (rejection : rejection) =
  `Assoc
    [ "source_index", `Int rejection.source_index
    ; ( "source_id"
      , `String (Skill_source_config.source_id_to_string rejection.source_id) )
    ; ( "package_id"
      , match rejection.package_id with
        | Some package_id -> `String (package_id_to_string package_id)
        | None -> `Null )
    ; "directory", `String rejection.directory
    ; ( "content_revision"
      , match rejection.content_revision with
        | Some revision -> `String (content_revision_to_string revision)
        | None -> `Null )
    ; "reason", rejection_reason_to_private_yojson rejection.reason
    ]
;;

let entry_to_private_yojson (entry : entry) =
  `Assoc
    [ "identity", identity_to_yojson entry.identity
    ; "source_index", `Int entry.source_index
    ; "content_revision", `String (content_revision_to_string entry.content_revision)
    ]
;;

let shadow_to_yojson (shadow : shadow) =
  `Assoc
    [ "winner", identity_to_yojson shadow.winner
    ; "shadowed", identity_to_yojson shadow.shadowed
    ]
;;

let catalog_projection ~sources ~entries ~rejections ~shadows =
  `Assoc
    [ "sources", `List (List.map source_to_private_yojson sources)
    ; "entries", `List (List.map entry_to_private_yojson entries)
    ; "rejections", `List (List.map rejection_to_private_yojson rejections)
    ; "shadows", `List (List.map shadow_to_yojson shadows)
    ]
;;

let effective_projection (entries : entry list) =
  let winners = Hashtbl.create (List.length entries) in
  List.fold_left
    (fun (effective, shadows) entry ->
       match Hashtbl.find_opt winners entry.identity.name with
       | None ->
         Hashtbl.add winners entry.identity.name entry.identity;
         entry :: effective, shadows
       | Some winner ->
         effective, { winner; shadowed = entry.identity } :: shadows)
    ([], [])
    entries
  |> fun (effective, shadows) -> List.rev effective, List.rev shadows
;;

let build_entries sources =
  let exact = Hashtbl.create (List.length sources) in
  let entries, rejections =
    List.fold_left
      (fun (entries, rejections) (source_index, scan) ->
         let source_id = scan.source.source.id in
         List.fold_left
           (fun (entries, rejections) candidate ->
              match candidate with
              (* The name is checked before the file, the same order the
                 readable branch below uses. A directory that cannot be a
                 package id has no identity to reject under, so that is the
                 reason it is rejected for; erasing it to [None] here made the
                 field say "unnamed" for both a bad name and a good one. *)
              | Candidate_unreadable { directory; path; detail } ->
                (match package_id_of_directory directory with
                 | Error package_error ->
                   ( entries
                   , { source_index
                     ; source_id
                     ; package_id = None
                     ; directory
                     ; content_revision = None
                     ; reason = Invalid_package_id package_error
                     }
                     :: rejections )
                 | Ok package_id ->
                   ( entries
                   , { source_index
                     ; source_id
                     ; package_id = Some package_id
                     ; directory
                     ; content_revision = None
                     ; reason = Document_unreadable { path; detail }
                     }
                     :: rejections ))
              | Candidate_document { directory; source_text } ->
                (match package_id_of_directory directory with
                 | Error package_error ->
                   ( entries
                   , { source_index
                     ; source_id
                     ; package_id = None
                     ; directory
                     ; content_revision = Some (content_revision source_text)
                     ; reason = Invalid_package_id package_error
                     }
                     :: rejections )
                 | Ok package_id ->
                   (match
                      Agent_core.Skill_document.decode
                        ~directory_name:directory
                        source_text
                    with
                    | Unloadable diagnostics ->
                      ( entries
                      , { source_index
                        ; source_id
                        ; package_id = Some package_id
                        ; directory
                        ; content_revision = Some (content_revision source_text)
                        ; reason = Document_rejected diagnostics
                        }
                        :: rejections )
                    | Loaded document ->
                      let identity = make_identity ~source_id ~package_id ~name:document.name in
                      let key = identity_key identity in
                      (match Hashtbl.find_opt exact key with
                       | Some first_directory ->
                         ( entries
                         , { source_index
                           ; source_id
                           ; package_id = Some package_id
                           ; directory
                           ; content_revision = Some (content_revision source_text)
                           ; reason = Exact_identity_duplicate { first_directory }
                           }
                           :: rejections )
                       | None ->
                         Hashtbl.add exact key directory;
                         ( { identity
                           ; source_index
                           ; directory
                           ; document
                           ; content_revision = content_revision source_text
                           }
                           :: entries
                         , rejections )))))
           (entries, rejections)
           scan.candidates)
      ([], [])
      (List.mapi (fun source_index scan -> source_index, scan) sources)
  in
  List.rev entries, List.rev rejections
;;

let config_state_private_yojson = function
  | Configured { revision; _ } ->
    `Assoc [ "kind", `String "configured"; "revision", `String revision ]
  | Config_rejected { source_revision; diagnostics } ->
    `Assoc
      [ "kind", `String "rejected"
      ; "source_revision", `String source_revision
      ; ( "diagnostics"
        , `List
            (List.map
               (fun diagnostic ->
                  `String (Skill_source_config.diagnostic_to_string diagnostic))
               diagnostics) )
      ]
  | Config_unreadable { detail } ->
    `Assoc [ "kind", `String "unreadable"; "detail", `String detail ]
;;

let make ~config_state sources =
  let entries, rejections = build_entries sources in
  let effective_entries, shadows = effective_projection entries in
  let catalog_revision =
    catalog_projection ~sources ~entries ~rejections ~shadows
    |> Yojson.Safe.to_string
    |> fun value -> digest_fields [ "skill_catalog", value ]
  in
  let snapshot_revision =
    digest_fields
      [ ( "skill_config_state"
        , Yojson.Safe.to_string (config_state_private_yojson config_state) )
      ; "skill_catalog_revision", catalog_revision
      ]
  in
  { config_state
  ; sources
  ; entries
  ; effective_entries
  ; rejections
  ; shadows
  ; catalog_revision
  ; snapshot_revision
  }
;;

let same_source
      (left : Skill_source_config.source)
      (right : Skill_source_config.source)
  =
  String.equal
    (Skill_source_config.source_id_to_string left.id)
    (Skill_source_config.source_id_to_string right.id)
  && left.anchor = right.anchor
  && String.equal left.configured_path right.configured_path
  && left.access = right.access
;;

let configured ~config scans =
  let configured_ids =
    List.map
      (fun (source : Skill_source_config.source) ->
         Skill_source_config.source_id_to_string source.id)
      config.Skill_source_config.sources
  in
  let unexpected =
    List.filter_map
      (fun (scan : source_scan) ->
         let id = Skill_source_config.source_id_to_string scan.source.source.id in
         if List.mem id configured_ids
         then None
         else Some (Unexpected_source_scan scan.source.source.id))
      scans
  in
  let ordered, ordering_errors =
    List.fold_right
      (fun (configured_source : Skill_source_config.source) (ordered, errors) ->
         let configured_id =
           Skill_source_config.source_id_to_string configured_source.id
         in
         let matching =
           List.filter
             (fun (scan : source_scan) ->
                String.equal
                  configured_id
                  (Skill_source_config.source_id_to_string scan.source.source.id))
             scans
         in
         match matching with
         | [] -> ordered, Missing_source_scan configured_source.id :: errors
         | [ scan ] when same_source configured_source scan.source.source ->
           scan :: ordered, errors
         | [ _ ] ->
           ordered, Source_scan_config_mismatch configured_source.id :: errors
         | _ -> ordered, Duplicate_source_scan configured_source.id :: errors)
      config.sources
      ([], [])
  in
  let errors = ordering_errors @ unexpected in
  if errors <> []
  then Error errors
  else (
    let revision =
      Skill_source_config.to_yojson config
      |> Yojson.Safe.to_string
      |> fun value -> digest_fields [ "skill_config", value ]
    in
    Ok (make ~config_state:(Configured { config; revision }) ordered))
;;

let config_rejected ~source_text ~diagnostics =
  let source_revision = config_source_revision source_text in
  make ~config_state:(Config_rejected { source_revision; diagnostics }) []
;;

let config_unreadable ~detail =
  make ~config_state:(Config_unreadable { detail }) []
;;

let config_state snapshot = snapshot.config_state
let sources snapshot = snapshot.sources
let entries snapshot = snapshot.entries
let effective_entries snapshot = snapshot.effective_entries
let rejections snapshot = snapshot.rejections
let shadows snapshot = snapshot.shadows

let config_revision snapshot =
  match snapshot.config_state with
  | Configured { revision; _ } -> Some revision
  | Config_rejected _ | Config_unreadable _ -> None
;;

let catalog_revision snapshot = snapshot.catalog_revision
let snapshot_revision snapshot = snapshot.snapshot_revision

let find_exact snapshot identity =
  let key = identity_key identity in
  List.find_opt (fun entry -> identity_key entry.identity = key) snapshot.entries
;;

let entry_reference (entry : entry) =
  Skill_reference.make
    ~identity:entry.identity
    ~content_revision:entry.content_revision
;;

let resolve_reference snapshot (reference : Skill_reference.t) =
  match find_exact snapshot reference.identity with
  | None -> Error (Identity_not_found reference.identity)
  | Some entry ->
    if Skill_reference.equal_content_revision entry.content_revision reference.content_revision
    then Ok entry
    else
      Error
        (Content_revision_mismatch
           { identity = reference.identity
           ; requested = reference.content_revision
           ; observed = entry.content_revision
           })
;;

let find_effective_by_name snapshot name =
  List.find_opt
    (fun entry -> String.equal entry.identity.name name)
    snapshot.effective_entries
;;

let source_observation_to_public_yojson = function
  | Source_ready { candidates; _ } ->
    `Assoc [ "kind", `String "ready"; "candidates", `Int candidates ]
  | Source_missing _ -> `Assoc [ "kind", `String "missing" ]
  | Source_not_directory { kind; _ } ->
    `Assoc
      [ "kind", `String "not_directory"
      ; "file_kind", `String (file_kind_to_string kind)
      ]
  | Source_unavailable { operation; _ } ->
    `Assoc
      [ "kind", `String "unavailable"
      ; "operation", `String (source_operation_to_string operation)
      ]
  | Source_unresolved _ -> `Assoc [ "kind", `String "unresolved" ]
;;

let source_to_public_yojson (scan : source_scan) =
  let source = scan.source.source in
  let configured_path =
    match source.anchor with
    | Skill_source_config.Absolute -> `Null
    | Base_path | User_home -> `String source.configured_path
  in
  `Assoc
    [ "id", `String (Skill_source_config.source_id_to_string source.id)
    ; "anchor", `String (Skill_source_config.anchor_to_string source.anchor)
    ; "path", configured_path
    ; "access", `String (Skill_source_config.access_to_string source.access)
    ; "observation", source_observation_to_public_yojson scan.observation
    ]
;;

let entry_to_public_yojson (entry : entry) =
  `Assoc
    [ "identity", identity_to_yojson entry.identity
    ; "content_revision", `String (content_revision_to_string entry.content_revision)
    ; "description", `String entry.document.description
    ; "body_bytes", `Int (String.length entry.document.body)
    ]
;;

let rejection_to_public_yojson (rejection : rejection) =
  let reason =
    match rejection.reason with
    | Document_rejected diagnostics ->
      `Assoc
        [ "kind", `String "document_rejected"
        ; ( "diagnostics"
          , `List
              (List.map Agent_core.Skill_document.diagnostic_to_yojson diagnostics) )
        ]
    | Document_unreadable _ ->
      `Assoc [ "kind", `String "document_unreadable" ]
    | Exact_identity_duplicate _ ->
      `Assoc [ "kind", `String "exact_identity_duplicate" ]
    | Invalid_package_id _ -> `Assoc [ "kind", `String "invalid_package_id" ]
  in
  `Assoc
    [ "source_index", `Int rejection.source_index
    ; ( "source_id"
      , `String (Skill_source_config.source_id_to_string rejection.source_id) )
    ; ( "package_id"
      , match rejection.package_id with
        | Some package_id -> `String (package_id_to_string package_id)
        | None -> `Null )
    ; ( "content_revision"
      , match rejection.content_revision with
        | Some revision -> `String (content_revision_to_string revision)
        | None -> `Null )
    ; "reason", reason
    ]
;;

let config_state_to_public_yojson = function
  | Configured { revision; config } ->
    `Assoc
      [ "kind", `String "configured"
      ; "revision", `String revision
      ; ( "resource_read_max_bytes"
        , match config.resource_read_max_bytes with
          | Some value ->
            `Int (Skill_source_config.resource_read_max_bytes_to_int value)
          | None -> `Null )
      ]
  | Config_rejected { source_revision; diagnostics } ->
    `Assoc
      [ "kind", `String "rejected"
      ; "source_revision", `String source_revision
      ; ( "diagnostics"
        , `List
            (List.map
               (fun diagnostic ->
                  `String (Skill_source_config.diagnostic_to_string diagnostic))
               diagnostics) )
      ]
  | Config_unreadable _ -> `Assoc [ "kind", `String "unreadable" ]
;;

let to_public_yojson snapshot =
  `Assoc
    [ "snapshot_revision", `String snapshot.snapshot_revision
    ; "catalog_revision", `String snapshot.catalog_revision
    ; "config", config_state_to_public_yojson snapshot.config_state
    ; "sources", `List (List.map source_to_public_yojson snapshot.sources)
    ; "skills", `List (List.map entry_to_public_yojson snapshot.entries)
    ; ( "effective_skills"
      , `List (List.map (fun entry -> identity_to_yojson entry.identity) snapshot.effective_entries) )
    ; "shadows", `List (List.map shadow_to_yojson snapshot.shadows)
    ; "rejections", `List (List.map rejection_to_public_yojson snapshot.rejections)
    ]
;;
