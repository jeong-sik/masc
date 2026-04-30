type layer =
  | Authority
  | Projection
  | Ephemeral

type writer =
  | Ocaml_authority
  | Sync_sidecar
  | Dashboard_client

type rejection =
  | Not_authoritative
  | Projection_is_read_only
  | Ephemeral_only

type admission =
  | Accepted
  | Rejected of rejection

let layer_name = function
  | Authority -> "authority"
  | Projection -> "projection"
  | Ephemeral -> "ephemeral"
;;

let writer_name = function
  | Ocaml_authority -> "ocaml_authority"
  | Sync_sidecar -> "sync_sidecar"
  | Dashboard_client -> "dashboard_client"
;;

let rejection_name = function
  | Not_authoritative -> "not_authoritative"
  | Projection_is_read_only -> "projection_is_read_only"
  | Ephemeral_only -> "ephemeral_only"
;;

let admit_write layer writer =
  match layer, writer with
  | Authority, Ocaml_authority -> Accepted
  | Authority, (Sync_sidecar | Dashboard_client) -> Rejected Not_authoritative
  | Projection, Ocaml_authority -> Accepted
  | Projection, (Sync_sidecar | Dashboard_client) -> Rejected Projection_is_read_only
  | Ephemeral, Dashboard_client -> Accepted
  | Ephemeral, Sync_sidecar -> Accepted
  | Ephemeral, Ocaml_authority -> Rejected Ephemeral_only
;;

let can_write layer writer =
  match admit_write layer writer with
  | Accepted -> true
  | Rejected _ -> false
;;

let cluster_sizes active_agents =
  if active_agents <= 0
  then []
  else if active_agents <= 5
  then [ active_agents ]
  else (
    let cells = (active_agents + 4) / 5 in
    let base = active_agents / cells in
    let extra = active_agents mod cells in
    List.init cells (fun index -> if index < extra then base + 1 else base))
;;

let plan_clusters agents =
  let rec take_n n acc rest =
    if n <= 0
    then List.rev acc, rest
    else (
      match rest with
      | [] -> List.rev acc, []
      | head :: tail -> take_n (n - 1) (head :: acc) tail)
  in
  let rec loop sizes rest acc =
    match sizes with
    | [] -> List.rev acc
    | size :: more ->
      let group, rest = take_n size [] rest in
      loop more rest (group :: acc)
  in
  loop (cluster_sizes (List.length agents)) agents []
;;

type frame_codec =
  | Json_text
  | Opaque_binary_frame
  | Native_binary_protocol

type frame_contract =
  { codec : frame_codec
  ; text_fallback : bool
  ; version_negotiated : bool
  ; semantics_preserved : bool
  ; collaboration_specific : bool
  }

let admits_frame_contract contract =
  contract.semantics_preserved
  && (not contract.collaboration_specific)
  &&
  match contract.codec with
  | Json_text -> true
  | Opaque_binary_frame -> contract.text_fallback
  | Native_binary_protocol -> contract.text_fallback && contract.version_negotiated
;;
