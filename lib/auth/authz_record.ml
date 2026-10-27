(* HIGH-RISK-UNREVIEWED: this is the line format of the authorization log, and
   its writer-side check says which author may write which record. A record
   that gets past it is a grant, revocation, or principal that the whole
   system will treat as true. *)

open Authz_types
open Authz_records

module Hash = struct
  type t = string

  let hex_length = Agent_core_sha256.digest_size * 2
  let genesis = String.make hex_length '0'

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_hex s =
    if String.length s = hex_length && String.for_all is_lower_hex s then Some s else None
  ;;

  let to_hex t = t
  let equal = String.equal
end

module Kind = struct
  type t =
    | Runtime_grant
    | Delegate_policy
    | Principal
    | Internal_service_credential
    | Permission_revocation
    | Trigger_evidence
    | Lease_terminal_evidence
    | Preauthorized_expiry
    | Migration_diagnostic
    | Local_recovery

  let all =
    [ Runtime_grant
    ; Delegate_policy
    ; Principal
    ; Internal_service_credential
    ; Permission_revocation
    ; Trigger_evidence
    ; Lease_terminal_evidence
    ; Preauthorized_expiry
    ; Migration_diagnostic
    ; Local_recovery
    ]
  ;;

  let to_string = function
    | Runtime_grant -> "runtime_grant"
    | Delegate_policy -> "delegate_policy"
    | Principal -> "principal"
    | Internal_service_credential -> "internal_service_credential"
    | Permission_revocation -> "permission_revocation"
    | Trigger_evidence -> "trigger_evidence"
    | Lease_terminal_evidence -> "lease_terminal_evidence"
    | Preauthorized_expiry -> "preauthorized_expiry"
    | Migration_diagnostic -> "migration_diagnostic"
    | Local_recovery -> "local_recovery"
  ;;

  let of_string label = List.find_opt (fun kind -> String.equal (to_string kind) label) all
end

(* The kinds of author, without the principal an authenticated one carries. *)
type writer =
  | Authenticated_principal
  | Host_operator
  | Cron
  | Maintenance
  | Migration

let writer_of : Author.t -> writer = function
  | Author.Authenticated _ -> Authenticated_principal
  | Author.Local_operator -> Host_operator
  | Author.System_cron -> Cron
  | Author.System_maintenance -> Maintenance
  | Author.System_migration -> Migration
;;

(* Design 6.3. The local operator writes recovery records only until a layer
   that defines bootstrap records says otherwise. *)
let writers : Kind.t -> writer list = function
  | Kind.Runtime_grant
  | Kind.Delegate_policy
  | Kind.Principal
  | Kind.Internal_service_credential
  | Kind.Permission_revocation -> [ Authenticated_principal ]
  | Kind.Trigger_evidence -> [ Cron ]
  | Kind.Lease_terminal_evidence | Kind.Preauthorized_expiry -> [ Maintenance ]
  | Kind.Migration_diagnostic -> [ Migration ]
  | Kind.Local_recovery -> [ Host_operator ]
;;

let admits kind author = List.mem (writer_of author) (writers kind)

let principal_to_json = function
  | Principal.Human id ->
    `Assoc [ "type", `String "human"; "id", `String (User_id.to_string id) ]
  | Principal.Service id ->
    `Assoc [ "type", `String "service"; "id", `String (Service_id.to_string id) ]
;;

let author_to_json = function
  | Author.Authenticated principal ->
    `Assoc [ "type", `String "authenticated"; "principal", principal_to_json principal ]
  | Author.Local_operator -> `Assoc [ "type", `String "local_operator" ]
  | Author.System_cron -> `Assoc [ "type", `String "system_cron" ]
  | Author.System_maintenance -> `Assoc [ "type", `String "system_maintenance" ]
  | Author.System_migration -> `Assoc [ "type", `String "system_migration" ]
;;

let principal_of_json = function
  | `Assoc [ ("type", `String "human"); ("id", `String id) ] ->
    Option.map (fun id -> Principal.Human id) (Result.to_option (User_id.of_string id))
  | `Assoc [ ("type", `String "service"); ("id", `String id) ] ->
    Option.map (fun id -> Principal.Service id) (Result.to_option (Service_id.of_string id))
  | _ -> None
;;

let author_of_json = function
  | `Assoc [ ("type", `String "authenticated"); ("principal", principal) ] ->
    Option.map (fun principal -> Author.Authenticated principal) (principal_of_json principal)
  | `Assoc [ ("type", `String "local_operator") ] -> Some Author.Local_operator
  | `Assoc [ ("type", `String "system_cron") ] -> Some Author.System_cron
  | `Assoc [ ("type", `String "system_maintenance") ] -> Some Author.System_maintenance
  | `Assoc [ ("type", `String "system_migration") ] -> Some Author.System_migration
  | _ -> None
;;

type head =
  { next_seq : int
  ; head_hash : Hash.t
  }

let genesis = { next_seq = 1; head_hash = Hash.genesis }
let next_seq head = head.next_seq
let head_hash head = head.head_hash

type t =
  { seq : int
  ; previous_hash : Hash.t
  ; at_ms : int
  ; author : Author.t
  ; kind : Kind.t
  ; body : Yojson.Safe.t
  ; hash : Hash.t
  }

let head_after record = { next_seq = record.seq + 1; head_hash = record.hash }

(* Everything the hash covers, in the order the line carries it. *)
let unsigned_fields ~seq ~previous_hash ~at_ms ~author ~kind ~body =
  [ "seq", `Int seq
  ; "previous_hash", `String (Hash.to_hex previous_hash)
  ; "at_ms", `Int at_ms
  ; "author", author_to_json author
  ; "kind", `String (Kind.to_string kind)
  ; "body", body
  ]
;;

(* Keeps a record hash from being valid as a digest in any other protocol. *)
let hash_domain = "masc-authz-record-v1\n"

let hash_of fields : Hash.t =
  Agent_core_sha256.to_hex
    (Agent_core_sha256.digest_string (hash_domain ^ Yojson.Safe.to_string (`Assoc fields)))
;;

type make_error = Author_not_admitted of { kind : Kind.t; author : Author.t }

let make ~head ~at_ms ~author ~kind ~body =
  if not (admits kind author)
  then Error (Author_not_admitted { kind; author })
  else (
    let seq = head.next_seq in
    let previous_hash = head.head_hash in
    let hash = hash_of (unsigned_fields ~seq ~previous_hash ~at_ms ~author ~kind ~body) in
    Ok { seq; previous_hash; at_ms; author; kind; body; hash })
;;

type decode_error =
  | Not_json
  | Unexpected_shape
  | Unknown_kind of string
  | Invalid_author
  | Invalid_hash
  | Seq_mismatch of { expected : int; actual : int }
  | Previous_hash_mismatch
  | Author_not_admitted_to_write of { kind : Kind.t; author : Author.t }
  | Hash_mismatch
  | Non_canonical

let decode_error_to_string = function
  | Not_json -> "not json"
  | Unexpected_shape -> "not exactly the fields of a record, in order"
  | Unknown_kind label -> Printf.sprintf "unknown kind %S" label
  | Invalid_author -> "author is not one of the known shapes"
  | Invalid_hash -> "hash is not 64 lowercase hex characters"
  | Seq_mismatch { expected; actual } ->
    Printf.sprintf "seq is %d where %d was expected" actual expected
  | Previous_hash_mismatch -> "previous_hash is not the hash of the line before"
  | Author_not_admitted_to_write { kind; author = _ } ->
    Printf.sprintf "the author may not write %s records" (Kind.to_string kind)
  | Hash_mismatch -> "hash does not match the content"
  | Non_canonical -> "valid record, but not the line this module writes for it"
;;

let to_line record =
  let fields =
    unsigned_fields
      ~seq:record.seq
      ~previous_hash:record.previous_hash
      ~at_ms:record.at_ms
      ~author:record.author
      ~kind:record.kind
      ~body:record.body
  in
  Yojson.Safe.to_string (`Assoc (fields @ [ "hash", `String (Hash.to_hex record.hash) ]))
;;

let of_line ~head line =
  let ( let* ) = Result.bind in
  let* json =
    match Yojson.Safe.from_string line with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error Not_json
  in
  let* seq, previous, at_ms, author_json, kind_label, body, hash_hex =
    match json with
    | `Assoc
        [ ("seq", `Int seq)
        ; ("previous_hash", `String previous)
        ; ("at_ms", `Int at_ms)
        ; ("author", author)
        ; ("kind", `String kind)
        ; ("body", body)
        ; ("hash", `String hash)
        ] -> Ok (seq, previous, at_ms, author, kind, body, hash)
    | _ -> Error Unexpected_shape
  in
  let* kind = Option.to_result ~none:(Unknown_kind kind_label) (Kind.of_string kind_label) in
  let* author = Option.to_result ~none:Invalid_author (author_of_json author_json) in
  let* previous_hash = Option.to_result ~none:Invalid_hash (Hash.of_hex previous) in
  let* hash = Option.to_result ~none:Invalid_hash (Hash.of_hex hash_hex) in
  let* () =
    if seq = head.next_seq
    then Ok ()
    else Error (Seq_mismatch { expected = head.next_seq; actual = seq })
  in
  let* () =
    if Hash.equal previous_hash head.head_hash then Ok () else Error Previous_hash_mismatch
  in
  let* () =
    if admits kind author then Ok () else Error (Author_not_admitted_to_write { kind; author })
  in
  let expected = hash_of (unsigned_fields ~seq ~previous_hash ~at_ms ~author ~kind ~body) in
  let* () = if Hash.equal expected hash then Ok () else Error Hash_mismatch in
  let record = { seq; previous_hash; at_ms; author; kind; body; hash } in
  if String.equal (to_line record) line then Ok record else Error Non_canonical
;;
