// GFM Designer - development server without Oracle.
//
// Serves the client and an in-memory implementation of the REST API with the
// same contract as ORDS module gfm.designer (db/02_gfm_api.pkb).
// Data is lost when the server stops. No dependency: Node 18+.
//
//   node dev/mock-server.mjs            -> http://localhost:8080
//   PORT=3000 node dev/mock-server.mjs
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = Number(process.env.PORT || 8080);
const CLIENT = fileURLToPath(new URL('../client/', import.meta.url));
const APP_ID = 157;

// ------------------------------------------------------------------ data
let seq = 1000;
const nextId = () => ++seq;

const comps = [
    { id: 1, lib: 'Yes / No', notes: 'Answer with two choices: Yes or No', ctype: 'LI', vtype: 'RADIO', internal: 'N', lov: [['Oui', 'O'], ['Non', 'N']] },
    { id: 3, lib: 'Inline List', notes: 'List of values declared at form level', ctype: 'LI', vtype: 'LIST', internal: 'N' },
    { id: 4, lib: 'Date', notes: 'Date field', ctype: 'DA', internal: 'N' },
    { id: 6, lib: 'Text Field', notes: 'Standard Text field used for short text', ctype: 'CT', internal: 'N' },
    { id: 7, lib: 'Text Area', notes: 'Text area with 1000 char max', ctype: 'CN', internal: 'N' },
    { id: 11, lib: 'Email', notes: 'Email', ctype: 'CT', internal: 'N', icon: 'fa-envelope-o' },
    { id: 12, lib: 'Number', notes: 'Number', ctype: 'NB', internal: 'N' },
    { id: 20, lib: 'Activités', notes: 'Activités de l\'entreprise', ctype: 'LI', vtype: 'LIST', internal: 'N',
        lov: [['Services nucléaires', 'SERVICES NUCLEAIRES'], ['Amiante', 'AMIANTE'], ['Tertiaire', 'TERTIAIRE']] },
    { id: 21, lib: 'Sites', notes: 'Liste des sites (vue GFM_SITES_V)', ctype: 'DL', vtype: 'POPUP', internal: 'N',
        lov: [['Toulouse', 'TLS'], ['Bordeaux', 'BDX'], ['Lyon', 'LYS']] },
    { id: 8, lib: '$ITEM_TEMPLATE', notes: 'Templates used for items. Depending this pref, label will be placed beside the field or inside it', ctype: 'LI', internal: 'Y',
        lov: [['Floating', 'FLOATING'], ['Above', 'ABOVE'], ['Beside', 'BESIDE']] },
    { id: 9, lib: '$ITEM_HELP', notes: 'Displays a help message for each item', ctype: 'LI', internal: 'Y', lov: [['Oui', 'Y'], ['Non', 'N']] },
    { id: 10, lib: '$PAGE_TEMPLATE', notes: 'Page template', ctype: 'LI', internal: 'Y', lov: [['Standard', 'STANDARD'], ['Left Side Column', 'LEFT_SIDE_COLUMN']] },
    { id: 13, lib: '$REGION_SECTION', notes: 'Mode for displaying sections', ctype: 'LI', internal: 'Y',
        lov: [['Tabs', 'TABS_CONTAINER'], ['Display selector', 'DISPLAY_SELECTOR'], ['Standard', 'STANDARD']] },
];

// values as in GFM_LOV, in display order (SEQ); factory = standard components
const FACTORY = new Set(['Yes / No', 'Inline List', 'Date', 'Text Field', 'Text Area', 'Email', 'Number']);
for (const c of comps) {
    c.values = (c.lov || []).map(([d, r]) => ({ id: nextId(), d, r, isDefault: 'N' }));
    delete c.lov;
    c.factory = FACTORY.has(c.lib) ? 'Y' : 'N';
    c.objSource = c.ctype === 'DL' ? 'GFM_SITES_V' : null;
    c.icon = c.icon || null;
    c.groupe = null;
}
const forms = [];
const sections = [];
const items = [];
const prefs = [];        // {formId, pref, val}
const data = [];         // {formId}

function addForm(f) {
    const form = { id: nextId(), notes: null, vtype: 'M', authent: 'Y', scope: '0', isPublished: 'N', pageId: null, reportPageId: null, lastBuild: null,
        isViewGenerated: 'N', isFormGenerated: 'N', ...f };
    forms.push(form);
    prefs.push({ formId: form.id, pref: '$ITEM_TEMPLATE', val: 'FLOATING' },
        { formId: form.id, pref: '$REGION_SECTION', val: 'TABS_CONTAINER' });
    return form;
}
function addSection(formId, name) {
    const rank = sections.filter((s) => s.formId === formId).length + 1;
    const s = { id: nextId(), formId, name, rank };
    sections.push(s);
    return s;
}
function addItem(formId, sectionId, compId, lib, extra = {}) {
    const { code, ...rest } = extra;
    const it = { id: nextId(), formId, sectionId, compId, tcomp: 'C', lib,
        description: null, vtype: null, lov: null, seq: (items.filter((i) => i.formId === formId).length + 1) * 10,
        newRow: 'Y', mandatory: 'N', colSpan: null, icon: null, masterId: null, masterValue: null, mapId: null, ...rest,
        code: itemCode(formId, code || lib) };
    const comp = comps.find((c) => c.id === it.compId);
    if (it.tcomp === 'C' && comp && (comp.ctype === 'LI' || comp.ctype === 'DL') && !it.vtype) it.vtype = comp.vtype || 'LIST';
    items.push(it);
    return it;
}

function toCode(text, max, def) {
    let c = String(text || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase()
        .replace(/[^A-Z0-9_]+/g, '_').replace(/^_+|_+$/g, '');
    if (!c) c = def;
    else if (/^[0-9]/.test(c)) c = `C_${c}`;
    return c.slice(0, max);
}
function itemCode(formId, text, excludeId = null) {
    let base = toCode(text, 26, 'CHAMP');
    if (['SEQ_ID', 'FORM_ID', 'PARENT_ID', 'UPD_ID'].includes(base)) base += '_X';
    let code = base;
    for (let n = 2; items.some((i) => i.formId === formId && i.id !== excludeId && i.code === code); n++) code = `${base}_${n}`;
    return code;
}
function formCode(text) {
    const base = toCode(text, 22, 'FORM');
    let code = base;
    for (let n = 2; forms.some((f) => f.code === code); n++) code = `${base}_${n}`;
    return code;
}

// seed: a master form like the APEX page 102, and a detail form
(() => {
    const hist = addForm({ lib: 'Historique accès', code: 'HISTORIQUE_ACCES', vtype: 'D', notes: 'Accès aux sites par contrat' });
    for (const lib of ['Nro contrat', 'Site', 'Début', 'Fin']) addItem(hist.id, null, 6, lib);

    const f = addForm({ lib: 'Fiche Logistique', code: 'FICHE_LOGISTIQUE', pageId: 102, notes: 'Recueil des informations pour la demande d\'accès à un site sensible',
        lastBuild: '2026-10-29T21:58:12', isViewGenerated: 'Y', isFormGenerated: 'Y' });
    const gen = addSection(f.id, 'Général');
    const rh = addSection(f.id, 'RH');
    const hab = addSection(f.id, 'Habilitations');
    const log = addSection(f.id, 'Logistique');
    const nom = addItem(f.id, gen.id, 6, 'Nom du demandeur', { mandatory: 'Y', colSpan: 3, icon: 'fa-user', mapId: 1 });
    const act = addItem(f.id, gen.id, 20, 'Activité', { mandatory: 'Y', colSpan: 2, newRow: 'N', mapId: 2 });
    addItem(f.id, gen.id, 4, 'Date entrée', { colSpan: 3, mapId: 3 });
    addItem(f.id, gen.id, 1, 'Site nucléaire', { colSpan: 3, newRow: 'N', masterId: act.id, masterValue: 'SERVICES NUCLEAIRES', mapId: 4 });
    addItem(f.id, rh.id, 6, 'Adresse', { mapId: 5 });
    addItem(f.id, rh.id, 11, 'Email', { colSpan: 3, mapId: 6 });
    addItem(f.id, rh.id, 6, 'Téléphone', { colSpan: 3, newRow: 'N', mapId: 7 });
    addItem(f.id, hab.id, 3, 'Habilitation défense', { vtype: 'LIST', lov: 'Aucune:Confidentiel défense:Secret défense' });
    addItem(f.id, hab.id, 0, 'Historique accès', { tcomp: 'D', compId: hist.id });
    addItem(f.id, log.id, 1, 'Véhicule de service', { vtype: 'NATIVE_SINGLE_CHECKBOX', colSpan: 3 });
    addItem(f.id, log.id, 1, 'Vestiaire site', { vtype: 'NATIVE_SINGLE_CHECKBOX', colSpan: 3, newRow: 'N' });
    for (let n = 0; n < 12; n++) data.push({ formId: f.id });
    void nom;

    addForm({ lib: 'Demande de badge', code: 'DEMANDE_DE_BADGE', pageId: 103, notes: 'Badge d\'accès temporaire', isPublished: 'Y', scope: '1' });
    const bloc = addForm({ lib: 'Coordonnées', code: 'COORDONNEES', vtype: 'B', notes: 'Adresse, téléphone et email à reprendre dans les formulaires' });
    for (const lib of ['Adresse', 'Téléphone', 'Email']) addItem(bloc.id, null, lib === 'Email' ? 11 : 6, lib);
})();

// ------------------------------------------------------------- documents
function formJson(id) {
    const f = forms.find((x) => x.id === id);
    if (!f) throw httpError(404, `Formulaire ${id} introuvable`);
    return {
        id: f.id, lib: f.lib, code: f.code, notes: f.notes, vtype: f.vtype, authent: f.authent,
        scope: f.scope, isPublished: f.isPublished,
        pageId: f.pageId, reportPageId: f.reportPageId, appId: APP_ID, lastBuild: f.lastBuild,
        isViewGenerated: f.isViewGenerated, isFormGenerated: f.isFormGenerated,
        dataCount: data.filter((d) => d.formId === id).length,
        sections: sections.filter((s) => s.formId === id).sort((a, b) => a.rank - b.rank || a.id - b.id)
            .map((s) => ({ id: s.id, name: s.name, rank: s.rank })),
        items: items.filter((i) => i.formId === id).sort((a, b) => a.seq - b.seq || a.id - b.id).map((i) => {
            const c = i.tcomp === 'C' ? comps.find((x) => x.id === i.compId) : null;
            const d = i.tcomp === 'D' ? forms.find((x) => x.id === i.compId) : null;
            return {
                id: i.id, lib: i.lib, code: i.code, description: i.description, tcomp: i.tcomp, compId: i.compId,
                compLib: d ? d.lib : c?.lib, ctype: d ? 'SF' : c?.ctype, isInline: c?.lib === 'Inline List' ? 'Y' : 'N',
                vtype: i.vtype, lov: i.lov, sectionId: i.sectionId, seq: i.seq, newRow: i.newRow, mandatory: i.mandatory,
                colSpan: i.colSpan, icon: i.icon, compIcon: c?.icon || null, masterId: i.masterId, masterValue: i.masterValue, mapId: i.mapId,
                mapCol: i.mapCol || (i.mapId ? `C${String(i.mapId).padStart(3, '0')}` : null),
            };
        }),
        prefs: comps.filter((c) => c.internal === 'Y' && c.lib.startsWith('$')).sort((a, b) => a.lib.localeCompare(b.lib)).map((c) => ({
            pref: c.lib, notes: c.notes, val: prefs.find((p) => p.formId === id && p.pref === c.lib)?.val ?? null,
            options: c.values.map(({ d, r }) => ({ d, r })),
        })),
    };
}

function httpError(status, message) {
    const e = new Error(message);
    e.status = status;
    return e;
}
const need = (cond, status, message) => { if (!cond) throw httpError(status, message); };
const formOf = (id) => { const f = forms.find((x) => x.id === id); need(f, 404, `Formulaire ${id} introuvable`); return f; };
const yn = (v, def) => (v === undefined || v === null ? def : (v === true || v === 'Y' ? 'Y' : 'N'));

// ---------------------------------------------------------------- routes
const routes = [];
const route = (method, pattern, fn) => routes.push({ method, re: new RegExp(`^${pattern.replace(/:id/g, '(\\d+)')}$`), fn });

route('GET', '/info', () => [200, { user: 'DEV', appId: APP_ID, version: '1.0-mock' }]);

route('GET', '/forms', () => [200, forms.slice().sort((a, b) => a.lib.localeCompare(b.lib)).map((f) => ({
    id: f.id, lib: f.lib, code: f.code, notes: f.notes, vtype: f.vtype, authent: f.authent, scope: f.scope, isPublished: f.isPublished, pageId: f.pageId, reportPageId: f.reportPageId, lastBuild: f.lastBuild,
    itemCount: items.filter((i) => i.formId === f.id).length,
    sectionCount: sections.filter((s) => s.formId === f.id).length,
    dataCount: data.filter((d) => d.formId === f.id).length,
}))]);

route('POST', '/forms', (_, b) => {
    need(b.lib && b.lib.trim(), 422, 'Le libellé du formulaire est obligatoire');
    const used = new Set(forms.flatMap((f) => [f.pageId, f.reportPageId]));
    let page = 101; while (used.has(page)) page++;
    const vtype = b.vtype || 'M';
    need(['M', 'D', 'B'].includes(vtype), 422, 'Type de formulaire attendu : M (formulaire), D (grille) ou B (bloc)');
    const scope = String(b.scope ?? '0');
    need(['0', '1', '2'].includes(scope), 422, 'Portée attendue : 0 (public), 1 (groupe) ou 2 (privé)');
    const f = addForm({ lib: b.lib.trim(), notes: b.notes || null, code: formCode(b.lib), vtype, scope,
        authent: yn(b.authent, 'Y'), isPublished: yn(b.isPublished, 'N'), pageId: vtype === 'M' ? page : null });
    return [201, { id: f.id, form: formJson(f.id) }];
});

route('GET', '/forms/:id', ([id]) => [200, formJson(id)]);

route('PUT', '/forms/:id', ([id], b) => {
    const f = formOf(id);
    if ('lib' in b && b.lib) f.lib = b.lib;
    if ('notes' in b) f.notes = b.notes;
    if ('vtype' in b) {
        need(['M', 'D', 'B'].includes(b.vtype), 422, 'Type de formulaire attendu : M (formulaire), D (grille) ou B (bloc)');
        const used = items.filter((i) => i.tcomp === 'D' && i.compId === id && i.formId !== id).length;
        need(f.vtype !== 'D' || b.vtype === 'D' || !used, 409, `Cette grille est utilisée par ${used} formulaire(s) : son type ne peut pas changer`);
        f.vtype = b.vtype;
    }
    if ('scope' in b) { need(['0', '1', '2'].includes(String(b.scope)), 422, 'Portée attendue : 0 (public), 1 (groupe) ou 2 (privé)'); f.scope = String(b.scope); }
    if ('authent' in b) f.authent = yn(b.authent, 'Y');
    if ('isPublished' in b) f.isPublished = yn(b.isPublished, 'N');
    return [200, formJson(id)];
});

route('DELETE', '/forms/:id', ([id], _, q) => {
    formOf(id);
    const used = items.filter((i) => i.tcomp === 'D' && i.compId === id && i.formId !== id).length;
    need(!used, 409, `Ce formulaire est utilisé comme sous-formulaire par ${used} champ(s) : supprimez-les d'abord`);
    const n = data.filter((d) => d.formId === id).length;
    need(!n || q.get('force') === 'Y', 409, `Le formulaire contient ${n} enregistrement(s) : confirmez pour les supprimer aussi`);
    const f = forms.find((x) => x.id === id);
    const removed = [];
    if (f.isFormGenerated === 'Y') {
        for (const p of [f.pageId, f.reportPageId]) if (p) removed.push(`page ${p} supprimée`);
    }
    if (f.isViewGenerated === 'Y') {
        if (f.vtype === 'M') removed.push(`vue G$_${f.code}_R supprimée`);
        removed.push(`vue G$_${f.code} supprimée`);
    }
    const drop = (arr, pred) => { for (let k = arr.length - 1; k >= 0; k--) if (pred(arr[k])) arr.splice(k, 1); };
    drop(data, (d) => d.formId === id); drop(items, (i) => i.formId === id);
    drop(sections, (s) => s.formId === id); drop(prefs, (p) => p.formId === id); drop(forms, (f) => f.id === id);
    return [200, { deleted: id, message: removed.join(', ') }];
});

route('POST', '/forms/:id/copy', ([id]) => {
    const src = formOf(id);
    const suffix = `_${new Date().toTimeString().slice(0, 8).replace(/:/g, '')}`;
    const used = new Set(forms.flatMap((f) => [f.pageId, f.reportPageId]));
    let page = 101; while (used.has(page)) page++;
    const { id: _ignored, ...props } = src;
    const f = addForm({ ...props, lib: src.lib + suffix, code: src.code.slice(0, 18) + suffix, pageId: page,
        reportPageId: null, lastBuild: null, isViewGenerated: 'N', isFormGenerated: 'N' });
    // preferences of the source instead of the defaults
    for (let k = prefs.length - 1; k >= 0; k--) if (prefs[k].formId === f.id) prefs.splice(k, 1);
    prefs.push(...prefs.filter((p) => p.formId === id).map((p) => ({ ...p, formId: f.id })));
    const secMap = new Map();
    for (const s of sections.filter((s) => s.formId === id)) { const n = { ...s, id: nextId(), formId: f.id }; sections.push(n); secMap.set(s.id, n.id); }
    const itemMap = new Map();
    for (const i of items.filter((i) => i.formId === id)) { const n = { ...i, id: nextId(), formId: f.id, sectionId: secMap.get(i.sectionId) ?? null, mapId: null }; items.push(n); itemMap.set(i.id, n.id); }
    for (const i of items.filter((i) => i.formId === f.id && i.masterId)) i.masterId = itemMap.get(i.masterId) ?? null;
    return [201, { id: f.id, form: formJson(f.id) }];
});

route('POST', '/forms/:id/generate', ([id]) => {
    const f = formOf(id);
    need(f.vtype !== 'B', 422, 'Un bloc n\'est pas généré : il sert de groupe de champs réutilisable');
    const formItems = items.filter((i) => i.formId === id);
    const empty = formItems.filter((i) => i.tcomp === 'C' && comps.find((c) => c.id === i.compId)?.lib === 'Inline List'
        && !(i.lov || '').replace(/:/g, '').trim()).map((i) => `« ${i.lib} »`);
    need(!empty.length, 422, `Listes sans valeur : ${empty.join(', ')}. Ajoutez au moins une valeur à chacune avant de générer.`);
    // storage columns by type (same rules as gfm_builder): N001 reserved, 20 N / 20 D, 50 C
    const colOf = (i) => i.mapCol || (i.mapId ? `C${String(i.mapId).padStart(3, '0')}` : null);
    const free = (family, max) => {
        const used = new Set(formItems.map(colOf).filter(Boolean));
        for (let n = 1; n <= max; n++) {
            const col = `${family}${String(n).padStart(3, '0')}`;
            if (col !== 'N001' && !used.has(col)) return col;
        }
        return null;
    };
    for (const i of formItems.filter((x) => x.tcomp === 'C' && !colOf(x)).sort((a, b) => a.seq - b.seq)) {
        const ctype = comps.find((c) => c.id === i.compId)?.ctype;
        const family = ctype === 'NB' ? 'N' : ctype === 'DA' ? 'D' : 'C';
        const col = (family !== 'C' && free(family, 20)) || free('C', 50);
        need(col, 422, `Plus de colonne disponible dans GFM_DATA pour le champ ${i.code}`);
        i.mapCol = col;
        i.mapId = Number(col.slice(1));
    }
    f.isViewGenerated = 'Y';
    let message = 'Vue générée. Régénérez les formulaires maîtres qui utilisent ce sous-formulaire';
    if (f.vtype === 'M') {
        f.isFormGenerated = 'Y';
        f.lastBuild = new Date().toISOString().slice(0, 19);
        let reportMsg = 'inchangé';
        if (!f.reportPageId) {
            const used = new Set(forms.flatMap((x) => [x.pageId, x.reportPageId]));
            let page = 101; while (used.has(page)) page++;
            f.reportPageId = page;
            reportMsg = 'régénéré';
        }
        message = `Page ${f.pageId} générée (rapport ${f.reportPageId} ${reportMsg}) dans l'application ${APP_ID}`;
    }
    return [200, { appId: APP_ID, pageId: f.vtype === 'M' ? f.pageId : null, reportPageId: f.reportPageId, message, form: formJson(id) }];
});

route('POST', '/forms/:id/reset', ([id]) => {
    formOf(id);
    for (let k = data.length - 1; k >= 0; k--) if (data[k].formId === id) data.splice(k, 1);
    for (const i of items.filter((i) => i.formId === id)) { i.mapId = null; i.mapCol = null; }
    forms.find((f) => f.id === id).isViewGenerated = 'N';
    return [200, formJson(id)];
});

route('PUT', '/forms/:id/layout', ([id], b) => {
    formOf(id);
    let s = 0;
    const place = (ids, sectionId) => {
        for (const itemId of ids || []) {
            const it = items.find((i) => i.id === itemId && i.formId === id);
            need(it, 422, `Champ ${itemId} inconnu pour ce formulaire`);
            it.sectionId = sectionId; it.seq = (s += 10);
        }
    };
    place(b.unsectioned, null);
    (b.sections || []).forEach((sec, n) => {
        const row = sections.find((x) => x.id === sec.id && x.formId === id);
        need(row, 422, `Section ${sec.id} inconnue pour ce formulaire`);
        row.rank = n + 1;
        place(sec.items, sec.id);
    });
    return [200, formJson(id)];
});

route('PUT', '/forms/:id/prefs', ([id], b) => {
    formOf(id);
    need(b.prefs, 422, 'Attribut "prefs" attendu');
    for (const [pref, val] of Object.entries(b.prefs)) {
        need(comps.some((c) => c.internal === 'Y' && c.lib === pref), 422, `Préférence inconnue : ${pref}`);
        const k = prefs.findIndex((p) => p.formId === id && p.pref === pref);
        if (k >= 0) prefs.splice(k, 1);
        if (val) prefs.push({ formId: id, pref, val });
    }
    return [200, formJson(id)];
});

route('POST', '/forms/:id/sections', ([id], b) => {
    formOf(id);
    const list = sections.filter((s) => s.formId === id);
    const rank = b.rank || list.length + 1;
    for (const s of list) if (s.rank >= rank) s.rank += 1;
    const s = { id: nextId(), formId: id, name: (b.name || '').trim() || 'Nouvelle section', rank };
    sections.push(s);
    return [201, { id: s.id, form: formJson(id) }];
});

route('PUT', '/sections/:id', ([id], b) => {
    const s = sections.find((x) => x.id === id);
    need(s, 404, 'Ressource introuvable');
    if (b.name && b.name.trim()) s.name = b.name.trim();
    return [200, formJson(s.formId)];
});

route('DELETE', '/sections/:id', ([id]) => {
    const k = sections.findIndex((x) => x.id === id);
    need(k >= 0, 404, 'Ressource introuvable');
    const { formId } = sections[k];
    for (const i of items.filter((i) => i.sectionId === id)) i.sectionId = null;
    sections.splice(k, 1);
    return [200, formJson(formId)];
});

route('POST', '/forms/:id/items', ([id], b) => {
    formOf(id);
    const tcomp = b.tcomp === 'D' ? 'D' : 'C';
    if (b.sectionId) need(sections.some((s) => s.id === b.sectionId && s.formId === id), 422, `Section ${b.sectionId} inconnue pour ce formulaire`);
    let lib = b.lib;
    if (tcomp === 'C') {
        const c = comps.find((x) => x.id === b.compId && x.internal === 'N');
        need(c, 422, `Composant ${b.compId} inconnu`);
        lib = lib || c.lib;
    } else {
        const d = forms.find((x) => x.id === b.compId && x.vtype === 'D');
        need(d, 422, `Sous-formulaire ${b.compId} inconnu (type D attendu)`);
        need(d.id !== id, 422, 'Un formulaire ne peut pas s\'inclure lui-même');
        lib = lib || d.lib;
    }
    const it = addItem(id, b.sectionId || null, b.compId, lib, { tcomp, code: b.code || lib,
        seq: Math.max(0, ...items.filter((i) => i.formId === id).map((i) => i.seq)) + 10 });
    return [201, { id: it.id, form: formJson(id) }];
});

route('PUT', '/items/:id', ([id], b) => {
    const it = items.find((x) => x.id === id);
    need(it, 404, 'Ressource introuvable');
    if (b.lib) it.lib = b.lib;
    if (b.code) it.code = itemCode(it.formId, b.code, id);
    for (const k of ['description', 'vtype', 'lov', 'icon', 'masterValue']) if (k in b) it[k] = b[k];
    if ('mandatory' in b) it.mandatory = yn(b.mandatory, 'N');
    if ('newRow' in b) it.newRow = yn(b.newRow, 'Y');
    if ('colSpan' in b) {
        need(b.colSpan === null || (b.colSpan >= 1 && b.colSpan <= 6), 422, 'Largeur attendue entre 1 et 6 (sixièmes de ligne)');
        it.colSpan = b.colSpan;
    }
    if ('masterId' in b) {
        if (b.masterId) {
            need(b.masterId !== id, 422, 'Un champ ne peut pas dépendre de lui-même');
            need(items.some((x) => x.id === b.masterId && x.formId === it.formId), 422, 'Champ maître inconnu pour ce formulaire');
            it.masterId = b.masterId;
        } else { it.masterId = null; it.masterValue = null; }
    }
    return [200, formJson(it.formId)];
});

route('DELETE', '/items/:id', ([id]) => {
    const k = items.findIndex((x) => x.id === id);
    need(k >= 0, 404, 'Ressource introuvable');
    const { formId } = items[k];
    for (const i of items.filter((i) => i.masterId === id)) { i.masterId = null; i.masterValue = null; }
    items.splice(k, 1);
    return [200, formJson(formId)];
});

route('GET', '/items/:id/lov', ([id]) => {
    const it = items.find((x) => x.id === id);
    need(it, 404, 'Ressource introuvable');
    const c = comps.find((x) => x.id === it.compId);
    if (!c || it.tcomp !== 'C') return [200, []];
    if (c.lib === 'Inline List') return [200, (it.lov || '').split(':').filter(Boolean).map((v) => ({ d: v, r: v }))];
    return [200, c.values.map(({ d, r }) => ({ d, r }))];
});

const usage = (c) => items.filter((i) => i.tcomp === 'C' && i.compId === c.id);
const compSummary = (c) => ({ id: c.id, lib: c.lib, notes: c.notes, ctype: c.ctype, vtype: c.vtype || null, icon: c.icon,
    groupe: c.groupe, objSource: c.objSource, factory: c.factory, isInline: c.lib === 'Inline List' ? 'Y' : 'N',
    itemCount: usage(c).length, valueCount: c.values.length });
const compJson = (c) => ({ ...compSummary(c),
    forms: [...new Set(usage(c).map((i) => i.formId))].map((id) => forms.find((f) => f.id === id)).filter(Boolean)
        .map((f) => ({ id: f.id, lib: f.lib })),
    values: c.values.map(({ id, d, r, isDefault }) => ({ id, d, r, isDefault })) });
const compOf = (id) => { const c = comps.find((x) => x.id === id && x.internal === 'N'); need(c, 404, `Composant ${id} introuvable`); return c; };
const CTYPE_OK = ['CT', 'CN', 'NB', 'DA', 'LI', 'DL'];
const VIEWS = { GFM_SITES_V: [['Bordeaux', 'BDX'], ['Lyon', 'LYS'], ['Toulouse', 'TLS']] };   // fake dynamic sources
const checkSource = (s) => {
    need(s, 422, 'Une liste dynamique doit indiquer sa vue source (colonnes D et R)');
    need(VIEWS[s.toUpperCase()], 422, `Vue ou table « ${s} » introuvable`);
    return s.toUpperCase();
};

route('GET', '/components', () => [200, {
    components: comps.filter((c) => c.internal === 'N').sort((a, b) => a.ctype.localeCompare(b.ctype) || a.lib.localeCompare(b.lib))
        .map(compSummary),
    detailForms: forms.filter((f) => f.vtype === 'D').map((f) => ({ id: f.id, lib: f.lib, code: f.code })),
}]);

route('GET', '/components/:id', ([id]) => [200, compJson(compOf(id))]);

route('POST', '/components', (_, b) => {
    const lib = (b.lib || '').trim();
    need(lib, 422, 'Le libellé du composant est obligatoire');
    need(!lib.startsWith('$') && lib !== 'Inline List', 422, `Libellé réservé : ${lib}`);
    need(CTYPE_OK.includes(b.ctype), 422, 'Type attendu : CT, CN, NB, DA, LI ou DL');
    need(!comps.some((c) => c.lib === lib), 409, `Un composant porte déjà le libellé « ${lib} »`);
    const list = b.ctype === 'LI' || b.ctype === 'DL';
    const c = { id: nextId(), lib, notes: b.notes || null, ctype: b.ctype, vtype: list ? b.vtype || 'LIST' : null, icon: b.icon || null,
        groupe: null, internal: 'N', factory: 'N', objSource: b.ctype === 'DL' ? checkSource(b.objSource) : null, values: [] };
    comps.push(c);
    return [201, compJson(c)];
});

route('PUT', '/components/:id', ([id], b) => {
    const c = compOf(id);
    const lib = 'lib' in b && b.lib ? b.lib.trim() : c.lib;
    const ctype = b.ctype || c.ctype;
    need(c.factory !== 'Y' || (lib === c.lib && ctype === c.ctype), 409, 'Composant standard : son libellé et son type ne peuvent pas changer');
    need(ctype === c.ctype || !usage(c).length, 409, `Le type ne peut pas changer : composant utilisé par ${usage(c).length} champ(s)`);
    need(CTYPE_OK.includes(ctype), 422, 'Type attendu : CT, CN, NB, DA, LI ou DL');
    need(lib === c.lib || !comps.some((x) => x.lib === lib), 409, `Un composant porte déjà le libellé « ${lib} »`);
    const list = ctype === 'LI' || ctype === 'DL';
    const source = 'objSource' in b ? b.objSource : c.objSource;
    Object.assign(c, { lib, ctype,
        notes: 'notes' in b ? b.notes : c.notes, icon: 'icon' in b ? b.icon : c.icon,
        vtype: list ? ('vtype' in b ? b.vtype : c.vtype) || 'LIST' : null,
        objSource: ctype === 'DL' ? checkSource(source) : null });
    return [200, compJson(c)];
});

route('DELETE', '/components/:id', ([id]) => {
    const c = compOf(id);
    need(c.factory !== 'Y', 409, 'Composant standard : il ne peut pas être supprimé');
    const n = usage(c).length;
    need(!n, 409, `Composant utilisé par ${n} champ(s) : supprimez-les ou changez leur composant d'abord`);
    comps.splice(comps.indexOf(c), 1);
    return [200, { deleted: id }];
});

route('PUT', '/components/:id/values', ([id], b) => {
    const c = compOf(id);
    need(c.ctype === 'LI' && c.lib !== 'Inline List', 422, 'Seules les listes statiques ont des valeurs enregistrées');
    need(Array.isArray(b.values), 422, 'Attribut "values" attendu');
    const seen = new Set();
    let hasDefault = false;
    c.values = b.values.map((v, n) => {
        const r = String(v.r ?? '').trim();
        need(r, 422, `Valeur ${n + 1} : la valeur enregistrée est obligatoire`);
        need(!seen.has(r), 422, `Valeur « ${r} » en double`);
        seen.add(r);
        if (v.id) need(c.values.some((x) => x.id === v.id), 422, `Valeur ${v.id} inconnue pour ce composant`);
        const isDefault = v.isDefault === 'Y' && !hasDefault ? 'Y' : 'N';
        hasDefault ||= isDefault === 'Y';
        return { id: v.id || nextId(), d: String(v.d ?? '').trim() || r, r, isDefault };
    });
    return [200, compJson(c)];
});

route('GET', '/components/:id/preview', ([id]) => {
    const c = compOf(id);
    if (c.ctype === 'LI') return [200, c.values.map(({ d, r }) => ({ d, r }))];
    if (c.ctype === 'DL') return [200, VIEWS[checkSource(c.objSource)].map(([d, r]) => ({ d, r }))];
    return [200, []];
});

// ---------------------------------------------------------------- server
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.json': 'application/json' };

const DEV_CONFIG = `export default {
    apiBase: '/api',
    auth: { mode: 'none' },
    apexPageUrl: 'https://apex.oracle.com/pls/apex/f?p={app}:{page}',
};
`;

const send = (res, status, body, type = 'application/json; charset=utf-8') => {
    res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
};

http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
        if (url.pathname.startsWith('/api/')) {
            const path = url.pathname.slice(4);
            let body = {};
            if (req.method === 'POST' || req.method === 'PUT') {
                let raw = '';
                for await (const chunk of req) raw += chunk;
                try { body = raw ? JSON.parse(raw) : {}; } catch { throw httpError(422, 'Corps de requête JSON invalide'); }
            }
            for (const r of routes) {
                const m = r.method === req.method && path.match(r.re);
                if (m) {
                    await new Promise((ok) => setTimeout(ok, 120));      // network latency
                    const [status, payload] = r.fn(m.slice(1).map(Number), body, url.searchParams);
                    send(res, status, payload);
                    return;
                }
            }
            throw httpError(404, `Route inconnue : ${req.method} ${path}`);
        }

        if (url.pathname === '/js/config.js') { send(res, 200, DEV_CONFIG, MIME['.js']); return; }
        const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname.slice(1));
        const file = normalize(join(CLIENT, rel));
        if (!file.startsWith(CLIENT)) throw httpError(403, 'Interdit');
        send(res, 200, await readFile(file), MIME[extname(file)] || 'application/octet-stream');
    } catch (err) {
        const status = err.status || (err.code === 'ENOENT' ? 404 : 500);
        if (status === 500) console.error(err);
        send(res, status, { error: err.message });
    }
}).listen(PORT, () => console.log(`GFM Designer (maquette) : http://localhost:${PORT}`));
