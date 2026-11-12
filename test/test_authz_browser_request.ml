(* The cookies of a browser login and the check of a request that carries the
   session cookie, against the writer zone on real files: each case
   bootstraps a fresh installation in a temporary directory, lets the first
   Admin join, and issues a session. No network. *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module Bs = Authz_browser_session
module Q = Authz_browser_request
module E = Authz_invite_event
module Z = Authz_zone

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

let admin_token = String.make 64 'a'

(* The zone of a fresh installation, the first Admin, and a cookie of theirs. *)
let with_session f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-browser-request-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let now_ms () = start_ms in
        (match
           B.fresh_bootstrap
             { B.base_path = base
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = get (Workspace_id.of_string "workspace-1")
             ; now_ms
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let log_path = Authz_log.path_of_base_path ~base_path:base in
        match Z.open_at_start ~now_ms ~log_path ~store_path:store with
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        | Ok zone ->
          (match
             Z.commit
               zone
               { Z.author = Author.Local_operator
               ; kind = Authz_record.Kind.Invite
               ; body =
                   get
                     (E.to_body
                        (E.Issued
                           { invite_id = get (Invite_id.of_string "invite-admin")
                           ; token_digest = E.Token_digest.of_token admin_token
                           ; expires_at_ms = start_ms + 3_600_000
                           ; role = E.Admin
                           }))
               }
           with
           | Ok (_ : Z.committed) -> ()
           | Error error -> Alcotest.failf "invitation refused: %s" (Z.error_detail error));
          let fresh = ref 0 in
          let draw () =
            incr fresh;
            Printf.sprintf "%032x" !fresh
          in
          let admin =
            match
              Authz_login.sign_in
                zone
                ~now_ms
                ~draw
                ~identity:(get (Authz_external_identity.google ~sub:"111"))
                ~invite:(Some (E.Token_digest.of_token admin_token))
            with
            | Ok (Authz_login.Admitted { user_id; _ }) -> user_id
            | Ok (Authz_login.Signed_in _) | Error _ -> Alcotest.fail "the first Admin did not join"
          in
          (match Bs.issue zone ~user_id:admin ~draw:(fun () -> "session-1") ~replaces:None with
           | Ok cookie -> f zone admin cookie
           | Error error -> Alcotest.failf "no session: %s" (Bs.error_to_string error))))
;;

let request ?(method_ = Q.Unsafe) ?session_cookie ?(bearer = false) ?(query_credential = false)
    ?(origin = Q.Same_origin) ?csrf () =
  { Q.method_; session_cookie; bearer; query_credential; origin; csrf }
;;

let cookie_of value =
  match Bs.Cookie.of_value value with
  | Some cookie -> cookie
  | None -> Alcotest.failf "the cookie value %S is refused" value
;;

let verdict zone request =
  match Z.read zone with
  | Error uncertain -> Alcotest.failf "the zone cannot be trusted: %s" (Z.uncertain_to_string uncertain)
  | Ok trusted ->
    (match Q.check trusted ~now_ms:start_ms request with
     | Ok Q.No_session -> "no session"
     | Ok (Q.Session { signed_in = { Bs.user_id; _ }; cookie = _ }) -> "acts as " ^ User_id.to_string user_id
     | Error refusal -> Q.refusal_to_string refusal)
;;

(* ---- the checks ---- *)

let a_request_with_its_session () =
  with_session (fun zone admin cookie ->
    let value = Bs.Cookie.to_value cookie in
    let token = Bs.csrf_token cookie in
    let acts = "acts as " ^ User_id.to_string admin in
    List.iter
      (fun (label, request, expected) -> Alcotest.(check string) label expected (verdict zone request))
      [ "a change with the token", request ~session_cookie:value ~csrf:token (), acts
      ; "a read from the same origin", request ~method_:Q.Safe ~session_cookie:value (), acts
      ; "a read that names no origin", request ~method_:Q.Safe ~session_cookie:value ~origin:Q.No_origin (), acts
      ; "no cookie", request (), "no session"
      ; "no cookie, with a bearer", request ~bearer:true ~origin:Q.Other_origin (), "no session"
      ])
;;

let a_request_that_is_refused () =
  with_session (fun zone _admin cookie ->
    let value = Bs.Cookie.to_value cookie in
    let token = Bs.csrf_token cookie in
    let other_secret =
      "session-1." ^ String.make 64 '0'
    in
    List.iter
      (fun (label, request, expected) ->
        Alcotest.(check string) label (Q.refusal_to_string expected) (verdict zone request))
      [ "a query credential", request ~query_credential:true (), Q.Query_credential
      ; ( "a query credential beside the session"
        , request ~session_cookie:value ~csrf:token ~query_credential:true ()
        , Q.Query_credential )
      ; "a bearer beside the session", request ~session_cookie:value ~csrf:token ~bearer:true (), Q.Session_and_bearer
      ; ( "a bearer beside the session on a read"
        , request ~method_:Q.Safe ~session_cookie:value ~bearer:true ()
        , Q.Session_and_bearer )
      ; "a cookie that is not one", request ~session_cookie:"session-1" ~csrf:token (), Q.Not_a_session_cookie
      ; "an empty cookie", request ~session_cookie:"" ~csrf:token (), Q.Not_a_session_cookie
      ; "a change from another origin", request ~session_cookie:value ~csrf:token ~origin:Q.Other_origin (), Q.Cross_origin
      ; ( "a read from another origin"
        , request ~method_:Q.Safe ~session_cookie:value ~origin:Q.Other_origin ()
        , Q.Cross_origin )
      ; "a change that names no origin", request ~session_cookie:value ~csrf:token ~origin:Q.No_origin (), Q.Origin_missing
      ; "a change with no token", request ~session_cookie:value (), Q.Csrf_missing
      ; "a change with another token", request ~session_cookie:value ~csrf:(String.make 64 'f') (), Q.Csrf_differs
      ; "a change with the secret as the token", request ~session_cookie:value ~csrf:(String.sub value 10 64) (), Q.Csrf_differs
      ; ( "another secret with its own token"
        , request ~session_cookie:other_secret ~csrf:(Bs.csrf_token (cookie_of other_secret)) ()
        , Q.Session_refused Bs.Secret_differs )
      ; ( "an unknown session"
        , request ~method_:Q.Safe ~session_cookie:("session-9." ^ String.sub value 10 64) ()
        , Q.Session_refused Bs.Unknown )
      ])
;;

let the_cookies () =
  with_session (fun _zone _admin cookie ->
    Alcotest.(check string)
      "the session cookie"
      ("__Host-masc_session=" ^ Bs.Cookie.to_value cookie ^ "; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=604800")
      (Q.set_session_cookie cookie);
    Alcotest.(check string)
      "its clear"
      "__Host-masc_session=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
      Q.clear_session_cookie;
    let sealed = String.make 64 'c' in
    (match Oidc_login_transaction.Sealed.of_string sealed with
     | Some txn ->
       Alcotest.(check string)
         "the transaction cookie"
         ("__Host-masc_oidc_txn=" ^ sealed ^ "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600")
         (Q.set_transaction_cookie txn)
     | None -> Alcotest.fail "fixture transaction refused");
    (* RFC 6265 section 6.1: a browser keeps at least 4096 bytes of a cookie,
       its name, value and attributes together. *)
    (match Oidc_login_transaction.Sealed.of_string (String.make Oidc_login_transaction.max_sealed_length 'c') with
     | Some longest ->
       Alcotest.(check bool)
         "the longest transaction cookie fits in 4096 bytes"
         true
         (String.length (Q.set_transaction_cookie longest) <= 4096)
     | None -> Alcotest.fail "the longest sealed text was refused");
    Alcotest.(check string)
      "its clear"
      "__Host-masc_oidc_txn=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0"
      Q.clear_transaction_cookie;
    Alcotest.(check string) "the CSRF header" "x-masc-csrf-token" Q.csrf_header)
;;

let texts_are_told_apart () =
  let texts =
    List.map
      Q.refusal_to_string
      [ Q.Query_credential
      ; Q.Session_and_bearer
      ; Q.Not_a_session_cookie
      ; Q.Cross_origin
      ; Q.Origin_missing
      ; Q.Csrf_missing
      ; Q.Csrf_differs
      ; Q.Session_refused Bs.Unknown
      ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let () =
  Alcotest.run
    "authz_browser_request"
    [ ( "check"
      , [ Alcotest.test_case "with its session" `Quick a_request_with_its_session
        ; Alcotest.test_case "refused" `Quick a_request_that_is_refused
        ] )
    ; ( "cookies"
      , [ Alcotest.test_case "values" `Quick the_cookies
        ; Alcotest.test_case "texts" `Quick texts_are_told_apart
        ] )
    ]
;;
