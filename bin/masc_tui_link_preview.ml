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

let clear_cache () =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      preview_cache := Masc_tui_lru.create ~capacity:preview_cache_capacity)

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
      ; image_url = None
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

let has_informative_preview p = p.has_metadata

let get_preview url =
  match cache_lookup url with
  | Some p -> p
  | None ->
      let p = synthesize_preview url in
      cache_store p;
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

let render_inline_card ~width p =
  let inner_width = max 20 (width - 4) in
  let icon = site_icon p in
  let site = site_label p in
  let header_text = Printf.sprintf " %s %s " icon site in
  let header_cells = Masc_tui_message_layout.display_width header_text in
  let rule_len = max 2 (inner_width - header_cells) in
  let rule = make_hline rule_len in
  let top_border = Printf.sprintf "\xe2\x95\xad\xe2\x94\x80%s%s\xe2\x95\xae" header_text rule in
  let total_box_width = 1 + 1 + header_cells + rule_len + 1 in
  let content_width = total_box_width - 4 in
  let pad_content line =
    let fitted = Masc_tui_message_layout.fit_width line content_width in
    Printf.sprintf "\xe2\x94\x82 %s \xe2\x94\x82" fitted
  in
  let title = Option.value ~default:p.url p.title in
  let title_line = pad_content ("\xe2\xaf\x88 " ^ title) in
  let desc_line =
    match p.description with
    | Some d when String.trim d <> "" ->
        [ pad_content d ]
    | _ -> []
  in
  let media_line =
    match p.kind with
    | Image_direct { ext } ->
        [ pad_content (Printf.sprintf "[🖼️  %s Image Embed · /preview to view]" (String.uppercase_ascii ext)) ]
    | YouTube _ ->
        [ pad_content "[▶️  YouTube Video Stream Embed]" ]
    | Arxiv _ ->
        [ pad_content "[📄 Research Paper · Peer / Preprint Archive]" ]
    | _ -> []
  in
  let link_line = pad_content ("\xe2\x86\x97 " ^ p.url) in
  let bottom_border = Printf.sprintf "\xe2\x95\xb0%s\xe2\x95\xaf" (make_hline (total_box_width - 2)) in
  [ top_border; title_line ] @ desc_line @ media_line @ [ link_line; bottom_border ]

let render_modal_card ~width ~height:_ p =
  let inner_width = max 20 (width - 6) in
  let icon = site_icon p in
  let site = site_label p in
  let title = Option.value ~default:p.url p.title in
  let lines = ref [] in
  let add s = lines := s :: !lines in
  add (Printf.sprintf "  %s  %s" icon site);
  add "";
  add (Printf.sprintf "  \xe2\xaf\x88 %s" (Masc_tui_message_layout.fit_width title (inner_width - 4)));
  add "";
  (match p.description with
   | Some desc when String.trim desc <> "" ->
       add (Printf.sprintf "  %s" (Masc_tui_message_layout.fit_width desc (inner_width - 4)));
       add ""
   | _ -> ());
  (match p.kind with
   | Image_direct { ext } ->
       add (Printf.sprintf "  \xf0\x9f\x96\xbc\xef\xb8\x8f  Direct Image: %s format" (String.uppercase_ascii ext));
       add "  Press [v] to view this image directly inside the terminal graphics engine."
   | YouTube { video_id } ->
       add (Printf.sprintf "  \xe2\x96\xb6\xef\xb8\x8f  YouTube Video Stream (ID: %s)" video_id);
       add "  Press [o] to open the video in your default system browser."
   | Arxiv { id } ->
       add (Printf.sprintf "  \xf0\x9f\x93\x84  arXiv e-Print Archive Paper %s" id);
       add "  Press [o] to read the paper and abstract in your browser."
   | HackerNews { item_id } ->
       add (Printf.sprintf "  \xf0\x9f\x9f\xa7  Hacker News Item #%s" item_id);
       add "  Press [o] to join the discussion thread in your browser."
   | Github { label; owner; repo } ->
       add (Printf.sprintf "  \xf0\x9f\x90\x99  %s/%s · %s" owner repo label);
       add "  Press [o] to inspect the pull request / issue in GitHub."
   | Web_page ->
       add "  \xf0\x9f\x8c\x90  Web Resource");
  add "";
  add (Printf.sprintf "  \xe2\x86\x97 URL: %s" (Masc_tui_message_layout.fit_width p.url (inner_width - 8)));
  List.rev !lines
