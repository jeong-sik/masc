; Every chat-store writer announces the rows it appends, and only those.

(test
 (name test_keeper_chat_store_announces)
 (modules test_keeper_chat_store_announces)
 (libraries masc_test_deps))
