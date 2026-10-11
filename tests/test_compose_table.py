import importlib.util
import os
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
