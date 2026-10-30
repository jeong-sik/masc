import pricing


def render(items):
    return "TOTAL: " + pricing.total(items, "KRW")
