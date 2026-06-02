type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric =
  { name : string
  ; help : string
  ; metric_type : metric_type
  ; value : float
  ; labels : label list
  }

let metric ~name ~help ~metric_type ~value ~labels =
  { name; help; metric_type; value; labels }
;;

let add_key_segment buf s =
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_char buf ':';
  Buffer.add_string buf s
;;

let labels_key labels =
  let buf = Buffer.create 32 in
  List.iter
    (fun (k, v) ->
       add_key_segment buf k;
       add_key_segment buf v)
    labels;
  Buffer.contents buf
;;

let metric_key name labels =
  let encoded_labels = labels_key labels in
  let buf = Buffer.create (String.length name + String.length encoded_labels + 16) in
  add_key_segment buf name;
  Buffer.add_string buf encoded_labels;
  Buffer.contents buf
;;

let type_to_string = function
  | Counter -> "counter"
  | Gauge -> "gauge"
  | Histogram -> "histogram"
;;

let labels_to_string = function
  | [] -> ""
  | labels ->
    let pairs =
      List.map (fun (k, v) -> Printf.sprintf "%s=\"%s\"" k (String.escaped v)) labels
    in
    "{" ^ String.concat "," pairs ^ "}"
;;

let has_metric_type metric_type (m : metric) = m.metric_type = metric_type

let choose_help name ms =
  let unlabeled = List.find_opt (fun (m : metric) -> m.labels = []) ms in
  match unlabeled with
  | Some m when m.help <> "" && m.help <> m.name -> m.help
  | _ ->
    let descriptive =
      List.find_opt (fun (m : metric) -> m.help <> "" && m.help <> m.name) ms
    in
    (match descriptive with
     | Some m -> m.help
     | None -> name)
;;

let is_histogram_count ~histogram_parents name =
  let suffix = "_count" in
  let suffix_len = String.length suffix in
  String.length name > suffix_len
  && String.sub name (String.length name - suffix_len) suffix_len = suffix
  &&
  let parent = String.sub name 0 (String.length name - suffix_len) in
  Hashtbl.mem histogram_parents parent
;;

let render snapshot =
  let buf = Buffer.create 1024 in
  let by_name = Hashtbl.create 32 in
  let values_by_key = Hashtbl.create 64 in
  List.iter
    (fun (m : metric) ->
       let existing = Hashtbl.find_opt by_name m.name |> Option.value ~default:[] in
       Hashtbl.replace by_name m.name (m :: existing);
       Hashtbl.replace values_by_key (metric_key m.name m.labels) m.value)
    snapshot;
  let histogram_parents = Hashtbl.create 8 in
  Hashtbl.iter
    (fun name ms ->
       if List.exists (has_metric_type Histogram) ms
       then Hashtbl.replace histogram_parents name true)
    by_name;
  Hashtbl.iter
    (fun name ms ->
       if is_histogram_count ~histogram_parents name
       then ()
       else (
         match ms with
         | [] -> ()
         | head_metric :: _ ->
           Printf.bprintf buf "# HELP %s %s\n" name (choose_help name ms);
           (match head_metric.metric_type with
            | Histogram ->
              Printf.bprintf buf "# TYPE %s summary\n" name;
              List.iter
                (fun (metric : metric) ->
                   let labels = labels_to_string metric.labels in
                   Printf.bprintf buf "%s_sum%s %g\n" name labels metric.value;
                   let count_key = metric_key (name ^ "_count") metric.labels in
                   let count_value =
                     Hashtbl.find_opt values_by_key count_key |> Option.value ~default:0.0
                   in
                   Printf.bprintf buf "%s_count%s %g\n" name labels count_value)
                ms
            | _ ->
              Printf.bprintf buf "# TYPE %s %s\n" name (type_to_string head_metric.metric_type);
              List.iter
                (fun (metric : metric) ->
                   Printf.bprintf
                     buf
                     "%s%s %g\n"
                     metric.name
                     (labels_to_string metric.labels)
                     metric.value)
                ms)))
    by_name;
  Buffer.contents buf
;;
