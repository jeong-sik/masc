let canonical_key = "canonical_turn_id"
let bridged_key = "masc.bridged_turn_ref"

let nonblank_string key (message : Agent_core.Types.message) =
  match List.assoc_opt key message.metadata with
  | Some (`String value) when not (String.equal (String.trim value) "") ->
    Some (Ids.Turn_id.of_string value)
  | Some _ | None -> None
;;

let turn_of_message message =
  match nonblank_string canonical_key message with
  | Some _ as named -> named
  | None -> nonblank_string bridged_key message
;;
