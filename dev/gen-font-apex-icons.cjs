// Generates client/js/font-apex-icons.js from docs/icons.js of
// https://github.com/oracle/font-apex
//   git clone --depth 1 https://github.com/oracle/font-apex /tmp/font-apex
//   node dev/gen-font-apex-icons.cjs /tmp/font-apex/docs/icons.js client/js/font-apex-icons.js
// Then put the commit of the clone in the font-apex.min.css link of index.html.
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const ctx = {}; vm.createContext(ctx); vm.runInContext(src, ctx);
const cats = ctx.fontapex.icons;
const out = {};
let n = 0; const all = new Set();
for (const [cat, list] of Object.entries(cats)) {
  out[cat] = list.map(i => i.filters ? [i.name, i.filters] : [i.name]);
  list.forEach(i => all.add(i.name)); n += list.length;
}
const header = `// Font APEX icons (Universal Theme), by category, with search keywords.
// Generated from docs/icons.js of https://github.com/oracle/font-apex
// (commit 24631d9, March 2024, MIT licence). ${all.size} icons.
// Each entry: [class name, keywords?]. To refresh it, see ARCHITECTURE.md.
`;
fs.writeFileSync(process.argv[3], header + 'export default ' + JSON.stringify(out) + ';\n');
console.log(Object.keys(out).join(', '), '|', all.size, 'icons |', n, 'entries');
