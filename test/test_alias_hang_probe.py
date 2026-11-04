import time

# Hangs on purpose: the targeted runner must still take this down with its own
# suite budget. The deps preparation moves the compile out of the budget; it
# must not move the body out of it.
print("hang probe: body started", flush=True)
time.sleep(900)
print("hang probe: body finished", flush=True)
