type parse_error =
  | Empty
  | Too_long of { bytes : int }
  | Empty_label of { position : int }
  | Label_too_long of { position : int; bytes : int }
  | Label_edge_hyphen of { position : int }
  | Forbidden_byte of { offset : int; byte : char }

let escape_byte byte =
  (* Never render the offending byte raw: it reaches logs and evidence rows,
     and the whole point of this module is that a NUL or a CR read one way
     here and another way downstream. *)
  Printf.sprintf "\\x%02x" (Char.code byte)
;;

let parse_error_to_string = function
  | Empty -> "host is empty"
  | Too_long { bytes } ->
    Printf.sprintf "host is %d bytes, over the 253-byte name ceiling" bytes
  | Empty_label { position } ->
    Printf.sprintf "label %d is empty" position
  | Label_too_long { position; bytes } ->
    Printf.sprintf "label %d is %d bytes, over the 63-byte label ceiling" position bytes
  | Label_edge_hyphen { position } ->
    Printf.sprintf "label %d starts or ends with a hyphen" position
  | Forbidden_byte { offset; byte } ->
    Printf.sprintf "byte %s at offset %d is not allowed in a host"
      (escape_byte byte) offset
;;

(* The DNS ceilings. Named because an unexplained 253 in a security check is
   the kind of constant a later edit rounds up. *)
let max_name_bytes = 253
let max_label_bytes = 63

type t =
  | Name of string list  (** normalized labels, lower-cased, apex last *)
  | Ip_literal of string

let is_ip_literal = function Ip_literal _ -> true | Name _ -> false

let to_string = function
  | Ip_literal address -> address
  | Name labels -> String.concat "." labels
;;

let lower_byte c = if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c

let byte_is_allowed = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' -> true
  | _ -> false
;;

(* Everything a resolver could read differently is refused here, before any
   comparison happens. The scan is over bytes rather than over a split,
   because splitting first would let a NUL ride inside a label unexamined. *)
let scan_bytes raw =
  let length = String.length raw in
  let rec walk offset =
    if offset >= length then Ok ()
    else
      let byte = raw.[offset] in
      if byte_is_allowed byte then walk (offset + 1)
      else Error (Forbidden_byte { offset; byte })
  in
  walk 0
;;

let check_label position label =
  let bytes = String.length label in
  if bytes = 0 then Error (Empty_label { position })
  else if bytes > max_label_bytes then Error (Label_too_long { position; bytes })
  else if label.[0] = '-' || label.[bytes - 1] = '-' then
    Error (Label_edge_hyphen { position })
  else Ok ()
;;

let rec check_labels position = function
  | [] -> Ok ()
  | label :: rest ->
    (match check_label position label with
     | Error _ as error -> error
     | Ok () -> check_labels (position + 1) rest)
;;

(* An IPv4 literal, and only that shape. A destination that is an address
   has to stay distinguishable from a name, so that a name rule can never
   answer for it -- an allowlist of [github.com] must not admit a connection
   to github's address. IPv6 does not reach this module: it cannot survive
   [scan_bytes], which refuses the colon, so an IPv6 destination is a
   refusal rather than a silent name. *)
let is_ipv4_literal labels =
  List.length labels = 4
  && List.for_all
       (fun label ->
         let bytes = String.length label in
         bytes >= 1
         && bytes <= 3
         && String.for_all (function '0' .. '9' -> true | _ -> false) label
         && int_of_string_opt label |> Option.fold ~none:false ~some:(fun n -> n <= 255))
       labels
;;

let normalize raw =
  match scan_bytes raw with
  | Error _ as error -> error
  | Ok () ->
    let lowered = String.map lower_byte raw in
    (* One trailing dot is the absolute form of the same name, so it is
       dropped rather than refused. A second one leaves an empty label and
       is refused by [check_labels]. *)
    let trimmed =
      let length = String.length lowered in
      if length > 0 && lowered.[length - 1] = '.' then String.sub lowered 0 (length - 1)
      else lowered
    in
    if String.equal trimmed "" then Error Empty
    else if String.length trimmed > max_name_bytes then
      Error (Too_long { bytes = String.length trimmed })
    else
      let labels = String.split_on_char '.' trimmed in
      (match check_labels 0 labels with
       | Error _ as error -> error
       | Ok () -> Ok labels)
;;

let parse raw =
  match normalize raw with
  | Error _ as error -> error
  | Ok labels ->
    if is_ipv4_literal labels then Ok (Ip_literal (String.concat "." labels))
    else Ok (Name labels)
;;

type rule_host =
  | Exact of t
  | Subdomains_of of string list
      (** [*.example.com] as the labels of its apex. *)

type rule =
  { rule_host : rule_host
  ; port : int
  }

let default_rule_port = 443
let rule_port rule = rule.port

let rule_host_to_string = function
  | Exact host -> to_string host
  | Subdomains_of labels -> "*." ^ String.concat "." labels
;;

let rule_to_string rule =
  if Int.equal rule.port default_rule_port then rule_host_to_string rule.rule_host
  else Printf.sprintf "%s:%d" (rule_host_to_string rule.rule_host) rule.port
;;

(* The port is split off here, at the last colon, and nowhere else. A second
   splitter could disagree with this one about which bytes are the host, and
   a disagreement about that boundary is what an allowlist bypass is. The
   host parser refuses a colon outright, so a host that kept one would be
   refused rather than silently re-read. *)
let split_port raw =
  match String.rindex_opt raw ':' with
  | None -> Ok (raw, default_rule_port)
  | Some index ->
    let host = String.sub raw 0 index in
    let port_text = String.sub raw (index + 1) (String.length raw - index - 1) in
    (match int_of_string_opt port_text with
     | Some port when port > 0 && port <= 65535 -> Ok (host, port)
     (* Not a port, so the colon belongs to the host -- and a host with a
        colon in it is refused by the host parser, which is where that
        refusal should come from. *)
     | Some _ | None -> Ok (raw, default_rule_port))
;;

let rule_of_string raw =
  match split_port raw with
  | Error _ as error -> error
  | Ok (host_text, port) ->
    let wildcard_prefix = "*." in
    let prefix_length = String.length wildcard_prefix in
    if
      String.length host_text > prefix_length
      && String.equal (String.sub host_text 0 prefix_length) wildcard_prefix
    then (
      let apex =
        String.sub host_text prefix_length (String.length host_text - prefix_length)
      in
      match normalize apex with
      | Error _ as error -> error
      | Ok labels -> Ok { rule_host = Subdomains_of labels; port })
    else (
      match parse host_text with
      | Error _ as error -> error
      | Ok host -> Ok { rule_host = Exact host; port })
;;

let equal_rule_host left right =
  match left, right with
  | Exact left, Exact right ->
    (match left, right with
     | Name left, Name right -> List.equal String.equal left right
     | Ip_literal left, Ip_literal right -> String.equal left right
     | Name _, Ip_literal _ | Ip_literal _, Name _ -> false)
  | Subdomains_of left, Subdomains_of right -> List.equal String.equal left right
  | Exact _, Subdomains_of _ | Subdomains_of _, Exact _ -> false
;;

let equal_rule left right =
  Int.equal left.port right.port && equal_rule_host left.rule_host right.rule_host
;;

let pp_rule formatter rule = Format.pp_print_string formatter (rule_to_string rule)

(* Suffix comparison on labels, not on the string. [notexample.com] shares no
   label boundary with [example.com], so it cannot be admitted here the way
   an [endsWith] check would admit it. *)
let rec labels_end_with ~suffix labels =
  let extra = List.length labels - List.length suffix in
  if extra < 0 then false
  else if extra = 0 then List.equal String.equal labels suffix
  else
    match labels with
    | [] -> false
    | _ :: rest -> labels_end_with ~suffix rest
;;

let matches_host rule_host host =
  match rule_host, host with
  | Exact (Ip_literal expected), Ip_literal actual -> String.equal expected actual
  | Exact (Name expected), Name actual -> List.equal String.equal expected actual
  | Exact (Ip_literal _), Name _ | Exact (Name _), Ip_literal _ -> false
  (* A wildcard is a statement about names. An address is not a subdomain of
     anything, so it is never admitted by one. *)
  | Subdomains_of _, Ip_literal _ -> false
  | Subdomains_of apex, Name actual ->
    (* Strictly below the apex: [*.example.com] answers for
       [api.example.com] and refuses [example.com]. *)
    List.length actual > List.length apex && labels_end_with ~suffix:apex actual
;;

let matches rule host ~port =
  Int.equal rule.port port && matches_host rule.rule_host host
;;

let admits rules host ~port = List.exists (fun rule -> matches rule host ~port) rules

let admits_host rules host =
  List.exists (fun rule -> matches_host rule.rule_host host) rules
;;

let ports_for_host rules host =
  rules
  |> List.filter_map (fun rule ->
       if matches_host rule.rule_host host then Some rule.port else None)
  |> List.sort_uniq Int.compare
;;
