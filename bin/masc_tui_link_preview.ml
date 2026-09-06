(** Masc_tui_link_preview — Web link previews, OpenGraph extraction,
    rich embed cards, and 3D drop-shadow inspection modal. *)

type link_kind =
  | Github of {
      label : string;
      owner : string;
      repo : string;
    }
  | Arxiv of { id : string }
  | HackerNews of { item_id : string }
  | YouTube of { video_id : string }
  | Image_direct of { ext : string }
  | Web_page

type og_preview = {
  url : string;
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  kind : link_kind;
  has_metadata : bool;
}

let preview_cache_capacity = 256
let preview_cache_mu = Stdlib.Mutex.create ()
let preview_cache : (string, og_preview) Masc_tui_lru.t ref =
  ref (Masc_tui_lru.create ~capacity:preview_cache_capacity)

let cache_lookup url =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      Masc_tui_lru.find !preview_cache url)

let cache_store preview =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      Masc_tui_lru.set !preview_cache preview.url preview)

(* Rendered half-block mosaics keyed by image URL, filled asynchronously after a
   preview's image is downloaded and decoded off the render loop. Read by
   [render_modal_card]; a miss simply draws no preview. *)
let mosaic_cache_mu = Stdlib.Mutex.create ()
let mosaic_cache : (string, string list) Hashtbl.t = Hashtbl.create 64

let mosaic_lookup url =
  Stdlib.Mutex.protect mosaic_cache_mu (fun () -> Hashtbl.find_opt mosaic_cache url)

let mosaic_store url lines =
  Stdlib.Mutex.protect mosaic_cache_mu (fun () -> Hashtbl.replace mosaic_cache url lines)

let clear_cache () =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      preview_cache := Masc_tui_lru.create ~capacity:preview_cache_capacity);
  Stdlib.Mutex.protect mosaic_cache_mu (fun () -> Hashtbl.clear mosaic_cache)

let path_segments uri =
  Uri.path uri
  |> String.split_on_char '/'
  |> List.filter (fun s -> not (String.equal s ""))

let is_image_extension ext =
  match String.lowercase_ascii ext with
  | "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "avif" | "bmp" -> true
  | _ -> false

let file_extension path =
  match String.rindex_opt path '.' with
  | Some idx -> String.sub path (idx + 1) (String.length path - idx - 1)
  | None -> ""

let synthesize_preview url =
  let uri = Uri.of_string url in
  let host = Option.value ~default:"" (Uri.host uri) |> String.lowercase_ascii in
  let segments = path_segments uri in
  let ext = file_extension (Uri.path uri) in
  match Masc_tui_link_label.label url with
  | Some label_text ->
      let owner, repo =
        match segments with
        | o :: r :: _ -> o, r
        | _ -> "github", "repo"
      in
      { url
      ; title = Some label_text
      ; description = Some (Printf.sprintf "GitHub resource %s" label_text)
      ; site_name = Some "GitHub"
      ; image_url = Some (Printf.sprintf "https://opengraph.githubassets.com/1/%s/%s" owner repo)
      ; kind = Github { label = label_text; owner; repo }
      ; has_metadata = true
      }
  | None ->
      if is_image_extension ext then
        let filename =
          match List.rev segments with
          | last :: _ -> last
          | [] -> "image." ^ ext
        in
        { url
        ; title = Some filename
        ; description = Some (Printf.sprintf "%s Image (%s)" (String.uppercase_ascii ext) filename)
        ; site_name = Some (if host = "" then "Image" else host)
        ; image_url = Some url
        ; kind = Image_direct { ext }
        ; has_metadata = true
        }
      else if String.equal host "arxiv.org" || String.ends_with ~suffix:".arxiv.org" host then
        let id =
          match segments with
          | "abs" :: paper_id :: _ | "pdf" :: paper_id :: _ -> paper_id
          | last :: _ -> last
          | [] -> "paper"
        in
        { url
        ; title = Some (Printf.sprintf "arXiv %s" id)
        ; description = Some (Printf.sprintf "Preprint archive paper: arXiv:%s" id)
        ; site_name = Some "arXiv.org"
        ; image_url = None
        ; kind = Arxiv { id }
        ; has_metadata = true
        }
      else if String.equal host "news.ycombinator.com" then
        let item_id =
          match Uri.get_query_param uri "id" with
          | Some id -> id
          | None -> "item"
        in
        { url
        ; title = Some (Printf.sprintf "Hacker News item #%s" item_id)
        ; description = Some "Hacker News discussion"
        ; site_name = Some "Hacker News"
        ; image_url = None
        ; kind = HackerNews { item_id }
        ; has_metadata = true
        }
      else if String.equal host "youtube.com" || String.equal host "www.youtube.com"
              || String.equal host "youtu.be" then
        let video_id =
          if String.equal host "youtu.be" then
            match segments with vid :: _ -> vid | [] -> "video"
          else
            match Uri.get_query_param uri "v" with
            | Some vid -> vid
            | None -> "video"
        in
        { url
        ; title = Some (Printf.sprintf "YouTube %s" video_id)
        ; description = Some "YouTube video broadcast"
        ; site_name = Some "YouTube"
        ; image_url = Some (Printf.sprintf "https://img.youtube.com/vi/%s/hqdefault.jpg" video_id)
        ; kind = YouTube { video_id }
        ; has_metadata = true
        }
      else
        { url
        ; title = None
        ; description = None
        ; site_name = Some (if host = "" then "Web Link" else host)
        ; image_url = None
        ; kind = Web_page
        ; has_metadata = false
        }

(* ---- Real OpenGraph fetch upgrade ----

   [synthesize_preview] above builds a card from the URL shape alone: the
   instant, offline fallback. The parser below reads a fetched page's <title>
   and og:* meta tags so a card shows the real title/description/image instead
   of a guess. It is a pure, reentrant scanner -- [Str] keeps global match state
   that is unsafe across the fetch fibers, and a scanner is unit-testable with no
   network. The HTTP call itself lives in the TUI layer (which owns the HTTP
   client and the redraw mailbox) and is injected through [set_background_fetch],
   so this render library keeps no network dependency. *)

(* Allocation-free forward substring search. *)
let index_sub ~sub s from =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 then Some (max 0 from)
  else begin
    let last = ls - lsub in
    let rec loop i =
      if i > last then None
      else begin
        let rec eq j = j >= lsub || (s.[i + j] = sub.[j] && eq (j + 1)) in
        if eq 0 then Some i else loop (i + 1)
      end
    in
    loop (max 0 from)
  end

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let skip_ws s i =
  let n = String.length s in
  let rec loop i = if i < n && is_ws s.[i] then loop (i + 1) else i in
  loop i

(* Decode the few HTML entities that occur in meta content. Unknown entities are
   kept verbatim rather than dropped, so no text is silently lost. *)
let decode_entities s =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '&' then begin
      match String.index_from_opt s !i ';' with
      | Some semi when semi - !i <= 8 ->
          let ent =
            String.lowercase_ascii (String.sub s (!i + 1) (semi - !i - 1))
          in
          let repl =
            match ent with
            | "amp" -> "&"
            | "lt" -> "<"
            | "gt" -> ">"
            | "quot" -> "\""
            | "apos" | "#39" -> "'"
            | "#47" | "#x2f" -> "/"
            | _ -> ""
          in
          if repl = "" then (Buffer.add_char buf '&'; incr i)
          else (Buffer.add_string buf repl; i := semi + 1)
      | _ -> Buffer.add_char buf '&'; incr i
    end
    else (Buffer.add_char buf s.[!i]; incr i)
  done;
  Buffer.contents buf

(* Value of [name="v"] / [name='v'] inside a single tag body. [lower] is the
   lowercased [tag]; the name match is case-insensitive and boundary-guarded so
   ["name"] does not match inside a longer attribute. Only quoted values. *)
let tag_attr ~tag ~lower name =
  let name = String.lowercase_ascii name in
  let n = String.length tag in
  let rec search from =
    match index_sub ~sub:name lower from with
    | None -> None
    | Some i ->
        let boundary_ok = i = 0 || is_ws lower.[i - 1] in
        let j = skip_ws lower (i + String.length name) in
        if boundary_ok && j < n && tag.[j] = '=' then begin
          let k = skip_ws lower (j + 1) in
          if k < n && (tag.[k] = '"' || tag.[k] = '\'') then
            match String.index_from_opt tag (k + 1) tag.[k] with
            | Some e -> Some (String.sub tag (k + 1) (e - k - 1))
            | None -> None
          else search (i + String.length name)
        end
        else search (i + String.length name)
  in
  search 0

(* [content] of the first <meta> whose property or name attribute equals [key]
   (already lowercased). [head]/[lhead] are the page head and its lowercase. *)
let meta_content ~head ~lhead key =
  let n = String.length head in
  let rec loop from =
    match index_sub ~sub:"<meta" lhead from with
    | None -> None
    | Some i ->
        let close =
          match String.index_from_opt head i '>' with Some c -> c | None -> n
        in
        let tag = String.sub head i (close - i) in
        let lower = String.lowercase_ascii tag in
        let prop =
          match tag_attr ~tag ~lower "property" with
          | Some _ as p -> p
          | None -> tag_attr ~tag ~lower "name"
        in
        (match prop with
         | Some p when String.equal (String.lowercase_ascii (String.trim p)) key ->
             (match tag_attr ~tag ~lower "content" with
              | Some c -> Some (decode_entities (String.trim c))
              | None -> loop (close + 1))
         | _ -> loop (close + 1))
  in
  loop 0

(* Text of the first <title>...</title>. *)
let title_tag ~head ~lhead =
  match index_sub ~sub:"<title" lhead 0 with
  | None -> None
  | Some i -> (
      match String.index_from_opt head i '>' with
      | None -> None
      | Some gt -> (
          match index_sub ~sub:"</title" lhead (gt + 1) with
          | None -> None
          | Some e ->
              Some (decode_entities (String.trim (String.sub head (gt + 1) (e - gt - 1))))))

(* Merge a fetched page's real metadata onto the URL-synthesized base, keeping
   its [kind] (and thus its banner styling). Returns the base unchanged when the
   page yielded no title or og:* at all, so [has_metadata] never claims fetched
   data we do not have. The whole body is scanned rather than a head window:
   real pages (YouTube, for one) place og:* hundreds of KB in, after large inline
   scripts, so a small window would silently miss them. The body is already
   capped at 8 MB by the fetch, and the scan is a linear byte walk. *)
let parse_og_html ~url ~body =
  let base = synthesize_preview url in
  let lhead = String.lowercase_ascii body in
  let meta key = meta_content ~head:body ~lhead key in
  let non_empty = function
    | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | _ -> None
  in
  let og_title = non_empty (meta "og:title") in
  let og_desc = non_empty (meta "og:description") in
  let og_image = non_empty (meta "og:image") in
  let og_site = non_empty (meta "og:site_name") in
  let html_title = non_empty (title_tag ~head:body ~lhead) in
  let got_real =
    og_title <> None || og_desc <> None || og_image <> None || html_title <> None
  in
  if not got_real then base
  else
    let title =
      match og_title with
      | Some _ as t -> t
      | None -> ( match html_title with Some _ as t -> t | None -> base.title)
    in
    let description = match og_desc with Some _ as d -> d | None -> base.description in
    let image_url = match og_image with Some _ as im -> im | None -> base.image_url in
    let site_name = match og_site with Some _ as s -> s | None -> base.site_name in
    { base with title; description; site_name; image_url; has_metadata = true }

(* Injected by the TUI at startup: given a URL, spawn a background fetch that
   replaces the synthesized cache entry with fetched metadata and requests a
   redraw. A no-op until registered, so [get_preview] stays pure in tests. *)
let background_fetch : (string -> unit) ref = ref (fun _ -> ())

let set_background_fetch f = background_fetch := f

let has_informative_preview p = p.has_metadata

let get_preview url =
  match cache_lookup url with
  | Some p -> p
  | None ->
      let p = synthesize_preview url in
      cache_store p;
      (* Kick off a real fetch exactly once -- this is the only cache miss for
         the url. Its result replaces this synthesized card on the next render;
         a failed or unregistered fetch simply leaves the synthesized card. A
         direct image URL has no HTML page to read, so it is not fetched. *)
      (match p.kind with Image_direct _ -> () | _ -> !background_fetch url);
      p

let site_icon p =
  match p.kind with
  | Github _ -> "\xf0\x9f\x90\x99" (* 🐙 *)
  | Arxiv _ -> "\xf0\x9f\x93\x84" (* 📄 *)
  | HackerNews _ -> "\xf0\x9f\x9f\xa7" (* 🟧 *)
  | YouTube _ -> "\xe2\x96\xb6\xef\xb8\x8f" (* ▶️ *)
  | Image_direct _ -> "\xf0\x9f\x96\xbc\xef\xb8\x8f" (* 🖼️ *)
  | Web_page -> "\xf0\x9f\x8c\x90" (* 🌐 *)

let site_label p =
  match p.site_name with
  | Some name -> name
  | None ->
      let uri = Uri.of_string p.url in
      Option.value ~default:"Web Link" (Uri.host uri)

let render_compact_badge p =
  if not (has_informative_preview p) then None
  else
    let icon = site_icon p in
    let site = site_label p in
    let title = Option.value ~default:p.url p.title in
    Some (Printf.sprintf "\xe2\x95\xb0\xe2\x94\x80 %s [%s] %s" icon site title)

let make_hline n =
  let buf = Buffer.create (max 0 n * 3) in
  for _ = 1 to max 0 n do
    Buffer.add_string buf "\xe2\x94\x80"
  done;
  Buffer.contents buf

let truecolor_bg r g b =
  Masc_tui_theme.style (Printf.sprintf "\027[48;2;%d;%d;%dm" r g b)

let truecolor_fg r g b =
  Masc_tui_theme.style (Printf.sprintf "\027[38;2;%d;%d;%dm" r g b)

let pad_banner_cell ~width ~bg ~fg text =
  let dw = Masc_tui_message_layout.display_width text in
  let centered =
    if dw >= width then
      Masc_tui_message_layout.fit_width text width
    else
      let pad = width - dw in
      let lpad = pad / 2 in
      let rpad = pad - lpad in
      String.make lpad ' ' ^ text ^ String.make rpad ' '
  in
  bg ^ fg ^ centered ^ Masc_tui_theme.Sgr.reset

let render_og_banner ~width p =
  match p.kind with
  | Github { repo; _ } ->
      let bg = truecolor_bg 22 27 34 in
      let fg_hi = truecolor_fg 88 166 255 in
      let fg_sub = truecolor_fg 201 209 217 in
      let short_repo =
        if String.length repo > width - 4 then
          String.sub repo 0 (max 0 (width - 6)) ^ ".."
        else repo
      in
      [ pad_banner_cell ~width ~bg ~fg:fg_hi "GITHUB"
      ; pad_banner_cell ~width ~bg ~fg:fg_sub "/\\___/\\"
      ; pad_banner_cell ~width ~bg ~fg:fg_sub "(  o o  )"
      ; pad_banner_cell ~width ~bg ~fg:fg_sub "(  =^=  )"
      ; pad_banner_cell ~width ~bg ~fg:fg_hi short_repo
      ]
  | YouTube { video_id = _ } ->
      let bg = truecolor_bg 180 20 20 in
      let fg = truecolor_fg 255 255 255 in
      [ pad_banner_cell ~width ~bg ~fg "YOUTUBE"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82   \xe2\x96\xb6     \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82  VIDEO  \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf"
      ]
  | Arxiv { id } ->
      let bg = truecolor_bg 15 32 67 in
      let fg = truecolor_fg 220 235 255 in
      let short_id =
        if String.length id > 7 then String.sub id 0 7 else id
      in
      [ pad_banner_cell ~width ~bg ~fg "ARXIV"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82 e-Print \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg (Printf.sprintf "\xe2\x94\x82 %-7s \xe2\x94\x82" short_id)
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf"
      ]
  | HackerNews { item_id = _ } ->
      let bg = truecolor_bg 255 102 0 in
      let fg = truecolor_fg 20 20 20 in
      [ pad_banner_cell ~width ~bg ~fg "HACKER NEWS"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82    Y    \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82  YC:HN  \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf"
      ]
  | Image_direct { ext } ->
      let bg = truecolor_bg 12 44 58 in
      let fg = truecolor_fg 79 214 238 in
      let ext_str = String.uppercase_ascii ext in
      let ext_padded =
        if String.length ext_str > 5 then String.sub ext_str 0 5 else ext_str
      in
      [ pad_banner_cell ~width ~bg ~fg "IMAGE EMBED"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae"
      ; pad_banner_cell ~width ~bg ~fg (Printf.sprintf "\xe2\x94\x82  %-5s  \xe2\x94\x82" ext_padded)
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82 [v:View]\xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf"
      ]
  | Web_page ->
      let bg = truecolor_bg 33 37 43 in
      let fg = truecolor_fg 215 220 228 in
      [ pad_banner_cell ~width ~bg ~fg "WEB LINK"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82   WWW   \xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x94\x82 BOOKMARK\xe2\x94\x82"
      ; pad_banner_cell ~width ~bg ~fg "\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf"
      ]

let render_narrow_card ~width p =
  let card_w = max 24 (width - 2) in
  let content_w = card_w - 4 in
  let icon = site_icon p in
  let site = site_label p in
  let header = Printf.sprintf "%s %s" icon site in
  let title = Option.value ~default:p.url p.title in
  let top_border = Printf.sprintf "\xe2\x95\xad%s\xe2\x95\xae" (make_hline (card_w - 2)) in
  let bot_border = Printf.sprintf "\xe2\x95\xb0%s\xe2\x95\xaf" (make_hline (card_w - 2)) in
  let pad_row text =
    let fitted = Masc_tui_message_layout.fit_width text content_w in
    Printf.sprintf "\xe2\x94\x82 %s \xe2\x94\x82" fitted
  in
  let r0 = pad_row header in
  let r1 = pad_row ("\xe2\xaf\x88 " ^ title) in
  let r2 =
    match p.description with
    | Some d when String.trim d <> "" -> [ pad_row d ]
    | _ -> []
  in
  let r3 =
    let pills =
      if p.image_url <> None then "[o:Browser] [y:Copy] [v:Visual]"
      else "[o:Browser] [y:Copy]"
    in
    pad_row pills
  in
  [ top_border; r0; r1 ] @ r2 @ [ r3; bot_border ]

let render_notion_card ~width p =
  if width < 55 then
    render_narrow_card ~width p
  else
    let banner_w = 20 in
    let left_w = max 24 (width - banner_w - 3) in
    let top_border =
      Printf.sprintf "\xe2\x95\xad%s\xe2\x94\xac%s\xe2\x95\xae"
        (make_hline left_w) (make_hline banner_w)
    in
    let bot_border =
      Printf.sprintf "\xe2\x95\xb0%s\xe2\x94\xb4%s\xe2\x95\xaf"
        (make_hline left_w) (make_hline banner_w)
    in
    let left_inner_w = max 10 (left_w - 2) in
    let pad_left text =
      let fitted = Masc_tui_message_layout.fit_width text left_inner_w in
      Printf.sprintf " %s " fitted
    in
    let icon = site_icon p in
    let site = site_label p in
    let uri = Uri.of_string p.url in
    let host = Option.value ~default:"" (Uri.host uri) in
    let domain_suffix =
      if host <> "" && not (String.equal host site) then " \xc2\xb7 " ^ host else ""
    in
    let header = Printf.sprintf "%s %s%s" icon site domain_suffix in
    let title = Option.value ~default:p.url p.title in
    let desc =
      match p.description with
      | Some d when String.trim d <> "" -> d
      | _ -> p.url
    in
    let pills =
      if p.image_url <> None then "[o:Browser]  [y:Copy]  [v:Visual]"
      else "[o:Browser]  [y:Copy]"
    in
    let left_rows =
      [| pad_left header
       ; pad_left (Masc_tui_theme.Sgr.bold ^ "\xe2\xaf\x88 " ^ title ^ Masc_tui_theme.Sgr.reset)
       ; pad_left (Masc_tui_theme.Sgr.dim ^ desc ^ Masc_tui_theme.Sgr.reset)
       ; pad_left (Masc_tui_theme.Sgr.dim ^ "\xe2\x86\x97 " ^ p.url ^ Masc_tui_theme.Sgr.reset)
       ; pad_left (Masc_tui_theme.Sgr.dim ^ pills ^ Masc_tui_theme.Sgr.reset)
      |]
    in
    let banner_rows = Array.of_list (render_og_banner ~width:banner_w p) in
    let content_lines =
      List.init 5 (fun i ->
          Printf.sprintf "\xe2\x94\x82%s\xe2\x94\x82%s\xe2\x94\x82"
            left_rows.(i) banner_rows.(i))
    in
    [ top_border ] @ content_lines @ [ bot_border ]

let render_inline_card ~width p =
  render_notion_card ~width p

let render_modal_card ~width ~height:_ p =
  let card = render_notion_card ~width:(max 30 (width - 4)) p in
  let inner_width = max 20 (width - 6) in
  let lines = ref [] in
  let add s = lines := s :: !lines in
  List.iter add card;
  add "";
  (match p.image_url with
   | Some img -> (
       match mosaic_lookup img with
       | Some (_ :: _ as mosaic) ->
           add "  preview";
           List.iter (fun l -> add ("  " ^ l)) mosaic;
           add ""
       | _ -> ())
   | None -> ());
  (match p.kind with
   | Image_direct { ext } ->
       add (Printf.sprintf "  \xf0\x9f\x96\xbc\xef\xb8\x8f  Direct Image: %s format" (String.uppercase_ascii ext));
       add "  Press [v] to view this image directly inside the terminal graphics engine."
   | YouTube { video_id } ->
       add (Printf.sprintf "  \xe2\x96\xb6\xef\xb8\x8f  YouTube Video Stream (ID: %s)" video_id);
       add "  Press [o] to open the video in your default system browser.";
       add "  Press [v] to view the high-resolution video thumbnail in the terminal."
   | Arxiv { id } ->
       add (Printf.sprintf "  \xf0\x9f\x93\x84  arXiv e-Print Archive Paper %s" id);
       add "  Press [o] to read the paper and abstract in your browser."
   | HackerNews { item_id } ->
       add (Printf.sprintf "  \xf0\x9f\x9f\xa7  Hacker News Item #%s" item_id);
       add "  Press [o] to join the discussion thread in your browser."
   | Github { label; owner; repo } ->
       add (Printf.sprintf "  \xf0\x9f\x90\x99  %s/%s \xc2\xb7 %s" owner repo label);
       add "  Press [o] to inspect the pull request / issue in GitHub.";
       add "  Press [v] to preview the GitHub social card in terminal graphics."
   | Web_page ->
       add "  \xf0\x9f\x8c\x90  Web Resource Bookmark";
       add "  Press [o] to open in default browser.");
  add "";
  add (Printf.sprintf "  \xe2\x86\x97 URL: %s" (Masc_tui_message_layout.fit_width p.url (inner_width - 8)));
  List.rev !lines
