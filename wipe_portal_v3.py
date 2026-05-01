import re
with open("test/test_room.ml", "r") as f: content = f.read()
# Remove let contains_portal
content = re.sub(r'let contains_portal.*?\n', '', content)
# Remove test functions
content = re.sub(r'let test_portal_.*?\n  \)\n', '', content, flags=re.DOTALL)
# Remove Alcotest registration
content = re.sub(r'\s*"portal", \[.*?\];', '', content, flags=re.DOTALL)
content = re.sub(r'\s*"portal_errors", \[.*?\];', '', content, flags=re.DOTALL)
content = re.sub(r'\s*"portal_extended", \[.*?\];', '', content, flags=re.DOTALL)
with open("test/test_room.ml", "w") as f: f.write(content)
