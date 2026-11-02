module String_map = Map.Make (String)

type node =
  | Readable of
      { page : string
      ; links : Wiki_link.link list
      ; sources : Wiki_sources.t
      ; revision : int
      }
  | Unreadable of
      { file : string
      ; reason : string
      }

type page_facts =
  { links : Wiki_link.link list
  ; sources : Wiki_sources.t
  ; revision : int
  }

type t =
  { pages : page_facts String_map.t
  ; unreadable : string String_map.t (* file -> reason *)
  ; incoming_by_page : int String_map.t
  }

let of_nodes nodes =
  let pages, unreadable =
    List.fold_left
      (fun (pages, unreadable) -> function
        | Readable { page; links; sources; revision } ->
          String_map.add page { links; sources; revision } pages, unreadable
        | Unreadable { file; reason } ->
          pages, String_map.add file reason unreadable)
      (String_map.empty, String_map.empty)
      nodes
  in
  let incoming_by_page =
    String_map.fold
      (fun page ({ links; _ } : page_facts) acc ->
         let targets =
           List.filter_map
             (fun (link : Wiki_link.link) ->
                match link.target with
                | Wiki_link.Page name when not (String.equal name page) -> Some name
                | Wiki_link.Page _
                | Wiki_link.Own_file _
                | Wiki_link.External _
                | Wiki_link.Invalid_name _
                | Wiki_link.Unsupported _ -> None)
             links
           |> List.sort_uniq String.compare
         in
         List.fold_left
           (fun acc name ->
              let count = Option.value (String_map.find_opt name acc) ~default:0 in
              String_map.add name (count + 1) acc)
           acc
           targets)
      pages
      String_map.empty
  in
  { pages; unreadable; incoming_by_page }
;;

let readable_pages t =
  String_map.bindings t.pages |> List.map fst
;;

let unreadable_files t =
  String_map.bindings t.unreadable
;;

let file_exists t name =
  String_map.mem name t.pages || String_map.mem (name ^ ".md") t.unreadable
;;

let links_of t name =
  match String_map.find_opt name t.pages with
  | Some { links; _ } -> links
  | None -> []
;;

let sources_of t name =
  Option.map (fun ({ sources; _ } : page_facts) -> sources) (String_map.find_opt name t.pages)
;;

let revision_of t name =
  Option.map (fun ({ revision; _ } : page_facts) -> revision) (String_map.find_opt name t.pages)
;;

let incoming t name = Option.value (String_map.find_opt name t.incoming_by_page) ~default:0
