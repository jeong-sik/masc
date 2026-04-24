type site = string

type tuple_key = {
  raw_value : float;
  threshold : float;
  triggered : bool;
}

let make_tuple_key ~raw_value ~threshold ~triggered =
  { raw_value; threshold; triggered }

type site_stat = {
  site : site;
  count : int;
  unique_tuples : int;
  latest_timestamp : float option;
  triggered_true_count : int;
  triggered_false_count : int;
}

type report = {
  total_records : int;
  sites : site_stat list;
  degenerate_sites : site list;
  one_sided_sites : site list;
}

(* Chosen empirically from #7718 evidence: 51 records formed the
   regression signal; 20 is a conservative lower bound that still
   lets early-life sites avoid false positives. *)
let degenerate_min_records = 20

(* --- JSON extraction --------------------------------------------- *)

let json_field name (j : Yojson.Safe.t) =
  match j with
  | `Assoc pairs -> List.assoc_opt name pairs
  | _ -> None

let as_string = function `String s -> Some s | _ -> None

let as_float = function
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let as_bool = function `Bool b -> Some b | _ -> None

type parsed = {
  site : site;
  key : tuple_key;
  timestamp : float option;
}

let bind_field name conv j = Option.bind (json_field name j) conv

let parse_record (j : Yojson.Safe.t) : parsed option =
  let ( let* ) = Option.bind in
  let* site = bind_field "site" as_string j in
  let* raw = bind_field "raw_value" as_float j in
  let* thr = bind_field "threshold" as_float j in
  let* trig = bind_field "triggered" as_bool j in
  let ts = bind_field "timestamp" as_float j in
  Some
    {
      site;
      key = make_tuple_key ~raw_value:raw ~threshold:thr ~triggered:trig;
      timestamp = ts;
    }

(* --- Aggregation ------------------------------------------------- *)

module SiteTbl = Hashtbl.Make (struct
  type t = site
  let equal = String.equal
  let hash = Hashtbl.hash
end)

module KeySet = Set.Make (struct
  type t = tuple_key
  let compare (a : tuple_key) b =
    let c = Float.compare a.raw_value b.raw_value in
    if c <> 0 then c
    else
      let c = Float.compare a.threshold b.threshold in
      if c <> 0 then c else Bool.compare a.triggered b.triggered
end)

type accum = {
  mutable count : int;
  mutable keys : KeySet.t;
  mutable latest_ts : float option;
  mutable t_count : int;
  mutable f_count : int;
}

let fresh_accum () =
  { count = 0; keys = KeySet.empty; latest_ts = None; t_count = 0; f_count = 0 }

let merge_accum acc p =
  acc.count <- acc.count + 1;
  acc.keys <- KeySet.add p.key acc.keys;
  (match p.timestamp with
   | None -> ()
   | Some ts ->
     (match acc.latest_ts with
      | None -> acc.latest_ts <- Some ts
      | Some prev -> if ts > prev then acc.latest_ts <- Some ts));
  if p.key.triggered then acc.t_count <- acc.t_count + 1
  else acc.f_count <- acc.f_count + 1

let analyze (records : Yojson.Safe.t list) : report =
  let tbl : accum SiteTbl.t = SiteTbl.create 16 in
  let total = ref 0 in
  List.iter
    (fun r ->
      match parse_record r with
      | None -> ()
      | Some p ->
        incr total;
        let acc =
          match SiteTbl.find_opt tbl p.site with
          | Some a -> a
          | None ->
            let a = fresh_accum () in
            SiteTbl.add tbl p.site a;
            a
        in
        merge_accum acc p)
    records;
  let stats =
    SiteTbl.fold
      (fun site acc xs ->
        {
          site;
          count = acc.count;
          unique_tuples = KeySet.cardinal acc.keys;
          latest_timestamp = acc.latest_ts;
          triggered_true_count = acc.t_count;
          triggered_false_count = acc.f_count;
        }
        :: xs)
      tbl []
  in
  let stats =
    List.sort (fun (a : site_stat) (b : site_stat) ->
      String.compare a.site b.site) stats
  in
  let degenerate_sites =
    List.filter_map
      (fun (s : site_stat) ->
        if s.count >= degenerate_min_records && s.unique_tuples <= 1 then
          Some s.site
        else None)
      stats
  in
  let one_sided_sites =
    List.filter_map
      (fun (s : site_stat) ->
        if s.count < degenerate_min_records then None
        else if s.triggered_true_count = s.count
             || s.triggered_false_count = s.count
        then Some s.site
        else None)
      stats
  in
  {
    total_records = !total;
    sites = stats;
    degenerate_sites;
    one_sided_sites;
  }

let pretty_summary r =
  let site_lines =
    List.map
      (fun (s : site_stat) ->
        Printf.sprintf
          "  site=%s count=%d unique_tuples=%d triggered_true=%d triggered_false=%d"
          s.site s.count s.unique_tuples s.triggered_true_count
          s.triggered_false_count)
      r.sites
  in
  let header =
    Printf.sprintf
      "heuristic_metrics diagnostics: total=%d sites=%d degenerate=%d one_sided=%d"
      r.total_records (List.length r.sites)
      (List.length r.degenerate_sites)
      (List.length r.one_sided_sites)
  in
  String.concat "\n" (header :: site_lines)
