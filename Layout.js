// Pure geometry for the overview: where each window's thumbnail goes, how big
// the workspace tiles are, and which thumbnail an arrow key lands on.
//
// Qt-free on purpose, so test/layout-test.sh runs it under plain node with no
// compositor and no shell. Rects are plain {x, y, w, h} objects in the
// monitor's logical pixels; nothing here is ever mutated in place.

// A window Hyprland has not reported a size for yet still gets a slot.
var FALLBACK_W = 800
var FALLBACK_H = 500

function sane(rect) {
  var w = Number(rect && rect.w), h = Number(rect && rect.h)
  var x = Number(rect && rect.x), y = Number(rect && rect.y)
  return {
    x: isFinite(x) ? x : 0,
    y: isFinite(y) ? y : 0,
    w: isFinite(w) && w > 0 ? w : FALLBACK_W,
    h: isFinite(h) && h > 0 ? h : FALLBACK_H
  }
}

// Split windows, already in reading order, into `rows` runs of roughly equal
// total width. Contiguous runs keep a window above another in a row above it.
function partition(items, rows) {
  var total = 0
  for (var i = 0; i < items.length; i++) total += items[i].w
  var target = total / rows
  var out = [[]]
  var width = 0
  for (var j = 0; j < items.length; j++) {
    var left = items.length - j
    var rowsLeft = rows - out.length
    var row = out[out.length - 1]
    // Start a new row once this one is full, or when every remaining row
    // needs at least one window.
    if (row.length > 0 && rowsLeft > 0 && (width + items[j].w / 2 > target || left <= rowsLeft)) {
      out.push([])
      width = 0
      row = out[out.length - 1]
    }
    row.push(items[j])
    width += items[j].w
  }
  return out
}

// Lay out `windows` (real geometry, any order) inside `area` without overlap,
// every window at one shared scale so their relative sizes stay true, never
// larger than life. `gap` is the space between thumbnails, `labelHeight` the
// room each row keeps under its thumbnails for the title. Returns one rect per
// window, in the order given.
function spread(windows, area, opts) {
  var n = windows ? windows.length : 0
  if (n === 0) return []
  opts = opts || {}
  var gap = Math.max(0, Number(opts.gap) || 0)
  var labelHeight = Math.max(0, Number(opts.labelHeight) || 0)
  var maxScale = Number(opts.maxScale) > 0 ? Number(opts.maxScale) : 1

  var items = []
  for (var i = 0; i < n; i++) {
    var r = sane(windows[i])
    items.push({ index: i, x: r.x, y: r.y, w: r.w, h: r.h, cx: r.x + r.w / 2, cy: r.y + r.h / 2 })
  }
  // Reading order: top to bottom, ties left to right.
  items.sort(function(a, b) { return a.cy - b.cy || a.cx - b.cx || a.index - b.index })

  var best = null
  for (var rows = 1; rows <= n; rows++) {
    var runs = partition(items, rows)
    var scale = maxScale
    var tallest = 0
    for (var k = 0; k < runs.length; k++) {
      var sumW = 0, maxH = 0
      for (var m = 0; m < runs[k].length; m++) {
        sumW += runs[k][m].w
        maxH = Math.max(maxH, runs[k][m].h)
      }
      scale = Math.min(scale, (area.w - gap * (runs[k].length - 1)) / sumW)
      tallest += maxH
    }
    scale = Math.min(scale, (area.h - (gap + labelHeight) * runs.length + gap) / tallest)
    // Strictly better only: of two equal fits, fewer rows reads calmer.
    if (!best || scale > best.scale + 1e-9) best = { scale: scale, runs: runs }
  }

  var s = Math.max(0.01, best.scale)
  var heights = best.runs.map(function(run) {
    return run.reduce(function(h, it) { return Math.max(h, it.h * s) }, 0)
  })
  var blockH = heights.reduce(function(a, h) { return a + h }, 0)
    + (gap + labelHeight) * best.runs.length - gap
  var y = area.y + Math.max(0, (area.h - blockH) / 2)

  var out = new Array(n)
  for (var ri = 0; ri < best.runs.length; ri++) {
    // Within a row, left to right as on screen.
    var run = best.runs[ri].slice().sort(function(a, b) { return a.cx - b.cx || a.index - b.index })
    var rowW = run.reduce(function(a, it) { return a + it.w * s }, 0) + gap * (run.length - 1)
    var x = area.x + (area.w - rowW) / 2
    for (var c = 0; c < run.length; c++) {
      var it = run[c]
      var w = it.w * s, h = it.h * s
      out[it.index] = {
        x: Math.round(x),
        y: Math.round(y + (heights[ri] - h) / 2),
        w: Math.round(w),
        h: Math.round(h)
      }
      x += w + gap
    }
    y += heights[ri] + gap + labelHeight
  }
  return out
}

// Workspace tiles along the top: as tall as `maxH` allows, shrunk so `count`
// tiles plus the narrow `+` tile fit across `availW`. Tiles keep the
// monitor's aspect.
function stripTiles(count, availW, aspect, opts) {
  opts = opts || {}
  var gap = Math.max(0, Number(opts.gap) || 0)
  var maxH = Math.max(1, Number(opts.maxH) || 1)
  var addW = Math.max(0, Number(opts.addW) || 0)
  var a = Number(aspect) > 0 ? Number(aspect) : 16 / 9
  var n = Math.max(0, count | 0)
  var h = maxH
  if (n > 0) h = Math.min(maxH, (availW - addW - gap * n) / (n * a))
  h = Math.max(1, Math.floor(h))
  return { w: Math.floor(h * a), h: h }
}

// The thumbnail an arrow key moves to from `from`: the nearest one whose
// centre lies in that direction, weighing sideways distance double so the
// cursor keeps to its row or column. Stays put when nothing is there.
function neighbor(rects, from, direction) {
  if (!rects || rects.length === 0) return -1
  if (from < 0 || from >= rects.length) return 0
  var o = rects[from]
  var ox = o.x + o.w / 2, oy = o.y + o.h / 2
  var bestIndex = from, bestScore = Infinity
  for (var i = 0; i < rects.length; i++) {
    if (i === from || !rects[i]) continue
    var cx = rects[i].x + rects[i].w / 2, cy = rects[i].y + rects[i].h / 2
    var dx = cx - ox, dy = cy - oy
    var along, across
    if (direction === "left") { along = -dx; across = dy }
    else if (direction === "right") { along = dx; across = dy }
    else if (direction === "up") { along = -dy; across = dx }
    else if (direction === "down") { along = dy; across = dx }
    else return from
    if (along <= 0) continue
    var score = along + 2 * Math.abs(across)
    if (score < bestScore) { bestScore = score; bestIndex = i }
  }
  return bestIndex
}

// The rect under a point, by index, or -1.
function rectAt(rects, x, y) {
  if (!rects) return -1
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i]
    if (r && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return i
  }
  return -1
}

// `rect` moved, keeping its size where it fits, to lie inside a w×h screen:
// the wallpaper behind a window that hangs over an edge, or is off screen,
// ends at that edge.
function clampInto(rect, w, h) {
  var rw = Math.min(rect.w, w), rh = Math.min(rect.h, h)
  return {
    x: Math.max(0, Math.min(rect.x, w - rw)),
    y: Math.max(0, Math.min(rect.y, h - rh)),
    w: rw,
    h: rh
  }
}

function lerp(a, b, t) {
  return a + (b - a) * t
}

function clamp01(t) {
  return t < 0 ? 0 : t > 1 ? 1 : t
}

// A CSS-style cubic Bézier easing at progress t, from its two control points
// in Qt's form ([x1, y1, x2, y2, 1, 1], as Style.easeOut is): x is solved for
// t by bisection, which is exact enough for a frame and never diverges.
function ease(curve, t) {
  t = clamp01(t)
  if (t === 0 || t === 1) return t
  var x1 = curve[0], y1 = curve[1], x2 = curve[2], y2 = curve[3]
  function at(a, b, s) {
    var u = 1 - s
    return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
  }
  var lo = 0, hi = 1, s = t
  for (var i = 0; i < 30; i++) {
    s = (lo + hi) / 2
    if (at(x1, x2, s) < t) lo = s
    else hi = s
  }
  return at(y1, y2, (lo + hi) / 2)
}

if (typeof module !== "undefined") {
  module.exports = {
    FALLBACK_W: FALLBACK_W,
    FALLBACK_H: FALLBACK_H,
    partition: partition,
    spread: spread,
    stripTiles: stripTiles,
    neighbor: neighbor,
    rectAt: rectAt,
    clampInto: clampInto,
    lerp: lerp,
    clamp01: clamp01,
    ease: ease
  }
}
