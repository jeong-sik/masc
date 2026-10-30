(rule
 (alias runtest-test_bedrock_sdk)
 (deps ../scripts/bedrock-sdk.py test_bedrock_sdk.py)
 (action (run python3 -B %{dep:test_bedrock_sdk.py})))
