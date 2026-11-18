type label = string * string

let add_key_segment buf s =
  Buffer.add_string buf (string_of_int (String.length s));
  Buffer.add_char buf ':';
  Buffer.add_string buf s
;;

let metric_key name (labels : label list) =
  let buf = Buffer.create (String.length name + 32) in
  add_key_segment buf name;
  List.iter
    (fun (k, v) ->
       add_key_segment buf k;
       add_key_segment buf v)
    labels;
  Buffer.contents buf
;;
