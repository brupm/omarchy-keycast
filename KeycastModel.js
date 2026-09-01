.pragma library

// keyd modifier key names (see `keyd list-keys`). Held members of this set are
// what chord mode joins onto the next non-modifier key.
var MODIFIERS = {
  "leftshift": true, "rightshift": true,
  "leftcontrol": true, "rightcontrol": true,
  "leftalt": true, "rightalt": true,
  "leftmeta": true, "rightmeta": true,
  "iso-level3-shift": true
}

var MODES = ["stream", "chords", "caption"]

function isModifier(key) {
  return MODIFIERS[key] === true
}

function normalizeMode(value) {
  return MODES.indexOf(value) === -1 ? "stream" : value
}

function nextMode(value) {
  var i = MODES.indexOf(normalizeMode(value))
  return MODES[(i + 1) % MODES.length]
}

// Parse one line of `keyd monitor` output.
//   "<device name>\t<vendor:product>\t<keyname> <state>"
// Returns { key, state } with state in {"down","up","repeat"}, or null for
// device-list / diagnostic lines and anything that doesn't match.
function parseLine(line) {
  if (!line)
    return null
  var parts = String(line).split("\t")
  if (parts.length < 3)
    return null
  var field = parts[parts.length - 1].trim()
  var sp = field.lastIndexOf(" ")
  if (sp <= 0)
    return null
  var key = field.slice(0, sp).trim()
  var state = field.slice(sp + 1).trim()
  if (state !== "down" && state !== "up" && state !== "repeat")
    return null
  if (!key || key.indexOf(" ") !== -1)
    return null
  return { key: key, state: state }
}

// Display form of a keyd key name. Literal, uppercased — the whole point is to
// show the name of the key, so no symbol substitution.
function pretty(key) {
  return String(key).toUpperCase()
}
