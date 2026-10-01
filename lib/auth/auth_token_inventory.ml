type expiry =
  | Never
  | Valid_until of string
  | Expired_at of string
  | Invalid_expiry of string

let classify ~now (cred : Types_auth.agent_credential) =
  match cred.expires_at with
  | None -> Never
  | Some stamp ->
    (match Types_auth.Credential_expiry.parse cred.expires_at with
     | Error (Types_auth.Credential_expiry.Invalid_timestamp invalid) -> Invalid_expiry invalid
     | Ok expiry ->
       if Types_auth.Credential_expiry.is_expired ~now expiry
       then Expired_at stamp else Valid_until stamp)
;;

let expiry_label = function
  | Never -> "never expires"
  | Valid_until stamp -> "valid until " ^ stamp
  | Expired_at stamp -> "EXPIRED " ^ stamp
  | Invalid_expiry stamp -> "INVALID expiry " ^ stamp
;;

let is_expired = function
  | Expired_at _ -> true
  | Never | Valid_until _ | Invalid_expiry _ -> false
;;

let row ~now ~raw_present (cred : Types_auth.agent_credential) =
  Printf.sprintf
    "%-32s %-6s %-28s %s"
    cred.agent_name
    (Types_auth.agent_role_to_string cred.role)
    (expiry_label (classify ~now cred))
    (if raw_present then "raw token on disk" else "no raw token file")
;;

let error_row = function
  | Auth.Invalid_credential_expiry { agent_name; role; timestamp } ->
    Printf.sprintf "%-32s %-6s %s" agent_name
      (Types_auth.agent_role_to_string role) (expiry_label (Invalid_expiry timestamp))
  | Auth.Unreadable_credential _ as error -> Auth.credential_listing_error_to_string error
;;

let expired ~now creds = List.filter (fun c -> is_expired (classify ~now c)) creds

(* Sorted so a listing of a hundred credentials is readable and so two runs of
   the same command answer in the same order. Expired first because that is the
   set an operator is looking for. *)
let ordered ~now creds =
  let key (c : Types_auth.agent_credential) =
    ((if is_expired (classify ~now c) then 0 else 1), c.agent_name)
  in
  List.stable_sort (fun a b -> compare (key a) (key b)) creds
;;
