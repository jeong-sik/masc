def greet(config):
    name = config.get("NAME", "")
    if not name:
        return "Hello, world!"
    return f"Hello, {name}!"
