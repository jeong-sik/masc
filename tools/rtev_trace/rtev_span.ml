type span =
  { span_name : string
  ; span_domain : int
  ; enter_ns : int64
  ; mutable exit_ns : int64 option
  ; mutable run_ns : int64
  ; waits : (string, int64) Hashtbl.t
  ; parent : span option
  }

type book =
  { own_spans : (int, span list) Hashtbl.t
  ; inherited_span : (int, span) Hashtbl.t
  }

let create () = { own_spans = Hashtbl.create 1024; inherited_span = Hashtbl.create 4096 }
let is_open sp = Option.is_none sp.exit_ns

let active book fiber =
  match Hashtbl.find_opt book.own_spans fiber with
  | Some (sp :: _) -> Some sp
  | Some [] | None ->
    (match Hashtbl.find_opt book.inherited_span fiber with
     | Some sp when is_open sp -> Some sp
     | Some _ | None -> None)
;;

let inherit_from book ~creator ~child =
  match active book creator with
  | Some sp -> Hashtbl.replace book.inherited_span child sp
  | None -> ()
;;

(* [sp] and the sections around it, innermost first. A section that has ended
   is passed over and the ones around it are still reached. *)
let rec around sp f =
  if is_open sp then f sp;
  Option.iter (fun enclosing -> around enclosing f) sp.parent
;;

let enter book ~fiber ~domain ~name ~ts ~segment_start =
  (* The running segment began before the section: count only the part after
     [ts] by starting below zero. [ran] adds the whole segment. *)
  let sp =
    { span_name = name
    ; span_domain = domain
    ; enter_ns = ts
    ; exit_ns = None
    ; run_ns = Int64.neg (Int64.sub ts segment_start)
    ; waits = Hashtbl.create 4
    ; parent = active book fiber
    }
  in
  let stack = Option.value ~default:[] (Hashtbl.find_opt book.own_spans fiber) in
  Hashtbl.replace book.own_spans fiber (sp :: stack)
;;

let leave book ~fiber ~ts ~segment_start =
  match Hashtbl.find_opt book.own_spans fiber with
  | Some (sp :: rest) ->
    (* The running segment goes on after the section; count its part up to
       [ts] now, as [ran] adds nothing to a closed section. *)
    sp.run_ns <- Int64.add sp.run_ns (Int64.sub ts segment_start);
    sp.exit_ns <- Some ts;
    if rest = [] then Hashtbl.remove book.own_spans fiber
    else Hashtbl.replace book.own_spans fiber rest;
    Some sp
  | Some [] | None -> None
;;

let ran book ~fiber ~dur =
  match active book fiber with
  | Some sp -> around sp (fun s -> s.run_ns <- Int64.add s.run_ns dur)
  | None -> ()
;;

let waited book ~fiber ~reason ~dur =
  match active book fiber with
  | Some sp ->
    around sp (fun s ->
      let prior = Option.value ~default:0L (Hashtbl.find_opt s.waits reason) in
      Hashtbl.replace s.waits reason (Int64.add prior dur))
  | None -> ()
;;
