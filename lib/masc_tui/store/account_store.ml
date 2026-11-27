open Masc_tui_core
open Masc_tui_protocol

type token_source =
  | Token_startup_default
  | Token_runtime_set
  | Token_runtime_cleared

let token_source_rank = function
  | Token_startup_default -> 0
  | Token_runtime_set -> 1
  | Token_runtime_cleared -> 2

let equal_token_source a b =
  Int.equal (token_source_rank a) (token_source_rank b)

type token_editor = {
  active : bool;
  draft : string;
  error : string option;
}

let empty_token_editor = { active = false; draft = ""; error = None }

type t = {
  token_source : token_source;
  token_editor : token_editor;
  provider_accounts : Wire_account.provider_accounts_snapshot Observed.t;
  integrations : Wire_account.person_integrations_snapshot Observed.t;
  own_provider_forbidden : string option;
  last_verification : (string * Wire_account.account_verify_response) option;
  selected_account_idx : int;
  scroll_offset : int;
}

let empty =
  {
    token_source = Token_startup_default;
    token_editor = empty_token_editor;
    provider_accounts = Observed.unreported;
    integrations = Observed.unreported;
    own_provider_forbidden = None;
    last_verification = None;
    selected_account_idx = 0;
    scroll_offset = 0;
  }

let sanitize_token_chunk raw =
  let len = String.length raw in
  let buf = Buffer.create len in
  for i = 0 to len - 1 do
    let c = raw.[i] in
    let code = Char.code c in
    if code >= 0x20 && code <> 0x7F then Buffer.add_char buf c
  done;
  Buffer.contents buf

let utf8_char_count s =
  let len = String.length s in
  let rec loop i acc =
    if i >= len then acc
    else
      let d = String.get_utf_8_uchar s i in
      let step = Int.max 1 (Uchar.utf_decode_length d) in
      loop (i + step) (acc + 1)
  in
  loop 0 0

let drop_last_utf8 s =
  let len = String.length s in
  if len = 0 then ""
  else
    let rec walk i prev =
      if i >= len then prev
      else
        let d = String.get_utf_8_uchar s i in
        let step = Int.max 1 (Uchar.utf_decode_length d) in
        walk (i + step) i
    in
    let cut = walk 0 0 in
    String.sub s 0 cut

let masked_draft_display (ed : token_editor) =
  let n = utf8_char_count ed.draft in
  if n = 0 then ""
  else
    let dots = Int.min 24 n in
    let buf = Buffer.create ((dots * 3) + 12) in
    for _ = 1 to dots do
      Buffer.add_string buf "•"
    done;
    Buffer.add_string buf (Printf.sprintf " (%d)" n);
    Buffer.contents buf

let open_token_editor t =
  { t with token_editor = { active = true; draft = ""; error = None } }

let close_token_editor t = { t with token_editor = empty_token_editor }

let wipe_token_draft t =
  { t with token_editor = { t.token_editor with draft = ""; error = None } }

let append_token_text raw t =
  let clean = sanitize_token_chunk raw in
  if String.equal clean "" then t
  else
    {
      t with
      token_editor =
        { t.token_editor with draft = t.token_editor.draft ^ clean; error = None };
    }

let backspace_token_text t =
  {
    t with
    token_editor =
      {
        t.token_editor with
        draft = drop_last_utf8 t.token_editor.draft;
        error = None;
      };
  }

let set_token_editor_error msg t =
  { t with token_editor = { t.token_editor with error = Some msg } }

let mark_token_runtime_set t =
  {
    t with
    token_source = Token_runtime_set;
    token_editor = empty_token_editor;
  }

let mark_token_runtime_cleared t =
  {
    t with
    token_source = Token_runtime_cleared;
    token_editor = empty_token_editor;
  }

let clamp_idx count idx =
  if count <= 0 then 0 else Int.max 0 (Int.min (count - 1) idx)

let accounts_list t =
  match Observed.to_option t.provider_accounts with
  | Some snap -> snap.provider_accounts
  | None -> []

let integrations_list t =
  match Observed.to_option t.integrations with
  | Some snap -> snap.integrations
  | None -> []

let apply_provider_accounts ~observed_at (snap : Wire_account.provider_accounts_snapshot) t =
  let count = List.length snap.provider_accounts in
  {
    t with
    provider_accounts = Observed.value ~observed_at snap;
    own_provider_forbidden = None;
    selected_account_idx = clamp_idx count t.selected_account_idx;
  }

let apply_integrations ~observed_at (snap : Wire_account.person_integrations_snapshot) t =
  {
    t with
    integrations = Observed.value ~observed_at snap;
    own_provider_forbidden = None;
  }

let mark_own_provider_forbidden ~at ~reason t =
  {
    t with
    provider_accounts = Observed.failed ~reason ~retryable:false ~at;
    integrations = Observed.failed ~reason ~retryable:false ~at;
    own_provider_forbidden = Some reason;
  }

let apply_verification ~provider_account_id resp t =
  { t with last_verification = Some (provider_account_id, resp) }

let purge_own_provider_data t =
  {
    t with
    provider_accounts = Observed.unreported;
    integrations = Observed.unreported;
    own_provider_forbidden = None;
    last_verification = None;
    selected_account_idx = 0;
    scroll_offset = 0;
  }

let mark_stale t =
  {
    t with
    provider_accounts = Observed.mark_stale t.provider_accounts;
    integrations = Observed.mark_stale t.integrations;
  }

let selected_provider_account t =
  let rows = accounts_list t in
  if rows = [] then None
  else List.nth_opt rows (clamp_idx (List.length rows) t.selected_account_idx)

let runtimes_for_account ~provider_account_id t =
  match Observed.to_option t.provider_accounts with
  | None -> []
  | Some snap ->
      List.filter
        (fun (rt : Wire_account.provider_runtime) ->
          String.equal rt.provider_account_id provider_account_id)
        snap.runtimes

let integration_by_id ~integration_id t =
  List.find_opt
    (fun (it : Wire_account.person_integration) ->
      String.equal it.integration_id integration_id)
    (integrations_list t)

let move_selection ~delta t =
  let count = List.length (accounts_list t) in
  if count <= 0 then { t with selected_account_idx = 0; scroll_offset = 0 }
  else
    let next_idx = clamp_idx count (t.selected_account_idx + delta) in
    { t with selected_account_idx = next_idx }
