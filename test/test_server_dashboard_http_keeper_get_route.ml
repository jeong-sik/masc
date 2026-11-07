(* The GET sub-route type. Every route is found by its own suffix, and no
   suffix ends another, which is why the order of the routes does not matter. *)

open Alcotest

module R = Server_dashboard_http_keeper_get_route

let prefix = "/api/v1/keepers/"

let pp ppf = function
  | None -> Format.pp_print_string ppf "None"
  | Some R.Fleet_composite -> Format.pp_print_string ppf "Fleet_composite"
  | Some (R.Keeper (route, name)) ->
    Format.fprintf ppf "Keeper (%s, %S)" (R.suffix route) name
;;

let routed = testable pp ( = )

let test_each_route_is_found_by_its_suffix () =
  List.iter
    (fun route ->
       let suffix = R.suffix route in
       check
         routed
         suffix
         (Some (R.Keeper (route, "k")))
         (R.of_path (prefix ^ "k" ^ suffix)))
    R.all
;;

let test_no_suffix_ends_another () =
  List.iter
    (fun a ->
       List.iter
         (fun b ->
            if a <> b
            then
              check
                bool
                (Printf.sprintf "%s ends %s" (R.suffix a) (R.suffix b))
                false
                (String.ends_with ~suffix:(R.suffix a) (R.suffix b)))
         R.all)
    R.all
;;

let test_keeper_name () =
  let metrics path name =
    check routed path (Some (R.Keeper (R.Metrics, name))) (R.of_path (prefix ^ path))
  in
  metrics "a/b/metrics" "a/b";
  metrics " a /metrics" "a";
  (* The name is not percent-decoded. The handler refuses what is no name. *)
  metrics "a%2Fb/metrics" "a%2Fb";
  (* A blank name reaches the handler, which refuses it. *)
  metrics " /metrics" "";
  check routed "a route needs a name" None (R.of_path (prefix ^ "/metrics"))
;;

let test_composite () =
  check routed "all keepers" (Some R.Fleet_composite) (R.of_path (prefix ^ "composite"));
  check
    routed
    "one keeper"
    (Some (R.Keeper (R.Composite, "k")))
    (R.of_path (prefix ^ "k/composite"));
  check routed "a trailing slash" None (R.of_path (prefix ^ "composite/"))
;;

let test_not_a_route () =
  check routed "outside the prefix" None (R.of_path "/api/v1/keeper/k/metrics");
  check routed "no prefix" None (R.of_path "/k/metrics");
  check routed "empty" None (R.of_path "");
  check routed "unknown suffix" None (R.of_path (prefix ^ "k/unknown"));
  check routed "the prefix alone" None (R.of_path prefix)
;;

let () =
  run
    "keeper_get_route"
    [ ( "of_path"
      , [ test_case
            "each route is found by its suffix"
            `Quick
            test_each_route_is_found_by_its_suffix
        ; test_case "no suffix ends another" `Quick test_no_suffix_ends_another
        ; test_case "keeper name" `Quick test_keeper_name
        ; test_case "composite" `Quick test_composite
        ; test_case "not a route" `Quick test_not_a_route
        ] )
    ]
;;
