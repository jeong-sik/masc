type request = {
  mime_type : string option;
  contents : Masc_tui_mcp.resource_content list;
  width : int;
  cell_pixels : int * int;
  colors : (string * string) option;
  sources : string list;
}
type image = { png : string; key : string; width : int; height : int }
type outcome = Pending | Ready of image | Failed of string
type t = { request : request; entries : (string * outcome) list }
module Sources = Set.Make (String)

let create ~mime_type ~contents ~width ~cell_pixels ~colors =
  let sources = Masc_tui_resource_images.images ~mime_type contents
    |> List.filter_map (function
      | _, Masc_tui_image_preview.Output_image {source=Inline_mermaid source;_} -> Some source
      | _, (Named_path _ | Staged _ | Stored_attachment _
        | Output_image {source=(Inline_data _ | Inline_svg _ | Server_path _ | Remote_uri _);_}
        | Unavailable_image _ | No_image) -> None)
    |> List.fold_left (fun (seen,ordered) source ->
      if Sources.mem source seen then seen,ordered
      else Sources.add source seen,source :: ordered) (Sources.empty,[])
    |> snd |> List.rev in
  let request = {mime_type;contents;width;cell_pixels;colors;sources} in
  {request;entries=List.map (fun source -> source, Pending) sources}

let request t = t.request
let sources (request : request) = request.sources
let width (request : request) = request.width
let colors (request : request) = request.colors
let cell_pixels t = t.request.cell_pixels
let owns contents t = t.request.contents == contents
let matches ~mime_type ~contents ~width ~cell_pixels ~colors t =
  t.request.contents == contents && t.request.width=width
  && t.request.mime_type=mime_type
  && t.request.cell_pixels=cell_pixels && t.request.colors=colors

let settle request ~source result t =
  if request != t.request then t
  else
    let outcome = match result with
      | Error detail -> Failed detail
      | Ok png ->
        (match Masc.Keeper_vision_tool.sniff_image_media_type png,
            Masc.Keeper_image_dimensions.image_dimensions png with
         | Ok "image/png", Some (width,height) when width > 0 && height > 0 ->
             Ready {png;key=Agent_core_sha256.(to_hex (digest_string png));width;height}
         | (Ok _ | Error _), (Some _ | None) -> Failed "Diagram renderer did not return a valid PNG") in
    {t with entries=List.map (fun (original,previous) ->
      original, (match previous with
        | Pending when String.equal original source -> outcome
        | Pending | Ready _ | Failed _ -> previous)) t.entries}

let image ~source t = match List.assoc_opt source t.entries with
  | Some (Ready image) -> Some image
  | Some (Pending | Failed _) | None -> None
let image_for_display ~source t =
  let matches = List.filter_map (fun (original,outcome) ->
    (* A closed fence's final line ended in LF. Restore that context before
       CRLF normalization, then remove only the synthetic terminal empty line. *)
    let lines = Masc_tui_text_block.lines (original ^ "\n") |> List.rev in
    let lines = match lines with "" :: rest -> List.rev rest | _ -> List.rev lines in
    let displayed = lines
      |> List.map Masc.Tui_terminal_text.sanitize_terminal_text |> String.concat "\n" in
    if String.equal source displayed then Some outcome else None) t.entries in
  match matches with
  | [Ready image] -> Some image
  | [] | [Pending | Failed _] | _ :: _ :: _ -> None
let failure ~source t = match List.assoc_opt source t.entries with
  | Some (Failed detail) -> Some detail
  | Some (Pending | Ready _) | None -> None
let failures t = List.filter_map (function
  | _, Failed detail -> Some detail | _, (Pending | Ready _) -> None) t.entries
let progress t =
  List.fold_left (fun (done_,total) (_,outcome) ->
    (done_+(match outcome with Pending -> 0 | Ready _ | Failed _ -> 1),total+1)) (0,0) t.entries
