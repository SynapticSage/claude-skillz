#!/usr/bin/env python3
"""org2md — deterministic org → Obsidian converter + judgment harness.

Design philosophy (from the migration-feedback memory):

    Mechanical / syntactic conversion is automated HERE.
    SEMANTIC restructuring is NOT — this tool *detects and reports* the
    judgment calls and the calling agent *applies* them. Linter, not sed.

The headline judgment call is **header-vs-bullet**: org `*`/`**`/`***`
encode outline DEPTH but not whether a node is a true section heading or
just a nested bullet. The syntax can't tell them apart; only a human/agent
can. So this tool never decides that on its own:

    1. `convert --outline file.org`
         Parse the org outline into a tree, compute per-node signal and a
         low-confidence *suggestion*. Emit the judgment plan. No final md.
    2. agent reads original + plan, calls each ambiguous node header|bullet,
       writes a tiny decisions map {line: kind}.
    3. `convert --decisions map.json file.org`
         Render final markdown. The script handles only MECHANICAL
         re-leveling: heading level = HEADER-ancestors+1, bullet indent =
         BULLET-ancestors since the last header. TODO nodes always render
         as Obsidian Tasks regardless of classification.

Attachments: org-attach is a content-addressed store. `[[attachment:x]]`
resolves against the NEAREST ancestor (heading or file) bearing :ID: / :DIR:,
expanded as data/<id[:2]>/<id[2:]>/. We track that inherited id through the
tree so each embed resolves to its true source folder.

`convert` is pure (reads one .org, prints JSON, touches nothing). Stateful
subcommands: `stage` (move source → _migrated/) and `pull-attachments`
(copy a note's assets into its Obsidian folder). Both md5-verify and refuse
to overwrite.

    index            [--source-root DIR] [--rebuild-index]
    stage            <file.org> [...] [--execute]
    pull-attachments <file.org> --into <dir> [--execute] [--move]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ─── locations ────────────────────────────────────────────────────────────────

DEFAULT_SOURCE_ROOT = Path.home() / "Documents/org/roam"
STAGING_ROOT = Path.home() / "Documents/org/roam/_migrated"
CACHE_DIR = Path.home() / ".cache/org2obsidian"
INDEX_PATH = CACHE_DIR / "id_index.json"


# ═══════════════════════════════════════════════════════════════════════════════
# id → title index  (fresh scan beats the static manifest; ids duplicated across
# A/B/C copies resolve to the same title, so we dedupe by id)
# ═══════════════════════════════════════════════════════════════════════════════

_ID_RE = re.compile(r"^:ID:\s+(\S+)", re.MULTILINE)
_TITLE_RE = re.compile(r"^#\+title:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)


def build_index(source_root: Path) -> dict[str, str]:
    index: dict[str, str] = {}
    for org in source_root.rglob("*.org"):
        if "_migrated" in org.parts or org.is_symlink():
            continue
        try:
            head = org.read_text(encoding="utf-8", errors="replace")[:2048]
        except OSError:
            continue
        m_id, m_title = _ID_RE.search(head), _TITLE_RE.search(head)
        if m_id and m_title:
            index.setdefault(m_id.group(1).lower(), m_title.group(1).strip())
    return index


def load_index(source_root: Path, rebuild: bool = False) -> dict[str, str]:
    if not rebuild and INDEX_PATH.exists():
        try:
            return json.loads(INDEX_PATH.read_text())
        except (OSError, json.JSONDecodeError):
            pass
    index = build_index(source_root)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(json.dumps(index))
    return index


# ═══════════════════════════════════════════════════════════════════════════════
# parsing
# ═══════════════════════════════════════════════════════════════════════════════

ORG_TODO_OPEN = {"TODO", "NEXT", "STARTED", "WAITING", "HOLD", "PROJ"}
ORG_TODO_DONE = {"DONE", "CANCELLED", "CANCELED", "KILL"}
ORG_TODO_ALL = ORG_TODO_OPEN | ORG_TODO_DONE
ORG_SYSTEM_TAGS = {"ATTACH", "noexport", "ARCHIVE", "crypt", "COMMENT", "ignore"}
PRIORITY_EMOJI = {"A": "⏫", "B": "🔼", "C": "🔽"}  # org [#A] highest .. [#C] lowest

LINK_RE = re.compile(r"\[\[(?P<target>[^\]]+?)\](?:\[(?P<desc>[^\]]*?)\])?\]")
HEADING_RE = re.compile(r"^(\*+)\s+(.*)$")
HEADING_TAGS_RE = re.compile(r"\s+(:(?:[A-Za-z0-9_@#%]+:)+)\s*$")
PRIORITY_RE = re.compile(r"^\[#([ABC])\]\s*")
DATE_RE = re.compile(r"[<\[](\d{4}-\d{2}-\d{2})(?:[^\]>]*)[>\]]")
ORG_CHECKBOX_RE = re.compile(r"^(\s*)([-+*]|\d+[.)])\s+\[([ Xx-])\]\s*(.*)$")
PLAIN_LIST_RE = re.compile(r"^(\s*)([-+]|\d+[.)])\s+(.*)$")
PLANNING_RE = re.compile(r"^\s*(SCHEDULED|DEADLINE|CLOSED):")
DRAWER_OPEN_RE = re.compile(r"^\s*:([A-Za-z][A-Za-z0-9_]*):\s*$")
KEYWORD_LINE_RE = re.compile(r"^\s*#\+\w")
_PRIVACY_WORDS = re.compile(
    r"\b(salary|loan|debt|medical|health|diagnos|therapy|password|ssn|"
    r"finance|bank|mortgage|girlfriend|boyfriend|family|mom|dad)\b", re.IGNORECASE)


@dataclass
class Node:
    line: int                 # 1-based org line of the heading (stable id)
    level: int                # org star count
    text: str = ""
    keyword: str | None = None
    priority: str | None = None
    sched: str = ""
    deadline: str = ""
    closed: str = ""
    htags: list[str] = field(default_factory=list)
    props: dict = field(default_factory=dict)        # :ID:, :DIR: from drawer
    body: list[str] = field(default_factory=list)    # raw lines until next heading
    children: list["Node"] = field(default_factory=list)


@dataclass
class Report:
    source: str = ""
    title: str = ""
    org_id: str = ""
    filetags: list[str] = field(default_factory=list)
    suggested_tags: list[str] = field(default_factory=list)
    privacy_hint: str = "public"
    outline: list[dict] = field(default_factory=list)
    links_resolved: list[dict] = field(default_factory=list)
    links_unresolved: list[dict] = field(default_factory=list)
    citations: list[dict] = field(default_factory=list)
    external_links: list[dict] = field(default_factory=list)
    attachments: list[dict] = field(default_factory=list)
    tasks: dict = field(default_factory=lambda: {"open": 0, "done": 0, "dropped": 0})
    notes: list[str] = field(default_factory=list)


def _resolve_date(raw: str) -> str:
    m = DATE_RE.search(raw)
    return m.group(1) if m else ""


def parse_header(lines: list[str]) -> tuple[str, str, list[str], int]:
    """Consume leading PROPERTIES drawer + #+keywords; return
    (org_id, title, filetags, body_start_index)."""
    org_id = title = ""
    filetags: list[str] = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s == ":PROPERTIES:":
            i += 1
            while i < len(lines) and lines[i].strip() != ":END:":
                pm = re.match(r":ID:\s+(\S+)", lines[i].strip())
                if pm:
                    org_id = pm.group(1)
                i += 1
            i += 1
            continue
        m = re.match(r"#\+title:\s*(.+)", s, re.IGNORECASE)
        if m:
            title = m.group(1).strip()
            i += 1
            continue
        m = re.match(r"#\+filetags:\s*(.+)", s, re.IGNORECASE)
        if m:
            raw = m.group(1).strip().strip(":")
            filetags = [t for t in re.split(r"[:\s]+", raw) if t] if raw else []
            i += 1
            continue
        if s.startswith("#+") or s == "":
            i += 1
            continue
        break
    return org_id, title, filetags, i


def _parse_heading_line(raw: str, line_no: int, lines: list[str], idx: int) -> tuple[Node, int]:
    hm = HEADING_RE.match(raw)
    level, text = len(hm.group(1)), hm.group(2)

    htags: list[str] = []
    tm = HEADING_TAGS_RE.search(text)
    if tm:
        htags = [t for t in tm.group(1).strip(":").split(":")
                 if t and t not in ORG_SYSTEM_TAGS]
        text = text[: tm.start()].rstrip()

    keyword = None
    parts = text.split(None, 1)
    if parts and parts[0] in ORG_TODO_ALL:
        keyword = parts[0]
        text = parts[1] if len(parts) > 1 else ""

    priority = None
    pm = PRIORITY_RE.match(text)
    if pm:
        priority, text = pm.group(1), text[pm.end():]

    node = Node(line=line_no, level=level, text=text.strip(),
                keyword=keyword, priority=priority, htags=htags)

    j = idx + 1
    while j < len(lines) and PLANNING_RE.match(lines[j]):
        pl = lines[j]
        if "SCHEDULED:" in pl:
            node.sched = _resolve_date(pl.split("SCHEDULED:", 1)[1])
        if "DEADLINE:" in pl:
            node.deadline = _resolve_date(pl.split("DEADLINE:", 1)[1])
        if "CLOSED:" in pl:
            node.closed = _resolve_date(pl.split("CLOSED:", 1)[1])
        j += 1
    return node, j


def _extract_drawer(body: list[str]) -> tuple[dict, list[str]]:
    """Pull a leading :PROPERTIES:…:END: drawer off a node body → (props, rest).

    The drawer carries the org-attach :ID: / :DIR: used to locate this node's
    attachments. Leading blank lines before the drawer are tolerated.
    """
    props: dict = {}
    i = 0
    while i < len(body) and body[i].strip() == "":
        i += 1
    if i < len(body) and body[i].strip() == ":PROPERTIES:":
        i += 1
        while i < len(body) and body[i].strip() != ":END:":
            pm = re.match(r":([A-Za-z][A-Za-z0-9_]*):\s+(.+)", body[i].strip())
            if pm:
                props[pm.group(1).upper()] = pm.group(2).strip()
            i += 1
        i += 1  # consume :END:
        return props, body[i:]
    return props, body


def parse_tree(lines: list[str], start: int) -> tuple[list[str], list[Node]]:
    preamble: list[str] = []
    roots: list[Node] = []
    stack: list[Node] = []
    i = start
    while i < len(lines):
        raw = lines[i]
        if HEADING_RE.match(raw):
            node, nxt = _parse_heading_line(raw, i + 1, lines, i)
            while stack and stack[-1].level >= node.level:
                stack.pop()
            (stack[-1].children if stack else roots).append(node)
            stack.append(node)
            i = nxt
            continue
        if stack:
            stack[-1].body.append(raw)
        else:
            preamble.append(raw)
        i += 1

    def finalize(n: Node):
        n.props, n.body = _extract_drawer(n.body)
        for c in n.children:
            finalize(c)
    for r in roots:
        finalize(r)
    return preamble, roots


# ═══════════════════════════════════════════════════════════════════════════════
# inline + body conversion  (no headings here — those are owned by the tree)
# ═══════════════════════════════════════════════════════════════════════════════


def _convert_inline(text: str, rep: Report, index: dict[str, str], attach_id: str) -> str:
    ph: list[str] = []

    def stash(s: str) -> str:
        ph.append(s)
        return f"\x00{len(ph) - 1}\x00"

    text = re.sub(r"~([^~\n]+)~", lambda m: stash(f"`{m.group(1)}`"), text)
    text = re.sub(r"=([^=\n]+)=", lambda m: stash(f"`{m.group(1)}`"), text)
    text = re.sub(r"\\\(([^\n]+?)\\\)", lambda m: stash(f"${m.group(1)}$"), text)
    text = re.sub(r"\$([^$\n]+?)\$", lambda m: stash(f"${m.group(1)}$"), text)

    def link_sub(m: re.Match) -> str:
        target = m.group("target").strip()
        desc = (m.group("desc") or "").strip()
        low = target.lower()
        if low.startswith("id:"):
            oid = target[3:].strip()
            title = index.get(oid.lower())
            if title:
                rep.links_resolved.append({"id": oid, "desc": desc, "title": title})
                return stash(f"[[{title}|{desc}]]" if desc and desc.lower() != title.lower()
                             else f"[[{title}]]")
            rep.links_unresolved.append({"id": oid, "desc": desc})
            return stash(f"[[{desc or oid}]]")
        if low.startswith("cite:"):
            key = target.split(":", 1)[1].lstrip("&")
            rep.citations.append({"key": key, "desc": desc})
            return stash(f"[[@{key}|{desc}]]" if desc else f"[[@{key}]]")
        if low.startswith("attachment:"):
            ref = target.split(":", 1)[1]
            rep.attachments.append({"ref": ref, "attach_id": attach_id})
            return stash(f"![[{Path(ref).name}]]")
        if low.startswith("file:"):
            ref = target.split(":", 1)[1]
            if Path(ref).suffix.lower() in {".png", ".jpg", ".jpeg", ".gif",
                                            ".webp", ".svg", ".pdf"}:
                rep.attachments.append({"ref": ref, "attach_id": attach_id})
                return stash(f"![[{Path(ref).name}]]")
            return stash(f"[{desc or ref}]({ref})")
        if low.startswith(("http://", "https://", "mailto:")):
            rep.external_links.append({"url": target, "desc": desc})
            return stash(f"[{desc}]({target})" if desc else f"<{target}>")
        return stash(f"[[{target}|{desc}]]" if desc else f"[[{target}]]")

    text = LINK_RE.sub(link_sub, text)
    text = re.sub(r"(?<![\w*])\*([^\s*][^*\n]*?)\*(?![\w*])", r"**\1**", text)
    text = re.sub(r"(?<![\w/])/([^\s/][^/\n]*?)/(?![\w/])", r"*\1*", text)
    text = re.sub(r"(?<![\w+])\+([^\s+][^+\n]*?)\+(?![\w+])", r"~~\1~~", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: ph[int(m.group(1))], text)


def convert_body(lines: list[str], rep: Report, index: dict[str, str],
                 done_mode: str, attach_id: str) -> list[str]:
    """Convert a node's section body (blocks, lists, tables, paragraphs).

    Strips org bookkeeping that has no Obsidian analog: stray drawers
    (:LOGBOOK: etc.) and metadata #+keyword lines (#+DOWNLOADED, #+CAPTION…).
    """
    out: list[str] = []
    in_block: str | None = None
    i = 0
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()

        bm = re.match(r"#\+begin_(\w+)(?:\s+(.*))?$", s, re.IGNORECASE)
        if bm and in_block is None:
            kind, arg = bm.group(1).lower(), (bm.group(2) or "").strip()
            if kind == "src":
                out.append(f"```{arg.split()[0] if arg else ''}")
                in_block = "src"
            elif kind == "example":
                out.append("```")
                in_block = "example"
            elif kind == "quote":
                in_block = "quote"
            else:
                in_block = "passthrough"
            i += 1
            continue
        if re.match(r"#\+end_(\w+)", s, re.IGNORECASE) and in_block is not None:
            if in_block in ("src", "example"):
                out.append("```")
            in_block = None
            i += 1
            continue
        if in_block in ("src", "example", "passthrough"):
            out.append(raw)
            i += 1
            continue
        if in_block == "quote":
            out.append(f"> {raw}" if raw.strip() else ">")
            i += 1
            continue

        if PLANNING_RE.match(raw) or KEYWORD_LINE_RE.match(raw):
            i += 1
            continue
        if DRAWER_OPEN_RE.match(raw):                 # stray drawer → skip to :END:
            i += 1
            while i < len(lines) and lines[i].strip() != ":END:":
                i += 1
            i += 1
            continue

        cm = ORG_CHECKBOX_RE.match(raw)
        if cm:
            indent, _b, mark, rest = cm.groups()
            box = "x" if mark in "Xx" else " "
            rep.tasks["done" if box == "x" else "open"] += 1
            if box == "x" and done_mode == "remove":
                rep.tasks["dropped"] += 1
            else:
                out.append(f"{indent}- [{box}] {_convert_inline(rest, rep, index, attach_id)}")
            i += 1
            continue

        lm = PLAIN_LIST_RE.match(raw)
        if lm:
            indent, bullet, rest = lm.groups()
            mb = bullet if bullet[0].isdigit() else "-"
            out.append(f"{indent}{mb} {_convert_inline(rest, rep, index, attach_id)}")
            i += 1
            continue

        if re.match(r"^\s*\|[-+|]+\|?\s*$", raw):
            cols = raw.count("+") + 1 if "+" in raw else raw.strip().strip("|").count("|") + 1
            out.append("|" + "|".join(["---"] * max(cols, 1)) + "|")
            i += 1
            continue

        out.append("" if s == "" else _convert_inline(raw, rep, index, attach_id))
        i += 1
    return out


# ═══════════════════════════════════════════════════════════════════════════════
# header-vs-bullet: suggest (detect) + render (apply the agent's decision)
# ═══════════════════════════════════════════════════════════════════════════════


def _wc(text: str) -> int:
    return len(text.split())


def suggest_kind(node: Node, siblings: list[Node]) -> tuple[str, str]:
    """Return (suggestion, confidence). Detection only — the agent decides."""
    if node.keyword:
        return "task", "high"
    body_n = sum(1 for b in node.body if b.strip())
    if node.children or body_n >= 3:
        return "header", "high"
    sibs = [s for s in siblings if s is not node]
    sibs_listy = sibs and all(
        not s.children and _wc(s.text) <= 6 and
        sum(1 for b in s.body if b.strip()) <= 2 for s in sibs)
    if sibs_listy and not node.children and body_n <= 2:
        return "bullet", "high"
    if body_n == 0 and _wc(node.text) <= 6:
        return "bullet", "low"
    return "header", "low"


def build_outline(nodes: list[Node], rep: Report) -> None:
    def walk(forest: list[Node]):
        for n in forest:
            sug, conf = suggest_kind(n, forest)
            rep.outline.append({
                "line": n.line, "level": n.level, "text": n.text,
                "keyword": n.keyword, "word_count": _wc(n.text),
                "children": len(n.children),
                "body_lines": sum(1 for b in n.body if b.strip()),
                "siblings": len(forest) - 1, "has_attachments": "ID" in n.props,
                "suggestion": sug, "confidence": conf,
            })
            walk(n.children)
    walk(nodes)


def _task_line(node: Node, indent: str, rep: Report, index: dict[str, str], attach_id: str) -> str:
    done = node.keyword in ORG_TODO_DONE
    box = "x" if done else " "
    meta = ""
    if node.priority:
        meta += f" {PRIORITY_EMOJI[node.priority]}"
    if node.sched:
        meta += f" ⏳ {node.sched}"
    if node.deadline:
        meta += f" 📅 {node.deadline}"
    if done and node.closed:
        meta += f" ✅ {node.closed}"
    tags = "".join(f" #{t}" for t in node.htags)
    return f"{indent}- [{box}] {_convert_inline(node.text, rep, index, attach_id)}{tags}{meta}".rstrip()


def render(nodes: list[Node], decisions: dict[int, str], rep: Report,
           index: dict[str, str], done_mode: str, hlevel: int, bdepth: int,
           out: list[str], archived: list[str], attach_id: str) -> None:
    """heading level = header-ancestors+1 (hlevel); bullet indent =
    bullet-ancestors since last header (bdepth). Attach-ID inherited unless a
    node's own drawer overrides it."""
    for node in nodes:
        node_attach = node.props.get("ID", attach_id)
        kind = ("task" if node.keyword
                else decisions.get(node.line)
                or next((o["suggestion"] for o in rep.outline if o["line"] == node.line),
                        "header"))
        tags = "".join(f" #{t}" for t in node.htags)

        if kind == "task":
            done = node.keyword in ORG_TODO_DONE
            target = out
            if done:
                rep.tasks["done"] += 1
                if done_mode == "remove":
                    rep.tasks["dropped"] += 1
                    continue
                if done_mode == "archive":
                    target = archived
            else:
                rep.tasks["open"] += 1
            indent = "    " * bdepth
            target.append(_task_line(node, indent, rep, index, node_attach))
            for bl in convert_body(node.body, rep, index, done_mode, node_attach):
                target.append(f"{'    ' * (bdepth + 1)}{bl}" if bl else "")
            render(node.children, decisions, rep, index, done_mode,
                   hlevel, bdepth + 1, target, archived, node_attach)

        elif kind == "bullet":
            indent = "    " * bdepth
            out.append(f"{indent}- {_convert_inline(node.text, rep, index, node_attach)}{tags}")
            for bl in convert_body(node.body, rep, index, done_mode, node_attach):
                out.append(f"{'    ' * (bdepth + 1)}{bl}" if bl else "")
            render(node.children, decisions, rep, index, done_mode,
                   hlevel, bdepth + 1, out, archived, node_attach)

        else:  # header
            out.append(f"{'#' * min(hlevel, 6)} {_convert_inline(node.text, rep, index, node_attach)}{tags}".rstrip())
            out.append("")
            out.extend(convert_body(node.body, rep, index, done_mode, node_attach))
            render(node.children, decisions, rep, index, done_mode,
                   hlevel + 1, 0, out, archived, node_attach)


# ═══════════════════════════════════════════════════════════════════════════════
# attachment resolution  (content-addressed: data/<id[:2]>/<id[2:]>/<name>)
# ═══════════════════════════════════════════════════════════════════════════════


def _attach_candidate_dirs(attach_id: str, dir_prop: str | None) -> list[str]:
    cands: list[str] = []
    if dir_prop:
        cands.append(dir_prop)
    for v in dict.fromkeys([attach_id, attach_id.lower()]):  # try original + lower case
        if len(v) >= 3:
            cands.append(f"data/{v[:2]}/{v[2:]}")
    return cands


def _locate_attachments(rep: Report, source_path: Path) -> None:
    root = source_path.parent
    seen: dict[str, dict] = {}
    for att in rep.attachments:
        name = Path(att["ref"]).name
        if name in seen:                      # same asset referenced twice
            att["found"] = seen[name]["found"]
            att["source"] = seen[name].get("source", "")
            att["embed"] = seen[name]["embed"]
            continue
        att["embed"] = f"![[{name}]]"
        src = ""
        for d in _attach_candidate_dirs(att.get("attach_id", ""), None):
            p = root / d / Path(att["ref"]).name
            if p.exists():
                src = str(p)
                break
        if not src:                            # fallback: scoped search under data/
            data = root / "data"
            if data.exists():
                hit = next((p for p in data.rglob(name)), None)
                if hit:
                    src = str(hit)
        att["found"] = bool(src)
        att["source"] = src
        seen[name] = att


# ═══════════════════════════════════════════════════════════════════════════════
# top-level convert
# ═══════════════════════════════════════════════════════════════════════════════


def _suggest_tags(filetags: list[str]) -> list[str]:
    out = []
    for t in filetags:
        t = t.strip().lower().replace(" ", "-")
        if t and t not in out:
            out.append(t)
    return out


def _sanitize_filename(title: str) -> str:
    return re.sub(r'[\\/:*?"<>|]', "-", title).strip()


def convert(org_text: str, source_path: Path, index: dict[str, str], *,
            decisions: dict[int, str] | None = None, done_mode: str = "keep",
            archive_target: str | None = None) -> tuple[dict, str, Report, str]:
    rep = Report(source=str(source_path))
    lines = org_text.splitlines()

    org_id, title, filetags, body_start = parse_header(lines)
    rep.title, rep.org_id, rep.filetags = title, org_id, [t for t in filetags if t]

    preamble, roots = parse_tree(lines, body_start)
    build_outline(roots, rep)

    out: list[str] = convert_body(preamble, rep, index, done_mode, org_id)
    archived: list[str] = []
    render(roots, decisions or {}, rep, index, done_mode,
           hlevel=1, bdepth=0, out=out, archived=archived, attach_id=org_id)

    _locate_attachments(rep, source_path)
    rep.suggested_tags = _suggest_tags(rep.filetags)
    if _PRIVACY_WORDS.search(org_text) or any(
            t in {"family", "private", "health", "finance"} for t in rep.filetags):
        rep.privacy_hint = "review"

    fm: dict = {}
    if title and _sanitize_filename(title) != title:
        fm["aliases"] = [title]
    if rep.suggested_tags:
        fm["tags"] = rep.suggested_tags
    if org_id:
        fm["org-id"] = org_id  # provenance: trace inbound id: links & backlinks

    md = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"

    archived_block = ""
    if archived:
        block = "\n".join(archived)
        if archive_target:
            archived_block = block
        else:
            md += "\n## Archived (migrated, done)\n\n" + block + "\n"
    return fm, md, rep, archived_block


# ═══════════════════════════════════════════════════════════════════════════════
# stateful subcommands  (move source; copy assets) — md5-verified, no overwrite
# ═══════════════════════════════════════════════════════════════════════════════


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage(paths: list[Path], source_root: Path, execute: bool) -> int:
    plan = []
    for src in paths:
        src = src.resolve()
        try:
            rel = src.relative_to(source_root.resolve())
        except ValueError:
            print(f"BLOCK {src}: not under source root {source_root}", file=sys.stderr)
            return 2
        if src.is_symlink():
            print(f"BLOCK {src}: source is a symlink", file=sys.stderr)
            return 2
        if STAGING_ROOT.resolve() in src.parents:
            print(f"BLOCK {src}: already under staging", file=sys.stderr)
            return 2
        dst = STAGING_ROOT / rel
        if dst.exists():
            print(f"BLOCK {dst}: destination exists — refusing overwrite", file=sys.stderr)
            return 2
        if not src.exists():
            print(f"BLOCK {src}: source missing", file=sys.stderr)
            return 2
        plan.append((src, dst, md5_of(src), src.stat().st_size))

    print(f"stage plan: {len(plan)} file(s)  ({'EXECUTE' if execute else 'dry-run'})")
    for src, dst, digest, size in plan:
        print(f"  {src}\n    → {dst}  ({size}B md5={digest[:8]})")
    if not execute:
        print("dry-run only. re-run with --execute to move.")
        return 0
    for src, dst, expected, _ in plan:
        if md5_of(src) != expected:
            print(f"FATAL md5 drift before move: {src}", file=sys.stderr)
            return 4
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        if dst.is_symlink() or md5_of(dst) != expected:
            print(f"FATAL post-move verify failed: {dst}", file=sys.stderr)
            return 4
        print(f"moved {src.name}")
    return 0


def pull_attachments(org_file: Path, into: Path, source_root: Path,
                     execute: bool, move: bool) -> int:
    """Copy (default) or move a note's resolved attachments into `into`."""
    index = load_index(source_root)
    _, _, rep, _ = convert(org_file.read_text(encoding="utf-8", errors="replace"),
                           org_file, index)
    found = [a for a in rep.attachments if a.get("found")]
    missing = [a for a in rep.attachments if not a.get("found")]
    verb = "move" if move else "copy"
    print(f"attachments: {len(found)} resolved, {len(missing)} missing  "
          f"({verb}, {'EXECUTE' if execute else 'dry-run'})")
    for a in found:
        print(f"  {a['source']}\n    → {into / Path(a['ref']).name}")
    for a in missing:
        print(f"  MISSING source for: {a['ref']} (attach_id={a.get('attach_id','')[:8]})")
    if not execute:
        print("dry-run only. re-run with --execute.")
        return 0
    into.mkdir(parents=True, exist_ok=True)
    for a in found:
        src = Path(a["source"])
        dst = into / Path(a["ref"]).name
        if dst.exists():
            print(f"SKIP exists: {dst}")
            continue
        (shutil.move if move else shutil.copy2)(str(src), str(dst))
        print(f"{verb}d {dst.name}")
    return 1 if missing else 0


# ═══════════════════════════════════════════════════════════════════════════════
# cli
# ═══════════════════════════════════════════════════════════════════════════════


def _load_decisions(arg: str | None) -> dict[int, str]:
    if not arg:
        return {}
    raw = Path(arg).read_text() if Path(arg).exists() else arg
    return {int(k): str(v).lower() for k, v in json.loads(raw).items()}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("convert", help="org → JSON {frontmatter, markdown, report}")
    pc.add_argument("file")
    pc.add_argument("--source-root", default=str(DEFAULT_SOURCE_ROOT))
    pc.add_argument("--rebuild-index", action="store_true")
    pc.add_argument("--outline", action="store_true",
                    help="emit ONLY the header-vs-bullet judgment plan (no final md)")
    pc.add_argument("--decisions", default=None,
                    help="JSON map {line: header|bullet} (path or inline string)")
    pc.add_argument("--remove-done", action="store_true")
    pc.add_argument("--archive-done", nargs="?", const="__INFILE__", default=None,
                    metavar="WHERE", help="archive DONE tasks; WHERE defaults to within the file")
    pc.add_argument("--md-only", action="store_true")

    pi = sub.add_parser("index", help="build/show the org-id → title index")
    pi.add_argument("--source-root", default=str(DEFAULT_SOURCE_ROOT))
    pi.add_argument("--rebuild-index", action="store_true")

    ps = sub.add_parser("stage", help="move migrated source(s) to _migrated/")
    ps.add_argument("files", nargs="+")
    ps.add_argument("--source-root", default=str(DEFAULT_SOURCE_ROOT))
    ps.add_argument("--execute", action="store_true")

    pa = sub.add_parser("pull-attachments", help="copy a note's assets into its folder")
    pa.add_argument("file")
    pa.add_argument("--into", required=True)
    pa.add_argument("--source-root", default=str(DEFAULT_SOURCE_ROOT))
    pa.add_argument("--execute", action="store_true")
    pa.add_argument("--move", action="store_true", help="move instead of copy")

    args = p.parse_args()

    if args.cmd == "index":
        idx = load_index(Path(args.source_root), rebuild=args.rebuild_index)
        print(f"id_index: {len(idx)} entries  (cache: {INDEX_PATH})")
        return 0
    if args.cmd == "stage":
        return stage([Path(f) for f in args.files], Path(args.source_root), args.execute)
    if args.cmd == "pull-attachments":
        return pull_attachments(Path(args.file), Path(args.into),
                                Path(args.source_root), args.execute, args.move)

    # convert
    src = Path(args.file)
    if not src.exists():
        print(f"FATAL not found: {src}", file=sys.stderr)
        return 2
    text = src.read_text(encoding="utf-8", errors="replace")

    if args.outline:
        rep = Report(source=str(src))
        org_id, title, filetags, body_start = parse_header(text.splitlines())
        rep.title, rep.org_id, rep.filetags = title, org_id, [t for t in filetags if t]
        _, roots = parse_tree(text.splitlines(), body_start)
        build_outline(roots, rep)
        json.dump({"title": title, "org_id": org_id,
                   "n_headings": len(rep.outline), "outline": rep.outline},
                  sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    index = load_index(Path(args.source_root), rebuild=args.rebuild_index)
    done_mode, archive_target = "keep", None
    if args.remove_done:
        done_mode = "remove"
    elif args.archive_done is not None:
        done_mode = "archive"
        archive_target = None if args.archive_done == "__INFILE__" else args.archive_done

    fm, md, rep, archived_block = convert(
        text, src, index, decisions=_load_decisions(args.decisions),
        done_mode=done_mode, archive_target=archive_target)

    if args.md_only:
        sys.stdout.write(md)
        return 0
    json.dump({"frontmatter": fm, "markdown": md, "archived_block": archived_block,
               "archive_target": archive_target, "report": rep.__dict__},
              sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
