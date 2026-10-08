type detail =
  | Unserved of
      { transport : Browser_lane.live_transport
      ; capability : Browser_lane.live_capability
      ; serving_clients : int
      }
  | Next_step of string

type t =
  { case : Browser_lane.selection_case
  ; detail : detail
  }

let of_result text =
  let ( let* ) = Option.bind in
  let own_text =
    match String.index_opt text '\n' with
    | Some line_end -> String.sub text 0 line_end
    | None -> text
  in
  let* fields =
    match Yojson.Safe.from_string own_text with
    | exception Yojson.Json_error _ -> None
    | `Assoc fields -> Some fields
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
  in
  let string name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Some value
    | Some _ | None -> None
  in
  let* case = Option.bind (string "error") Browser_lane.selection_case_of_code in
  match case with
  | Browser_lane.Transport_unsupported_case ->
    let* transport =
      Option.bind (string "transport") (fun raw ->
        Result.to_option (Browser_lane.live_transport_of_string raw))
    in
    let* capability = Option.bind (string "capability") Browser_lane.live_capability_of_wire in
    let* serving_clients =
      match List.assoc_opt "servingClients" fields with
      | Some (`List clients) -> Some (List.length clients)
      | Some _ | None -> None
    in
    Some { case; detail = Unserved { transport; capability; serving_clients } }
  | Browser_lane.Lane_off_case | Browser_lane.Activity_unavailable_case ->
    let* message = string "message" in
    Some { case; detail = Next_step message }
  | Browser_lane.No_live_client_case
  | Browser_lane.Selected_client_disconnected_case
  | Browser_lane.Ambiguous_clients_case ->
    let* retry = string "retry" in
    Some { case; detail = Next_step retry }
;;

let line ~transport_label ~capability_word rejection =
  let code = Browser_lane.selection_case_code rejection.case in
  match rejection.detail with
  | Next_step sentence -> code ^ " \xc2\xb7 " ^ sentence
  | Unserved { transport; capability; serving_clients } ->
    Printf.sprintf
      "%s \xc2\xb7 this %s connection does not serve %s \xc2\xb7 %s"
      code
      (transport_label transport)
      (capability_word capability)
      (match serving_clients with
       | 0 -> "no connected browser does"
       | 1 -> "1 connected browser does"
       | count -> Printf.sprintf "%d connected browsers do" count)
;;
