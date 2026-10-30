(* Invites to the shared machine (RFC play-link-for-the-shared-machine §2.4). *)

let max_name_length = 32

module Name = struct
  type t = string

  let is_lower c = c >= 'a' && c <= 'z'
  let is_digit c = c >= '0' && c <= '9'

  let of_string raw =
    let length = String.length raw in
    if length = 0 then Error "an invite name is empty"
    else if length > max_name_length then
      Error (Printf.sprintf "an invite name is at most %d characters" max_name_length)
    else if not (is_lower raw.[0]) then
      Error "an invite name starts with a lowercase letter (a-z)"
    else if not (String.for_all (fun c -> is_lower c || is_digit c) raw) then
      Error "an invite name holds only lowercase letters and digits (a-z, 0-9)"
    else Ok raw

  let to_string name = name
end

type readiness_gap =
  | Auth_disabled
  | Token_not_required
  | No_public_base_url
  | Public_base_url_not_http

let readiness_gap_to_string = function
  | Auth_disabled -> "auth_disabled"
  | Token_not_required -> "token_not_required"
  | No_public_base_url -> "no_public_base_url"
  | Public_base_url_not_http -> "public_base_url_not_http"

type taken_by =
  | Keeper
  | Credential

let taken_by_to_string = function
  | Keeper -> "keeper"
  | Credential -> "credential"

type issue_error =
  | Not_ready of readiness_gap list
  | Name_taken of taken_by
  | Keeper_names_unreadable of string
  | Hours_out_of_range of int
  | Credential_not_saved of Masc_domain.masc_error

type issued =
  { name : Name.t
  ; expires_at : string
  ; link : string
  }

let play_path = "/play"
let agent_guide_path = play_path ^ "/agent.md"

(* A link's base is an http(s) origin of printable ASCII with a host, an
   optional valid port, and no userinfo, path, query, or fragment. A value
   outside this contract cannot form [<base>/play#<token>] that a browser, a
   QR code, and the server's root-mounted play routes agree on. *)
let is_valid_port_suffix suffix =
  if String.equal suffix "" then true
  else if not (Char.equal suffix.[0] ':') then false
  else
    let raw_port = String.sub suffix 1 (String.length suffix - 1) in
    raw_port <> ""
    && String.for_all (fun c -> c >= '0' && c <= '9') raw_port
    &&
    match int_of_string_opt raw_port with
    | Some port -> port >= 1 && port <= 65_535
    | None -> false

let is_valid_reg_name_char c =
  (c >= '0' && c <= '9')
  || (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || String.contains "-._~!$&'()*+,;=" c

(* WHATWG special hosts ending in a number are IPv4, including shortened,
   octal and hexadecimal forms. A generic URI reg-name check does not perform
   these range checks: https://url.spec.whatwg.org/#concept-ipv4-parser . *)
let ipv4_number raw =
  let len = String.length raw in
  let radix, offset =
    if len >= 2 && Char.equal raw.[0] '0' then
      if Char.equal raw.[1] 'x' || Char.equal raw.[1] 'X' then 16, 2
      else 8, 1
    else 10, 0
  in
  let rec parse i value =
    if i = len then Some value
    else
      let digit = match raw.[i] with
        | '0' .. '9' as c -> Char.code c - Char.code '0'
        | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
        | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
        | _ -> radix
      in
      (* The IPv4 address space is 32 bits; reject before multiplication can
         overflow, even if the input has arbitrarily many digits. *)
      if digit >= radix || value > (0xffff_ffff - digit) / radix then None
      else parse (i + 1) (value * radix + digit)
  in
  if len = 0 then None else parse offset 0

let is_valid_numeric_host host =
  let parts = String.split_on_char '.' host in
  let reversed = match List.rev parts with
    | "" :: (_ :: _ as rest) -> rest
    | rest -> rest
  in
  match reversed with
  | [] -> false
  | last :: preceding ->
    let ends_in_number =
      (last <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) last)
      || (String.length last >= 2 && Char.equal last.[0] '0'
          && (Char.equal last.[1] 'x' || Char.equal last.[1] 'X')
          && String.for_all (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
               (String.sub last 2 (String.length last - 2)))
    in
    if not ends_in_number then true
    else
      let count = List.length reversed in
      count <= 4
      && List.for_all (fun part -> match ipv4_number part with
          | Some number -> number <= 255
          | None -> false) preceding
      && (match ipv4_number last with
          | Some number -> number < (1 lsl (8 * (5 - count)))
          | None -> false)

let is_valid_authority authority =
  let len = String.length authority in
  if len = 0 then false
  else if Char.equal authority.[0] '[' then
    match String.index_opt authority ']' with
    | None | Some 1 -> false
    | Some close ->
      let raw_host = String.sub authority 1 (close - 1) in
      let suffix = String.sub authority (close + 1) (len - close - 1) in
      Result.is_ok (Ipaddr.V6.of_string raw_host) && is_valid_port_suffix suffix
  else
    let host, suffix =
      match String.index_opt authority ':' with
      | None -> authority, ""
      | Some i ->
        String.sub authority 0 i, String.sub authority i (len - i)
    in
    host <> ""
    && String.for_all is_valid_reg_name_char host
    && is_valid_numeric_host host
    && is_valid_port_suffix suffix

let is_http_public_base_url base =
  let authority_opt =
    if String.starts_with ~prefix:"https://" base
    then Some (String.sub base 8 (String.length base - 8))
    else if String.starts_with ~prefix:"http://" base
    then Some (String.sub base 7 (String.length base - 7))
    else None
  in
  match authority_opt with
  | None -> false
  | Some authority ->
    String.for_all (fun c -> c > ' ' && c < '\127') base
    && is_valid_authority authority
    &&
    let uri = Uri.of_string base in
    Option.is_none (Uri.userinfo uri)
    && (match Uri.host uri with Some host -> host <> "" | None -> false)
    && (match Uri.port uri with None -> true | Some port -> port >= 1 && port <= 65_535)
    && String.equal (Uri.path uri) ""
    && Uri.query uri = []
    && Option.is_none (Uri.fragment uri)

(* Every gap at once, so the operator fixes the setup in one pass. *)
let readiness ~(auth_config : Masc_domain.auth_config) ~public_base_url =
  let auth_gaps =
    List.filter_map
      (fun (gap, missing) -> if missing then Some gap else None)
      [ Auth_disabled, not auth_config.enabled
      ; Token_not_required, not auth_config.require_token
      ]
  in
  match public_base_url with
  | None -> Error (auth_gaps @ [ No_public_base_url ])
  | Some base ->
    if not (is_http_public_base_url base)
    then Error (auth_gaps @ [ Public_base_url_not_http ])
    else (
      match auth_gaps with
      | [] -> Ok base
      | _ :: _ as gaps -> Error gaps)

(* A keeper's credential lives at its name through [Common.safe_filename],
   which lowercases, and keeper names may hold capitals. "Minsu" and "minsu"
   share agents/minsu.json, so the keeper booting later would overwrite the
   invite's credential. Compared as file names, not as strings. *)
let is_keeper_name_string ~keepers name =
  List.exists (fun keeper -> String.equal (Common.safe_filename keeper) name) keepers

let is_keeper_name ~keepers (name : Name.t) = is_keeper_name_string ~keepers name

(* A gift target is a wallet key, not a credential file name, so it must
   match a roster name exactly apart from case: the balance fold opens a
   wallet for a spelling no keeper holds, and the gift would sit in it
   forever. Returns the roster's own spelling, which is the wallet key the
   fold reads, or [None] when no name matches or the case-fold is
   ambiguous. *)
let resolve_keeper_name ~keepers name =
  let folded = String.lowercase_ascii name in
  match
    List.filter
      (fun keeper -> String.equal (String.lowercase_ascii keeper) folded)
      keepers
  with
  | [ keeper ] -> Some keeper
  | _ -> None

let issue ~base_path ~public_base_url ~keeper_names ~name ~hours =
  let open Result.Syntax in
  let* base =
    readiness ~auth_config:(Auth.load_auth_config base_path) ~public_base_url
    |> Result.map_error (fun gaps -> Not_ready gaps)
  in
  let* () =
    if hours >= Masc_domain.min_token_expiry_hours && hours <= Masc_domain.max_token_expiry_hours
    then Ok ()
    else Error (Hours_out_of_range hours)
  in
  let* keepers = Result.map_error (fun detail -> Keeper_names_unreadable detail) keeper_names in
  let* () =
    if is_keeper_name ~keepers name then Error (Name_taken Keeper)
    else Ok ()
  in
  match Auth.create_token_expiring_in_if_absent base_path ~agent_name:name ~role:Masc_domain.Player ~hours with
  | Error Auth.Credential_name_taken -> Error (Name_taken Credential)
  | Error (Auth.Credential_not_created err) -> Error (Credential_not_saved err)
  | Ok (_, { Masc_domain.expires_at = None; _ }) ->
    (* The record type allows no expiry, though [create_token_expiring_in_if_absent]
       always sets one. An invite that never ends is not handed out. *)
    Error
      (Credential_not_saved
         (Masc_domain.System
            (Masc_domain.System_error.IoError "the invite credential was saved without an expiry")))
  | Ok (raw_token, { Masc_domain.expires_at = Some expires_at; _ }) ->
    Ok { name; expires_at; link = base ^ play_path ^ "#" ^ raw_token }

type invite =
  { invite_name : string
  ; expires_at : string option
  ; expired : bool
  }

let expired ~now (cred : Masc_domain.agent_credential) =
  Masc_domain.Credential_expiry.parse cred.expires_at
  |> Result.map (Masc_domain.Credential_expiry.is_expired ~now)

type list_error =
  | Credentials_unavailable of Masc_domain.masc_error
  | Invalid_expiry of Masc_domain.Credential_expiry.error

let list ~base_path ~now =
  let open Result.Syntax in
  let rec collect invites = function
    | [] -> Ok (List.sort (fun a b -> String.compare a.invite_name b.invite_name) invites)
    | (cred : Masc_domain.agent_credential) :: rest ->
      (match cred.role with
       | Masc_domain.Player ->
         Result.bind (expired ~now cred) (fun expired ->
           collect ({ invite_name = cred.agent_name; expires_at = cred.expires_at; expired } :: invites) rest)
       | Masc_domain.Worker | Masc_domain.Admin -> collect invites rest)
  in
  (* Diagnostics retain the owner/role of an invalid-expiry record. Consult
     that fact only while its exact named owner is occupied and undecodable;
     an obsolete UUID must not invalidate a healthy or deleted named owner. *)
  let rec invalid_named_player = function
    | [] -> Ok ()
    | Error (Auth.Invalid_credential_expiry
        { agent_name; role = Masc_domain.Player; timestamp }) :: rest ->
        let* current_error = Auth.with_credential_transaction base_path (fun transaction ->
          let* present = Auth.credential_exists_in_transaction transaction agent_name in
          if not present then Ok false
          else Ok (Option.is_none (Auth.load_credential base_path agent_name)))
          |> Result.join |> Result.map_error (fun error -> Credentials_unavailable error) in
        if current_error then Error (Invalid_expiry (Masc_domain.Credential_expiry.Invalid_timestamp timestamp))
        else invalid_named_player rest
    | (Ok _)::rest
    | (Error (Auth.Invalid_credential_expiry
        { role = Masc_domain.Worker | Masc_domain.Admin; _ }))::rest
    | (Error (Auth.Unreadable_credential _))::rest -> invalid_named_player rest
  in
  (* Batch the file reads without moving transaction admission to a blocking
     thread. A cancelled HTTP request must stop waiting for a publisher; the
     admitted transaction then protects its read and release as before. *)
  let diagnostics = Eio_guard.run_in_systhread ~label:"play-invite-diagnostics"
      (fun () -> Auth.list_credential_results base_path) in
  let* () = invalid_named_player diagnostics in
  let* credentials = Auth.with_credential_transaction base_path (fun transaction ->
      Eio_guard.run_in_systhread ~label:"play-invite-current-credentials" (fun () ->
        Auth.list_current_credentials_in_transaction transaction))
    |> Result.join |> Result.map_error (fun error -> Credentials_unavailable error) in
  collect [] credentials |> Result.map_error (fun error -> Invalid_expiry error)

type revoked =
  | Deleted
  | Already_gone

type revoke_error =
  | Not_an_invite of Masc_domain.agent_role
  | Credential_not_deleted of Masc_domain.masc_error
  | Credential_unreadable
  | Credential_identity_mismatch of string

let revoke ~base_path ~name ~after_revoke =
  Auth.with_credential_transaction base_path (fun transaction ->
    match Auth.credential_exists_in_transaction transaction name with
    | Error error -> Error (Credential_not_deleted error)
    | Ok false -> Ok (after_revoke Already_gone)
    | Ok true ->
      let credential =
        try Auth.load_credential base_path name with
        | Sys_error _ | Unix.Unix_error _ | Eio.Io _ -> None
      in
      (match credential with
       | None -> Error Credential_unreadable
       | Some { Masc_domain.agent_name; _ } when not (String.equal agent_name name) ->
         Error (Credential_identity_mismatch agent_name)
       | Some { Masc_domain.role = Masc_domain.Player; _ } ->
         let open Result.Syntax in
         let* current = Auth.current_credential_in_transaction transaction name
           |> Result.map_error (fun error -> Credential_not_deleted error) in
         let* () = match current with
           | None -> Error Credential_unreadable
           | Some _ -> Ok () in
         Auth.delete_credential_in_transaction transaction name
         |> Result.map_error (fun error -> Credential_not_deleted error)
         |> Result.map (fun () -> after_revoke Deleted)
       | Some { Masc_domain.role = (Masc_domain.Worker | Masc_domain.Admin) as role; _ } ->
         Error (Not_an_invite role)))
  |> Result.map_error (fun error -> Credential_not_deleted error)
  |> Result.join
