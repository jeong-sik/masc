(** One owner for what this client is called and for what it says when the
    server refuses it.

    Three surfaces report a refusal -- the chat reconciliation line, the keeper
    roster line, and every JSON read -- and each was writing the sentence for
    itself. The agent name was written twice more, once for the request header
    and once for the credential filename. Both are single facts; a rename that
    reaches only some of the copies leaves the others telling the operator to
    provision something under a name that no longer exists. *)

let agent_name = "masc-tui"

let login_command =
  Printf.sprintf "masc login --agent %s --client-env MASC_TOKEN" agent_name

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
