#!/usr/bin/env python3
"""Dump the effective XCompose table as JSON for the omacompose overlay.

Resolves the same file libxkbcommon/libX11 would use ($XCOMPOSEFILE, then
~/.XCompose, then the locale's Compose), follows `include` lines with the
%H / %L / %S substitutions, and keeps only <Multi_key> sequences. Each key
gets a display label via libxkbcommon, and the keyboard layout Hyprland is
running is used to drop sequences that can't be typed on it.
"""

import ctypes
import ctypes.util
import json
import os
import re
import subprocess
import sys

X11_LOCALE = "/usr/share/X11/locale"
HOME = os.path.expanduser("~")


def current_locale():
    for var in ("LC_ALL", "LC_CTYPE", "LANG"):
        value = os.environ.get(var)
        if value:
            return value
    return "C"


def locale_compose_file(locale):
    # compose.dir maps "<dir>/Compose  <locale>"; try the full name, then
    # common normalizations (en_US.utf8 -> en_US.UTF-8).
    candidates = [locale, re.sub(r"\.utf-?8$", ".UTF-8", locale, flags=re.I)]
    try:
        with open(os.path.join(X11_LOCALE, "compose.dir"), encoding="utf-8") as f:
            rows = [line.split() for line in f if line.strip() and not line.startswith("#")]
    except OSError:
        return None
    for name in candidates:
        for row in rows:
            if len(row) >= 2 and row[1].rstrip(":") == name:
                return os.path.join(X11_LOCALE, row[0].rstrip(":"))
    return None


def root_compose_file():
    env = os.environ.get("XCOMPOSEFILE")
    if env and os.path.isfile(env):
        return env
    home = os.path.join(HOME, ".XCompose")
    if os.path.isfile(home):
        return home
    return locale_compose_file(current_locale())


TOKEN = re.compile(r'<([^>]+)>')
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n in "01234567":
            m = re.match(r"[0-7]{1,3}", s[i + 1:])
            out.append(chr(int(m.group(0), 8)))
            i += 1 + len(m.group(0))
        elif n in "xX":
            m = re.match(r"[0-9a-fA-F]{1,2}", s[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
            else:
                out.append(n)
                i += 2
        else:
            out.append({"n": "\n", "t": "\t", "r": "\r"}.get(n, n))
            i += 2
    # Octal/hex escapes describe UTF-8 bytes.
    try:
        return "".join(out).encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return "".join(out)


def parse(path, table, sources, custom, seen, descendants):
    real = os.path.realpath(path)
    if real in seen or not os.path.isfile(real):
        return
    seen.add(real)
    sources.append(path)
    is_custom = not real.startswith(X11_LOCALE + "/")
    with open(real, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("include"):
                m = STRING.search(line)
                if not m:
                    continue
                target = m.group(1)
                target = target.replace("%H", HOME).replace("%S", X11_LOCALE)
                if "%L" in target:
                    loc = locale_compose_file(current_locale())
                    if not loc:
                        continue
                    target = target.replace("%L", loc)
                parse(target, table, sources, custom, seen, descendants)
                continue
            if ":" not in line:
                continue
            lhs, rhs = line.split(":", 1)
            keys = TOKEN.findall(lhs)
            # Skip modifier-qualified lines (e.g. "~Ctrl <a>"): anything
            # besides <keysym> tokens on the left-hand side.
            if not keys or TOKEN.sub("", lhs).strip() or keys[0] != "Multi_key" or len(keys) < 2:
                continue
            m = STRING.search(rhs)
            if not m:
                continue
            result = unescape(m.group(1))
            after = rhs[m.end():]
            comment = after.split("#", 1)[1].strip() if "#" in after else ""
            seq = tuple(keys[1:])
            # Later definitions win, like in libxkbcommon: a new sequence
            # replaces an existing one that is its prefix, or that it is a
            # prefix of (so `<Multi_key> <a> : "ä"` hides every `<a> <…>`).
            for i in range(1, len(seq)):
                if table.pop(seq[:i], None) is not None:
                    custom.discard(seq[:i])
            for longer in descendants.pop(seq, ()):
                if table.pop(longer, None) is not None:
                    custom.discard(longer)
            table[seq] = (result, comment)
            for i in range(1, len(seq)):
                descendants.setdefault(seq[:i], set()).add(seq)
            if is_custom:
                custom.add(seq)
            else:
                custom.discard(seq)


class Xkb:
    def __init__(self):
        name = ctypes.util.find_library("xkbcommon") or "libxkbcommon.so.0"
        try:
            self.lib = ctypes.CDLL(name)
            self.lib.xkb_keysym_from_name.restype = ctypes.c_uint32
            self.lib.xkb_keysym_from_name.argtypes = [ctypes.c_char_p, ctypes.c_int]
            self.lib.xkb_keysym_to_utf8.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
        except OSError:
            self.lib = None
        self.cache = {}

    def label(self, keysym):
        if keysym in self.cache:
            return self.cache[keysym]
        text = ""
        if self.lib:
            sym = self.lib.xkb_keysym_from_name(keysym.encode(), 0)
            if sym:
                buf = ctypes.create_string_buffer(16)
                n = self.lib.xkb_keysym_to_utf8(sym, buf, 16)
                if n > 1:
                    text = buf.value.decode("utf-8", "replace")
        if not text or not text.isprintable():
            text = {"space": "␣", "Multi_key": "compose"}.get(keysym, keysym)
        if text == " ":
            text = "␣"
        self.cache[keysym] = text
        return text


def typeable_keysyms():
    """Level 1/2 keysyms of the layout Hyprland's main keyboard uses."""
    try:
        devices = json.loads(subprocess.run(["hyprctl", "-j", "devices"], capture_output=True,
                                            text=True, timeout=2).stdout)
        kb = next((k for k in devices.get("keyboards", []) if k.get("main")), None) \
            or devices["keyboards"][0]
        args = ["xkbcli", "compile-keymap", "--layout", kb.get("layout", "us"),
                "--variant", kb.get("variant", ""), "--options", kb.get("options", "")]
        if kb.get("rules"):
            args += ["--rules", kb["rules"]]
        if kb.get("model"):
            args += ["--model", kb["model"]]
        keymap = subprocess.run(args, capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return None
    symbols = keymap.split("xkb_symbols", 1)[-1]
    syms = set()
    for block in re.findall(r"key\s+<[^>]+>\s*\{(.*?)\};", symbols, re.S):
        for group in re.findall(r"\[([^\]]*)\]", block):
            levels = [s.strip() for s in group.split(",")]
            syms.update(s for s in levels[:2] if s and s != "NoSymbol")
    return syms or None


def main():
    root = root_compose_file()
    table, custom, sources = {}, set(), []
    if root:
        parse(root, table, sources, custom, set(), {})

    typeable = typeable_keysyms()
    xkb = Xkb()
    entries = []
    for seq, (result, comment) in table.items():
        # Keypad keys duplicate the main-row sequences; leave them out.
        if any(k.startswith("KP_") for k in seq):
            continue
        if typeable and any(k not in typeable for k in seq):
            continue
        entries.append({
            "keys": list(seq),
            "result": result,
            "comment": comment,
            "custom": seq in custom,
        })
    labels = {k: xkb.label(k) for e in entries for k in e["keys"]}
    json.dump({"sources": sources, "labels": labels, "entries": entries},
              sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
