(* The registration of a person's API key (RFC
   a-persons-api-key-is-their-own-provider-account 3.3), through the answers
   of its route, over a zone on real files and a runtime.toml the server
   reads: what a request leaves on the server when it is refused, when it
   goes through, and when the files of its account are not made. The keys of
   this file are made up. *)

open Authz_types
module Login = Server_setup_account_login
module Layout = Runtime_account_home_layout
module Files = Runtime_key_account_files
module Accounts = Authz_provider_account_state
module Purges = Authz_purge_state
module Event = Authz_purge_event
module R = Login_routes
module B = Authz_bootstrap
module E = Authz_invite_event
module Z = Authz_zone

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "a fixture path was not spelled: %s" detail
;;

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")
let the_key = "sk-test-the-key-of-alice"

(* A provider of the client whose key is taken, one of another client, and
   one that is called over HTTP. The commands name no file. *)
let runtime_toml =
  {|[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "/nonexistent/claude"
is-non-interactive = true

[providers.codex]
display-name = "Codex"
protocol = "codex-app-server"
command = "/nonexistent/codex"
is-non-interactive = true

[providers.local]
display-name = "Local server"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[models."gpt-5.5"]
api-name = "gpt-5.5"
max-context = 400000
tools-support = true
streaming = true

[models.local-model]
api-name = "local-model"
max-context = 32000
tools-support = true
streaming = true

[claude_code."claude-sonnet-5"]

[codex."gpt-5.5"]

[local.local-model]
|}
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

let rec private_dirs path =
  if not (Sys.file_exists path)
  then (
    private_dirs (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

(* A folder with exactly [mode], whatever the umask of who runs the test. *)
let folder path mode =
  private_dirs path;
  Unix.chmod path mode
;;

(* A zone a fresh bootstrap made, opened as a server opens it. [root] holds
   everything the case writes: the base path, the store and the
   configuration of the bootstrap. *)
let with_zone work () =
  Eio_main.run (fun _env ->
    let root = Unix.realpath (Filename.temp_dir "server-key-account-registration-" "") in
    Fun.protect
      ~finally:(fun () ->
        (* A tree that was not removed is said, and does not take the place
           of the failure of the case. *)
        try remove_tree root with
        | Unix.Unix_error (error, call, path) ->
          Printf.eprintf "the tree of the case stays: %s %s: %s\n" call path (Unix.error_message error)
        | Sys_error detail -> Printf.eprintf "the tree of the case stays: %s\n" detail)
      (fun () ->
        let base_path = Filename.concat root "base" in
        Unix.mkdir base_path 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let now_ms () = start_ms in
        (match
           B.fresh_bootstrap
             { B.base_path
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = workspace
             ; now_ms
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        match Z.open_at_start ~now_ms ~log_path:(Authz_log.path_of_base_path ~base_path) ~store_path:store with
        | Ok zone -> work ~zone ~root ~base_path
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)))
;;

(* The runtime.toml of the workspace, where the routes of setup read it. *)
let declare ~base_path =
  let path = Server_runtime_setup_actions.config_path ~base_path in
  private_dirs (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out runtime_toml)
;;

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_detail error)
;;

(* One person joins through an invitation, as an Admin. *)
let admit zone ~name ~hex =
  let user_id = get (User_id.of_string (String.make 32 hex)) in
  let invite_id = get (Invite_id.of_string ("invite-" ^ name)) in
  let namespace = get (Account_home_namespace.of_string ("ns-" ^ name)) in
  commit
    zone
    ~author:Authz_records.Author.Local_operator
    ~kind:Authz_record.Kind.Invite
    (get
       (E.to_body
          (E.Issued
             { invite_id
             ; token_digest = E.Token_digest.of_token ("token-" ^ name)
             ; expires_at_ms = start_ms + 3_600_000
             ; role = E.Admin
             })));
  commit
    zone
    ~author:(Authz_records.Author.Authenticated (Principal.Human user_id))
    ~kind:Authz_record.Kind.Admission
    (get
       (Authz_admission_event.to_body
          { Authz_admission_event.user_id
          ; identity = get (Authz_external_identity.google ~sub:name)
          ; through = Authz_admission_event.Invite invite_id
          ; membership = { workspace_id = workspace; account_home_namespace = namespace }
          }));
  { Login.zone; user_id; namespace }
;;

let state_of (person : Login.person) = (Z.snapshot person.zone).Z.state

let runtime_root_of ~base_path (person : Login.person) =
  Layout.person_runtime_root ~base_path ~namespace:person.namespace
;;

let home_of ~runtime_root id =
  get_text (Layout.home ~runtime_root Layout.Claude_home ~account_id:(Provider_account_id.to_string id))
;;

(* ---- a request and its answer ---- *)

let body members = Yojson.Safe.to_string (`Assoc members)

let key_body ?(integration = "claude_code") key =
  body [ "integration_id", `String integration; "key", `String key ]
;;

let register (person : Login.person) ~base_path body = Server_key_account.register ~person ~base_path ~body

let member name (answer : R.answer) =
  match Yojson.Safe.from_string answer.R.body with
  | `Assoc members -> List.assoc_opt name members
  | (_ : Yojson.Safe.t) -> None
  | exception Yojson.Json_error (_ : string) -> None
;;

let text_member name answer =
  match member name answer with
  | Some (`String text) -> Some text
  | Some (_ : Yojson.Safe.t) | None -> None
;;

(* The status of the answer and its [code]. An answer that went through has
   no code. *)
let answered label (answer : R.answer) ~status ~code =
  Alcotest.(check (pair int (option string)))
    label
    (status, code)
    (R.status_code answer.R.status, text_member "code" answer)
;;

let account_in answer =
  match text_member "provider_account_id" answer with
  | Some id -> get (Provider_account_id.of_string id)
  | None -> Alcotest.fail "the answer names no account"
;;

let holds ~text content =
  let length = String.length text in
  let last = String.length content - length in
  let rec from index = index <= last && (String.equal (String.sub content index length) text || from (index + 1)) in
  from 0
;;

let says_nothing_of label ~key (answer : R.answer) =
  Alcotest.(check bool) (label ^ ": the answer holds nothing of the key") false (holds ~text:key answer.R.body)
;;

(* The files under [root] that hold [text], every folder opened for the
   reading. *)
let holding ~text root =
  let rec under path found =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.fold_left (fun found name -> under (Filename.concat path name) found) found (Sys.readdir path)
    | { Unix.st_kind = Unix.S_REG; _ } ->
      if holds ~text (In_channel.with_open_bin path In_channel.input_all) then path :: found else found
    | { Unix.st_kind = Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } -> found
  in
  List.sort String.compare (under root [])
;;

let nothing_recorded label (person : Login.person) =
  Alcotest.(check int)
    (label ^ ": no account of the person is in the log")
    0
    (List.length (Authz_provider_account.owned (state_of person) person.user_id))
;;

(* What the records say of the removal of each account of the person. *)
let removals (person : Login.person) =
  List.filter_map
    (fun (({ owner; provider_account_id } : Event.account), (status : Purges.account_status)) ->
       if User_id.equal owner person.user_id
       then
         Some
           ( provider_account_id
           , match status with
             | Purges.Account_pending -> "pending"
             | Purges.Account_purged -> "purged"
             | Purges.Account_failed { failed_stage = Event.Key_not_removed } -> "failed:key_not_removed"
             | Purges.Account_failed { failed_stage = Event.Home_not_removed } -> "failed:home_not_removed" )
       else None)
    (Purges.accounts (state_of person).Authz_state.purges)
;;

let files_there label ~runtime_root id expected =
  match Files.present ~runtime_root ~account_id:id with
  | Ok there -> Alcotest.(check bool) label expected there
  | Error detail -> Alcotest.failf "%s: not looked at: %s" label detail
;;

let read_name path =
  match Runtime_api_key_file.read path with
  | Ok key -> "key:" ^ Runtime_api_key_file.value key
  | Error error -> Runtime_api_key_file.read_error_code error
;;

(* The file the records say the key of the account is in. *)
let key_file_of (person : Login.person) ~runtime_root id =
  match Accounts.find (state_of person).Authz_state.provider_accounts id with
  | Some { Accounts.owner; kind = Accounts.Key { integration_id; generation } } ->
    Alcotest.(check bool) "the account is the person's" true (User_id.equal owner person.user_id);
    Alcotest.(check string)
      "it is of the integration of the request"
      "claude_code"
      (Integration_id.to_string integration_id);
    get_text (Layout.key_file ~runtime_root ~account_id:id ~generation)
  | Some { Accounts.owner = _; kind = Accounts.Login } -> Alcotest.fail "the account holds a login"
  | None -> Alcotest.fail "no record links the account"
;;

(* ---- the cases ---- *)

let test_registered =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    Alcotest.(check bool) "nothing made the runtime root of the person yet" false (Sys.file_exists runtime_root);
    let first = register alice ~base_path (key_body the_key) in
    answered "a key of a Claude Code provider" first ~status:200 ~code:None;
    Alcotest.(check (option string)) "the answer gives the kind" (Some "key") (text_member "kind" first);
    says_nothing_of "a registration" ~key:the_key first;
    let account = account_in first in
    let key_file = key_file_of alice ~runtime_root account in
    Alcotest.(check string) "the key reads back from the file the records say" ("key:" ^ the_key) (read_name key_file);
    Alcotest.(check bool) "the home of the account is there" true (Sys.is_directory (home_of ~runtime_root account));
    (* What a verification and a turn do first: the runtime of a model of
       the provider, on the account, inside its call. *)
    (match
       Login.one_call_of account ~busy:None (fun in_call ->
         Login.person_runtime
           in_call
           alice
           ~base_path
           ~binding:(Runtime_account_runtime.Model "claude-sonnet-5")
         |> Result.map_error Option.some)
     with
     | Ok { Login.provider_account_id; runtime_id = _; runtime = _ } ->
       Alcotest.(check bool)
         "the runtime is of the account"
         true
         (Provider_account_id.equal provider_account_id account)
     | Error None -> Alcotest.fail "a call of the account ran after its registration"
     | Error (Some (Login.Refused ((_ : [ `Bad_request | `Not_found | `Service_unavailable ]), sentence))) ->
       Alcotest.failf "no runtime on the registered account: %s" sentence
     | Error (Some (Login.Key_unusable error)) ->
       Alcotest.failf "no runtime on the registered account: %s" (Runtime_api_key_file.read_error_code error));
    (* The request carries no idempotency key: the same key again is a
       second account. *)
    let second = register alice ~base_path (key_body the_key) in
    answered "the same key again" second ~status:200 ~code:None;
    let other = account_in second in
    Alcotest.(check bool) "it is another account" false (Provider_account_id.equal account other);
    let other_key_file = key_file_of alice ~runtime_root other in
    Alcotest.(check (list string))
      "the key is in the key files of the two accounts and in no other file of the server"
      (List.sort String.compare [ key_file; other_key_file ])
      (holding ~text:the_key root))
;;

(* A request that is refused before its record leaves nothing: no account in
   the log, and no folder of the person. *)
let test_refused =
  with_zone (fun ~zone ~root ~base_path ->
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let refused label request ~status ~code =
      let answer = register alice ~base_path request in
      answered label answer ~status ~code:(Some code);
      says_nothing_of label ~key:the_key answer;
      nothing_recorded label alice;
      Alcotest.(check bool) (label ^ ": no folder of the person was made") false (Sys.file_exists runtime_root)
    in
    refused "before runtime.toml is there" (key_body the_key) ~status:503 ~code:"configuration_unavailable";
    declare ~base_path;
    refused "a body that is the key alone" the_key ~status:400 ~code:"invalid_request";
    refused
      "a body with no key"
      (body [ "integration_id", `String "claude_code" ])
      ~status:400
      ~code:"invalid_request";
    refused
      "a body with a third member"
      (body [ "integration_id", `String "claude_code"; "key", `String the_key; "label", `String "mine" ])
      ~status:400
      ~code:"invalid_request";
    refused
      "a body with the key twice"
      (body [ "integration_id", `String "claude_code"; "key", `String the_key; "key", `String the_key ])
      ~status:400
      ~code:"invalid_request";
    refused
      "a key that is no string"
      (body [ "integration_id", `String "claude_code"; "key", `List [ `String the_key ] ])
      ~status:400
      ~code:"invalid_request";
    refused
      "an integration that is no id"
      (key_body ~integration:"../claude_code" the_key)
      ~status:400
      ~code:"invalid_request";
    refused "an empty key" (key_body " \n ") ~status:400 ~code:"not_a_key";
    refused "a key with a control character" (key_body "sk-test\tthe-key") ~status:400 ~code:"not_a_key";
    refused
      "a credential document as the key"
      (key_body (body [ "api_key", `String the_key ]))
      ~status:400
      ~code:"not_a_key";
    refused
      "an integration the workspace does not declare"
      (key_body ~integration:"claude_code_2" the_key)
      ~status:400
      ~code:"unknown_integration";
    refused
      "a provider of another client"
      (key_body ~integration:"codex" the_key)
      ~status:400
      ~code:"integration_takes_no_key";
    refused
      "a provider that is called over HTTP"
      (key_body ~integration:"local" the_key)
      ~status:400
      ~code:"integration_takes_no_key";
    Alcotest.(check (list string)) "no file of the server holds the key" [] (holding ~text:the_key root))
;;

(* The record comes first, so a person the zone turns down has nothing
   written for them. *)
let test_not_active =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let bob = admit zone ~name:"bob" ~hex:'b' in
    commit
      zone
      ~author:(Authz_records.Author.Authenticated (Principal.Human alice.Login.user_id))
      ~kind:Authz_record.Kind.Principal
      (get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = bob.Login.user_id })));
    let answer = register bob ~base_path (key_body the_key) in
    answered "a person who was disabled" answer ~status:403 ~code:(Some "registration_refused");
    nothing_recorded "a person who was disabled" bob;
    Alcotest.(check bool)
      "no folder of the person was made"
      false
      (Sys.file_exists (runtime_root_of ~base_path bob));
    Alcotest.(check (list string)) "no file of the server holds the key" [] (holding ~text:the_key root))
;;

(* The files are not made: the same request removes the account it recorded,
   and nothing of the key stays. *)
let test_files_not_made =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let not_stored label =
      let before = List.map fst (removals alice) in
      let answer = register alice ~base_path (key_body the_key) in
      answered label answer ~status:503 ~code:(Some "key_not_stored");
      says_nothing_of label ~key:the_key answer;
      (match
         List.filter
           (fun ((id, _) : Provider_account_id.t * string) ->
              not (List.exists (Provider_account_id.equal id) before))
           (removals alice)
       with
       | [ (account, status) ] ->
         Alcotest.(check string) (label ^ ": the removal of the account went through") "purged" status;
         files_there (label ^ ": no file of the account is there") ~runtime_root account false;
         Alcotest.(check bool)
           (label ^ ": the account is not one to spend")
           false
           (Result.is_ok
              (Authz_provider_account.availability (state_of alice) ~user_id:alice.Login.user_id account))
       | [] | _ :: _ :: _ -> Alcotest.failf "%s: the records hold not one removal more" label);
      Alcotest.(check (list string))
        (label ^ ": no file of the server holds the key")
        []
        (holding ~text:the_key root)
    in
    (* A folder of homes that its group reads: no home is made under it. *)
    let homes = Filename.concat runtime_root Layout.clients_dir in
    folder homes 0o750;
    not_stored "under a folder of homes open to its group";
    Unix.chmod homes 0o700;
    (* A folder of keys that its group reads: the home is made, and no key
       is written. The removal takes the home again. *)
    let keys = Filename.concat runtime_root Layout.api_keys_dir in
    folder keys 0o750;
    not_stored "under a folder of keys open to its group";
    Unix.chmod keys 0o700;
    let answer = register alice ~base_path (key_body the_key) in
    answered "with the two folders closed again" answer ~status:200 ~code:None;
    Alcotest.(check string)
      "the key reads back"
      ("key:" ^ the_key)
      (read_name (key_file_of alice ~runtime_root (account_in answer))))
;;

(* The files are not made and the removal does not go through: the answer
   gives the account, the records say how far its removal went, and its
   owner removes it. The modes that keep a folder closed do not keep the
   superuser out, so this case says nothing when the superuser runs it. *)
let test_account_stays =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      (* A folder of keys that nothing is made in and nothing is looked up
         in. *)
      let keys = Filename.concat runtime_root Layout.api_keys_dir in
      folder keys 0o000;
      let answer = register alice ~base_path (key_body the_key) in
      answered "under a folder of keys closed to its owner" answer ~status:503 ~code:(Some "account_not_removed");
      says_nothing_of "an account that stays" ~key:the_key answer;
      let account = account_in answer in
      Alcotest.(check (list (pair string string)))
        "the records say which stage of its removal stayed"
        [ Provider_account_id.to_string account, "failed:key_not_removed" ]
        (List.map (fun (id, status) -> Provider_account_id.to_string id, status) (removals alice));
      Alcotest.(check bool)
        "the account is not one to spend"
        false
        (Result.is_ok
           (Authz_provider_account.availability (state_of alice) ~user_id:alice.Login.user_id account));
      Unix.chmod keys 0o700;
      Alcotest.(check (list string)) "no file of the server holds the key" [] (holding ~text:the_key root);
      let removed =
        Server_key_account.remove
          ~person:alice
          ~base_path
          ~provider_account_id:(Provider_account_id.to_string account)
      in
      answered "its removal by its owner, the folder open again" removed ~status:200 ~code:None;
      files_there "no file of the account is there" ~runtime_root account false;
      Alcotest.(check (list (pair string string)))
        "the records say the removal went through"
        [ Provider_account_id.to_string account, "purged" ]
        (List.map (fun (id, status) -> Provider_account_id.to_string id, status) (removals alice))))
;;

let () =
  Alcotest.run
    "server_key_account_registration"
    [ ( "register"
      , [ Alcotest.test_case "the record, the files, and a runtime on them" `Quick test_registered
        ; Alcotest.test_case "a refused request leaves nothing" `Quick test_refused
        ; Alcotest.test_case "a person the zone turns down" `Quick test_not_active
        ; Alcotest.test_case "files that are not made" `Quick test_files_not_made
        ; Alcotest.test_case "an account whose removal does not go through" `Quick test_account_stays
        ] )
    ]
;;
