type client = Codex | Claude | Antigravity | Muse
type provider = { id : string; label : string; client : client }
type model = { id : string; label : string; context : int option; tools : bool option }
type phase = Loading | Providers | Logging | Models | Documented_context of model | Saving | Finished | Failed
type recovery = Login_status | Refresh_configuration
type email_gap = Login_file_unreadable | Login_file_unrecognized | Email_not_reported | Email_not_displayable
type account_email = Email of string | Not_read of email_gap | Login_unfinished | Not_recorded | Unreadable
  | Unrecognized  (* the server's row for this account had a shape this TUI does not know *)
type account_emails =
  | Email_rows of { rows : (string * account_email) list; unattributed : int }
      (* [unattributed]: rows naming no listed integration, or no integration at all *)
  | Email_list_unrecognized  (* the inventory carried no readable email list *)
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable cursor : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option; mutable recovery : recovery;
  mutable account_emails : account_emails;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved | Refresh_retry | Start of bool | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model | Close | Nothing
let create requested = {requested; generation=0; phase=Loading; providers=[]; provider=None; models=[]; account_emails=Email_rows {rows=[]; unattributed=0};
  cursor=0; account_ref=None; login_id=None; revision=""; existing=[]; default_runtime_id=None; draft="";
  output=""; notice="계정 목록을 읽고 있습니다."; input_pending=false; input_sequence=0; cancel_stream=None; recovery=Login_status}
let begin_attempt t provider ~existing =
  if t.provider <> Some provider then t.account_ref <- None;
  t.provider <- Some provider;
  let previous = if existing then t.account_ref else None in
  t.login_id <- None; t.recovery <- Login_status;
  t.phase <- Logging; t.output <- ""; t.models <- []; t.draft <- ""; t.input_pending <- false;
  t.notice <- "공식 클라이언트의 안내 주소에서 로그인하세요.";
  previous
let field name = function `Assoc fields -> (match List.assoc_opt name fields with Some v -> v | None -> `Null) | _ -> `Null
let string = function `String s when s<>"" -> Some s | _ -> None
let reference json = match string json with
  | Some s when String.length s=64 && String.for_all (function 'a'..'f' | '0'..'9' -> true | _ -> false) s -> Some s
  | Some _ | None -> None
let client_of_protocol = function
  | "codex-app-server" -> Some Codex | "claude-code" -> Some Claude
  | "antigravity-cli" -> Some Antigravity | "muse-serve" -> Some Muse | _ -> None
let authentication = function
  | `String "authenticated" -> Some Authenticated
  | `String "login_completed" -> Some Login_completed
  | `String "credential_captured" -> Some Credential_captured
  | _ -> None
let email_gap = function
  | `String "source_unavailable" -> Some Login_file_unreadable
  | `String "source_unrecognized" -> Some Login_file_unrecognized
  | `String "not_reported" -> Some Email_not_reported
  | `String "invalid_email" -> Some Email_not_displayable
  | _ -> None
(* One row's email state. A row this TUI cannot read is that row's own
   [Unrecognized]; it never refuses the provider list. *)
let account_email_of_row row =
  let keys = match row with `Assoc fields -> List.sort String.compare (List.map fst fields) | _ -> [] in
  match field "state" row with
  | `String "recorded" when keys = ["email"; "integration_id"; "state"] ->
    (match field "email" row with
     | `String email when email <> "" -> Email email
     | _ -> Unrecognized)
  | `String "not_read" when keys = ["cause"; "integration_id"; "state"] ->
    (match email_gap (field "cause" row) with
     | Some gap -> Not_read gap
     | None -> Unrecognized)
  | `String "login_unfinished" when keys = ["integration_id"; "state"] -> Login_unfinished
  | `String "absent" when keys = ["integration_id"; "state"] -> Not_recorded
  | `String "unreadable" when keys = ["integration_id"; "state"] -> Unreadable
  | _ -> Unrecognized
let account_emails_of_json ~integration_ids = function
  | `List rows ->
    let attributed = List.filter_map (fun row -> match string (field "integration_id" row) with
      | Some id when List.mem id integration_ids -> Some (id, account_email_of_row row)
      | Some _ | None -> None) rows in
    let ids = List.sort_uniq String.compare (List.map fst attributed) in
    (* An account listed twice has no single state to show. *)
    let rows' = List.map (fun id -> match List.filter (fun (other, _) -> String.equal other id) attributed with
      | [ (_, email) ] -> id, email
      | _ -> id, Unrecognized) ids in
    Email_rows {rows = rows'; unattributed = List.length rows - List.length attributed}
  | _ -> Email_list_unrecognized
let email_notice = function
  | Email_rows {unattributed = 0; _} -> ""
  | Email_rows {unattributed; _} ->
    Printf.sprintf " 어느 공급자 것인지 모르는 계정 이메일 %d개는 보여 주지 않습니다." unattributed
  | Email_list_unrecognized -> " 계정 이메일 목록은 읽지 못했습니다."
let inventory t json =
  match string (field "setup_revision" json), field "integrations" json, field "runtimes" json,
        field "default_runtime_selection" json with
  | Some revision, `List rows, `List runtimes, `List selected ->
    let ids = List.filter_map (fun row -> string (field "id" row)) runtimes in
    let selected = List.map string selected in
    let existing = List.filter_map Fun.id selected in
    if (field "default_runtime_id" json<>`Null && Option.is_none (string (field "default_runtime_id" json)))
       || List.exists Option.is_none selected
       || List.length existing <> List.length (List.sort_uniq String.compare existing)
       || List.exists (fun id -> not (List.mem id ids)) existing
    then Error "기본 모델과 대체 연결의 설정 순서를 확인하지 못했습니다."
    else
    let integration_ids = List.filter_map (fun row -> string (field "id" row)) rows in
    let account_emails = account_emails_of_json ~integration_ids (field "account_emails" json) in
    let providers = List.filter_map (fun row -> match string (field "id" row), string (field "display_name" row), string (field "protocol" row) with
      | Some id, Some label, Some protocol -> Option.map (fun client -> {id;label;client}) (client_of_protocol protocol)
      | _ -> None) rows in
    let requested_client = match t.requested with
      | "codex" -> Some Codex | "claude" -> Some Claude
      | "antigravity" -> Some Antigravity | "muse" -> Some Muse | _ -> None in
    let selected = match List.find_index (fun (p:provider) -> p.id=t.requested) providers with
      | Some _ as found -> found
      | None -> List.find_index (fun (p:provider) -> Some p.client=requested_client) providers in
    if t.requested<>"" && Option.is_none selected then Error "요청한 공식 클라이언트를 찾지 못했습니다. /login으로 목록을 확인하세요."
    else (
      t.providers <- providers; t.revision <- revision; t.account_emails <- account_emails;
      t.existing <- existing; t.default_runtime_id <- string (field "default_runtime_id" json);
      t.cursor <- (match selected with Some i -> i | None -> 0);
      t.phase <- Providers;
      t.notice <- "Enter: 새 계정 로그인. 기존 계정은 e로 선택합니다." ^ email_notice account_emails; Ok ())
  | _ -> Error "서버 계정 목록을 읽지 못했습니다."
let save_failed t (model:model) message =
  t.models <- List.map (fun (existing:model) -> if existing.id=model.id then model else existing) t.models;
  t.recovery <- Refresh_configuration; t.phase <- Failed;
  t.notice <- "r로 설정을 새로 읽은 뒤 다시 저장하세요. " ^ message
let refresh_retry t result =
  let cursor = t.cursor in
  let refreshed = match result with Ok json -> inventory t json | Error _ as error -> error in
  t.cursor <- cursor;
  t.recovery <- Refresh_configuration;
  match refreshed with
  | Ok () -> t.phase <- Models; t.notice <- "최신 설정을 읽었습니다. 선택한 모델을 확인하고 Enter로 다시 저장하세요."
  | Error _ -> t.phase <- Failed; t.notice <- "최신 설정을 읽지 못했습니다. r로 다시 확인하세요."
let refresh_saved t result =
  let refreshed = match result with Ok json -> inventory t json | Error _ as error -> error in
  t.phase <- Finished;
  t.notice <- (match refreshed with
    | Ok () -> "모델의 응답과 도구 호출을 검증하고 저장했습니다."
    | Error _ -> "모델 검증과 저장은 완료했습니다. 목록을 새로 읽지 못했습니다. r로 다시 확인하세요.")
let input_response ~sequence t result =
  match result with
  | Error _ when sequence=t.input_sequence && t.input_pending ->
    t.input_pending <- false;
    t.notice <- "입력 전달 결과를 확인하지 못했습니다. 로그인 안내를 확인하고 다시 시도하세요."
  | Ok _ | Error _ -> ()
let models t json =
  match field "models" json with
  | `List rows ->
    let parsed = List.map (fun row -> match string (field "id" row) with
      | None -> None
      | Some id -> Some {id; label=(match string (field "label" row) with Some x -> x | None -> id);
        context=(match field "context" row with `Int n when n>0 -> Some n | _ -> None);
        tools=(match field "tools" row with `Bool b -> Some b | _ -> None)}) rows in
    if List.exists Option.is_none parsed then Error "모델 목록 형식이 올바르지 않습니다."
    else (t.models <- List.filter_map Fun.id parsed; t.cursor <- 0; t.phase <- Models;
      t.notice <- "Enter: 검증 후 모델 추가. 기존 기본 모델 순서는 유지됩니다."; Ok ())
  | _ -> Error "이 계정의 모델 목록을 읽지 못했습니다. r로 다시 확인하세요."
let prepared t model json = match field "model" json, field "context" json with
  | `String id, `Int n when id=model.id && n>0 ->
    t.models <- List.map (fun m -> if m.id=id then {m with context=Some n} else m) t.models;
    t.phase <- Models; t.notice <- "실행 context를 확인했습니다. Enter로 검증하고 추가하세요."; Ok ()
  | _ -> Error "모델 실행 context를 확인하지 못했습니다."
let source t = `Assoc (["integration_id", `String (match t.provider with Some p -> p.id | None -> "")]
  @ (match t.account_ref with Some r -> ["account_ref",`String r] | None -> []))
let receipt t json =
  match t.provider, string (field "integration_id" json), field "invocation_verified" json,
        reference (field "login_id" json) with
  | Some p, Some id, `Bool false, Some login_id when p.id=id && t.login_id=Some login_id ->
    let selected = reference (field "account_ref" json) in
    (match field "status" json, selected, authentication (field "authentication" json) with
     | `String "complete", Some account_ref, Some _ -> t.account_ref <- Some account_ref; Ok true
     | `String ("running" | "failed" | "cancelled" | "interrupted"), _, None
       when field "account_ref" json=`Null || Option.is_some selected ->
       t.account_ref <- selected;
       t.phase <- Failed; t.notice <- "로그인 결과를 재확인했습니다. e로 이 계정에 다시 로그인할 수 있습니다."; Ok false
     | _ -> Error "로그인 결과를 확인하지 못했습니다.")
  | _ -> Error "다른 계정의 로그인 결과입니다."
let event ~generation t message =
  if generation <> t.generation then Nothing else match message with
  | Started (id, reference) -> t.login_id <- Some id; t.account_ref <- reference; Nothing
  | Output text ->
    let text = t.output ^ text in
    (* Visible terminal tail only; this never limits or persists the login. *)
    t.output <- if String.length text>65536 then String.sub text (String.length text-65536) 65536 else text; Nothing
  | Input_ready -> t.input_pending <- false; Nothing
  | Complete (reference, authentication) ->
    t.account_ref <- Some reference; t.draft <- ""; t.phase <- Loading;
    t.notice <- (match authentication with Authenticated -> "계정 인증을 확인했습니다." | Login_completed | Credential_captured -> "로그인 자료를 받았습니다."); Discover
  | Login_failed (id, reference) ->
    t.login_id <- Some id; t.account_ref <- reference; t.phase <- Failed;
    t.draft <- ""; t.input_pending <- false;
    t.notice <- "로그인 절차를 완료하지 못했습니다. r로 상태를 확인하거나 e로 다시 로그인하세요."; Nothing
  | Login_error -> t.phase <- Failed; t.draft <- ""; t.notice <- "로그인 절차를 완료하지 못했습니다. r로 상태를 확인하세요."; Nothing
let append_draft t text =
  let value = t.draft ^ text in
  if String.is_valid_utf_8 value && String.length value <= 65536 then t.draft <- value
  else t.notice <- "입력은 유효한 UTF-8이며 한 번에 64 KiB 이하여야 합니다."
let pasted_line text =
  let length = String.length text in
  let ending =
    if String.ends_with ~suffix:"\r\n" text then 2
    else if String.ends_with ~suffix:"\r" text || String.ends_with ~suffix:"\n" text then 1
    else 0 in
  let text = String.sub text 0 (length-ending) in
  let rec printable offset =
    if offset = String.length text then true
    else
      let count = String.get_utf_8_uchar text offset |> Uchar.utf_decode_length in
      Masc_tui_message_layout.is_printable_utf8_scalar (String.sub text offset count)
      && printable (offset+count) in
  if String.is_valid_utf_8 text && printable 0 then Some text else None
let paste t text = match t.phase with
  | Logging | Documented_context _ when not t.input_pending ->
    (match pasted_line text with
     | Some text -> append_draft t text
     | None -> t.notice <- "여러 줄이나 제어 문자는 붙여넣을 수 없습니다. 한 줄을 확인해 다시 입력하세요.")
  | Loading | Providers | Models | Saving | Finished | Failed | Logging | Documented_context _ -> ()
let submit_input t json =
  t.input_sequence <- t.input_sequence + 1;
  t.input_pending <- true;
  Input (t.input_sequence, json)
let key t key =
  if key="esc" then Close else
  match t.phase with
  | Logging ->
    if key="ctrl-c" || key="\003" then Cancel
    else if t.input_pending then Nothing
    else if Option.is_none t.login_id && List.mem key
      ["\r"; "\n"; "enter"; "up"; "down"; "tab"; "\t"; "ctrl-d"; "\004"] then (
      t.notice <- "로그인 세션을 준비하고 있습니다. 안내가 도착하면 입력을 전달하세요."; Nothing)
    else if key="\r" || key="\n" || key="enter" then (
      let json = `Assoc ["kind",`String "text";"text",`String t.draft] in t.draft<-""; submit_input t json)
    else if List.mem key ["up";"down";"tab";"\t";"ctrl-d";"\004"] then (
      submit_input t (`Assoc ["kind",`String "key";"key",`String (if key="ctrl-d" || key="\004" then "eof" else if key="\t" then "tab" else key)]))
    else if key="backspace" || key="\127" then (t.draft<-Masc_tui_message_layout.drop_last_utf8_scalar t.draft; Nothing)
    else if Masc_tui_message_layout.is_printable_utf8_scalar key then (append_draft t key; Nothing)
    else Nothing
  | Documented_context model ->
    if key="\r" || key="\n" || key="enter" then
      (match int_of_string_opt t.draft with
       | Some n when n>0 ->
         t.draft<-"";
         Save {model with context=Some n}
       | _ -> t.notice<-"확인한 한도를 양의 정수로 입력하세요."; Nothing)
    else if key="backspace" || key="\127" then (t.draft<-Masc_tui_message_layout.drop_last_utf8_scalar t.draft; Nothing)
    else if String.length key=1 && key.[0]>='0' && key.[0]<='9' then (paste t key; Nothing) else Nothing
  | Loading | Saving -> Nothing
  | Providers | Models | Finished | Failed ->
    if key="up" || key="k" then (t.cursor<-max 0 (t.cursor-1); Nothing)
    else if key="down" || key="j" then (let count=if t.phase=Providers then List.length t.providers else List.length t.models in t.cursor<-min (max 0 (count-1)) (t.cursor+1); Nothing)
    else if key="r" then (if t.phase=Models then Discover else if t.phase=Finished then Refresh_saved else if t.phase=Failed && t.recovery=Refresh_configuration then Refresh_retry else if Option.is_some t.login_id then Recover else Inventory)
    else if key="n" || key="e" then Start (key="e")
    else if key="\r" || key="\n" || key="enter" then
      (match t.phase with
       | Providers -> Start false
       | Models -> (match List.nth_opt t.models t.cursor with
         | None -> Nothing | Some {tools=Some false;_} -> t.notice<-"이 모델은 도구 호출을 지원하지 않습니다."; Nothing
         | Some ({context=None;_} as model) ->
           (match t.provider with
            | Some {client=Antigravity;_} -> Prepare model
            | Some {client=(Codex | Claude);_} ->
              t.phase<-Documented_context model; t.draft<-"";
              t.notice<-"공식 문서나 CLI 설정에서 확인한 context 한도(tokens)를 입력하세요. 모르면 Esc로 닫으세요. 저장 전 응답·도구 검증을 수행합니다."; Nothing
            | Some {client=Muse;_} ->
              t.notice<-"Muse가 이 모델의 context를 보고하지 않았습니다. CLI 설정을 확인하고 r로 목록을 새로 읽으세요."; Nothing
            | None -> Nothing)
         | Some model -> Save model)
       | Loading | Logging | Documented_context _ | Saving | Finished | Failed -> Nothing)
    else Nothing
let save_body t model =
  let existing=List.map (fun id -> `Assoc ["runtime_id",`String id]) t.existing in
  let model = `Assoc ["id",`String model.id;"context",(match model.context with Some n -> `Int n | None -> `Null);"streaming",`Bool true] in
  `Assoc (["revision",`String t.revision;"connections",`List [`Assoc ["source",source t;"models",`List [model]]];
    "selection",`List (existing @ [`Assoc ["connection",`Int 0;"model",`Int 0]])]
    @ (match t.default_runtime_id with None -> [] | Some id -> ["default_runtime_id",`String id]))
let hints t = match t.phase with
  | Logging -> "Enter:코드 전달  ↑↓/Tab:선택  Ctrl-D:입력 종료  Ctrl-C:취소  Esc:닫기"
  | Documented_context _ -> "확인한 context 한도(tokens)  Enter:검증 후 추가  Esc:닫기"
  | Providers -> "↑↓:공급자  Enter/n:새 계정  e:기존 계정  Esc:닫기"
  | Models -> "↑↓:모델  Enter:검증 후 추가  r:목록 새로고침  e:재로그인  Esc:닫기"
  | Loading | Saving | Finished | Failed -> "r:상태 재확인  e:재로그인  n:새 계정  Esc:닫기"
type row = Text of string | Terminal of Masc_tui_sgr_text.line
(* A row with no entry is not a selected account (a client prototype, or a
   provider on the inherited home that setup login never records). *)
let account_suffix t (p:provider) =
  let rows = match t.account_emails with Email_rows {rows; _} -> rows | Email_list_unrecognized -> [] in
  match List.assoc_opt p.id rows with
  | Some (Email email) -> " · " ^ email
  | Some (Not_read Login_file_unreadable) -> " · 이메일 모름: 로그인 파일을 못 읽음"
  | Some (Not_read Login_file_unrecognized) -> " · 이메일 모름: 로그인 파일 형식을 모름"
  | Some (Not_read Email_not_reported) -> " · 이메일 모름: 클라이언트가 알려 주지 않음"
  | Some (Not_read Email_not_displayable) -> " · 이메일 모름: 표시할 수 없는 값"
  | Some Login_unfinished -> " · 마지막 로그인이 끝나지 않음"
  | Some Not_recorded -> " · 이메일 기록 없음"
  | Some Unreadable -> " · 이메일 기록을 읽지 못함"
  | Some Unrecognized -> " · 이메일 정보를 알아볼 수 없음"
  | None -> ""
let lines t =
  let rows = match t.phase with
    | Providers -> List.mapi (fun i (p:provider) -> Text ((if i=t.cursor then "> " else "  ") ^ p.label ^ account_suffix t p)) t.providers
    | Models -> List.mapi (fun i (m:model) -> Text ((if i=t.cursor then "> " else "  ") ^ m.label ^ (match m.context with None->" · context 확인 필요" | Some _ -> ""))) t.models
    | Logging -> List.map (fun line -> Terminal line) (Masc_tui_sgr_text.parse t.output)
      @ [Text ("로그인 코드: " ^ String.make (min 40 (String.length t.draft)) '*'); Text (if t.input_pending then "입력 전달 중" else if Option.is_none t.login_id then "로그인 세션 준비 중" else "코드 입력 대기")]
    | Documented_context _ -> [Text ("문서 또는 설정의 context 한도(tokens): " ^ t.draft)]
    | Loading | Saving | Finished | Failed -> [] in
  Text t.notice :: rows
let row_text = function Text text -> text | Terminal line -> Masc_tui_sgr_text.text line
let visible_lines ~height t =
  if height <= 0 then [] else
  let rows = lines t in
  let skip = match t.phase with
    | Providers | Models -> max 0 (t.cursor + 2 - height)
    | Loading | Logging | Documented_context _ | Saving | Finished | Failed -> max 0 (List.length rows - height) in
  List.filteri (fun index _ -> index >= skip && index < skip + height) rows
let decoder ~integration_id on_event =
  let line=Buffer.create 256 and data=Buffer.create 256 in
  let name=ref "" and ended=ref false and started=ref false in
  let emit () =
    if Buffer.length data>0 && not !ended then (
      let ev = try
        let json=Yojson.Safe.from_string (Buffer.contents data) in
        match !name with
        | "started" when not !started && field "integration_id" json=`String integration_id ->
          (match reference (field "login_id" json), field "account_ref" json with
           | Some id, selected when selected=`Null || Option.is_some (reference selected) ->
             started:=true; Started (id,reference selected)
           | _ -> Login_error)
        | "output" when !started ->
          (match field "stream" json, field "text" json with
           | `String ("stdout" | "stderr" | "terminal"), `String text -> Output text
           | _ -> Login_error)
        | "input_ready" when !started -> Input_ready
        | "error" when field "integration_id" json=`String integration_id && field "invocation_verified" json=`Bool false ->
          (match reference (field "login_id" json), field "account_ref" json with
           | Some id, selected when selected=`Null || Option.is_some (reference selected) -> Login_failed (id, reference selected)
           | _ -> Login_error)
        | "complete" when !started && field "integration_id" json=`String integration_id && field "invocation_verified" json=`Bool false ->
          (match reference (field "account_ref" json),authentication (field "authentication" json) with
           | Some r,Some a -> Complete (r,a)
           | _ -> Login_error)
        | _ -> Login_error
        with Yojson.Json_error _ -> Login_error in
      (match ev with Complete _ | Login_failed _ | Login_error -> ended:=true | Started _ | Output _ | Input_ready -> ());
      on_event ev);
    name:=""; Buffer.clear data in
  let feed chunk = String.iter (fun c ->
    if c='\n' then (
      let text=Buffer.contents line |> String.trim in Buffer.clear line;
      if text="" then emit ()
      else match String.index_opt text ':' with
        | Some n -> let key=String.sub text 0 n and value=String.sub text (n+1) (String.length text-n-1) |> String.trim in
          (match key with "event" -> name:=value | "data" ->
             if Buffer.length data>0 then Buffer.add_char data '\n'; Buffer.add_string data value
           | _ -> ())
        | None -> ())
    else Buffer.add_char line c) chunk in
  feed, (fun () -> !ended)
