module Catalog = Masc.Lane_addon_catalog
type t = {directory : string option; snapshot : Catalog.t option; cursor : int}
type event = Updated of t | Browse of string option | Preview of string | Manual | Jump | Declare | Cancel
let create ?directory () = {directory; snapshot=None; cursor=0}
let directory t = t.directory
module Category = Masc.Lane_addon_category
let category_rank = function
  | Some Category.Memory_and_judgment -> 0 | Some Category.Browser -> 1
  | Some Category.External_communications -> 2 | Some Category.Voice_and_media -> 3
  | Some Category.Execution_environment -> 4 | Some Category.Analysis -> 5
  | None -> 6
let category_label = function
  | Some Category.Memory_and_judgment -> "Memory & judgment" | Some Category.Browser -> "Browser"
  | Some Category.External_communications -> "External communications"
  | Some Category.Voice_and_media -> "Voice & media"
  | Some Category.Execution_environment -> "Execution environment"
  | Some Category.Analysis -> "Analysis" | None -> "Unclassified"
type placement = Navigation | Role of Category.t option
let placement = function
  | Catalog.Package package -> Role package.metadata.ui_category
  | Catalog.Folder _ | Catalog.Issue _ -> Navigation
(* One presented order serves rendering, selection and Enter/Right: folders and
   issues keep their discovery order ahead of the packages, which are grouped by
   their declared role. Headers are drawn from this order and never selectable. *)
let present entries =
  let rank e = match placement e with Navigation -> -1 | Role c -> category_rank c in
  List.stable_sort (fun a b -> Int.compare (rank a) (rank b)) entries
let entries t = match t.snapshot with None -> [] | Some snapshot -> present snapshot.entries
let selected t = List.nth_opt (entries t) t.cursor
let identity = function
  | Catalog.Folder path -> `Folder path
  | Catalog.Package package -> `Package package.manifest_path
  | Catalog.Issue issue -> `Issue issue.path
let receive json t =
  Result.map (fun (snapshot : Catalog.t) ->
    let previous = Option.map identity (selected t) in
    let cursor = match List.find_index (fun entry -> Some (identity entry) = previous) (present snapshot.entries) with
      | Some index -> index | None -> 0 in
    {directory=Some snapshot.directory; snapshot=Some snapshot; cursor}) (Catalog.of_json json)
let selected_manifest t = match selected t with
  | Some (Catalog.Package package) -> Some package.manifest_path
  | Some (Folder _ | Issue _) | None -> None
let handle ~key t =
  match key with
  | "esc" -> Ok Cancel
  | "p" -> Ok Manual
  | "g" -> Ok Jump
  | "n" -> Ok Declare
  | "r" -> Ok (Browse t.directory)
  | "j" | "down" -> Ok (Updated {t with cursor=min (max 0 (List.length (entries t)-1)) (t.cursor+1)})
  | "k" | "up" -> Ok (Updated {t with cursor=max 0 (t.cursor-1)})
  | "home" -> Ok (Updated {t with cursor=0})
  | "end" -> Ok (Updated {t with cursor=max 0 (List.length (entries t)-1)})
  | "h" | "left" | "backspace" | "\127" | "\b" ->
      (* A folder that was never read has no known parent: a remembered folder
         may since have been removed or belong to another worktree. The
         workspace root does not depend on that folder. *)
      (match t.snapshot,t.directory with
       | Some {parent=None;_},_ | None,None -> Ok (Updated t)
       | Some {parent=Some path;_},_ -> Ok (Browse (Some path))
       | None,Some _ -> Ok (Browse None))
  | "l" | "right" | "enter" | "\r" | "\n" ->
      (match selected t with
       | None -> Ok (Updated t)
       | Some (Folder path) -> Ok (Browse (Some path))
       | Some (Issue issue) -> Error issue.message
       | Some (Package package) ->
           if key="l" || key="right" then Ok (Browse (Some (Filename.dirname package.manifest_path)))
           else Ok (Preview package.manifest_path))
  | _ -> Ok (Updated t)
let left_hint t = match t.snapshot,t.directory with
  | None,Some _ -> "Left:workspace root"
  | Some _,_ | None,None -> "Left:parent"
let hints t = String.concat "  " ["j/k:select";"Enter:open";left_hint t;"Right:folder";
  "g:directory";"p:manifest";"n:new TOML";"PgUp/PgDn:details";"Esc:cancel"]
let lines ~height ~render t =
  let compact line = match render line with [] -> "" | [line] -> line | first::_ -> first in
  let rows = entries t in
  let header = List.map compact ["Choose a local package · j/k:select · Enter:open";
    ("Folder: " ^ (match t.directory with None -> "workspace root" | Some path -> path));
    left_hint t ^ " · Right:folder · g:directory · p:manifest · n:new TOML · r:reload · Esc:cancel";
    Printf.sprintf "%d/%d entries · lane.toml in this folder and immediate child folders"
      (if rows=[] then 0 else t.cursor+1) (List.length rows)] in
  let capacity = max 1 (height - List.length header - 6) in
  (* Role headers occupy screen lines, so the window is computed over the drawn
     lines (headers included) and always contains the selected entry's line. *)
  let drawn = rows |> List.mapi (fun index entry ->
    let heading = match placement entry with
      | Navigation -> None
      | Role category ->
          let previous = if index=0 then Navigation else placement (List.nth rows (index-1)) in
          if previous = Role category then None else Some (compact ("-- " ^ category_label category ^ " --")) in
    let label = match entry with
      | Catalog.Folder path -> "Folder  " ^ Filename.basename path
      | Package package -> "Package " ^ package.metadata.title ^ " · " ^ package.metadata.revision
      | Issue issue -> "Issue   " ^ Filename.basename (Filename.dirname issue.path) ^ "/" ^ Filename.basename issue.path in
    (index, heading, compact ((if index=t.cursor then "> " else "  ") ^ label))) in
  let all_lines = List.concat_map (fun (index, heading, line) ->
    (match heading with Some h -> [(index, Some h, h)] | None -> []) @ [(index, None, line)]) drawn in
  let total = List.length all_lines in
  let cursor_line = match List.find_index (fun (index, h, _) -> index=t.cursor && h=None) all_lines with
    | Some i -> i | None -> 0 in
  let start = max 0 (min (cursor_line - capacity/2) (total-capacity)) in
  let window = all_lines |> List.drop start |> List.take capacity in
  let current_heading index =
    List.find_map (fun (i, h, _) -> if i=index then h else None) all_lines in
  let visible = match window with
    | (index, None, _) :: rest when start < cursor_line && index <> t.cursor && start > 0 ->
        (match current_heading index with
         | Some h -> List.map (fun (_, _, l) -> l) ((index, Some h, h) :: rest)
         | None -> List.map (fun (_, _, l) -> l) window)
    | _ -> List.map (fun (_, _, l) -> l) window in
  let details = match selected t with
    | None -> [match t.snapshot,t.directory with
               | None,None -> "Read a folder or use p to enter a manifest path."
               | None,Some _ -> "No folder read yet. Left:workspace root · g:directory · p:manifest"
               | Some _,_ -> "No local packages or child folders here. Left:parent · g:directory · p:manifest"]
    | Some (Folder path) -> [path;"Enter opens this folder."]
    | Some (Issue issue) -> [issue.path;issue.message]
    | Some (Package package) ->
        [package.metadata.title ^ " · revision " ^ package.metadata.revision;package.manifest_path]
        @ Option.to_list package.metadata.description
        @ ["Enter rereads the package execution; nothing is installed yet."] in
  header @ visible @ List.concat_map render details
