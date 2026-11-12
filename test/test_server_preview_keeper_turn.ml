(* One turn of a person's Keeper in the localhost preview (plan D2-8). The
   zone is on real files, made by the real bootstrap, and its records are made
   by the real writers. The runtime is the provider of a runtime.toml with a
   login receipt of each account. The Claude Code CLI is a script that answers
   the stream-json protocol, the Codex CLI is a script that answers the
   app-server protocol, and each writes down what it was started with.
   Codex has no turn without native tools, so the preview refuses a Codex
   turn before Codex starts one (plan D3c).
   The access is published once per process, so the executable has one case
   and it runs in order. *)

open Masc
open Authz_types
module Access = Runtime_account_access
module Layout = Runtime_account_home_layout
module Login = Server_setup_account_login
module Receipt = Runtime_setup_login_receipt
module B = Authz_bootstrap
module E = Authz_invite_event
module Z = Authz_zone
module R = Login_routes

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "a fixture step failed: %s" detail
;;

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_detail error)
;;

(* The CLI of the template. It answers [auth status] as a signed-in
   subscription, and a turn with "echo: " and the message. It writes the home
   it was started on, its directory, its arguments and the message to
   [<script>.turn.json]. While [<script>.hold] is there it writes
   [<script>.started] after the message and waits. *)
let fake_claude = {|#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
script = sys.argv[0]
if "auth" in args and "status" in args:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}))
    sys.exit(0)

def read():
    return json.loads(sys.stdin.readline())

def emit(frame):
    print(json.dumps(frame), flush=True)

model = args[args.index("--model") + 1]
session = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--session-id="))
request = read()
emit({"type": "control_response", "response": {"subtype": "success",
    "request_id": request["request_id"], "response": {}}})
user = read()
assert user["type"] == "user"
content = user["message"]["content"]
prompt = content if isinstance(content, str) else "".join(block.get("text", "") for block in content)
Path(script + ".turn.json").write_text(json.dumps({"home": os.environ.get("CLAUDE_CONFIG_DIR"),
    "cwd": os.getcwd(), "args": args, "prompt": prompt}))
hold = Path(script + ".hold")
if hold.exists():
    Path(script + ".started").write_text("started")
    while hold.exists():
        time.sleep(0.02)
emit({"type": "system", "subtype": "init", "session_id": session})
text = "echo: " + prompt
emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session, "uuid": "turn-assistant",
    "message": {"role": "assistant", "model": model, "content": [{"type": "text", "text": text}]}})
emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session,
    "uuid": "turn-result", "result": text, "api_error_status": None})
for line in sys.stdin:
    pass
|}

(* The Codex CLI of the template. It answers the app-server protocol as a
   signed-in subscription, and a turn with "echo: " and the message. It writes
   the home it was started on, its arguments, the parameters of
   [thread/start] and the message to [<script>.turn.json]. *)
let fake_codex = {|#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
script = sys.argv[0]

def emit(frame):
    print(json.dumps(frame), flush=True)

thread = None
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        emit({"id": request["id"], "result": {"userAgent": "fixture/0.1"}})
    elif method == "account/read":
        emit({"id": request["id"], "result": {"account": {"type": "chatgpt", "planType": "fixture-plan"},
            "requiresOpenaiAuth": True}})
    elif method == "thread/start":
        thread = request["params"]
        emit({"id": request["id"], "result": {"thread": {"id": "thread-1"}, "model": thread["model"]}})
    elif method == "turn/start":
        prompt = "".join(item.get("text", "") for item in request["params"]["input"])
        Path(script + ".turn.json").write_text(json.dumps({"home": os.environ.get("CODEX_HOME"),
            "args": args, "thread": thread, "prompt": prompt}))
        emit({"id": request["id"], "result": {"turn": {"id": "turn-1"}}})
        message = {"type": "agentMessage", "id": "message-1", "text": "echo: " + prompt, "phase": "final_answer"}
        emit({"method": "item/completed", "params": {"threadId": "thread-1", "turnId": "turn-1",
            "completedAtMs": 1, "item": message}})
        emit({"method": "turn/completed", "params": {"threadId": "thread-1",
            "turn": {"id": "turn-1", "items": [message], "status": "completed"}}})
|}

let runtime_toml ~claude ~codex =
  Printf.sprintf
    {|[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = %S
is-non-interactive = true

[providers.codex]
display-name = "Codex"
protocol = "codex-app-server"
command = %S
is-non-interactive = true

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

[claude_code."claude-sonnet-5"]

[codex."gpt-5.5"]
|}
    claude
    codex
;;

type someone =
  { person : Login.person
  ; account_id : string
  }

(* The Claude Code home of the account, as the layout spells it. *)
let home_of ~base_path (who : someone) =
  get_text
    (Layout.home
       ~runtime_root:(Layout.person_runtime_root ~base_path ~namespace:who.person.namespace)
       Layout.Claude_home
       ~account_id:who.account_id)
;;

(* The home a login of the person makes for a new account: the runtime root
   under their namespace, as the connect route makes it, and the home under it
   from the spelling of the layout ({!Runtime_setup_login_client.prepare}). *)
let login_home ~base_path ~namespace ~account_id ~client =
  let runtime_root = Layout.person_runtime_root ~base_path ~namespace in
  let private_dir path = try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> () in
  private_dir (Filename.dirname runtime_root);
  private_dir runtime_root;
  match Runtime_setup_login_client.prepare ~runtime_root ~account_id ~client ~existing:None with
  | Ok (_ : Runtime_setup_login_client.t) -> ()
  | Error detail -> Alcotest.failf "the login home was not made: %s" detail
;;

(* One person joins through an invitation and links one account of
   [integration], whose login receipt names that integration, and makes the
   Runtime of [model] on it. The id of the account is the id of its login,
   which has the shape of a generated token. *)
let join zone ~base_path ~name ~hex ~integration ~client ~model =
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
  let account = get (Provider_account_id.of_string (String.make 64 hex)) in
  login_home ~base_path ~namespace ~account_id:(Provider_account_id.to_string account) ~client;
  (match Authz_provider_account.link zone ~user_id ~provider_account_id:account with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
  (match
     Receipt.save
       ~workspace:base_path
       ~actor:(Runtime_setup_login_session.Person (User_id.to_string user_id))
       { Receipt.login_id = Provider_account_id.to_string account
       ; integration_id = integration
       ; account = Receipt.Linked
       ; status = Receipt.Complete Runtime_setup_login_client.Authenticated
       }
   with
   | Ok () -> ()
   | Error (Receipt.Not_found | Receipt.Unavailable) -> Alcotest.fail "the login receipt was not saved");
  (* The binding of [model] on the account makes this Runtime id. *)
  let runtime_id = get (Runtime_id.of_string (Provider_account_id.to_string account ^ "." ^ model)) in
  (match
     Authz_runtime.make
       zone
       ~user_id
       ~provider_account_id:account
       ~runtime_id
       ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
       ~draw:(fun () -> "grant-" ^ name)
   with
   | Ok (_ : Grant_id.t) -> ()
   | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
  { person = { Login.zone; user_id; namespace }; account_id = Provider_account_id.to_string account }, runtime_id
;;

(* The person makes a Keeper as the preview makes one, and gives it
   [runtime] when there is one. [policy] is the id its policy gets, which no
   other Keeper of the log may have. *)
let keeper zone (who : someone) name ?(policy = "policy-" ^ name) ?runtime () =
  let keeper_id = get (Keeper_id.of_string name) in
  let turn_scope =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.of_list Channel.[ Autonomous; Direct ])
    ; allowed_effects = Effect_scope.all
    }
  in
  (match
     Authz_keeper.make zone ~user_id:who.person.user_id ~keeper_id ~turn_scope ~draw:(fun () -> policy)
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  match runtime with
  | None -> ()
  | Some runtime_id ->
    (match Authz_keeper.assign zone ~user_id:who.person.user_id ~keeper_id ~runtime_id with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Authz_keeper.error_detail error))
;;

let body ~keeper ~message =
  Yojson.Safe.to_string (`Assoc [ "keeper_id", `String keeper; "message", `String message ])
;;

let seen script =
  match Yojson.Safe.from_file (script ^ ".turn.json") with
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "the CLI wrote no record"
;;

let text_of fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "the CLI record has no %s" name
;;

let args_of fields =
  match List.assoc_opt "args" fields with
  | Some (`List args) ->
    List.map
      (function
        | `String arg -> arg
        | _ -> Alcotest.fail "an argument is not a string")
      args
  | _ -> Alcotest.fail "the CLI record has no arguments"
;;

(* The value after [flag] in [args]. *)
let rec after flag = function
  | name :: value :: _ when String.equal name flag -> Some value
  | _ :: rest -> after flag rest
  | [] -> None
;;

(* Login receipts live under the configuration directory of the user. *)
let config_home = "XDG_CONFIG_HOME"

let test_turn () =
  Eio_main.run (fun env ->
    let root = Filename.temp_dir "server-preview-keeper-turn-" "" |> Unix.realpath in
    let previous = Sys.getenv_opt config_home in
    Fun.protect
      ~finally:(fun () ->
        (match previous with
         | Some value -> Unix.putenv config_home value
         | None -> Unix.unsetenv config_home);
        Fs_compat.remove_tree root)
      (fun () ->
        Unix.putenv config_home (Filename.concat root "xdg");
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
        let zone =
          match
            Z.open_at_start ~now_ms ~log_path:(Authz_log.path_of_base_path ~base_path) ~store_path:store
          with
          | Ok zone -> zone
          | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        in
        let script name body =
          let path = Filename.concat root name in
          Out_channel.with_open_bin path (fun out -> output_string out body);
          Unix.chmod path 0o700;
          path
        in
        let claude = script "claude" fake_claude in
        let codex = script "codex" fake_codex in
        let config = Filename.concat (Common.masc_dir_from_base_path ~base_path) "config" in
        Fs_compat.mkdir_p config;
        Out_channel.with_open_bin
          (Filename.concat config Config_dir_resolver.runtime_toml_filename)
          (fun out -> output_string out (runtime_toml ~claude ~codex));
        let alice, alice_runtime =
          join zone ~base_path ~name:"alice" ~hex:'a' ~integration:"claude_code"
            ~client:Runtime_setup_login_client.Claude ~model:"claude-sonnet-5"
        in
        (* The stream of a person's connection allows no origin (issue
           #51421); the operator's allows the one that asked. *)
        let from_elsewhere =
          Httpun.Request.create
            ~headers:(Httpun.Headers.of_list [ "origin", "https://elsewhere.example" ])
            `POST
            "/api/v1/setup/accounts/login"
        in
        Alcotest.(check (list (pair string string)))
          "a person's stream allows no origin"
          []
          (Login.stream_cors_headers (Login.Person alice.person) from_elsewhere);
        Alcotest.(check (option string))
          "the operator's stream allows the origin that asked"
          (Some "https://elsewhere.example")
          (List.assoc_opt
             "access-control-allow-origin"
             (Login.stream_cors_headers (Login.Operator { actor = "operator" }) from_elsewhere));
        let bob, bob_runtime =
          join zone ~base_path ~name:"bob" ~hex:'b' ~integration:"claude_code"
            ~client:Runtime_setup_login_client.Claude ~model:"claude-sonnet-5"
        in
        let carol, carol_runtime =
          join zone ~base_path ~name:"carol" ~hex:'c' ~integration:"codex"
            ~client:Runtime_setup_login_client.Codex ~model:"gpt-5.5"
        in
        keeper zone alice "keeper-alice" ~runtime:alice_runtime ();
        keeper zone alice "keeper-alice-second" ~runtime:alice_runtime ();
        keeper zone alice "keeper-alice-idle" ();
        keeper zone bob "keeper-bob" ~runtime:bob_runtime ();
        (* A Keeper name is a person's own: he has a Keeper of the name of
           hers (issue #51073). *)
        keeper zone bob "keeper-alice" ~policy:"policy-bob-keeper-alice" ~runtime:bob_runtime ();
        keeper zone carol "keeper-carol" ~runtime:carol_runtime ();
        (match
           Access.publish
             (Access.Multi_account { zone; base_path; now = (fun () -> Float.of_int start_ms /. 1000.) })
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        let answered keeper runtime text =
          ( 200
          , Printf.sprintf
              {|{"keeper_id":"%s","runtime_id":"%s","model":"claude-sonnet-5","text":"%s"}|}
              keeper
              (Runtime_id.to_string runtime)
              text )
        in
        let reply ?(pat = Pat_binding.Not_pat) (who : someone) body =
          let answer = Server_preview_keeper_turn.run ~env ~person:who.person ~pat ~base_path ~body in
          R.status_code answer.R.status, answer.R.body
        in
        let check_reply label expected actual = Alcotest.(check (pair int string)) label expected actual in
        (* The person's Keeper answers on the home of their own account. *)
        check_reply
          "her Keeper answers"
          (answered "keeper-alice" alice_runtime "echo: hello")
          (reply alice (body ~keeper:"keeper-alice" ~message:"hello"));
        let first = seen claude in
        Alcotest.(check string) "on the home of her account" (home_of ~base_path alice) (text_of first "home");
        (* A request that a personal access token authenticated runs the turn
           only inside the scope of that token. *)
        let token effects =
          Pat_binding.Pat
            { Pat_scope.scope =
                { Authorization_scope.runtimes = Runtime_scope.all
                ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
                ; allowed_effects = Effect_scope.only (Effect.Set.of_list effects)
                }
            ; expires_at = None
            }
        in
        check_reply
          "a token that covers the turn"
          (answered "keeper-alice" alice_runtime "echo: by token")
          (reply
             ~pat:(token Effect.[ Invoke_model; Manage_own_keeper; Use_tool ])
             alice
             (body ~keeper:"keeper-alice" ~message:"by token"));
        Alcotest.(check int)
          "a token that manages Keepers and calls no model"
          403
          (fst
             (reply
                ~pat:(token Effect.[ Manage_own_keeper; Read_state ])
                alice
                (body ~keeper:"keeper-alice" ~message:"refused")));
        Alcotest.(check string)
          "the refused turn started no client"
          "by token"
          (text_of (seen claude) "prompt");
        Alcotest.(check string) "with her message" "hello" (text_of first "prompt");
        Alcotest.(check (option string))
          "with no built-in tool but the lookup"
          (Some "ToolSearch")
          (after "--tools" (args_of first));
        Alcotest.(check bool)
          "in a private directory that is gone after the turn"
          false
          (Sys.file_exists (text_of first "cwd"));
        check_reply
          "request field order does not change the turn"
          (answered "keeper-alice" alice_runtime "echo: reversed")
          (reply alice {|{"message":"reversed","keeper_id":"keeper-alice"}|});
        let reversed = seen claude in
        Alcotest.(check string)
          "reversed fields keep her account home"
          (home_of ~base_path alice)
          (text_of reversed "home");
        Alcotest.(check string)
          "reversed fields keep the message"
          "reversed"
          (text_of reversed "prompt");
        (* Another person's Keeper is not there for her, and nothing starts. *)
        Sys.remove (claude ^ ".turn.json");
        check_reply
          "another person's Keeper"
          (404, {|{"error":"No Keeper of yours has this name."}|})
          (reply alice (body ~keeper:"keeper-bob" ~message:"hello"));
        check_reply
          "her Keeper with no Runtime"
          (409, {|{"error":"The Keeper has no Runtime. Give it one of yours first."}|})
          (reply alice (body ~keeper:"keeper-alice-idle" ~message:"hello"));
        check_reply
          "a blank message"
          (400, {|{"error":"The message is blank."}|})
          (reply alice (body ~keeper:"keeper-alice" ~message:" \n"));
        check_reply
          "a message over the limit"
          (400, {|{"error":"The message is longer than 4096 bytes."}|})
          (reply
             alice
             (body ~keeper:"keeper-alice" ~message:(String.make (Server_preview_keeper_turn.max_message_bytes + 1) 'a')));
        List.iter
          (fun (label, request) ->
            Alcotest.(check int) label 400 (fst (reply alice request)))
          [ "malformed JSON", "{"
          ; "a non-object body", "[]"
          ; "missing Keeper", {|{"message":"hello"}|}
          ; "missing message", {|{"keeper_id":"keeper-alice"}|}
          ; "non-string Keeper", {|{"keeper_id":1,"message":"hello"}|}
          ; "non-string message", {|{"keeper_id":"keeper-alice","message":null}|}
          ; "additional field", {|{"keeper_id":"keeper-alice","message":"hello","extra":true}|}
          ; "duplicate Keeper", {|{"keeper_id":"keeper-alice","message":"hello","keeper_id":"keeper-bob"}|}
          ; "duplicate message", {|{"keeper_id":"keeper-alice","message":"hello","message":"second"}|}
          ; "duplicate replacing a missing field", {|{"keeper_id":"keeper-alice","keeper_id":"keeper-bob"}|}
          ];
        Alcotest.(check int)
          "a name that is not a Keeper name"
          400
          (fst (reply alice (body ~keeper:".." ~message:"hello")));
        Alcotest.(check bool) "no client started" false (Sys.file_exists (claude ^ ".turn.json"));
        (* One call of an account at a time: her second Keeper runs on the
           same account, so it is told the account is busy and does not wait. *)
        let hold = claude ^ ".hold" in
        Out_channel.with_open_bin hold (fun (_ : out_channel) -> ());
        let clock = Eio.Stdenv.clock env in
        let rec started tries =
          if Sys.file_exists (claude ^ ".started")
          then ()
          else if tries = 0
          then Alcotest.fail "the first turn did not start"
          else (
            Eio.Time.sleep clock 0.02;
            started (tries - 1))
        in
        let held, busy =
          Eio.Fiber.pair
            (fun () -> reply alice (body ~keeper:"keeper-alice" ~message:"first"))
            (fun () ->
              started 500;
              let busy = reply alice (body ~keeper:"keeper-alice-second" ~message:"second") in
              Sys.remove hold;
              busy)
        in
        check_reply
          "a turn while another runs on the account"
          (409, {|{"error":"A call of the account of this Keeper's Runtime is running."}|})
          busy;
        Alcotest.(check int) "the first turn answers" 200 (fst held);
        Alcotest.(check string) "the first turn's message" "first" (text_of (seen claude) "prompt");
        check_reply
          "the account is free again"
          (answered "keeper-alice-second" alice_runtime "echo: second")
          (reply alice (body ~keeper:"keeper-alice-second" ~message:"second"));
        (* Bob's Keeper answers on his home, not hers. *)
        check_reply
          "his Keeper answers"
          (answered "keeper-bob" bob_runtime "echo: hi")
          (reply bob (body ~keeper:"keeper-bob" ~message:"hi"));
        Alcotest.(check string) "on the home of his account" (home_of ~base_path bob) (text_of (seen claude) "home");
        (* Her turns above ran her Keeper of that name on her home. His Keeper
           of the same name runs on his Runtime and his home. *)
        check_reply
          "his Keeper of her Keeper's name answers"
          (answered "keeper-alice" bob_runtime "echo: his")
          (reply bob (body ~keeper:"keeper-alice" ~message:"his"));
        Alcotest.(check string)
          "on his home, not hers"
          (home_of ~base_path bob)
          (text_of (seen claude) "home");
        Alcotest.(check bool)
          "a home of its own"
          false
          (String.equal (home_of ~base_path alice) (home_of ~base_path bob));
        (* Carol's Keeper runs on Codex. Its least posture reads what the
           server process reads, which holds the homes of other people, so
           the turn is refused and Codex runs none. *)
        check_reply
          "her Codex Keeper is refused for its native tools"
          ( 403
          , Yojson.Safe.to_string
              (`Assoc
                  [ ( "error"
                    , `String
                        (Access.native_refusal_to_string
                           (Access.Native_tools_reach_other_homes Runtime_native_tools.Native_read)) )
                  ]) )
          (reply carol (body ~keeper:"keeper-carol" ~message:"hello"));
        Alcotest.(check bool) "Codex ran no turn" false (Sys.file_exists (codex ^ ".turn.json"))))
;;

let () =
  Alcotest.run
    "server_preview_keeper_turn"
    [ "turn", [ Alcotest.test_case "a turn of a person's Keeper" `Quick test_turn ] ]
;;
