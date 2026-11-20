module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Board_composer = Masc_tui_board_composer
module Board_hearth = Masc_tui_board_hearth
module Board_publication = Masc_tui_board_publication

(* The Board draft splits at the first newline: commit-message shape, one
   buffer covering title and body. Trimming the title keeps a draft whose
   first line has stray spaces publishable without surprising the operator. *)
let split_board_draft (text : string) : string * string =
  Board_composer.split_draft text

let open_board_composer_editor (state : T.state) ~restore ~reenter =
  match Masc_tui_editor.editor_command () with
  | None ->
      state.T.board_post_error <-
        Some
          (Masc_tui_editor.abort_detail ~ko:(state.T.ui_language = T.Lang_ko)
             (Masc_tui_editor.Editor_unavailable Masc_tui_editor.Unset));
      state.T.board_compose_armed <- false;
      Masc_tui_shell.Editor_notice.report_unset state ~form:Masc_tui_shell.Editor_notice.Board_draft
  | Some _ -> (
      let current_draft = Buffer.contents state.T.board_draft in
      let stem =
        if String.length (String.trim current_draft) > 0 then current_draft
        else if Option.is_none state.T.board_compose_reply_to then
          Board_composer.template_for_new_post ()
        else
          ""
      in
      match
        Masc_tui_editor.roundtrip ~restore ~reenter ~suffix:".md" stem
      with
      | Error abort ->
          Masc_tui_shell.Editor_notice.report_abort state ~form:Masc_tui_shell.Editor_notice.Board_draft abort;
          state.T.board_compose_armed <- false
      | Ok edited ->
          let trimmed = String.trim edited in
          if Board_composer.is_untouched_template ~draft:trimmed
             && String.length (String.trim current_draft) = 0 then begin
            state.T.board_compose_armed <- false;
            Masc_tui_loader.report_action state "system"
              (T.ui_text state ~ko:"글쓰기 취소 · 빈 초안"
                 ~en:"Board compose cancelled · empty draft")
          end else begin
            Buffer.clear state.T.board_draft;
            Buffer.add_string state.T.board_draft trimmed;
            state.T.board_compose_armed <- false;
            state.T.board_post_error <- None;
            Masc_tui_loader.report_action state "system"
              (T.ui_text state ~ko:"편집기로 초안을 고침" ~en:"Board draft updated from editor")
          end )

(* The attach path input closed with nothing staged: Esc, or Enter on an
   empty path. *)
let attach_cancelled state = T.ui_text state ~ko:"첨부 취소" ~en:"attach cancelled"

(* Stage one local file for the post. Its kind comes from the file's name:
   the store keeps nothing that says what a file is, so the extension is the
   only signal. A path that does not name a plain file keeps the input open
   with the error showing, so the typing can be fixed rather than
   re-entered. *)
let stage_board_compose_path (state : T.state) raw =
  (* A shell would have expanded a leading [~]; nothing does here, and a
     path typed by hand usually starts with one. *)
  let path =
    let typed = String.trim raw in
    match Sys.getenv_opt "HOME" with
    | Some home when String.equal typed "~" -> home
    | Some home when String.starts_with ~prefix:"~/" typed ->
        Filename.concat home (String.sub typed 2 (String.length typed - 2))
    | Some _ | None -> typed
  in
  let ko = state.T.ui_language = T.Lang_ko in
  if String.equal path "" then begin
    state.T.board_compose_attach_input <- None;
    state.T.board_post_error <- None;
    Masc_tui_loader.report_action state "system" (attach_cancelled state)
  end
  else if
    List.exists
      (fun (staged : T.board_staged_attachment) -> String.equal staged.T.sa_path path)
      state.T.board_compose_attachments
  then
    state.T.board_post_error <-
      Some (if ko then "이미 첨부한 파일" else "that file is already attached")
  else
    match
      Masc_tui_board_upload.attachable
        ~max_bytes:Masc_tui_board_upload.max_attachment_bytes path
    with
    | Error refusal ->
        state.T.board_post_error <- Some (Masc_tui_board_upload.refusal_text ~ko refusal)
    | Ok () ->
        let sa_kind = T.upload_kind_of_path path in
        state.T.board_compose_attachments <-
          state.T.board_compose_attachments
          @ [ { T.sa_path = path; sa_name = Filename.basename path; sa_kind } ];
        state.T.board_compose_attach_input <- None;
        state.T.board_post_error <- None;
        Masc_tui_loader.report_action state "system"
          (Printf.sprintf
             (if ko then "%s (%s) 첨부 준비 · 글에 붙일 파일 %s개"
              else "attached %s (%s) · %s staged for the post")
             (Filename.basename path)
             (T.board_upload_kind_to_wire sa_kind)
             (Masc_tui_value.Count.grouped (List.length state.T.board_compose_attachments)))

(* While the attach path is being typed it owns the compose keys: Enter
   stages, Esc cancels, printable keys are path text. Tab keeps its global
   meaning, the rule the draft itself keeps. *)
let handle_board_attach_input_key (state : T.state) (input : Buffer.t) (key : string) : bool =
  match key with
  | "\r" | "\n" | "enter" ->
      stage_board_compose_path state (Buffer.contents input);
      true
  | "esc" ->
      state.T.board_compose_attach_input <- None;
      state.T.board_post_error <- None;
      Masc_tui_loader.report_action state "system" (attach_cancelled state);
      true
  | "\127" | "\b" | "backspace" ->
      let next =
        Buffer.contents input
        |> Masc_tui_message_layout.drop_last_utf8_scalar
      in
      Buffer.clear input;
      Buffer.add_string input next;
      true
  | "\t" | "shift-tab" -> false
  | s when Masc_tui_message_layout.is_printable_utf8_scalar s ->
      Buffer.add_string input s;
      true
  | _ -> true

(* A second send while one is out is refused; the draft stays. *)
let send_in_flight state =
  T.ui_text state ~ko:"이미 보내는 중" ~en:"a send is already in flight"

(* Without the terminal hand-off pair the editor cannot take the screen. *)
let editor_not_here state =
  T.ui_text state ~ko:"여기서는 편집기를 열 수 없음" ~en:"external editor not available here"

(* Compose-mode keys. Sending is armed rather than pressed: esc offers
   send-or-discard, so a stray key during writing cannot publish. Returns
   false for keys this pane does not own, so Tab and quit keep their global
   meaning. *)
let handle_board_compose_key (state : T.state) ~mailbox ?restore ?reenter (key : string) : bool =
  match state.T.board_compose_attach_input with
  | Some input -> handle_board_attach_input_key state input key
  | None ->
  let armed_allowed =
    if Option.is_none state.T.board_compose_reply_to then
      [ "s"; "S"; "d"; "D"; "e"; "E"; "h"; "H"; "esc" ]
    else
      [ "s"; "S"; "d"; "D"; "e"; "E"; "esc" ]
  in
  if state.T.board_compose_armed && not (List.mem key armed_allowed) then
    state.T.board_compose_armed <- false;
  match key with
  | "\001" -> (
      (* Ctrl-A stages a local file: the path input takes the keys until
         Enter or Esc. The comment wire has no attachments, so a reply keeps
         its staged files parked for a new post and says so. *)
      match state.T.board_compose_reply_to with
      | Some _ ->
          Masc_tui_loader.report_action state "system"
            (T.ui_text state ~ko:"첨부는 새 글에만 · 댓글은 글자만"
               ~en:"attachments go with new posts · a comment carries text only");
          true
      | None ->
          state.T.board_compose_attach_input <- Some (Buffer.create 128);
          state.T.board_post_error <- None;
          true )
  | "\005" -> (
      match restore, reenter with
      | Some r, Some re ->
          open_board_composer_editor state ~restore:r ~reenter:re;
          true
      | Some _, None | None, (Some _ | None) ->
          state.T.board_post_error <- Some (editor_not_here state);
          true )
  | "e" | "E" when state.T.board_compose_armed -> (
      match restore, reenter with
      | Some r, Some re ->
          open_board_composer_editor state ~restore:r ~reenter:re;
          true
      | Some _, None | None, (Some _ | None) ->
          state.T.board_post_error <- Some (editor_not_here state);
          true )
  | "h" | "H" when state.T.board_compose_armed && Option.is_none state.T.board_compose_reply_to ->
      state.T.board_compose_hearth <-
        Board_hearth.next ~current:state.T.board_compose_hearth
          ~census:(T.board_census_values state);
      (* Keep armed so the operator can continue cycling hearths or press 's' to send *)
      (* The pane's own label for the hearth, with the value it now holds. *)
      Masc_tui_loader.report_action state "system"
        (T.ui_text state ~ko:"게시판: " ~en:"hearth: "
         ^ (match state.T.board_compose_hearth with
            | Some h -> "#" ^ h
            | None -> T.ui_text state ~ko:"기본" ~en:"default"));
      true
  | "esc" ->
      state.T.board_compose_armed <- not state.T.board_compose_armed;
      true
  | "s" | "S" when state.T.board_compose_armed -> (
      (* A reply sends the whole draft as one comment; a new post still
         splits title from body at the first line. *)
      match state.T.board_compose_reply_to with
      | Some post_id ->
          let content = Buffer.contents state.T.board_draft in
          if String.equal (String.trim content) "" then begin
            state.T.board_compose_armed <- false;
            state.T.board_post_error <-
              Some (T.ui_text state ~ko:"댓글이 비어 있음" ~en:"the comment is empty");
            true
          end else if T.board_write_inflight state.T.board_write then begin
            state.T.board_compose_armed <- false;
            state.T.board_post_error <- Some (send_in_flight state);
            true
          end else begin
            state.T.board_compose_armed <- false;
            let sent_draft = Buffer.contents state.T.board_draft in
            let request_id = ref () in
            let cancelled =
              P.Board_msg (P.Board_comment_done
                { request_id
                ; post_id
                ; sent_draft
                ; result =
                    Error
                      (T.Request_failed
                         (Masc_tui_board_updates.comment_outcome_unknown
                            ~ko:(state.T.ui_language = T.Lang_ko)))
                })
            in
            let on_not_run () =
              Masc_tui_board_updates.comment_launch_failed state ~request_id
            in
            Masc_tui_board_requests.start_board_comment state ~host:Masc_tui_transport.Workspace_admission.server_peer_host
              ~request_id
              ~report:(Masc_tui_loader.report_action state)
              ~launch:(fun ~deliver read ->
                let authority = state.T.workspace_authority in
                let identity = state.T.server_identity in
                let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
                Masc_tui_transport.Workspace_admission.launch_result ~operation:true ~cancelled ~on_not_run state ~mailbox
                  ~boundary_error:(fun detail -> T.Request_failed detail)
                  ~withdrawn:(fun refusal -> T.Request_withdrawn refusal) ~deliver (fun () ->
                    match Masc_tui_transport.Workspace_admission.admit_request state ~mailbox ~authority ~identity ~host ~port () with
                    | Error refusal -> Error (T.Request_withdrawn refusal)
                    | Ok () -> read ()))
              ~post_id ~content;
            true
          end
      | None ->
          let title, body =
            split_board_draft (Buffer.contents state.T.board_draft)
          in
          match String.split_on_char '\n' (String.trim title) with
          | [] | [ "" ] ->
              state.T.board_compose_armed <- false;
              state.T.board_post_error <-
                Some
                  (T.ui_text state ~ko:"첫 줄(제목)이 비어 있음"
                     ~en:"the first line (title) is empty");
              true
          | _ when T.board_write_inflight state.T.board_write ->
              state.T.board_compose_armed <- false;
              state.T.board_post_error <- Some (send_in_flight state);
              true
          | _ ->
              state.T.board_compose_armed <- false;
              Masc_tui_board_requests.start_board_post state ~host:Masc_tui_transport.Workspace_admission.server_peer_host
                ~results:mailbox.Masc_tui_transport.Workspace_admission.workspace_results
                ~admit:(fun request ->
                  Masc_tui_transport.Workspace_admission.admit_request state ~mailbox
                    ~authority:request.Board_publication.authority
                    ~identity:request.Board_publication.expected_workspace
                    ~host:request.Board_publication.host ~port:request.Board_publication.port ())
                ~report:(Masc_tui_loader.report_action state) ~title ~body
                ?hearth:state.T.board_compose_hearth ();
              true )
  | "d" | "D" when state.T.board_compose_armed ->
      Buffer.clear state.T.board_draft;
      state.T.board_compose_armed <- false;
      state.T.board_compose_hearth <- None;
      state.T.board_post_error <- None;
      (* The staged files belong to the new post being discarded. A reply
         never showed or carried them, so discarding one leaves them waiting
         for the post they were staged for. *)
      (match state.T.board_compose_reply_to with
       | Some post_id -> state.T.board_mode <- T.Board_read post_id
       | None ->
           state.T.board_compose_attachments <- [];
           state.T.board_mode <- T.Board_list);
      Masc_tui_loader.report_action state "system" "Board draft discarded";
      true
  | "\r" | "\n" | "enter" ->
      Buffer.add_char state.T.board_draft '\n';
      true
  | "\127" | "\b" | "backspace" ->
      let new_content =
        Buffer.contents state.T.board_draft
        |> Masc_tui_message_layout.drop_last_utf8_scalar
      in
      Buffer.clear state.T.board_draft;
      Buffer.add_string state.T.board_draft new_content;
      true
  | "\t" | "shift-tab" -> false
  | s when Masc_tui_message_layout.is_printable_utf8_scalar s ->
      (* The same printable test the chat draft uses: a Korean scalar is
         three bytes and one keystroke, and a control byte is neither. *)
      Buffer.add_string state.T.board_draft s;
      true
  | _ -> true
