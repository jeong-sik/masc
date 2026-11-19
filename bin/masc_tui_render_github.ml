(** GitHub authentication pane rows from immutable UI inputs.
    The root renderer resolves the selected Keeper's stamped base rows. *)

open Masc_tui_ansi

type view =
  { token_input : string option
  ; save_status : string option
  ; login_scopes : Masc.Keeper_github_identity.login_scope list
  }

let lines ?(ko = false) (view : view) ~base =
  let say korean english = if ko then korean else english in
  let input_lines =
    match view.token_input with
    | Some draft ->
      let masked =
        let len = String.length draft in
        if len = 0
        then say "(비어 있음)" "(empty)"
        else if len <= 8
        then String.make len '*'
        else
          String.sub draft 0 4 ^ String.make (len - 8) '*' ^ String.sub draft (len - 4) 4
      in
      [ Theme.ok ()
        ^ say "  ╭─ GitHub Personal Access Token (PAT) 설정 ─"
              "  ╭─ Set GitHub Personal Access Token (PAT) ─"
        ^ Ansi.reset
      ; say "  │ 토큰: " "  │ Token: " ^ masked ^ "█"
      ; "  │ " ^ Ansi.dim ^ say "Enter:저장  Esc:취소" "Enter:save  Esc:cancel" ^ Ansi.reset
      ; "  ╰─────────────────────────────────────────"
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
    ((Ansi.dim
      ^ say "  로그인 권한 범위 (숫자 키로 토글 · L로 로그인)"
            "  Login scopes (digit toggles, L logs in with them)"
      ^ Ansi.reset)
     :: List.mapi
          (fun index scope ->
             let ticked = List.mem scope view.login_scopes in
             let note =
               match scope with
               | Masc.Keeper_github_identity.Workflow ->
                 say "저장소 비밀을 쓰는 .github/workflows 변경 허용"
                   "may change .github/workflows, which run with repo secrets"
               | Masc.Keeper_github_identity.Write_packages ->
                 say "ghcr.io 이미지 등 GitHub Packages 게시 허용"
                   "may publish GitHub Packages, ghcr.io images among them"
               | Masc.Keeper_github_identity.Read_packages ->
                 say "ghcr.io 이미지 등 GitHub Packages 다운로드 허용"
                   "may download GitHub Packages, ghcr.io images among them"
               | Masc.Keeper_github_identity.Project ->
                 say "접근 가능한 Projects (v2) 조회·변경 허용"
                   "may read and change Projects (v2) the account can reach"
               | Masc.Keeper_github_identity.Write_repo_hook ->
                 say "임의 URL로 이벤트를 보내는 저장소 웹훅 추가 허용"
                   "may add repo webhooks, which post repo events to any URL"
             in
             Printf.sprintf
               "  %d %s %s %s· %s%s"
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
