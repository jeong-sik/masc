(** GitHub authentication pane rows from immutable UI inputs.
    The root renderer resolves the selected Keeper's stamped base rows. *)

open Masc_tui_ansi

type view =
  { token_input : string option
  ; save_status : string option
  ; login_scopes : Masc.Keeper_github_identity.login_scope list
  }

let split_utf8_scalars s =
  let len = String.length s in
  let rec loop i acc =
    if i >= len then List.rev acc
    else
      let dec = String.get_utf_8_uchar s i in
      let step = max 1 (Uchar.utf_decode_length dec) in
      let take = min step (len - i) in
      loop (i + take) (String.sub s i take :: acc)
  in
  loop 0 []
;;

let lines ?(ko = false) (view : view) ~base =
  let say korean english = if ko then korean else english in
  let input_lines =
    match view.token_input with
    | Some draft ->
      let masked =
        let scalars = split_utf8_scalars draft in
        let n = List.length scalars in
        if n = 0
        then Theme.recede () ^ say "(비어 있음)" "(empty)" ^ Ansi.reset
        else if n <= 8
        then String.make n '*'
        else
          String.concat "" (List.take 4 scalars)
          ^ String.make (n - 8) '*'
          ^ String.concat "" (List.drop (n - 4) scalars)
      in
      let edge = Theme.border_muted () in
      let pipe = edge ^ "  \xe2\x94\x82 " ^ Ansi.reset in
      [ edge ^ "  \xe2\x95\xad\xe2\x94\x80 " ^ Ansi.reset
        ^ Theme.ok () ^ Ansi.bold
        ^ say "GitHub Personal Access Token (PAT) 설정"
              "Set GitHub Personal Access Token (PAT)"
        ^ Ansi.reset ^ edge ^ " \xe2\x94\x80" ^ Ansi.reset
      ; pipe ^ Theme.recede () ^ say "토큰: " "Token: " ^ Ansi.reset ^ masked ^ "\xe2\x96\x88"
      ; pipe ^ Theme.recede () ^ say "Enter:저장  Esc:취소" "Enter:save  Esc:cancel" ^ Ansi.reset
      ; edge ^ "  \xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ^ Ansi.reset
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
    ((Theme.recede ()
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
             let box =
               if ticked then Theme.ok () ^ "[x]" ^ Ansi.reset
               else Theme.recede () ^ "[ ]" ^ Ansi.reset
             in
             Printf.sprintf
               "  %s%d%s %s %s %s· %s%s"
               Ansi.bold
               (index + 1)
               Ansi.reset
               box
               (Masc.Keeper_github_identity.login_scope_to_string scope)
               (Theme.recede ())
               note
               Ansi.reset)
          Masc.Keeper_github_identity.all_login_scopes)
    @ [ "" ]
  in
  input_lines @ status_lines @ scope_lines @ base
;;
