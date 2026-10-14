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
  { pages : (string, page_facts) Hashtbl.t
  ; unreadable : (string, string) Hashtbl.t  (* file -> reason *)
  ; incoming_by_page : (string, int) Hashtbl.t
  }

let of_nodes nodes =
  let pages = Hashtbl.create 64 in
  let unreadable = Hashtbl.create 8 in
  List.iter
    (function
      | Readable { page; links; sources; revision } ->
        Hashtbl.replace pages page { links; sources; revision }
      | Unreadable { file; reason } -> Hashtbl.replace unreadable file reason)
    nodes;
  let incoming_by_page = Hashtbl.create 64 in
  Hashtbl.iter
    (fun page ({ links; _ } : page_facts) ->
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
       List.iter
         (fun name ->
            let count = Option.value (Hashtbl.find_opt incoming_by_page name) ~default:0 in
            Hashtbl.replace incoming_by_page name (count + 1))
         targets)
    pages;
  { pages; unreadable; incoming_by_page }
;;

let sorted_keys table =
  Hashtbl.fold (fun key _ acc -> key :: acc) table [] |> List.sort String.compare
;;

let readable_pages t = sorted_keys t.pages

let unreadable_files t =
  sorted_keys t.unreadable
  |> List.map (fun file -> file, Hashtbl.find t.unreadable file)
;;

let file_exists t name =
  Hashtbl.mem t.pages name || Hashtbl.mem t.unreadable (name ^ ".md")
;;

let links_of t name =
  match Hashtbl.find_opt t.pages name with
  | Some { links; _ } -> links
  | None -> []
;;

let sources_of t name =
  Option.map (fun ({ sources; _ } : page_facts) -> sources) (Hashtbl.find_opt t.pages name)
;;

let revision_of t name =
  Option.map (fun ({ revision; _ } : page_facts) -> revision) (Hashtbl.find_opt t.pages name)
;;

let incoming t name = Option.value (Hashtbl.find_opt t.incoming_by_page name) ~default:0
