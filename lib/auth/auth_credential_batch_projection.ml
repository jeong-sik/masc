open Masc_domain

module String_map = Map.Make (String)
module Shared_hashes = Set.Make (String)

type ownership =
  (Auth_credential_base.stored_credential * agent_credential) list

type admitted_shared = Shared_hashes.t

type current =
  { ownership : ownership
  ; by_token : agent_credential list String_map.t
  ; by_name : agent_credential String_map.t
  }

let admit ownership =
  let by_token, by_name =
    List.fold_left
      (fun (by_token, by_name) (_, (credential : agent_credential)) ->
         ( String_map.add_to_list credential.token credential by_token
         , String_map.add credential.agent_name credential by_name ))
      (String_map.empty, String_map.empty) ownership
  in
  let by_token = String_map.map List.rev by_token in
  let admitted_shared =
    String_map.fold
      (fun hash owners shared ->
         match owners with
         | _ :: _ :: _ -> Shared_hashes.add hash shared
         | [] | [_] -> shared)
      by_token Shared_hashes.empty
  in
  admitted_shared, { ownership; by_token; by_name }

let index_credential (credential : agent_credential) current =
  let by_token =
    match String_map.find_opt credential.agent_name current.by_name with
    | None -> current.by_token
    | Some previous ->
        String_map.update previous.token
          (function
            | None -> None
            | Some entries ->
                Some (List.filter (fun (entry : agent_credential) ->
                    not (String.equal entry.agent_name credential.agent_name)) entries))
          current.by_token
  in
  { current with
    by_token = String_map.add_to_list credential.token credential by_token
  ; by_name = String_map.add credential.agent_name credential current.by_name
  }

let refreshed ownership =
  List.fold_left (fun current (_, credential) -> index_credential credential current)
    { ownership; by_token = String_map.empty; by_name = String_map.empty }
    ownership

let ownership current = current.ownership
let was_shared shared hash = Shared_hashes.mem hash shared
let owners_for_hash current hash = String_map.find_opt hash current.by_token

let published current ~stored (credential : agent_credential) =
  let current = index_credential credential current in
  { current with ownership =
      (stored, credential) :: List.filter (fun (_, (owner : agent_credential)) ->
        not (String.equal owner.agent_name credential.agent_name)) current.ownership }
