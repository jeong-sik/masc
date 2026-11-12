module F = Masc_tui_fetched
module D = Masc_tui_detail_reading
type key = { post_id : string; sha256 : string; bytes : int; name : string option }
type presentation = Source | Markdown | Html
type content_kind = Document | Image_bytes
type content = { reference : key; original : string }
type preparation = { key : key; content : content; presentation : presentation; width : int;
  content_kind : content_kind }
type 'a owned_request = { ticket : 'a F.request; job : unit ref }
type request = key owned_request
type preparation_request = preparation owned_request
(* This reader's titles and section names are written in English only, so the
   capture note under them is English too. *)
let titles_in_korean = false
type t = { opened : key option; source : (key,content) F.t;
  read_request : request option; preparation_request : preparation_request option;
  preparation : (preparation,D.row list) F.t; presentation : presentation;
  content_kind : content_kind; original_open_pending : unit ref option; document : D.t }
let initial = {opened=None;source=F.initial;preparation=F.initial;presentation=Source;
  read_request=None;preparation_request=None;content_kind=Document;original_open_pending=None;
  document=D.create ~ko:titles_in_korean ~title:"Board attachment" []}
let request_job (request : request)=request.job
let preparation_job (request : preparation_request)=request.job
let key t=t.opened
let equal_key a b=a.post_id=b.post_id && a.sha256=b.sha256 && a.bytes=b.bytes && a.name=b.name
let owns t request=match t.read_request,t.opened with
  | Some current,Some key -> equal_key key (F.request_key request.ticket)
    && current.job==request.job && F.same_request ~equal:equal_key current.ticket request.ticket
  | None,_ | _,None -> false
let equal_preparation a b=equal_key a.key b.key && a.content==b.content
  && a.presentation=b.presentation && a.width=b.width && a.content_kind=b.content_kind
let pending t=if F.in_flight t.source then t.read_request else None
let pending_preparation t=if F.in_flight t.preparation then t.preparation_request else None
let close t={t with opened=None;source=F.clear t.source;preparation=F.clear t.preparation;
  read_request=None;preparation_request=None;content_kind=Document;original_open_pending=None;
  document=D.create ~ko:titles_in_korean ~title:"Board attachment" []}
let title key=Option.value key.name ~default:"Board attachment"
let notice key body=D.create ~ko:titles_in_korean ~title:(title key) [{D.heading="Attachment";body}]
let offer_image ~key ~message t=
  let t=close t in
  {t with opened=Some key;content_kind=Image_bytes;
    document=notice key (message ^
      "\nPress r to read the original; after verification s saves it and o opens it.")}
let open_read ?(content_kind=Document) ~key t=
  let t=close t in
  match F.start ~equal:equal_key t.source ~key with
  | Already_loading -> t,None
  | Started (source,ticket) ->
    let request={ticket;job=ref ()} in
    {t with opened=Some key;source;read_request=Some request;presentation=Source;content_kind;
      document=notice key "Reading original bytes…"},Some request
let validate key original=
  if String.length original<>key.bytes then Error "Attachment byte length differs from the selected reference"
  else if Agent_core_sha256.(digest_string original |> to_hex)<>key.sha256
  then Error "Attachment digest differs from the selected reference"
  else Ok {reference=key;original}
let complete t request result=
  if not (owns t request && F.is_current ~equal:equal_key t.source request.ticket) then t else
  let result=match result with
    | Ok content when not (equal_key content.reference (F.request_key request.ticket)) ->
      Error "Attachment reading belongs to another reference"
    | Ok _ | Error _ -> result in
  let source=F.complete ~equal:equal_key t.source request.ticket result in
  let key=F.request_key request.ticket in
  let document=notice key (match result with Ok _ -> "Preparing original reading…" | Error error -> error ^ "\nPress r to retry.") in
  {t with source;document}
let select presentation t=
  {t with presentation;preparation=F.clear t.preparation;preparation_request=None}
let ready t=match t.opened with
  | None -> None
  | Some key -> match F.view_for ~equal:equal_key t.source ~key with
    | Ready content -> Some (key,content)
    | Absent | Loading | Failed _ | Stale _ -> None
let start_preparation ~width t=match ready t with
  | None -> t,None
  | Some (key,content) ->
    let input={key;content;presentation=t.presentation;width=max 1 width;content_kind=t.content_kind} in
    (match F.current_key t.preparation with
     | Some previous when equal_preparation previous input -> t,None
     | Some _ | None -> match F.start ~equal:equal_preparation t.preparation ~key:input with
       | Already_loading -> t,None
       | Started (preparation,ticket) ->
         let request={ticket;job=ref ()} in
         {t with preparation;preparation_request=Some request},Some request)
let prepare request=
  let input=F.request_key request.ticket in
  let safe=Masc.Tui_terminal_text.sanitize_terminal_text in
  let wrap text=Masc_tui_text_block.lines text |> List.concat_map (fun line ->
    Masc_tui_message_layout.split_cells ~max_cells:input.width (safe line)) in
  let note text=List.map (fun line -> D.Note line) (wrap text) in
  let content=
    if input.content_kind=Image_bytes || not (String.is_valid_utf_8 input.content.original) then
      note "Binary attachment · use s to save the original bytes."
    else match input.presentation with
      | Source -> List.map (fun line -> D.Content line) (wrap input.content.original)
      | Markdown ->
        Masc_tui_message_layout.wrap_body ~markdown:Masc_tui_markdown_theme.document
          ~max_cells:input.width ~sanitize:safe
          (String.concat "\n" (Masc_tui_text_block.lines input.content.original))
        |> List.map (fun line -> D.Content line)
      | Html -> Masc_tui_artifact_html.project input.content.original
        |> Masc_tui_artifact_html_rows.render ~image_action:No_image_action ~width:input.width
        |> List.map (fun line -> D.Content line) in
  note ("Post: " ^ input.key.post_id ^ "\nSHA-256: " ^ input.key.sha256
    ^ "\n" ^ string_of_int input.key.bytes ^ " bytes · "
    ^ (match input.presentation with Source -> "source" | Markdown -> "view as Markdown" | Html -> "view as HTML (inert)"))
  @ (D.Content ""::content)
let complete_preparation t request result=
  let owns_job=match t.preparation_request with
    | Some current -> current.job==request.job
    | None -> false in
  if not (owns_job && F.is_current ~equal:equal_preparation t.preparation request.ticket) then t
  else
    let input=F.request_key request.ticket in
    let current=match ready t with Some (key,content) -> equal_key key input.key
      && content==input.content && t.presentation=input.presentation
      && t.content_kind=input.content_kind | None -> false in
    let preparation=F.complete ~equal:equal_preparation t.preparation request.ticket result in
    if not current then {t with preparation} else
    let rows=match result with Ok rows -> rows | Error error ->
      Masc_tui_message_layout.split_cells ~max_cells:input.width
        (Masc.Tui_terminal_text.sanitize_terminal_text error)
      |> List.map (fun line -> D.Note line) in
    let hints=match input.content_kind with
      | Image_bytes -> "s:save o:open original r:retry Esc:back"
      | Document -> "j/k:scroll PgUp/PgDn:page Home/End:edges u:source m:Markdown h:HTML y:copy s:save r:retry Esc:back" in
    let document=D.replace_prepared ~title:(title input.key) ~hints
      ~width:input.width rows t.document in
    {t with preparation;document}
let document t=t.document
let move ~count ~height movement t={t with document=D.move ~count ~height movement t.document}
let search_key ~width ~height ~key t=
  Option.map (fun document -> {t with document}) (D.search_key ~width ~height ~key t.document)
let search_insert ~width ~height ~text t=
  {t with document=D.search_insert ~width ~height ~text t.document}
let source t=match ready t with
  | Some (_,content) when t.content_kind=Document && String.is_valid_utf_8 content.original -> Ok content.original
  | Some _ -> Error "Binary attachment cannot be copied as terminal text; use s to save"
  | None -> Error "Original attachment has not been read"
let saved_source t=match t.read_request,ready t with
  | Some request,Some (key,content) -> Some (request,key,content.original)
  | None,_ | _,None -> None
let begin_original_open t =
  if Option.is_some t.original_open_pending then t,None else
  match saved_source t with
  | None -> t,None
  | Some (request,key,bytes) ->
      let attempt=ref () in
      {t with original_open_pending=Some attempt},Some (attempt,request,key,bytes)
let owns_original_open t request attempt =
  owns t request && Option.exists (fun current -> current == attempt) t.original_open_pending
let withdraw_original_open t = {t with original_open_pending=None}
let finish_original_open t request attempt =
  if owns_original_open t request attempt then {t with original_open_pending=None} else t
