module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base

(** What each runtime is told about the network.

    A closed network is an isolation property, so it is spelled per runtime
    rather than in one grammar handed to all three. [container] and
    [nerdctl] take Docker's [--network none] / [--dns]. [msb] takes neither:
    [msb run --network none] answers "unexpected argument '--network' found"
    and [--dns] the same (0.6.16, 2026-09-04). Its own spellings are
    [--no-net] ("Disable all network access by default... without rules, the
    guest has no network reachability"), [--net <PROFILE>], and
    [--dns-nameserver <ADDR>].

    [Network_inherit] is a refusal for [msb]: leaving the flags off would
    hand the guest whatever msb's unstated default network is, and that is
    the difference between a keeper that reaches GitHub and one that reaches
    the host. What msb's default is has not been measured, so it is not
    assumed. [--no-net] answers [Network_none] and that is the only mode this
    module can say in msb's grammar today.

    Below is what was measured for Apple's runtime.

    [Network_none] closes it with [--network none].

    [Network_inherit] uses container's default network, which is a NAT
    ([container network inspect default] reports mode "nat"). A guest on it
    gets an address and a default route and reaches the outside: measured
    2026-08-28 on container 1.3.0, ping 8.8.8.8 answered in 39 ms, and with
    a nameserver supplied, HTTPS to api.github.com and `git ls-remote`
    against this repository both succeeded.

    The nameserver has to be supplied. The guest's /etc/resolv.conf points at
    the gateway, and the gateway does not answer DNS from inside the guest
    ("connection refused") even though the same port answers from the host.
    Without [--dns] the guest routes fine and resolves nothing, which reads
    as "no network" -- it is what made an earlier version of this module
    refuse [inherit] outright, on a claim that was wrong.

    [--network host] is a separate matter and still has no equivalent:
    container has no host network, and asking for one fails with "network
    host not found". [inherit] therefore means container's NAT, not the
    host's namespace, and the two differ in what the guest can reach on
    localhost. *)
(* One host-only network per keeper. Separate subnets keep a guest from
   reaching a neighbour's proxy and using its allowlist. Apple network names
   are narrower than guest names: at most 63 bytes, with lowercase
   alphanumeric first and last characters. *)
let policy_network_max_length = 63
let policy_network_digest_hex_length = 32
let policy_network_prefix = "masc-egress-policy-"

let policy_network_lower_alnum = function
  | 'a' .. 'z' | '0' .. '9' -> true
  | _ -> false
;;

let policy_network_ends_alnum value =
  String.length value > 0 && policy_network_lower_alnum value.[String.length value - 1]
;;

(* Reserve the digest suffix shape so an unhashed name cannot impersonate the
   bounded form of another keeper's name. *)
let policy_network_digest_shaped segment =
  let length = String.length segment in
  let suffix_at = length - policy_network_digest_hex_length - 1 in
  let rec hex_from index =
    index >= length
    ||
    (match segment.[index] with
     | '0' .. '9' | 'a' .. 'f' -> hex_from (index + 1)
     | _ -> false)
  in
  suffix_at >= 0
  && Char.equal segment.[suffix_at] '-'
  && hex_from (suffix_at + 1)
;;

let trim_policy_network_segment value =
  let rec last_alnum index =
    if index < 0 then -1
    else if policy_network_lower_alnum value.[index] then index
    else last_alnum (index - 1)
  in
  match last_alnum (String.length value - 1) with
  | -1 -> ""
  | last -> String.sub value 0 (last + 1)
;;

let policy_network_name ~keeper_name =
  let segment = Workspace_utils.safe_filename keeper_name in
  let candidate = policy_network_prefix ^ segment in
  let needs_digest =
    not (String.equal keeper_name segment)
    || String.length candidate > policy_network_max_length
    || not (policy_network_ends_alnum segment)
    || policy_network_digest_shaped segment
  in
  if not needs_digest
  then candidate
  else (
    let digest =
      String.sub
        Agent_core_sha256.(digest_string keeper_name |> to_hex)
        0
        policy_network_digest_hex_length
    in
    let keeper_room =
      policy_network_max_length
      - String.length policy_network_prefix
      - policy_network_digest_hex_length
      - 1
    in
    let kept =
      String.sub segment 0 (min (String.length segment) keeper_room)
      |> trim_policy_network_segment
    in
    Printf.sprintf "%s%s-%s" policy_network_prefix kept digest)
;;

let boot_plan_network ~keeper_name (mode : Keeper_types_profile_sandbox.network_mode) =
  match mode with
  | Keeper_types_profile_sandbox.Network_none -> Keeper_microvm_boot_plan.Network_none
  | Keeper_types_profile_sandbox.Network_inherit -> Keeper_microvm_boot_plan.Network_inherit
  | Keeper_types_profile_sandbox.Network_policy ->
    Keeper_microvm_boot_plan.Network_policy {name = policy_network_name ~keeper_name}
;;

(* The proxy a policy guest is pointed at: the gateway it sees the host at,
   and the port that keeper's listener bound. Both are discovered at boot --
   the gateway from the network, the port from the listener -- so neither is
   a constant here. *)
type policy_proxy =
  { gateway : string
  ; port : int
  }

let apple_policy_environment {gateway; port} =
  Egress_proxy_decision.client_env ~proxy_url:(Printf.sprintf "http://%s:%d" gateway port)
;;

let apple_network_args ~dns ~(policy_proxy : policy_proxy option)
      (network : Keeper_microvm_boot_plan.network) =
  (match network with
     | Keeper_microvm_boot_plan.Network_none -> Ok [ "--network"; "none" ]
     | Keeper_microvm_boot_plan.Network_inherit ->
       Ok
         (match dns with
          | Some server when String.trim server <> "" -> [ "--dns"; String.trim server ]
          | Some _ | None -> [])
     | Keeper_microvm_boot_plan.Network_policy {name} ->
       (match policy_proxy with
        | None ->
          (* A guest on this network has one route, and it is this proxy. A
             boot that does not know the address would produce a guest that
             reaches nothing and cannot say why, so it is refused instead. *)
          Error
            "microvm_policy_proxy_unknown: network_mode = \"policy\" needs the \
             address of this keeper's egress proxy, and the lane has not \
             reported one. The proxy is forked with the keeper lane; a guest \
             booting before it binds is refused rather than started with no \
             route."
        | Some { gateway; port } ->
          (* Three things, and all three are the policy rather than a default.

             The host-only network is the enforcement point. Measured
             2026-09-04 on container 1.3.1: a guest attached to an
             [--internal] network could not reach 1.1.1.1:443 or a public
             address by raw TCP, and could reach a listener on the host
             gateway. So a subprocess carrying its own socket does not get
             out, which is what proxy environment variables alone cannot
             promise.

             [--no-dns] leaves the guest with no resolver on purpose. The
             proxy speaks CONNECT, so the guest hands it a name and the proxy
             resolves it -- after the allowlist has judged that same name.
             One resolver, downstream of the matcher, is what closes the gap
             a null-byte bypass goes through: there is no second parser to
             disagree with the first.

             The proxy variables are how a client finds the one route that
             exists. They are convenience, not enforcement: a client that
             ignores them finds no route rather than a way around. Without
             them the guest is merely stuck, which is how this lane shipped
             and did not work. *)
          Ok
            ([ "--network"; name; "--no-dns" ]
             @ List.concat_map
                 (fun (name, value) -> [ "-e"; name ^ "=" ^ value ])
                 (apple_policy_environment {gateway; port}))))
;;

let network_args_for
      backend
      ~dns
      ~keeper_name
      ~(policy_proxy : policy_proxy option)
      (mode : Keeper_types_profile_sandbox.network_mode)
  =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    apple_network_args ~dns ~policy_proxy (boot_plan_network ~keeper_name mode)
  | Backend.Nerdctl_kata ->
    (match mode with
     | Keeper_types_profile_sandbox.Network_none -> Ok [ "--network"; "none" ]
     | Keeper_types_profile_sandbox.Network_inherit ->
       Ok
         (match dns with
          | Some server when String.trim server <> "" -> [ "--dns"; String.trim server ]
          | Some _ | None -> [])
     | Keeper_types_profile_sandbox.Network_policy ->
       Error
         "microvm_network_mode_unmeasured: nerdctl can create an internal \
          network, so the shape is plausible, but whether a Kata guest on one \
          can still reach a public address by raw TCP has not been measured \
          (RFC-0415). A mode that is policy on one backend and advice on \
          another is worse than one that refuses. Next: measure it, then \
          replace this arm.")
  | Backend.Microsandbox ->
    (match mode with
     | Keeper_types_profile_sandbox.Network_none -> Ok [ "--no-net" ]
     | Keeper_types_profile_sandbox.Network_policy ->
       Error
         "microvm_network_mode_unmeasured: msb spells its own network policy \
          (--no-net / --net <PROFILE>), and which profile leaves only a host \
          listener reachable has not been measured (RFC-0415). msb also does \
          not boot under masc today -- its list output carries no labels -- \
          so this arm has no live path to measure on yet."
     | Keeper_types_profile_sandbox.Network_inherit ->
       Error
         "microvm_network_mode_unexpressible: msb 0.6.16 rejects --network \
          and --dns and spells its own policy --no-net / --net <PROFILE> / \
          --dns-nameserver. --no-net answers network_mode = \"none\", but \
          what msb's network is with no flag at all has not been measured, \
          so network_mode = \"inherit\" is not handed to it as an omission. \
          Next: set network_mode = \"none\" on this Keeper, or measure msb's \
          default network and name the profile that matches inherit.")
;;

(* The two runtimes spell removal differently -- [container delete --force]
   against [msb remove --force] -- and stop the same way. Measured against
   msb 0.6.16 on 2026-09-03; a spelling this file guesses at would fail every
   call rather than fail once, so each is written from that CLI's own help. *)
(* Creating and checking the host-only network the policy lane attaches to.

   Only Apple's runtime answers these, because it is the only backend whose
   policy arm exists; the other two refuse the mode before anything asks for
   a network. Returning an error rather than an empty argv keeps that
   agreement visible: a backend that gained a policy arm without gaining
   these would fail here rather than boot a guest onto a network nobody
   created. *)
let policy_network_create_argv_for backend ~keeper_name =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    Ok
      (command_argv_for backend
       @ [ "network"; "create"; "--internal"; policy_network_name ~keeper_name ])
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    Error
      (Printf.sprintf
         "microvm_policy_network_unsupported: %s has no policy lane, so it has no \
          host-only network to create"
         (Backend.to_string backend))
;;

let policy_network_list_argv_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    (* [--format json], not the default table. The table is for a person, and
       reading it means splitting on whitespace and hoping the first column is
       the name -- a spacing change upstream would then read as "the network
       is absent" and boot a guest onto one nobody created. The machine form
       is asked for explicitly, the same way [msb inspect] is. *)
    Ok (command_argv_for backend @ [ "network"; "list"; "--format"; "json" ])
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    Error
      (Printf.sprintf
         "microvm_policy_network_unsupported: %s has no policy lane, so it has no \
          host-only network to list"
         (Backend.to_string backend))
;;

(* [container network list --format json] answers an array whose entries
   carry the network's [id]. Compared as a decoded string, so nothing here
   depends on how the CLI spaces a column.

   Unparseable JSON is an error rather than "absent". Reading a failed decode
   as absence would drive a create against a network that may already exist,
   and that create fails on this CLI -- so the guest would be refused with a
   message about creation rather than about the listing that could not be
   read. *)
let policy_network_present ~keeper_name ~listing =
  match Yojson.Safe.from_string listing with
  | `List entries ->
    let expected = policy_network_name ~keeper_name in
    List.fold_left
      (fun result entry ->
        Result.bind result (fun present ->
          match entry with
          | `Assoc fields ->
            (match List.filter_map
                     (fun (key, value) -> if String.equal key "id" then Some value else None)
                     fields with
             | [ `String id ] when String.trim id <> "" ->
               Ok (present || String.equal id expected)
             | [] -> Error "container network list: row has no id"
             | [ `String _ ] -> Error "container network list: row has a blank id"
             | [ _ ] -> Error "container network list: row id is not a string"
             | _ :: _ :: _ -> Error "container network list: row repeats id")
          | _ -> Error "container network list: expected an object row"))
      (Ok false)
      entries
  | _ -> Error "container network list: expected a JSON array"
  | exception Yojson.Json_error detail ->
    Error ("container network list: unparseable JSON: " ^ detail)
;;

let policy_network_inspect_argv_for backend ~keeper_name =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    (* No [--format json] here, unlike [network list]: [network inspect]
       rejects the flag ("Unknown option '--format'") and already answers
       JSON. Measured 2026-09-05 on container 1.3.1 -- the two subcommands
       do not agree, and assuming they did made every policy boot fail at
       reading the gateway. *)
    Ok (command_argv_for backend @ [ "network"; "inspect"; policy_network_name ~keeper_name ])
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    Error
      (Printf.sprintf
         "microvm_policy_network_unsupported: %s has no policy lane, so it has no \
          host-only network to inspect"
         (Backend.to_string backend))
;;

(* The gateway a guest on this network sees the host at. Read rather than
   assumed: container assigns the subnet when the network is created, so a
   compiled-in 192.168.128.1 would be right until someone had a network
   already on it. *)
let policy_network_gateway ~inspect =
  let open Result.Syntax in
  let fields name = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields
      else Error ("container network inspect: duplicate " ^ name ^ " key")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error ("container network inspect: invalid " ^ name)
  in
  let decode row =
    let* row = fields "row" row in
    match List.assoc_opt "status" row with
    | Some status ->
      let* status = fields "status" status in
      (match List.assoc_opt "ipv4Gateway" status with
       | Some (`String gateway) ->
         (match Ipaddr.V4.of_string gateway with
          | Ok address -> Ok (Ipaddr.V4.to_string address)
          | Error (`Msg _) -> Error "container network inspect: invalid status.ipv4Gateway")
       | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)
       | None -> Error "container network inspect: status.ipv4Gateway missing or invalid")
    | None -> Error "container network inspect: status missing"
  in
  match Yojson.Safe.from_string inspect with
  | `List [row] -> decode row
  | `Assoc _ as row -> decode row
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
  | `List [] | `List (_ :: _ :: _) ->
    Error "container network inspect: expected an object or a one-element array"
  | exception Yojson.Json_error _ -> Error "container network inspect: unparseable JSON"
;;
