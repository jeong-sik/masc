(rule
 (alias runtest)
 (deps test_item_http_redirects.py ../scripts/item-http-acceptance.py)
 (action
  (run python3 -I %{dep:test_item_http_redirects.py}
   %{dep:../scripts/item-http-acceptance.py})))
