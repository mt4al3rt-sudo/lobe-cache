"""Contoh target Python (pola sama dengan Research Factory D1: modul + test)."""


def slugify(text):
    out = []
    dash = False
    for ch in text.strip().lower():
        if ch.isalnum():
            out.append(ch)
            dash = False
        elif not dash:
            out.append("-")
            dash = True
    return "".join(out).strip("-")


def chunk(items, size):
    if size <= 0:
        raise ValueError("size harus > 0")
    return [items[i:i + size] for i in range(0, len(items), size)]


def pct(part, total):
    return 0.0 if total == 0 else round(part / total * 100, 2)


if __name__ == "__main__":
    print(slugify("Hello  World!"), pct(3, 8))
