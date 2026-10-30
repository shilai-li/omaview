// Run with: bash test/layout-test.sh
const L = require("../Layout.js")

let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures.push(name + "\n    " + e.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "value") + ": expected " + b + ", got " + a)
}

function ok(value, what) {
  if (!value) throw new Error((what || "assertion") + " was falsy")
}

function overlaps(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function inside(r, area) {
  return r.x >= area.x - 1 && r.y >= area.y - 1 && r.x + r.w <= area.x + area.w + 1 && r.y + r.h <= area.y + area.h + 1
}

const AREA = { x: 40, y: 220, w: 1840, h: 820 }
const OPTS = { gap: 40, labelHeight: 30 }

// Four windows, tiled as Hyprland would on a 1920×1080 output.
const TILED = [
  { x: 10, y: 32, w: 945, h: 520 },
  { x: 965, y: 32, w: 945, h: 1038 },
  { x: 10, y: 562, w: 470, h: 508 },
  { x: 490, y: 562, w: 465, h: 508 }
]

check("empty workspace lays out nothing", () => {
  eq(L.spread([], AREA, OPTS), [])
  eq(L.spread(null, AREA, OPTS), [])
})

check("a lone window is centred and never enlarged", () => {
  const [r] = L.spread([{ x: 0, y: 0, w: 400, h: 300 }], AREA, OPTS)
  eq([r.w, r.h], [400, 300], "real size")
  eq(r.x, AREA.x + (AREA.w - 400) / 2, "centred x")
})

check("a lone big window shrinks to fit, aspect kept", () => {
  const [r] = L.spread([{ x: 0, y: 0, w: 3840, h: 2160 }], AREA, OPTS)
  ok(inside(r, AREA), "inside area")
  ok(Math.abs(r.w / r.h - 3840 / 2160) < 0.01, "aspect")
})

check("tiled windows never overlap and stay inside", () => {
  const out = L.spread(TILED, AREA, OPTS)
  eq(out.length, TILED.length, "one rect each")
  for (let i = 0; i < out.length; i++) {
    ok(inside(out[i], AREA), "rect " + i + " inside")
    for (let j = i + 1; j < out.length; j++) ok(!overlaps(out[i], out[j]), i + " vs " + j + " apart")
  }
})

check("rows keep the label room free", () => {
  const out = L.spread(TILED, AREA, OPTS)
  for (let i = 0; i < out.length; i++)
    for (let j = 0; j < out.length; j++) {
      if (i === j) continue
      const a = out[i], b = out[j]
      const sameColumn = a.x < b.x + b.w && b.x < a.x + a.w
      if (sameColumn && b.y > a.y) ok(b.y - (a.y + a.h) >= OPTS.labelHeight, "label gap " + i + "→" + j)
    }
})

check("every window shares one scale", () => {
  const out = L.spread(TILED, AREA, OPTS)
  const s = out.map((r, i) => r.w / TILED[i].w)
  for (const v of s) ok(Math.abs(v - s[0]) < 0.01, "scale " + v + " ≈ " + s[0])
})

check("left stays left within a row", () => {
  const out = L.spread([{ x: 1000, y: 0, w: 500, h: 500 }, { x: 0, y: 0, w: 500, h: 500 }], AREA, OPTS)
  ok(out[1].x < out[0].x, "window on the left drawn on the left")
})

check("windows stacked on one spot still separate", () => {
  const same = Array.from({ length: 6 }, () => ({ x: 100, y: 100, w: 900, h: 600 }))
  const out = L.spread(same, AREA, OPTS)
  for (let i = 0; i < out.length; i++)
    for (let j = i + 1; j < out.length; j++) ok(!overlaps(out[i], out[j]), i + " vs " + j)
})

check("many windows fit", () => {
  const many = Array.from({ length: 24 }, (_, i) => ({ x: (i % 6) * 300, y: Math.floor(i / 6) * 250, w: 300 + (i % 3) * 200, h: 250 + (i % 4) * 90 }))
  const out = L.spread(many, AREA, OPTS)
  for (let i = 0; i < out.length; i++) {
    ok(inside(out[i], AREA), "rect " + i + " inside")
    for (let j = i + 1; j < out.length; j++) ok(!overlaps(out[i], out[j]), i + " vs " + j)
  }
})

check("missing geometry falls back to a real slot", () => {
  const out = L.spread([{ x: 0, y: 0, w: 0, h: NaN }, {}], AREA, OPTS)
  ok(out[0].w > 0 && out[0].h > 0, "fallback size")
  ok(!overlaps(out[0], out[1]), "still apart")
})

check("partition never leaves a row empty", () => {
  const items = [{ w: 1000 }, { w: 10 }, { w: 10 }]
  const rows = L.partition(items, 3)
  eq(rows.map((r) => r.length), [1, 1, 1])
})

check("strip tiles keep aspect and fit", () => {
  const t = L.stripTiles(5, 1880, 16 / 9, { gap: 20, maxH: 124, addW: 56 })
  eq(t.h, 124, "full height when room")
  ok(Math.abs(t.w / t.h - 16 / 9) < 0.02, "aspect")
  const crowded = L.stripTiles(12, 1880, 16 / 9, { gap: 20, maxH: 124, addW: 56 })
  ok(crowded.w * 12 + 20 * 12 + 56 <= 1880, "twelve fit")
  ok(crowded.h < 124, "shrunk")
})

check("arrows move to the neighbour in that direction", () => {
  const rects = [
    { x: 0, y: 0, w: 100, h: 100 }, { x: 200, y: 0, w: 100, h: 100 },
    { x: 0, y: 200, w: 100, h: 100 }, { x: 200, y: 200, w: 100, h: 100 }
  ]
  eq(L.neighbor(rects, 0, "right"), 1)
  eq(L.neighbor(rects, 0, "down"), 2)
  eq(L.neighbor(rects, 3, "left"), 2)
  eq(L.neighbor(rects, 3, "up"), 1)
  eq(L.neighbor(rects, 0, "left"), 0, "edge stays put")
  eq(L.neighbor(rects, -1, "left"), 0, "no cursor starts at the first")
  eq(L.neighbor([], 0, "left"), -1, "nothing to select")
})

check("the rect under a point", () => {
  const rects = [{ x: 0, y: 0, w: 100, h: 100 }, { x: 200, y: 0, w: 100, h: 100 }]
  eq(L.rectAt(rects, 50, 50), 0)
  eq(L.rectAt(rects, 250, 99), 1)
  eq(L.rectAt(rects, 150, 50), -1, "between them")
  eq(L.rectAt(rects, 100, 50), -1, "right edge is outside")
  eq(L.rectAt(null, 0, 0), -1, "no rects")
})

check("wallpaper pieces stay inside the screen", () => {
  eq(L.clampInto({ x: 100, y: 50, w: 400, h: 300 }, 1536, 960), { x: 100, y: 50, w: 400, h: 300 }, "inside untouched")
  eq(L.clampInto({ x: 1503, y: 34, w: 729, h: 914 }, 1536, 960), { x: 807, y: 34, w: 729, h: 914 }, "over the right edge slides back")
  eq(L.clampInto({ x: -2181, y: 34, w: 729, h: 914 }, 1536, 960), { x: 0, y: 34, w: 729, h: 914 }, "off to the left")
  eq(L.clampInto({ x: 10, y: 10, w: 3000, h: 2000 }, 1536, 960), { x: 0, y: 0, w: 1536, h: 960 }, "bigger than the screen")
})

if (failures.length) {
  console.log(failures.map((f) => "FAIL " + f).join("\n"))
  console.log(passed + " passed, " + failures.length + " failed")
  process.exit(1)
}
console.log(passed + " passed")
