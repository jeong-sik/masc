type label = string * string

let add_key_segment buf s =
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_char buf ':';
  Buffer.add_string buf s
;;

let labels_key (labels : label list) =
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
