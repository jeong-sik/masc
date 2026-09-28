type client = Codex | Claude | Antigravity | Muse
type provider = { id : string; label : string; client : client }
type model = { id : string; label : string; context : int option; tools : bool option }
type phase = Loading | Providers | Logging | Models | Capacity of model | Documented_context of model | Saving | Finished | Failed
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable cursor : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved | Start of bool | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model * int option | Close | Nothing
let create requested = {requested; generation=0; phase=Loading; providers=[]; provider=None; models=[];
  cursor=0; account_ref=None; login_id=None; revision=""; existing=[]; default_runtime_id=None; draft="";
  output=""; notice="계정 목록을 읽고 있습니다."; input_pending=false; input_sequence=0; cancel_stream=None}
let begin_attempt t provider ~existing =
  if t.provider <> Some provider then t.account_ref <- None;
  t.provider <- Some provider;
  let previous = if existing then t.account_ref else None in
  t.login_id <- None;
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
      t.providers <- providers; t.revision <- revision;
      t.existing <- existing; t.default_runtime_id <- string (field "default_runtime_id" json);
      t.cursor <- (match selected with Some i -> i | None -> 0);
      t.phase <- Providers; t.notice <- "Enter: 새 계정 로그인. 기존 계정은 e로 선택합니다."; Ok ())
  | _ -> Error "서버 계정 목록을 읽지 못했습니다."
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
let paste t text = match t.phase with
  | Logging | Capacity _ | Documented_context _ when not t.input_pending -> append_draft t (String.trim text)
  | Loading | Providers | Models | Saving | Finished | Failed | Logging | Capacity _ | Documented_context _ -> ()
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
  | (Capacity model | Documented_context model) as phase ->
    if key="\r" || key="\n" || key="enter" then
      (match int_of_string_opt t.draft with
       | Some n when n>0 ->
         t.draft<-"";
         (match phase with
          | Capacity _ -> Save (model,Some n)
          | Documented_context _ -> Save ({model with context=Some n},None)
          | Loading | Providers | Logging | Models | Saving | Finished | Failed -> Nothing)
       | _ -> t.notice<-"확인한 한도를 양의 정수로 입력하세요."; Nothing)
    else if key="backspace" || key="\127" then (t.draft<-Masc_tui_message_layout.drop_last_utf8_scalar t.draft; Nothing)
    else if String.length key=1 && key.[0]>='0' && key.[0]<='9' then (paste t key; Nothing) else Nothing
  | Loading | Saving -> Nothing
  | Providers | Models | Finished | Failed ->
    if key="up" || key="k" then (t.cursor<-max 0 (t.cursor-1); Nothing)
    else if key="down" || key="j" then (let count=if t.phase=Providers then List.length t.providers else List.length t.models in t.cursor<-min (max 0 (count-1)) (t.cursor+1); Nothing)
    else if key="r" then (if t.phase=Models then Discover else if t.phase=Finished then Refresh_saved else if Option.is_some t.login_id then Recover else Inventory)
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
         | Some model -> (match t.provider with Some {client=Muse;_} -> t.phase<-Capacity model; t.draft<-""; Nothing
           | Some _ | None -> Save (model,None)))
       | Loading | Logging | Capacity _ | Documented_context _ | Saving | Finished | Failed -> Nothing)
    else Nothing
let save_body t model bytes =
  let existing=List.map (fun id -> `Assoc ["runtime_id",`String id]) t.existing in
  let model = `Assoc (["id",`String model.id;"context",(match model.context with Some n -> `Int n | None -> `Null);"streaming",`Bool true]
    @ (match bytes with Some n -> ["max_prompt_bytes",`Int n] | None -> [])) in
  `Assoc (["revision",`String t.revision;"connections",`List [`Assoc ["source",source t;"models",`List [model]]];
    "selection",`List (existing @ [`Assoc ["connection",`Int 0;"model",`Int 0]])]
    @ (match t.default_runtime_id with None -> [] | Some id -> ["default_runtime_id",`String id]))
let hints t = match t.phase with
  | Logging -> "Enter:코드 전달  ↑↓/Tab:선택  Ctrl-D:입력 종료  Ctrl-C:취소  Esc:닫기"
  | Capacity _ -> "Muse 입력 한도(bytes)  Enter:검증 후 추가  Esc:닫기"
  | Documented_context _ -> "확인한 context 한도(tokens)  Enter:검증 후 추가  Esc:닫기"
  | Providers -> "↑↓:공급자  Enter/n:새 계정  e:기존 계정  Esc:닫기"
  | Models -> "↑↓:모델  Enter:검증 후 추가  r:목록 새로고침  e:재로그인  Esc:닫기"
  | Loading | Saving | Finished | Failed -> "r:상태 재확인  e:재로그인  n:새 계정  Esc:닫기"
let lines t =
  let rows = match t.phase with
    | Providers -> List.mapi (fun i (p:provider) -> (if i=t.cursor then "> " else "  ") ^ p.label) t.providers
    | Models -> List.mapi (fun i (m:model) -> (if i=t.cursor then "> " else "  ") ^ m.label ^ (match m.context with None->" · context 확인 필요" | Some _ -> "")) t.models
    | Logging -> String.split_on_char '\n' t.output @ ["로그인 코드: " ^ String.make (min 40 (String.length t.draft)) '*'; if t.input_pending then "입력 전달 중" else if Option.is_none t.login_id then "로그인 세션 준비 중" else "코드 입력 대기"]
    | Capacity _ -> ["Muse 입력 한도(bytes): " ^ t.draft]
    | Documented_context _ -> ["문서 또는 설정의 context 한도(tokens): " ^ t.draft]
    | Loading | Saving | Finished | Failed -> [] in
  t.notice :: rows
let visible_lines ~height t =
  if height <= 0 then [] else
  let rows = lines t in
  let skip = match t.phase with
    | Providers | Models -> max 0 (t.cursor + 2 - height)
    | Loading | Logging | Capacity _ | Documented_context _ | Saving | Finished | Failed -> max 0 (List.length rows - height) in
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
