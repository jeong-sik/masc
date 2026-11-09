open Result.Syntax

type source = Artifact of Keeper_peer_artifact_ref.t | Draft of string

type source_error =
  | Artifact_fetch_failed of Keeper_peer_artifact.fetch_error
  | Draft_rejected of Keeper_composition_draft.error
  | Frozen_surface_required

let request = function
  | `Assoc fields when List.length fields = 2 ->
    let* package_id = match List.assoc_opt "package_id" fields with
      | Some (`String directory) -> Skill_reference.package_id_of_directory directory
          |> Result.map_error (fun error -> "package_id " ^ Skill_reference.package_id_error_to_string error)
      | _ -> Error "string package_id is required" in
    let* source = match List.assoc_opt "artifact" fields, List.assoc_opt "draft_sha256" fields with
      | Some artifact, None -> Keeper_peer_artifact.reference artifact |> Result.map (fun artifact -> Artifact artifact)
      | None, Some (`String digest) -> Ok (Draft digest)
      | _ -> Error "exactly one of artifact or draft_sha256 is required" in
    Ok (source, package_id)
  | _ -> Error "Expected package_id and exactly one of artifact or draft_sha256"
;;

let resolve_source ~draft_context ~config ~package_id = function
  | Artifact artifact ->
    Keeper_peer_artifact.fetch ~config artifact
    |> Result.map (fun (fetched : Keeper_peer_artifact.fetched) -> fetched.content)
    |> Result.map_error (fun error -> Artifact_fetch_failed error)
  | Draft sha256 ->
    (match draft_context with
     | None -> Error Frozen_surface_required
     | Some (capability_surface, keeper_name) ->
       Keeper_composition_draft.load_authored ~base_path:config.Workspace.base_path
         ~capability_surface ~keeper_name ~package_id ~sha256
       |> Result.map (fun source -> source.Keeper_composition_draft.source_text)
       |> Result.map_error (fun error -> Draft_rejected error))
;;

let failure ~class_ ~code ~message fields =
  Keeper_tool_execution.failure_data
    ~class_
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message
    (`Assoc
       ([ "ok", `Bool false
        ; "error", `String code
        ; "message", `String message
        ]
        @ fields))
;;

(* The verdict names the exact bytes it judged by a digest computed here from
   the bytes [Keeper_peer_artifact.fetch] returned, never by the caller's
   reference metadata and never as a normalized artifact reference. A
   normalized reference anywhere in a result makes [Tool_projection.project_result]
   require a durable result manifest, and a manifest projection would replace
   this inline verdict with a blob marker whose preview is empty. Without the
   manifest every call failed as "tool output artifact storage failed"
   (#37493). *)
let source_identity ~digest ~bytes =
  `Assoc
    [ "sha256", `String digest
    ; "bytes", `Int bytes
    ; "filename", `String "SKILL.md"
    ]
;;

(* Repeat cache for identical static validations (#49177): on 10-25 the same
   [keeper_skill_validate] input failed 1,632 times, re-parsing identical
   bytes on every call. Parsing is pure in (source bytes, package id,
   descriptor surface), so a repeat within one process reuses the first
   verdict instead of re-parsing the same nodes. Fetch failures
   (missing/unreadable artifact or draft) are not cached: the store can gain
   the bytes later. A hit only adds ["cached": true] to the data; a miss
   renders exactly the uncached shape. *)
module Repeat_cache = struct
  type cached =
    | Success of { fields : (string * Yojson.Safe.t) list }
    | Failure of
        { class_ : Tool_result.tool_failure_class
        ; code : string
        ; message : string
        ; fields : (string * Yojson.Safe.t) list
        }

  let max_entries = 64

  let table : (string, cached * Keeper_tool_descriptor.t list) Hashtbl.t =
    Hashtbl.create 64
  ;;

  let order : string Queue.t = Queue.create ()
  let mutex = Stdlib.Mutex.create ()

  let descriptors_digest descriptors =
    let canonical =
      List.map
        (fun (descriptor : Keeper_tool_descriptor.t) -> descriptor.Keeper_tool_descriptor.id)
        descriptors
      |> String.concat "\x00"
    in
    Agent_core_sha256.(digest_string canonical |> to_hex)
  ;;

  let key ~source_digest ~package_id ~descriptors =
    String.concat "\x00" [ source_digest; package_id; descriptors_digest descriptors ]
  ;;

  (* Same descriptor objects, as [Keeper_skill_catalog.prepared_matches]: an
     id that resolves to rebuilt objects re-parses instead of trusting a
     possibly stale verdict. *)
  let descriptors_match stored current =
    stored == current
    || (List.length stored = List.length current && List.for_all2 ( == ) stored current)
  ;;

  let find key descriptors =
    Stdlib.Mutex.protect mutex (fun () ->
      match Hashtbl.find_opt table key with
      | Some (cached, stored) when descriptors_match stored descriptors -> Some cached
      | Some _ | None -> None)
  ;;

  let add key descriptors cached =
    Stdlib.Mutex.protect mutex (fun () ->
      if Hashtbl.mem table key
      then Hashtbl.replace table key (cached, descriptors)
      else (
        while Hashtbl.length table >= max_entries && not (Queue.is_empty order) do
          Hashtbl.remove table (Queue.take order)
        done;
        Hashtbl.add table key (cached, descriptors);
        Queue.add key order))
  ;;
end

let handle ~descriptors ~draft_context ~config ~args =
  match request args with
  | Error message ->
    failure ~class_:Tool_result.Policy_rejection ~code:"invalid_skill_validation_request"
      ~message []
  | Ok (source, package_id) ->
    (match resolve_source ~draft_context ~config ~package_id source with
     | Error (Artifact_fetch_failed error) ->
       let code = match error with
         | Keeper_peer_artifact.Absent _ -> "artifact_not_found"
         | Keeper_peer_artifact.Unreadable _ -> "artifact_read_failed" in
       failure ~class_:(Keeper_peer_artifact.fetch_error_class error) ~code
         ~message:(Keeper_peer_artifact.fetch_error_to_string error) []
     | Error Frozen_surface_required ->
       failure ~class_:Tool_result.Policy_rejection ~code:"frozen_surface_required"
         ~message:"Prepared Skill validation requires the caller's frozen surface" []
     | Error (Draft_rejected error) ->
       let detail = Keeper_composition_draft.error_to_json error in
       let class_ = Keeper_composition_draft.failure_class error in
       failure ~class_ ~code:"composition_draft_rejected"
         ~message:(Yojson.Safe.to_string detail) [ "draft_error", detail ]
     | Ok source_text ->
       let directory = Skill_reference.package_id_to_string package_id in
       let source_digest = Agent_core_sha256.(digest_string source_text |> to_hex) in
       let source_bytes = String.length source_text in
       let identity =
         [ "source", source_identity ~digest:source_digest ~bytes:source_bytes
         ; "package_id", `String directory
         ; "validation", `String "static"
         ]
       in
       let key = Repeat_cache.key ~source_digest ~package_id:directory ~descriptors in
       let render () =
         match Keeper_skill_catalog.validate_authored_source ~descriptors ~directory source_text with
         | Error (Source_too_large { bytes; max_bytes }) ->
           Repeat_cache.Failure
             { class_ = Tool_result.Policy_rejection
             ; code = "source_too_large"
             ; message =
                 Printf.sprintf "Skill source is %d bytes; maximum is %d bytes" bytes max_bytes
             ; fields = identity @ [ "bytes", `Int bytes; "max_bytes", `Int max_bytes ]
             }
         | Error
             (Invalid_document
                (Keeper_skill_catalog.Body_too_large_to_read { bytes; max_bytes; _ } as error)) ->
           Repeat_cache.Failure
             { class_ = Tool_result.Policy_rejection
             ; code = Keeper_skill_catalog.error_code error
             ; message = Keeper_skill_catalog.error_to_string error
             ; fields = identity @ [ "bytes", `Int bytes; "max_bytes", `Int max_bytes ]
             }
         | Error
             (Invalid_document
                (( Keeper_skill_catalog.Definition_rejected _
                 | Keeper_skill_catalog.Unterminated_composition_block _
                 | Keeper_skill_catalog.Multiple_composition_blocks _
                 | Keeper_skill_catalog.Composition_rejected _
                 | Keeper_skill_catalog.Not_exactly_one_composition _
                 | Keeper_skill_catalog.Composition_name_mismatch _
                 | Keeper_skill_catalog.Composition_info_near_miss _
                 | Keeper_skill_catalog.Duplicate_skill _
                 | Keeper_skill_catalog.Body_blank _ ) as error)) ->
           Repeat_cache.Failure
             { class_ = Tool_result.Policy_rejection
             ; code = Keeper_skill_catalog.error_code error
             ; message = Keeper_skill_catalog.error_to_string error
             ; fields = identity
             }
         | Ok skill ->
           Repeat_cache.Success
             { fields =
                 identity
                 @ [ "ok", `Bool true
                   ; "kind", `String (Keeper_skill_catalog.surface_to_string skill.surface)
                   ; "name", `String skill.name
                   ; "description", `String skill.description
                   ]
             }
       in
       let emit ~cached = function
         | Repeat_cache.Success { fields } ->
           let fields =
             match cached with
             | true -> ("cached", `Bool true) :: fields
             | false -> fields
           in
           Keeper_tool_execution.success_data (`Assoc fields)
         | Repeat_cache.Failure { class_; code; message; fields } ->
           let fields =
             match cached with
             | true -> ("cached", `Bool true) :: fields
             | false -> fields
           in
           failure ~class_ ~code ~message fields
       in
       (match Repeat_cache.find key descriptors with
        | Some cached -> emit ~cached:true cached
        | None ->
          let parts = render () in
          Repeat_cache.add key descriptors parts;
          emit ~cached:false parts))
;;
