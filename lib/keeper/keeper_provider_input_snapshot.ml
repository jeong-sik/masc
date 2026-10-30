(* Field names carry a per-record prefix. Four records here shared [bytes],
   four shared [index], and two shared [artifact]; OCaml gives an unqualified
   field to the last record that declared it, so every unannotated access was
   resolving against whichever record happened to be defined last. That cost
   twelve build repairs in one merge burst (#32298) and two more after it. *)
type artifact =
  { art_bytes : int
  ; art_content_ref : string
  }

type message =
  { msg_index : int
  ; msg_role : string
  ; msg_artifact : artifact
  ; msg_media : (string * Agent_core.History.stored) list
  }

type tool_schema =
  { ts_index : int
  ; ts_name : string
  ; ts_artifact : artifact
  }

type t =
  { keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; system_prompt : artifact option
  ; messages : message list
  ; tool_schemas : tool_schema list
  }

(* One retained part of a request, in the order the request carries them:
   the system prompt, the messages, the tool schemas. [part_index] is the
   position in that order, so a part request names one part of one row. *)
type part_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type part =
  { part_index : int
  ; part_kind : part_kind
  ; part_bytes : int
  ; part_sha256 : string
  }

type manifest =
  { mf_snapshot : t
  ; mf_parts : part list
  }

type part_content =
  { pc_keeper : string
  ; pc_turn_ref : Ids.Turn_ref.t
  ; pc_part : part
  ; pc_text : string
  }

type read_error =
  | Unknown_keeper of string
  | Store_read_failed of Dated_jsonl.read_error
  | Malformed_snapshot of string
  | Snapshot_not_found of Ids.Turn_ref.t
  | Invalid_artifact_reference of string
  | Artifact_read_failed of string
  | Artifact_missing of string
  | Artifact_length_mismatch of
      { sha256 : string
      ; expected : int
      ; actual : int
      }
  | Part_not_found of
      { turn_ref : Ids.Turn_ref.t
      ; index : int
      }

open Result.Syntax

module Artifact_key = struct
  type t = string * string

  let compare (left_sha, left_mime) (right_sha, right_mime) =
    match String.compare left_sha right_sha with
    | 0 -> String.compare left_mime right_mime
    | order -> order
  ;;
end

module Artifact_map = Map.Make (Artifact_key)

let read_error_to_string = function
  | Unknown_keeper keeper -> Printf.sprintf "invalid keeper name: %s" keeper
  | Store_read_failed error -> Dated_jsonl.read_error_to_string error
  | Malformed_snapshot detail -> "provider-input snapshot is malformed: " ^ detail
  | Snapshot_not_found turn_ref ->
    Printf.sprintf
      "no provider-input snapshot for %s"
      (Ids.Turn_ref.to_string turn_ref)
  | Invalid_artifact_reference detail ->
    "provider-input artifact reference is invalid: " ^ detail
  | Artifact_read_failed detail -> "provider-input artifact read failed: " ^ detail
  | Artifact_missing sha256 -> "provider-input artifact is absent: " ^ sha256
  | Artifact_length_mismatch { sha256; expected; actual } ->
    Printf.sprintf
      "provider-input artifact length mismatch sha256=%s expected=%d actual=%d"
      sha256
      expected
      actual
  | Part_not_found { turn_ref; index } ->
    Printf.sprintf
      "provider-input for %s has no part %d"
      (Ids.Turn_ref.to_string turn_ref)
      index
;;

(* The JSON keys keep their old spelling: the prefixes name fields in OCaml,
   not the persisted schema, and renaming those would strand every row already
   on disk. *)
let artifact_to_json artifact =
  `Assoc
    [ "bytes", `Int artifact.art_bytes
    ; "content_ref", `String artifact.art_content_ref
    ]
;;

let message_to_json message =
  `Assoc
    [ "index", `Int message.msg_index
    ; "role", `String message.msg_role
    ; "artifact", artifact_to_json message.msg_artifact
    ; ( "media"
      , `List
          (List.map
             (fun (media_type, stored) ->
                Agent_core.History.stored_source_to_json ~media_type stored)
             message.msg_media) )
    ]
;;

let tool_schema_to_json tool =
  `Assoc
    [ "index", `Int tool.ts_index
    ; "name", `String tool.ts_name
    ; "artifact", artifact_to_json tool.ts_artifact
    ]
;;

let to_json snapshot =
  `Assoc
    [ "schema", `String "masc.provider-input-snapshot.v1"
    ; "keeper", `String snapshot.keeper
    ; "trace_id", `String snapshot.trace_id
    ; "absolute_turn", `Int snapshot.absolute_turn
    ; "turn_ref", Ids.Turn_ref.to_yojson snapshot.turn_ref
    ; "runtime_profile", `String snapshot.runtime_profile
    ; "captured_at", `Float snapshot.captured_at
    ; ( "wire"
      , Llm_provider.Request_wire_observer.observation_to_yojson snapshot.wire )
    ; ( "system_prompt"
      , match snapshot.system_prompt with
        | Some artifact -> artifact_to_json artifact
        | None -> `Null )
    ; "messages", `List (List.map message_to_json snapshot.messages)
    ; "tool_schemas", `List (List.map tool_schema_to_json snapshot.tool_schemas)
    ]
;;

let exact_fields expected fields =
  List.length expected = List.length fields
  && List.for_all
       (fun name ->
          match List.filter (fun (key, _) -> String.equal key name) fields with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       expected
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ name)
;;

let nonempty_string name = function
  | `String value when not (String.equal value "") -> Ok value
  | _ -> Error (name ^ " must be a non-empty string")
;;

let nonnegative_int name = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (name ^ " must be a non-negative integer")
;;

let artifact_of_json = function
  | `Assoc fields when exact_fields [ "bytes"; "content_ref" ] fields ->
    let* bytes_json = field "bytes" fields in
    let* bytes = nonnegative_int "artifact.bytes" bytes_json in
    let* content_ref_json = field "content_ref" fields in
    let* content_ref = nonempty_string "artifact.content_ref" content_ref_json in
    Ok { art_bytes = bytes; art_content_ref = content_ref }
  | `Assoc _ -> Error "artifact fields are not exact"
  | _ -> Error "artifact must be an object"
;;

let indexed_list ~name decode values =
  let rec loop index reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
      let* item_index, item = decode value in
      if item_index <> index
      then Error (Printf.sprintf "%s index %d is not contiguous" name item_index)
      else loop (index + 1) (item :: reversed) rest
  in
  loop 0 [] values
;;

let stored_media_of_json = function
  | `List values ->
    List.fold_right
      (fun value acc ->
         let* rest = acc in
         match Agent_core.History.stored_source_of_json value with
         | Agent_core.History.Decoded_stored_source { media_type; stored } ->
           Ok ((media_type, stored) :: rest)
         | Invalid_stored_source error ->
           Error ("message.media: " ^ Agent_core.History.decode_error_to_string error)
         | Not_stored_source -> Error "message.media holds a value that is not a stored source")
      values
      (Ok [])
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    Error "message.media must be a list"
;;

let message_of_json = function
  | `Assoc fields when exact_fields [ "index"; "role"; "artifact"; "media" ] fields ->
    let* index_json = field "index" fields in
    let* index = nonnegative_int "message.index" index_json in
    let* role_json = field "role" fields in
    let* role = nonempty_string "message.role" role_json in
    let* artifact_json = field "artifact" fields in
    let* artifact = artifact_of_json artifact_json in
    let* media_json = field "media" fields in
    let* media = stored_media_of_json media_json in
    Ok
      ( index
      , { msg_index = index; msg_role = role; msg_artifact = artifact; msg_media = media } )
  | `Assoc _ -> Error "message fields are not exact"
  | _ -> Error "message must be an object"
;;

let tool_schema_of_json = function
  | `Assoc fields when exact_fields [ "index"; "name"; "artifact" ] fields ->
    let* index_json = field "index" fields in
    let* index = nonnegative_int "tool_schema.index" index_json in
    let* name_json = field "name" fields in
    let* name = nonempty_string "tool_schema.name" name_json in
    let* artifact_json = field "artifact" fields in
    let* artifact = artifact_of_json artifact_json in
    Ok (index, { ts_index = index; ts_name = name; ts_artifact = artifact })
  | `Assoc _ -> Error "tool_schema fields are not exact"
  | _ -> Error "tool_schema must be an object"
;;

let list_field name decode fields =
  let* json = field name fields in
  match json with
  | `List values -> indexed_list ~name decode values
  | _ -> Error (name ^ " must be a list")
;;

let of_json = function
  | `Assoc fields
    when exact_fields
           [ "schema"
           ; "keeper"
           ; "trace_id"
           ; "absolute_turn"
           ; "turn_ref"
           ; "runtime_profile"
           ; "captured_at"
           ; "wire"
           ; "system_prompt"
           ; "messages"
           ; "tool_schemas"
           ]
           fields ->
    let* schema_json = field "schema" fields in
    let* schema = nonempty_string "schema" schema_json in
    let* () =
      if String.equal schema "masc.provider-input-snapshot.v1"
      then Ok ()
      else Error ("unknown schema " ^ schema)
    in
    let* keeper_json = field "keeper" fields in
    let* keeper = nonempty_string "keeper" keeper_json in
    let* trace_json = field "trace_id" fields in
    let* trace_id = nonempty_string "trace_id" trace_json in
    let* absolute_turn_json = field "absolute_turn" fields in
    let* absolute_turn = nonnegative_int "absolute_turn" absolute_turn_json in
    let* turn_ref_json = field "turn_ref" fields in
    let* turn_ref =
      match Ids.Turn_ref.of_yojson turn_ref_json with
      | Ok turn_ref -> Ok turn_ref
      | Error detail -> Error detail
    in
    let expected_turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
    let* () =
      if Ids.Turn_ref.equal turn_ref expected_turn_ref
      then Ok ()
      else Error "turn_ref does not match trace_id and absolute_turn"
    in
    let* runtime_json = field "runtime_profile" fields in
    let* runtime_profile = nonempty_string "runtime_profile" runtime_json in
    let* captured_at_json = field "captured_at" fields in
    let* captured_at =
      match captured_at_json with
      | `Float value when Float.is_finite value && value >= 0. -> Ok value
      | `Int value when value >= 0 -> Ok (Float.of_int value)
      | _ -> Error "captured_at must be a non-negative finite number"
    in
    let* wire_json = field "wire" fields in
    let* wire =
      match Llm_provider.Request_wire_observer.observation_of_yojson wire_json with
      | Ok wire -> Ok wire
      | Error detail -> Error detail
    in
    let* system_prompt_json = field "system_prompt" fields in
    let* system_prompt =
      match system_prompt_json with
      | `Null -> Ok None
      | json -> Result.map Option.some (artifact_of_json json)
    in
    let* messages = list_field "messages" message_of_json fields in
    let* tool_schemas = list_field "tool_schemas" tool_schema_of_json fields in
    Ok
      { keeper
      ; trace_id
      ; absolute_turn
      ; turn_ref
      ; runtime_profile
      ; captured_at
      ; wire
      ; system_prompt
      ; messages
      ; tool_schemas
      }
  | `Assoc _ -> Error "snapshot fields are not exact"
  | _ -> Error "snapshot must be an object"
;;

let reusable_artifacts snapshot =
  let add reusable artifact =
    match Tool_output.decode_from_agent_core artifact.art_content_ref with
    | Tool_output.Decoded reference when reference.bytes = artifact.art_bytes ->
      Artifact_map.add (reference.sha256, reference.mime) artifact reusable
    | Tool_output.Decoded _
    | Tool_output.Not_marker
    | Tool_output.Invalid_marker _ -> reusable
  in
  let reusable =
    match snapshot.system_prompt with
    | Some artifact -> add Artifact_map.empty artifact
    | None -> Artifact_map.empty
  in
  let reusable =
    List.fold_left
      (fun reusable message -> add reusable message.msg_artifact)
      reusable
      snapshot.messages
  in
  List.fold_left
    (fun reusable tool -> add reusable tool.ts_artifact)
    reusable
    snapshot.tool_schemas
;;

let snapshot_of_recent_entry = function
  | Dated_jsonl.Malformed_json { path; line_number; detail } ->
    Error
      (Malformed_snapshot
         (Printf.sprintf
            "%s:%s: %s"
            path
            (Option.fold ~none:"?" ~some:string_of_int line_number)
            detail))
  | Dated_jsonl.Parsed json ->
    Result.map_error (fun detail -> Malformed_snapshot detail) (of_json json)
;;

let latest_snapshot_for_reuse store =
  match Dated_jsonl.find_latest_entry_result store (fun entry ->
    Some (snapshot_of_recent_entry entry)) with
  | Error error -> Error (Store_read_failed error)
  | Ok None -> Ok None
  | Ok (Some (Ok snapshot)) -> Ok (Some snapshot)
  | Ok (Some (Error error)) -> Error error
;;

(* What the pool computes for one artifact: the bytes and their digest. The
   digest is a C routine that does not yield, and a turn's snapshot hashes
   every message in the request; until 2026-09-05 that ran on the main
   domain once per turn (RFC main-domain-scheduler-latency section 8.8). *)
type payload =
  { payload_bytes : string
  ; payload_sha256 : string
  }

let payload_of_string payload_bytes =
  { payload_bytes
  ; payload_sha256 = Agent_core_sha256.(digest_string payload_bytes |> to_hex)
  }
;;

let message_payload (message : Agent_core.Types.message) =
  Keeper_context_core_message_json.message_to_json message
  |> Yojson.Safe.to_string
  |> payload_of_string
;;

let tool_schema_payload (tool : Agent_core.Tool.t) =
  let json = Agent_core.Tool.schema_to_json tool in
  Agent_core.Base.Schema_observation.encode
    ~site:Provider_snapshot_encode ~schema:tool.Agent_core.Tool.schema
    (fun () -> Yojson.Safe.to_string json)
  |> payload_of_string
;;

let store_artifact store ~reusable ~mime { payload_bytes = bytes; payload_sha256 = sha256 } =
  let bytes_length = String.length bytes in
  match Artifact_map.find_opt (sha256, mime) reusable with
  | Some artifact when artifact.art_bytes = bytes_length -> artifact, reusable
  | Some _ | None ->
    let reference =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Tool_blob_store.put_durable_reuse store ~bytes ~mime)
    in
    let reference = Tool_output.with_preview reference "" in
    let artifact =
      { art_bytes = bytes_length
      ; art_content_ref =
          Tool_output.encode_for_agent_core (Tool_output.Stored reference)
      }
    in
    artifact, Artifact_map.add (sha256, mime) artifact reusable
;;

let write_best_effort
      ~(config : Workspace.config)
      ~keeper
      ~trace_id
      ~absolute_turn
      ~runtime_profile
      ~wire
      ~system_prompt
      ~messages
      ~tools
  =
  let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
  let write () =
    (* Serialising and hashing every message and tool schema is pure, so the
       CPU pool does it. Reuse lookup, map updates and the append stay on
       this fiber; each new blob's addressing and durable put use the IO pool. *)
    let work = Agent_core.Base.Schema_observation.capture (fun () ->
      Agent_core.Base.Schema_observation.measure ~site:Worker_work (fun () ->
        ( (if String.equal system_prompt "" then None else Some (payload_of_string system_prompt))
        , List.map message_payload messages
        , List.map tool_schema_payload tools )))
    in
    let system_payload, message_payloads, tool_payloads =
      Agent_core.Base.Schema_observation.measure ~site:Worker_queue_and_await
        (fun () -> Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ work)
    in
    let blob_store = Tool_blob_store.create ~base_path:config.base_path in
    let reusable =
      let store = Keeper_types_support.keeper_provider_input_store config keeper in
      match latest_snapshot_for_reuse store with
      | Ok (Some snapshot) -> reusable_artifacts snapshot
      | Ok None -> Artifact_map.empty
      | Error error ->
        Log.Keeper.warn
          ~keeper_name:keeper
          "provider-input artifact reuse unavailable: %s"
          (read_error_to_string error);
        Artifact_map.empty
    in
    let system_prompt, reusable =
      match system_payload with
      | None -> None, reusable
      | Some payload ->
        let artifact, reusable =
          store_artifact
            blob_store
            ~reusable
            (* No space: the agent-core blob marker is space-delimited, so a
               spaced mime parameter breaks decode_from_agent_core (#32332),
               and make_artifact_ref now rejects such a media type outright
               rather than writing a marker that cannot be read back. *)
            ~mime:"text/plain;charset=utf-8"
            payload
        in
        Some artifact, reusable
    in
    let (reusable, _), messages =
      List.fold_left_map
        (fun (reusable, index) ((message : Agent_core.Types.message), payload) ->
           let artifact, reusable =
             store_artifact
               blob_store
               ~reusable
               ~mime:"application/vnd.masc.provider-input-message+json"
               payload
           in
           ( (reusable, index + 1)
           , { msg_index = index
             ; msg_role = Agent_core.Types.role_to_string message.role
             ; msg_artifact = artifact
             ; msg_media = List.concat_map Agent_core.History.stored_media message.content
             } ))
        (reusable, 0)
        (List.combine messages message_payloads)
    in
    let _, tool_schemas =
      List.fold_left_map
        (fun (reusable, index) ((tool : Agent_core.Tool.t), payload) ->
           let artifact, reusable =
             store_artifact
               blob_store
               ~reusable
               ~mime:"application/vnd.masc.provider-input-tool-schema+json"
               payload
           in
           ( reusable, index + 1 )
           , { ts_index = index
             ; ts_name = tool.schema.name
             ; ts_artifact = artifact
             })
        (reusable, 0)
        (List.combine tools tool_payloads)
    in
    let snapshot =
      { keeper
      ; trace_id
      ; absolute_turn
      ; turn_ref
      ; runtime_profile
      ; captured_at = Time_compat.now ()
      ; wire
      ; system_prompt
      ; messages
      ; tool_schemas
      }
    in
    Dated_jsonl.append
      (Keeper_types_support.keeper_provider_input_store config keeper)
      (to_json snapshot)
  in
  match write () with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as error) -> raise error
  | exception exn ->
    Log.Keeper.warn
      ~keeper_name:keeper
      "provider-input snapshot write failed trace=%s turn=%d: %s"
      trace_id
      absolute_turn
      (Printexc.to_string exn)
;;

let find_snapshot ~config ~keeper ~turn_ref =
  if not (Keeper_config.validate_name keeper)
  then Error (Unknown_keeper keeper)
  else
    let store = Keeper_types_support.keeper_provider_input_store config keeper in
    let wanted_trace = Ids.Turn_ref.trace_id turn_ref in
    let wanted_turn = Ids.Turn_ref.absolute_turn turn_ref in
    match
      Dated_jsonl.find_latest_entry_result store (fun entry ->
        match snapshot_of_recent_entry entry with
        | Error error -> Some (Error error)
        | Ok snapshot when Ids.Turn_ref.equal snapshot.turn_ref turn_ref ->
          Some (Ok snapshot)
        | Ok snapshot
          when String.equal snapshot.trace_id wanted_trace
               && snapshot.absolute_turn < wanted_turn ->
          (* A trace appends its turns in order, so the entries before this one
             are older turns of it: the turn asked for was never written here.
             Reading on would decode every remaining snapshot, and a live
             store is 79-231 MB of them. *)
          Some (Error (Snapshot_not_found turn_ref))
        | Ok _ -> None)
    with
    | Error error -> Error (Store_read_failed error)
    | Ok None -> Error (Snapshot_not_found turn_ref)
    | Ok (Some result) -> result
;;

let artifact_reference artifact =
  match Tool_output.decode_from_agent_core artifact.art_content_ref with
  | Tool_output.Decoded reference when reference.bytes = artifact.art_bytes ->
    Ok reference
  | Tool_output.Decoded reference ->
    Error
      (Invalid_artifact_reference
         (Printf.sprintf
            "declared bytes %d do not match marker bytes %d"
            artifact.art_bytes
            reference.bytes))
  | Tool_output.Not_marker ->
    Error (Invalid_artifact_reference "value is not an artifact marker")
  | Tool_output.Invalid_marker { detail } ->
    Error (Invalid_artifact_reference detail)
;;

let fetch_artifact store artifact =
  let* reference = artifact_reference artifact in
  match Tool_blob_store.fetch store ~sha256:reference.sha256 with
  | Error error ->
    Error
      (Artifact_read_failed (Tool_blob_store.fetch_error_to_string error))
  | Ok None -> Error (Artifact_missing reference.sha256)
  | Ok (Some content) when String.length content = artifact.art_bytes ->
    Ok (reference.sha256, content)
  | Ok (Some content) ->
    Error
      (Artifact_length_mismatch
         { sha256 = reference.sha256
         ; expected = artifact.art_bytes
         ; actual = String.length content
         })
;;

let part_artifacts snapshot =
  let system_prompt =
    match snapshot.system_prompt with
    | None -> []
    | Some artifact -> [ System_prompt, artifact ]
  in
  let messages =
    List.map
      (fun message -> Message { role = message.msg_role }, message.msg_artifact)
      snapshot.messages
  in
  let tool_schemas =
    List.map
      (fun tool -> Tool_schema { name = tool.ts_name }, tool.ts_artifact)
      snapshot.tool_schemas
  in
  List.mapi
    (fun index (kind, artifact) -> index, kind, artifact)
    (system_prompt @ messages @ tool_schemas)
;;

(* The digest comes from the row's artifact marker, so listing a request reads
   no blob. A request of 212 messages and 57 tool schemas used to read, hash
   and parse every one of them to answer a list (#37752). *)
let rec parts_of reversed = function
  | [] -> Ok (List.rev reversed)
  | (index, kind, artifact) :: rest ->
    let* reference = artifact_reference artifact in
    parts_of
      ({ part_index = index
       ; part_kind = kind
       ; part_bytes = artifact.art_bytes
       ; part_sha256 = reference.sha256
       }
       :: reversed)
      rest
;;

let read_manifest ~config ~keeper ~turn_ref =
  let* snapshot = find_snapshot ~config ~keeper ~turn_ref in
  let* parts = parts_of [] (part_artifacts snapshot) in
  Ok { mf_snapshot = snapshot; mf_parts = parts }
;;

(* Only a part this row lists is read. The blob store is shared by the whole
   workspace, so a digest alone must not open any blob in it. *)
let read_part ~config ~keeper ~turn_ref ~index =
  let* snapshot = find_snapshot ~config ~keeper ~turn_ref in
  match
    List.find_opt
      (fun (candidate, _, _) -> candidate = index)
      (part_artifacts snapshot)
  with
  | None -> Error (Part_not_found { turn_ref; index })
  | Some (index, kind, artifact) ->
    let store = Tool_blob_store.create ~base_path:config.base_path in
    let* sha256, text = fetch_artifact store artifact in
    Ok
      { pc_keeper = snapshot.keeper
      ; pc_turn_ref = snapshot.turn_ref
      ; pc_part =
          { part_index = index
          ; part_kind = kind
          ; part_bytes = artifact.art_bytes
          ; part_sha256 = sha256
          }
      ; pc_text = text
      }
;;

let manifest_schema = "masc.provider-input-manifest.v1"
let part_schema = "masc.provider-input-part.v1"

let part_to_json part =
  let kind =
    match part.part_kind with
    | System_prompt -> [ "kind", `String "system_prompt" ]
    | Message { role } -> [ "kind", `String "message"; "role", `String role ]
    | Tool_schema { name } -> [ "kind", `String "tool_schema"; "name", `String name ]
  in
  `Assoc
    (("index", `Int part.part_index)
     :: kind
     @ [ "bytes", `Int part.part_bytes; "sha256", `String part.part_sha256 ])
;;

let manifest_to_json manifest =
  let snapshot = manifest.mf_snapshot in
  `Assoc
    [ "schema", `String manifest_schema
    ; "keeper", `String snapshot.keeper
    ; "trace_id", `String snapshot.trace_id
    ; "absolute_turn", `Int snapshot.absolute_turn
    ; "turn_ref", Ids.Turn_ref.to_yojson snapshot.turn_ref
    ; "runtime_profile", `String snapshot.runtime_profile
    ; "captured_at", `Float snapshot.captured_at
    ; ( "wire"
      , Llm_provider.Request_wire_observer.observation_to_yojson snapshot.wire )
    ; "parts", `List (List.map part_to_json manifest.mf_parts)
    ]
;;

let part_content_to_json content =
  `Assoc
    [ "schema", `String part_schema
    ; "keeper", `String content.pc_keeper
    ; "turn_ref", Ids.Turn_ref.to_yojson content.pc_turn_ref
    ; "part", part_to_json content.pc_part
    ; "text", `String content.pc_text
    ]
;;
