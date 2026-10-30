def total(items, currency):
    amount = sum(items)
    if currency == "KRW":
        return f"{amount}won"
    return f"{amount}{currency}"
