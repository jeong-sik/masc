(** One owner for what this client is called and for what it says when the
    server refuses it.

    Three surfaces report a refusal -- the chat reconciliation line, the keeper
    roster line, and every JSON read -- and each was writing the sentence for
    itself. The agent name was written twice more, once for the request header
    and once for the credential filename. Both are single facts; a rename that
    reaches only some of the copies leaves the others telling the operator to
    provision something under a name that no longer exists. *)

let agent_name = "masc-tui"

(* The env var an operator may set to override the stored bearer. Named here
   because it appears in three unrelated-looking places: the lookup, the
   argument that tells masc login which name to print, and the command the
   operator is handed. *)
let token_env_var = "MASC_TOKEN"

let login_command =
  Printf.sprintf "masc login --agent %s --client-env %s" agent_name
    token_env_var

(* How long a bearer this client mints for itself lasts. The workspace's own
   window is a day, meant for an operator session someone is sitting in front
   of; an operator who leaves this running overnight comes back to a refused
   credential, which is the failure the mint exists to end. No expiry at all
   goes the other way and leaves an admin secret on disk that nothing retires.
   A month outlasts any single sitting and still stops answering for a
   workspace nobody returns to -- and this client mints a replacement on the
   next start, so crossing it costs the operator nothing. *)
let self_mint_expiry_hours = 24 * 30

(* What the server said about the bearer it refused, read from the typed
   [auth_error_code] its 401/403 body carries. One sentence for every refusal
   sent an operator whose token had simply expired to look for a broken
   credential elsewhere -- on 2026-09-23 a Keeper's GitHub identity view read
   as a GitHub account problem. Only the two codes that change what the
   operator should believe are told apart; every other code, and a body with
   none, is the plain refusal it always was. The code is the server's closed
   type, matched in full, so a code added there has to be placed here. *)
type server_reason =
  | Expired
  | Insufficient_role
  | Rejected

let server_reason_of_code : Masc_error.Auth_error_code.t -> server_reason =
  function
  | Masc_error.Auth_error_code.Token_expired -> Expired
  | Masc_error.Auth_error_code.Insufficient_role -> Insufficient_role
  | Masc_error.Auth_error_code.Invalid_token
  | Masc_error.Auth_error_code.Same_origin_blocked
  | Masc_error.Auth_error_code.Actor_mismatch
  | Masc_error.Auth_error_code.Missing_token
  | Masc_error.Auth_error_code.Unknown ->
      Rejected

let server_reason_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc_opt "auth_error_code" fields with
      | Some (`String code) -> (
          match Masc_error.Auth_error_code.of_string code with
          | Some code -> server_reason_of_code code
          | None -> Rejected)
      | Some _ | None -> Rejected)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Rejected
  | exception Yojson.Json_error _ -> Rejected

(* A refusal names two situations and only one of them is fixed by providing a
   token. This client finds the bearer masc login left in the workspace, so it
   usually does present one, and then "you have no token" is both false and
   advice the operator has already followed. The server's reason only means
   something when a bearer was sent: with none there is nothing for it to have
   judged. *)
let refusal_cause ~credential_sent reason =
  if not credential_sent then
    Printf.sprintf "this %s holds no operator token" agent_name
  else
    match reason with
    | Expired ->
        Printf.sprintf "the operator token this %s presented has expired"
          agent_name
    | Insufficient_role ->
        Printf.sprintf
          "the operator token this %s presented lacks the role this request \
           needs"
          agent_name
    | Rejected ->
        Printf.sprintf "the operator token this %s presented was refused"
          agent_name

let remedy =
  Printf.sprintf "run '%s' and restart %s" login_command agent_name

let refusal ~credential_sent reason =
  Printf.sprintf "%s — %s" (refusal_cause ~credential_sent reason) remedy

(* Which bearer this client should carry, decided from three facts and nothing
   else, so the decision can be read and tested apart from the file and network
   work that carries it out. *)
type plan =
  | Use of string
  | Mint
  | Go_without
  | No_workspace

(* [workspace_initialized] is not redundant with [workspace_requires_token]. A
   missing auth config reads as the default, and the default demands a bearer,
   so an empty directory -- a mistyped base path included -- claims to require
   one. Minting on that alone would write a durable admin secret into whatever
   directory the flag happened to name, for a workspace no server is serving.
   Adding a credential to a workspace that is already here is a different act
   from creating one. *)
let plan ~env_token ~workspace_token ~workspace_requires_token
    ~workspace_initialized =
  match (env_token, workspace_token) with
  | Some token, _ | None, Some token -> Use token
  | None, None ->
      if not workspace_requires_token then Go_without
      else if workspace_initialized then Mint
      else No_workspace

(* What came of carrying the plan out. Returned rather than logged in place so
   the surface decides how loudly to say it.

   Two outcomes leave this client without a bearer, and they are not the same
   news. [Workspace_pending] is the first install: minting is gated on a
   workspace that already exists, only a server creates one, and on a first
   install this client runs before the server it is about to start has made
   the directory. The gate is right to refuse at that moment, and the answer
   changes by itself once a server answers here. [Mint_failed] is a workspace
   that is here and still refused to take a credential -- the mint is local
   file work, so no server answering later changes it, and the operator has
   to act. One constructor for both gave the first install the second's
   sentence: an error line handing over a command for a state that clears
   itself a second or two later. *)
type outcome =
  | Held
  | Minted
  | Not_required
  | Workspace_pending
  | Mint_failed of string

let outcome_notice = function
  | Held | Not_required -> None
  | Minted ->
      Some
        (Printf.sprintf
           "no operator token was present, so this %s minted one for this \
            workspace and stored it; it lasts %d days. A server that is \
            already running rebuilds its credential index on a timer, so the \
            first reads may still be refused."
           agent_name
           (self_mint_expiry_hours / 24))
  | Workspace_pending ->
      (* No remedy: none is owed. The operator learns what is missing and
         that this client takes it again by itself. *)
      Some
        (Printf.sprintf
           "no operator token yet: this base path holds no workspace to mint \
            into. This %s mints one once a server answers here."
           agent_name)
  | Mint_failed detail ->
      Some
        (Printf.sprintf
           "no operator token, and minting one failed: %s — %s" detail remedy)

(* Only a missing workspace is worth a second look, taken when a server
   answers at this base path. The other four are answers a later workspace
   would not change: a mint that failed against a workspace that is already
   here fails the same way after the server is up. *)
let outcome_needs_retry = function
  | Workspace_pending -> true
  | Held | Minted | Not_required | Mint_failed _ -> false

(* How loudly the notice is said. A mint and a failure are not the same news:
   both were reported as errors, which reads a working first start as a broken
   one -- and on a first install, where the client mints for itself, that is
   the ordinary path. Waiting for the workspace is that same ordinary path one
   step earlier, so it reads as system too; only a workspace that refused a
   credential is a fault the operator has to act on. *)
let outcome_level = function
  | Mint_failed _ -> "error"
  | Held | Minted | Not_required | Workspace_pending -> "system"
