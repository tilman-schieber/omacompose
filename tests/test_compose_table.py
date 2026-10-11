import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compose_table", os.path.join(HERE, "..", "compose-table.py"))
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)


def load(files, root="root"):
    """Write {name: text} into a temp dir and parse `root` from it."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in files.items():
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
                f.write(text.replace("@DIR@", tmp))
        table, custom, sources = {}, set(), []
        ct.parse(os.path.join(tmp, root), table, sources, custom, set(), {})
        return table, custom, [os.path.basename(s) for s in sources]


class ParseTest(unittest.TestCase):
    def test_multi_key_sequences_only(self):
        table, _, _ = load({"root": '''
# comment
<Multi_key> <a> <e> : "æ" ae # LATIN SMALL LETTER AE
<dead_acute> <a> : "á"
~Ctrl <Multi_key> <x> : "nope"
<Multi_key> <space> <space> : "—"
'''})
        self.assertEqual(table, {("a", "e"): ("æ", "LATIN SMALL LETTER AE"), ("space", "space"): ("—", "")})

    def test_include_and_later_definition_wins(self):
        table, _, sources = load({
            "root": 'include "@DIR@/base"\n<Multi_key> <o> <e> : "OE"\n',
            "base": '<Multi_key> <o> <e> : "œ"\n<Multi_key> <o> <o> : "°"\n',
        })
        self.assertEqual(sources, ["root", "base"])
        self.assertEqual(table[("o", "e")][0], "OE")
        self.assertEqual(table[("o", "o")][0], "°")

    def test_shorter_sequence_replaces_longer_ones(self):
        table, _, _ = load({"root": '''
<Multi_key> <a> <e> : "æ"
<Multi_key> <a> <apostrophe> : "á"
<Multi_key> <b> <b> : "x"
<Multi_key> <a> : "ä"
'''})
        self.assertEqual(sorted(table), [("a",), ("b", "b")])

    def test_longer_sequence_replaces_prefix(self):
        table, _, _ = load({"root": '<Multi_key> <a> : "ä"\n<Multi_key> <a> <e> : "æ"\n'})
        self.assertEqual(list(table), [("a", "e")])

    def test_include_cycles_are_ignored(self):
        table, _, sources = load({
            "root": 'include "@DIR@/other"\n<Multi_key> <x> <x> : "×"\n',
            "other": 'include "@DIR@/root"\n',
        })
        self.assertEqual(sources, ["root", "other"])
        self.assertIn(("x", "x"), table)

    def test_files_outside_x11_locale_are_custom(self):
        _, custom, _ = load({"root": '<Multi_key> <m> <s> : "😄" # smile\n'})
        self.assertEqual(custom, {("m", "s")})


    def test_latin1_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "root")
            with open(root, "wb") as f:
                f.write('<Multi_key> <exclam> <exclam> : "¡" # exclamdown\n'.encode("latin-1"))
                f.write('<Multi_key> <c> <o> : "©" # copyright\n'.encode("utf-8"))
            table = {}
            ct.parse(root, table, [], set(), set(), {})
            self.assertEqual(table, {("exclam", "exclam"): ("¡", "exclamdown"), ("c", "o"): ("©", "copyright")})

    def test_unreadable_include_is_skipped(self):
        if os.geteuid() == 0:
            self.skipTest("root can read anything")
        with tempfile.TemporaryDirectory() as tmp:
            locked = os.path.join(tmp, "locked")
            with open(locked, "w") as f:
                f.write('<Multi_key> <l> <l> : "x"\n')
            os.chmod(locked, 0)
            root = os.path.join(tmp, "root")
            with open(root, "w") as f:
                f.write(f'include "{locked}"\n<Multi_key> <o> <k> : "ok"\n')
            table, sources = {}, []
            with contextlib.redirect_stderr(io.StringIO()):
                ct.parse(root, table, sources, set(), set(), {})
            self.assertEqual(list(table), [("o", "k")])
            self.assertEqual(sources, [root])


class RootFileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": os.path.join(self.tmp.name, "config")})
        self.env.start()
        self.addCleanup(self.env.stop)
        os.environ.pop("XCOMPOSEFILE", None)
        self.home = mock.patch.object(ct, "HOME", self.tmp.name)
        self.home.start()
        self.addCleanup(self.home.stop)

    def touch(self, *parts):
        path = os.path.join(self.tmp.name, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()
        return path

    def test_lookup_order(self):
        home = self.touch(".XCompose")
        self.assertEqual(ct.root_compose_file(), home)
        xdg = self.touch("config", "XCompose")
        self.assertEqual(ct.root_compose_file(), xdg)
        env = self.touch("env-compose")
        os.environ["XCOMPOSEFILE"] = env
        self.assertEqual(ct.root_compose_file(), env)


class LocaleTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        with open(os.path.join(tmp.name, "locale.alias"), "w") as f:
            f.write("# comment\nPOSIX\t\t\tC\nen_US\t\t\ten_US.ISO8859-1\nen_US:\t\t\ten_US.ISO8859-1\n")
        with open(os.path.join(tmp.name, "compose.dir"), "w") as f:
            f.write("iso8859-1/Compose\t\tC\niso8859-1/Compose\t\ten_US.ISO8859-1\n"
                    "en_US.UTF-8/Compose:\t\ten_US.UTF-8\nen_US.UTF-8/Compose\t\tde_DE.UTF-8\n")
        patch = mock.patch.object(ct, "X11_LOCALE", tmp.name)
        patch.start()
        self.addCleanup(patch.stop)
        self.dir = tmp.name

    def check(self, locale, table):
        found = ct.locale_compose_file(locale)
        self.assertEqual(found and os.path.relpath(found, self.dir), table)

    def test_resolution(self):
        self.check("de_DE.UTF-8", "en_US.UTF-8/Compose")
        self.check("de_DE.utf8", "en_US.UTF-8/Compose")
        self.check("en_US", "iso8859-1/Compose")
        self.check("C", "en_US.UTF-8/Compose")
        self.check("POSIX", "en_US.UTF-8/Compose")
        self.check("xx_XX", None)


class KeymapTest(unittest.TestCase):
    def test_multiple_layouts(self):
        keymap = """
xkb_symbols "pc+us+de:2" {
    key <AE01>               {
        symbols[1]= [               1,          exclam ],
        symbols[2]= [               1,          exclam,     onesuperior,      exclamdown ]
    };
    key <AD01>               {
        type[1]= "FOUR_LEVEL_SEMIALPHABETIC",
        symbols[1]= [               q,               Q ],
        symbols[2]= [               q,               Q,              at,     Greek_OMEGA ]
    };
    key <SPCE>               {	[           space ] };
};
"""
        self.assertEqual(ct.keymap_keysyms(keymap), {
            "1", "exclam", "onesuperior", "exclamdown", "q", "Q", "at", "Greek_OMEGA", "space"})

    def test_single_layout_has_no_group_labels(self):
        keymap = 'xkb_symbols "pc+us" {\n key <AE02> { [ 2, at ] };\n};\n'
        self.assertEqual(ct.keymap_keysyms(keymap), {"2", "at"})


class UnescapeTest(unittest.TestCase):
    def test_escapes(self):
        self.assertEqual(ct.unescape(r'\"q\"'), '"q"')
        self.assertEqual(ct.unescape(r"a\\b"), "a\\b")
        self.assertEqual(ct.unescape(r"\303\244"), "ä")
        self.assertEqual(ct.unescape(r"\xc3\xa4"), "ä")
        self.assertEqual(ct.unescape("plain ✓"), "plain ✓")


class LabelTest(unittest.TestCase):
    def test_labels(self):
        xkb = ct.Xkb()
        if not xkb.lib:
            self.skipTest("libxkbcommon not available")
        self.assertEqual(xkb.label("apostrophe"), "'")
        self.assertEqual(xkb.label("space"), "␣")
        self.assertEqual(xkb.label("Multi_key"), "compose")
        self.assertEqual(xkb.label("dead_acute"), "´")
        self.assertEqual(xkb.label("dead_stroke"), "stroke")


if __name__ == "__main__":
    unittest.main()
