open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let center_rect ~(outer : Rect.t) ~w ~h =
  let cw = Int.max 0 (Int.min outer.w w) in
  let ch = Int.max 0 (Int.min outer.h h) in
  let x = outer.x + ((outer.w - cw) / 2) in
  let y = outer.y + ((outer.h - ch) / 2) in
  Rect.make ~x ~y ~w:cw ~h:ch

let mode_label ~(lang : Say.lang) (session : Rbac.auth_session) =
  match Rbac.account_mode_of_session session with
  | Some Rbac.Single_user ->
      Say.resolve lang (Say.make ~ko:"Single_user (단일 사용자)" ~en:"Single_user")
  | Some Rbac.Multi_account ->
      Say.resolve lang (Say.make ~ko:"Multi_account (다중 계정)" ~en:"Multi_account")
  | None -> Say.resolve lang (Say.make ~ko:"확인 중 (Probing)" ~en:"Probing")

let token_source_label ~(lang : Say.lang) = function
  | Account_store.Token_startup_default ->
      Say.resolve lang
        (Say.make ~ko:"시작 기본값 ($MASC_TOKEN / admin.token)"
           ~en:"startup default ($MASC_TOKEN / admin.token)")
  | Account_store.Token_runtime_set ->
      Say.resolve lang
        (Say.make ~ko:"런타임 설정됨 (마스킹)" ~en:"runtime override (masked)")
  | Account_store.Token_runtime_cleared ->
      Say.resolve lang (Say.make ~ko:"런타임 해제됨 (없음)" ~en:"runtime cleared (none)")

let put_clipped grid ~clip ~x ~y ~style text =
  let max_width = Int.max 0 (Rect.right clip - x) in
  if max_width <= 0 || y < clip.y || y >= Rect.bottom clip then 0
  else
    Cell_grid.put_text ~clip grid ~x ~y ~style
      (Grapheme.truncate_to_width ~max_width text)

let put_kv grid ~clip ~x ~y ~key_st ~val_st ~key value =
  let adv = put_clipped grid ~clip ~x ~y ~style:key_st (key ^ ": ") in
  let adv2 = put_clipped grid ~clip ~x:(x + adv) ~y ~style:val_st value in
  adv + adv2

let format_integration_line (it : Wire_account.person_integration) =
  let methods =
    match it.connect with
    | [] -> "none"
    | xs ->
        String.concat ","
          (List.map Wire_account.connect_method_to_string xs)
  in
  let calls_str =
    match it.calls with
    | Wire_account.Calls_allowed -> "calls=allowed"
    | Wire_account.Calls_refused r ->
        "calls=refused(" ^ Wire_account.integration_refusal_to_string r ^ ")"
  in
  let models_str =
    match it.models with
    | [] -> "models=none"
    | xs ->
        let preview =
          if List.length xs <= 3 then String.concat ", " xs
          else
            Printf.sprintf "%s, %s (+%d)" (List.nth xs 0) (List.nth xs 1)
              (List.length xs - 2)
        in
        "models=" ^ preview
  in
  Printf.sprintf "%s (%s) [%s] %s · %s" it.integration_id it.display_name
    methods calls_str models_str

let format_withheld_line (it : Wire_account.person_integration) =
  match it.withheld with
  | [] -> None
  | xs ->
      let items =
        xs
        |> List.map (fun (w : Wire_account.withheld_model) ->
               Printf.sprintf "%s(%s)" w.model w.reason)
        |> String.concat ", "
      in
      Some ("    withheld:" ^ items)

let format_account_line ~(acct_store : Account_store.t)
    (acc : Wire_account.provider_account) =
  let kind_str =
    match acc.kind with
    | Wire_account.Provider_login -> "login"
    | Wire_account.Provider_key ks ->
        "key:" ^ Wire_account.provider_key_state_to_string ks
  in
  let warn_tags =
    let rem =
      match acc.removal with
      | Some r -> [ "removal=" ^ Wire_account.provider_removal_state_to_string r ]
      | None -> []
    in
    let rep =
      match acc.replacement with
      | Some r ->
          [ "replacement=" ^ Wire_account.provider_replacement_state_to_string r ]
      | None -> []
    in
    match rem @ rep with
    | [] -> ""
    | xs -> " [" ^ String.concat ", " xs ^ "]"
  in
  let runtimes =
    Account_store.runtimes_for_account ~provider_account_id:acc.provider_account_id
      acct_store
  in
  let rt_str =
    match runtimes with
    | [] -> "no runtime"
    | rs ->
        rs
        |> List.map (fun (r : Wire_account.provider_runtime) ->
               match r.model with
               | Wire_account.Runtime_model m ->
                   Printf.sprintf "%s(%s)" r.runtime_id m
               | Wire_account.Runtime_model_unread u ->
                   Printf.sprintf "%s(unread:%s)" r.runtime_id
                     (Wire_account.runtime_unread_reason_to_string u))
        |> String.concat ", "
  in
  Printf.sprintf "%s  [%s · %s]%s  -> %s" acc.provider_account_id
    acc.integration_id kind_str warn_tags rt_str

let render grid ~cache ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t) =
  let desired_w = Int.max 76 (Int.min 116 (rect.w * 4 / 5)) in
  let w = Int.min (Int.max 0 (rect.w - 2)) desired_w in
  let h = Int.min (Int.max 0 (rect.h - 2)) (Int.max 22 (rect.h - 2)) in
  let modal_r = center_rect ~outer:rect ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let session = model.auth_session in
    let editing = model.account.token_editor.active in
    let title = Say.resolve lang (Say.make ~ko:"계정 · 세션" ~en:"Account & Session") in
    let badge_text =
      Say.resolve lang (Rbac.session_badge ~compact:true session)
    in
    let badge_tone =
      if Rbac.requires_auth_gate session then Theme.Status_critical
      else if Rbac.can_admin session then Theme.Status_ok
      else if Rbac.is_authenticated session then Theme.Status_attention
      else Theme.Status_historical
    in
    let hotkey =
      if editing then
        Say.resolve lang
          (Say.make ~ko:"[Enter] 적용 · [Ctrl+U] 지우기 · [Esc] 취소"
             ~en:"[Enter] Apply · [Ctrl+U] Wipe · [Esc] Cancel")
      else
        Say.resolve lang
          (Say.make ~ko:"[t] 토큰 · [c] 해제 · [r] 재확인 · [Esc] 닫기"
             ~en:"[t] Token · [c] Clear · [r] Recheck · [Esc] Close")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          badge =
            Some
              {
                glyph =
                  (if Rbac.requires_auth_gate session then Some Glyph.Locked
                   else None);
                text = badge_text;
                tone = Some badge_tone;
              };
          hotkey = Some hotkey;
          focused = true;
          elevated = true;
        }
    in
    if Rect.is_empty inner then ()
    else
      let bg = Color.of_rgb theme.surface_2 in
      let pad_x = if inner.w >= 56 then 2 else 1 in
      let content_x = inner.x + pad_x in
      let content_w = Int.max 0 (inner.w - (2 * pad_x)) in
      let anchor_st = Typography.anchor ~bg theme in
      let primary_st = Typography.primary ~bg theme in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let acc_st = Typography.accent ~bg ~bold:true theme in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let warn_st = Typography.status ~bg ~bold:true theme Theme.Status_attention in
      let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
      let footer_h = if inner.h >= 8 then 1 else 0 in
      let body_bottom = Rect.bottom inner - footer_h in
      let body_clip =
        Rect.make ~x:content_x ~y:inner.y ~w:content_w
          ~h:(Int.max 0 (body_bottom - inner.y))
      in
      let y = ref inner.y in
      let line_ok () = !y < body_bottom in
      let next_line () = y := !y + 1 in
      (* Section 1: Identity & Session *)
      if line_ok () then begin
        let mode_s = mode_label ~lang session in
        let principal_s = Rbac.principal_display session in
        let binding_s =
          let base =
            Rbac.binding_display_to_string (Rbac.binding_display_of_session session)
          in
          match Rbac.binding_id_of_session session with
          | Some id -> Printf.sprintf "%s (%s)" base id
          | None -> base
        in
        let role_s = Rbac.role_display session in
        let adv =
          put_kv grid ~clip:body_clip ~x:content_x ~y:!y ~key_st:struct_st
            ~val_st:anchor_st ~key:"Mode" mode_s
        in
        let sep_x = content_x + adv + 3 in
        ignore
          (put_kv grid ~clip:body_clip ~x:sep_x ~y:!y ~key_st:struct_st
             ~val_st:ok_st ~key:"Role" role_s);
        next_line ();
        if line_ok () then begin
          let adv_p =
            put_kv grid ~clip:body_clip ~x:content_x ~y:!y ~key_st:struct_st
              ~val_st:primary_st ~key:"Principal" principal_s
          in
          let bx = content_x + adv_p + 3 in
          ignore
            (put_kv grid ~clip:body_clip ~x:bx ~y:!y ~key_st:struct_st
               ~val_st:primary_st ~key:"Binding" binding_s);
          next_line ()
        end;
        if line_ok () then begin
          ignore
            (put_kv grid ~clip:body_clip ~x:content_x ~y:!y ~key_st:struct_st
               ~val_st:whisper_st ~key:"Token"
               (token_source_label ~lang model.account.token_source));
          next_line ()
        end
      end;
      (* Active auth error detail (scrubbed) *)
      (match Rbac.auth_error_detail_of_session session with
      | Some detail when line_ok () ->
          let clean =
            Chat_transcript.scrub_secrets_in_text detail
            |> Text_util.sanitize_single_line
          in
          ignore
            (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y ~style:crit_st
               (Glyph.to_utf8 Glyph.Locked ^ " Auth error: " ^ clean));
          next_line ()
      | Some _ | None -> ());
      (* Inline Masked Token / PAT Editor *)
      if editing && line_ok () then begin
        let strip_r = Rect.make ~x:content_x ~y:!y ~w:content_w ~h:1 in
        let edit_bg = Color.of_rgb theme.selection_bg in
        let edit_st = Typography.anchor ~bg:edit_bg theme in
        Cell_grid.fill_rect ~clip:body_clip grid ~rect:strip_r ~style:edit_st ();
        let masked = Account_store.masked_draft_display model.account.token_editor in
        let prompt =
          Say.resolve lang
            (Say.make ~ko:"Bearer / PAT 입력 (마스킹): "
               ~en:"Bearer / PAT (masked): ")
        in
        let adv =
          put_clipped grid ~clip:strip_r ~x:content_x ~y:!y ~style:edit_st
            (prompt ^ masked)
        in
        let cur_x = content_x + adv in
        if cur_x < Rect.right strip_r then
          Cell_grid.put_ascii ~clip:strip_r grid ~x:cur_x ~y:!y
            ~style:
              (Style.make ~fg:(Color.of_rgb theme.surface_2)
                 ~bg:(Color.of_rgb theme.accent) ())
            ' ';
        next_line ();
        (match model.account.token_editor.error with
        | Some err when line_ok () ->
            ignore
              (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y ~style:crit_st
                 err);
            next_line ()
        | Some _ | None -> ())
      end;
      (* Section 2: Capability Matrix *)
      if line_ok () then begin
        let hdr =
          Say.resolve lang (Say.make ~ko:"권한 매트릭스" ~en:"Capabilities")
        in
        Card.draw_hairline ~pad_x ~label:hdr ~focused:false ~bg grid ~rect:inner
          ~y:!y ~theme;
        next_line ()
      end;
      let cap_rows = Rbac.capability_rows_of_session session in
      let format_cap (row : Rbac.capability_row) =
        match row.verdict with
        | Rbac.Allowed -> (ok_st, Printf.sprintf "[OK] %s" row.key)
        | Rbac.Denied reason ->
            let why = Say.resolve lang (Rbac.short_deny_reason_say reason) in
            (whisper_st, Printf.sprintf "[NO] %s (%s)" row.key why)
      in
      let two_col = content_w >= 68 in
      if two_col then begin
        let col_w = content_w / 2 in
        let rec draw_pairs = function
          | [] -> ()
          | a :: b :: rest ->
              if line_ok () then begin
                let st_a, txt_a = format_cap a in
                let st_b, txt_b = format_cap b in
                let left_clip =
                  Rect.make ~x:content_x ~y:!y ~w:(col_w - 1) ~h:1
                in
                let right_clip =
                  Rect.make ~x:(content_x + col_w) ~y:!y
                    ~w:(content_w - col_w) ~h:1
                in
                ignore
                  (put_clipped grid ~clip:left_clip ~x:content_x ~y:!y
                     ~style:st_a txt_a);
                ignore
                  (put_clipped grid ~clip:right_clip ~x:(content_x + col_w)
                     ~y:!y ~style:st_b txt_b);
                next_line ();
                draw_pairs rest
              end
          | [ a ] ->
              if line_ok () then begin
                let st_a, txt_a = format_cap a in
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:st_a txt_a);
                next_line ()
              end
        in
        draw_pairs cap_rows
      end
      else
        List.iter
          (fun row ->
            if line_ok () then begin
              let st, txt = format_cap row in
              ignore (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y ~style:st txt);
              next_line ()
            end)
          cap_rows;
      (* Section 3: Multi-Account Own-Provider Management *)
      if line_ok () then begin
        let hdr =
          Say.resolve lang
            (Say.make ~ko:"다중 계정 개인 프로바이더" ~en:"Multi-Account Own Providers")
        in
        Card.draw_hairline ~pad_x ~label:hdr ~focused:false ~bg grid ~rect:inner
          ~y:!y ~theme;
        next_line ()
      end;
      (match Rbac.decide session Rbac.Multi_account_own_provider with
      | Rbac.Denied reason ->
          if line_ok () then begin
            let msg =
              match reason with
              | Rbac.Multi_account_only_in_single_user ->
                  Say.resolve lang
                    (Say.make
                       ~ko:"단일 사용자 모드에서는 개인 프로바이더 관리가 비활성입니다 ([4] 런타임 화면에서 로컬 설정 사용)"
                       ~en:"Inactive in Single_user mode (manage local providers in [4] Runtime)")
              | Rbac.Probing_auth
              | Rbac.Auth_required _
              | Rbac.Requires_admin
              | Rbac.Pat_cannot_admin
              | Rbac.Token_auth_not_enabled
              | Rbac.Service_cannot_manage_own_provider
              | Rbac.Requires_worker_or_admin
              | Rbac.Single_user_only_in_multi_account ->
                  Say.resolve lang (Rbac.deny_reason_say reason)
            in
            ignore (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y ~style:whisper_st msg);
            next_line ()
          end
      | Rbac.Allowed ->
          (* Explicit HTTP 403 scope banner *)
          (match model.account.own_provider_forbidden with
          | Some detail when line_ok () ->
              let clean =
                Chat_transcript.scrub_secrets_in_text detail
                |> Text_util.sanitize_single_line
              in
              ignore
                (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                   ~style:crit_st
                   (Glyph.to_utf8 Glyph.Locked
                    ^ " HTTP 403 (manage_own_provider required): " ^ clean));
              next_line ()
          | Some _ | None -> ());
          (* Integrations scope honesty *)
          if line_ok () then begin
            match model.account.integrations with
            | Observed.Loading _ ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:whisper_st "Integrations: loading...");
                next_line ()
            | Observed.Failed { reason; _ } ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:warn_st
                     ("Integrations error: " ^ Text_util.sanitize_single_line reason));
                next_line ()
            | Observed.Unreported | Observed.Absent ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:whisper_st "Integrations: not loaded ([r] refresh)");
                next_line ()
            | Observed.Value { data; _ } ->
                if data.integrations = [] then begin
                  ignore
                    (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                       ~style:whisper_st "Integrations: none reported");
                  next_line ()
                end
                else
                  List.iter
                    (fun (it : Wire_account.person_integration) ->
                      if line_ok () then begin
                        let st =
                          match it.calls with
                          | Wire_account.Calls_allowed -> struct_st
                          | Wire_account.Calls_refused _ -> warn_st
                        in
                        ignore
                          (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                             ~style:st (format_integration_line it));
                        next_line ();
                        (match format_withheld_line it with
                        | Some wline when line_ok () ->
                            ignore
                              (put_clipped grid ~clip:body_clip ~x:content_x
                                 ~y:!y ~style:whisper_st wline);
                            next_line ()
                        | Some _ | None -> ())
                      end)
                    data.integrations
          end;
          (* Active CLI login status if running *)
          (match model.runtime.setup_login_receipt with
          | Some r when line_ok () ->
              let extra =
                match model.runtime.setup_login_device_code with
                | Some code -> " · code=" ^ code
                | None -> (
                    match model.runtime.setup_login_auth_url with
                    | Some url -> " · " ^ url
                    | None -> "")
              in
              let line =
                Printf.sprintf "Active CLI login: %s [%s] (%s)%s"
                  r.integration_id r.status r.login_id extra
              in
              ignore
                (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                   ~style:acc_st line);
              next_line ()
          | Some _ | None -> ());
          (* Last verification result if present *)
          (match model.account.last_verification with
          | Some (acc_id, resp) when line_ok () ->
              let v = resp.verification in
              let st =
                match v.status with
                | Wire_account.Verify_verified -> ok_st
                | Wire_account.Verify_failed | Wire_account.Verify_unavailable ->
                    warn_st
              in
              let checks =
                Printf.sprintf "resp=%b tool=%b rt=%b" v.checks.response
                  v.checks.tool_called v.checks.tool_roundtrip
              in
              let tail =
                match v.failure with
                | Some f -> Printf.sprintf " · %s: %s" f.code f.message
                | None -> (
                    match resp.runtime with
                    | Some rt ->
                        Printf.sprintf " · runtime=%s(%s)" rt.runtime_id
                          (Wire_account.runtime_record_outcome_to_string rt.record)
                    | None -> "")
              in
              let line =
                Printf.sprintf "Last verify (%s): %s [%s]%s" acc_id
                  (Wire_account.verification_status_to_string v.status)
                  checks tail
              in
              ignore
                (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y ~style:st
                   line);
              next_line ()
          | Some _ | None -> ());
          (* Provider accounts list *)
          if line_ok () then begin
            match model.account.provider_accounts with
            | Observed.Loading _ ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:whisper_st "Provider accounts: loading...");
                next_line ()
            | Observed.Failed { reason; _ } ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:warn_st
                     ("Provider accounts error: "
                     ^ Text_util.sanitize_single_line reason));
                next_line ()
            | Observed.Unreported | Observed.Absent ->
                ignore
                  (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                     ~style:whisper_st
                     "Provider accounts: not loaded ([r] refresh)");
                next_line ()
            | Observed.Value { data; _ } ->
                if data.provider_accounts = [] then begin
                  ignore
                    (put_clipped grid ~clip:body_clip ~x:content_x ~y:!y
                       ~style:whisper_st
                       "Provider accounts: none connected ([l] CLI login · [K] add API key)");
                  next_line ()
                end
                else
                  let sel_idx = model.account.selected_account_idx in
                  List.iteri
                    (fun idx acc ->
                      if line_ok () then begin
                        let is_sel = Int.equal idx sel_idx in
                        let rbg =
                          Color.of_rgb
                            (if is_sel then theme.selection_bg else theme.surface_2)
                        in
                        let row_r =
                          Rect.make ~x:content_x ~y:!y ~w:content_w ~h:1
                        in
                        Cell_grid.fill_rect ~clip:body_clip grid ~rect:row_r
                          ~style:(Typography.primary ~bg:rbg theme) ();
                        let prefix =
                          if is_sel then Glyph.to_utf8 Glyph.Left_rail ^ " "
                          else "  "
                        in
                        let st =
                          if is_sel then Typography.anchor ~bg:rbg theme
                          else Typography.primary ~bg:rbg theme
                        in
                        let txt =
                          prefix
                          ^ format_account_line ~acct_store:model.account acc
                        in
                        ignore
                          (put_clipped grid ~clip:row_r ~x:content_x ~y:!y
                             ~style:st txt);
                        next_line ()
                      end)
                    data.provider_accounts
          end);
      (* Bottom truthful action bar *)
      if footer_h > 0 then begin
        let fy = Rect.bottom inner - 1 in
        let f_clip = Rect.make ~x:content_x ~y:fy ~w:content_w ~h:1 in
        let bar =
          if editing then
            Say.resolve lang
              (Say.make
                 ~ko:"[Enter] 토큰 적용  ·  [Ctrl+U] 지우기  ·  [Esc] 입력 취소 (붙여넣기 지원)"
                 ~en:"[Enter] Apply token  ·  [Ctrl+U] Wipe  ·  [Esc] Cancel (paste supported)")
          else if Rbac.is_allowed session Rbac.Multi_account_own_provider then
            let login_extra =
              if Option.is_some (Runtime_store.active_setup_login_id model.runtime)
              then " · [e] Input · [L] Poll · [x] Cancel"
              else ""
            in
            Say.resolve lang
              (Say.make
                 ~ko:
                   ("[t] 토큰 · [c] 해제 · [l] 로그인 · [K] 키 추가 · [u] 키 교체 · [d] 키 삭제 · [v] 검증 · [r] 새로고침"
                   ^ login_extra)
                 ~en:
                   ("[t] Token · [c] Clear · [l] Login · [K] Add Key · [u] Rotate Key · [d] Remove Key · [v] Verify · [r] Refresh"
                   ^ login_extra))
          else
            Say.resolve lang
              (Say.make
                 ~ko:"[t] 토큰 설정/교체  ·  [c] 토큰 해제  ·  [r] 세션 재확인  ·  [?] 도움말  ·  [Esc] 닫기"
                 ~en:"[t] Set/Rotate Token  ·  [c] Clear Token  ·  [r] Recheck Session  ·  [?] Help  ·  [Esc] Close")
        in
        ignore (put_clipped grid ~clip:f_clip ~x:content_x ~y:fy ~style:acc_st bar)
      end
