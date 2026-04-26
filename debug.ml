#use "topfind"

#require "masc_mcp"

let () =
  let agent_name = "keeper-direct-agent" in
  let keeper_name =
    Masc_mcp.Keeper_identity.canonical_keeper_name_from_agent_name agent_name
  in
  Printf.printf "from_agent_name: %s\n" (Option.value ~default:"NONE" keeper_name);
  let cname = Masc_mcp.Keeper_identity.canonical_keeper_name "keeper-direct" in
  Printf.printf "canonical: %s\n" (Option.value ~default:"NONE" cname)
;;
