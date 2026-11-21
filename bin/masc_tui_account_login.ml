type client = Codex | Claude | Antigravity
(* Whether a row of the server's list is an account: the runtime
   configuration declares one per account, and a catalog entry is the client's
   own way to add one. *)
type origin = Configured | Catalog
type provider = { id : string; label : string; client : client; origin : origin;
  enabled : bool; setup_supported : bool }
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
  | Saved_durability_unconfirmed of saved
  | Saved_lock_release_unconfirmed of saved
  | Saved_verified
  | Saved_unverified of unverified * unverified list
  | Saved_partly of { unverified : unverified list; not_rechecked : string list }
type activation = Activating | Activation_failed of string | Activation_kept_back of string
  | Active of { exact_output_available : bool }
(* The list opens on the clients; choosing one lists its accounts under a row
   that adds a new one. *)
type account_group = { group_id : string; provider_ids : string list; runtime_ids : string list }
type list_view = Clients | Accounts of client | Account_providers of client * string list
type context_batch = {
  current : model;
  remaining : model list;
  total : int;
  completed : int;
  failed : (model * string) list;
  previous_selected : string list;
}
type phase = Loading | Providers of list_view | Logging | Models | Refreshing_models | Preparing_context of model
  | Preparing_context_batch of context_batch
  | Documented_context of model | Saving | Removing
  | Finished of { saved : saved; activation : activation; refresh_failed : bool } | Failed
  | Removal of { provider : provider; revision : string; removal : removal }
type recovery = Login_status | Refresh_configuration | Refresh_model_inventory
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
  mutable saved_scroll_max : int;
  mutable saved_runtime_ids : string list;
  mutable account_ref : string option; mutable login_id : string option;
  mutable revision : string; mutable existing : string list; mutable default_runtime_id : string option; mutable draft : string;
  mutable output : string; mutable notice : string; mutable input_pending : bool; mutable input_sequence : int;
  mutable cancel_stream : (unit -> unit) option; mutable recovery : recovery;
  mutable account_emails : account_emails;
  mutable account_groups : account_group list;
  mutable activity_started_at : float option;
  mutable failed_context_models : string list;
  mutable batch_cancelled : bool;
  mutable ko : bool;
}
type authentication = Authenticated | Login_completed | Credential_captured
type event = Started of string * string option | Output of string | Screen of string | Input_ready
  | Complete of string * authentication | Login_failed of string * string option | Login_error
type action = Inventory | Activate_saved of saved | Refresh_saved of saved | Refresh_retry | Select_existing of provider
  | Start of { provider : provider; existing : bool }
  | Input of int * Yojson.Safe.t | Cancel
  | Recover | Discover | Refresh_models | Prepare of model | Prepare_batch of context_batch | Cancel_prepare
  | Save of model list | Close | Nothing
  | Preview_removal of { provider : provider; refused : string option }
  | Remove of { provider : provider; revision : string; login_store : string option }
  | Refresh_removed of { client : client; notice : string }
  | Refresh_list of list_view
let say_for ko korean english = if ko then korean else english
let say t korean english = if t.ko then korean else english
let create ?(ko = true) requested = {requested; generation=0; phase=Loading; providers=[]; provider=None; models=[];
  selected_models=[]; connected_models=[]; account_emails=Email_rows {rows=[]; unattributed=0}; account_groups=[]; ko;
  cursor=0; result_scroll=0; saved_scroll_max=0; saved_runtime_ids=[]; account_ref=None; login_id=None; revision=""; existing=[]; default_runtime_id=None; draft="";
  output=""; notice=say_for ko "계정 목록을 읽고 있습니다." "Loading accounts."; input_pending=false; input_sequence=0; cancel_stream=None; recovery=Login_status;
  activity_started_at=None; failed_context_models=[]; batch_cancelled=false}
let text_input_active t = match t.phase with
  | Logging | Documented_context _ -> true
  | Loading | Providers _ | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
  | Saving | Removing | Finished _ | Failed | Removal _ -> false
let in_progress t = match t.phase with
  | Loading | Refreshing_models | Preparing_context _ | Preparing_context_batch _ | Saving | Removing
  | Finished { activation = Activating; _ } -> true
  | Logging -> t.input_pending || Option.is_none t.login_id
  | Providers _ | Models | Documented_context _
  | Finished { activation = (Active _ | Activation_failed _ | Activation_kept_back _); _ }
  | Failed | Removal _ -> false
let note_activity_started ~at t = t.activity_started_at <- Some at
let begin_attempt t provider ~existing =
  if t.provider <> Some provider then t.account_ref <- None;
  t.provider <- Some provider;
  let previous = if existing then t.account_ref else None in
  t.login_id <- None; t.recovery <- Login_status; t.result_scroll <- 0;
  t.saved_runtime_ids <- [];
  t.phase <- Logging; t.output <- ""; t.models <- []; t.selected_models <- []; t.connected_models <- [];
  t.draft <- ""; t.input_pending <- false; t.activity_started_at <- None; t.failed_context_models <- [];
  t.batch_cancelled <- false;
  t.notice <- say t "공식 클라이언트의 안내 주소에서 로그인하세요." "Sign in at the official client's URL.";
  previous
let field name = function `Assoc fields -> (match List.assoc_opt name fields with Some v -> v | None -> `Null) | _ -> `Null
let string = function `String s when s<>"" -> Some s | _ -> None
let reference json = match string json with
  | Some s when String.length s=64 && String.for_all (function 'a'..'f' | '0'..'9' -> true | _ -> false) s -> Some s
  | Some _ | None -> None
let client_of_protocol = function
  | "codex-app-server" -> Some Codex | "claude-code" -> Some Claude
  | "antigravity-cli" -> Some Antigravity | _ -> None
let origin_of_json = function
  | `String "runtime_config" -> Some Configured
  | `String "masc_integration" -> Some Catalog
  | _ -> None
let client_label = function
  | Codex -> "Codex" | Claude -> "Claude Code" | Antigravity -> "Antigravity"
let client_order = [Codex; Claude; Antigravity]
let clients t = List.filter (fun client -> List.exists (fun (p:provider) -> p.client = client) t.providers) client_order
type account_row = New_account of provider | Account of provider
let account_group t (provider:provider) =
  List.find_opt (fun group -> List.mem provider.id group.provider_ids) t.account_groups
let account_members t provider = match account_group t provider with
  | None -> [provider]
  | Some group -> List.filter (fun (p:provider) -> List.mem p.id group.provider_ids) t.providers
let provider_selectable (provider:provider) = provider.enabled && provider.setup_supported
let account_representative t provider =
  let members = account_members t provider in
  match List.find_opt provider_selectable members with
  | Some provider -> Some provider
  | None -> List.nth_opt members 0
let accounts t client = List.filter (fun (p:provider) ->
  p.client = client && p.origin = Configured
  && match account_representative t p with Some first -> first.id=p.id | None -> false) t.providers
let member_rows t ids = List.filter_map (fun id ->
  List.find_opt (fun (p:provider) -> p.id=id) t.providers) ids
(* A login without an account reference adds a new account through any of the
   client's rows. The catalog entry is the usual one; the server leaves it out
   when runtime.toml declares a provider with the same id, and then one of the
   client's accounts carries the new login. *)
let new_account_provider t client =
  let templates = List.filter (fun (p:provider) -> p.client=client && p.setup_supported) t.providers in
  match List.find_opt (fun (p:provider) -> p.origin = Catalog) templates with
  | Some _ as catalog -> catalog
  | None -> List.nth_opt templates 0
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
let account_emails_of_document json =
  let rows = field "account_emails" json in
  let integration_ids = match rows with
    | `List rows -> List.filter_map (fun row -> string (field "integration_id" row)) rows
    | _ -> [] in
  account_emails_of_json ~integration_ids rows
let emails_of_document json =
  match account_emails_of_document json with
  | Email_rows {rows; unattributed} ->
    let emails = List.filter_map (function
      | id, Email email -> Some (id, email)
      | _, (Not_read _ | Unrecognized) -> None) rows in
    let unrecognized = List.length (List.filter (function
      | _, Unrecognized -> true
      | _, (Email _ | Not_read _) -> false) rows) in
    Ok (emails, unattributed + unrecognized)
  | Email_list_unrecognized -> Error "the response carries no readable account email list"
let email_notice ~ko = function
  | Email_rows {unattributed = 0; _} -> ""
  | Email_rows {unattributed; _} ->
    if ko then Printf.sprintf " 어느 공급자 것인지 모르는 계정 이메일 %d개는 보여 주지 않습니다." unattributed
    else Printf.sprintf " %d unattributed account %s hidden." unattributed (if unattributed = 1 then "email is" else "emails are")
  | Email_list_unrecognized ->
    say_for ko " 계정 이메일 목록은 읽지 못했습니다." " Account email list could not be read."
let clients_notice ~ko =
  say_for ko "공급자를 고르세요. Enter로 그 공급자의 계정을 봅니다."
    "Choose a provider. Press Enter to view its accounts."
let accounts_notice ~ko =
  say_for ko "+ 새 계정: 새 계정 로그인. 계정을 고르면 그 계정으로 모델을 추가합니다."
    "+ New account: sign in to a new account. Select an account to add models."
let index_of equal items = List.find_index equal items |> Option.value ~default:0
let show_clients ?on t =
  t.phase <- Providers Clients;
  t.activity_started_at <- None;
  t.cursor <- (match on with Some client -> index_of (( = ) client) (clients t) | None -> 0);
  t.notice <- clients_notice ~ko:t.ko ^ email_notice ~ko:t.ko t.account_emails
let show_accounts ?on t client =
  t.phase <- Providers (Accounts client);
  t.activity_started_at <- None;
  (* The account row first: when a client has no catalog entry, its first
     account also carries the new-account row. *)
  let rows = account_rows t client in
  t.cursor <- (match on with
    | Some (target:provider) ->
      (match List.find_index (function Account p -> List.exists (fun (member:provider) -> member.id=target.id) (account_members t p) | New_account _ -> false) rows with
       | Some index -> index
       | None -> index_of (function New_account p -> p.id = target.id | Account _ -> false) rows)
    | None -> 0);
  t.notice <- accounts_notice ~ko:t.ko ^ email_notice ~ko:t.ko t.account_emails
let show_account_providers t client ids =
  t.phase <- Providers (Account_providers (client, ids));
  t.activity_started_at <- None;
  t.cursor <- 0;
  t.notice <- say t
    "이 계정의 공급자 연결을 고르세요. Enter/D로 선택한 연결만 지우는 내용을 확인합니다. 다른 연결과 로그인은 남습니다."
    "Choose a provider link for this account. Enter/D previews removing only that link; other links and credentials remain."
let focused_row t = match t.phase with
  | Providers (Accounts client) -> List.nth_opt (account_rows t client) t.cursor
  | Providers (Account_providers (_, ids)) -> Option.map (fun provider -> Account provider) (List.nth_opt (member_rows t ids) t.cursor)
  | Providers Clients | Loading | Logging | Models | Refreshing_models | Preparing_context _
  | Preparing_context_batch _ | Documented_context _ | Saving | Removing | Finished _ | Failed | Removal _ -> None
let focused_client t = match t.phase with
  | Providers Clients -> List.nth_opt (clients t) t.cursor
  | Providers (Accounts client) -> Some client
  | Providers (Account_providers (client, _)) -> Some client
  | Loading | Logging | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
  | Documented_context _ | Saving | Removing | Finished _ | Failed | Removal _ ->
    Option.map (fun (p:provider) -> p.client) t.provider
let requested_client = function
  | "codex" -> Some Codex | "claude" -> Some Claude
  | "antigravity" -> Some Antigravity | _ -> None
(* Whether a pending login for [p] belongs to what [/login] asked for: any
   row for a bare [/login], that row for [/login <id>], and the client's rows
   for [/login <client>]. *)
let requested_matches t (p:provider) =
  t.requested = "" || String.equal t.requested p.id
  || (not (List.exists (fun (row:provider) -> String.equal row.id t.requested) t.providers)
      && requested_client t.requested = Some p.client)
let activation_incomplete t = match t.phase with
  | Saving | Finished {activation = Activating | Activation_failed _ | Activation_kept_back _; _} -> true
  | Failed -> t.recovery = Refresh_configuration
  | Finished {activation = Active _; _}
  | Loading | Providers _ | Logging | Models | Refreshing_models | Preparing_context _
  | Preparing_context_batch _ | Documented_context _ | Removing | Removal _ -> false
let reopen_saved ~requested t =
  let recoverable = match t.phase with
    | Saving | Finished _ -> true
    | Failed -> t.recovery = Refresh_configuration
    | Loading | Providers _ | Logging | Models | Refreshing_models | Preparing_context _
    | Preparing_context_batch _ | Documented_context _ | Removing | Removal _ -> false in
  if not recoverable then None else
  let matches = match t.provider with
    | Some provider ->
      (* Catalog entries such as [codex] name a client, not a competing
         configured account. Explicit configured IDs retain precedence. *)
      let providers = List.filter (fun (row:provider) -> row.origin=Configured) t.providers in
      requested_matches {t with requested; providers} provider
    | None -> requested = "" || String.equal requested t.requested in
  if matches then Some t else None
let retain_activation t retained =
  if activation_incomplete t then t :: List.filter (fun held -> held != t) retained
  else retained
let take_saved ~requested retained =
  match List.find_map (reopen_saved ~requested) retained with
  | None -> None, retained
  | Some view -> Some view, List.filter (fun held -> held != view) retained
let groups_of_inventory ?(ko = true) providers json =
  let open Result.Syntax in
  let invalid = Error (say_for ko "계정 그룹 목록을 확인하지 못했습니다. 새로고침하세요." "Could not verify account groups. Please refresh.") in
  let strings = function
    | `List rows ->
      let values = List.filter_map string rows in
      if List.length values=List.length rows
         && List.length values=List.length (List.sort_uniq String.compare values)
      then Ok values else invalid
    | _ -> invalid in
  let rec parse seen = function
    | [] -> Ok []
    | row :: rest ->
      let* group_id = match string (field "id" row) with Some id -> Ok id | None -> invalid in
      let* provider_ids = strings (field "integration_ids" row) in
      let* runtime_ids = strings (field "runtime_ids" row) in
      let members = List.filter (fun (p:provider) -> List.mem p.id provider_ids) providers in
      let* () = match members with
        | first :: _ when List.length members=List.length provider_ids
          && List.for_all (fun (p:provider) -> p.origin=Configured && p.client=first.client) members
          && not (List.exists (fun id -> List.mem id seen) provider_ids) -> Ok ()
        | _ -> invalid in
      let* rest = parse (provider_ids @ seen) rest in
      if List.exists (fun group -> group.group_id=group_id) rest then invalid
      else Ok ({group_id;provider_ids;runtime_ids} :: rest) in
  match field "account_groups" json with
  | `Null -> Ok []
  | `List rows -> parse [] rows
  | _ -> invalid
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
    then Error (say t "기본 모델과 대체 연결의 설정 순서를 확인하지 못했습니다." "Could not verify default model and fallback order.")
    else
    let account_emails = account_emails_of_inventory json in
    let providers = List.filter_map (fun row ->
      match string (field "id" row), string (field "display_name" row), string (field "protocol" row),
            origin_of_json (field "origin" row) with
      | Some id, Some label, Some protocol, Some origin ->
        let enabled = match field "enabled" row with `Bool value -> value | `Null -> true | _ -> false in
        let setup_supported = field "setup_support" row <> `String "unsupported" in
        Option.map (fun client -> {id;label;client;origin;enabled;setup_supported}) (client_of_protocol protocol)
      | _ -> None) rows in
    let open Result.Syntax in
    let* account_groups = groups_of_inventory ~ko:t.ko providers json in
    (* [/login <client>] opens that client's accounts; [/login <id>] opens its
       client's accounts on that row. *)
    let requested = match List.find_opt (fun (p:provider) -> p.id=t.requested) providers, requested_client t.requested with
      | Some p, _ -> Some (p.client, Some p)
      | None, Some client when List.exists (fun (p:provider) -> p.client=client) providers -> Some (client, None)
      | None, (Some _ | None) -> None in
    (* The request only decides where the list first opens. A later read
       keeps its view even after the requested account was removed. *)
    if Option.is_none view && t.requested<>"" && Option.is_none requested then
      Error (say t "요청한 공식 클라이언트를 찾지 못했습니다. /login으로 목록을 확인하세요." "Requested official client not found. Run /login to view the list.")
    else (
      t.providers <- providers; t.revision <- revision; t.account_emails <- account_emails;
      t.account_groups <- account_groups;
      t.existing <- existing; t.default_runtime_id <- string (field "default_runtime_id" json);
      (match view, requested with
       | Some Clients, _ | None, None -> show_clients t
       | Some (Accounts client), _ -> show_accounts t client
       | Some (Account_providers (client, _)), _ ->
           show_accounts t client;
           t.notice <- say t
             "계정 구성이 갱신되었습니다. 계정을 다시 고른 뒤 삭제할 연결을 확인하세요."
             "Account list refreshed. Select the account again to review the link to remove."
       | None, Some (client, on) -> show_accounts ?on t client);
      Ok ())
  | _ -> Error (say t "서버 계정 목록을 읽지 못했습니다." "Could not read server account list.")
let save_failed t message =
  t.recovery <- Refresh_configuration; t.result_scroll <- 0; t.phase <- Failed; t.activity_started_at <- None;
  (* The reason leads; the key to press is also in the hints. *)
  t.notice <- message ^ say t " · r로 설정을 새로 읽은 뒤 다시 저장하세요." " · Press r to reload config, then save again."
let refresh_retry t result =
  let cursor = t.cursor in
  let refreshed = match result with Ok json -> inventory t json | Error _ as error -> error in
  t.cursor <- cursor;
  t.recovery <- Refresh_configuration;
  t.activity_started_at <- None;
  match refreshed with
  | Ok () -> t.phase <- Models; t.notice <- say t "최신 설정을 읽었습니다. 선택한 모델을 확인하고 Enter로 다시 저장하세요." "Reloaded latest config. Review your selected models and press Enter to save."
  | Error _ -> t.result_scroll <- 0; t.phase <- Failed; t.notice <- say t "최신 설정을 읽지 못했습니다. r로 다시 확인하세요." "Could not reload latest config. Press r to retry."
let saved_notice ~ko = function
  | Saved_durability_unconfirmed _ ->
    say_for ko "설정은 현재 적용됐지만 디스크 저장 내구성을 확인하지 못했습니다. 재저장하지 말고 저장소 상태를 확인하세요."
      "Settings are active, but disk durability was not confirmed. Check storage before saving again."
  | Saved_lock_release_unconfirmed _ ->
    say_for ko "설정은 저장됐지만 설정 잠금 해제를 확인하지 못했습니다. 재저장하지 말고 서버의 잠금 상태를 확인하세요."
      "Settings saved, but config lock release was not confirmed. Check server lock status before saving again."
  | Saved_verified ->
    say_for ko "모델의 응답과 도구 호출을 검증하고 저장했습니다."
      "Verified model responses and tool calling, and saved."
  | Saved_unverified _ ->
    say_for ko "저장했습니다. 아래 런타임은 사용 한도에 걸려 응답·도구 검증을 못 했습니다."
      "Saved. The runtimes below hit usage limits and could not be verified."
  | Saved_partly { unverified = []; _ } ->
    say_for ko "저장했습니다. 기존 연결은 그대로 유지했습니다."
      "Saved. Existing connections were kept."
  | Saved_partly { unverified = _ :: _; _ } ->
    say_for ko "저장했습니다. 기존 연결은 유지했습니다. 아래 모델은 사용 한도로 검증하지 못했습니다."
      "Saved. Existing connections were kept; the models below hit usage limits and were not verified."
(* A runtime id is two hashes and a model name, longer than what a notice row
   has left at 100 columns, so each unmeasured runtime gets its own row. *)
let rec saved_rows ~ko = function
  | Saved_durability_unconfirmed saved | Saved_lock_release_unconfirmed saved -> saved_notice ~ko saved :: saved_rows ~ko saved
  | Saved_verified -> []
  | Saved_unverified (first, rest) ->
    List.map (fun (row:unverified) -> "  " ^ row.runtime_id ^ " (" ^ row.code ^ ")") (first :: rest)
  | Saved_partly { unverified; not_rechecked } ->
    List.map (fun (row:unverified) -> "  " ^ row.runtime_id ^ " (" ^ row.code ^ ")") unverified
    @ List.map (fun runtime_id -> "  " ^ runtime_id ^ say_for ko " (이번 저장에서 재검증하지 않음)" " (not rechecked in this save)") not_rechecked
let saved_of_json json =
  let selected = match field "runtime_ids" json with
    | `List ids -> List.filter_map string ids
    | _ -> [] in
  let unverified_rows rows =
    let parsed = List.map (fun row -> match string (field "runtime_id" row), string (field "code" row) with
      | Some runtime_id, Some code when List.mem runtime_id selected -> Some {runtime_id; code}
      | _ -> None) rows in
    if List.for_all Option.is_some parsed then Some (List.filter_map Fun.id parsed) else None in
  let readiness = match field "configured" json, field "readiness" json, field "unverified" json, field "not_rechecked" json with
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
  | _ -> None in
  let readiness = match field "warnings" (field "commit" json), readiness with
    | `List [], saved -> saved
    | `List rows, Some saved when List.for_all (fun row ->
        field "code" row = `String "runtime_config_lock_release_unconfirmed") rows ->
        Some (Saved_lock_release_unconfirmed saved)
    | _ -> None in
  match field "durability" (field "commit" json), readiness with
  | `String "durable", Some saved -> Some saved
  | `String "unconfirmed", Some saved -> Some (Saved_durability_unconfirmed saved)
  | _ -> None
let saved t json =
  match saved_of_json json with
  | Some saved ->
    t.saved_runtime_ids <- (match field "runtime_ids" json with
      | `List ids ->
        let parsed = List.map string ids in
        if List.for_all Option.is_some parsed then
          List.filter (fun id -> not (List.mem id t.existing)) (List.filter_map Fun.id parsed)
        else []
      | _ -> []);
    t.cursor <- 0; t.result_scroll <- 0; t.activity_started_at <- None;
    t.phase <- Finished {saved; activation = Activating; refresh_failed = false}; t.notice <- saved_notice ~ko:t.ko saved; Ok saved
  | None -> Error (say t "설정 저장 결과를 확인하지 못했습니다" "Could not verify save result.")
let activation_of_result ~ko = function
  | Ok json ->
    (match field "runtime_ready" json, field "exact_output_authority_available" json,
           field "status" (field "model_setup" json) with
     | `Bool true, `Bool exact_output_available, `String "available" -> Active {exact_output_available}
     | _ -> Activation_failed (say_for ko "서버가 런타임 활성화를 확인하지 않았습니다." "Server did not confirm runtime activation."))
  (* Activation errors can contain configuration details. Keep the failed
     boundary visible without printing those details into the terminal. *)
  | Error _ -> Activation_failed (say_for ko "런타임 활성화 요청을 확인하지 못했습니다. 서버 상태와 접근 권한을 확인하세요." "Could not verify runtime activation request. Check server status and access permissions.")
let activating t saved =
  t.result_scroll <- 0;
  t.phase <- Finished {saved; activation = Activating; refresh_failed = false};
  t.cursor <- 0; t.notice <- saved_notice ~ko:t.ko saved
let activated t saved result =
  t.result_scroll <- 0;
  let activation = activation_of_result ~ko:t.ko result in
  t.phase <- Finished {saved; activation; refresh_failed = false};
  t.activity_started_at <- None;
  t.cursor <- 0; t.notice <- saved_notice ~ko:t.ko saved;
  match activation with Active _ -> true | Activating | Activation_failed _ | Activation_kept_back _ -> false
let activation_kept_back t saved notice =
  t.result_scroll <- 0;
  t.phase <- Finished {saved; activation = Activation_kept_back notice; refresh_failed = false};
  t.activity_started_at <- None;
  t.cursor <- 0; t.notice <- saved_notice ~ko:t.ko saved
let reconcile_saved_account t json =
  match t.provider, t.saved_runtime_ids, field "runtimes" json with
  | Some original, (_ :: _ as ids), `List runtimes ->
    (* The save carries the selected runtime IDs; inventory owns their
       provider relationship. Never infer an account from an ID prefix,
       email, list order, or another account retained as a default route. *)
    let owners = List.map (fun id ->
      match List.filter (fun row -> string (field "id" row) = Some id) runtimes with
      | [row] ->
        Option.bind (string (field "provider_id" row)) (fun provider_id ->
          List.find_opt (fun (p:provider) -> p.id=provider_id && p.origin=Configured
            && p.client=original.client) t.providers)
      | [] | _ :: _ :: _ -> None) ids in
    if List.for_all Option.is_some owners then
      (match List.sort_uniq (fun (a:provider) (b:provider) -> String.compare a.id b.id)
          (List.filter_map Fun.id owners) with
       | [provider] -> t.provider <- Some provider
       | [] | _ :: _ :: _ -> ())
  | None, _, _ | Some _, [], _ | Some _, _ :: _, _ -> ()
let refresh_saved t saved result =
  let activation = match t.phase with
    | Finished {activation; _} -> activation
    | Loading | Providers _ | Logging | Models | Refreshing_models | Preparing_context _
    | Preparing_context_batch _ | Documented_context _ | Saving | Removing | Failed | Removal _ ->
      Activation_failed (say t "저장한 설정의 활성화 상태를 확인하지 못했습니다." "Could not verify activation status for saved settings.") in
  let refreshed = match result with
    | Ok json -> (match inventory t json with
        | Ok () -> reconcile_saved_account t json; Ok ()
        | Error _ as error -> error)
    | Error _ as error -> error in
  t.cursor <- 0; t.result_scroll <- 0;
  t.phase <- Finished {saved; activation; refresh_failed = Result.is_error refreshed};
  t.notice <- saved_notice ~ko:t.ko saved
let refresh_saved_kept_back t saved notice =
  let activation = match t.phase with
    | Finished {activation; _} -> activation
    | Loading | Providers _ | Logging | Models | Refreshing_models | Preparing_context _
    | Preparing_context_batch _ | Documented_context _ | Saving | Removing | Failed | Removal _ ->
      Activation_failed (say t "저장한 설정의 활성화 상태를 확인하지 못했습니다." "Could not verify activation status for saved settings.") in
  t.cursor <- 0; t.result_scroll <- 0;
  t.phase <- Finished {saved; activation; refresh_failed = false};
  t.notice <- notice
let input_response ~sequence t result =
  match result with
  | Error _ when sequence=t.input_sequence && t.input_pending ->
    t.input_pending <- false;
    t.activity_started_at <- None;
    t.notice <- say t "입력 전달 결과를 확인하지 못했습니다. 로그인 안내를 확인하고 다시 시도하세요." "Could not confirm input delivery. Check the login prompt and try again."
  | Ok _ | Error _ -> ()
let models t json =
  match field "models" json with
  | `List rows ->
    let parsed = List.map (fun row -> match string (field "id" row), field "bound" row with
      | Some id, `Bool bound -> Some ({id; label=(match string (field "label" row) with Some x -> x | None -> id);
        context=(match field "context" row with `Int n when n>0 -> Some n | _ -> None);
        tools=(match field "tools" row with `Bool b -> Some b | _ -> None)}, bound)
      | _ -> None) rows in
    if List.exists Option.is_none parsed then Error (say t "모델 목록 형식이 올바르지 않습니다." "Invalid model list format.")
    else (
      let available = List.filter_map (function
        | Some (model, false) -> Some model
        | Some (_, true) | None -> None) parsed in
      t.connected_models <- List.filter_map (function Some (model, true) -> Some model | Some (_, false) | None -> None) parsed;
      t.models <- available @ t.connected_models;
      t.selected_models <- [];
      t.failed_context_models <- [];
      t.batch_cancelled <- false;
      t.activity_started_at <- None;
      t.cursor <- 0; t.phase <- Models;
      t.notice <- (if available = [] && t.connected_models <> [] then
        say t "이 계정의 모델은 모두 연결되어 있습니다. ↑↓:확인  r:새로고침  Esc:닫기"
          "All models for this account are linked. ↑↓:browse  r:refresh  Esc:close"
        else if t.ko then
          Printf.sprintf "추가할 모델 %d개 · 이미 연결된 모델 %d개. Space:선택  a:전체  Enter:검증 후 저장" (List.length available) (List.length t.connected_models)
        else
          Printf.sprintf "%d available · %d linked. Space:toggle  a:all  Enter:verify & save" (List.length available) (List.length t.connected_models));
      Ok ())
  | _ -> Error (say t "이 계정의 모델 목록을 읽지 못했습니다. r로 다시 확인하세요." "Could not read models for this account. Press r to retry.")
let refreshing_models t =
  t.recovery <- Refresh_model_inventory;
  t.phase <- Refreshing_models;
  t.notice <- say t "모델 목록을 다시 읽고 있습니다. 선택과 입력 한도는 유지됩니다." "Reloading model list. Selections and context limits are preserved."
let refreshed_models t json =
  let previous = t.models and selected = t.selected_models in
  let focused = Option.map (fun (model:model) -> model.id) (List.nth_opt previous t.cursor) in
  let open Result.Syntax in
  let* () = models t json in
  t.models <- List.map (fun (model:model) ->
    match model.context with
    | Some _ -> model
    | None ->
      (match List.find_opt (fun (old:model) -> old.id=model.id) previous with
       | Some old -> {model with context=old.context}
       | None -> model)) t.models;
  t.selected_models <- List.filter_map (fun (model:model) ->
    if List.mem model.id selected && model.tools <> Some false && Option.is_some model.context
       && not (List.exists (fun (bound:model) -> bound.id=model.id) t.connected_models)
    then Some model.id else None) t.models;
  t.cursor <- (match focused with
    | Some id -> index_of (fun (model:model) -> model.id=id) t.models
    | None -> 0);
  t.recovery <- Login_status;
  t.notice <- say t "모델 목록을 갱신했습니다. 기존 선택을 유지했습니다. 새 한도가 없는 모델은 이 창의 값을 유지합니다." "Model list refreshed. Previous selections and known context limits were preserved.";
  Ok ()
let models_refresh_failed t detail =
  t.recovery <- Refresh_model_inventory;
  t.phase <- Failed; t.result_scroll <- 0; t.activity_started_at <- None;
  t.notice <- detail ^ say t " · 선택은 유지됩니다. r로 모델 목록을 다시 읽으세요." " · Selections kept. Press r to reload models."
let selected_account t provider json =
  match reference (field "account_ref" json) with
  | None -> Error (say t "저장된 계정의 참조를 읽지 못했습니다." "Could not read saved account reference.")
  | Some account_ref ->
    t.provider <- Some provider; t.account_ref <- Some account_ref; t.login_id <- None;
    t.models <- []; t.selected_models <- []; t.connected_models <- []; t.failed_context_models <- [];
    t.batch_cancelled <- false; Ok ()
let selected_models t =
  List.filter (fun (model:model) -> List.mem model.id t.selected_models) t.models
let preparing t model =
  t.phase <- Preparing_context model;
  t.notice <- model.label ^ say t " · 입력 한도를 확인하고 있습니다." " · checking context limit."
let preparing_batch ?at t batch =
  (if batch.completed = 0 && batch.failed = [] then
     t.activity_started_at <- at
   else if Option.is_none t.activity_started_at then
     t.activity_started_at <- at);
  t.batch_cancelled <- false;
  t.phase <- Preparing_context_batch batch;
  t.cursor <- index_of (fun (model:model) -> model.id = batch.current.id) t.models;
  let step = batch.completed + List.length batch.failed + 1 in
  let failed_suffix =
    match batch.failed with
    | [] -> ""
    | rows ->
      if t.ko then Printf.sprintf ", 실패 %d" (List.length rows)
      else Printf.sprintf ", %d failed" (List.length rows)
  in
  t.notice <-
    if t.ko then
      Printf.sprintf "입력 한도 확인 중 (%d/%d%s) · %s" step batch.total failed_suffix batch.current.label
    else
      Printf.sprintf "Checking context limits (%d/%d%s) · %s" step batch.total failed_suffix batch.current.label
let prepared_batch_step t batch outcome =
  let completed, failed =
    match outcome with
    | Ok json ->
      (match field "model" json, field "context" json with
       | `String id, `Int n when id = batch.current.id && n > 0 ->
         t.models <- List.map (fun m -> if m.id = id then { m with context = Some n } else m) t.models;
         t.selected_models <- id :: List.filter (fun selected -> selected <> id) t.selected_models;
         t.failed_context_models <- List.filter (fun fid -> fid <> id) t.failed_context_models;
         batch.completed + 1, batch.failed
       | _ ->
         t.failed_context_models <-
           batch.current.id :: List.filter (fun fid -> fid <> batch.current.id) t.failed_context_models;
         batch.completed, batch.failed @ [batch.current, say t "모델 실행 context를 확인하지 못했습니다." "Could not verify model runtime context."])
    | Error detail ->
      t.failed_context_models <-
        batch.current.id :: List.filter (fun fid -> fid <> batch.current.id) t.failed_context_models;
      batch.completed, batch.failed @ [batch.current, detail]
  in
  match batch.remaining with
  | next :: rest ->
    Some { current = next; remaining = rest; total = batch.total; completed; failed; previous_selected = batch.previous_selected }
  | [] ->
    t.phase <- Models;
    t.activity_started_at <- None;
    t.batch_cancelled <- false;
    let selected_count = List.length (selected_models t) in
    t.notice <- (
      match failed with
      | [] ->
        if t.ko then
          Printf.sprintf "입력 한도를 모두 확인하고 모델 %d개를 선택했습니다. Enter로 검증하고 저장하세요."
            selected_count
        else
          Printf.sprintf "Verified all context limits and selected %s. Press Enter to verify and save."
            (Masc_tui_message_layout.count_noun selected_count "model")
      | (first_failed, first_reason) :: rest_failed ->
        let failed_count = 1 + List.length rest_failed in
        if selected_count > 0 then
          if t.ko then
            Printf.sprintf
              "입력 한도 확인 완료: 모델 %d개 선택, %d개 실패 (%s: %s). Enter로 저장하거나 Space로 다시 확인하세요."
              selected_count failed_count first_failed.label first_reason
          else
            Printf.sprintf
              "Context check finished: %s selected, %d failed (%s: %s). Press Enter to save or Space to retry."
              (Masc_tui_message_layout.count_noun selected_count "model")
              failed_count first_failed.label first_reason
        else
          if t.ko then
            Printf.sprintf
              "입력 한도 확인에 실패했습니다 (%d개, %s: %s). Space로 다시 확인하거나 r로 목록을 새로 읽으세요."
              failed_count first_failed.label first_reason
          else
            Printf.sprintf
              "Context check failed (%d, %s: %s). Press Space to retry or r to reload models."
              failed_count first_failed.label first_reason);
    None
let prepare_failed t detail =
  (match t.phase with
   | Preparing_context model ->
     t.failed_context_models <-
       model.id :: List.filter (fun fid -> fid <> model.id) t.failed_context_models
   | Preparing_context_batch batch ->
     t.failed_context_models <-
       batch.current.id :: List.filter (fun fid -> fid <> batch.current.id) t.failed_context_models
   | Loading | Providers _ | Logging | Models | Refreshing_models | Documented_context _
   | Saving | Removing | Finished _ | Failed | Removal _ -> ());
  t.phase <- Models;
  t.activity_started_at <- None;
  t.notice <- detail ^ say t " · Space로 다시 확인하거나 다른 모델을 선택하세요." " · Press Space to retry or select another model."
let prepare_interrupted t detail =
  t.phase <- Models;
  t.activity_started_at <- None;
  t.notice <- detail
let cancel_prepare t =
  let selected_count = List.length (selected_models t) in
  t.phase <- Models;
  t.activity_started_at <- None;
  t.batch_cancelled <- true;
  t.notice <-
    (if selected_count > 0 then
       if t.ko then
         Printf.sprintf "입력 한도 확인을 중단했습니다. 이미 선택된 모델 %d개는 유지됩니다." selected_count
       else
         Printf.sprintf "Stopped context limit check. %s already selected kept."
           (Masc_tui_message_layout.count_noun selected_count "model")
     else
       say t "입력 한도 확인을 중단했습니다." "Stopped context limit check.")
let prepared t model json = match field "model" json, field "context" json with
  | `String id, `Int n when id=model.id && n>0 ->
    t.models <- List.map (fun m -> if m.id=id then {m with context=Some n} else m) t.models;
    t.selected_models <- id :: List.filter (fun selected -> selected <> id) t.selected_models;
    t.failed_context_models <- List.filter (fun fid -> fid <> id) t.failed_context_models;
    t.phase <- Models; t.activity_started_at <- None;
    t.notice <- say t "실행 context를 확인하고 모델을 선택했습니다. Enter로 검증하고 저장하세요." "Confirmed runtime context and selected model. Press Enter to verify and save."; Ok ()
  | _ -> Error (say t "모델 실행 context를 확인하지 못했습니다." "Could not verify model runtime context.")
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
       if List.exists Option.is_none changes then Error (say t "지울 내용의 형식이 올바르지 않습니다." "Invalid removal preview format.")
       else (
         t.phase <- Removal {provider; revision; removal = Removable {changes = List.filter_map Fun.id changes; login_store = string store}};
         t.activity_started_at <- None;
         t.notice <- lead ^ say t "Enter를 누르면 아래 내용대로 지우고 저장합니다." "Press Enter to apply the removals below and save."; Ok ())
     | _ -> Error (say t "지울 내용의 형식이 올바르지 않습니다." "Invalid removal preview format."))
  | `String id, Some revision, `String "refused" when id=provider.id ->
    (match string (field "reason" json) with
     | Some reason -> t.phase <- Removal {provider; revision; removal = Unremovable reason};
       t.activity_started_at <- None;
       t.notice <- lead ^ say t "이 연결은 지금 지울 수 없습니다." "This link cannot be removed right now."; Ok ()
     | None -> Error (say t "지울 수 없는 이유를 읽지 못했습니다." "Could not read why removal was refused."))
  | _ -> Error (say t "지울 내용을 읽지 못했습니다." "Could not read removal preview.")
let removed_notice ?(ko = true) (provider:provider) login_store =
  (if ko then
     provider.label ^ " 연결 (" ^ provider.id ^ ")을 설정에서 지웠습니다."
   else
     "Removed " ^ provider.label ^ " link (" ^ provider.id ^ ") from configuration.")
  ^ (match login_store with
     | Some path ->
         (if ko then " 로그인 정보는 남아 있습니다: " else " Login credentials remain at: ") ^ path
     | None -> "")
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
       t.result_scroll <- 0; t.phase <- Failed; t.activity_started_at <- None; t.notice <- say t "로그인 결과를 재확인했습니다. e로 이 계정에 다시 로그인할 수 있습니다." "Rechecked login result. Press e to log in to this account again."; Ok false
     | _ -> Error (say t "로그인 결과를 확인하지 못했습니다." "Could not verify login result."))
  | _ -> Error (say t "다른 계정의 로그인 결과입니다." "Login result belongs to a different account.")
let event ~generation t message =
  if generation <> t.generation then Nothing else match message with
  | Started (id, reference) -> t.login_id <- Some id; t.account_ref <- reference; t.activity_started_at <- None; Nothing
  | Output text ->
    let text = t.output ^ text in
    (* Visible terminal tail only; this never limits or persists the login. *)
    t.output <- if String.length text>65536 then String.sub text (String.length text-65536) 65536 else text; Nothing
  | Screen text ->
    (* The server's terminal drew the whole screen; it replaces the last one. *)
    t.output <- text; Nothing
  | Input_ready -> t.input_pending <- false; t.activity_started_at <- None; Nothing
  | Complete (reference, authentication) ->
    t.account_ref <- Some reference; t.draft <- ""; t.phase <- Loading; t.activity_started_at <- None;
    t.notice <- (match authentication with
      | Authenticated -> say t "계정 인증을 확인했습니다." "Account authentication verified."
      | Login_completed | Credential_captured -> say t "로그인 자료를 받았습니다." "Login credentials received."); Discover
  | Login_failed (id, reference) ->
    t.login_id <- Some id; t.account_ref <- reference; t.result_scroll <- 0; t.phase <- Failed;
    t.draft <- ""; t.input_pending <- false; t.activity_started_at <- None;
    t.notice <- say t "로그인 절차를 완료하지 못했습니다. r로 상태를 확인하거나 e로 다시 로그인하세요." "Login did not complete. Press r to check status or e to try again."; Nothing
  | Login_error -> t.result_scroll <- 0; t.phase <- Failed; t.draft <- ""; t.activity_started_at <- None; t.notice <- say t "로그인 절차를 완료하지 못했습니다. r로 상태를 확인하세요." "Login did not complete. Press r to check status."; Nothing
let append_draft t text =
  let value = t.draft ^ text in
  if String.is_valid_utf_8 value && String.length value <= 65536 then t.draft <- value
  else t.notice <- say t "입력은 유효한 UTF-8이며 한 번에 64 KiB 이하여야 합니다." "Input must be valid UTF-8 and at most 64 KiB at once."
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
     | None -> t.notice <- say t "여러 줄이나 제어 문자는 붙여넣을 수 없습니다. 한 줄을 확인해 다시 입력하세요." "Multiline or control characters cannot be pasted. Paste a single line.")
  | Loading | Providers _ | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
  | Saving | Removing | Finished _ | Failed | Logging | Documented_context _ | Removal _ -> ()
let submit_input t json =
  t.input_sequence <- t.input_sequence + 1;
  t.input_pending <- true;
  Input (t.input_sequence, json)
let is_connected t (model:model) =
  List.exists (fun (connected:model) -> connected.id = model.id) t.connected_models
let toggle_model t (model:model) =
  t.batch_cancelled <- false;
  if is_connected t model then (t.notice <- model.label ^ say t " · 이미 연결된 모델입니다." " · already linked."; Nothing)
  else if List.mem model.id t.selected_models then (
    t.selected_models <- List.filter (fun id -> id <> model.id) t.selected_models;
    Nothing)
  else if model.tools = Some false then (
    t.notice <- model.label ^ say t " · 도구 호출 미지원" " · tools unsupported"; Nothing)
  else match model.context, t.provider with
    | Some _, _ -> t.selected_models <- model.id :: t.selected_models; Nothing
    | None, Some {client=Antigravity;_} -> Prepare model
    | None, Some {client=(Codex | Claude);_} ->
      t.phase <- Documented_context model; t.draft <- "";
      t.notice <- model.label ^ say t " · 공식 문서나 CLI 설정에서 확인한 context 한도(tokens)를 입력하세요." " · enter the documented context limit (tokens) from docs or CLI settings.";
      Nothing
    | None, None -> Nothing
let unavailable_account t (provider:provider) =
  t.notice <- (if not provider.setup_supported then
    say t "이 연결은 계정 설정을 지원하지 않습니다. 지원되는 공급자 연결을 선택하세요."
      "This link does not support account setup. Choose a supported provider link."
    else say t "이 기존 연결은 비활성 상태입니다. 활성화한 뒤 새로고침하세요. n으로 별도의 새 계정을 추가할 수 있습니다."
      "This existing link is disabled. Enable it and refresh, or press n to add a new account.");
  Nothing
let start_login t (provider:provider) ~existing =
  (* A fresh login uses a new isolated account home, so a disabled connection
     may supply its supported client command without enabling the old account.
     Reauthentication targets the existing home and requires a usable binding. *)
  if provider.setup_supported && (not existing || provider_selectable provider)
  then Start {provider;existing}
  else unavailable_account t provider
let key t key =
  if key="esc" then (match t.phase with
    (* Esc steps back to the list rather than closing /login: the removal is
       a question asked from it. *)
    | Removal {provider; _} -> show_accounts ~on:provider t provider.client; Nothing
    (* Esc from a client's accounts goes back to the clients. *)
    | Providers (Accounts client) -> show_clients ~on:client t; Nothing
    | Providers (Account_providers (client, ids)) ->
        show_accounts ?on:(List.nth_opt (member_rows t ids) 0) t client; Nothing
    | Documented_context _ -> t.phase <- Models; t.draft <- ""; Nothing
    | Loading | Providers Clients | Logging | Models | Refreshing_models | Preparing_context _
    | Preparing_context_batch _ | Saving | Removing | Finished _ | Failed -> Close) else
  match t.phase with
  | Removal {provider; revision; removal = Removable {login_store; _}} ->
    if key="\r" || key="\n" || key="enter" then Remove {provider; revision; login_store} else Nothing
  | Removal {removal = Unremovable _; _} -> Nothing
  | Logging ->
    if key="ctrl-c" || key="\003" then Cancel
    else if t.input_pending then Nothing
    else if Option.is_none t.login_id && List.mem key
      ["\r"; "\n"; "enter"; "up"; "down"; "tab"; "\t"; "ctrl-d"; "\004"] then (
      t.notice <- say t "로그인 세션을 준비하고 있습니다. 안내가 도착하면 입력을 전달하세요." "Preparing login session. Send input once the prompt appears."; Nothing)
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
         t.phase <- Models; t.notice <- model.label ^ say t " · context를 확인하고 선택했습니다." " · context confirmed and selected.";
         Nothing
       | _ -> t.notice<-say t "확인한 한도를 양의 정수로 입력하세요." "Enter the documented limit as a positive integer."; Nothing)
    else if key="backspace" || key="\127" then (t.draft<-Masc_tui_message_layout.drop_last_utf8_scalar t.draft; Nothing)
    else if String.length key=1 && key.[0]>='0' && key.[0]<='9' then (paste t key; Nothing) else Nothing
  | Preparing_context _ | Preparing_context_batch _ ->
    if key="c" || key="C" || key="ctrl-c" || key="\003" then Cancel_prepare else Nothing
  | Loading | Refreshing_models | Saving | Removing -> Nothing
  | Models when key=" " ->
    (match List.nth_opt t.models t.cursor with
     | Some model -> toggle_model t model
     | None -> Nothing)
  | Models when key="a" || key="A" ->
    let selectable (model:model) =
      not (is_connected t model) && model.tools <> Some false in
    let ready =
      List.filter (fun (model:model) -> selectable model && Option.is_some model.context) t.models in
    let missing_context =
      List.filter (fun (model:model) -> selectable model && Option.is_none model.context) t.models in
    let antigravity = match t.provider with
      | Some { client = Antigravity; _ } -> true
      | Some { client = (Codex | Claude); _ } | None -> false in
    let preparable =
      if antigravity then
        List.filter (fun (model:model) -> not (List.mem model.id t.failed_context_models)) missing_context
      else [] in
    let all_selected =
      ready <> [] && List.for_all (fun (model:model) -> List.mem model.id t.selected_models) ready in
    if t.batch_cancelled && all_selected then (
      t.selected_models <- [];
      t.batch_cancelled <- false;
      t.notice <- say t "선택을 모두 해제했습니다." "Cleared all model selections.";
      Nothing)
    else (match preparable with
     | first :: rest ->
       let previous_selected = t.selected_models in
       t.selected_models <- List.map (fun (model:model) -> model.id) ready;
       t.batch_cancelled <- false;
       Prepare_batch
         { current = first
         ; remaining = rest
         ; total = 1 + List.length rest
         ; completed = 0
         ; failed = []
         ; previous_selected
         }
     | [] ->
       t.batch_cancelled <- false;
       if ready = [] then (
         t.selected_models <- [];
         t.notice <- (
           if missing_context <> [] then
             let missing_count = List.length missing_context in
             (match t.provider with
              | Some { client = Antigravity; _ } ->
                if t.ko then
                  Printf.sprintf "입력 한도 확인에 실패한 모델 %d개가 남아 있습니다. Space로 다시 확인하거나 r로 목록을 새로 읽으세요."
                    missing_count
                else
                  Printf.sprintf "%s failed context check. Press Space to retry or r to reload models."
                    (Masc_tui_message_layout.count_noun missing_count "model")
              | Some { client = (Codex | Claude); _ } ->
                if t.ko then
                  Printf.sprintf "context 확인이 필요한 모델 %d개는 자동 선택할 수 없습니다. Space로 각 모델의 한도를 입력하세요."
                    missing_count
                else
                  Printf.sprintf "%s needing a context limit cannot be auto-selected. Press Space to enter each limit."
                    (Masc_tui_message_layout.count_noun missing_count "model")
              | None ->
                if t.ko then
                  Printf.sprintf "context가 확인된 모델이 없습니다(%d개 확인 필요). CLI 설정을 확인하고 r로 목록을 새로 읽으세요."
                    missing_count
                else
                  Printf.sprintf "No models have a verified context limit (%d need verification). Check CLI settings and press r to reload."
                    missing_count)
           else if List.for_all (is_connected t) t.models && t.connected_models <> [] then
             say t "이 계정의 모델은 모두 연결되어 있습니다. Esc로 닫으세요."
               "All models for this account are already linked. Press Esc to close."
           else
             say t "선택할 수 있는 모델이 없습니다." "No selectable models available.");
         Nothing)
       else if all_selected then (
         t.selected_models <- [];
         t.notice <- say t "선택을 모두 해제했습니다." "Cleared all model selections.";
         Nothing)
       else (
         t.selected_models <- List.map (fun (model:model) -> model.id) ready;
         let ready_count = List.length ready in
         let missing_count = List.length missing_context in
         t.notice <- (
           if missing_context = [] then
             if t.ko then
               Printf.sprintf "모델 %d개를 모두 선택했습니다. Enter로 검증하고 저장하세요." ready_count
             else
               Printf.sprintf "Selected all %s. Press Enter to verify and save."
                 (Masc_tui_message_layout.count_noun ready_count "model")
           else
             match t.provider with
             | Some { client = Antigravity; _ } ->
               if t.ko then
                 Printf.sprintf "모델 %d개를 선택했습니다. 이전 확인에 실패한 %d개는 Space로 다시 확인하세요."
                   ready_count missing_count
               else
                 Printf.sprintf "Selected %s. Press Space to retry %d that failed context check."
                   (Masc_tui_message_layout.count_noun ready_count "model") missing_count
             | Some { client = (Codex | Claude); _ } ->
               if t.ko then
                 Printf.sprintf "모델 %d개를 선택했습니다. 나머지 %d개는 Space로 context 한도를 입력하세요."
                   ready_count missing_count
               else
                 Printf.sprintf "Selected %s. Press Space to enter context limits for the remaining %d."
                   (Masc_tui_message_layout.count_noun ready_count "model") missing_count
             | None ->
               if t.ko then
                 Printf.sprintf "모델 %d개를 선택했습니다. 나머지 %d개는 context 확인이 필요합니다(r:새로고침)."
                   ready_count missing_count
               else
                 Printf.sprintf "Selected %s. The remaining %d need context verification (r: refresh)."
                   (Masc_tui_message_layout.count_noun ready_count "model") missing_count);
         Nothing))
  | (Finished _ | Failed) when key="up" || key="k" ->
    t.result_scroll <- max 0 (t.result_scroll - 1); Nothing
  | (Finished _ | Failed) when key="down" || key="j" ->
    t.result_scroll <- min t.saved_scroll_max (t.result_scroll + 1); Nothing
  | Finished {activation = Activating; _} -> Nothing
  | Finished {saved; activation = (Activation_failed _ | Activation_kept_back _); _}
    when List.mem key ["r"; "\r"; "\n"; "enter"] -> Activate_saved saved
  | Finished {activation = (Activation_failed _ | Activation_kept_back _); _} -> Nothing
  | Providers _ | Models | Finished {activation = Active _; _} | Failed ->
    if key="up" || key="k" then (t.cursor<-max 0 (t.cursor-1); Nothing)
    else if key="down" || key="j" then (
      let count = match t.phase with
        | Providers Clients -> List.length (clients t)
        | Providers (Accounts client) -> List.length (account_rows t client)
        | Providers (Account_providers (_, ids)) -> List.length (member_rows t ids)
        | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
        | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removing | Removal _ -> List.length t.models in
      t.cursor<-min (max 0 (count-1)) (t.cursor+1); Nothing)
    else if key="r" then (match t.phase with
      | Models -> t.recovery <- Refresh_model_inventory; Refresh_models
      | Finished {saved; _} -> Refresh_saved saved
      | Failed when t.recovery=Refresh_configuration -> Refresh_retry
      | Failed when t.recovery=Refresh_model_inventory -> Refresh_models
      | Providers view when Option.is_none t.login_id -> Refresh_list view
      | Providers _ | Failed | Loading | Logging | Refreshing_models | Preparing_context _
      | Preparing_context_batch _ | Documented_context _ | Saving | Removing | Removal _ ->
        if Option.is_some t.login_id then Recover else Inventory)
    else if key="D" then
      (match focused_row t with
       | Some (Account provider) ->
         (match t.phase, account_members t provider with
          | Providers (Accounts client), (_ :: _ :: _ as members) ->
              show_account_providers t client (List.map (fun (p:provider) -> p.id) members); Nothing
          | Providers (Accounts _), ([] | [_])
          | (Providers (Clients | Account_providers _) | Loading | Logging | Models | Refreshing_models | Preparing_context _
            | Preparing_context_batch _ | Documented_context _ | Saving | Removing | Finished _ | Failed | Removal _), _ ->
              Preview_removal {provider; refused = None})
       | Some (New_account _) | None -> Nothing)
    else if key="n" then
      (match t.phase with
       | Providers _ ->
         (match Option.bind (focused_client t) (new_account_provider t) with
          | Some provider -> start_login t provider ~existing:false
          | None -> Nothing)
       | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
       | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removing | Removal _ ->
         (match t.provider with
          | Some provider -> start_login t provider ~existing:false
          | None -> t.notice <- say t "r로 계정 목록을 다시 읽은 뒤 계정을 고르세요." "Press r to reload accounts, then choose one."; Nothing))
    else if key="e" then
      (match t.phase with
       | Providers _ ->
         (match focused_row t with
          | Some (Account provider) -> start_login t provider ~existing:true
          | Some (New_account _) | None -> Nothing)
       | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _
       | Finished _ | Failed | Loading | Logging | Documented_context _ | Saving | Removing | Removal _ ->
         (match t.provider with
          | Some provider -> start_login t provider ~existing:true
          | None -> t.notice <- say t "r로 계정 목록을 다시 읽은 뒤 계정을 고르세요." "Press r to reload accounts, then choose one."; Nothing))
    else if key="\r" || key="\n" || key="enter" then
      (match t.phase with
       | Providers Clients ->
         (match List.nth_opt (clients t) t.cursor with
          | Some client -> show_accounts t client; Nothing
          | None -> Nothing)
       | Providers (Accounts _) ->
         (match focused_row t with
          | Some (New_account provider) -> start_login t provider ~existing:false
          | Some (Account provider) when provider_selectable provider -> Select_existing provider
          | Some (Account provider) -> unavailable_account t provider
          | None -> Nothing)
       | Providers (Account_providers (_, ids)) ->
         (match List.nth_opt (member_rows t ids) t.cursor with
          | Some provider -> Preview_removal {provider; refused=None}
          | None -> Nothing)
       | Models ->
         (match selected_models t with
          | [] -> t.notice <- (if List.for_all (is_connected t) t.models && t.connected_models <> [] then
              say t "이 계정의 모델은 모두 연결되어 있습니다. Esc로 닫으세요." "All models for this account are linked. Press Esc to close."
              else say t "선택한 모델이 없습니다. Space로 모델을 고르세요." "No model selected. Press Space to choose models."); Nothing
          | models -> Save models)
       | Loading | Logging | Refreshing_models | Preparing_context _ | Preparing_context_batch _
       | Documented_context _ | Saving | Removing | Finished _ | Failed | Removal _ -> Nothing)
    else Nothing
let save_body t models =
  let existing=List.map (fun id -> `Assoc ["runtime_id",`String id]) t.existing in
  let model_rows=List.map (fun (model:model) ->
    `Assoc ["id",`String model.id;"context",(match model.context with Some n -> `Int n | None -> `Null);"streaming",`Bool true]) models in
  let selected=List.mapi (fun index _ -> `Assoc ["connection",`Int 0;"model",`Int index]) models in
  `Assoc (["revision",`String t.revision;"connections",`List [`Assoc ["source",source t;"models",`List model_rows]];
    "selection",`List (existing @ selected)]
    @ (match t.default_runtime_id with None -> [] | Some id -> ["default_runtime_id",`String id]))
let under_way_mark = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way
let waiting_mark = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting
let hints ?ko t =
  let ko = Option.value ko ~default:t.ko in
  let say korean english = if ko then korean else english in
  match t.phase with
  | Logging ->
      say "Enter:코드 전달  ↑↓/Tab:선택  Ctrl-D:입력 종료  Ctrl-C:취소  Esc:닫기"
        "Enter:send code  ↑↓/Tab:select  Ctrl-D:end input  Ctrl-C:cancel  Esc:close"
  | Documented_context _ ->
      say "확인한 context 한도(tokens)  Enter:선택  Esc:모델 목록"
        "Documented context limit (tokens)  Enter:select  Esc:models"
  | Providers Clients ->
      say "↑↓:공급자  Enter:계정 보기  n:새 계정  Esc:닫기"
        "↑↓:provider  Enter:accounts  n:new account  Esc:close"
  | Providers (Accounts _) ->
      say "↑↓:계정  Enter:선택  n:새 계정  D:연결 삭제  Esc:공급자 목록"
        "↑↓:account  Enter:select  n:new account  D:remove link  Esc:providers"
  | Providers (Account_providers _) ->
      say "↑↓:공급자 연결  Enter/D:선택한 연결 삭제 미리보기  Esc:계정 목록"
        "↑↓:provider link  Enter/D:preview removal  Esc:accounts"
  | Removal {removal = Removable _; _} ->
      say "Enter:지우고 저장  Esc:목록으로" "Enter:remove & save  Esc:back"
  | Removal {removal = Unremovable _; _} ->
      say "Esc:목록으로" "Esc:back"
  | Models ->
      say "↑↓:모델  Space:선택  a:전체  Enter:검증 후 저장  r:새로고침  Esc:닫기"
        "↑↓:model  Space:toggle  a:all  Enter:verify & save  r:refresh  Esc:close"
  | Refreshing_models ->
      say (under_way_mark ^ " 모델 목록 확인 중  Esc:닫기")
        (under_way_mark ^ " Checking models  Esc:close")
  | Preparing_context _ ->
      say (under_way_mark ^ " 입력 한도 확인 중  c:중단  Esc:닫기")
        (under_way_mark ^ " Checking context limit  c:stop  Esc:close")
  | Preparing_context_batch batch ->
      let step = batch.completed + List.length batch.failed + 1 in
      say
        (Printf.sprintf "%s 입력 한도 확인 중 (%d/%d)  c:중단  Esc:닫기" under_way_mark step batch.total)
        (Printf.sprintf "%s Checking context limits (%d/%d)  c:stop  Esc:close" under_way_mark step batch.total)
  | Finished {activation = Activating; _} ->
      say ("j/k:스크롤  " ^ under_way_mark ^ " 런타임 활성화 중  Esc:닫기")
        ("j/k:scroll  " ^ under_way_mark ^ " activating runtime  Esc:close")
  | Finished {activation = (Activation_failed _ | Activation_kept_back _); _} ->
      say "j/k:스크롤  r/Enter:활성화 재시도  Esc:닫기" "j/k:scroll  r/Enter:retry activation  Esc:close"
  | Finished {activation = Active _; _} ->
      say "j/k:스크롤  r:목록 새로고침  n:새 계정  Esc:닫기" "j/k:scroll  r:refresh  n:new account  Esc:close"
  | Saving ->
      say (under_way_mark ^ " 저장 결과 대기 중 · Esc:닫기 (백그라운드에서 계속)")
        (under_way_mark ^ " Waiting for save result · Esc:close (continues in background)")
  | Failed when t.recovery=Refresh_model_inventory ->
      say "↑↓/j/k:결과 스크롤  r:모델 다시 읽기  e:재로그인  n:새 계정  Esc:닫기"
        "↑↓/j/k:scroll  r:reload models  e:re-login  n:new account  Esc:close"
  | Failed ->
      say "↑↓/j/k:결과 스크롤  r:상태 재확인  e:재로그인  n:새 계정  Esc:닫기"
        "↑↓/j/k:scroll  r:recheck  e:re-login  n:new account  Esc:close"
  | Loading ->
      say (under_way_mark ^ " 불러오는 중  Esc:닫기")
        (under_way_mark ^ " Loading  Esc:close")
  | Removing ->
      say (under_way_mark ^ " 연결 삭제 중  Esc:닫기")
        (under_way_mark ^ " Removing link  Esc:close")
type row = Text of string | Progress of string | Terminal of Masc_tui_sgr_text.line
let progress_label ~ko t =
  let say korean english = if ko then korean else english in
  match t.phase with
  | Loading -> Some (say "불러오는 중" "Loading")
  | Refreshing_models -> Some (say "목록 새로고침 중" "Refreshing")
  | Preparing_context _ -> Some (say "입력 한도 확인 중" "Checking context")
  | Preparing_context_batch batch ->
      let step = batch.completed + List.length batch.failed + 1 in
      Some (Printf.sprintf (if ko then "입력 한도 확인 %d/%d" else "Checking %d/%d") step batch.total)
  | Saving -> Some (say "검증·저장 중" "Verifying & saving")
  | Removing -> Some (say "연결 삭제 중" "Removing")
  | Finished { activation = Activating; _ } -> Some (say "런타임 활성화 중" "Activating")
  | Logging when t.input_pending -> Some (say "입력 전달 중" "Sending input")
  | Logging when Option.is_none t.login_id -> Some (say "세션 준비 중" "Preparing session")
  | Logging | Providers _ | Models | Documented_context _
  | Finished { activation = (Active _ | Activation_failed _ | Activation_kept_back _); _ }
  | Failed | Removal _ -> None
type progress_info = {
  title : string;
  detail : string option;
  started_at : float option;
  meter : (int * int * int) option;
  action_hint : string option;
  blocking : bool;
}
let progress_info ?ko t =
  let ko = Option.value ko ~default:t.ko in
  let say korean english = if ko then korean else english in
  let started_at = t.activity_started_at in
  match t.phase with
  | Loading ->
      Some
        { title = say "불러오는 중" "Loading"
        ; detail = Some (if ko then t.notice else "Waiting for setup response from server")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Esc:닫기" "Esc:close")
        ; blocking = true
        }
  | Refreshing_models ->
      Some
        { title = say "모델 목록 새로고침 중" "Refreshing model list"
        ; detail = Some (say "기존 선택과 입력 한도는 유지됩니다" "Existing selections and limits are preserved")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Esc:닫기" "Esc:close")
        ; blocking = true
        }
  | Preparing_context model ->
      Some
        { title = say "입력 한도 확인 중" "Checking context limit"
        ; detail = Some model.label
        ; started_at
        ; meter = None
        ; action_hint = Some (say "c:중단 · Esc:닫기" "c:stop · Esc:close")
        ; blocking = true
        }
  | Preparing_context_batch batch ->
      let done_steps = batch.completed + List.length batch.failed in
      Some
        { title = say "입력 한도 일괄 확인 중" "Checking context limits"
        ; detail = Some batch.current.label
        ; started_at
        ; meter = Some (done_steps, batch.total, List.length batch.failed)
        ; action_hint = Some (say "c:중단 · Esc:닫기" "c:stop · Esc:close")
        ; blocking = true
        }
  | Saving ->
      Some
        { title = say "모델 검증·저장 중" "Verifying & saving models"
        ; detail = Some (if ko then t.notice else "Verifying model responses and tool calls")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Esc:닫기 (백그라운드에서 계속)" "Esc:close (continues in background)")
        ; blocking = true
        }
  | Removing ->
      Some
        { title = say "공급자 연결 삭제 중" "Removing provider link"
        ; detail = Some (if ko then t.notice else "Deleting selected provider connection")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Esc:닫기" "Esc:close")
        ; blocking = true
        }
  | Finished { activation = Activating; _ } ->
      Some
        { title = say "런타임 활성화 중" "Activating runtime"
        ; detail = Some (say "저장된 설정을 서버 런타임에 적용하고 있습니다" "Applying saved settings to the server runtime")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Esc:닫기 (백그라운드에서 계속)" "Esc:close (continues in background)")
        ; blocking = true
        }
  | Logging when t.input_pending ->
      Some
        { title = say "입력 전달 중" "Sending input"
        ; detail = Some (say "공식 클라이언트 응답을 기다리고 있습니다" "Waiting for client acknowledgement")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Ctrl-C:취소 · Esc:닫기" "Ctrl-C:cancel · Esc:close")
        ; blocking = true
        }
  | Logging when Option.is_none t.login_id ->
      Some
        { title = say "로그인 세션 준비 중" "Preparing login session"
        ; detail = Some (say "공식 클라이언트 로그인 스트림을 열고 있습니다" "Opening official client login stream")
        ; started_at
        ; meter = None
        ; action_hint = Some (say "Ctrl-C:취소 · Esc:닫기" "Ctrl-C:cancel · Esc:close")
        ; blocking = true
        }
  | Logging | Providers _ | Models | Documented_context _
  | Finished { activation = (Active _ | Activation_failed _ | Activation_kept_back _); _ }
  | Failed | Removal _ -> None
let progress_badge ?ko ?now t =
  let ko = Option.value ko ~default:t.ko in
  match progress_label ~ko t with
  | None -> None
  | Some label ->
      let elapsed =
        match now, t.activity_started_at with
        | Some now, Some started_at -> " · " ^ Masc_tui_value.Ongoing.since ~now started_at
        | Some _, None | None, (Some _ | None) -> ""
      in
      Some (under_way_mark ^ " " ^ label ^ elapsed)
let elapsed_suffix ~ko ~now t =
  match now, t.activity_started_at with
  | Some now, Some started_at ->
      let duration = Masc_tui_value.Ongoing.since ~now started_at in
      if ko then " · " ^ duration ^ " 경과" else " · " ^ duration
  | Some _, None | None, (Some _ | None) -> ""
let notice_in_progress t =
  match t.phase with
  | Loading | Refreshing_models | Preparing_context _ | Preparing_context_batch _
  | Saving | Removing -> true
  | Logging | Providers _ | Models | Documented_context _
  | Finished _ | Failed | Removal _ -> false
let strip_trailing_period text =
  if String.ends_with ~suffix:"." text then
    String.sub text 0 (String.length text - 1)
  else text
let notice_text ~ko ~now t =
  if notice_in_progress t then
    let suffix = elapsed_suffix ~ko ~now t in
    let base = if suffix <> "" then strip_trailing_period t.notice else t.notice in
    under_way_mark ^ " " ^ base ^ suffix
  else t.notice
(* A row with no entry runs on no account: a client prototype, an HTTP
   provider, or Antigravity without a credential file. *)
let email_state ~ko t (p:provider) =
  let say korean english = if ko then korean else english in
  let rows = match t.account_emails with Email_rows {rows; _} -> rows | Email_list_unrecognized -> [] in
  match List.assoc_opt p.id rows with
  | Some (Email email) -> Some email
  | Some (Not_read Login_file_unreadable) -> Some (say "이메일 모름: 로그인 파일을 못 읽음" "Email unknown: login file unreadable")
  | Some (Not_read Login_file_unrecognized) -> Some (say "이메일 모름: 로그인 파일 형식을 모름" "Email unknown: login file unrecognized")
  | Some (Not_read Email_not_reported) -> Some (say "이메일 모름: 클라이언트가 알려 주지 않음" "Email unknown: not reported by client")
  | Some (Not_read Email_not_displayable) -> Some (say "이메일 모름: 표시할 수 없는 값" "Email unknown: non-displayable value")
  | Some (Not_read Environment_credential) -> Some (say "이메일 없음: 환경 변수의 인증 정보로 실행" "No email: using environment credential")
  | Some Unrecognized -> Some (say "이메일 정보를 알아볼 수 없음" "Email info unrecognized")
  | None -> None
let account_suffix ~ko t p = match email_state ~ko t p with Some state -> " · " ^ state | None -> ""
(* The email says which account a row is, so it leads; the label says which
   provider entry holds it. *)
let account_label ~ko t (p:provider) =
  let say korean english = if ko then korean else english in
  let label = match account_group t p with
    | Some group when List.length group.provider_ids > 1 ->
        let links = List.length group.provider_ids in
        let models = List.length group.runtime_ids in
        let short_id = String.sub group.group_id 0 (min 8 (String.length group.group_id)) in
        if ko then
          Printf.sprintf "%s · %s · 연결 %d개 · 모델 설정 %d개"
            (client_label p.client) short_id links models
        else
          Printf.sprintf "%s · %s · %d %s · %d %s"
            (client_label p.client) short_id
            links (if links = 1 then "link" else "links")
            models (if models = 1 then "model" else "models")
    | Some group -> p.label ^ " · " ^ String.sub group.group_id 0 (min 8 (String.length group.group_id))
    | None -> p.label in
  let label =
    label
    ^ (if not p.enabled then say " · 비활성" " · disabled"
       else if not p.setup_supported then say " · 설정 미지원" " · setup unsupported"
       else "")
  in
  match email_state ~ko t p with
  | Some state -> state ^ "  (" ^ label ^ ")"
  | None -> label
let describe_change ~ko = function
  | Removed_table path -> "[" ^ path ^ "]"
  | Left_lane {lane; runtime} ->
      if ko then "lane " ^ lane ^ " 후보에서 " ^ runtime ^ " 를 뺍니다"
      else "Remove " ^ runtime ^ " from lane " ^ lane ^ " candidates"
  | Left_exact_lane {lane; runtime} ->
      if ko then "exact-output lane " ^ lane ^ " 에서 " ^ runtime ^ " 를 뺍니다"
      else "Remove " ^ runtime ^ " from exact-output lane " ^ lane
  | Left_vision runtime ->
      if ko then "media_failover 에서 " ^ runtime ^ " 를 뺍니다"
      else "Remove " ^ runtime ^ " from media_failover"
  | Unassigned {keeper; runtime} ->
      if ko then "keeper " ^ keeper ^ " 는 " ^ runtime ^ " 대신 default 로 갑니다"
      else "Keeper " ^ keeper ^ " falls back to default instead of " ^ runtime
let model_rows ~ko t =
  let say korean english = if ko then korean else english in
  let active_prepare_id, queued_ids =
    match t.phase with
    | Preparing_context active -> Some active.id, []
    | Preparing_context_batch batch ->
        Some batch.current.id, List.map (fun (m : model) -> m.id) batch.remaining
    | Loading | Providers _ | Logging | Models | Refreshing_models
    | Documented_context _ | Saving | Removing | Finished _ | Failed | Removal _ ->
        None, []
  in
  List.mapi (fun i (m:model) ->
    let selected = i = t.cursor in
    let cursor = if selected then "› " else "  " in
    let connected = is_connected t m in
    if active_prepare_id = Some m.id then
      selected, Progress (cursor ^ "[" ^ under_way_mark ^ "] " ^ m.label
                ^ say " · 입력 한도 확인 중" " · checking context")
    else if List.mem m.id queued_ids then
      selected, Text (cursor ^ "[" ^ waiting_mark ^ "] " ^ m.label
            ^ say " · 확인 대기" " · queued")
    else
      let mark =
        if connected then say "[연결됨] " "[linked] "
        else if List.mem m.id t.selected_models then "[x] "
        else "[ ] "
      in
      let reason =
        if connected then ""
        else if m.tools = Some false then say " · 도구 호출 미지원" " · tools unsupported"
        else if Option.is_none m.context then say " · context 확인 필요" " · context limit required"
        else ""
      in
      selected, Text (cursor ^ mark ^ m.label ^ reason)) t.models
(* Everything under the notice, paired with whether the row is cursor-selected. *)
let plain_row text = false, Text text
let body_rows ~ko ~now t =
  let say korean english = if ko then korean else english in
  match t.phase with
  | Providers Clients -> List.mapi (fun i client ->
      let count = List.length (accounts t client) in
      let selected = i = t.cursor in
      selected, Text ((if selected then "› " else "  ") ^ client_label client
            ^ (if count = 0 then ""
               else if ko then Printf.sprintf " · 계정 %d" count
               else Printf.sprintf " · %d %s" count (if count = 1 then "account" else "accounts")))) (clients t)
  | Providers (Accounts client) -> List.mapi (fun i row ->
      let selected = i = t.cursor in
      selected, Text ((if selected then "› " else "  ")
            ^ (match row with New_account _ -> say "+ 새 계정" "+ New account" | Account p -> account_label ~ko t p))) (account_rows t client)
  | Providers (Account_providers (_, ids)) -> List.mapi (fun i (p:provider) ->
      let selected = i = t.cursor in
      selected, Text ((if selected then "› " else "  ") ^ p.id ^ " · " ^ p.label)) (member_rows t ids)
  | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _ -> model_rows ~ko t
  | Failed when t.recovery=Refresh_model_inventory -> model_rows ~ko t
  | Logging -> List.map (fun line -> false, Terminal line) (Masc_tui_sgr_text.parse t.output)
    @ [ plain_row ((say "로그인 코드: " "Login code: ") ^ String.make (min 40 (String.length t.draft)) '*')
      ; (if t.input_pending then
           false, Progress (under_way_mark ^ " " ^ say "입력 전달 중" "Sending input" ^ elapsed_suffix ~ko ~now t)
         else if Option.is_none t.login_id then
           false, Progress (under_way_mark ^ " " ^ say "로그인 세션 준비 중" "Preparing login session" ^ elapsed_suffix ~ko ~now t)
         else plain_row (say "코드 입력 대기" "Waiting for code")) ]
  | Documented_context _ -> [plain_row ((say "문서 또는 설정의 context 한도(tokens): " "Documented context limit (tokens): ") ^ t.draft)]
  | Removal {provider; removal; _} ->
    plain_row ((say "지울 공급자 연결: " "Provider link to remove: ") ^ provider.id ^ " · " ^ provider.label ^ account_suffix ~ko t provider) ::
    (match removal with
     | Removable {changes; login_store} ->
       plain_row (say "지우거나 고치는 것:" "Changes:") :: List.map (fun change -> plain_row ("  " ^ describe_change ~ko change)) changes
       @ (match login_store with Some path -> [plain_row ((say "로그인 정보는 지우지 않습니다: " "Login credentials are kept: ") ^ path)] | None -> [])
     | Unremovable reason -> [plain_row ((say "지울 수 없습니다: " "Cannot remove: ") ^ reason)])
  | Finished {saved; activation; refresh_failed} ->
    (match activation with
     | Activating ->
       let suffix = elapsed_suffix ~ko ~now t in
       let base = say "저장 완료 · 런타임 활성화 중입니다." "Saved · activating runtime." in
       let base = if suffix <> "" then strip_trailing_period base else base in
       [false, Progress (under_way_mark ^ " " ^ base ^ suffix)]
     | Activation_failed detail ->
       [ plain_row (say "저장 완료 · 런타임 활성화 미확인" "Saved · runtime activation unconfirmed"); plain_row detail
       ; plain_row (say "r/Enter: 저장이나 로그인 없이 활성화만 다시 시도합니다." "r/Enter: retry activation without saving or re-logging in.") ]
     (* The activation was not sent: the kept-back notice, alone. *)
     | Activation_kept_back notice ->
       [ plain_row (say "저장 완료" "Saved"); plain_row notice
       ; plain_row (say "r/Enter: 저장이나 로그인 없이 활성화만 다시 시도합니다." "r/Enter: retry activation without saving or re-logging in.") ]
     | Active {exact_output_available} ->
       plain_row (say "저장한 설정을 런타임에 활성화했습니다." "Saved settings activated in runtime.") ::
       (if exact_output_available then []
        else [plain_row (say "Standalone 정확한 출력 검증 Lane은 아직 사용할 수 없습니다."
                       "Standalone exact-output verification Lane is not available yet.")]))
    @ List.map plain_row (saved_rows ~ko saved)
    @ (if refresh_failed then
         [plain_row (say "목록을 새로 읽지 못했습니다. r로 다시 확인하세요." "Could not refresh inventory. Press r to check again.")]
       else [])
  | Loading | Saving | Removing | Failed -> []
let lines ?ko ?now t =
  let ko = Option.value ko ~default:t.ko in
  let head = notice_text ~ko ~now t in
  (if notice_in_progress t then Progress head else Text head) :: List.map snd (body_rows ~ko ~now t)
let row_text = function Text text | Progress text -> text | Terminal line -> Masc_tui_sgr_text.text line
(* The notice wraps rather than being cut at the pane's edge: a refused
   save's reason ends in the verification code and detail, the part that says
   what to do. The client's own output wraps in every phase: the login
   address it prints is longer than most panes, and a cut one can be neither
   read nor copied (#52278). *)
let visible_lines_with_selection ?ko ?now ~height ~width t =
  let ko = Option.value ko ~default:t.ko in
  if height <= 0 then [], None else
  let wrap_notice_row line =
    false, (if notice_in_progress t then Progress line else Text line)
  in
  let notice = match Masc_tui_message_layout.wrap_words ~max_cells:width (notice_text ~ko ~now t) with
    | [] -> [wrap_notice_row ""]
    | wrapped -> List.map wrap_notice_row wrapped in
  let results = match t.phase with
    | Finished _ | Failed -> true
    | Loading | Providers _ | Logging | Models | Refreshing_models | Preparing_context _
    | Preparing_context_batch _ | Documented_context _ | Saving | Removing
    | Removal _ -> false in
  let body =
    List.concat_map (fun row -> match row with
      | selected, Terminal line ->
          List.map (fun line -> selected, Terminal line) (Masc_tui_sgr_text.wrap ~max_cells:width line)
      | selected, Text text when results ->
          List.map (fun line -> selected, Text line) (Masc_tui_message_layout.wrap_words ~max_cells:width text)
      | selected, Progress text when results ->
          List.map (fun line -> selected, Progress line) (Masc_tui_message_layout.wrap_words ~max_cells:width text)
      | _, (Text _ | Progress _) -> [row]) (body_rows ~ko ~now t) in
  let rows = notice @ body in
  if results then (
    let count = List.length rows in
    let content_height = max 0 height in
    t.saved_scroll_max <- max 0 (count - content_height);
    let scroll = min t.saved_scroll_max (max 0 t.result_scroll) in
    t.result_scroll <- scroll;
    let visible = List.filteri (fun index _ -> index >= scroll && index < scroll + content_height) rows in
    visible, Masc_tui_value.Position.window ~first:scroll ~shown:content_height ~total:count)
  else
    (* A list names its selected row, hidden rows or not; the other phases
       hand the window they draw when it hides rows. *)
    let window skip = Masc_tui_value.Position.window ~first:skip ~shown:height ~total:(List.length rows) in
    let skip, position = match t.phase with
      | Providers _ | Models | Refreshing_models | Preparing_context _ | Preparing_context_batch _ ->
          ( max 0 (t.cursor + List.length notice + 1 - height),
            (match body with
             | [] -> None
             | _ :: _ ->
                 Some (Masc_tui_value.Position.row ~selected:(Some t.cursor) ~total:(List.length body))) )
      | Removal _ -> 0, window 0
      | Loading | Logging | Documented_context _ | Saving | Removing | Finished _ | Failed ->
          let skip = max 0 (List.length rows - height) in
          skip, window skip in
    List.filteri (fun index _ -> index >= skip && index < skip + height) rows, position
let visible_lines ?ko ?now ~height ~width t =
  let rows, position = visible_lines_with_selection ?ko ?now ~height ~width t in
  List.map snd rows, position

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
           | `String ("stdout" | "stderr"), `String text -> Output text
           | _ -> Login_error)
        | "screen" when !started ->
          (match field "text" json with `String text -> Screen text | _ -> Login_error)
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
      (match ev with Complete _ | Login_failed _ | Login_error -> ended:=true | Started _ | Output _ | Screen _ | Input_ready -> ());
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
