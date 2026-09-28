module R = Runtime_account_removal

type error =
  | Invalid_request
  | Configuration_unavailable of string
  | Configuration_changed
  | Refused of R.error
  | Save_rejected of string

let error_message = function
  | Invalid_request ->
    "Send the account's integration_id, and for a removal the revision its preview \
     answered with."
  | Configuration_unavailable detail -> "runtime.toml could not be read: " ^ detail
  | Configuration_changed ->
    "runtime.toml changed since the removal was shown; show it again before removing."
  | Refused e -> R.error_message e
  | Save_rejected detail -> detail
;;

(* Raised inside [Runtime.edit_config_text]'s edit, which cannot answer an
   error of its own, and turned back into [error] around the call -- the
   shape [Voice_setup.apply] uses. *)
exception Revision_changed
exception Removal_refused of R.error

let ( let* ) = Result.bind

(* An object with exactly [keys], no key twice. *)
let exactly keys = function
  | `Assoc fields
    when List.sort String.compare (List.map fst fields) = List.sort String.compare keys ->
    Ok fields
  | _ -> Error Invalid_request
;;

(* A non-empty string on one line. *)
let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value)
    when value <> ""
         && String.trim value = value
         && not (String.exists (function '\000' .. '\031' | '\127' -> true | _ -> false) value) ->
    Ok value
  | Some _ | None -> Error Invalid_request
;;

let revision_of (observation : Runtime.config_observation) =
  Runtime.config_source_revision_to_string observation.source_revision
;;

let change_json = function
  | R.Table path -> `Assoc [ "kind", `String "table"; "path", `String path ]
  | R.Lane_candidate { lane; runtime } ->
    `Assoc [ "kind", `String "lane_candidate"; "lane", `String lane; "runtime", `String runtime ]
  | R.Exact_lane_slot { lane; runtime } ->
    `Assoc [ "kind", `String "exact_lane_slot"; "lane", `String lane; "runtime", `String runtime ]
  | R.Vision_runtime runtime -> `Assoc [ "kind", `String "vision_runtime"; "runtime", `String runtime ]
  | R.Assignment { keeper; runtime } ->
    `Assoc [ "kind", `String "assignment"; "keeper", `String keeper; "runtime", `String runtime ]
;;

let preview ~runtime_config_path body =
  let* fields = exactly [ "integration_id" ] body in
  let* id = string_field fields "integration_id" in
  let* observation =
    Result.map_error
      (fun detail -> Configuration_unavailable detail)
      (Runtime.load_config_observation ~runtime_config_path ())
  in
  let head = [ "integration_id", `String id; "revision", `String (revision_of observation) ] in
  match R.remove observation.source_text ~id with
  | Ok removed ->
    Ok
      (`Assoc
          (head
           @ [ "state", `String "removable"
             ; "changes", `List (List.map change_json removed.changes)
             ; ( "login_store"
               , match removed.login_store with
                 | Some path -> `String path
                 | None -> `Null )
             ]))
  | Error e ->
    Ok (`Assoc (head @ [ "state", `String "refused"; "reason", `String (R.error_message e) ]))
;;

let remove ~runtime_config_path body =
  let* fields = exactly [ "integration_id"; "revision" ] body in
  let* id = string_field fields "integration_id" in
  let* expected = string_field fields "revision" in
  (* The revision is checked again here, inside the lock, because the
     preview read it outside one. *)
  let edit contents =
    let observation = Runtime.config_observation ~path:runtime_config_path contents in
    if not (String.equal (revision_of observation) expected) then raise Revision_changed;
    match R.remove contents ~id with
    | Ok removed -> removed.text
    | Error e -> raise (Removal_refused e)
  in
  match Runtime.edit_config_text ~runtime_config_path edit with
  | Ok receipt -> Ok receipt
  | Error detail -> Error (Save_rejected detail)
  | exception Revision_changed -> Error Configuration_changed
  | exception Removal_refused e -> Error (Refused e)
;;
