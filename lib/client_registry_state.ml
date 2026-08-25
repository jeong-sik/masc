module String_map = Set_util.StringMap

type t =
  { identities : Client_identity.t String_map.t
  ; session_map : string String_map.t
  ; resolved_map : (string * bool) String_map.t
  }

type install_outcome =
  | Registered of Client_identity.t
  | Reused of Client_identity.t

let empty =
  { identities = String_map.empty
  ; session_map = String_map.empty
  ; resolved_map = String_map.empty
  }
;;

let identity_for_mcp_session state mcp_session_id =
  Option.bind
    (String_map.find_opt mcp_session_id state.session_map)
    (fun session_key -> String_map.find_opt session_key state.identities)
;;

let reuse_session ~now ~mcp_session_id state =
  match identity_for_mcp_session state mcp_session_id with
  | None -> None
  | Some identity ->
    let last_seen = Float.max identity.last_seen now in
    let identity : Client_identity.t = { identity with last_seen } in
    let identities =
      String_map.add identity.Client_identity.session_key identity state.identities
    in
    Some ({ state with identities }, identity)
;;

let install_session ~now ~mcp_session_id ~candidate state =
  match reuse_session ~now ~mcp_session_id state with
  | Some (state, identity) -> state, Reused identity
  | None ->
    let identities =
      String_map.add
        candidate.Client_identity.session_key
        candidate
        state.identities
    in
    let session_map =
      String_map.add
        mcp_session_id
        candidate.Client_identity.session_key
        state.session_map
    in
    { state with identities; session_map }, Registered candidate
;;

let resolved_name state mcp_session_id =
  String_map.find_opt mcp_session_id state.resolved_map
;;

let cache_resolved_name ~mcp_session_id ~name ~is_ephemeral state =
  { state with
    resolved_map =
      String_map.add mcp_session_id (name, is_ephemeral) state.resolved_map
  }
;;

let unregister_mcp_session ~mcp_session_id state =
  match String_map.find_opt mcp_session_id state.session_map with
  | None -> state
  | Some session_key ->
    let session_map = String_map.remove mcp_session_id state.session_map in
    let still_referenced =
      String_map.exists
        (fun _ mapped_session_key -> String.equal mapped_session_key session_key)
        session_map
    in
    let identities =
      if still_referenced
      then state.identities
      else String_map.remove session_key state.identities
    in
    { identities
    ; session_map
    ; resolved_map = String_map.remove mcp_session_id state.resolved_map
    }
;;

let count state = String_map.cardinal state.identities
