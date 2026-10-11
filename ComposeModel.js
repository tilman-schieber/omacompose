.pragma library

// Pure helpers for the omacompose overlay. `table` is the JSON emitted by
// compose-table.py: { labels: {keysym: text}, entries: [{keys, result, comment, custom}] }.

function label(table, keysym) {
  return (table && table.labels && table.labels[keysym]) || keysym
}

// What the typed prefix leads to:
//   state "pending":  more keys needed; `groups` lists the possible next keys
//   state "done":     the prefix is a full sequence (compose has emitted it)
//   state "dead":     no sequence starts like this
function step(table, seq) {
  var entries = (table && table.entries) || []
  var depth = seq.length
  var byKey = {}
  var order = []
  var matched = 0

  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (e.keys.length < depth) continue
    var ok = true
    for (var j = 0; j < depth; j++) {
      if (e.keys[j] !== seq[j]) { ok = false; break }
    }
    if (!ok) continue
    if (e.keys.length === depth) return { state: "done", groups: [], entry: e }
    matched++

    var next = e.keys[depth]
    var g = byKey[next]
    if (!g) {
      g = byKey[next] = { key: next, label: label(table, next), entry: null, results: [], count: 0, custom: false }
      order.push(g)
    }
    g.count++
    if (e.custom) g.custom = true
    if (e.keys.length === depth + 1) g.entry = e
    else if (g.results.length < 6) g.results.push(e.result)
  }

  if (matched === 0) return { state: "dead", groups: [] }

  order.sort(function(a, b) {
    if (a.custom !== b.custom) return a.custom ? -1 : 1
    return keyRank(a.key) - keyRank(b.key) || (a.label < b.label ? -1 : a.label > b.label ? 1 : 0)
  })
  return { state: "pending", groups: order }
}

// Letters, then digits, then everything else; lower case before upper.
function keyRank(keysym) {
  if (/^[a-z]$/.test(keysym)) return 0
  if (/^[A-Z]$/.test(keysym)) return 1
  if (/^[0-9]$/.test(keysym)) return 2
  if (keysym === "space") return 3
  return 4
}
