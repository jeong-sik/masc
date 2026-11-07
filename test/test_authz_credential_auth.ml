(* PATs and Service credentials against the writer zone, on real files: each
   case bootstraps a fresh installation in a temporary directory, lets the
   first Admin join, and issues, matches, and revokes credentials. No network.
   The clock is a reference the case moves. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module E = Authz_invite_event
module Login = Authz_login
module Z = Authz_zone
module P = Authz_pat
module Sc = Authz_service_credential
module T = Authz_credential_token

let start_ms = 1_700_000_000_000

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Sys.remove path
;;

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture value rejected"
;;

type installation =
  { zone : Z.t
  ; clock : int ref
  ; admin : User_id.t  (** The first Admin, who joined. *)
  ; log_path : string
  ; store_path : string
  }

let now_ms clock () = !clock
let admin_token = String.make 64 'a'

(* Ids from a list, then fresh ones. *)
let drawing values =
  let left = ref values in
  let fresh = ref 0 in
  fun () ->
    match !left with
    | value :: rest ->
      left := rest;
      value
    | [] ->
      incr fresh;
      Printf.sprintf "%032x" !fresh
;;

let google sub = get (Authz_external_identity.google ~sub)

let with_installation f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-credential-auth-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let clock = ref start_ms in
        (match
           B.fresh_bootstrap
             { B.base_path = base
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = get (Workspace_id.of_string "workspace-1")
             ; now_ms = now_ms clock
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let log_path = Authz_log.path_of_base_path ~base_path:base in
        match Z.open_at_start ~now_ms:(now_ms clock) ~log_path ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          let invitation =
            E.Issued
              { invite_id = get (Invite_id.of_string "invite-admin")
              ; token_digest = E.Token_digest.of_token admin_token
              ; expires_at_ms = start_ms + 3_600_000
              ; role = E.Admin
              }
          in
          (match
             Z.commit
               zone
               { Z.author = Author.Local_operator
               ; kind = Authz_record.Kind.Invite
               ; body = get (E.to_body invitation)
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
          let admin =
            match
              Login.sign_in
                zone
                ~now_ms:(now_ms clock)
                ~draw:(drawing [])
                ~identity:(google "111")
                ~invite:(Some (E.Token_digest.of_token admin_token))
            with
            | Ok (Login.Admitted { user_id; _ }) -> user_id
            | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "the first Admin did not join"
          in
          f { zone; clock; admin; log_path; store_path = store }))
;;


let read_file path = In_channel.with_open_bin path In_channel.input_all

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.equal (String.sub text i n) sub || go (i + 1)) in
  go 0
;;


let member t =
  let token = String.make 64 'b' in
  (match
     Z.commit
       t.zone
       { Z.author = Author.Authenticated (Principal.Human t.admin)
       ; kind = Authz_record.Kind.Invite
       ; body =
           get
             (E.to_body
                (E.Issued
                   { invite_id = get (Invite_id.of_string "invite-2")
                   ; token_digest = E.Token_digest.of_token token
                   ; expires_at_ms = !(t.clock) + 3_600_000
                   ; role = E.Member
                   }))
       }
   with
   | Ok (_ : Z.committed) -> ()
   | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_to_string error));
  match
    Login.sign_in
      t.zone
      ~now_ms:(now_ms t.clock)
      ~draw:(drawing [ String.make 32 'm' ])
      ~identity:(google "222")
      ~invite:(Some (E.Token_digest.of_token token))
  with
  | Ok (Login.Admitted { user_id; _ }) -> user_id
  | Ok (Login.Signed_in _) | Error _ -> Alcotest.fail "the member did not join"
;;


let issue_pat ?(draw = drawing [ "pat-1" ]) ?expires_at_ms t ~user_id =
  match P.issue t.zone ~user_id ~draw ~scope:Authorization_scope.all ~expires_at_ms with
  | Ok token -> token
  | Error error -> Alcotest.failf "no PAT was issued: %s" (P.error_to_string error)
;;

let pat_acts t token =
  match P.authenticate (Z.snapshot t.zone).state ~now_ms:!(t.clock) token with
  | Ok { P.user_id; pat_id; pat_scope } ->
    Printf.sprintf
      "acts as %s with %s until %s"
      (User_id.to_string user_id)
      (Pat_id.to_string pat_id)
      (match pat_scope.Pat_scope.expires_at with
       | Some at -> Printf.sprintf "%.3f" at
       | None -> "no expiry")
  | Error refusal -> P.refusal_to_string refusal
;;

let pat_of text =
  match T.read text with
  | T.Pat_token token -> token
  | T.Service_credential_token _ | T.Pat_malformed | T.Service_credential_malformed | T.No_prefix ->
    Alcotest.failf "%S is not a PAT" text
;;

let secret_of text = String.sub text (String.length text - 64) 64

let a_pat_acts_until_it_ends () =
  with_installation (fun t ->
    let token = issue_pat t ~user_id:t.admin ~expires_at_ms:(start_ms + 60_000) in
    let text = T.Pat.to_string token in
    let admin = User_id.to_string t.admin in
    Alcotest.(check string) "the id" "pat-1" (Pat_id.to_string (T.Pat.id token));
    Alcotest.(check string)
      "acts"
      ("acts as " ^ admin ^ " with pat-1 until 1700000060.000")
      (pat_acts t token);
    Alcotest.(check bool)
      "the log holds no secret"
      false
      (contains ~sub:(secret_of text) (read_file t.log_path));
    Alcotest.(check string)
      "another secret"
      (P.refusal_to_string P.Secret_differs)
      (pat_acts t (pat_of ("mpat_pat-1." ^ String.make 64 '0')));
    Alcotest.(check string)
      "an unknown id"
      (P.refusal_to_string P.Unknown)
      (pat_acts t (pat_of ("mpat_pat-9." ^ secret_of text)));
    t.clock := start_ms + 60_000;
    Alcotest.(check string) "at its expiry" (P.refusal_to_string P.Expired) (pat_acts t token);
    t.clock := start_ms;
    let member_id = member t in
    let member_token = issue_pat t ~user_id:member_id ~draw:(drawing [ "pat-2" ]) in
    (match P.revoke t.zone ~user_id:member_id (T.Pat.id token) with
     | Error (P.Commit_failed (Z.Refused (Authz_state.Pat (Authz_pat_state.Not_the_owner _)))) -> ()
     | Ok () -> Alcotest.fail "a member revoked the PAT of the Admin"
     | Error error -> Alcotest.failf "another refusal: %s" (P.error_to_string error));
    (match
       Z.commit
         t.zone
         { Z.author = Author.Authenticated (Principal.Human t.admin)
         ; kind = Authz_record.Kind.Principal
         ; body = get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = member_id }))
         }
     with
     | Ok (_ : Z.committed) -> ()
     | Error error -> Alcotest.failf "disable refused: %s" (Z.error_to_string error));
    Alcotest.(check string)
      "a disabled principal"
      (P.refusal_to_string (P.Principal_inactive member_id))
      (pat_acts t member_token);
    (match P.revoke t.zone ~user_id:t.admin (T.Pat.id token) with
     | Ok () -> ()
     | Error error -> Alcotest.failf "revoke refused: %s" (P.error_to_string error));
    Alcotest.(check string) "revoked" (P.refusal_to_string P.Ended) (pat_acts t token);
    Alcotest.(check bool)
      "the revoke is an intent on the PAT"
      true
      (contains ~sub:{|"event":"revoke","subject":{"type":"pat","id":"pat-1"}|} (read_file t.store_path)))
;;

let service_acts t token =
  match Sc.authenticate (Z.snapshot t.zone).state token with
  | Ok { Sc.service_id; credential_id } ->
    Printf.sprintf
      "acts as %s with %s"
      (Service_id.to_string service_id)
      (Service_credential_id.to_string credential_id)
  | Error refusal -> Sc.refusal_to_string refusal
;;

let a_service_credential_acts_until_it_is_revoked () =
  with_installation (fun t ->
    let service_id = get (Service_id.of_string "keeper-runner") in
    let token =
      match Sc.issue t.zone ~service_id ~draw:(drawing [ "cred-1" ]) with
      | Ok token -> token
      | Error error -> Alcotest.failf "no credential was issued: %s" (Sc.error_to_string error)
    in
    Alcotest.(check string) "acts" "acts as keeper-runner with cred-1" (service_acts t token);
    let text = T.Service_credential.to_string token in
    let wrong =
      match T.read ("msvc_cred-1." ^ String.make 64 '0') with
      | T.Service_credential_token token -> token
      | T.Pat_token _ | T.Pat_malformed | T.Service_credential_malformed | T.No_prefix ->
        Alcotest.fail "the fixture is not a Service credential"
    in
    Alcotest.(check string)
      "another secret"
      (Sc.refusal_to_string Sc.Secret_differs)
      (service_acts t wrong);
    Alcotest.(check bool)
      "the log holds no secret"
      false
      (contains ~sub:(secret_of text) (read_file t.log_path));
    (match Sc.revoke t.zone (T.Service_credential.id token) with
     | Ok () -> ()
     | Error error -> Alcotest.failf "revoke refused: %s" (Sc.error_to_string error));
    Alcotest.(check string) "revoked" (Sc.refusal_to_string Sc.Ended) (service_acts t token);
    Alcotest.(check bool)
      "the revoke is an intent on the credential"
      true
      (contains
         ~sub:{|"event":"revoke","subject":{"type":"service_credential","id":"cred-1"}|}
         (read_file t.store_path)))
;;

let () =
  Alcotest.run
    "authz_credential_auth"
    [ ( "credentials"
      , [ Alcotest.test_case "a PAT acts until it ends" `Quick a_pat_acts_until_it_ends
        ; Alcotest.test_case
            "a Service credential acts until it is revoked"
            `Quick
            a_service_credential_acts_until_it_is_revoked
        ] )
    ]
;;
