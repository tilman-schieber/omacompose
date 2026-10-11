const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

// ComposeModel.js is a QML JS library; drop the pragma and load it as a function body.
const source = fs.readFileSync(path.join(__dirname, "..", "ComposeModel.js"), "utf8").replace(/^\.pragma library\s*/, "")
const Model = new Function(source + "\nreturn { step, label }")()

const table = {
  labels: { a: "a", e: "e", m: "m", s: "s", apostrophe: "'", space: "␣" },
  entries: [
    { keys: ["a"], result: "ä", comment: "", custom: true },
    { keys: ["m", "s"], result: "😄", comment: "smile", custom: true },
    { keys: ["apostrophe", "e"], result: "é", comment: "", custom: false },
    { keys: ["apostrophe", "a"], result: "á", comment: "", custom: false },
    { keys: ["apostrophe", "apostrophe", "a"], result: "ǻ", comment: "", custom: false },
  ],
}

test("root lists custom groups first", () => {
  const r = Model.step(table, [])
  assert.strictEqual(r.state, "pending")
  assert.deepStrictEqual(r.groups.map(g => g.key), ["a", "m", "apostrophe"])
  assert.strictEqual(r.groups[0].entry.result, "ä")
  assert.deepStrictEqual(r.groups[1].results, ["😄"])
})

test("prefix groups next keys, terminals and subtrees", () => {
  const r = Model.step(table, ["apostrophe"])
  assert.deepStrictEqual(r.groups.map(g => [g.key, g.entry && g.entry.result, g.results]), [
    ["a", "á", []],
    ["e", "é", []],
    ["apostrophe", null, ["ǻ"]],
  ])
})

test("complete and dead sequences", () => {
  assert.strictEqual(Model.step(table, ["a"]).state, "done")
  assert.strictEqual(Model.step(table, ["m", "s"]).entry.result, "😄")
  assert.strictEqual(Model.step(table, ["m", "x"]).state, "dead")
  assert.strictEqual(Model.step(table, ["z"]).state, "dead")
})

test("labels fall back to the keysym", () => {
  assert.strictEqual(Model.label(table, "apostrophe"), "'")
  assert.strictEqual(Model.label(table, "dead_acute"), "dead_acute")
})
