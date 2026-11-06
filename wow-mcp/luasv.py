"""Minimal parser for WoW SavedVariables / Lua table literals."""
import re

_TOKEN = re.compile(r"""
    \s+|--\[\[.*?\]\]|--[^\n]*            # whitespace / comments
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<num>-?(?:0x[0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|inf|nan))
  | (?P<name>[A-Za-z_][A-Za-z0-9_.]*)
  | (?P<op>[{}\[\]=,;])
""", re.S | re.X)

_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def _unquote(s):
    out, i, s = [], 0, s[1:-1]
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n.isdigit():
                m = re.match(r"\d{1,3}", s[i + 1:]).group()
                out.append(chr(int(m)))
                i += 1 + len(m)
                continue
            out.append(_ESC.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _tokens(text):
    for m in _TOKEN.finditer(text):
        kind = m.lastgroup
        if kind:
            yield kind, m.group(kind)


class _Parser:
    def __init__(self, text):
        self.toks = list(_tokens(text))
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else (None, None)

    def take(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def value(self):
        kind, v = self.take()
        if kind == "str":
            return _unquote(v)
        if kind == "num":
            if v in ("inf", "-inf", "nan"):
                return float(v)
            if v.lower().startswith(("0x", "-0x")):
                return int(v, 16)
            f = float(v)
            return int(f) if f.is_integer() and "." not in v and "e" not in v.lower() else f
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(v, v)
        if v == "{":
            return self.table()
        raise ValueError(f"unexpected token {v!r}")

    def table(self):
        arr, d, n = [], {}, 0
        while True:
            kind, v = self.peek()
            if v == "}":
                self.take()
                break
            if v == "[":
                self.take()
                key = self.value()
                self.take()  # ]
                self.take()  # =
                d[key] = self.value()
            elif kind == "name" and self.peek(1)[1] == "=":
                self.take()
                self.take()
                d[v] = self.value()
            else:
                n += 1
                d[n] = self.value()
            if self.peek()[1] in (",", ";"):
                self.take()
        # pure 1..n sequence -> list
        if d and all(isinstance(k, int) for k in d) and set(d) == set(range(1, len(d) + 1)):
            return [d[k] for k in range(1, len(d) + 1)]
        return d if d else arr

    def assignments(self):
        out = {}
        while self.i < len(self.toks):
            _, name = self.take()
            self.take()  # =
            out[name] = self.value()
        return out


def load_assignments(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # DatabaseData.lua starts with "local _,F=..." — keep only table assignments.
    text = re.sub(r"^local[^\n]*\n", "", text, flags=re.M)
    return _Parser(text).assignments()
