(** See keeper_identity_tools.mli. *)

module Provider = Keeper_oauth_provider

type catalog = {
  provider_id : string;
  provider_label : string;
  discovered_at : float;
  tools : Mcp_client.tool list;
}

let ( let* ) = Result.bind

type transports = {
  mcp_post : Mcp_client.post;
  token_post : Keeper_oauth_flow.post;
  discover : mcp_url:string -> (Keeper_oauth_discovery.t, Keeper_oauth_discovery.error) result;
}

(* The production transports, every request bounded on [clock]. Each
   request of the MCP session runs under the keeper's no-progress threshold
   ([Keeper_runtime_resolved.provider_call_deadline_sec]): a tools/call is
   work the model is waiting on, and the attempt watchdog does not watch a
   tool in flight, so this deadline is the only liveness the call has. The
   bound is per request, not per call: a server that answers nothing ends
   the call one threshold after its last completed request, and one that
   answers each request inside the threshold runs the call to its end. The
   OAuth hops a renewal makes -- discovery and the token endpoint -- are
   short JSON round trips of the same class as the Slack and Discord REST
   calls, and run under the shared request timeout those use. *)
let http_transports ~clock =
  let rest_timeout_sec = Masc_http_client.default_request_timeout_sec in
  { mcp_post =
      Mcp_client.http_post
        ~clock
        ~deadline_s:(Keeper_runtime_resolved.provider_call_deadline_sec ());
    token_post = Keeper_oauth_flow.http_post ~clock ~timeout_sec:rest_timeout_sec;
    discover =
      (fun ~mcp_url ->
        Keeper_oauth_discovery.discover
          ~get:(Keeper_oauth_discovery.http_get ~clock ~timeout_sec:rest_timeout_sec)
          ~ask:(Keeper_oauth_discovery.http_ask ~clock ~timeout_sec:rest_timeout_sec)
          ~mcp_url ());
  }

let catalog_path ~base_path ~keeper_name ~provider_id =
  let identity_dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity"
  in
  Filename.concat
    (Filename.concat
       (Filename.concat identity_dir "catalogs")
       (Workspace_utils.safe_filename keeper_name))
    (provider_id ^ ".json")
;;

(* Which Keepers have a catalog for this provider.

   Read off the catalogs directory rather than the roster, because a catalog
   is what "attached" means here: a Keeper with a name and no catalog has
   nothing to report, and one whose name left the roster still has whatever
   it was given. The names are the directories masc wrote, which is the
   keeper name put through [Workspace_utils.safe_filename]. *)
let keepers_with ~base_path ~provider_id ~excluding =
  let root =
    Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity")
      "catalogs"
  in
  match Sys.readdir root with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter (fun keeper ->
         (not (String.equal keeper (Workspace_utils.safe_filename excluding)))
         && Sys.file_exists
              (Filename.concat
                 (Filename.concat root keeper)
                 (provider_id ^ ".json")))
    |> List.sort String.compare
;;

let tool_to_json (tool : Mcp_client.tool) =
  `Assoc
    ([ "name", `String tool.Mcp_client.name
     ; "description", `String tool.Mcp_client.description
     ; "input_schema", tool.Mcp_client.input_schema
     ]
     @
     (* Written only when the server said something. An absent key and a
        [false] are different facts and the approval policy treats them the
        same way for now, but flattening them here would lose the
        difference for good. *)
     match tool.Mcp_client.read_only with
     | Some value -> [ "read_only", `Bool value ]
     | None -> [])
;;

let tool_of_json json =
  let member key =
    match json with
    | `Assoc pairs -> List.assoc_opt key pairs
    | _ -> None
  in
  match member "name", member "description", member "input_schema" with
  | Some (`String name), Some (`String description), Some input_schema ->
    let read_only =
      match member "read_only" with
      | Some (`Bool value) -> Some value
      | Some _ | None -> None
    in
    Some { Mcp_client.name; description; input_schema; read_only }
  | _ -> None
;;

let catalog_to_json catalog =
  `Assoc
    [ "provider_id", `String catalog.provider_id
    ; "provider_label", `String catalog.provider_label
    ; "discovered_at", `Float catalog.discovered_at
    ; "tools", `List (List.map tool_to_json catalog.tools)
    ]
;;

let catalog_of_json json =
  let member key =
    match json with
    | `Assoc pairs -> List.assoc_opt key pairs
    | _ -> None
  in
  match member "provider_id", member "provider_label", member "tools" with
  | Some (`String provider_id), Some (`String provider_label), Some (`List rows) ->
    let discovered_at =
      match member "discovered_at" with
      | Some (`Float value) -> value
      | Some (`Int value) -> float_of_int value
      | Some _ | None -> 0.0
    in
    (* A row this build cannot read is a written catalog disagreeing with the
       code that reads it, which is worth saying rather than quietly
       offering a shorter list. *)
    let tools = List.map tool_of_json rows in
    if List.exists Option.is_none tools
    then Error "the written catalog carries a tool this build cannot read"
    else Ok { provider_id; provider_label; discovered_at; tools = List.filter_map Fun.id tools }
  | _ -> Error "the written catalog is missing provider_id, provider_label or tools"
;;

let load ~base_path ~keeper_name ~provider_id =
  let path = catalog_path ~base_path ~keeper_name ~provider_id in
  match In_channel.with_open_bin path In_channel.input_all with
  | contents ->
    (match Yojson.Safe.from_string contents with
     | json -> Result.map Option.some (catalog_of_json json)
     | exception Yojson.Json_error detail -> Error detail)
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok None
  | exception Sys_error message -> Error message
;;

let rec ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
     || Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then ensure_dir parent;
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let save ~base_path ~keeper_name catalog =
  let path =
    catalog_path ~base_path ~keeper_name ~provider_id:catalog.provider_id
  in
  let temp = path ^ ".tmp" in
  try
    ensure_dir (Filename.dirname path);
    Out_channel.with_open_bin temp (fun oc ->
      Out_channel.output_string oc (Yojson.Safe.to_string (catalog_to_json catalog)));
    Unix.rename temp path;
    Ok ()
  with
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s: %s %s" (Unix.error_message err) fn arg)
  | Sys_error message -> Error message
;;

(* The Keeper's own projection, which is the same array its runtime would be
   handed. A variable of this name in masc's own environment cannot reach it:
   [Env_keeper_scrub] inherits an exact closed set of process keys and a
   provider credential is not in it. That is where the guarantee lives, not
   here -- an earlier version of this passed an empty host env and claimed
   the credit, and removing that changed nothing. *)
let projected_env_value ~base_path ~keeper_name ~name =
  let* env =
    Keeper_secret_projection.local_env_for_keeper ~base_path
      ~keeper_name ()
  in
  match env with
  | None -> Error "this keeper has no secret projection"
  | Some entries ->
    let prefix = name ^ "=" in
    let found =
      Array.to_list entries
      |> List.find_map (fun entry ->
           if String.length entry >= String.length prefix
              && String.equal (String.sub entry 0 (String.length prefix)) prefix
           then
             Some
               (String.sub entry (String.length prefix)
                  (String.length entry - String.length prefix))
           else None)
    in
    (match found with
     | Some value when String.trim value <> "" -> Ok value
     | Some _ | None ->
       Error
         (Printf.sprintf "this keeper has no %s; attach it to the provider first"
            name))
;;

(* One place decides where a provider's bearer comes from. The two call paths
   below -- cataloguing tools and running one -- would otherwise each carry
   the decision, and the day a third source appears they drift. *)
let access_token_for ~base_path ~keeper_name ~(provider : Provider.t) =
  match provider.Provider.credential_source with
  | Provider.Oauth_exchange ->
    projected_env_value ~base_path ~keeper_name
      ~name:provider.Provider.access_token_env
  | Provider.Github_cli { hostname } ->
    Keeper_github_identity.stored_token ~base_path ~keeper_name ~hostname
;;

let refresh ~mcp_post ~base_path ~keeper_name ~(provider : Provider.t) ~now () =
  let* access_token = access_token_for ~base_path ~keeper_name ~provider in
  let* client =
    Result.map_error Mcp_client.error_to_string
      (Mcp_client.connect ~post:mcp_post ~url:provider.Provider.mcp_url ~access_token ())
  in
  let* tools =
    Result.map_error Mcp_client.error_to_string (Mcp_client.list_tools ~post:mcp_post client)
  in
  let catalog =
    { provider_id = provider.Provider.id
    ; provider_label = provider.Provider.label
    ; discovered_at = now
    ; tools
    }
  in
  let* () = save ~base_path ~keeper_name catalog in
  Ok catalog
;;

(* -32601 read through the typed sum rather than the bare integer.  The code
   proves only that the server rejected a method/name; it does not by itself
   prove that the requested tool disappeared.  A fresh catalog supplies that
   second fact below. *)
let is_method_not_found_error = function
  | Mcp_client.Rpc { code; _ } ->
    (match Mcp_error_code.of_wire_code code with
     | Some Mcp_error_code.Method_not_found -> true
     | Some _ | None -> false)
  | _ -> false
;;

(* What changed between the catalog a turn was assembled from and what the
   service just listed. By name: a description edit is not drift. *)
let drift_of ~previous ~fresh =
  let names tools =
    List.map (fun (tool : Mcp_client.tool) -> tool.Mcp_client.name) tools
  in
  let previous_names = names previous and fresh_names = names fresh in
  let lost =
    List.filter (fun name -> not (List.mem name fresh_names)) previous_names
  in
  let gained =
    List.filter (fun name -> not (List.mem name previous_names)) fresh_names
  in
  (lost, gained)
;;

let catalog_contains tools name =
  List.exists
    (fun (tool : Mcp_client.tool) -> String.equal tool.Mcp_client.name name)
    tools
;;

type offered_tool = {
  schema : Agent_core.Types.tool_schema;
  read_only : bool option;
  provider : Provider.t;
  remote_name : string;
}

type offering = {
  offered : offered_tool list;
  unusable : (string * string) list;
}

let model_tool_name ~(provider : Provider.t) ~remote_name =
  Printf.sprintf "%s_%s" provider.Provider.id remote_name
;;

type call_phase =
  | Session_open
  | Tool_call

type call_error =
  | Precondition of string
  | Transient_precondition of string
      (* A precondition that failed for a reason a later attempt may clear --
         a network blip while renewing, a 5xx/429 from the token endpoint. Kept
         apart from [Precondition] so the model is told it can retry rather than
         that the call is permanently impossible. *)
  | Mcp of {
      phase : call_phase;
      error : Mcp_client.error;
    }

let failed ~recoverable ~error_class message =
  Error { Agent_core.Types.message; recoverable; error_class }
;;

(* JSON-RPC error codes the server sends before it runs any tool: the
   request never became a tool execution, so no effect happened. Every other
   post-send failure keeps the honest answer, which is "unknown". Decided
   over the typed code sum, not bare literals: the same numbers written out
   here were the exact "magic number repetition" the [Mcp_error_code.t] sum
   was introduced to close. *)
let rpc_rejects_before_execution code =
  match Mcp_error_code.of_wire_code code with
  | Some
      ( Mcp_error_code.Invalid_request | Mcp_error_code.Method_not_found
      | Mcp_error_code.Invalid_params ) -> true
  | Some _ | None -> false
;;

type call_proof =
  | Effect_never_began
  | Outcome_unknown

let call_proof_of_call_error : call_error -> call_proof = function
  | Precondition _ | Transient_precondition _ -> Effect_never_began
  (* A session that never came up carries proof the call was not sent. *)
  | Mcp { phase = Session_open; _ } -> Effect_never_began
  (* The server refused the token; auth precedes the tool run. *)
  | Mcp { phase = Tool_call; error = Mcp_client.Unauthorized _ } -> Effect_never_began
  | Mcp { phase = Tool_call; error = Mcp_client.Rpc { code; _ } }
    when rpc_rejects_before_execution code -> Effect_never_began
  (* Once the tools/call was handed to the transport, no other failure
     proves anything: a transport error here may be the connection step of
     the tools/call itself, and an HTTP status, any other JSON-RPC code, or
     an answer that does not parse all follow a request the service may
     have applied. *)
  | Mcp
      { phase = Tool_call
      ; error =
          Mcp_client.Rpc _ | Mcp_client.Http _ | Mcp_client.Malformed _
          | Mcp_client.Transport _
      } -> Outcome_unknown
;;

let effect_disposition_of_call_error call_error =
  match call_proof_of_call_error call_error with
  | Effect_never_began -> Tool_result.Proven_pre_effect
  | Outcome_unknown -> Tool_result.Effect_outcome_unknown
;;

let call_error_to_string = function
  | Precondition message | Transient_precondition message -> message
  | Mcp { error; _ } -> Mcp_client.error_to_string error
;;

let tool_result_of_call ~read_only answer =
  match answer with
  | Ok (result : Mcp_client.tool_result) ->
    if result.Mcp_client.is_error
    then
      (* The tool ran and said no. The model can try other arguments, and
         nothing about that is this process's failure. *)
      failed ~recoverable:true ~error_class:(Some Agent_core.Types.Unknown)
        result.Mcp_client.text
    else Ok { Agent_core.Types.content = result.Mcp_client.text; content_blocks = None; _meta = None }
  | Error (Precondition message) ->
    failed ~recoverable:false ~error_class:(Some Agent_core.Types.Deterministic)
      message
  | Error (Transient_precondition message) ->
    failed ~recoverable:true ~error_class:(Some Agent_core.Types.Transient) message
  | Error (Mcp { error = Mcp_client.Unauthorized _; _ }) ->
    (* Not something the model can fix by trying again. Whoever attached
       this Keeper has to attach it again. *)
    failed ~recoverable:false ~error_class:(Some Agent_core.Types.Deterministic)
      "this keeper's credential for that service is no longer accepted; attach \
       it again"
  | Error (Mcp { error; _ } as call_error) ->
    let detail = Mcp_client.error_to_string error in
    let error_class =
      match error with
      | Mcp_client.Transport _ -> Agent_core.Types.Transient
      | Mcp_client.Rpc _ | Mcp_client.Http _ | Mcp_client.Malformed _
      | Mcp_client.Unauthorized _ -> Agent_core.Types.Deterministic
    in
    (* "Recoverable" tells the model a second call is safe. It is safe when
       the provider said the tool only reads (its explicit word, as at the
       gate: silence is not that), or when the failure proves the effect
       never began; the proof is the same fact replay reads. A write the
       transport took and did not answer for may have applied, and a model
       told to retry it would apply it twice. *)
    (match read_only, call_proof_of_call_error call_error with
     | Some true, _ | (Some false | None), Effect_never_began ->
       failed ~recoverable:true ~error_class:(Some error_class) detail
     | (Some false | None), Outcome_unknown ->
       failed
         ~recoverable:false
         ~error_class:(Some Agent_core.Types.Unknown)
         (Printf.sprintf
            "%s; the request may have reached the service, so whether it applied \
             is unknown: read the service's state before sending it again"
            detail))
;;

let store_tokens ~base_path ~keeper_name ~(provider : Provider.t)
      (tokens : Keeper_oauth_flow.tokens) =
  let set_env ~name ~value =
    Keeper_secret_projection.set_env_entry ~base_path ~keeper_name
      ~scope:Keeper_secret_projection.Keeper_secret ~name ~value
  in
  (* The refresh token first, and only when the provider rotated it. A
     provider that returns none kept the one already on disk, and writing
     nothing is what keeps it. *)
  let* () =
    match tokens.Keeper_oauth_flow.refresh_token with
    | None -> Ok ()
    | Some refresh_token ->
      Keeper_secret_projection.set_file_entry ~base_path ~keeper_name
        ~scope:Keeper_secret_projection.Keeper_secret
        ~container_path:provider.Provider.refresh_token_file ~value:refresh_token
  in
  let* () =
    set_env ~name:provider.Provider.access_token_env
      ~value:tokens.Keeper_oauth_flow.access_token
  in
  (* A renewal that names no new expiry has not told us this credential is
     younger than the one it replaced. Keeping the old moment would put the
     renewal check against a clock that already ran out and send it back
     every turn; empty says the moment is unknown, which is what stops it. *)
  set_env ~name:provider.Provider.expires_at_env
    ~value:
      (match tokens.Keeper_oauth_flow.expires_at with
       | None -> ""
       | Some expires_at -> Printf.sprintf "%.0f" expires_at)
;;

let stored_expires_at ~base_path ~keeper_name ~(provider : Provider.t) =
  match
    projected_env_value ~base_path ~keeper_name
      ~name:provider.Provider.expires_at_env
  with
  | Error _ -> None
  | Ok value -> float_of_string_opt (String.trim value)
;;

(* Exchange the refresh token for a new access token when the stored one is
   inside its declared window. Done where the token is read rather than on a
   timer: the only moment it matters is the moment before it is used, and a
   Keeper nobody is running does not need a fresh credential. *)
(* [token_post] is the OAuth token endpoint's contract, which is not the MCP
   one: a status and a body rather than a response with headers. Two wire
   contracts, two injection points, so a test can pin either without
   pretending they are the same. *)
(* A renewal that fails does not always fail the same way. A network blip or a
   5xx/429 from the token endpoint is worth retrying; a revoked refresh token or
   a missing client is not. Kept apart so the caller can tell the model which
   it is instead of reporting every renewal failure as permanent. *)
type renewal_error =
  | Renew_transient of string
  | Renew_permanent of string

let renewal_error_message = function
  | Renew_transient message | Renew_permanent message -> message
;;

(* Spend the refresh token now, whatever the stored expiry says. Two callers:
   [renew_if_needed] when the declared window has opened, and the reactive path
   in [run_call] when the endpoint answered 401 -- the only renewal a provider
   that issued no expiry ever gets. *)
let force_refresh ~token_post ~discover ~base_path ~keeper_name
      ~(provider : Provider.t) ~now () =
  let* refresh_token =
    match
      Keeper_secret_projection.read_file_entry ~base_path ~keeper_name
        ~scope:Keeper_secret_projection.Keeper_secret
        ~container_path:provider.Provider.refresh_token_file
    with
    | Error message -> Error (Renew_permanent message)
    | Ok None ->
      Error
        (Renew_permanent
           "this keeper has no refresh token; attach it to the provider again")
    | Ok (Some value) when String.trim value <> "" -> Ok (String.trim value)
    | Ok (Some _) -> Error (Renew_permanent "this keeper's refresh token file is empty")
  in
  let* discovered =
    match discover ~mcp_url:provider.Provider.mcp_url with
    | Ok discovered -> Ok discovered
    (* Could not reach the discovery hop -- the auth server may answer a moment
       later. *)
    | Error (Keeper_oauth_discovery.Transport _ as err) ->
      Error (Renew_transient (Keeper_oauth_discovery.error_to_string err))
    | Error err -> Error (Renew_permanent (Keeper_oauth_discovery.error_to_string err))
  in
  let* configured_client_id =
    match
      Keeper_oauth_client_store.load
        ~dir:(Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity")
        ~provider
    with
    | Error message -> Error (Renew_permanent message)
    (* A lapsed secret cannot be redeemed, and sending it anyway returns the
       authorization server's own wording for an id it has forgotten --
       which says nothing about what to do. Answer with the sentence that
       does: a fresh login registers a new client. *)
    | Ok (Some credentials)
      when Keeper_oauth_client_store.secret_expired credentials ~now ->
      Error
        (Renew_permanent
           "this install's registered client has expired; attach a keeper to \
            the provider again to register a new one")
    | Ok (Some credentials) -> Ok credentials
    | Ok None ->
      Error (Renew_permanent "this install has no registered client; attach a keeper first")
  in
  let* tokens =
    match
      Keeper_oauth_flow.refresh ~post:token_post ~discovered
        ~client_id:configured_client_id.Keeper_oauth_client_store.client_id
        ?client_secret:configured_client_id.Keeper_oauth_client_store.client_secret
        ~refresh_token ~now ()
    with
    | Ok tokens -> Ok tokens
    | Error (Keeper_oauth_flow.Transport _ as err) ->
      Error (Renew_transient (Keeper_oauth_flow.exchange_error_to_string err))
    (* The token endpoint was reachable but answered a server-side or
       rate-limit status; the refresh itself is not refused. *)
    | Error (Keeper_oauth_flow.Provider_rejected { status; _ } as err)
      when status = 429 || status >= 500 ->
      Error (Renew_transient (Keeper_oauth_flow.exchange_error_to_string err))
    | Error err -> Error (Renew_permanent (Keeper_oauth_flow.exchange_error_to_string err))
  in
  let* () =
    match store_tokens ~base_path ~keeper_name ~provider tokens with
    | Ok () -> Ok ()
    | Error message -> Error (Renew_permanent message)
  in
  Ok tokens.Keeper_oauth_flow.access_token
;;

let renew_if_needed ~token_post ~discover ~base_path ~keeper_name
      ~(provider : Provider.t) ~now ~access_token () =
  match provider.Provider.credential_source with
  (* gh owns this credential: it minted the token, it rewrites the file it
     lives in, and masc holds no refresh token to spend. Renewing here would
     mean going to an authorization server about a grant masc never made. *)
  | Provider.Github_cli _ -> Ok access_token
  | Provider.Oauth_exchange ->
  match stored_expires_at ~base_path ~keeper_name ~provider with
  (* No stored expiry means nothing said this token is old. Renewing on a
     guess would spend a refresh token to replace a working credential; the
     reactive path in [run_call] covers a token that turns out to be stale. *)
  | None -> Ok access_token
  | Some expires_at ->
    if not (Keeper_oauth_flow.needs_renewal ~provider ~expires_at ~now)
    then Ok access_token
    else force_refresh ~token_post ~discover ~base_path ~keeper_name ~provider ~now ()
;;

let run_call_once ~transports ~base_path ~keeper_name
      ~(provider : Provider.t) ~remote_name ~arguments () =
  let { mcp_post; token_post; discover } = transports in
  match access_token_for ~base_path ~keeper_name ~provider with
  | Error message -> Error (Precondition message)
  | Ok stored_token -> (
    match
      renew_if_needed ~token_post ~discover ~base_path ~keeper_name ~provider
        (* [Time_compat.now] rather than the raw clock: masc reads time
           through one module so a deterministic boundary has one place to
           look, and the determinism gate flags anything that goes around
           it. *)
        ~now:(Time_compat.now ()) ~access_token:stored_token ()
    with
    | Error (Renew_permanent message) -> Error (Precondition message)
    | Error (Renew_transient message) -> Error (Transient_precondition message)
    | Ok access_token -> (
      match
        Mcp_client.connect ~post:mcp_post ~url:provider.Provider.mcp_url ~access_token ()
      with
      (* A session that never came up carries proof the call was not sent;
         an error after [call_tool] does not, and the two must stay apart
         because replay reads the phase as the effect's disposition. *)
      | Error error -> Error (Mcp { phase = Session_open; error })
      | Ok client -> (
        match Mcp_client.call_tool ~post:mcp_post client ~name:remote_name ~arguments with
        | Error error when is_method_not_found_error error -> (
          (* The wire error alone does not distinguish an unknown tools/call
             method from a stale tool name.  Only investigate when the
             catalog used to assemble this call advertised the name, then
             ask the live session once.  A removed name is not called again;
             a still-advertised name gets one bounded retry. *)
          match load ~base_path ~keeper_name ~provider_id:provider.Provider.id with
          | Ok (Some previous_catalog)
            when catalog_contains previous_catalog.tools remote_name -> (
            match Mcp_client.list_tools ~post:mcp_post client with
            | Error rediscovery_error ->
              Log.Keeper.emit Log.Warn ~keeper_name
                (Printf.sprintf
                   "keeper_identity_tools: %s catalog rediscovery after a \
                    method-not-found for %s failed: %s"
                   provider.Provider.id remote_name
                   (Mcp_client.error_to_string rediscovery_error));
              Error (Mcp { phase = Tool_call; error })
            | Ok tools ->
              let fresh =
                { provider_id = provider.Provider.id
                ; provider_label = provider.Provider.label
                ; discovered_at = Time_compat.now ()
                ; tools
                }
              in
              let lost, gained = drift_of ~previous:previous_catalog.tools ~fresh:tools in
              (* emit, not info: a computed string goes through
                 [LOGGER.emit]; the format-taking [info] is for literals. *)
              Log.Keeper.emit Log.Info ~keeper_name
                (Printf.sprintf
                   "keeper_identity_tools: %s catalog rediscovered after a \
                    method-not-found for %s — %d tools before, %d after \
                    (lost %d, gained %d), catalog time %.0f"
                   provider.Provider.id remote_name
                   (List.length previous_catalog.tools) (List.length tools)
                   (List.length lost) (List.length gained) fresh.discovered_at);
              (match save ~base_path ~keeper_name fresh with
               | Ok () -> ()
               | Error problem ->
                 Log.Keeper.emit Log.Warn ~keeper_name
                   (Printf.sprintf
                      "keeper_identity_tools: rediscovered %s catalog could \
                       not be saved: %s"
                      provider.Provider.id problem));
              if not (catalog_contains tools remote_name)
              then
                (* Rediscovery proved that the old offer was stale.  Retrying
                   a name the server no longer advertises would be a second
                   predictable failure, not recovery. *)
                Error (Mcp { phase = Tool_call; error })
              else
                match Mcp_client.call_tool ~post:mcp_post client ~name:remote_name ~arguments with
                | Error retry_error ->
                  Error (Mcp { phase = Tool_call; error = retry_error })
                | Ok result -> Ok result)
          | Error problem ->
            Log.Keeper.emit Log.Warn ~keeper_name
              (Printf.sprintf
                 "keeper_identity_tools: %s catalog could not be read while \
                  investigating method-not-found for %s: %s"
                 provider.Provider.id remote_name problem);
            Error (Mcp { phase = Tool_call; error })
          | Ok None | Ok (Some _) -> Error (Mcp { phase = Tool_call; error }))
        | Error error -> Error (Mcp { phase = Tool_call; error })
        | Ok result -> Ok result)))
;;

(* One reactive refresh. [run_call_once] renews proactively only when a stored
   expiry says the token is old; a provider that issues no expiry never triggers
   that, so a token it rejects with 401 would otherwise fail the call with
   "attach it again" while a spendable refresh token sits unused. Force a refresh
   and retry once. [force_refresh] stores the new token, so the retry reads it
   back through [access_token_for]; any refresh failure keeps the original 401,
   so the operator still learns to re-attach and there is no second retry. *)
let run_call ~transports ~base_path ~keeper_name
      ~(provider : Provider.t) ~remote_name ~arguments () =
  match
    run_call_once ~transports ~base_path ~keeper_name ~provider
      ~remote_name ~arguments ()
  with
  | Error (Mcp { error = Mcp_client.Unauthorized _; _ }) as unauthorized -> (
    match provider.Provider.credential_source with
    (* gh owns this credential and rewrites its own file; masc holds no refresh
       token to spend, so a 401 here is genuinely re-attach. *)
    | Provider.Github_cli _ -> unauthorized
    | Provider.Oauth_exchange -> (
      match
        force_refresh ~token_post:transports.token_post ~discover:transports.discover
          ~base_path ~keeper_name ~provider ~now:(Time_compat.now ()) ()
      with
      | Error _ -> unauthorized
      | Ok _ ->
        run_call_once ~transports ~base_path ~keeper_name ~provider
          ~remote_name ~arguments ()))
  | other -> other
;;

let agent_tools ~(provider : Provider.t) catalog =
  List.fold_left
    (fun acc (tool : Mcp_client.tool) ->
      let name = model_tool_name ~provider ~remote_name:tool.Mcp_client.name in
      match
        Agent_core.Types.tool_schema_of_input_schema ~name
          ~description:tool.Mcp_client.description
          ~input_schema:tool.Mcp_client.input_schema ()
      with
      | Error detail ->
        { acc with unusable = (name, detail) :: acc.unusable }
      | Ok schema ->
        (* The policy runs mid-turn with only a name, so what the service
           said about this tool has to be somewhere it can reach. Recorded
           before the tool is handed out, not after: a tool the model could
           call while the row was missing would be asked about with a reason
           nobody can act on. *)
        Keeper_identity_tool_index.record
          (Keeper_identity_tool_index.shared ())
          ~tool_name:name ~read_only:tool.Mcp_client.read_only;
        let offered_tool =
          { schema
          ; read_only = tool.Mcp_client.read_only
          ; provider
          ; remote_name = tool.Mcp_client.name
          }
        in
        { acc with offered = offered_tool :: acc.offered })
    { offered = []; unusable = [] }
    catalog.tools
  |> fun acc ->
  { offered = List.rev acc.offered; unusable = List.rev acc.unusable }
;;

let for_turn ~base_path ~keeper_name =
  (* Read once for the turn, not once per provider. An unreadable switch
     store marks every declared provider unusable rather than offering
     tools an operator may have turned off — the same reading the store
     itself gives an unreadable file. *)
  let switched_off =
    Keeper_identity_switch.disabled_providers_for_keeper ~base_path ~keeper_name
  in
  List.fold_left
    (fun acc declaration ->
      match declaration with
      (* A declaration nobody can read is not this Keeper's problem to
         solve, but a turn that silently offered fewer tools because of it
         would leave nobody able to tell. *)
      | Keeper_oauth_declarations.Unreadable { id; problem } ->
        { acc with unusable = (id, problem) :: acc.unusable }
      | Keeper_oauth_declarations.Declared provider ->
        (match switched_off with
         | Error problem ->
           { acc with unusable = (provider.Provider.id, problem) :: acc.unusable }
         | Ok off when List.mem provider.Provider.id off ->
           (* Switched off by an operator. Not [unusable]: nothing is
              broken, and the identity screen says off while the audit log
              says who and when. Reporting it every turn would be noise
              about a choice. *)
           acc
         | Ok _ ->
           (match
              load ~base_path ~keeper_name ~provider_id:provider.Provider.id
            with
            (* Never attached. Nothing to offer and nothing wrong. *)
            | Ok None -> acc
            | Error problem ->
              { acc with
                unusable = (provider.Provider.id, problem) :: acc.unusable
              }
            | Ok (Some catalog) ->
              let offering = agent_tools ~provider catalog in
              { offered = acc.offered @ offering.offered
              ; unusable = List.rev_append offering.unusable acc.unusable
              })))
    { offered = []; unusable = [] }
    (Keeper_oauth_declarations.all ())
  |> fun acc -> { acc with unusable = List.rev acc.unusable }
;;
