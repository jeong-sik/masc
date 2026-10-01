(** GitHub authentication pane rows from immutable UI inputs.
    The root renderer resolves the selected Keeper's stamped base rows. *)

open Masc_tui_ansi

type view =
  { token_input : string option
  ; save_status : string option
  ; login_scopes : Masc.Keeper_github_identity.login_scope list
  }

let lines (view : view) ~base =
  let input_lines =
    match view.token_input with
    | Some draft ->
      let masked =
        let len = String.length draft in
        if len = 0
        then "(empty)"
        else if len <= 8
        then String.make len '*'
        else
          String.sub draft 0 4 ^ String.make (len - 8) '*' ^ String.sub draft (len - 4) 4
      in
      [ Theme.ok () ^ "  ┌─ Set GitHub Personal Access Token (PAT) ─" ^ Ansi.reset
      ; "  │ Token: " ^ masked ^ "█"
      ; "  │ " ^ Ansi.dim ^ "(Enter: save, Esc: cancel)" ^ Ansi.reset
      ; "  └─────────────────────────────────────────"
      ; ""
      ]
    | None -> []
  in
  let status_lines =
    match view.save_status with
    | Some status -> [ "  " ^ status; "" ]
    | None -> []
  in
  (* What the next [L] asks for, ticked with the digit printed beside
     it. Drawn from the server's own list so the number and the scope
     the key toggles cannot disagree. *)
  let scope_lines =
    ((Ansi.dim ^ "  Login scopes (digit toggles, L logs in with them)" ^ Ansi.reset)
     :: List.mapi
          (fun index scope ->
             let ticked = List.mem scope view.login_scopes in
             let note =
               match scope with
               | Masc.Keeper_github_identity.Workflow ->
                 "may change .github/workflows, which run with repo secrets"
               | Masc.Keeper_github_identity.Write_packages ->
                 "may publish GitHub Packages, ghcr.io images among them"
               | Masc.Keeper_github_identity.Read_packages ->
                 "may download GitHub Packages, ghcr.io images among them"
               | Masc.Keeper_github_identity.Project ->
                 "may read and change Projects (v2) the account can reach"
               | Masc.Keeper_github_identity.Write_repo_hook ->
                 "may add repo webhooks, which post repo events to any URL"
             in
             Printf.sprintf
               "  %d %s %s %s— %s%s"
               (index + 1)
               (if ticked then "[x]" else "[ ]")
               (Masc.Keeper_github_identity.login_scope_to_string scope)
               Ansi.dim
               note
               Ansi.reset)
          Masc.Keeper_github_identity.all_login_scopes)
    @ [ "" ]
  in
  input_lines @ status_lines @ scope_lines @ base
;;
