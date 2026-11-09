import calc


def test_slugify_basic():
    assert calc.slugify("Hello  World!") == "hello-world"


def test_slugify_trim():
    assert calc.slugify("  --A  B--  ") == "a-b"


def test_chunk_split():
    assert calc.chunk([1, 2, 3, 4, 5], 2) == [[1, 2], [3, 4], [5]]


def test_chunk_invalid():
    try:
        calc.chunk([], 0)
    except ValueError:
        return
    raise AssertionError("harus raise ValueError")


def test_pct():
    assert calc.pct(3, 8) == 37.5
    assert calc.pct(1, 0) == 0.0
