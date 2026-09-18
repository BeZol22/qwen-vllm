import re
import unicodedata


def word_count(text: str) -> int:
    """Return the number of whitespace-separated words in text."""
    return len(text.split())


def slugify(text: str, max_length: int | None = None) -> str:
    """Return a lowercase hyphen-separated slug, accents stripped.

    Non-alphanumeric runs become a single hyphen; no leading/trailing
    hyphens. If max_length is given, truncate without a trailing hyphen.
    """
    if max_length is not None and max_length <= 0:
        raise ValueError("max_length must be a positive integer")
    text = "".join(ch for ch in unicodedata.normalize("NFKD", text)
                   if not unicodedata.combining(ch))
    text = text.lower()
    text = "".join(ch if ch.isalnum() else "-" for ch in text)
    text = re.sub(r"-+", "-", text)
    text = text.strip("-")
    if max_length is not None:
        text = text[:max_length].rstrip("-")
    return text
