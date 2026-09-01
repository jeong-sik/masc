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

type resolved_message =
  { rmsg_index : int
  ; rmsg_role : string
  ; rmsg_bytes : int
  ; rmsg_sha256 : string
  ; rmsg_content : Yojson.Safe.t
  }

type resolved_tool_schema =
  { rts_index : int
  ; rts_name : string
  ; rts_bytes : int
  ; rts_sha256 : string
  ; rts_content : Yojson.Safe.t
  }

type resolved_system_prompt =
  { rsp_bytes : int
  ; rsp_sha256 : string
  ; rsp_text : string
  }

(* The record was [resolved] and its fields repeated [resolved_], so a reader
   met the word twice for one fact. The prefix now names the record, not the
   state. *)
type resolved =
  { rv_snapshot : t
  ; rv_system_prompt : resolved_system_prompt option
  ; rv_messages : resolved_message list
  ; rv_tool_schemas : resolved_tool_schema list
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
  | Artifact_json_invalid of
      { sha256 : string
      ; detail : string
      }

let ( let* ) = Result.bind

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
  | Artifact_json_invalid { sha256; detail } ->
    Printf.sprintf
      "provider-input artifact is not JSON sha256=%s: %s"
      sha256
      detail
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

let message_of_json = function
  | `Assoc fields when exact_fields [ "index"; "role"; "artifact" ] fields ->
    let* index_json = field "index" fields in
    let* index = nonnegative_int "message.index" index_json in
    let* role_json = field "role" fields in
    let* role = nonempty_string "message.role" role_json in
    let* artifact_json = field "artifact" fields in
    let* artifact = artifact_of_json artifact_json in
    Ok (index, { msg_index = index; msg_role = role; msg_artifact = artifact })
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

let store_artifact store ~reusable ~mime bytes =
  let bytes_length = String.length bytes in
  let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
  match Artifact_map.find_opt (sha256, mime) reusable with
  | Some artifact when artifact.art_bytes = bytes_length -> artifact, reusable
  | Some _ | None ->
    let reference = Tool_blob_store.put_durable store ~bytes ~mime in
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
      if String.equal system_prompt ""
      then None, reusable
      else
        let artifact, reusable =
          store_artifact
            blob_store
            ~reusable
            (* No space: the agent-core blob marker is space-delimited, so a
               spaced mime parameter breaks decode_from_agent_core (#32332). *)
            ~mime:"text/plain;charset=utf-8"
            system_prompt
        in
        Some artifact, reusable
    in
    let (reusable, _), messages =
      List.fold_left_map
        (fun (reusable, index) (message : Agent_core.Types.message) ->
           let payload =
             Keeper_context_core_message_json.message_to_json message
             |> Yojson.Safe.to_string
           in
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
             } ))
        (reusable, 0)
        messages
    in
    let _, tool_schemas =
      List.fold_left_map
        (fun (reusable, index) (tool : Agent_core.Tool.t) ->
           let payload = Agent_core.Tool.schema_to_json tool |> Yojson.Safe.to_string in
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
        tools
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
    match
      Dated_jsonl.find_latest_entry_result store (fun entry ->
        match snapshot_of_recent_entry entry with
        | Error error -> Some (Error error)
        | Ok snapshot when Ids.Turn_ref.equal snapshot.turn_ref turn_ref ->
          Some (Ok snapshot)
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

let parse_artifact_json ~sha256 content =
  match Yojson.Safe.from_string content with
  | json -> Ok json
  | exception Yojson.Json_error detail ->
    Error (Artifact_json_invalid { sha256; detail })
;;

let rec resolve_messages store reversed = function
  | [] -> Ok (List.rev reversed)
  | message :: rest ->
    let* sha256, payload = fetch_artifact store message.msg_artifact in
    let* content = parse_artifact_json ~sha256 payload in
    resolve_messages
      store
      ({ rmsg_index = message.msg_index
       ; rmsg_role = message.msg_role
       ; rmsg_bytes = message.msg_artifact.art_bytes
       ; rmsg_sha256 = sha256
       ; rmsg_content = content
       }
       :: reversed)
      rest
;;

let rec resolve_tool_schemas store reversed = function
  | [] -> Ok (List.rev reversed)
  | tool :: rest ->
    let* sha256, payload = fetch_artifact store tool.ts_artifact in
    let* content = parse_artifact_json ~sha256 payload in
    resolve_tool_schemas
      store
      ({ rts_index = tool.ts_index
       ; rts_name = tool.ts_name
       ; rts_bytes = tool.ts_artifact.art_bytes
       ; rts_sha256 = sha256
       ; rts_content = content
       }
       :: reversed)
      rest
;;

let read_resolved ~config ~keeper ~turn_ref =
  let* snapshot = find_snapshot ~config ~keeper ~turn_ref in
  let store = Tool_blob_store.create ~base_path:config.base_path in
  let* resolved_system_prompt =
    match snapshot.system_prompt with
    | None -> Ok None
    | Some artifact ->
      let* sha256, text = fetch_artifact store artifact in
      Ok
        (Some
           { rsp_bytes = artifact.art_bytes; rsp_sha256 = sha256; rsp_text = text })
  in
  let* resolved_messages = resolve_messages store [] snapshot.messages in
  let* resolved_tool_schemas =
    resolve_tool_schemas store [] snapshot.tool_schemas
  in
  Ok
    { rv_snapshot = snapshot
    ; rv_system_prompt = resolved_system_prompt
    ; rv_messages = resolved_messages
    ; rv_tool_schemas = resolved_tool_schemas
    }
;;

let resolved_message_to_json message =
  `Assoc
    [ "index", `Int message.rmsg_index
    ; "role", `String message.rmsg_role
    ; "bytes", `Int message.rmsg_bytes
    ; "sha256", `String message.rmsg_sha256
    ; "content", message.rmsg_content
    ]
;;

let resolved_tool_schema_to_json tool =
  `Assoc
    [ "index", `Int tool.rts_index
    ; "name", `String tool.rts_name
    ; "bytes", `Int tool.rts_bytes
    ; "sha256", `String tool.rts_sha256
    ; "content", tool.rts_content
    ]
;;

let resolved_to_json resolved =
  let snapshot = resolved.rv_snapshot in
  `Assoc
    [ "schema", `String "masc.resolved-provider-input.v1"
    ; "keeper", `String snapshot.keeper
    ; "trace_id", `String snapshot.trace_id
    ; "absolute_turn", `Int snapshot.absolute_turn
    ; "turn_ref", Ids.Turn_ref.to_yojson snapshot.turn_ref
    ; "runtime_profile", `String snapshot.runtime_profile
    ; "captured_at", `Float snapshot.captured_at
    ; ( "wire"
      , Llm_provider.Request_wire_observer.observation_to_yojson snapshot.wire )
    ; ( "system_prompt"
      , match resolved.rv_system_prompt with
        | Some prompt ->
          `Assoc
            [ "bytes", `Int prompt.rsp_bytes
            ; "sha256", `String prompt.rsp_sha256
            ; "text", `String prompt.rsp_text
            ]
        | None -> `Null )
    ; ( "messages"
      , `List (List.map resolved_message_to_json resolved.rv_messages) )
    ; ( "tool_schemas"
      , `List
          (List.map resolved_tool_schema_to_json resolved.rv_tool_schemas)
      )
    ]
;;
