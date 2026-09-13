import json
decoder = json.JSONDecoder()

def raw_value(text, path):
    if not path:
        start = len(text) - len(text.lstrip())
        _, end = decoder.raw_decode(text, start)
        return text[start:end]
    value = json.loads(text)
    index = len(text) - len(text.lstrip()) + 1
    wanted, *remaining = path
    def skip(i):
        while i < len(text) and text[i] in ' \n\r\t':
            i += 1
        return i
    if isinstance(value, dict):
        while True:
            index = skip(index)
            if text[index] == '}':
                raise KeyError(wanted)
            key, index = decoder.raw_decode(text, index)
            index = skip(index)
            assert text[index] == ':'
            start = skip(index + 1)
            _, end = decoder.raw_decode(text, start)
            if key == wanted:
                return raw_value(text[start:end], remaining)
            index = skip(end)
            if text[index] == ',':
                index += 1
    elif isinstance(value, list):
        for item_index in range(len(value)):
            start = skip(index)
            _, end = decoder.raw_decode(text, start)
            if item_index == wanted:
                return raw_value(text[start:end], remaining)
            index = skip(end)
            if text[index] == ',':
                index += 1
        raise IndexError(wanted)
    else:
        raise TypeError('JSON path crosses a scalar')

