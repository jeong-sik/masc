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

(* A refusal names two situations and only one of them is fixed by providing a
   token. This client finds the bearer masc login left in the workspace, so it
   usually does present one, and then "you have no token" is both false and
   advice the operator has already followed. *)
let refusal_cause ~credential_sent =
  if credential_sent then
    Printf.sprintf
      "the operator token this %s presented was refused" agent_name
  else Printf.sprintf "this %s holds no operator token" agent_name

let remedy =
  Printf.sprintf "run '%s' and restart %s" login_command agent_name

let refusal ~credential_sent =
  Printf.sprintf "%s — %s" (refusal_cause ~credential_sent) remedy

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
   the surface decides how loudly to say it. *)
type outcome =
  | Held
  | Minted
  | Not_required
  | Unavailable of string

let no_workspace_detail =
  "this base path holds no workspace to mint into"

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
  | Unavailable detail ->
      Some
        (Printf.sprintf "no operator token, and none could be made: %s — %s"
           detail remedy)
