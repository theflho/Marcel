"""Marcel's isolated web search, for the bots.

The bot that knows the user never touches the web: it only writes a question. The server
checks that question for anything personal (leaks), and, once the user said "Valider" (or under
an "auto" rule), the searcher fetches the results. The searcher is plain code, not a model: it
knows nothing but the question, reads no instruction and has no tool, so a trapped page can't
steer it. The pages come back to the bot as outside content; the bot has no tool either, so a
page can at worst mislead it. Before the reply reaches the user, links are cleaned so a page
can't have the bot smuggle data out in a URL.

Fetching pages from the server is guarded too: only http(s) to public addresses, checked again
after each redirect, so a page can't point the server at its own services.
"""

from __future__ import annotations

import asyncio
import html
import ipaddress
import re
import socket
from urllib.parse import parse_qs, quote_plus, urlsplit, urlunsplit

import httpx

ENGINE = "https://html.duckduckgo.com/html/?q="
MAX_QUESTION_CHARS = 200
MAX_RESULTS, MAX_PAGES = 5, 3
MAX_PAGE_BYTES, MAX_PAGE_CHARS = 400_000, 2500
TIMEOUT = httpx.Timeout(connect=5, read=10, write=5, pool=5)
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; MarcelSearch/1.0)", "Accept-Language": "fr-FR,fr;q=0.8"}

# What always counts as personal in a question, whoever the user is.
PATTERNS = {
    "une adresse e-mail": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "un numéro de téléphone": re.compile(r"(?:\+\d{1,3}[\s.-]?)?(?:\d[\s.-]?){9,}\d"),
    "un IBAN": re.compile(r"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,}", re.IGNORECASE),
    "une adresse postale": re.compile(r"\b\d{1,4}\s*(?:bis|ter)?,?\s+(?:rue|avenue|av\.?|boulevard|bd|chemin|allée|"
                                      r"impasse|place|route|quai|cours)\b", re.IGNORECASE),
}
# Facts of Marcel's memory that say who the user is: their capitalised words become private.
IDENTITY = re.compile(r"(s'appelle|je m'appelle|nom|prénom|habite|adresse|domicile|né[e]? |téléphone|"
                      r"travaille (chez|pour)|employeur|épouse|mari|femme|copine|copain|fils|fille)", re.IGNORECASE)
COMMON = {"Marcel", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche", "France",
          "Paris", "Il", "Elle", "Son", "Sa", "Ses", "Le", "La", "Les", "Un", "Une", "Utilisateur", "RMA"}


def identity_words(facts: list[str]) -> set[str]:
    words: set[str] = set()
    for fact in facts:
        if IDENTITY.search(fact):
            # Not the fact's first word, capitalised anyway.
            for word in re.findall(r"(?<=\s)[A-ZÀ-Ý][\wÀ-ÿ'-]{2,}", fact):
                if word not in COMMON:
                    words.add(word)
    return words


def leaks(question: str, private: set[str]) -> list[str]:
    """What is personal in the question, by name; empty when it can leave."""
    found = [name for name, pattern in PATTERNS.items() if pattern.search(question)]
    lowered = question.lower()
    found += [f"« {word} »" for word in sorted(private)
              if len(word) >= 3 and re.search(rf"(?<!\w){re.escape(word.lower())}(?!\w)", lowered)]
    return found


MARKDOWN_IMAGE = re.compile(r"!\[([^\]]*)\]\(([^)\s]*)[^)]*\)")
MARKDOWN_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)[^)]*\)")
BARE_URL = re.compile(r"(?<![(\[<])\bhttps?://[^\s)>\]]+")


def clean_url(url: str, private: set[str]) -> str | None:
    """The address without query nor fragment (where a page would hide data), or None when it
    isn't plain http(s) or still carries something personal."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        return None
    cleaned = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return None if leaks(cleaned.replace("/", " ").replace("-", " "), private) else cleaned


def clean_links(text: str, private: set[str]) -> str:
    """Images become their caption (the app never loads one); links lose their query string, or
    become plain text when their address isn't clean."""
    text = MARKDOWN_IMAGE.sub(lambda m: m.group(1), text)

    def link(match: re.Match) -> str:
        url = clean_url(match.group(2), private)
        return f"[{match.group(1)}]({url})" if url else match.group(1)

    text = MARKDOWN_LINK.sub(link, text)
    return BARE_URL.sub(lambda m: clean_url(m.group(0), private) or "[lien retiré]", text)


def public_host(host: str) -> bool:
    """True when every address of the host is on the public internet."""
    try:
        infos = socket.getaddrinfo(host, None)
    except (socket.gaierror, UnicodeError):
        return False
    for info in infos:
        address = ipaddress.ip_address(info[4][0].split("%")[0])
        if not address.is_global or address.is_multicast:
            return False
    return bool(infos)


async def fetch(client: httpx.AsyncClient, url: str) -> tuple[str, str] | None:
    """(final url, html) for a public http(s) page, following at most 3 redirects, each checked."""
    for _ in range(4):
        parts = urlsplit(url)
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or not await asyncio.to_thread(public_host, parts.hostname)):
            return None
        async with client.stream("GET", url, headers=HEADERS) as response:
            if response.is_redirect:
                url = str(response.url.join(response.headers.get("location", "")))
                continue
            if response.status_code != 200 or "html" not in response.headers.get("content-type", ""):
                return None
            body = b""
            async for chunk in response.aiter_bytes():
                body += chunk
                if len(body) > MAX_PAGE_BYTES:
                    break
            return url, body.decode(response.encoding or "utf-8", errors="replace")
    return None


def page_text(raw: str) -> str:
    raw = re.sub(r"(?is)<(script|style|noscript|svg|head|nav|footer|form)\b.*?</\1>", " ", raw)
    raw = re.sub(r"(?s)<!--.*?-->", " ", raw)
    text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
    return " ".join(text.split())[:MAX_PAGE_CHARS]


def engine_results(raw: str) -> list[dict]:
    """Titles, addresses and snippets from DuckDuckGo's plain HTML page."""
    results = []
    links = re.findall(r'(?s)<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>', raw)
    snippets = re.findall(r'(?s)class="result__snippet"[^>]*>(.*?)</a>', raw)
    for index, (href, title) in enumerate(links):
        href = html.unescape(href)
        if "uddg=" in href:
            href = parse_qs(urlsplit(href).query).get("uddg", [""])[0]
        if not href.startswith("http"):
            continue
        snippet = snippets[index] if index < len(snippets) else ""
        results.append({"title": page_text(title)[:150], "url": href, "snippet": page_text(snippet)[:300]})
        if len(results) >= MAX_RESULTS:
            break
    return results


async def search(question: str) -> list[dict]:
    """The results for the question, the first pages' text included. Knows nothing else."""
    async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False) as client:
        response = await client.get(ENGINE + quote_plus(question[:MAX_QUESTION_CHARS]), headers=HEADERS)
        response.raise_for_status()
        results = engine_results(response.text)
        for result in results[:MAX_PAGES]:
            try:
                page = await fetch(client, result["url"])
            except httpx.HTTPError:
                page = None
            result["text"] = page_text(page[1]) if page else ""
    return results


def results_text(results: list[dict]) -> str:
    if not results:
        return "Aucun résultat."
    return "\n\n".join(f"{i}. {r['title']}\n{r['url']}\n{r['snippet']}" + (f"\n{r['text']}" if r.get("text") else "")
                       for i, r in enumerate(results, 1))
