type client = Codex | Claude | Antigravity | Muse
(* Whether a row of the server's list is an account: the runtime
   configuration declares one per account, and a catalog entry is the client's
   own way to add one. *)
type origin = Configured | Catalog
type provider = { id : string; label : string; client : client; origin : origin }
type model = { id : string; label : string; context : int option; tools : bool option }
(* What removing an account changes, as the setup API's removal preview lists it. *)
type removal_change =
  | Removed_table of string
  | Left_lane of { lane : string; runtime : string }
  | Left_exact_lane of { lane : string; runtime : string }
  | Left_vision of string
  | Unassigned of { keeper : string; runtime : string }
type removal =
  | Removable of { changes : removal_change list; login_store : string option }
  | Unremovable of string
(* What a save published: every selected runtime verified, or some published
   unmeasured because the provider declined for the account's usage. *)
type unverified = { runtime_id : string; code : string }
type saved =
  | Saved_verified
  | Saved_unverified of unverified * unverified list
  | Saved_partly of { unverified : unverified list; not_rechecked : string list }
(* The list opens on the clients; choosing one lists its accounts under a row
   that adds a new one. *)
type list_view = Clients | Accounts of client
type phase = Loading | Providers of list_view | Logging | Models | Documented_context of model | Saving
  | Finished of { saved : saved; refresh_failed : bool } | Failed
  | Removal of { provider : provider; revision : string; removal : removal }
type recovery = Login_status | Refresh_configuration
type email_gap = Login_file_unreadable | Login_file_unrecognized | Email_not_reported | Email_not_displayable
  | Environment_credential
type account_email = Email of string | Not_read of email_gap
  | Unrecognized  (* the server's row for this account had a shape this TUI does not know *)
type account_emails =
  | Email_rows of { rows : (string * account_email) list; unattributed : int }
      (* [unattributed]: rows naming no listed integration, or no integration at all *)
  | Email_list_unrecognized  (* the inventory carried no readable email list *)
type t = {
  requested : string; mutable generation : int; mutable phase : phase; mutable providers : provider list;
  mutable provider : provider option; mutable models : model list; mutable selected_models : string list; mutable connected_models : model list;
  mutable cursor : int;
  mutable result_scroll : int;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option; mutable recovery : recovery;
  mutable account_emails : account_emails;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Refresh_saved of saved | Refresh_retry | Select_existing of provider
  | Start of { provider : provider; existing : bool }
  | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Prepare of model | Save of model list | Close | Nothing
  | Preview_removal of { provider : provider; refused : string option }
  | Remove of { provider : provider; revision : string; login_store : string option }
  | Refresh_removed of { client : client; notice : string }
  | Refresh_list of list_view
let create requested = {requested; generation=0; phase=Loading; providers=[]; provider=None; models=[];
  selected_models=[]; connected_models=[]; account_emails=Email_rows {rows=[]; unattributed=0};
  cursor=0; result_scroll=0; account_ref=None; login_id=None; revision=""; existing=[]; default_runtime_id=None; draft="";
  output=""; notice="계정 목록을 읽고 있습니다."; input_pending=false; input_sequence=0; cancel_stream=None; recovery=Login_status}
let begin_attempt t provider ~existing =
  if t.provider <> Some provider then t.account_ref <- None;
  t.provider <- Some provider;
  let previous = if existing then t.account_ref else None in
  t.login_id <- None; t.recovery <- Login_status; t.result_scroll <- 0;
  t.phase <- Logging; t.output <- ""; t.models <- []; t.selected_models <- []; t.connected_models <- [];
  t.draft <- ""; t.input_pending <- false;
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
let origin_of_json = function
  | `String "runtime_config" -> Some Configured
  | `String "masc_integration" -> Some Catalog
  | _ -> None
let client_label = function
  | Codex -> "Codex" | Claude -> "Claude Code" | Antigravity -> "Antigravity" | Muse -> "Muse"
let client_order = [Codex; Claude; Antigravity; Muse]
let clients t = List.filter (fun client -> List.exists (fun (p:provider) -> p.client = client) t.providers) client_order
type account_row = New_account of provider | Account of provider
let accounts t client = List.filter (fun (p:provider) -> p.client = client && p.origin = Configured) t.providers
(* A login without an account reference adds a new account through any of the
   client's rows. The catalog entry is the usual one; the server leaves it out
   when runtime.toml declares a provider with the same id, and then one of the
   client's accounts carries the new login. *)
let new_account_provider t client =
  match List.find_opt (fun (p:provider) -> p.client = client && p.origin = Catalog) t.providers with
  | Some _ as catalog -> catalog
  | None -> List.nth_opt (accounts t client) 0
let account_rows t client =
  (match new_account_provider t client with Some p -> [New_account p] | None -> [])
  @ List.map (fun p -> Account p) (accounts t client)
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
  | `String "environment_credential" -> Some Environment_credential
  | _ -> None
(* One row's email state. A row this TUI cannot read is that row's own
   [Unrecognized]; it never refuses the provider list. *)
let account_email_of_row row =
  let keys = match row with `Assoc fields -> List.sort String.compare (List.map fst fields) | _ -> [] in
  match field "state" row with
  | `String "read" when keys = ["email"; "integration_id"; "state"] ->
    (match field "email" row with
     | `String email when email <> "" -> Email email
     | _ -> Unrecognized)
  | `String "not_read" when keys = ["cause"; "integration_id"; "state"] ->
    (match email_gap (field "cause" row) with
     | Some gap -> Not_read gap
     | None -> Unrecognized)
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
let account_emails_of_inventory json =
  match field "integrations" json with
  | `List rows ->
    account_emails_of_json ~integration_ids:(List.filter_map (fun row -> string (field "id" row)) rows)
      (field "account_emails" json)
  | _ -> Email_list_unrecognized
let emails_of_document json =
  let rows = field "account_emails" json in
  let integration_ids = match rows with
    | `List rows -> List.filter_map (fun row -> string (field "integration_id" row)) rows
    | _ -> [] in
  match account_emails_of_json ~integration_ids rows with
  | Email_rows {rows; unattributed} ->
    let emails = List.filter_map (function
      | id, Email email -> Some (id, email)
      | _, (Not_read _ | Unrecognized) -> None) rows in
    let unrecognized = List.length (List.filter (function
      | _, Unrecognized -> true
      | _, (Email _ | Not_read _) -> false) rows) in
    Ok (emails, unattributed + unrecognized)
  | Email_list_unrecognized -> Error "the response carries no readable account email list"
let email_notice = function
  | Email_rows {unattributed = 0; _} -> ""
  | Email_rows {unattributed; _} ->
    Printf.sprintf " 어느 공급자 것인지 모르는 계정 이메일 %d개는 보여 주지 않습니다." unattributed
  | Email_list_unrecognized -> " 계정 이메일 목록은 읽지 못했습니다."
let clients_notice = "공급자를 고르세요. Enter로 그 공급자의 계정을 봅니다."
let accounts_notice = "+ 새 계정: 새 계정 로그인. 계정을 고르면 그 계정으로 모델을 추가합니다."
let index_of equal items = List.find_index equal items |> Option.value ~default:0
let show_clients ?on t =
  t.phase <- Providers Clients;
  t.cursor <- (match on with Some client -> index_of (( = ) client) (clients t) | None -> 0);
  t.notice <- clients_notice ^ email_notice t.account_emails
let show_accounts ?on t client =
  t.phase <- Providers (Accounts client);
  (* The account row first: when a client has no catalog entry, its first
     account also carries the new-account row. *)
  let rows = account_rows t client in
  t.cursor <- (match on with
    | Some (target:provider) ->
      (match List.find_index (function Account p -> p.id = target.id | New_account _ -> false) rows with
       | Some index -> index
       | None -> index_of (function New_account p -> p.id = target.id | Account _ -> false) rows)
    | None -> 0);
  t.notice <- accounts_notice ^ email_notice t.account_emails
let focused_row t = match t.phase with
  | Providers (Accounts client) -> List.nth_opt (account_rows t client) t.cursor
  | Providers Clients | Loading | Logging | Models | Documented_context _ | Saving | Finished _ | Failed | Removal _ -> None
let focused_client t = match t.phase with
  | Providers Clients -> List.nth_opt (clients t) t.cursor
  | Providers (Accounts client) -> Some client
  | Loading | Logging | Models | Documented_context _ | Saving | Finished _ | Failed | Removal _ ->
    Option.map (fun (p:provider) -> p.client) t.provider
let requested_client = function
  | "codex" -> Some Codex | "claude" -> Some Claude
  | "antigravity" -> Some Antigravity | "muse" -> Some Muse | _ -> None
(* Whether a pending login for [p] belongs to what [/login] asked for: any
   row for a bare [/login], that row for [/login <id>], and the client's rows
   for [/login <client>]. *)
let requested_matches t (p:provider) =
  t.requested = "" || String.equal t.requested p.id
  || (not (List.exists (fun (row:provider) -> String.equal row.id t.requested) t.providers)
      && requested_client t.requested = Some p.client)
let inventory ?view t json =
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
    let account_emails = account_emails_of_inventory json in
    let providers = List.filter_map (fun row ->
      match string (field "id" row), string (field "display_name" row), string (field "protocol" row),
            origin_of_json (field "origin" row) with
      | Some id, Some label, Some protocol, Some origin ->
        Option.map (fun client -> {id;label;client;origin}) (client_of_protocol protocol)
      | _ -> None) rows in
    (* [/login <client>] opens that client's accounts; [/login <id>] opens its
       client's accounts on that row. *)
    let requested = match List.find_opt (fun (p:provider) -> p.id=t.requested) providers, requested_client t.requested with
      | Some p, _ -> Some (p.client, Some p)
      | None, Some client when List.exists (fun (p:provider) -> p.client=client) providers -> Some (client, None)
      | None, (Some _ | None) -> None in
    (* The request only decides where the list first opens. A later read
       keeps its view even after the requested account was removed. *)
    if Option.is_none view && t.requested<>"" && Option.is_none requested then
      Error "요청한 공식 클라이언트를 찾지 못했습니다. /login으로 목록을 확인하세요."
    else (
      t.providers <- providers; t.revision <- revision; t.account_emails <- account_emails;
      t.existing <- existing; t.default_runtime_id <- string (field "default_runtime_id" json);
      (match view, requested with
       | Some Clients, _ | None, None -> show_clients t
       | Some (Accounts client), _ -> show_accounts t client
       | None, Some (client, on) -> show_accounts ?on t client);
      Ok ())
  | _ -> Error "서버 계정 목록을 읽지 못했습니다."
let save_failed t message =
  t.recovery <- Refresh_configuration; t.phase <- Failed; t.result_scroll <- 0;
  (* The reason leads; the key to press is also in the hints. *)
  t.notice <- message ^ " · r로 설정을 새로 읽은 뒤 다시 저장하세요."
let refresh_retry t result =
  let cursor = t.cursor in
  let refreshed = match result with Ok json -> inventory t json | Error _ as error -> error in
  t.cursor <- cursor;
  t.recovery <- Refresh_configuration;
  match refreshed with
  | Ok () -> t.phase <- Models; t.notice <- "최신 설정을 읽었습니다. 선택한 모델을 확인하고 Enter로 다시 저장하세요."
  | Error _ -> t.phase <- Failed; t.notice <- "최신 설정을 읽지 못했습니다. r로 다시 확인하세요."
let saved_notice = function
  | Saved_verified -> "모델의 응답과 도구 호출을 검증하고 저장했습니다."
  | Saved_unverified _ -> "저장했습니다. 아래 런타임은 사용 한도에 걸려 응답·도구 검증을 못 했습니다."
  | Saved_partly { unverified = []; _ } -> "저장했습니다. 기존 연결은 그대로 유지했습니다."
  | Saved_partly { unverified = _ :: _; _ } ->
    "저장했습니다. 기존 연결은 유지했습니다. 아래 모델은 사용 한도로 검증하지 못했습니다."
(* A runtime id is two hashes and a model name, longer than what a notice row
   has left at 100 columns, so each unmeasured runtime gets its own row. *)
let saved_rows = function
  | Saved_verified -> []
  | Saved_unverified (first, rest) ->
    List.map (fun (row:unverified) -> "  " ^ row.runtime_id ^ " (" ^ row.code ^ ")") (first :: rest)
  | Saved_partly { unverified; not_rechecked = _ } ->
    List.map (fun (row:unverified) -> "  " ^ row.runtime_id ^ " (" ^ row.code ^ ")") unverified
let saved_of_json json =
  let selected = match field "runtime_ids" json with
    | `List ids -> List.filter_map string ids
    | _ -> [] in
  let unverified_rows rows =
    let parsed = List.map (fun row -> match string (field "runtime_id" row), string (field "code" row) with
      | Some runtime_id, Some code when List.mem runtime_id selected -> Some {runtime_id; code}
      | _ -> None) rows in
    if List.for_all Option.is_some parsed then Some (List.filter_map Fun.id parsed) else None in
  match field "configured" json, field "readiness" json, field "unverified" json, field "not_rechecked" json with
  | `Bool true, `String "verified", `Null, `Null -> Some Saved_verified
  | `Bool true, `String "usage_limited", `List rows, `Null ->
    (match unverified_rows rows with
     | Some (first :: rest) -> Some (Saved_unverified (first, rest))
     | Some [] | None -> None)
  | `Bool true, `String "partly_checked", `List rows, `List ids ->
    let ids = List.map string ids in
    (match unverified_rows rows with
     | Some unverified when ids <> [] && List.for_all (function
         | Some id -> List.mem id selected
         | None -> false) ids ->
       Some (Saved_partly { unverified; not_rechecked = List.filter_map Fun.id ids })
     | Some _ | None -> None)
  | _ -> None
let saved t json =
  match saved_of_json json with
  | Some saved -> t.result_scroll <- 0; t.phase <- Finished {saved; refresh_failed = false}; t.notice <- saved_notice saved; Ok saved
  | None -> Error "설정 저장 결과를 확인하지 못했습니다"
let refresh_saved t saved result =
  let refreshed = match result with Ok json -> inventory t json | Error _ as error -> error in
  t.phase <- Finished {saved; refresh_failed = Result.is_error refreshed};
  t.notice <- saved_notice saved
let input_response ~sequence t result =
  match result with
  | Error _ when sequence=t.input_sequence && t.input_pending ->
    t.input_pending <- false;
    t.notice <- "입력 전달 결과를 확인하지 못했습니다. 로그인 안내를 확인하고 다시 시도하세요."
  | Ok _ | Error _ -> ()
let models t json =
  match field "models" json with
  | `List rows ->
    let parsed = List.map (fun row -> match string (field "id" row), field "bound" row with
      | Some id, `Bool bound -> Some ({id; label=(match string (field "label" row) with Some x -> x | None -> id);
        context=(match field "context" row with `Int n when n>0 -> Some n | _ -> None);
        tools=(match field "tools" row with `Bool b -> Some b | _ -> None)}, bound)
      | _ -> None) rows in
    if List.exists Option.is_none parsed then Error "모델 목록 형식이 올바르지 않습니다."
    else (
      let available = List.filter_map (function
        | Some (model, false) -> Some model
        | Some (_, true) | None -> None) parsed in
      t.connected_models <- List.filter_map (function Some (model, true) -> Some model | Some (_, false) | None -> None) parsed;
      t.models <- available @ t.connected_models;
      t.selected_models <- List.filter_map (fun (model:model) ->
        if model.tools <> Some false && Option.is_some model.context then Some model.id else None) available;
      t.cursor <- 0; t.phase <- Models;
      t.notice <- (if available = [] && t.connected_models <> [] then
        "이 계정의 모델은 모두 연결되어 있습니다. ↑↓:확인  r:새로고침  Esc:닫기"
        else Printf.sprintf "추가할 모델 %d개 · 이미 연결된 모델 %d개. Space:선택  a:전체  Enter:검증 후 저장" (List.length available) (List.length t.connected_models));
      Ok ())
  | _ -> Error "이 계정의 모델 목록을 읽지 못했습니다. r로 다시 확인하세요."
let selected_account t provider json =
  match reference (field "account_ref" json) with
  | None -> Error "저장된 계정의 참조를 읽지 못했습니다."
  | Some account_ref ->
    t.provider <- Some provider; t.account_ref <- Some account_ref; t.login_id <- None;
    t.models <- []; t.selected_models <- []; t.connected_models <- []; Ok ()
let prepared t model json = match field "model" json, field "context" json with
  | `String id, `Int n when id=model.id && n>0 ->
    t.models <- List.map (fun m -> if m.id=id then {m with context=Some n} else m) t.models;
    t.selected_models <- id :: List.filter (fun selected -> selected <> id) t.selected_models;
    t.phase <- Models; t.notice <- "실행 context를 확인하고 모델을 선택했습니다. Enter로 검증하고 저장하세요."; Ok ()
  | _ -> Error "모델 실행 context를 확인하지 못했습니다."
let removal_change row = match string (field "kind" row) with
  | Some "table" -> Option.map (fun path -> Removed_table path) (string (field "path" row))
  | Some "lane_candidate" -> (match string (field "lane" row), string (field "runtime" row) with
    | Some lane, Some runtime -> Some (Left_lane {lane; runtime}) | _ -> None)
  | Some "exact_lane_slot" -> (match string (field "lane" row), string (field "runtime" row) with
    | Some lane, Some runtime -> Some (Left_exact_lane {lane; runtime}) | _ -> None)
  | Some "vision_runtime" -> Option.map (fun runtime -> Left_vision runtime) (string (field "runtime" row))
  | Some "assignment" -> (match string (field "keeper" row), string (field "runtime" row) with
    | Some keeper, Some runtime -> Some (Unassigned {keeper; runtime}) | _ -> None)
  | Some _ | None -> None
(* [refused] is why the server declined the last removal: the file moved or
   the account can no longer go, and this preview is the file as it is now. *)
let removal_preview t (provider:provider) ~refused json =
  let lead = match refused with Some reason -> reason ^ " · " | None -> "" in
  match field "integration_id" json, string (field "revision" json), field "state" json with
  | `String id, Some revision, `String "removable" when id=provider.id ->
    (match field "changes" json, field "login_store" json with
     | `List rows, (`Null | `String _ as store) ->
       let changes = List.map removal_change rows in
       if List.exists Option.is_none changes then Error "지울 내용의 형식이 올바르지 않습니다."
       else (
         t.phase <- Removal {provider; revision; removal = Removable {changes = List.filter_map Fun.id changes; login_store = string store}};
         t.notice <- lead ^ "Enter를 누르면 아래 내용대로 지우고 저장합니다."; Ok ())
     | _ -> Error "지울 내용의 형식이 올바르지 않습니다.")
  | `String id, Some revision, `String "refused" when id=provider.id ->
    (match string (field "reason" json) with
     | Some reason -> t.phase <- Removal {provider; revision; removal = Unremovable reason};
       t.notice <- lead ^ "이 계정은 지금 지울 수 없습니다."; Ok ()
     | None -> Error "지울 수 없는 이유를 읽지 못했습니다.")
  | _ -> Error "지울 내용을 읽지 못했습니다."
let removed_notice (provider:provider) login_store =
  provider.label ^ " 계정을 지웠습니다."
  ^ (match login_store with Some path -> " 로그인 정보는 남아 있습니다: " ^ path | None -> "")
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
  | Loading | Providers _ | Models | Saving | Finished _ | Failed | Logging | Documented_context _ | Removal _ -> ()
let submit_input t json =
  t.input_sequence <- t.input_sequence + 1;
  t.input_pending <- true;
  Input (t.input_sequence, json)
let is_connected t (model:model) =
  List.exists (fun (connected:model) -> connected.id = model.id) t.connected_models
let toggle_model t (model:model) =
  if is_connected t model then (t.notice <- model.label ^ " · 이미 연결된 모델입니다."; Nothing)
  else if List.mem model.id t.selected_models then (
    t.selected_models <- List.filter (fun id -> id <> model.id) t.selected_models;
    Nothing)
  else if model.tools = Some false then (
    t.notice <- model.label ^ " · 도구 호출 미지원"; Nothing)
  else match model.context, t.provider with
    | Some _, _ -> t.selected_models <- model.id :: t.selected_models; Nothing
    | None, Some {client=Antigravity;_} -> Prepare model
    | None, Some {client=(Codex | Claude);_} ->
      t.phase <- Documented_context model; t.draft <- "";
      t.notice <- model.label ^ " · 공식 문서나 CLI 설정에서 확인한 context 한도(tokens)를 입력하세요.";
      Nothing
    | None, Some {client=Muse;_} ->
      t.notice <- model.label ^ " · context 확인 필요. CLI 설정을 확인하고 r로 목록을 새로 읽으세요.";
      Nothing
    | None, None -> Nothing
let selected_models t =
  List.filter (fun (model:model) -> List.mem model.id t.selected_models) t.models
let key t key =
  if key="esc" then (match t.phase with
    (* Esc steps back to the list rather than closing /login: the removal is
       a question asked from it. *)
    | Removal {provider; _} -> show_accounts ~on:provider t provider.client; Nothing
    (* Esc from a client's accounts goes back to the clients. *)
    | Providers (Accounts client) -> show_clients ~on:client t; Nothing
    | Documented_context _ -> t.phase <- Models; t.draft <- ""; Nothing
    | Loading | Providers Clients | Logging | Models | Saving | Finished _ | Failed -> Close) else
  match t.phase with
  | Removal {provider; revision; removal = Removable {login_store; _}} ->
    if key="\r" || key="\n" || key="enter" then Remove {provider; revision; login_store} else Nothing
  | Removal {removal = Unremovable _; _} -> Nothing
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
         t.models <- List.map (fun (row:model) ->
           if row.id=model.id then {row with context=Some n} else row) t.models;
         t.selected_models <- model.id :: List.filter (fun id -> id <> model.id) t.selected_models;
         t.phase <- Models; t.notice <- model.label ^ " · context를 확인하고 선택했습니다.";
         Nothing
       | _ -> t.notice<-"확인한 한도를 양의 정수로 입력하세요."; Nothing)
    else if key="backspace" || key="\127" then (t.draft<-Masc_tui_message_layout.drop_last_utf8_scalar t.draft; Nothing)
    else if String.length key=1 && key.[0]>='0' && key.[0]<='9' then (paste t key; Nothing) else Nothing
  | Loading | Saving -> Nothing
  | Models when key=" " ->
    (match List.nth_opt t.models t.cursor with
     | Some model -> toggle_model t model
     | None -> Nothing)
  | Models when key="a" ->
    let eligible = List.filter (fun (model:model) -> not (is_connected t model) && model.tools <> Some false && Option.is_some model.context) t.models in
    let all_selected = List.for_all (fun (model:model) -> List.mem model.id t.selected_models) eligible in
    t.selected_models <- (if all_selected then [] else List.map (fun (model:model) -> model.id) eligible);
    Nothing
  | (Finished _ | Failed) when key="up" || key="k" ->
    t.result_scroll <- max 0 (t.result_scroll - 1); Nothing
  | (Finished _ | Failed) when key="down" || key="j" ->
    t.result_scroll <- t.result_scroll + 1; Nothing
  | Providers _ | Models | Finished _ | Failed ->
    if key="up" || key="k" then (t.cursor<-max 0 (t.cursor-1); Nothing)
    else if key="down" || key="j" then (
      let count = match t.phase with
        | Providers Clients -> List.length (clients t)
        | Providers (Accounts client) -> List.length (account_rows t client)
        | Models | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removal _ -> List.length t.models in
      t.cursor<-min (max 0 (count-1)) (t.cursor+1); Nothing)
    else if key="r" then (match t.phase with
      | Models -> Discover
      | Finished {saved; _} -> Refresh_saved saved
      | Failed when t.recovery=Refresh_configuration -> Refresh_retry
      | Providers view when Option.is_none t.login_id -> Refresh_list view
      | Providers _ | Failed | Loading | Logging | Documented_context _ | Saving | Removal _ ->
        if Option.is_some t.login_id then Recover else Inventory)
    else if key="D" then
      (match focused_row t with
       | Some (Account provider) -> Preview_removal {provider; refused = None}
       | Some (New_account _) | None -> Nothing)
    else if key="n" then
      (match t.phase with
       | Providers _ ->
         (match Option.bind (focused_client t) (new_account_provider t) with
          | Some provider -> Start {provider; existing = false}
          | None -> Nothing)
       | Models | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removal _ ->
         (match t.provider with
          | Some provider -> Start {provider; existing = false}
          | None -> t.notice <- "r로 계정 목록을 다시 읽은 뒤 계정을 고르세요."; Nothing))
    else if key="e" then
      (match t.phase with
       | Providers _ ->
         (match focused_row t with
          | Some (Account provider) -> Start {provider; existing = true}
          | Some (New_account _) | None -> Nothing)
       | Models | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removal _ ->
         (match t.provider with
          | Some provider -> Start {provider; existing = true}
          | None -> t.notice <- "r로 계정 목록을 다시 읽은 뒤 계정을 고르세요."; Nothing))
    else if key="\r" || key="\n" || key="enter" then
      (match t.phase with
       | Providers Clients ->
         (match List.nth_opt (clients t) t.cursor with
          | Some client -> show_accounts t client; Nothing
          | None -> Nothing)
       | Providers (Accounts _) ->
         (match focused_row t with
          | Some (New_account provider) -> Start {provider; existing = false}
          | Some (Account provider) -> Select_existing provider
          | None -> Nothing)
       | Models ->
         (match selected_models t with
          | [] -> t.notice <- (if List.for_all (is_connected t) t.models && t.connected_models <> [] then
              "이 계정의 모델은 모두 연결되어 있습니다. Esc로 닫으세요."
              else "선택한 모델이 없습니다. Space로 모델을 고르세요."); Nothing
          | models -> Save models)
       | Loading | Logging | Documented_context _ | Saving | Finished _ | Failed | Removal _ -> Nothing)
    else Nothing
let save_body t models =
  let existing=List.map (fun id -> `Assoc ["runtime_id",`String id]) t.existing in
  let model_rows=List.map (fun (model:model) ->
    `Assoc ["id",`String model.id;"context",(match model.context with Some n -> `Int n | None -> `Null);"streaming",`Bool true]) models in
  let selected=List.mapi (fun index _ -> `Assoc ["connection",`Int 0;"model",`Int index]) models in
  `Assoc (["revision",`String t.revision;"connections",`List [`Assoc ["source",source t;"models",`List model_rows]];
    "selection",`List (existing @ selected)]
    @ (match t.default_runtime_id with None -> [] | Some id -> ["default_runtime_id",`String id]))
let hints t = match t.phase with
  | Logging -> "Enter:코드 전달  ↑↓/Tab:선택  Ctrl-D:입력 종료  Ctrl-C:취소  Esc:닫기"
  | Documented_context _ -> "확인한 context 한도(tokens)  Enter:선택  Esc:모델 목록"
  | Providers Clients -> "↑↓:공급자  Enter:계정 보기  n:새 계정  Esc:닫기"
  | Providers (Accounts _) -> "↑↓:계정  Enter:선택  n:새 계정  D:지우기  Esc:공급자 목록"
  | Removal {removal = Removable _; _} -> "Enter:지우고 저장  Esc:목록으로"
  | Removal {removal = Unremovable _; _} -> "Esc:목록으로"
  | Models -> "↑↓:모델  Space:선택  a:전체  Enter:검증 후 저장  r:새로고침  Esc:닫기"
  | Finished _ | Failed -> "↑↓/j/k:결과 스크롤  r:상태 재확인  e:재로그인  n:새 계정  Esc:닫기"
  | Loading | Saving -> "r:상태 재확인  e:재로그인  n:새 계정  Esc:닫기"
type row = Text of string | Terminal of Masc_tui_sgr_text.line
(* A row with no entry runs on no account: a client prototype, an HTTP
   provider, or Antigravity without a credential file. *)
let email_state t (p:provider) =
  let rows = match t.account_emails with Email_rows {rows; _} -> rows | Email_list_unrecognized -> [] in
  match List.assoc_opt p.id rows with
  | Some (Email email) -> Some email
  | Some (Not_read Login_file_unreadable) -> Some "이메일 모름: 로그인 파일을 못 읽음"
  | Some (Not_read Login_file_unrecognized) -> Some "이메일 모름: 로그인 파일 형식을 모름"
  | Some (Not_read Email_not_reported) -> Some "이메일 모름: 클라이언트가 알려 주지 않음"
  | Some (Not_read Email_not_displayable) -> Some "이메일 모름: 표시할 수 없는 값"
  | Some (Not_read Environment_credential) -> Some "이메일 없음: 환경 변수의 인증 정보로 실행"
  | Some Unrecognized -> Some "이메일 정보를 알아볼 수 없음"
  | None -> None
let account_suffix t p = match email_state t p with Some state -> " · " ^ state | None -> ""
(* The email says which account a row is, so it leads; the label says which
   provider entry holds it. *)
let account_label t (p:provider) =
  match email_state t p with
  | Some state -> state ^ "  (" ^ p.label ^ ")"
  | None -> p.label
let describe_change = function
  | Removed_table path -> "[" ^ path ^ "]"
  | Left_lane {lane; runtime} -> "lane " ^ lane ^ " 후보에서 " ^ runtime ^ " 를 뺍니다"
  | Left_exact_lane {lane; runtime} -> "exact-output lane " ^ lane ^ " 에서 " ^ runtime ^ " 를 뺍니다"
  | Left_vision runtime -> "media_failover 에서 " ^ runtime ^ " 를 뺍니다"
  | Unassigned {keeper; runtime} -> "keeper " ^ keeper ^ " 는 " ^ runtime ^ " 대신 default 로 갑니다"
(* Everything under the notice. *)
let body_rows t =
  match t.phase with
  | Providers Clients -> List.mapi (fun i client ->
      let count = List.length (accounts t client) in
      Text ((if i=t.cursor then "> " else "  ") ^ client_label client
            ^ (if count = 0 then "" else Printf.sprintf " · 계정 %d" count))) (clients t)
  | Providers (Accounts client) -> List.mapi (fun i row ->
      Text ((if i=t.cursor then "> " else "  ")
            ^ (match row with New_account _ -> "+ 새 계정" | Account p -> account_label t p))) (account_rows t client)
  | Models -> List.mapi (fun i (m:model) ->
      let connected = is_connected t m in
      let mark = if connected then "[연결됨] " else if List.mem m.id t.selected_models then "[x] " else "[ ] " in
      let reason = if connected then "" else if m.tools = Some false then " · 도구 호출 미지원"
        else if Option.is_none m.context then " · context 확인 필요" else "" in
      Text ((if i=t.cursor then "> " else "  ") ^ mark ^ m.label ^ reason)) t.models
  | Logging -> List.map (fun line -> Terminal line) (Masc_tui_sgr_text.parse t.output)
    @ [Text ("로그인 코드: " ^ String.make (min 40 (String.length t.draft)) '*'); Text (if t.input_pending then "입력 전달 중" else if Option.is_none t.login_id then "로그인 세션 준비 중" else "코드 입력 대기")]
  | Documented_context _ -> [Text ("문서 또는 설정의 context 한도(tokens): " ^ t.draft)]
  | Removal {provider; removal; _} -> Text ("지울 계정: " ^ provider.label ^ account_suffix t provider) ::
    (match removal with
     | Removable {changes; login_store} -> Text "지우거나 고치는 것:" :: List.map (fun change -> Text ("  " ^ describe_change change)) changes
       @ (match login_store with Some path -> [Text ("로그인 정보는 지우지 않습니다: " ^ path)] | None -> [])
     | Unremovable reason -> [Text ("지울 수 없습니다: " ^ reason)])
  | Finished {saved; refresh_failed} -> List.map (fun row -> Text row) (saved_rows saved)
    @ (if refresh_failed then [Text "목록을 새로 읽지 못했습니다. r로 다시 확인하세요."] else [])
  | Loading | Saving | Failed -> []
let lines t = Text t.notice :: body_rows t
let row_text = function Text text -> text | Terminal line -> Masc_tui_sgr_text.text line
(* The notice wraps rather than being cut at the pane's edge: a refused
   save's reason ends in the verification code and detail, the part that says
   what to do. *)
let visible_lines ~height ~width t =
  if height <= 0 then [] else
  let notice = match Masc_tui_message_layout.wrap_words ~max_cells:width t.notice with
    | [] -> [Text ""]
    | wrapped -> List.map (fun line -> Text line) wrapped in
  let results = match t.phase with Finished _ | Failed -> true | _ -> false in
  let body = if results then
    List.concat_map (function
      | Text text -> List.map (fun line -> Text line)
          (Masc_tui_message_layout.wrap_words ~max_cells:width text)
      | Terminal _ as row -> [row]) (body_rows t)
    else body_rows t in
  let rows = notice @ body in
  if results then (
    let count = List.length rows in
    let overflow = height >= 2 && count > height in
    let content_height = height - if overflow then 1 else 0 in
    let scroll = min (max 0 (count - content_height)) (max 0 t.result_scroll) in
    t.result_scroll <- scroll;
    let visible = List.filteri (fun index _ -> index >= scroll && index < scroll + content_height) rows in
    visible @ if overflow then
      [Text (Masc_tui_message_layout.fit_width
        (Printf.sprintf "[결과 %d-%d/%d · j/k:스크롤]" (scroll + 1)
          (min count (scroll + content_height)) count) width)]
      else [])
  else
    let skip = match t.phase with
      | Providers _ | Models -> max 0 (t.cursor + List.length notice + 1 - height)
      | Removal _ -> 0
      | Loading | Logging | Documented_context _ | Saving | Finished _ | Failed -> max 0 (List.length rows - height) in
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
