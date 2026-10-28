module Blocks = Keeper_chat_blocks
open Result.Syntax
let escape text =
  let buf = Buffer.create (String.length text) in
  String.iter (function
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | c -> Buffer.add_char buf c) text;
  Buffer.contents buf
let text_of_html text =
  Markup_document.parse_html text
  |> List.map Markup_document.text_content |> String.concat ""
type part = Plain of string | Bold of string | Pre of string | Link of {url:string;title:string} | Unsupported_media
let optional = Option.value ~default:""
let cell = function Blocks.Cell_text text -> text | Cell_value {v;num=_;muted=_} -> v
let link ~url ~title =
  if String.trim url="" then [Plain title]
  else [Link {url; title=if String.trim title="" then url else title}]
let parts = function
  | Blocks.Text {html} -> [Plain(text_of_html html)]
  | Heading {html} -> [Bold(text_of_html html)]
  | Unordered_list {items} -> [Plain(String.concat "\n" (List.map(fun s -> "- " ^ text_of_html s) items))]
  | Callout {severity;html} -> [Bold("Callout" ^ Option.fold ~none:"" ~some:(fun s -> " ("^s^")") severity ^ ": ");Plain(text_of_html html)]
  | Table {head;rows} -> [Pre(String.concat "\n" (List.map(fun row -> String.concat " | " (List.map cell row)) (head::rows)))]
  | Code {cap;html;source} -> [Bold(optional cap); Pre(Option.value ~default:(text_of_html html) source)]
  | Mermaid {source;caption} -> [Bold("Mermaid "^optional caption);Pre source]
  | Svg {svg;cap} -> [Bold("SVG "^optional cap);Pre svg]
  | Voice {src;transcript;via;secs=_;wave=_;size=_} ->
    [Bold("Audio "^optional via);Plain(optional transcript)] @ link ~url:(optional src) ~title:(optional src)
  | Attach {name;src;kind;svg;data;dims=_;ph=_;via=_;size=_;mime_type=_;size_bytes=_} ->
    [Bold("Attachment "^optional kind^": "^name)] @ link ~url:(optional src) ~title:(optional src)
    @ [Pre(optional svg)] @ (match data,src with Some _,None -> [Unsupported_media] | None, (None|Some _) | Some _,Some _ -> [])
  | Image {src;cap} -> [Plain "Image: "] @ link ~url:src ~title:(Option.value ~default:"image" cap)
  | Link {url;title;meta} -> link ~url ~title @ [Plain meta]
  | Fusion {board_post_id;run_id} -> [Bold "Fusion result";Plain("board_post_id: "^board_post_id^"\nrun_id: "^run_id)]
  | Status {kind} -> [Plain(Blocks.status_kind_connector_text kind)]
  | Trace _ | Thinking _ -> []
let render_part part =
  let* text,wrap = match part with
    | Unsupported_media -> Error "Telegram attachment requires a public media reference"
    | Plain text -> Ok(text,(fun s -> s))
    | Bold text -> Ok(text,(fun s -> "<b>"^s^"</b>"))
    | Pre text -> Ok(text,(fun s -> "<pre><code>"^s^"</code></pre>"))
    | Link {url;title} ->
      (match Uri.scheme(Uri.of_string url) with
       | Some ("https" | "http") -> Ok(title,(fun s -> "<a href=\"" ^ escape url ^ "\">" ^ s ^ "</a>"))
       | None | Some _ -> Error "Telegram media/link requires a public HTTP reference") in
  if String.trim text="" then Ok []
  else Channel_gate_telegram_state.chunks text
    |> Result.map_error (Format.asprintf "%a" Telegram_rest_client.pp_error)
    |> Result.map (List.map (fun chunk -> wrap(escape chunk)))
let render ~reply ~blocks =
  let parts = match blocks with
    | None | Some [] -> [Plain reply]
    | Some blocks -> List.concat_map parts blocks in
  let* messages = List.fold_left (fun result part ->
    let* acc = result in let* chunks = render_part part in Ok(List.rev_append chunks acc)) (Ok []) parts
    |> Result.map List.rev in
  match messages with
  | [] -> Error "Telegram visible reply has no public content"
  | _::_ -> Ok messages
