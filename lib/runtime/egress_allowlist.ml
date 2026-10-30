type t =
  { keeper_name : string
  ; allow : Egress_host.rule list [@printer fun fmt rules ->
      Format.fprintf fmt "[%s]"
        (String.concat "; " (List.map Egress_host.rule_to_string rules))]
  }
[@@deriving show, eq]

let allow_strings t = List.map Egress_host.rule_to_string t.allow

let for_keeper entries ~keeper_name =
  List.find_opt (fun entry -> String.equal entry.keeper_name keeper_name) entries
;;
