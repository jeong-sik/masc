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

(* The child of [with_foreign_lock]: takes the lock file the way [Fs_compat]
   does, says so, and holds the lock until its input closes. A lock that
   another process holds needs a second process, so the case starts this
   executable again. *)
let hold_lock_child_flag = "--hold-log-lock"

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) hold_lock_child_flag
  then (
    let fd = Unix.openfile Sys.argv.(2) [ Unix.O_WRONLY ] 0o600 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        output_char stdout 'R';
        flush stdout;
        try ignore (input_char stdin) with
        | End_of_file -> ());
    exit 0)
;;

(* Runs [f] while another process holds [lock_path], and returns once that
   process ended and the lock is free. *)
let with_foreign_lock ~lock_path f =
  (* Close-on-exec, so that the child does not inherit the write end of the
     release pipe and the parent's close of it reaches the child as EOF. *)
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; hold_lock_child_flag; lock_path |]
      release_read
      ready_write
      Unix.stderr
  in
  Unix.close ready_write;
  Unix.close release_read;
  let rec wait_for_child () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close release_write;
      ignore (wait_for_child () : int * Unix.process_status))
    (fun () ->
      let ready = Bytes.create 1 in
      let count = Unix.read ready_read ready 0 1 in
      Unix.close ready_read;
      if count <> 1 || Bytes.get ready 0 <> 'R' then Alcotest.fail "the lock holder did not start";
      f ())
;;

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
let the_key = "made-up-key-of-alice"

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
(* The seq of the newest line of the log ring, or the seq before the first
   line of an empty ring ([Log.Ring.recent ~since_seq] gives the lines after
   a seq). *)
let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

(* The lines of the log ring written after [since_seq], of every module. The
   cases of this file write far fewer than the limit. *)
let ring_lines_limit = 1_000

let lines_since since_seq =
  List.map
    (fun (entry : Log.Ring.entry) -> entry.Log.Ring.message)
    (Log.Ring.recent ~limit:ring_lines_limit ~since_seq ())
;;

(* Every key of this file begins with these characters. They are no shape
   the log masks ([Secret_patterns.redact_text]): a key of a masked shape
   that was written to the log is read back as its mask, and the reading of
   the log below would find no key in it. *)
let key_prefix = "made-up-key"

(* What the log writes in place of what it masked. *)
let masked = "[REDACTED]"

let store_of root = Filename.concat (Filename.concat root "store") "external.jsonl"

(* The zone of the installation, as a start of the server opens it. *)
let opened ~root ~base_path =
  match
    Z.open_at_start
      ~now_ms:(fun () -> start_ms)
      ~log_path:(Authz_log.path_of_base_path ~base_path)
      ~store_path:(store_of root)
  with
  | Ok zone -> zone
  | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
;;

let with_env_zone work () =
  Eio_main.run (fun env ->
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
        (match
           B.fresh_bootstrap
             { B.base_path
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store_of root
             ; workspace_id = workspace
             ; now_ms = (fun () -> start_ms)
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        let zone = opened ~root ~base_path in
        (* No line the server logs while a case runs holds a key or a part
           of one (RFC a-persons-api-key-is-their-own-provider-account
           3.3): the lines of every module are read, those of a
           registration that failed among them. *)
        let before = latest_ring_seq () in
        work ~env ~zone ~root ~base_path;
        List.iter
          (fun line ->
            if String_util.contains_substring line key_prefix
            then Alcotest.failf "a log line of the case holds a key: %d bytes" (String.length line);
            (* A line the log masked wrote something it took for a secret:
               a key under a name the log masks by, among them. *)
            if String_util.contains_substring line masked
            then Alcotest.failf "a log line of the case holds what the log masked: %d bytes" (String.length line))
          (lines_since before)))
;;

let with_zone work =
  with_env_zone (fun ~env:(_ : Eio_unix.Stdenv.base) ~zone ~root ~base_path -> work ~zone ~root ~base_path)
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
    refused "a key with a control character" (key_body "made-up-key\tof-alice") ~status:400 ~code:"not_a_key";
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
      let logged_before = latest_ring_seq () in
      let answer = register alice ~base_path (key_body the_key) in
      answered label answer ~status:503 ~code:(Some "key_not_stored");
      (* The failure is logged, so the reading of the log at the end of the
         case reads lines of a registration. *)
      Alcotest.(check bool)
        (label ^ ": the server logged the failure")
        true
        (lines_since logged_before <> []);
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
   superuser out, so this case is skipped when the superuser runs it. *)
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
        (List.map (fun (id, status) -> Provider_account_id.to_string id, status) (removals alice)))
    else Alcotest.skip ())
;;

(* ---- the replacement of a key (the same RFC, 3.7) ---- *)

(* Neither holds [the_key], nor the other: a file is looked for by the key
   it holds. *)
let second_key = key_prefix ^ "-the-second-of-alice"
let third_key = key_prefix ^ "-the-third-of-alice"
let left_key = key_prefix ^ "-no-record-names"
let key_of_bob = key_prefix ^ "-of-bob"
let second_key_of_bob = key_prefix ^ "-the-second-of-bob"

let replace (person : Login.person) ~base_path id body =
  Server_key_account.replace
    ~person
    ~base_path
    ~provider_account_id:(Provider_account_id.to_string id)
    ~body
;;

let replacement_body key = body [ "key", `String key ]

(* A key account of the person, as a registration leaves it. *)
let registered (person : Login.person) ~base_path key =
  let answer = register person ~base_path (key_body key) in
  answered "the registration of the case" answer ~status:200 ~code:None;
  account_in answer
;;

(* The generation the records give the key of the account. *)
let generation_of (person : Login.person) id =
  match Accounts.find (state_of person).Authz_state.provider_accounts id with
  | Some { Accounts.owner = _; kind = Accounts.Key { integration_id = _; generation } } ->
    Key_generation.to_int generation
  | Some { Accounts.owner = _; kind = Accounts.Login } | None -> Alcotest.fail "no key account has this id"
;;

(* What a refused replacement leaves: the generation and the key that were
   there, and nothing of the key that was sent. *)
let unchanged label (person : Login.person) ~root ~runtime_root id ~sent =
  Alcotest.(check int) (label ^ ": the generation is the one that was there") 1 (generation_of person id);
  Alcotest.(check string)
    (label ^ ": the key in place is the one that was there")
    ("key:" ^ the_key)
    (read_name (key_file_of person ~runtime_root id));
  Alcotest.(check (list string)) (label ^ ": no file of the server holds the key sent") [] (holding ~text:sent root)
;;

let test_replaced =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let answer = replace alice ~base_path account (replacement_body second_key) in
    answered "the key of an account of the person" answer ~status:200 ~code:None;
    says_nothing_of "a replacement" ~key:second_key answer;
    Alcotest.(check (option string))
      "the answer names the account, which is the same account"
      (Some (Provider_account_id.to_string account))
      (text_member "provider_account_id" answer);
    Alcotest.(check bool)
      "the answer says the keys before are gone"
      true
      (match member "old_keys_removed" answer with
       | Some (`Bool removed) -> removed
       | Some (_ : Yojson.Safe.t) | None -> false);
    Alcotest.(check int) "the records give the account the next generation" 2 (generation_of alice account);
    let key_file = key_file_of alice ~runtime_root account in
    Alcotest.(check string) "the new key reads back from the file the records say" ("key:" ^ second_key) (read_name key_file);
    Alcotest.(check (list string)) "the new key is in that file alone" [ key_file ] (holding ~text:second_key root);
    Alcotest.(check (list string)) "no file of the server holds the key before" [] (holding ~text:the_key root);
    Alcotest.(check bool)
      "the account is one to spend"
      true
      (Result.is_ok (Authz_provider_account.availability (state_of alice) ~user_id:alice.Login.user_id account));
    Alcotest.(check bool) "its home is there" true (Sys.is_directory (home_of ~runtime_root account));
    (* The request carries no idempotency key: the same key again is a
       second replacement. *)
    let again = replace alice ~base_path account (replacement_body second_key) in
    answered "the same key again" again ~status:200 ~code:None;
    Alcotest.(check int) "the generation goes up again" 3 (generation_of alice account);
    Alcotest.(check (list string))
      "the key is in the file of that generation alone"
      [ key_file_of alice ~runtime_root account ]
      (holding ~text:second_key root))
;;

(* What the route refuses before any record, and what each refusal leaves. *)
let test_replacement_refused =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let bob = admit zone ~name:"bob" ~hex:'b' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let refused label answer ~status ~code =
      answered label answer ~status ~code:(Some code);
      says_nothing_of label ~key:second_key answer;
      unchanged label alice ~root ~runtime_root account ~sent:second_key
    in
    refused
      "an id no account has"
      (replace alice ~base_path (get (Provider_account_id.of_string "no-such-account")) (replacement_body second_key))
      ~status:404
      ~code:"unknown_account";
    refused
      "a path that is no id"
      (Server_key_account.replace
         ~person:alice
         ~base_path
         ~provider_account_id:"../account"
         ~body:(replacement_body second_key))
      ~status:404
      ~code:"unknown_account";
    refused
      "the account of another person"
      (replace bob ~base_path account (replacement_body second_key))
      ~status:404
      ~code:"unknown_account";
    refused "a body with no member" (replace alice ~base_path account (body [])) ~status:400 ~code:"invalid_request";
    refused
      "a body with a member more"
      (replace alice ~base_path account (key_body second_key))
      ~status:400
      ~code:"invalid_request";
    refused
      "a key that is no string"
      (replace alice ~base_path account (body [ "key", `Int 1 ]))
      ~status:400
      ~code:"invalid_request";
    refused "a body that is the key and no JSON" (replace alice ~base_path account second_key) ~status:400 ~code:"invalid_request";
    refused "an empty key" (replace alice ~base_path account (replacement_body "")) ~status:400 ~code:"not_a_key";
    (* The body is read before the records of the account, and after the id. *)
    refused
      "a body that is refused, for an id no account has"
      (replace alice ~base_path (get (Provider_account_id.of_string "no-such-account")) (body []))
      ~status:400
      ~code:"invalid_request";
    refused
      "a body that is refused, for the account of another person"
      (replace bob ~base_path account (body []))
      ~status:400
      ~code:"invalid_request";
    refused
      "a body that is refused, for a path that is no id"
      (Server_key_account.replace ~person:alice ~base_path ~provider_account_id:"../account" ~body:(body []))
      ~status:404
      ~code:"unknown_account";
    (* An account that holds a login, as a login of the person records it. *)
    let login = get (Provider_account_id.of_string "login-account") in
    (match Authz_provider_account.link zone ~user_id:alice.Login.user_id ~provider_account_id:login with
     | Ok () -> ()
     | Error error -> Alcotest.failf "the login account was not recorded: %s" (Authz_provider_account.error_to_string error));
    refused
      "an account that holds a login"
      (replace alice ~base_path login (replacement_body second_key))
      ~status:400
      ~code:"not_a_key_account";
    (* The owner is asked about before the kind: what another person's
       account holds is not told. *)
    refused
      "the login account of another person"
      (replace bob ~base_path login (replacement_body second_key))
      ~status:404
      ~code:"unknown_account";
    (* A call of the account runs: a turn, a verification, or its removal. *)
    (match
       Login.one_call_of account ~busy:None (fun (_ : Login.in_call) ->
         Ok (replace alice ~base_path account (replacement_body second_key)))
     with
     | Ok answer -> refused "while a call of the account runs" answer ~status:409 ~code:"account_call_running"
     | Error (_ : unit option) -> Alcotest.fail "the call of the account was not taken");
    (* Whether a call of another person's account runs is not told. *)
    (match
       Login.one_call_of account ~busy:None (fun (_ : Login.in_call) ->
         Ok (replace bob ~base_path account (replacement_body second_key)))
     with
     | Ok answer ->
       refused
         "the account of another person, while a call of it runs"
         answer
         ~status:404
         ~code:"unknown_account"
     | Error (_ : unit option) -> Alcotest.fail "the call of the account was not taken");
    commit
      zone
      ~author:(Authz_records.Author.Authenticated (Principal.Human bob.Login.user_id))
      ~kind:Authz_record.Kind.Principal
      (get (Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = alice.Login.user_id })));
    refused
      "a person who was disabled"
      (replace alice ~base_path account (replacement_body second_key))
      ~status:403
      ~code:"replacement_refused")
;;

(* The record goes in and the key file is refused, in a folder the server
   can remove: the folder of the keys goes with the key before in it, and
   the home of the account stays. A folder of keys that others read is one
   no key is written into. *)
let test_replacement_not_stored_and_the_folder_gone =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let keys = Filename.dirname (key_file_of alice ~runtime_root account) in
    Unix.chmod keys 0o755;
    let answer = replace alice ~base_path account (replacement_body second_key) in
    answered "under a folder of keys that others read" answer ~status:503 ~code:(Some "key_not_stored");
    Alcotest.(check int) "the record went in" 2 (generation_of alice account);
    Alcotest.(check bool) "the folder of the keys is gone" false (Sys.file_exists keys);
    Alcotest.(check (list string)) "no file of the server holds the key before" [] (holding ~text:the_key root);
    Alcotest.(check (list string)) "nor the key sent" [] (holding ~text:second_key root);
    Alcotest.(check bool) "the home of the account stays" true (Sys.is_directory (home_of ~runtime_root account));
    let next = replace alice ~base_path account (replacement_body third_key) in
    answered "the next replacement" next ~status:200 ~code:None;
    Alcotest.(check int) "it took the next generation" 3 (generation_of alice account);
    Alcotest.(check string)
      "its key reads back"
      ("key:" ^ third_key)
      (read_name (key_file_of alice ~runtime_root account)))
;;

(* A file in the place of the key of the generation after, which no
   replacement of this server wrote: the record that names the generation
   makes it the file the account reads. The store fails on it, and the
   folder of the keys goes, so the account reads no key, and neither that
   file nor the key before stays on disk. The next replacement puts its key
   in place. *)
let test_replacement_over_a_file_in_its_place =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let in_the_place =
      get_text
        (Layout.key_file
           ~runtime_root
           ~account_id:account
           ~generation:(Key_generation.next Key_generation.first))
    in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 in_the_place (fun out ->
      Out_channel.output_string out left_key);
    let answer = replace alice ~base_path account (replacement_body second_key) in
    answered "over a file in the place of its key" answer ~status:503 ~code:(Some "key_not_stored");
    says_nothing_of "a key that was not stored" ~key:second_key answer;
    Alcotest.(check int) "the record went in" 2 (generation_of alice account);
    Alcotest.(check string)
      "the file the records say holds no key"
      "key_missing"
      (read_name (key_file_of alice ~runtime_root account));
    Alcotest.(check (list string)) "the file that was in the place is gone" [] (holding ~text:left_key root);
    Alcotest.(check (list string)) "the key before is gone" [] (holding ~text:the_key root);
    Alcotest.(check (list string)) "no file of the server holds the key sent" [] (holding ~text:second_key root);
    let next = replace alice ~base_path account (replacement_body third_key) in
    answered "the next replacement" next ~status:200 ~code:None;
    Alcotest.(check int) "it took the generation after the one that has no file" 3 (generation_of alice account);
    Alcotest.(check string)
      "its key reads back from the file the records say"
      ("key:" ^ third_key)
      (read_name (key_file_of alice ~runtime_root account)))
;;

(* A removal that stopped on the account: its key is not replaced, and the
   account is removed. The modes that keep a folder closed do not keep the
   superuser out, so this case and the next are skipped when the superuser
   runs them. *)
let test_replacement_after_removal =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let remove () =
        Server_key_account.remove ~person:alice ~base_path ~provider_account_id:(Provider_account_id.to_string account)
      in
      let keys = Filename.dirname (key_file_of alice ~runtime_root account) in
      Unix.chmod keys 0o500;
      answered "a removal whose key does not go" (remove ()) ~status:503 ~code:(Some "key_not_removed");
      Unix.chmod keys 0o700;
      let answer = replace alice ~base_path account (replacement_body second_key) in
      answered "an account a removal stopped on" answer ~status:409 ~code:(Some "removal_left");
      unchanged "an account a removal stopped on" alice ~root ~runtime_root account ~sent:second_key;
      answered "its removal, asked again" (remove ()) ~status:200 ~code:None;
      answered
        "an account that was removed"
        (replace alice ~base_path account (replacement_body second_key))
        ~status:404
        ~code:(Some "unknown_account");
      Alcotest.(check (list string)) "no file of the server holds the key sent" [] (holding ~text:second_key root))
    else Alcotest.skip ())
;;

(* The record goes in and the key file does not: the account has no key, and
   the key before is not read again. The folder of the keys of the case is
   one nothing is written into, so the server does not remove it either,
   and the key before stays on disk. The next replacement puts a key in
   place and takes the files before it away. *)
let test_replacement_not_stored =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let first_file = key_file_of alice ~runtime_root account in
      let keys = Filename.dirname first_file in
      Unix.chmod keys 0o500;
      let answer = replace alice ~base_path account (replacement_body second_key) in
      answered "under a folder of keys that is not written" answer ~status:503 ~code:(Some "key_not_stored");
      says_nothing_of "a key that was not stored" ~key:second_key answer;
      Unix.chmod keys 0o700;
      Alcotest.(check int) "the record went in" 2 (generation_of alice account);
      Alcotest.(check string)
        "the file the records say holds no key"
        "key_missing"
        (read_name (key_file_of alice ~runtime_root account));
      Alcotest.(check (list string)) "no file of the server holds the key sent" [] (holding ~text:second_key root);
      Alcotest.(check (list string))
        "the key before is on disk, in the folder that did not go, where nothing reads it"
        [ first_file ]
        (holding ~text:the_key root);
      (* A file of the folder that does not go: the new key is in place all
         the same, and the answer says a file stayed. *)
      let stuck = Filename.concat keys "0-stuck" in
      folder stuck 0o700;
      Out_channel.with_open_bin (Filename.concat stuck "note") (fun out -> output_string out "a note");
      Unix.chmod stuck 0o500;
      let next = replace alice ~base_path account (replacement_body third_key) in
      answered "the next replacement" next ~status:200 ~code:None;
      Alcotest.(check bool)
        "the answer says a file of the folder stayed"
        true
        (match member "old_keys_removed" next with
         | Some (`Bool removed) -> not removed
         | Some (_ : Yojson.Safe.t) | None -> false);
      Alcotest.(check int) "it took the generation after the one that has no file" 3 (generation_of alice account);
      Alcotest.(check string)
        "its key reads back from the file the records say"
        ("key:" ^ third_key)
        (read_name (key_file_of alice ~runtime_root account));
      Alcotest.(check (list string)) "the key of the first generation is gone" [] (holding ~text:the_key root);
      Unix.chmod stuck 0o700)
    else Alcotest.skip ())
;;

(* What the list of the accounts of the person says is on the account. *)
let blocked_of (person : Login.person) id =
  List.find_map
    (fun ({ provider_account_id; kind = _; blocked } : Authz_provider_account.shown) ->
      if Provider_account_id.equal provider_account_id id then Some blocked else None)
    (Authz_provider_account.shown (state_of person) person.Login.user_id)
;;

let spent (person : Login.person) id =
  Result.is_ok (Authz_provider_account.availability (state_of person) ~user_id:person.Login.user_id id)
;;

(* The runtime root of the person is not reached: the replacement is turned
   down before its record and changes nothing. The superuser reaches a
   folder whatever its mode is, so the case is skipped when the superuser
   runs it. *)
let test_replacement_without_the_runtime_root =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let above = Filename.dirname runtime_root in
      Unix.chmod above 0o000;
      let answer =
        Fun.protect
          ~finally:(fun () -> Unix.chmod above 0o700)
          (fun () -> replace alice ~base_path account (replacement_body second_key))
      in
      answered
        "under a runtime root that is not reached"
        answer
        ~status:503
        ~code:(Some "files_not_reached");
      says_nothing_of "a replacement that was not recorded" ~key:second_key answer;
      unchanged "a replacement that was not recorded" alice ~root ~runtime_root account ~sent:second_key;
      Alcotest.(check bool) "the account is one to spend" true (spent alice account);
      let again = replace alice ~base_path account (replacement_body third_key) in
      answered "the replacement, asked again" again ~status:200 ~code:None;
      Alcotest.(check int) "it took the next generation" 2 (generation_of alice account))
    else Alcotest.skip ())
;;

(* The place of the runtime root of the person holds a link that leads
   nowhere, as when the volume it led to is away. Making the folder finds
   the name there, and no file under it is reached: the replacement is
   turned down before its record. With the folder back, nothing of the
   account was changed. *)
let test_replacement_under_a_root_that_leads_nowhere =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let away = runtime_root ^ ".away" in
    Unix.rename runtime_root away;
    Unix.symlink (runtime_root ^ ".nowhere") runtime_root;
    let answer =
      Fun.protect
        ~finally:(fun () ->
          Unix.unlink runtime_root;
          Unix.rename away runtime_root)
        (fun () -> replace alice ~base_path account (replacement_body second_key))
    in
    answered
      "under a runtime root that leads nowhere"
      answer
      ~status:503
      ~code:(Some "files_not_reached");
    says_nothing_of "a replacement that was not recorded" ~key:second_key answer;
    unchanged "a replacement that was not recorded" alice ~root ~runtime_root account ~sent:second_key;
    Alcotest.(check bool) "the account is one to spend" true (spent alice account);
    let again = replace alice ~base_path account (replacement_body third_key) in
    answered "the replacement, asked again" again ~status:200 ~code:None;
    Alcotest.(check int) "it took the next generation" 2 (generation_of alice account))
;;

(* The home of the account is a folder others read. The store of the key
   is refused under such a home, so the replacement is turned down before
   its record, and the account keeps the key it has. With the home closed
   again the replacement goes through. *)
let test_replacement_over_an_open_home =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let home = home_of ~runtime_root account in
    Unix.chmod home 0o755;
    let answer = replace alice ~base_path account (replacement_body second_key) in
    answered "over a home others read" answer ~status:503 ~code:(Some "files_not_reached");
    says_nothing_of "a replacement that was not recorded" ~key:second_key answer;
    unchanged "a replacement that was not recorded" alice ~root ~runtime_root account ~sent:second_key;
    Unix.chmod home 0o700;
    let again = replace alice ~base_path account (replacement_body third_key) in
    answered "the replacement, asked again" again ~status:200 ~code:None;
    Alcotest.(check int) "it took the next generation" 2 (generation_of alice account))
;;

(* The runtime root of the person was taken away whole, with the home and
   the key of the account in it. The replacement makes the root and the
   home again, and puts its key in place. *)
let test_replacement_after_the_runtime_root_went =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    remove_tree runtime_root;
    let answer = replace alice ~base_path account (replacement_body second_key) in
    answered "over a runtime root that went" answer ~status:200 ~code:None;
    Alcotest.(check int) "it took the next generation" 2 (generation_of alice account);
    let key_file = key_file_of alice ~runtime_root account in
    Alcotest.(check string) "its key reads back" ("key:" ^ second_key) (read_name key_file);
    Alcotest.(check (list string)) "and is in that file alone" [ key_file ] (holding ~text:second_key root);
    Alcotest.(check bool) "the home of the account is there" true (Sys.is_directory (home_of ~runtime_root account)))
;;

(* The log takes the intent of a replacement and not its record, and stops.
   The request that found it so is answered as every request after it is:
   the 503 of a zone that cannot be trusted, which has no code. At the next
   start of the server the intent is one that was given up: it blocks the
   account, and the same request closes it (the same RFC, 3.7). The
   superuser writes a file whatever its mode is, so the case is skipped
   when the superuser runs it. *)
let test_replacement_given_up =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let log_path = Authz_log.path_of_base_path ~base_path in
      Unix.chmod log_path 0o400;
      let answer = replace alice ~base_path account (replacement_body second_key) in
      Unix.chmod log_path 0o600;
      answered "under a log that stopped" answer ~status:503 ~code:None;
      says_nothing_of "a replacement that was not recorded" ~key:second_key answer;
      (* The server starts again. *)
      let alice = { alice with Login.zone = opened ~root ~base_path } in
      unchanged "a replacement that was not recorded" alice ~root ~runtime_root account ~sent:second_key;
      (match blocked_of alice account with
       | Some (Some Authz_provider_account.Replacement_start_given_up) -> ()
       | Some (Some (Authz_provider_account.Removal (_ : Authz_provider_account.removal))) | Some None | None ->
         Alcotest.fail "the list does not say the start of the replacement was given up");
      Alcotest.(check bool) "no turn is let onto the account" false (spent alice account);
      let again = replace alice ~base_path account (replacement_body third_key) in
      answered "the replacement, asked again" again ~status:200 ~code:None;
      Alcotest.(check int) "it took the next generation" 2 (generation_of alice account);
      (match blocked_of alice account with
       | Some None -> ()
       | Some (Some (Authz_provider_account.Replacement_start_given_up | Authz_provider_account.Removal (_ : Authz_provider_account.removal)))
       | None -> Alcotest.fail "the request did not close what was given up");
      Alcotest.(check bool) "the account is one to spend" true (spent alice account);
      Alcotest.(check string)
        "its key reads back from the file the records say"
        ("key:" ^ third_key)
        (read_name (key_file_of alice ~runtime_root account));
      Alcotest.(check (list string)) "no file of the server holds the key before" [] (holding ~text:the_key root))
    else Alcotest.skip ())
;;

(* The server stopped between the new key of a replacement and the removal
   of the files before it: the folder of the keys holds the key of the
   generation before too. The next start of the server removes it, inside
   the call of the account (the same RFC, 3.7). *)
let test_left_keys_at_start =
  with_env_zone (fun ~env ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let first_file = key_file_of alice ~runtime_root account in
    answered
      "the replacement of the case"
      (replace alice ~base_path account (replacement_body second_key))
      ~status:200
      ~code:None;
    let key_file = key_file_of alice ~runtime_root account in
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_excl; Open_binary ]
      0o600
      first_file
      (fun out -> output_string out the_key);
    let at_start () = Eio.Switch.run (fun sw -> Server_stopped_work.start ~sw ~env ~zone ~base_path) in
    (match
       Login.one_call_of account ~busy:None (fun (_ : Login.in_call) ->
         at_start ();
         Ok ())
     with
     | Ok () -> ()
     | Error (_ : unit option) -> Alcotest.fail "the call of the account was not taken");
    Alcotest.(check (list string))
      "a start while a call of the account runs leaves the file"
      [ first_file ]
      (holding ~text:the_key root);
    at_start ();
    Alcotest.(check (list string)) "the next start removes the key before" [] (holding ~text:the_key root);
    Alcotest.(check string)
      "the key the records say reads back"
      ("key:" ^ second_key)
      (read_name key_file);
    Alcotest.(check (list string)) "and is in that file alone" [ key_file ] (holding ~text:second_key root);
    (* A runtime root that is gone is spelled and not made again. *)
    remove_tree runtime_root;
    at_start ();
    Alcotest.(check bool) "a start makes no runtime root" false (Sys.file_exists runtime_root))
;;

(* Nothing goes on records that cannot be trusted: records that went back
   name a generation before the one on disk. The log of the case stopped,
   as a record it did not take leaves it. *)
let test_left_keys_under_a_stopped_log =
  with_env_zone (fun ~env ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let first_file = key_file_of alice ~runtime_root account in
      answered
        "the replacement of the case"
        (replace alice ~base_path account (replacement_body second_key))
        ~status:200
        ~code:None;
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_excl; Open_binary ]
        0o600
        first_file
        (fun out -> output_string out the_key);
      let log_path = Authz_log.path_of_base_path ~base_path in
      Unix.chmod log_path 0o400;
      let answer = replace alice ~base_path account (replacement_body third_key) in
      Unix.chmod log_path 0o600;
      answered "under a log that stopped" answer ~status:503 ~code:None;
      Eio.Switch.run (fun sw -> Server_stopped_work.start ~sw ~env ~zone ~base_path);
      Alcotest.(check (list string))
        "a start over the zone whose log stopped leaves the file"
        [ first_file ]
        (holding ~text:the_key root);
      (* The server starts again, and reads the files again. *)
      Eio.Switch.run (fun sw ->
        Server_stopped_work.start ~sw ~env ~zone:(opened ~root ~base_path) ~base_path);
      Alcotest.(check (list string)) "a start over a zone it can trust removes it" [] (holding ~text:the_key root);
      Alcotest.(check string)
        "the key the records say reads back"
        ("key:" ^ second_key)
        (read_name (key_file_of alice ~runtime_root account)))
    else Alcotest.skip ())
;;

(* Another process holds the lock of the log for a moment and writes
   nothing. The record is not taken and the log is not stopped: the answer
   says to send the key again, and the same server takes it then. *)
let test_replacement_under_a_held_log =
  with_zone (fun ~zone ~root ~base_path ->
    declare ~base_path;
    let alice = admit zone ~name:"alice" ~hex:'a' in
    let runtime_root = runtime_root_of ~base_path alice in
    let account = registered alice ~base_path the_key in
    let lock_path = Fs_compat.private_jsonl_lock_path (Authz_log.path_of_base_path ~base_path) in
    let answer =
      with_foreign_lock ~lock_path (fun () -> replace alice ~base_path account (replacement_body second_key))
    in
    answered "while another process holds the log" answer ~status:503 ~code:(Some "replacement_not_recorded");
    says_nothing_of "a replacement that was not recorded" ~key:second_key answer;
    unchanged "a replacement that was not recorded" alice ~root ~runtime_root account ~sent:second_key;
    let again = replace alice ~base_path account (replacement_body third_key) in
    answered "the replacement, asked again of the same server" again ~status:200 ~code:None;
    Alcotest.(check int) "it took the next generation" 2 (generation_of alice account);
    Alcotest.(check bool) "the account is one to spend" true (spent alice account);
    Alcotest.(check string)
      "the key that was sent again reads back"
      ("key:" ^ third_key)
      (read_name (key_file_of alice ~runtime_root account)))
;;

(* A registration and a removal that find the log stopped are answered as
   every request after them is, and leave what was there. Each is asked of
   a zone a start opened. *)
let test_under_a_log_that_stopped =
  with_zone (fun ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let runtime_root = runtime_root_of ~base_path alice in
      let account = registered alice ~base_path the_key in
      let log_path = Authz_log.path_of_base_path ~base_path in
      let under_a_log_that_takes_no_record f =
        Unix.chmod log_path 0o400;
        Fun.protect ~finally:(fun () -> Unix.chmod log_path 0o600) f
      in
      let answer = under_a_log_that_takes_no_record (fun () -> register alice ~base_path (key_body second_key)) in
      answered "a registration under a log that stopped" answer ~status:503 ~code:None;
      says_nothing_of "a registration that was not recorded" ~key:second_key answer;
      Alcotest.(check (list string)) "no file of the server holds its key" [] (holding ~text:second_key root);
      (* The server starts again. *)
      let alice = { alice with Login.zone = opened ~root ~base_path } in
      let answer =
        under_a_log_that_takes_no_record (fun () ->
          Server_key_account.remove
            ~person:alice
            ~base_path
            ~provider_account_id:(Provider_account_id.to_string account))
      in
      answered "a removal under a log that stopped" answer ~status:503 ~code:None;
      Alcotest.(check string)
        "the key of the account is in place"
        ("key:" ^ the_key)
        (read_name (key_file_of alice ~runtime_root account)))
    else Alcotest.skip ())
;;

(* The key before of a key account, where a stopped server leaves it. *)
type left_key =
  { account : Provider_account_id.t
  ; file : string
  ; key : string
  }

let put_back { account = (_ : Provider_account_id.t); file; key } =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 file (fun out ->
    output_string out key)
;;

(* One account keeps no other waiting. The start looks at them in the order
   the records give: while the call of the first runs, and while a folder
   of the first does not go, the key the one after it left goes all the
   same. *)
let test_left_keys_of_two_accounts =
  with_env_zone (fun ~env ~zone ~root ~base_path ->
    if Unix.geteuid () <> 0
    then (
      declare ~base_path;
      let alice = admit zone ~name:"alice" ~hex:'a' in
      let bob = admit zone ~name:"bob" ~hex:'b' in
      let replaced_with_a_left_key (person : Login.person) ~before ~after =
        let runtime_root = runtime_root_of ~base_path person in
        let account = registered person ~base_path before in
        let left = { account; file = key_file_of person ~runtime_root account; key = before } in
        answered
          "the replacement of the case"
          (replace person ~base_path account (replacement_body after))
          ~status:200
          ~code:None;
        put_back left;
        left
      in
      let of_alice = replaced_with_a_left_key alice ~before:the_key ~after:second_key in
      let of_bob = replaced_with_a_left_key bob ~before:key_of_bob ~after:second_key_of_bob in
      let first, second =
        match Accounts.key_accounts (state_of alice).Authz_state.provider_accounts with
        | first :: (_ : Provider_account_id.t list) ->
          if Provider_account_id.equal first of_alice.account then of_alice, of_bob else of_bob, of_alice
        | [] -> Alcotest.fail "the records hold no key account"
      in
      let at_start () = Eio.Switch.run (fun sw -> Server_stopped_work.start ~sw ~env ~zone ~base_path) in
      (match
         Login.one_call_of first.account ~busy:None (fun (_ : Login.in_call) ->
           at_start ();
           Ok ())
       with
       | Ok () -> ()
       | Error (_ : unit option) -> Alcotest.fail "the call of the account was not taken");
      Alcotest.(check (list string))
        "the key the account after a running call left is gone"
        []
        (holding ~text:second.key root);
      Alcotest.(check (list string))
        "the key of the account whose call ran is there"
        [ first.file ]
        (holding ~text:first.key root);
      put_back second;
      let stuck = Filename.concat (Filename.dirname first.file) "0-stuck" in
      Unix.mkdir stuck 0o700;
      Out_channel.with_open_bin (Filename.concat stuck "1") (fun out -> output_string out "left");
      Unix.chmod stuck 0o500;
      at_start ();
      Alcotest.(check bool) "the folder that does not go is there" true (Sys.file_exists stuck);
      Alcotest.(check (list string))
        "the key the account after it left is gone"
        []
        (holding ~text:second.key root);
      Alcotest.(check (list string))
        "and so is the key before of the account the folder is in"
        []
        (holding ~text:first.key root);
      Unix.chmod stuck 0o700;
      at_start ();
      Alcotest.(check bool) "the next start removes what stayed" false (Sys.file_exists stuck))
    else Alcotest.skip ())
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
    ; ( "replace"
      , [ Alcotest.test_case "the record, the new key, and the keys before gone" `Quick test_replaced
        ; Alcotest.test_case "a refused request changes nothing" `Quick test_replacement_refused
        ; Alcotest.test_case "an account a removal stopped on" `Quick test_replacement_after_removal
        ; Alcotest.test_case "a key that is not stored, and the next one" `Quick test_replacement_not_stored
        ; Alcotest.test_case "a key that is not stored, and its folder gone" `Quick test_replacement_not_stored_and_the_folder_gone
        ; Alcotest.test_case "a runtime root that is not reached" `Quick test_replacement_without_the_runtime_root
        ; Alcotest.test_case "a runtime root that leads nowhere" `Quick test_replacement_under_a_root_that_leads_nowhere
        ; Alcotest.test_case "a home others read" `Quick test_replacement_over_an_open_home
        ; Alcotest.test_case "a runtime root that went" `Quick test_replacement_after_the_runtime_root_went
        ; Alcotest.test_case "a file in the place of the new key" `Quick test_replacement_over_a_file_in_its_place
        ; Alcotest.test_case "a record the log did not take, and the same request again" `Quick test_replacement_given_up
        ; Alcotest.test_case "a log another process holds for a moment" `Quick test_replacement_under_a_held_log
        ; Alcotest.test_case "a registration and a removal under a log that stopped" `Quick test_under_a_log_that_stopped
        ; Alcotest.test_case "what a stopped server left in the folder of the keys" `Quick test_left_keys_at_start
        ; Alcotest.test_case "records that cannot be trusted remove no key" `Quick test_left_keys_under_a_stopped_log
        ; Alcotest.test_case "one account keeps no other waiting" `Quick test_left_keys_of_two_accounts
        ] )
    ]
;;
