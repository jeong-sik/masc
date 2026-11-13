(* The turns of a person's Keeper in the localhost preview (plan D2-8) and the
   conversation they make (plan S1b-3). The
   zone is on real files, made by the real bootstrap, and its records are made
   by the real writers. The runtime is the provider of a runtime.toml with a
   login receipt of each account. The Claude Code CLI is a script that answers
   the stream-json protocol, the Codex CLI is a script that answers the
   app-server protocol, and each writes down what it was started with.
   Codex has no turn without native tools, so the preview refuses a Codex
   turn before Codex starts one (plan D3c).
   A turn of Claude Code is recorded under the namespace of the person, and
   the next turn of the Keeper resumes the session of the last answer.
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
module Conversation = Server_keeper_conversation

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
   [<script>.started] after the message and waits. While [<script>.fail] is
   there it ends after the message with no answer, and while [<script>.lost]
   is there it ends so when it was started to resume a session. The session
   is the one it was started with, new or resumed. *)
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
session = next(arg.split("=", 1)[1] for arg in args if arg.startswith(("--session-id=", "--resume=")))
request = read()
emit({"type": "control_response", "response": {"subtype": "success",
    "request_id": request["request_id"], "response": {}}})
user = read()
assert user["type"] == "user"
content = user["message"]["content"]
prompt = content if isinstance(content, str) else "".join(block.get("text", "") for block in content)
Path(script + ".turn.json").write_text(json.dumps({"home": os.environ.get("CLAUDE_CONFIG_DIR"),
    "cwd": os.getcwd(), "args": args, "prompt": prompt}))
if Path(script + ".fail").exists():
    sys.exit(1)
if Path(script + ".lost").exists() and any(arg.startswith("--resume=") for arg in args):
    sys.exit(1)
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

(* A provider of each kind, for what a person is offered (plan L2a). The
   commands name no file, so a check that reaches a client fails at once
   instead of starting the one on PATH. *)
let offered_toml =
  {|[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "/nonexistent/claude"
is-non-interactive = true

[providers.local]
display-name = "Local server"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.codex]
display-name = "Codex"
protocol = "codex-app-server"
command = "/nonexistent/codex"
is-non-interactive = true

[providers.agy]
display-name = "Antigravity"
protocol = "antigravity-cli"
command = "/nonexistent/agy"
is-non-interactive = true
timeout-s = 180.0

[providers.muse]
display-name = "Muse Code"
protocol = "muse-serve"
command = "/nonexistent/muse"
is-non-interactive = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[models."claude-opus-5"]
api-name = "claude-opus-5"
max-context = 1000000
tools-support = true
streaming = true

[models.claude-notools]
api-name = "claude-notools"
max-context = 200000
streaming = true

[models."gpt-5.5"]
api-name = "gpt-5.5"
max-context = 400000
tools-support = true
streaming = true

[models.muse-fixture]
api-name = "muse-fixture-1"
max-context = 200000
tools-support = true
streaming = true

[models.local-model]
api-name = "local-model"
max-context = 32000
tools-support = true
streaming = true

[claude_code."claude-sonnet-5"]

[claude_code."claude-opus-5"]

[claude_code.claude-notools]

[local.local-model]

[codex."gpt-5.5"]

[muse.muse-fixture]
|}
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

(* The answer of a turn of a conversation that the client ended without an
   answer. It names the way on and no cause. *)
let no_answer_in_conversation =
  {|{"error":"The client ended the turn without an answer. When the turns of this conversation keep failing, start a new conversation."}|}
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

(* The argument that starts with [prefix], without it. *)
let valued prefix args =
  List.find_map
    (fun arg ->
       if String.starts_with ~prefix arg
       then Some (String.sub arg (String.length prefix) (String.length arg - String.length prefix))
       else None)
    args
;;

let new_session = valued "--session-id="
let resumed_session = valued "--resume="

(* The directory of the conversations of the person, and the rows of a file
   under it. *)
let records_of ~base_path (who : someone) =
  Filename.concat
    (Layout.person_runtime_root ~base_path ~namespace:who.person.namespace)
    "keeper-conversations"
;;

let rows path =
  In_channel.with_open_bin path In_channel.input_lines
  |> List.map (fun row ->
    match Yojson.Safe.from_string row with
    | `Assoc fields -> fields
    | _ -> Alcotest.failf "a row of %s is not an object" (Filename.basename path))
;;

let kinds path = List.map (fun fields -> text_of fields "kind") (rows path)

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
        (* What the page of a person is told before any call (plan L2a): the
           Claude Code model runs here, and the Codex one is refused for the
           native tools that refuse Carol's turn below. *)
        Alcotest.(check (pair int string))
          "the integrations a person is offered"
          ( 200
          , {|{"integrations":[{"integration_id":"claude_code","display_name":"Claude Code","models":["claude-sonnet-5"],"calls":"allowed"},{"integration_id":"codex","display_name":"Codex","models":["gpt-5.5"],"calls":"refused","refusal":"native_tools_reach_other_homes"}]}|}
          )
          (let { R.status; headers = _; body } = Server_person_integrations.answer ~base_path in
           R.status_code status, body);
        (* A person logs in to the official clients that keep their
           credential in the home of the account. Antigravity keeps a copy in
           the setup registry, and a server over HTTP has no login: neither is
           offered. A model that declares no tool calling is not offered
           either: its verification ends before the client starts. Of the
           three, only Claude Code calls a model here. *)
        let every_kind =
          match Runtime_toml.parse_string offered_toml with
          | Ok config -> config
          | Error _ -> Alcotest.fail "the runtime.toml of every kind does not parse"
        in
        let offered = Server_person_integrations.of_config every_kind in
        Alcotest.(check (list (pair string (list string))))
          "the providers a person may connect, in declared order, with their models"
          [ "claude_code", [ "claude-sonnet-5"; "claude-opus-5" ]
          ; "codex", [ "gpt-5.5" ]
          ; "muse", [ "muse-fixture" ]
          ]
          (List.map
             (fun (offer : Server_person_integrations.integration) ->
               offer.integration_id, offer.models)
             offered);
        Alcotest.(check (list string))
          "the integrations whose models are called here"
          [ "claude_code" ]
          (List.filter_map
             (fun (offer : Server_person_integrations.integration) ->
               match offer.calls with
               | Server_person_integrations.Allowed -> Some offer.integration_id
               | Server_person_integrations.Refused (Access.Native_tools_reach_other_homes _) -> None
               | Server_person_integrations.Refused refusal ->
                 Alcotest.failf
                   "%s was refused for another reason: %s"
                   offer.integration_id
                   (Access.native_refusal_to_string refusal))
             offered);
        (* The model left out is the one a verification of her account
           refuses before any client starts. The window is never reached. *)
        (let left_out =
           match
             Runtime_account_runtime.of_template
               every_kind
               ~template:"claude_code"
               ~provider_id:alice.account_id
               ~account_home:(home_of ~base_path alice)
               ~binding:(Runtime_account_runtime.Model "claude-notools")
           with
           | Ok runtime -> runtime
           | Error error -> Alcotest.fail (Runtime_account_runtime.error_to_string error)
         in
         let window_s = 60. in
         let verdict =
           Eio.Switch.run (fun sw ->
             Runtime_verification.verify
               ~secure_random:(Eio.Stdenv.secure_random env)
               ~sw
               ~net:(Eio.Stdenv.net env)
               ~mgr:(Eio.Stdenv.process_mgr env)
               ~clock:(Eio.Stdenv.clock env)
               ~cwd:Eio.Path.(Eio.Stdenv.fs env / root)
               ~cwd_path:root
               ~timeout_s:window_s
               ~account_request:
                 (Access.Own_account
                    { user_id = alice.person.user_id
                    ; provider_account_id = get (Provider_account_id.of_string alice.account_id)
                    })
               left_out)
         in
         Alcotest.(check (option string))
           "the verification of the model left out"
           (Some "tools_not_declared")
           (Option.map Runtime_verification.failure_code verdict.Runtime_verification.failure));
        (* The answer of a turn of [keeper] on [runtime]: its fields in
           order, [text], and whether the turn resumed. The conversation it
           names is the value. *)
        let answered label ~keeper ~runtime ~text ~continued (status, body) =
          let fields =
            match status, Yojson.Safe.from_string body with
            | 200, `Assoc fields -> fields
            | _ -> Alcotest.failf "%s: the turn was not answered: %d %s" label status body
          in
          Alcotest.(check (list string))
            (label ^ ": the fields of the answer")
            [ "keeper_id"; "runtime_id"; "model"; "text"; "conversation_id"; "continued" ]
            (List.map fst fields);
          List.iter
            (fun (name, expected) ->
               Alcotest.(check string) (label ^ ": " ^ name) expected (text_of fields name))
            [ "keeper_id", keeper
            ; "runtime_id", Runtime_id.to_string runtime
            ; "model", "claude-sonnet-5"
            ; "text", text
            ];
          Alcotest.(check bool)
            (label ^ ": whether the turn resumed")
            true
            (List.assoc_opt "continued" fields = Some (`Bool continued));
          text_of fields "conversation_id"
        in
        let reply ?(pat = Pat_binding.Not_pat) (who : someone) body =
          let answer = Server_preview_keeper_turn.run ~env ~person:who.person ~pat ~base_path ~body in
          R.status_code answer.R.status, answer.R.body
        in
        let check_reply label expected actual = Alcotest.(check (pair int string)) label expected actual in
        (* The person's Keeper answers on the home of their own account. *)
        let conversation =
          answered
            "her Keeper answers"
            ~keeper:"keeper-alice"
            ~runtime:alice_runtime
            ~text:"echo: hello"
            ~continued:false
            (reply alice (body ~keeper:"keeper-alice" ~message:"hello"))
        in
        let first = seen claude in
        let session =
          match new_session (args_of first), resumed_session (args_of first) with
          | Some session, None -> session
          | _ -> Alcotest.fail "the first turn did not start a session"
        in
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
        (* The second turn of the Keeper goes on in the conversation: the
           client resumes the session of the first answer, in the directory
           of the first turn. *)
        Alcotest.(check string)
          "a token that covers the turn stays in the conversation"
          conversation
          (answered
             "a token that covers the turn"
             ~keeper:"keeper-alice"
             ~runtime:alice_runtime
             ~text:"echo: by token"
             ~continued:true
             (reply
                ~pat:(token Effect.[ Invoke_model; Manage_own_keeper; Use_tool ])
                alice
                (body ~keeper:"keeper-alice" ~message:"by token")));
        let second = seen claude in
        Alcotest.(check (pair (option string) (option string)))
          "the second turn resumes the session of the first"
          (None, Some session)
          (new_session (args_of second), resumed_session (args_of second));
        Alcotest.(check string)
          "in the directory of the first turn"
          (text_of first "cwd")
          (text_of second "cwd");
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
        let alice_records = records_of ~base_path alice in
        let alice_turns = List.fold_left Filename.concat alice_records [ conversation; "turns.jsonl" ] in
        Alcotest.(check string)
          "in the directory of the conversation, under her namespace"
          (List.fold_left Filename.concat alice_records [ conversation; "cwd" ])
          (text_of first "cwd");
        (* The token that calls no model was refused before the record. *)
        Alcotest.(check (list string))
          "the two turns are recorded"
          [ "asked"; "answered"; "asked"; "answered" ]
          (kinds alice_turns);
        (match rows alice_turns with
         | [ asked; answer; _; _ ] ->
           Alcotest.(check string) "her message is recorded" "hello" (text_of asked "message");
           Alcotest.(check string) "the answer is recorded" "echo: hello" (text_of answer "text");
           Alcotest.(check string) "with the session of the client" session (text_of answer "session_id")
         | _ -> Alcotest.fail "the record does not have four rows");
        let (_ : string) =
          answered
            "request field order does not change the turn"
            ~keeper:"keeper-alice"
            ~runtime:alice_runtime
            ~text:"echo: reversed"
            ~continued:true
            (reply alice {|{"message":"reversed","keeper_id":"keeper-alice"}|})
        in
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
        (* The refused call wrote nothing: this is the first turn of her
           second Keeper, in a conversation of its own. *)
        let second_conversation =
          answered
            "the account is free again"
            ~keeper:"keeper-alice-second"
            ~runtime:alice_runtime
            ~text:"echo: second"
            ~continued:false
            (reply alice (body ~keeper:"keeper-alice-second" ~message:"second"))
        in
        Alcotest.(check bool)
          "her second Keeper has a conversation of its own"
          false
          (String.equal conversation second_conversation);
        (* A turn the client ends without an answer is recorded as failed,
           and the next turn resumes the session of the last answer. *)
        let fail = claude ^ ".fail" in
        Out_channel.with_open_bin fail (fun (_ : out_channel) -> ());
        check_reply
          "a turn the client ends without an answer"
          (502, no_answer_in_conversation)
          (reply alice (body ~keeper:"keeper-alice" ~message:"lost"));
        Sys.remove fail;
        (match List.rev (rows alice_turns) with
         | failed :: asked :: _ ->
           Alcotest.(check string) "the failed turn is recorded" "failed" (text_of failed "kind");
           Alcotest.(check string) "with the kind of the failure" "no_answer" (text_of failed "failure");
           Alcotest.(check string) "after its message" "lost" (text_of asked "message")
         | _ -> Alcotest.fail "the failed turn left no rows");
        let (_ : string) =
          answered
            "the turn after a failed one"
            ~keeper:"keeper-alice"
            ~runtime:alice_runtime
            ~text:"echo: again"
            ~continued:true
            (reply alice (body ~keeper:"keeper-alice" ~message:"again"))
        in
        Alcotest.(check (option string))
          "resumes the session of the last answer"
          (Some session)
          (resumed_session (args_of (seen claude)));
        (* A conversation stays on the account it began on. Her idle Keeper
           gets a Runtime, and its conversation is one that began on another
           account: the turn is refused and no client starts. *)
        let idle = get (Keeper_id.of_string "keeper-alice-idle") in
        (match Authz_keeper.assign zone ~user_id:alice.person.user_id ~keeper_id:idle ~runtime_id:alice_runtime with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
        let elsewhere =
          match
            Conversation.start
              (Conversation.root ~base_path ~namespace:alice.person.namespace)
              idle
              (get (Provider_account_id.of_string "another-account"))
              ~draw:(fun () -> "conversation-elsewhere")
              ~now_ms:(fun () -> start_ms)
              ~one_call_of:Login.one_call_of
          with
          | Ok (conversation : Conversation.conversation) ->
            Conversation.Conversation_id.to_string conversation.conversation_id
          | Error Conversation.Account_busy -> Alcotest.fail "the account was busy"
          | Error (Conversation.Record_failed error) -> Alcotest.fail (Conversation.error_to_string error)
        in
        Sys.remove (claude ^ ".turn.json");
        check_reply
          "a conversation that began on another subscription"
          ( 409
          , {|{"error":"The conversation of this Keeper began on another subscription of yours. Start a new conversation."}|}
          )
          (reply alice (body ~keeper:"keeper-alice-idle" ~message:"hello"));
        Alcotest.(check bool)
          "the conversation of another subscription has no turn"
          false
          (Sys.file_exists (Filename.concat alice_records elsewhere));
        (* She starts a new conversation of the Keeper, on the account of the
           Runtime it has now, and its next turn runs there in a session of
           its own. *)
        let renew who body =
          let answer =
            Server_preview_keeper_conversation.start ~env ~person:who.person ~base_path ~body
          in
          R.status_code answer.R.status, answer.R.body
        in
        let only_keeper name = Yojson.Safe.to_string (`Assoc [ "keeper_id", `String name ]) in
        let renewed =
          match renew alice (only_keeper "keeper-alice-idle") with
          | 200, body ->
            (match Yojson.Safe.from_string body with
             | `Assoc [ ("keeper_id", `String "keeper-alice-idle"); ("conversation_id", `String id) ] -> id
             | _ -> Alcotest.failf "the new conversation is answered as %s" body)
          | status, body -> Alcotest.failf "no new conversation: %d %s" status body
        in
        Alcotest.(check string)
          "the turn after it runs in the new conversation"
          renewed
          (answered
             "the turn in a new conversation"
             ~keeper:"keeper-alice-idle"
             ~runtime:alice_runtime
             ~text:"echo: fresh"
             ~continued:false
             (reply alice (body ~keeper:"keeper-alice-idle" ~message:"fresh")));
        Alcotest.(check (option string))
          "in a session of its own"
          None
          (resumed_session (args_of (seen claude)));
        Sys.remove (claude ^ ".turn.json");
        (* A session the vendor no longer has: the client does not resume it.
           Each turn tries the session of the last answer again and fails,
           and the server starts no session in its place. The stand-in ends
           such a turn as one with no answer; how the real client ends it is
           not measured. *)
        let lost = claude ^ ".lost" in
        Out_channel.with_open_bin lost (fun (_ : out_channel) -> ());
        List.iter
          (fun message ->
            check_reply
              "a turn of a conversation whose session is gone"
              (502, no_answer_in_conversation)
              (reply alice (body ~keeper:"keeper-alice" ~message));
            Alcotest.(check (option string))
              "tries the session of the last answer again"
              (Some session)
              (resumed_session (args_of (seen claude))))
          [ "gone"; "still gone" ];
        Sys.remove (claude ^ ".turn.json");
        (* The directory of a conversation that others can enter is not used:
           the turn is refused and no client starts. *)
        let alice_conversation = Filename.concat alice_records conversation in
        Unix.chmod alice_conversation 0o755;
        check_reply
          "a turn of a conversation whose directory is not private"
          (503, {|{"error":"The record of this conversation could not be read or written."}|})
          (reply alice (body ~keeper:"keeper-alice" ~message:"open"));
        Alcotest.(check bool)
          "starts no client"
          false
          (Sys.file_exists (claude ^ ".turn.json"));
        Unix.chmod alice_conversation 0o700;
        (* A new conversation of her first Keeper is the way on: the next
           turn starts a session of its own though the client still resumes
           none, and the rows of the conversation before it stay. *)
        let rows_before = List.length (rows alice_turns) in
        (match renew alice (only_keeper "keeper-alice") with
         | 200, (_ : string) -> ()
         | status, body -> Alcotest.failf "no new conversation: %d %s" status body);
        Alcotest.(check bool)
          "her first Keeper has another conversation"
          false
          (String.equal
             conversation
             (answered
                "the first turn after a new conversation"
                ~keeper:"keeper-alice"
                ~runtime:alice_runtime
                ~text:"echo: anew"
                ~continued:false
                (reply alice (body ~keeper:"keeper-alice" ~message:"anew"))));
        Alcotest.(check int)
          "the conversation before it keeps its rows and gets no other"
          rows_before
          (List.length (rows alice_turns));
        Alcotest.(check (pair bool (option string)))
          "the turn started a session and resumed none"
          (true, None)
          (Option.is_some (new_session (args_of (seen claude))), resumed_session (args_of (seen claude)));
        Sys.remove lost;
        (* She reads what she asked and was answered. The read answers the
           current conversation, and an earlier one by its id. *)
        let read (who : someone) query =
          let answer =
            Server_preview_keeper_conversation.read ~person:who.person ~base_path ~query
          in
          R.status_code answer.R.status, answer.R.body
        in
        let read_fields label answer =
          match answer with
          | 200, body ->
            (match Yojson.Safe.from_string body with
             | `Assoc fields -> fields
             | _ -> Alcotest.failf "%s: the read is not an object" label)
          | status, body -> Alcotest.failf "%s: not read: %d %s" label status body
        in
        let turns_of fields =
          match List.assoc_opt "turns" fields with
          | Some (`List turns) ->
            List.map
              (function
                | `Assoc turn -> turn
                | _ -> Alcotest.fail "a turn is not an object")
              turns
          | _ -> Alcotest.fail "the read has no turns"
        in
        let shown fields = List.map (fun turn -> text_of turn "message", text_of turn "outcome") (turns_of fields) in
        let now = read_fields "the current conversation" (read alice [ "keeper_id", "keeper-alice" ]) in
        Alcotest.(check (list string))
          "the fields of the read"
          [ "keeper_id"; "current_conversation_id"; "conversations"; "conversation_id"; "turns" ]
          (List.map fst now);
        Alcotest.(check (list (pair string string)))
          "the current conversation has the turn after it was started"
          [ "anew", "answered" ]
          (shown now);
        Alcotest.(check bool)
          "the current conversation is not the first"
          false
          (String.equal conversation (text_of now "current_conversation_id"));
        Alcotest.(check string)
          "the turns read are those of the current conversation"
          (text_of now "current_conversation_id")
          (text_of now "conversation_id");
        (match List.assoc_opt "conversations" now with
         | Some (`List [ `Assoc first; `Assoc second ]) ->
           Alcotest.(check string) "the first conversation is listed first" conversation (text_of first "conversation_id");
           Alcotest.(check string)
             "the current one is listed last"
             (text_of now "current_conversation_id")
             (text_of second "conversation_id");
           Alcotest.(check (list string))
             "a listed conversation holds no text"
             [ "conversation_id"; "provider_account_id"; "started_at_ms" ]
             (List.map fst first);
           Alcotest.(check string)
             "and names the account it began on"
             alice.account_id
             (text_of first "provider_account_id")
         | _ -> Alcotest.fail "the Keeper does not list two conversations");
        let earlier =
          read_fields
            "the first conversation"
            (read alice [ "keeper_id", "keeper-alice"; "conversation_id", conversation ])
        in
        Alcotest.(check (list (pair string string)))
          "the first conversation has its turns in order"
          [ "hello", "answered"
          ; "by token", "answered"
          ; "reversed", "answered"
          ; "first", "answered"
          ; "lost", "failed"
          ; "again", "answered"
          ; "gone", "failed"
          ; "still gone", "failed"
          ]
          (shown earlier);
        (match turns_of earlier with
         | answered_turn :: _ ->
           Alcotest.(check (list string))
             "an answered turn names no session"
             [ "message"; "asked_at_ms"; "outcome"; "text"; "model"; "answered_at_ms" ]
             (List.map fst answered_turn);
           Alcotest.(check string) "with the answer" "echo: hello" (text_of answered_turn "text")
         | [] -> Alcotest.fail "the first conversation has no turn");
        Alcotest.(check (list (pair string bool)))
          "each failed turn names its failure, and its client was started with the message"
          [ "no_answer", true; "no_answer", true; "no_answer", true ]
          (List.filter_map
             (fun turn ->
                if String.equal (text_of turn "outcome") "failed"
                then Some (text_of turn "failure", List.assoc_opt "model_may_have_read" turn = Some (`Bool true))
                else None)
             (turns_of earlier));
        (* A turn the server stopped in has its message and no end. *)
        let records = Conversation.root ~base_path ~namespace:alice.person.namespace in
        (match Conversation.conversations records idle with
         | Ok listed ->
           (match List.rev listed with
            | { Conversation.conversation; started_at_ms = _ } :: _ ->
              (match
                 Result.bind (Conversation.open_turn records conversation) (fun turn ->
                   Conversation.ask
                     turn
                     ~message:"stopped"
                     ~draw:(fun () -> "turn-stopped")
                     ~now_ms:(fun () -> start_ms))
               with
               | Ok (_ : Conversation.asked) -> ()
               | Error error -> Alcotest.fail (Conversation.error_to_string error))
            | [] -> Alcotest.fail "her idle Keeper has no conversation")
         | Error error -> Alcotest.fail (Conversation.error_to_string error));
        let stopped = read_fields "a stopped turn" (read alice [ "keeper_id", "keeper-alice-idle" ]) in
        Alcotest.(check (list (pair string string)))
          "the stopped turn is read as unrecorded"
          [ "fresh", "answered"; "stopped", "unrecorded" ]
          (shown stopped);
        (* The record is hers: his Keeper of the same name does not have her
           conversation, and he reads his own. *)
        check_reply
          "her conversation is not one of his Keeper"
          (404, {|{"error":"No conversation of this Keeper has this id."}|})
          (read bob [ "keeper_id", "keeper-alice"; "conversation_id", conversation ]);
        Alcotest.(check (list (pair string string)))
          "his Keeper of her Keeper's name has no turn yet"
          []
          (shown (read_fields "his Keeper" (read bob [ "keeper_id", "keeper-alice" ])));
        check_reply
          "the conversation of another person's Keeper"
          (404, {|{"error":"No Keeper of yours has this name."}|})
          (read alice [ "keeper_id", "keeper-bob" ]);
        List.iter
          (fun (label, query) -> Alcotest.(check int) label 400 (fst (read alice query)))
          [ "a read with no Keeper", []
          ; "a read with two Keepers", [ "keeper_id", "keeper-alice"; "keeper_id", "keeper-alice-second" ]
          ; "a read with another name", [ "keeper_id", "keeper-alice"; "limit", "1" ]
          ; "a read with an id that is no id", [ "keeper_id", "keeper-alice"; "conversation_id", ".." ]
          ; "a read with a name that is no Keeper name", [ "keeper_id", ".." ]
          ];
        (* A row a stopped server left half written. The read writes nothing
           and is refused. The next turn of the conversation cuts the row, and
           the read after it has that turn. *)
        let current = text_of now "current_conversation_id" in
        let current_turns = List.fold_left Filename.concat alice_records [ current; "turns.jsonl" ] in
        let whole = In_channel.with_open_bin current_turns In_channel.input_all in
        let half = {|{"kind":"asked","turn_id":"half|} in
        Out_channel.with_open_gen
          [ Open_wronly; Open_append; Open_binary ]
          0o600
          current_turns
          (fun out -> output_string out half);
        check_reply
          "the read of a record with a half written row"
          (503, {|{"error":"The record of this conversation could not be read or written."}|})
          (read alice [ "keeper_id", "keeper-alice" ]);
        Alcotest.(check string)
          "the read leaves the row as it was"
          (whole ^ half)
          (In_channel.with_open_bin current_turns In_channel.input_all);
        Alcotest.(check string)
          "the next turn of the conversation goes on in it"
          current
          (answered
             "the turn after a half written row"
             ~keeper:"keeper-alice"
             ~runtime:alice_runtime
             ~text:"echo: after"
             ~continued:true
             (reply alice (body ~keeper:"keeper-alice" ~message:"after")));
        Alcotest.(check (list (pair string string)))
          "and the read after it has that turn, and not the half row"
          [ "anew", "answered"; "after", "answered" ]
          (shown (read_fields "after a half written row" (read alice [ "keeper_id", "keeper-alice" ])));
        (* A conversation gets no turn after a new one starts, so the start
           cuts such a row in it, and the conversation reads whole by its
           id. *)
        let settled = In_channel.with_open_bin current_turns In_channel.input_all in
        Out_channel.with_open_gen
          [ Open_wronly; Open_append; Open_binary ]
          0o600
          current_turns
          (fun out -> output_string out half);
        Alcotest.(check int)
          "a new conversation after a half written row"
          200
          (fst (renew alice (only_keeper "keeper-alice")));
        Alcotest.(check string)
          "cuts the row of the conversation it follows"
          settled
          (In_channel.with_open_bin current_turns In_channel.input_all);
        Alcotest.(check (list (pair string string)))
          "and that conversation reads whole"
          [ "anew", "answered"; "after", "answered" ]
          (shown
             (read_fields
                "the conversation a new one follows"
                (read alice [ "keeper_id", "keeper-alice"; "conversation_id", current ])));
        (* No new conversation starts while a call of the account of the
           current one runs: a turn of it could write after the start. *)
        let followed =
          text_of
            (read_fields "a new conversation" (read alice [ "keeper_id", "keeper-alice" ]))
            "current_conversation_id"
        in
        (match
           Login.one_call_of
             (get (Provider_account_id.of_string alice.account_id))
             ~busy:"the call of the test did not start"
             (fun () -> Ok (renew alice (only_keeper "keeper-alice")))
         with
         | Ok answer ->
           check_reply
             "a new conversation while a call of the account runs"
             (409, {|{"error":"A call of the account of this Keeper's current conversation is running."}|})
             answer
         | Error busy -> Alcotest.fail busy);
        Alcotest.(check string)
          "starts none"
          followed
          (text_of
             (read_fields "after a refused start" (read alice [ "keeper_id", "keeper-alice" ]))
             "current_conversation_id");
        Sys.remove (claude ^ ".turn.json");
        check_reply
          "a new conversation of another person's Keeper"
          (404, {|{"error":"No Keeper of yours has this name."}|})
          (renew alice (only_keeper "keeper-bob"));
        List.iter
          (fun (label, request) -> Alcotest.(check int) label 400 (fst (renew alice request)))
          [ "a new conversation: malformed JSON", "{"
          ; "a new conversation: no Keeper", "{}"
          ; "a new conversation: an additional field", {|{"keeper_id":"keeper-alice","message":"hello"}|}
          ; "a new conversation: a duplicate Keeper", {|{"keeper_id":"keeper-alice","keeper_id":"keeper-bob"}|}
          ; "a new conversation: a non-string Keeper", {|{"keeper_id":1}|}
          ];
        (* A row the server does not understand refuses the turn. It is not
           skipped and not repaired. *)
        let second_turns =
          List.fold_left Filename.concat alice_records [ second_conversation; "turns.jsonl" ]
        in
        let before = In_channel.with_open_bin second_turns In_channel.input_all in
        Out_channel.with_open_gen
          [ Open_wronly; Open_append; Open_binary ]
          0o600
          second_turns
          (fun out -> output_string out "{\"kind\":\"answered\"}\n");
        check_reply
          "a row the server does not understand"
          (500, {|{"error":"The record of this conversation has a row the server does not understand."}|})
          (reply alice (body ~keeper:"keeper-alice-second" ~message:"hello"));
        Alcotest.(check string)
          "the record keeps the row and gets no other"
          (before ^ "{\"kind\":\"answered\"}\n")
          (In_channel.with_open_bin second_turns In_channel.input_all);
        check_reply
          "the read of a record with such a row"
          (500, {|{"error":"The record of this conversation has a row the server does not understand."}|})
          (read alice [ "keeper_id", "keeper-alice-second" ]);
        Alcotest.(check bool) "no client started for either" false (Sys.file_exists (claude ^ ".turn.json"));
        (* Bob's Keeper answers on his home, not hers. *)
        let (_ : string) =
          answered
            "his Keeper answers"
            ~keeper:"keeper-bob"
            ~runtime:bob_runtime
            ~text:"echo: hi"
            ~continued:false
            (reply bob (body ~keeper:"keeper-bob" ~message:"hi"))
        in
        Alcotest.(check string) "on the home of his account" (home_of ~base_path bob) (text_of (seen claude) "home");
        (* Her turns above ran her Keeper of that name on her home. His Keeper
           of the same name runs on his Runtime and his home. *)
        (* Her Keeper of that name has a conversation. His is another: its
           first turn starts a session of its own, in a directory under his
           namespace, and her record does not get its rows. *)
        let her_rows = List.length (rows alice_turns) in
        let his_conversation =
          answered
            "his Keeper of her Keeper's name answers"
            ~keeper:"keeper-alice"
            ~runtime:bob_runtime
            ~text:"echo: his"
            ~continued:false
            (reply bob (body ~keeper:"keeper-alice" ~message:"his"))
        in
        let his = seen claude in
        Alcotest.(check (option string))
          "his turn resumes no session"
          None
          (resumed_session (args_of his));
        Alcotest.(check bool)
          "his session is not hers"
          false
          (Option.equal String.equal (new_session (args_of his)) (Some session));
        Alcotest.(check string)
          "in a directory under his namespace"
          (List.fold_left Filename.concat (records_of ~base_path bob) [ his_conversation; "cwd" ])
          (text_of his "cwd");
        Alcotest.(check int) "her record gets no row of his turn" her_rows (List.length (rows alice_turns));
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
