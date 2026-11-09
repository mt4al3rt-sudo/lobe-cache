const state = { count: 0 };
function inc() { state.count += 1; return state.count; }
function render(el) { if (el) el.textContent = "Hitungan: " + state.count; }
state.inc = inc;
