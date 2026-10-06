module Catalog = Masc.Lane_addon_catalog
type t = {directory : string option; snapshot : Catalog.t option; cursor : int}
type event = Updated of t | Browse of string option | Preview of string | Manual | Jump | Declare | Cancel
let create ?directory () = {directory; snapshot=None; cursor=0}
let directory t = t.directory
let entries t = match t.snapshot with None -> [] | Some snapshot -> snapshot.entries
let selected t = List.nth_opt (entries t) t.cursor
let identity = function
  | Catalog.Folder path -> `Folder path
  | Catalog.Package package -> `Package package.manifest_path
  | Catalog.Issue issue -> `Issue issue.path
let receive json t =
  Result.map (fun (snapshot : Catalog.t) ->
    let previous = Option.map identity (selected t) in
    let cursor = match List.find_index (fun entry -> Some (identity entry) = previous) snapshot.entries with
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
  | "h" | "left" | "backspace" ->
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
  let capacity = max 1 (height - List.length header - 4) in
  let start = max 0 (min (t.cursor - capacity/2) (List.length rows-capacity)) in
  let visible = rows |> List.drop start |> List.take capacity
    |> List.mapi (fun index entry ->
      let label = match entry with
        | Catalog.Folder path -> "Folder  " ^ Filename.basename path
        | Package package -> "Package " ^ package.metadata.title ^ " · " ^ package.metadata.revision
        | Issue issue -> "Issue   " ^ Filename.basename (Filename.dirname issue.path) ^ "/" ^ Filename.basename issue.path in
      compact ((if start+index=t.cursor then "> " else "  ") ^ label)) in
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
        @ ["Enter rereads the package and image state; nothing is installed yet."] in
  header @ visible @ List.concat_map render details
