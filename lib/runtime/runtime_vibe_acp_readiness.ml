type auth_state =
  | Signed_out
  | Auth_not_required
  | Os_keyring
  | Vibe_home_env_file
  | Process_env
  | Unsupported_provider
  | Unrecognized_auth_state of string

type auth_status =
  { authenticated : bool
  ; auth_state : auth_state
  }

type account_status =
  | Ready
  | Missing_key
  | Unauthorized
  | Unavailable
  | Unrecognized_account_status of string

type plan_kind =
  | Api
  | Chat
  | Mistral_code
  | Unrecognized_plan_kind of string

type key_scope =
  | Workspace
  | Vibe
  | Codestral
  | Unrecognized_key_scope of string

type budget =
  { usage_percentage : float
  ; reset_at : string option
  ; payg_enabled : bool
  }

type account =
  { status : account_status
  ; plan_kind : plan_kind option
  ; key_scope : key_scope option
  ; budget : budget option
  }

type readiness =
  | Not_signed_in of auth_state
  | Signed_in of
      { auth_state : auth_state
      ; account : account
      }

type not_ready =
  | Not_authenticated of auth_state
  | Credential_not_keyring of auth_state
  | Account_not_ready of account_status
  | Key_not_vibe_scope of key_scope option
  | Budget_used_up of budget

type budget_knowledge =
  | Known of budget
  | Unknown

type error =
  | Workdir_not_absolute of string
  | Invalid_timeout of float
  | Spawn_failed of string
  | Timed_out of { after_s : float }
  | Rpc_error of
      { meth : string
      ; code : int option
      ; message : string
      }
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Process_exited of { stderr_tail : string }

(* ACP protocol version this client speaks; vibe-acp 3.1.0 answered it. *)
let protocol_version = 1

(* Vibe's AccountBudgetView: usage past 100% "is billed instead of paused"
   when pay-as-you-go is on. *)
let budget_full_percentage = 100.0
let exit_grace_s = 5.0
let max_line_bytes = 1_048_576
let stderr_tail_bytes = 8192
let stderr_read_chunk_bytes = 4096

let auth_state_of_string = function
  | "signed_out" -> Signed_out
  | "auth_not_required" -> Auth_not_required
  | "os_keyring" -> Os_keyring
  | "vibe_home_env_file" -> Vibe_home_env_file
  | "process_env" -> Process_env
  | "unsupported_provider" -> Unsupported_provider
  | other -> Unrecognized_auth_state other
;;

let auth_state_to_string = function
  | Signed_out -> "signed_out"
  | Auth_not_required -> "auth_not_required"
  | Os_keyring -> "os_keyring"
  | Vibe_home_env_file -> "vibe_home_env_file"
  | Process_env -> "process_env"
  | Unsupported_provider -> "unsupported_provider"
  | Unrecognized_auth_state other -> other
;;

let account_status_of_string = function
  | "ready" -> Ready
  | "missing_key" -> Missing_key
  | "unauthorized" -> Unauthorized
  | "unavailable" -> Unavailable
  | other -> Unrecognized_account_status other
;;

let account_status_to_string = function
  | Ready -> "ready"
  | Missing_key -> "missing_key"
  | Unauthorized -> "unauthorized"
  | Unavailable -> "unavailable"
  | Unrecognized_account_status other -> other
;;

let plan_kind_of_string = function
  | "api" -> Api
  | "chat" -> Chat
  | "mistral_code" -> Mistral_code
  | other -> Unrecognized_plan_kind other
;;

let key_scope_of_string = function
  | "workspace" -> Workspace
  | "vibe" -> Vibe
  | "codestral" -> Codestral
  | other -> Unrecognized_key_scope other
;;

let key_scope_to_string = function
  | Some Workspace -> "workspace"
  | Some Vibe -> "vibe"
  | Some Codestral -> "codestral"
  | Some (Unrecognized_key_scope other) -> other
  | None -> "none"
;;

(* HIGH-RISK-UNREVIEWED: decides which stored credential a lane call may
   spend; needs a human review before a Keeper is assigned to the lane. *)
let verdict = function
  | Not_signed_in auth_state -> Error [ Not_authenticated auth_state ]
  | Signed_in { auth_state; account } ->
    let reasons =
      List.concat
        [ (match auth_state with
           | Os_keyring -> []
           | ( Signed_out
             | Auth_not_required
             | Vibe_home_env_file
             | Process_env
             | Unsupported_provider
             | Unrecognized_auth_state _ ) as state -> [ Credential_not_keyring state ])
        ; (match account.status with
           | Ready -> []
           | (Missing_key | Unauthorized | Unavailable | Unrecognized_account_status _) as
             status -> [ Account_not_ready status ])
        ; (match account.key_scope with
           | Some Vibe -> []
           | (Some (Workspace | Codestral | Unrecognized_key_scope _) | None) as scope ->
             [ Key_not_vibe_scope scope ])
        ; (* Written as "not below" so a NaN refuses instead of passing. *)
          (match account.budget with
           | Some budget when not (budget.usage_percentage < budget_full_percentage) ->
             [ Budget_used_up budget ]
           | Some _ | None -> [])
        ]
    in
    (match reasons, account.budget with
     | [], Some budget -> Ok (Known budget)
     | [], None -> Ok Unknown
     | _ :: _, (Some _ | None) -> Error reasons)
;;

let not_ready_to_string = function
  | Not_authenticated state -> "Vibe is not signed in: " ^ auth_state_to_string state
  | Credential_not_keyring state ->
    "Vibe's credential state is "
    ^ auth_state_to_string state
    ^ "; the lane takes the os_keyring credential only"
  | Account_not_ready status -> "Vibe account is " ^ account_status_to_string status
  | Key_not_vibe_scope scope -> "Vibe key scope is " ^ key_scope_to_string scope
  | Budget_used_up budget ->
    Printf.sprintf
      "Vibe Code allowance is %.2f%% used (pay-as-you-go %s)"
      budget.usage_percentage
      (if budget.payg_enabled then "on: further calls are billed" else "off: calls stop")
;;

let error_to_string = function
  | Workdir_not_absolute workdir -> Printf.sprintf "workdir %S is not absolute" workdir
  | Invalid_timeout timeout_s ->
    Printf.sprintf "timeout_s %g is not a positive finite number" timeout_s
  | Spawn_failed detail -> "vibe-acp did not start: " ^ detail
  | Timed_out { after_s } -> Printf.sprintf "vibe-acp did not answer within %gs" after_s
  | Rpc_error { meth; code = Some code; message } ->
    Printf.sprintf "vibe-acp refused %s (%d): %s" meth code message
  | Rpc_error { meth; code = None; message } ->
    Printf.sprintf "vibe-acp refused %s: %s" meth message
  | Protocol_error { stage; detail } -> Printf.sprintf "vibe-acp %s: %s" stage detail
  | Process_exited { stderr_tail } -> "vibe-acp exited before answering: " ^ stderr_tail
;;

let ( let* ) = Result.bind

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let fail stage detail = Error (Protocol_error { stage; detail })

let required_string ~stage name json =
  match field name json with
  | Some (`String value) -> Ok value
  | Some _ -> fail stage (name ^ " is not a string")
  | None -> fail stage (name ^ " is missing")
;;

let required_bool ~stage name json =
  match field name json with
  | Some (`Bool value) -> Ok value
  | Some _ -> fail stage (name ^ " is not a boolean")
  | None -> fail stage (name ^ " is missing")
;;

let required_number ~stage name json =
  match field name json with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> fail stage (name ^ " is not a number")
  | None -> fail stage (name ^ " is missing")
;;

let nullable_string ~stage name json =
  match field name json with
  | Some (`String value) -> Ok (Some value)
  | Some `Null | None -> Ok None
  | Some _ -> fail stage (name ^ " is not a string")
;;

(* An absent or null object is Vibe saying it has none (its model fields
   default to None); any other JSON type is an error. *)
let nullable_object ~stage name json decode =
  match field name json with
  | Some (`Assoc _ as value) ->
    let* decoded = decode value in
    Ok (Some decoded)
  | Some `Null | None -> Ok None
  | Some _ -> fail stage (name ^ " is not an object")
;;

let decode_auth_status json =
  let stage = "_auth/status" in
  let* authenticated = required_bool ~stage "authenticated" json in
  let* auth_state = required_string ~stage "authState" json in
  Ok { authenticated; auth_state = auth_state_of_string auth_state }
;;

let decode_budget json =
  let stage = "_account/read budget" in
  let* usage_percentage = required_number ~stage "usagePercentage" json in
  let* reset_at = nullable_string ~stage "resetAt" json in
  let* payg_enabled = required_bool ~stage "paygEnabled" json in
  Ok { usage_percentage; reset_at; payg_enabled }
;;

let decode_account json =
  let stage = "_account/read" in
  let* status = required_string ~stage "status" json in
  let* plan_kind =
    nullable_object ~stage "plan" json (fun plan ->
      let* kind = required_string ~stage:"_account/read plan" "kind" plan in
      Ok (plan_kind_of_string kind))
  in
  let* key_scope =
    nullable_object ~stage "apiKey" json (fun key ->
      let* scope = required_string ~stage:"_account/read apiKey" "scope" key in
      Ok (key_scope_of_string scope))
  in
  let* budget = nullable_object ~stage "budget" json decode_budget in
  Ok { status = account_status_of_string status; plan_kind; key_scope; budget }
;;

(* The end of the child's stderr, kept while it runs. A read error ends the
   drain like EOF does: the tail is a diagnostic, not part of the answer. *)
let drain_stderr flow buffer =
  let chunk = Cstruct.create stderr_read_chunk_bytes in
  let rec loop () =
    match Eio.Flow.single_read flow chunk with
    | read ->
      Buffer.add_string buffer (Cstruct.to_string ~len:read chunk);
      if Buffer.length buffer > 2 * stderr_tail_bytes
      then (
        let kept = Buffer.sub buffer (Buffer.length buffer - stderr_tail_bytes) stderr_tail_bytes in
        Buffer.clear buffer;
        Buffer.add_string buffer kept);
      loop ()
    | exception End_of_file -> ()
    | exception Eio.Io (_, _) -> ()
  in
  loop ()
;;

let stderr_tail buffer =
  String_util.utf8_suffix
    ~max_bytes:stderr_tail_bytes
    (Secret_patterns.redact_text (String.trim (Buffer.contents buffer)))
;;

let request id meth params =
  Yojson.Safe.to_string
    (`Assoc
        [ "jsonrpc", `String "2.0"; "id", `Int id; "method", `String meth; "params", params ])
  ^ "\n"
;;

(* How one step of the exchange failed. [Child_gone] becomes
   [Process_exited] only after the child is reaped, so its stderr tail is
   read once the child has stopped writing it. *)
type step_failure =
  | Child_gone
  | Failed of error

let protocol stage detail = Error (Failed (Protocol_error { stage; detail }))
let decoded result = Result.map_error (fun error -> Failed error) result

(* One response: skip notifications, refuse a request from the agent (none is
   expected before a prompt) or an answer to another id. *)
let rec await_response reader ~id ~meth =
  match Eio.Buf_read.line reader with
  | exception End_of_file -> Error Child_gone
  | exception Eio.Io (_, _) -> Error Child_gone
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
    protocol meth (Printf.sprintf "a line is longer than %d bytes" max_line_bytes)
  | line ->
    (match Yojson.Safe.from_string line with
     | exception Yojson.Json_error detail -> protocol meth ("unreadable line: " ^ detail)
     | message ->
       (match field "id" message, field "method" message with
        | None, Some _ -> await_response reader ~id ~meth
        | Some _, Some (`String request) ->
          protocol meth ("unexpected agent request " ^ request)
        | Some (`Int answered), None when answered = id ->
          (match field "error" message, field "result" message with
           | Some error, _ ->
             let code =
               match field "code" error with
               | Some (`Int code) -> Some code
               | Some _ | None -> None
             in
             let text =
               match field "message" error with
               | Some (`String text) -> text
               | Some _ | None -> Yojson.Safe.to_string error
             in
             Error
               (Failed (Rpc_error { meth; code; message = Secret_patterns.redact_text text }))
           | None, Some result -> Ok result
           | None, None -> protocol meth "response has neither result nor error")
        | Some other, _ -> protocol meth ("answer to another id " ^ Yojson.Safe.to_string other)
        | None, None -> protocol meth "message has neither id nor method"))
;;

(* A signed-out Vibe refuses [session/new], so the exchange stops after
   [_auth/status] when it says [authenticated=false]. *)
let exchange ~stdin ~reader ~workdir =
  let call id meth params =
    match Eio.Flow.copy_string (request id meth params) stdin with
    | () -> await_response reader ~id ~meth
    | exception Eio.Io (_, _) -> Error Child_gone
  in
  let* _ =
    call
      1
      "initialize"
      (`Assoc [ "protocolVersion", `Int protocol_version; "clientCapabilities", `Assoc [] ])
  in
  let* auth =
    Result.bind (call 2 "_auth/status" (`Assoc [])) (fun json ->
      decoded (decode_auth_status json))
  in
  if not auth.authenticated
  then Ok (Not_signed_in auth.auth_state)
  else
    let* session =
      call 3 "session/new" (`Assoc [ "cwd", `String workdir; "mcpServers", `List [] ])
    in
    let* session_id = decoded (required_string ~stage:"session/new" "sessionId" session) in
    let* account =
      Result.bind
        (call 4 "_account/read" (`Assoc [ "sessionId", `String session_id ]))
        (fun json -> decoded (decode_account json))
    in
    Ok (Signed_in { auth_state = auth.auth_state; account })
;;

let close_stdin stdin =
  try Eio.Flow.close stdin with
  | Eio.Io (_, _) -> ()
;;

let kill proc =
  Eio.Process.signal proc Sys.sigkill;
  ignore (Eio.Process.await proc : Eio.Process.exit_status)
;;

(* Closing stdin ends vibe-acp (it exited 0 on EOF in every measured run);
   one that does not exit within the grace is killed. *)
let stop ~clock proc stdin =
  close_stdin stdin;
  match Eio.Time.with_timeout clock exit_grace_s (fun () -> Ok (Eio.Process.await proc)) with
  | Ok _ -> ()
  | Error `Timeout -> kill proc
;;

let valid_timeout timeout_s = Float.is_finite timeout_s && timeout_s > 0.0

let spawn ~sw ~mgr ~cwd ~cli_path =
  let stdin_r, stdin_w = Eio.Process.pipe ~sw mgr in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw mgr in
  let proc =
    Eio.Process.spawn
      ~sw
      mgr
      ~cwd
      ~env:(Runtime_vibe_cli.child_environment (Unix.environment ()))
      ~stdin:stdin_r
      ~stdout:stdout_w
      ~stderr:stderr_w
      [ cli_path ]
  in
  Eio.Flow.close stdin_r;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  proc, stdin_w, stdout_r, stderr_r
;;

let read ~host:(_ : Runtime_account_access.host_account) ~mgr ~clock ~fs ~workdir ~cli_path
    ~timeout_s () =
  if Filename.is_relative workdir
  then Error (Workdir_not_absolute workdir)
  else if not (valid_timeout timeout_s)
  then Error (Invalid_timeout timeout_s)
  else
    Eio.Switch.run
    @@ fun sw ->
    match spawn ~sw ~mgr ~cwd:Eio.Path.(fs / workdir) ~cli_path with
    (* Eio raises [Eio.Io] for a missing executable or a pipe it could not
       make, [Unix_error] for a fork failure, and [Failure] with the child's
       own report for a setup step (fchdir, dup2, execve) that failed after
       the fork. *)
    | exception ((Eio.Io _ | Unix.Unix_error _ | Failure _) as exn) ->
      Error (Spawn_failed (Printexc.to_string exn))
    | proc, stdin, stdout, stderr_flow ->
      let stderr = Buffer.create stderr_read_chunk_bytes in
      let stderr_drained, drained = Eio.Promise.create () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        drain_stderr stderr_flow stderr;
        Eio.Promise.resolve drained ();
        `Stop_daemon);
      let reader = Eio.Buf_read.of_flow ~max_size:max_line_bytes stdout in
      let outcome =
        Eio.Time.with_timeout clock timeout_s (fun () ->
          Ok (exchange ~stdin ~reader ~workdir))
      in
      (match outcome with
       | Ok _ -> stop ~clock proc stdin
       | Error `Timeout ->
         close_stdin stdin;
         kill proc);
      (match outcome with
       | Ok (Ok readiness) -> Ok readiness
       | Ok (Error (Failed error)) -> Error error
       | Ok (Error Child_gone) ->
         (match
            Eio.Time.with_timeout clock exit_grace_s (fun () ->
              Ok (Eio.Promise.await stderr_drained))
          with
          | Ok () | Error `Timeout -> ());
         Error (Process_exited { stderr_tail = stderr_tail stderr })
       | Error `Timeout -> Error (Timed_out { after_s = timeout_s }))
;;
