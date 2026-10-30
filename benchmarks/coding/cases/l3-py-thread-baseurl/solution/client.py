from settings import base_url


def endpoint(path):
    return base_url() + path
