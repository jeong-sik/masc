(** Keeper source-bound current memory. *)

open Result.Syntax

let suffix = ".memory-source-current.json"
let max_source_bytes = 1_048_576

type file_source =
  { path : string
  ; sha256 : string
  }

type fact =
  { claim : string
  ; first_seen : float
  ; source : file_source
  }

type invalidation_reason =
  | Source_changed
  | Source_unavailable

type invalidation =
  { source_path : string
  ; invalidated_at : float
  ; reason : invalidation_reason
  }

type t =
  { revision : int
  ; updated_at : float
  ; trace_id : string
  ; facts : fact list
  ; invalidations : invalidation list
  }

type projection =
  { snapshot : t option
  ; facts : fact list
  ; invalidations : invalidation list
  }

type write_error =
  | Source_read_failed of string
  | Store_write_failed of string

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let invalidation_reason_to_string = function
  | Source_changed -> "source_changed"
  | Source_unavailable -> "source_unavailable"
;;

let invalidation_reason_of_string = function
  | "source_changed" -> Some Source_changed
  | "source_unavailable" -> Some Source_unavailable
  | _ -> None
;;

let exact_object_fields required fields =
  List.length required = List.length fields
  && List.for_all
       (fun required_name ->
          match
            List.filter
              (fun (observed_name, _) -> String.equal required_name observed_name)
              fields
          with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       required
;;

let non_empty value = not (String.equal (String.trim value) "")

let valid_source_path value =
  non_empty value
  && not (String.contains value '\n')
  && not (String.contains value '\r')
;;

let valid_sha256 value =
  String.length value = 71
  && String.starts_with ~prefix:"sha256:" value
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       (String.sub value 7 64)
;;

let finite_nonnegative value = Float.is_finite value && value >= 0.0

let sha256 content =
  "sha256:" ^ Digestif.SHA256.(digest_string content |> to_hex)
;;

let render_fact fact =
  Printf.sprintf
    "- [category=fact recorded=%s source=file:%S source_sha256=%s] %s"
    (Masc_domain.iso8601_of_unix_seconds fact.first_seen)
    fact.source.path
    fact.source.sha256
    fact.claim
;;

let render_invalidation invalidation =
  Printf.sprintf
    "- [invalidated source=file:%S reason=%s checked=%s] Previous claim was discarded; re-read this source before writing a replacement."
    invalidation.source_path
    (invalidation_reason_to_string invalidation.reason)
    (Masc_domain.iso8601_of_unix_seconds invalidation.invalidated_at)
;;

let source_to_json source =
  `Assoc
    [ "kind", `String "file"
    ; "path", `String source.path
    ; "sha256", `String source.sha256
    ]
;;

let source_of_json = function
  | `Assoc fields when exact_object_fields [ "kind"; "path"; "sha256" ] fields ->
    (match
       List.assoc_opt "kind" fields
       , List.assoc_opt "path" fields
       , List.assoc_opt "sha256" fields
     with
     | Some (`String "file"), Some (`String path), Some (`String digest)
       when valid_source_path path && valid_sha256 digest ->
       Some { path; sha256 = digest }
     | _ -> None)
  | _ -> None
;;

let fact_to_json fact =
  `Assoc
    [ "claim", `String fact.claim
    ; "first_seen", `Float fact.first_seen
    ; "source", source_to_json fact.source
    ]
;;

let fact_of_json = function
  | `Assoc fields when exact_object_fields [ "claim"; "first_seen"; "source" ] fields ->
    (match
       List.assoc_opt "claim" fields
       , List.assoc_opt "first_seen" fields
       , List.assoc_opt "source" fields
     with
     | Some (`String claim), Some (`Float first_seen), Some source
       when non_empty claim && finite_nonnegative first_seen ->
       Option.map
         (fun source -> { claim; first_seen; source })
         (source_of_json source)
     | Some (`String claim), Some (`Int first_seen), Some source
       when non_empty claim && first_seen >= 0 ->
       Option.map
         (fun source -> { claim; first_seen = float_of_int first_seen; source })
         (source_of_json source)
     | _ -> None)
  | _ -> None
;;

let invalidation_to_json invalidation =
  `Assoc
    [ "source_path", `String invalidation.source_path
    ; "invalidated_at", `Float invalidation.invalidated_at
    ; "reason", `String (invalidation_reason_to_string invalidation.reason)
    ]
;;

let invalidation_of_json = function
  | `Assoc fields
    when exact_object_fields [ "source_path"; "invalidated_at"; "reason" ] fields ->
    (match
       List.assoc_opt "source_path" fields
       , List.assoc_opt "invalidated_at" fields
       , List.assoc_opt "reason" fields
     with
     | Some (`String source_path), Some (`Float invalidated_at), Some (`String reason)
       when valid_source_path source_path && finite_nonnegative invalidated_at ->
       Option.map
         (fun reason -> { source_path; invalidated_at; reason })
         (invalidation_reason_of_string reason)
     | Some (`String source_path), Some (`Int invalidated_at), Some (`String reason)
       when valid_source_path source_path && invalidated_at >= 0 ->
       Option.map
         (fun reason ->
            { source_path; invalidated_at = float_of_int invalidated_at; reason })
         (invalidation_reason_of_string reason)
     | _ -> None)
  | _ -> None
;;

let list_of_json decode = function
  | `List values ->
    List.fold_left
      (fun decoded value ->
         match decoded, decode value with
         | Some decoded, Some value -> Some (value :: decoded)
         | _ -> None)
      (Some [])
      values
    |> Option.map List.rev
  | _ -> None
;;

module Path_set = Set.Make (String)

let paths_are_unique_and_disjoint facts invalidations =
  let add_unique seen path =
    if Path_set.mem path seen then None else Some (Path_set.add path seen)
  in
  let seen =
    List.fold_left
      (fun seen fact -> Option.bind seen (fun seen -> add_unique seen fact.source.path))
      (Some Path_set.empty)
      facts
  in
  List.fold_left
    (fun seen invalidation ->
       Option.bind seen (fun seen -> add_unique seen invalidation.source_path))
    seen
    invalidations
  |> Option.is_some
;;

let to_json snapshot =
  `Assoc
    [ "revision", `Int snapshot.revision
    ; "updated_at", `Float snapshot.updated_at
    ; "trace_id", `String snapshot.trace_id
    ; "facts", `List (List.map fact_to_json snapshot.facts)
    ; "invalidations", `List (List.map invalidation_to_json snapshot.invalidations)
    ]
;;

let of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "revision"; "updated_at"; "trace_id"; "facts"; "invalidations" ]
           fields ->
    (match
       List.assoc_opt "revision" fields
       , List.assoc_opt "updated_at" fields
       , List.assoc_opt "trace_id" fields
       , List.assoc_opt "facts" fields
       , List.assoc_opt "invalidations" fields
     with
     | ( Some (`Int revision)
       , Some updated_at_json
       , Some (`String trace_id)
       , Some facts_json
       , Some invalidations_json ) ->
       let updated_at =
         match updated_at_json with
         | `Float value -> Some value
         | `Int value -> Some (float_of_int value)
         | _ -> None
       in
       (match
          updated_at
          , list_of_json fact_of_json facts_json
          , list_of_json invalidation_of_json invalidations_json
        with
        | Some updated_at, Some facts, Some invalidations
          when revision >= 1
               && finite_nonnegative updated_at
               && non_empty trace_id
               && paths_are_unique_and_disjoint facts invalidations ->
          Some { revision; updated_at; trace_id; facts; invalidations }
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let parse path content =
  try
    match of_json (Yojson.Safe.from_string content) with
    | Some snapshot -> Ok snapshot
    | None -> Error (Printf.sprintf "%s: invalid source-bound memory snapshot" path)
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match Fs_compat.load_file_opt path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse path content in
      Some snapshot
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Sys_error message ->
    Error (Printf.sprintf "source-bound memory read failed path=%s: %s" path message)
;;

let read_source ~config ~meta ~source_path =
  let* resolved =
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta
      ~raw_path:source_path
  in
  try
    let stats = Unix.stat resolved in
    if stats.st_kind <> Unix.S_REG
    then Error (Printf.sprintf "source_path is not a regular file: %s" source_path)
    else if stats.st_size > max_source_bytes
    then
      Error
        (Printf.sprintf
           "source_path exceeds byte limit path=%s actual_bytes=%d max_bytes=%d"
           source_path
           stats.st_size
           max_source_bytes)
    else (
      let content = Fs_compat.load_file resolved in
      if String.length content > max_source_bytes
      then
        Error
          (Printf.sprintf
             "source_path exceeds byte limit path=%s actual_bytes=%d max_bytes=%d"
             source_path
             (String.length content)
             max_source_bytes)
      else Ok content)
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Sys_error message ->
    Error (Printf.sprintf "source_path read failed path=%s: %s" source_path message)
  | Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf
         "source_path read failed path=%s operation=%s: %s"
         source_path
         operation
         (Unix.error_message error))
;;

let save_snapshot path snapshot =
  let content = Yojson.Safe.pretty_to_string (to_json snapshot) ^ "\n" in
  match Fs_compat.save_file_atomic path content with
  | Ok () -> Ok snapshot
  | Error message ->
    Error
      (Printf.sprintf
         "source-bound memory atomic write failed path=%s: %s"
         path
         message)
;;

let trace_id meta = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id

let update_locked ?clock ~keepers_dir ~keeper_id build =
  Fs_compat.mkdir_p keepers_dir;
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  File_lock_eio.with_lock ?clock path (fun () ->
    let* previous =
      match Fs_compat.load_file_opt path with
      | None -> Ok None
      | Some content ->
        let+ snapshot = parse path content in
        Some snapshot
    in
    let* next, changed = build previous in
    if changed then save_snapshot path next else Ok next)
;;

let validate_recall_budget ~keepers_dir ~keeper_id ~facts ~invalidations =
  let* ordinary_facts =
    match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok None -> Ok []
    | Ok (Some snapshot) -> Ok snapshot.facts
    | Error detail -> Error detail
  in
  let lines =
    List.map Keeper_memory_os_budget.render_fact ordinary_facts
    @ List.map render_fact facts
    @ List.map render_invalidation invalidations
  in
  let actual_bytes = String.length (String.concat "\n" lines) in
  let max_bytes = Env_config.KeeperMemoryOs.recall_facts_max_bytes () in
  if actual_bytes <= max_bytes
  then Ok ()
  else
    Error
      (Printf.sprintf
         "source-bound memory would exceed combined recall byte budget actual_bytes=%d max_bytes=%d"
         actual_bytes
         max_bytes)
;;

let upsert_file_fact
      ?clock
      ~config
      ~meta
      ~keepers_dir
      ~now
      ~claim
      ~source_path
      ()
  =
  let source_path = String.trim source_path in
  let claim = String.trim claim in
  if not (valid_source_path source_path)
  then Error (Source_read_failed "source_path must be non-empty")
  else if not (non_empty claim)
  then Error (Store_write_failed "source-bound memory claim must be non-empty")
  else if not (finite_nonnegative now)
  then
    Error
      (Store_write_failed
         "source-bound memory timestamp must be finite and non-negative")
  else
    match read_source ~config ~meta ~source_path with
    | Error detail -> Error (Source_read_failed detail)
    | Ok content ->
      let incoming_source = { path = source_path; sha256 = sha256 content } in
      update_locked
        ?clock
        ~keepers_dir
        ~keeper_id:meta.Keeper_meta_contract.name
        (fun previous ->
      let previous_facts, previous_invalidations, revision, first_seen =
        match previous with
        | None -> [], [], 1, now
        | Some snapshot ->
          let first_seen =
            List.find_map
              (fun fact ->
                 if
                   String.equal fact.source.path source_path
                   && String.equal fact.claim claim
                   && String.equal fact.source.sha256 incoming_source.sha256
                 then Some fact.first_seen
                 else None)
              snapshot.facts
            |> Option.value ~default:now
          in
          snapshot.facts, snapshot.invalidations, snapshot.revision + 1, first_seen
      in
      let facts =
        previous_facts
        |> List.filter (fun fact -> not (String.equal fact.source.path source_path))
        |> fun facts ->
        facts @ [ { claim; first_seen; source = incoming_source } ]
      in
      let invalidations =
        List.filter
          (fun invalidation -> not (String.equal invalidation.source_path source_path))
          previous_invalidations
      in
      let* () =
        validate_recall_budget
          ~keepers_dir
          ~keeper_id:meta.Keeper_meta_contract.name
          ~facts
          ~invalidations
      in
      Ok
        ( { revision
          ; updated_at = now
          ; trace_id = trace_id meta
          ; facts
          ; invalidations
          }
        , true ))
      |> Result.map_error (fun detail -> Store_write_failed detail)
;;

let revalidate ?clock ~config ~meta ~keepers_dir ~now () =
  if not (finite_nonnegative now)
  then Error "source-bound memory timestamp must be finite and non-negative"
  else
    let+ snapshot =
      update_locked
        ?clock
        ~keepers_dir
        ~keeper_id:meta.Keeper_meta_contract.name
        (function
        | None ->
          Ok
            ( { revision = 1
              ; updated_at = now
              ; trace_id = trace_id meta
              ; facts = []
              ; invalidations = []
              }
            , false )
        | Some previous ->
          let facts_rev, newly_invalidated_rev =
            List.fold_left
              (fun (facts, invalidations) fact ->
                 match read_source ~config ~meta ~source_path:fact.source.path with
                 | Ok content when String.equal (sha256 content) fact.source.sha256 ->
                   fact :: facts, invalidations
                 | Ok _ ->
                   Log.Keeper.warn
                     "source-bound memory invalidated keeper=%s source=%S reason=source_changed"
                     meta.Keeper_meta_contract.name
                     fact.source.path;
                   ( facts
                   , { source_path = fact.source.path
                     ; invalidated_at = now
                     ; reason = Source_changed
                     }
                     :: invalidations )
                 | Error detail ->
                   Log.Keeper.warn
                     "source-bound memory invalidated keeper=%s source=%S reason=source_unavailable detail=%s"
                     meta.Keeper_meta_contract.name
                     fact.source.path
                     detail;
                   ( facts
                   , { source_path = fact.source.path
                     ; invalidated_at = now
                     ; reason = Source_unavailable
                     }
                     :: invalidations ))
              ([], [])
              previous.facts
          in
          let facts = List.rev facts_rev in
          let newly_invalidated = List.rev newly_invalidated_rev in
          if newly_invalidated = []
          then Ok (previous, false)
          else
            let invalidated_paths =
              List.fold_left
                (fun paths invalidation -> Path_set.add invalidation.source_path paths)
                Path_set.empty
                newly_invalidated
            in
            let retained_invalidations =
              List.filter
                (fun invalidation ->
                   not (Path_set.mem invalidation.source_path invalidated_paths))
                previous.invalidations
            in
            Ok
              ( { revision = previous.revision + 1
                ; updated_at = now
                ; trace_id = trace_id meta
                ; facts
                ; invalidations = retained_invalidations @ newly_invalidated
                }
              , true ))
    in
    let snapshot =
      if snapshot.facts = [] && snapshot.invalidations = []
      then None
      else Some snapshot
    in
    match snapshot with
    | None -> { snapshot = None; facts = []; invalidations = [] }
    | Some snapshot ->
      { snapshot = Some snapshot
      ; facts = snapshot.facts
      ; invalidations = snapshot.invalidations
      }
;;
