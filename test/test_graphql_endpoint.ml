open Masc_mcp

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

let with_graphql_env ?graphql_url ?railway_url f =
  with_env "GRAPHQL_URL" graphql_url (fun () ->
    with_env "RAILWAY_GRAPHQL_URL" railway_url f)
;;

let test_explicit_graphql_url_takes_priority () =
  with_graphql_env
    ~graphql_url:"http://127.0.0.1:8935/graphql"
    ~railway_url:"second-brain-graphql-production.up.railway.app"
    (fun () ->
       Alcotest.(check string)
         "graphql_url"
         "http://127.0.0.1:8935/graphql"
         (Graphql_endpoint.graphql_url ()))
;;

let test_explicit_graphql_host_normalizes_for_local_dev () =
  with_graphql_env
    ~graphql_url:"127.0.0.1:8935"
    ~railway_url:"second-brain-graphql-production.up.railway.app"
    (fun () ->
       Alcotest.(check string)
         "graphql_url"
         "http://127.0.0.1:8935/graphql"
         (Graphql_endpoint.graphql_url ()))
;;

let test_railway_url_without_scheme_is_normalized () =
  with_graphql_env
    ?graphql_url:None
    ~railway_url:"second-brain-graphql-production.up.railway.app"
    (fun () ->
       Alcotest.(check string)
         "graphql_url"
         "https://second-brain-graphql-production.up.railway.app/graphql"
         (Graphql_endpoint.graphql_url ()))
;;

let test_default_falls_back_to_railway_production () =
  with_graphql_env ?graphql_url:None ?railway_url:None (fun () ->
    Alcotest.(check string)
      "graphql_url"
      "https://second-brain-graphql-production.up.railway.app/graphql"
      (Graphql_endpoint.graphql_url ()))
;;

let () =
  Alcotest.run
    "Graphql_endpoint"
    [ ( "resolution"
      , [ Alcotest.test_case
            "explicit GRAPHQL_URL wins"
            `Quick
            test_explicit_graphql_url_takes_priority
        ; Alcotest.test_case
            "explicit GRAPHQL_URL host normalizes"
            `Quick
            test_explicit_graphql_host_normalizes_for_local_dev
        ; Alcotest.test_case
            "RAILWAY_GRAPHQL_URL host normalizes"
            `Quick
            test_railway_url_without_scheme_is_normalized
        ; Alcotest.test_case
            "default uses Railway production"
            `Quick
            test_default_falls_back_to_railway_production
        ] )
    ]
;;
