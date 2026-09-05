(** Masc_tui_link_preview — Web link previews, OpenGraph extraction,
    rich embed cards, and 3D drop-shadow inspection modal. *)

type link_kind =
  | Github of {
      owner : string;
      repo : string;
      item : string;
    }
  | Arxiv of { id : string }
  | HackerNews of { item_id : string }
  | YouTube of { video_id : string }
  | Image_direct of { ext : string }
  | Web_page

type og_preview = {
  url : string;
  canonical_url : string option;
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  favicon_url : string option;
  kind : link_kind;
  cache_state : string;
}

let preview_cache_mu = Stdlib.Mutex.create ()
let preview_cache : (string, og_preview) Hashtbl.t = Hashtbl.create 128

let cache_lookup url =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      Hashtbl.find_opt preview_cache url)

let cache_store preview =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      Hashtbl.replace preview_cache preview.url preview)

let clear_cache () =
  Stdlib.Mutex.protect preview_cache_mu (fun () ->
      Hashtbl.clear preview_cache)

let path_segments uri =
  Uri.path uri
  |> String.split_on_char '/'
  |> List.filter (fun s -> not (String.equal s ""))

let short_sha sha =
  if String.length sha <= 7 then sha else String.sub sha 0 7

let is_image_extension ext =
  let e = String.lowercase_ascii ext in
  match e with
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
  if is_image_extension ext then
    let filename =
      match List.rev segments with
      | last :: _ -> last
      | [] -> "image." ^ ext
    in
    { url
    ; canonical_url = Some url
    ; title = Some filename
    ; description = Some (Printf.sprintf "%s Image (%s)" (String.uppercase_ascii ext) url)
    ; site_name = Some (if host = "" then "Image Media" else host)
    ; image_url = Some url
    ; favicon_url = None
    ; kind = Image_direct { ext }
    ; cache_state = "synthetic"
    }
  else if String.equal host "github.com" || String.ends_with ~suffix:".github.com" host then
    match segments with
    | owner :: repo :: rest ->
        let item, title, desc =
          match rest with
          | [ "pull"; num ] ->
              let item = "PR #" ^ num in
              item,
              Printf.sprintf "%s/%s · Pull Request #%s" owner repo num,
              Printf.sprintf "GitHub Pull Request #%s in %s/%s" num owner repo
          | [ "issues"; num ] ->
              let item = "Issue #" ^ num in
              item,
              Printf.sprintf "%s/%s · Issue #%s" owner repo num,
              Printf.sprintf "GitHub Issue #%s in %s/%s" num owner repo
          | [ "commit"; sha ] ->
              let s = short_sha sha in
              let item = "Commit " ^ s in
              item,
              Printf.sprintf "%s/%s · Commit %s" owner repo s,
              Printf.sprintf "Git commit %s in repository %s/%s" s owner repo
          | "actions" :: "runs" :: run_id :: _ ->
              let item = "Run " ^ run_id in
              item,
              Printf.sprintf "%s/%s · CI Workflow Run #%s" owner repo run_id,
              Printf.sprintf "GitHub Actions workflow execution #%s in %s/%s" run_id owner repo
          | "blob" :: _ :: path | "tree" :: _ :: path ->
              let fname = match List.rev path with last :: _ -> last | [] -> repo in
              let item = fname in
              item,
              Printf.sprintf "%s/%s · %s" owner repo fname,
              Printf.sprintf "Source file %s in %s/%s" fname owner repo
          | [] ->
              "Repository",
              Printf.sprintf "%s/%s" owner repo,
              Printf.sprintf "GitHub repository %s/%s" owner repo
          | _ ->
              "GitHub Link",
              Printf.sprintf "%s/%s" owner repo,
              Printf.sprintf "GitHub resource at %s/%s" owner repo
        in
        { url
        ; canonical_url = Some url
        ; title = Some title
        ; description = Some desc
        ; site_name = Some "GitHub"
        ; image_url = None
        ; favicon_url = Some "https://github.githubassets.com/favicons/favicon.png"
        ; kind = Github { owner; repo; item }
        ; cache_state = "synthetic"
        }
    | _ ->
        { url
        ; canonical_url = Some url
        ; title = Some "GitHub"
        ; description = Some "GitHub: Where the world builds software"
        ; site_name = Some "GitHub"
        ; image_url = None
        ; favicon_url = None
        ; kind = Web_page
        ; cache_state = "synthetic"
        }
  else if String.equal host "arxiv.org" || String.ends_with ~suffix:".arxiv.org" host then
    let id =
      match segments with
      | "abs" :: paper_id :: _ | "pdf" :: paper_id :: _ -> paper_id
      | last :: _ -> last
      | [] -> "paper"
    in
    { url
    ; canonical_url = Some url
    ; title = Some (Printf.sprintf "arXiv:%s" id)
    ; description = Some (Printf.sprintf "Scientific pre-print e-Print archive: %s" id)
    ; site_name = Some "arXiv.org"
    ; image_url = None
    ; favicon_url = None
    ; kind = Arxiv { id }
    ; cache_state = "synthetic"
    }
  else if String.equal host "news.ycombinator.com" then
    let item_id =
      match Uri.get_query_param uri "id" with
      | Some id -> id
      | None -> "item"
    in
    { url
    ; canonical_url = Some url
    ; title = Some (Printf.sprintf "Hacker News discussion #%s" item_id)
    ; description = Some "Hacker News: tech, programming, and startup discussion"
    ; site_name = Some "Hacker News"
    ; image_url = None
    ; favicon_url = None
    ; kind = HackerNews { item_id }
    ; cache_state = "synthetic"
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
    ; canonical_url = Some url
    ; title = Some (Printf.sprintf "YouTube Video [%s]" video_id)
    ; description = Some "YouTube video broadcast"
    ; site_name = Some "YouTube"
    ; image_url = Some (Printf.sprintf "https://img.youtube.com/vi/%s/hqdefault.jpg" video_id)
    ; favicon_url = None
    ; kind = YouTube { video_id }
    ; cache_state = "synthetic"
    }
  else
    let path_hint =
      match List.rev segments with
      | last :: _ when String.length last > 0 -> " / " ^ last
      | _ -> ""
    in
    { url
    ; canonical_url = Some url
    ; title = Some (if host = "" then url else host ^ path_hint)
    ; description = Some (Printf.sprintf "Web page at %s" (if host = "" then url else host))
    ; site_name = Some (if host = "" then "Web Link" else host)
    ; image_url = None
    ; favicon_url = None
    ; kind = Web_page
    ; cache_state = "synthetic"
    }

let get_preview url =
  match cache_lookup url with
  | Some p -> p
  | None ->
      let p = synthesize_preview url in
      cache_store p;
      p

let json_string_opt key assoc =
  match List.assoc_opt key assoc with
  | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

let of_json url json =
  match json with
  | `Assoc fields ->
      let title = json_string_opt "title" fields in
      let description = json_string_opt "description" fields in
      let site_name = json_string_opt "site_name" fields in
      let image_url = json_string_opt "image_url" fields in
      let favicon_url = json_string_opt "favicon_url" fields in
      let canonical_url = json_string_opt "canonical_url" fields in
      let cache_state = Option.value ~default:"live" (json_string_opt "cache_state" fields) in
      let base = synthesize_preview url in
      let preview =
        { url
        ; canonical_url = (match canonical_url with Some _ -> canonical_url | None -> base.canonical_url)
        ; title = (match title with Some _ -> title | None -> base.title)
        ; description = (match description with Some _ -> description | None -> base.description)
        ; site_name = (match site_name with Some _ -> site_name | None -> base.site_name)
        ; image_url = (match image_url with Some _ -> image_url | None -> base.image_url)
        ; favicon_url = (match favicon_url with Some _ -> favicon_url | None -> base.favicon_url)
        ; kind = base.kind
        ; cache_state
        }
      in
      cache_store preview;
      Some preview
  | _ -> None

let to_json p =
  let opt_str k v acc =
    match v with
    | Some s -> (k, `String s) :: acc
    | None -> acc
  in
  let fields =
    [ ("url", `String p.url)
    ; ("cache_state", `String p.cache_state)
    ]
    |> opt_str "canonical_url" p.canonical_url
    |> opt_str "title" p.title
    |> opt_str "description" p.description
    |> opt_str "site_name" p.site_name
    |> opt_str "image_url" p.image_url
    |> opt_str "favicon_url" p.favicon_url
  in
  `Assoc (List.rev fields)

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
  let icon = site_icon p in
  let site = site_label p in
  let title = Option.value ~default:p.url p.title in
  Printf.sprintf "\xe2\x95\xb0\xe2\x94\x80 %s [%s] %s" icon site title

let fit_string s len =
  if len <= 0 then ""
  else
    let slen = String.length s in
    if slen <= len then s ^ String.make (len - slen) ' '
    else if len <= 3 then String.sub s 0 len
    else String.sub s 0 (len - 1) ^ "\xe2\x80\xa6"

let render_inline_card ~width p =
  let inner_width = max 20 (width - 4) in
  let icon = site_icon p in
  let site = site_label p in
  let title = Option.value ~default:p.url p.title in
  let header_text = Printf.sprintf " %s %s " icon site in
  let header_len = String.length header_text in
  let rule_len = max 2 (inner_width - header_len) in
  let make_hline n =
    let buf = Buffer.create (n * 3) in
    for _ = 1 to max 0 n do
      Buffer.add_string buf "\xe2\x94\x80"
    done;
    Buffer.contents buf
  in
  let rule = make_hline rule_len in
  let top_border = Printf.sprintf "\xe2\x95\xad\xe2\x94\x80%s%s\xe2\x95\xae" header_text rule in
  let title_line = Printf.sprintf "\xe2\x94\x82 \xe2\xaf\x88 %s \xe2\x94\x82" (fit_string title (inner_width - 4)) in
  let desc_line =
    match p.description with
    | Some d when String.trim d <> "" ->
        [ Printf.sprintf "\xe2\x94\x82   %s \xe2\x94\x82" (fit_string d (inner_width - 4)) ]
    | _ -> []
  in
  let media_line =
    match p.kind with
    | Image_direct { ext } ->
        [ Printf.sprintf "\xe2\x94\x82   [🖼️  %s Image Embed · /preview to view] \xe2\x94\x82"
            (String.uppercase_ascii ext) ]
    | YouTube _ ->
        [ Printf.sprintf "\xe2\x94\x82   [▶️  YouTube Video Stream Embed] \xe2\x94\x82" ]
    | Arxiv _ ->
        [ Printf.sprintf "\xe2\x94\x82   [📄 Research Paper · Peer / Preprint Archive] \xe2\x94\x82" ]
    | _ -> []
  in
  let link_line = Printf.sprintf "\xe2\x94\x82   \xe2\x86\x97 %s \xe2\x94\x82" (fit_string p.url (inner_width - 6)) in
  let bottom_border = Printf.sprintf "\xe2\x95\xb0%s\xe2\x95\xaf" (make_hline (inner_width + 2)) in
  [ top_border; title_line ] @ desc_line @ media_line @ [ link_line; bottom_border ]

let render_modal_card ~width ~height:_ p =
  let inner_width = max 20 (width - 6) in
  let icon = site_icon p in
  let site = site_label p in
  let title = Option.value ~default:p.url p.title in
  let lines = ref [] in
  let add s = lines := s :: !lines in
  add (Printf.sprintf "  %s  %s" icon site);
  add (Printf.sprintf "  %s" (fit_string title inner_width));
  add "";
  (match p.description with
   | Some desc ->
       add (Printf.sprintf "  Description:");
       add (Printf.sprintf "    %s" (fit_string desc (inner_width - 4)));
       add ""
   | None -> ());
  (match p.kind with
   | Github { owner; repo; item } ->
       add (Printf.sprintf "  Repository: %s/%s" owner repo);
       add (Printf.sprintf "  Reference:  %s" item);
       add ""
   | Image_direct { ext } ->
       add (Printf.sprintf "  Image Format: %s (Direct Media Embed)" (String.uppercase_ascii ext));
       add "  [Visual Preview: Press 'v' to view in full resolution]";
       add ""
   | YouTube { video_id } ->
       add (Printf.sprintf "  Video ID: %s" video_id);
       add "  Platform: YouTube Web Media";
       add ""
   | Arxiv { id } ->
       add (Printf.sprintf "  Archive Identifier: arXiv:%s" id);
       add "  Primary Category: Computer Science / Machine Learning";
       add ""
   | HackerNews { item_id } ->
       add (Printf.sprintf "  Hacker News Item: %s" item_id);
       add ""
   | Web_page -> ());
  add (Printf.sprintf "  Canonical URL: %s" p.url);
  List.rev !lines
