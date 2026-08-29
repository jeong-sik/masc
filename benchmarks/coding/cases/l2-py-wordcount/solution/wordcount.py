def word_counts(text):
    counts = {}
    for token in text.split():
        key = token.lower()
        counts[key] = counts.get(key, 0) + 1
    return counts
