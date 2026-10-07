type t =
  { conversation : (Keeper_turn_fragments.recent_messages, string) result
  ; autonomous_reply : (Keeper_turn_fragments.recent_messages, string) result
  }

let collect ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  let session_dir = Keeper_types_support.keeper_session_dir config
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
  (* Same eight-message conversation window as direct-turn context, but tools
     cannot displace conversation and the messages retain their provenance.
     The latest autonomous conclusion is separate: it may contain the next
     step taken after the direct exchange. Neither is inferred open work. *)
  let conversation = Keeper_turn_fragments.read_recent_messages
      ~session_dir ~roles:[Agent_core.Types.User; Assistant] ~limit:8 Main in
  let autonomous_reply = Keeper_turn_fragments.read_recent_messages
      ~session_dir ~roles:[Agent_core.Types.Assistant] ~limit:1 Internal in
  { conversation; autonomous_reply }

type transmission = Absent | Evidence of string | Unavailable of string

let transmit ~base_path ~tools work =
  let message_json (observed : Keeper_turn_fragments.observed_message) =
    `Assoc
      [ "turn_ref", Ids.Turn_ref.to_yojson observed.turn_ref
      ; "recorded_at", `Float observed.recorded_at
      ; "source", (match observed.source with None -> `Null | Some s -> `String s)
      ; "message", Keeper_official_client_context_codec.message_to_json observed.message ] in
  let observed_json = function
    | Ok window -> `Assoc ["messages", `List (List.map message_json window.Keeper_turn_fragments.messages);
                           "prefix_omitted", `Bool window.prefix_omitted]
    | Error detail -> `Assoc ["unavailable", `String detail] in
  match work.conversation, work.autonomous_reply with
  | Ok {messages=[];prefix_omitted=false}, Ok {messages=[];prefix_omitted=false} -> Absent
  | _ ->
    let bytes = Yojson.Safe.to_string (`Assoc
        ["recent_conversation", observed_json work.conversation;
         "latest_autonomous_reply", observed_json work.autonomous_reply]) in
    (* The existing artifact preview envelope is already safe to carry inline.
       Everything larger travels through its canonical reader, independently
       of the history's Wide/Small policy: this is extra pinned context. *)
    if String.length bytes <= Tool_blob_store.preview_max then Evidence bytes
    else match Keeper_recovery_transmission.require_reader tools with
    | Error _ -> Unavailable "Recent-work excerpt requires the canonical artifact reader; this tool surface does not offer it. Use retained conversation; absence of this excerpt does not mean no work remains."
    | Ok () ->
      (try
         let marker = Tool_blob_store.put (Tool_blob_store.create ~base_path)
             ~bytes ~mime:"application/json" |> Tool_output.encode_for_agent_core in
         Evidence (if String.length marker < String.length bytes then marker else bytes)
       with Sys_error detail -> Unavailable ("Recent-work artifact could not be stored: " ^ detail))
