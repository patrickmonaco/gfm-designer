// Properties panel of the selected element (form, section or item).
// Every field saves itself on change.
/* global Sortable */
import { api } from './api.js';
import { esc, html, showError, navigate } from './ui.js';
import { iconInput, bindIconInputs } from './icons.js';
import { VTYPES, WIDTHS, PREF_LABELS, FORM_TYPES, SCOPES, isList, itemTypeLabel, itemIcon } from './meta.js';

const field = (id, label, control, help = '') => `
    <div class="mb-3">
        <label class="form-label" for="${id}">${esc(label)}</label>
        ${control}
        ${help ? `<div class="form-text">${help}</div>` : ''}
    </div>`;

const toggle = (id, name, label, checked) => `
    <div class="form-check form-switch mb-2">
        <input class="form-check-input" type="checkbox" role="switch" id="${id}" data-field="${name}" ${checked ? 'checked' : ''}>
        <label class="form-check-label" for="${id}">${esc(label)}</label>
    </div>`;

/** Value of a bound control, converted for the API. */
function valueOf(el) {
    if (el.type === 'checkbox') return el.checked ? 'Y' : 'N';
    if (el.dataset.type === 'number') return el.value === '' ? null : Number(el.value);
    const v = el.value.trim();
    return v === '' ? null : v;
}

/** Saves each [data-field] control on change. */
function bind(container, save) {
    container.querySelectorAll('[data-field]').forEach((el) => {
        el.addEventListener('change', () => save(el.dataset.field, valueOf(el)));
    });
}

export function renderProps(container, ed) {
    const sel = ed.findSelection() || { type: 'form', obj: ed.form };
    container.innerHTML = '';
    if (sel.type === 'form') formProps(container, ed);
    else if (sel.type === 'section') sectionProps(container, ed, sel.obj);
    else itemProps(container, ed, sel.obj);
}

// ------------------------------------------------------------------- form

function formProps(container, ed) {
    const f = ed.form;
    const prefs = f.prefs || [];
    container.append(html(`
        <div>
            <h2 class="props-title"><i class="bi bi-file-earmark-text"></i>Formulaire</h2>
            ${field('p-lib', 'Libellé', `<input class="form-control" id="p-lib" data-field="lib" value="${esc(f.lib)}" maxlength="200" required>`)}
            ${field('p-notes', 'Description', `<textarea class="form-control" id="p-notes" data-field="notes" rows="2" maxlength="1000">${esc(f.notes)}</textarea>`,
                'Titre de la région principale de la page générée.')}
            ${field('p-vtype', 'Type', `
                <select class="form-select" id="p-vtype" data-field="vtype">
                    ${Object.entries(FORM_TYPES).map(([code, ft]) => `
                        <option value="${code}" ${code === (f.vtype || 'M') ? 'selected' : ''}>${esc(ft.label)} : ${esc(ft.help.toLowerCase())}</option>`).join('')}
                </select>`)}

            <h3 class="props-subtitle">Accès et publication</h3>
            ${field('p-scope', 'Portée', `
                <select class="form-select" id="p-scope" data-field="scope">
                    ${Object.entries(SCOPES).map(([code, s]) => `
                        <option value="${code}" ${code === String(f.scope ?? '0') ? 'selected' : ''}>${esc(s.label)}</option>`).join('')}
                </select>`)}
            ${toggle('p-authent', 'authent', 'Authentification requise', f.authent === 'Y')}
            ${toggle('p-published', 'isPublished', 'Publié', f.isPublished === 'Y')}
            <p class="form-text mt-0">La portée et la publication sont enregistrées ; leur effet sera mis en place prochainement.</p>
            <dl class="props-facts">
                <dt>Code</dt><dd class="font-monospace">${esc(f.code)}</dd>
                <dt>Page APEX</dt><dd>${f.pageId ?? '—'}</dd>
                <dt>Enregistrements</dt><dd>${f.dataCount}</dd>
            </dl>

            ${prefs.length ? `<h3 class="props-subtitle">Préférences de génération</h3>` : ''}
            <div class="prefs"></div>

            <h3 class="props-subtitle">Actions</h3>
            <div class="d-grid gap-2">
                <button class="btn btn-outline-secondary btn-sm" type="button" data-act="copy"><i class="bi bi-copy me-1"></i>Dupliquer le formulaire</button>
                <button class="btn btn-outline-danger btn-sm" type="button" data-act="reset" ${f.dataCount ? '' : 'disabled'}>
                    <i class="bi bi-eraser me-1"></i>Réinitialiser les données</button>
            </div>
        </div>`));

    const prefBox = container.querySelector('.prefs');
    prefs.forEach((p, n) => {
        const id = `p-pref-${n}`;
        prefBox.append(html(field(id, PREF_LABELS[p.pref] || p.pref, `
            <select class="form-select form-select-sm" id="${id}" data-pref="${esc(p.pref)}">
                <option value="">Par défaut</option>
                ${(p.options || []).map((o) => `<option value="${esc(o.r)}" ${o.r === p.val ? 'selected' : ''}>${esc(o.d)}</option>`).join('')}
            </select>`, p.notes ? esc(p.notes.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ')) : '')));
    });
    prefBox.querySelectorAll('[data-pref]').forEach((el) => {
        el.addEventListener('change', () => ed.savePrefs({ [el.dataset.pref]: el.value || null }));
    });

    bind(container, (name, value) => {
        if (name === 'lib' && !value) { ed.renderProps(); return; }
        ed.updateForm({ [name]: value });
    });
    container.querySelector('[data-act=copy]').addEventListener('click', () => ed.copy());
    container.querySelector('[data-act=reset]').addEventListener('click', () => ed.resetData());
}

// ---------------------------------------------------------------- section

function sectionProps(container, ed, s) {
    const n = ed.form.items.filter((i) => i.sectionId === s.id).length;
    container.append(html(`
        <div>
            <h2 class="props-title"><i class="bi bi-layout-split"></i>Section</h2>
            ${field('p-sname', 'Nom', `<input class="form-control" id="p-sname" data-field="name" value="${esc(s.name)}" maxlength="100">`,
                'Titre de l\'onglet ou de la région dans la page générée.')}
            <p class="small text-body-secondary">${n} champ(s). Faites glisser la poignée <i class="bi bi-grip-vertical"></i> pour changer l'ordre des sections.</p>
            <button class="btn btn-outline-danger btn-sm" type="button" data-act="delete"><i class="bi bi-trash3 me-1"></i>Supprimer la section</button>
        </div>`));
    bind(container, (name, value) => {
        if (!value) { ed.renderProps(); return; }
        ed.updateSection(s.id, { [name]: value });
    });
    container.querySelector('[data-act=delete]').addEventListener('click', () => ed.deleteSection(s.id));
}

// ------------------------------------------------------------------- item

function itemProps(container, ed, item) {
    const others = ed.form.items.filter((i) => i.id !== item.id && i.tcomp !== 'D');
    const sub = item.tcomp === 'D';

    container.append(html(`
        <div>
            <h2 class="props-title"><i class="bi ${itemIcon(item)}"></i>${esc(itemTypeLabel(item))}</h2>
            ${field('p-ilib', 'Libellé', `<input class="form-control" id="p-ilib" data-field="lib" value="${esc(item.lib)}" maxlength="200">`)}
            ${field('p-code', 'Code', `<input class="form-control font-monospace" id="p-code" data-field="code" value="${esc(item.code)}" maxlength="26">`,
                'Nom de la colonne dans la vue et de l\'item APEX. Le modifier après génération change la structure.')}
            ${sub ? `<p class="small text-body-secondary">Grille éditable du formulaire de détail « ${esc(item.compLib)} », liée à la ligne courante.</p>` : `
                ${field('p-desc', 'Aide / description', `<textarea class="form-control" id="p-desc" data-field="description" rows="2" maxlength="400">${esc(item.description)}</textarea>`)}
                ${toggle('p-mand', 'mandatory', 'Obligatoire', item.mandatory === 'Y')}
                ${toggle('p-newrow', 'newRow', 'Commencer une nouvelle ligne', item.newRow !== 'N')}
                ${field('p-span', 'Largeur', `
                    <select class="form-select" id="p-span" data-field="colSpan" data-type="number">
                        ${WIDTHS.map((w) => `<option value="${w.value}" ${String(w.value) === String(item.colSpan ?? '') ? 'selected' : ''}>${w.label}</option>`).join('')}
                    </select>`, 'Ou faites glisser le bord droit du champ dans le formulaire.')}
                ${isList(item) ? field('p-vtype', 'Affichage', `
                    <select class="form-select" id="p-vtype" data-field="vtype">
                        ${Object.entries(VTYPES).map(([k, v]) => `<option value="${k}" ${k === item.vtype ? 'selected' : ''}>${v.label}</option>`).join('')}
                    </select>`) : ''}
                ${isList(item) && item.isInline !== 'Y' ? `<p class="small mb-3">
                    <a href="?view=components&comp=${item.compId}" data-act="comp"><i class="bi bi-list-check me-1"></i>Modifier les valeurs de « ${esc(item.compLib)} »</a>
                    <span class="d-block text-body-secondary">Partagées par tous les champs de ce composant.</span></p>` : ''}
                ${item.isInline === 'Y' ? `<div class="mb-3 lov-editor">
                    <div class="alert alert-warning py-2 small lov-empty d-none" role="alert"><i class="bi bi-exclamation-triangle me-1"></i>Au moins une valeur est nécessaire pour générer le formulaire.</div>
                    <span class="form-label d-block">Valeurs de la liste</span>
                    <ul class="list-group list-group-sm lov-values"></ul>
                    <div class="input-group input-group-sm mt-2">
                        <input class="form-control" id="p-newval" placeholder="Nouvelle valeur" maxlength="100" aria-label="Nouvelle valeur">
                        <button class="btn btn-outline-primary" type="button" data-act="addval"><i class="bi bi-plus-lg"></i></button>
                    </div>
                    <div class="form-text">Glissez les valeurs pour les réordonner.</div>
                </div>` : ''}
                ${field('p-icon', 'Icône', iconInput('p-icon', item.icon, { placeholder: item.compIcon || '' }),
                    `Classe Font APEX, par exemple <code>fa-envelope-o</code>.${item.compIcon ? ` Vide : icône du composant (<code>${esc(item.compIcon)}</code>).` : ''}`)}

                <h3 class="props-subtitle">Affichage conditionnel</h3>
                ${field('p-master', 'Afficher seulement si', `
                    <select class="form-select" id="p-master" data-field="masterId" data-type="number">
                        <option value="">Toujours affiché</option>
                        ${others.map((o) => `<option value="${o.id}" ${o.id === item.masterId ? 'selected' : ''}>${esc(o.lib)}</option>`).join('')}
                    </select>`)}
                <div class="master-value"></div>`}
            ${sub ? '' : `<dl class="props-facts mt-3">
                <dt>Stockage</dt>
                <dd>${item.mapCol
                    ? `<span class="font-monospace">${esc(item.mapCol)}</span> · ${{ N: 'nombre', D: 'date' }[item.mapCol[0]] || 'texte'}`
                    : 'attribué à la prochaine génération'}</dd>
            </dl>`}
            <button class="btn btn-outline-danger btn-sm mt-2" type="button" data-act="delete"><i class="bi bi-trash3 me-1"></i>Supprimer le champ</button>
        </div>`));

    bind(container, (name, value) => {
        if (name === 'lib' && !value) { ed.renderProps(); return; }
        // these changes alter the panel itself: redraw it
        const props = ['code', 'masterId', 'vtype'].includes(name);
        ed.updateItem(item.id, { [name]: value }, { props });
    });
    container.querySelector('[data-act=delete]').addEventListener('click', () => ed.deleteItem(item.id));
    bindIconInputs(container);
    container.querySelector('[data-act=comp]')?.addEventListener('click', (e) => {
        e.preventDefault();
        navigate(`?view=components&comp=${item.compId}`);
    });

    if (item.isInline === 'Y') inlineValues(container, ed, item);
    if (item.masterId) masterValue(container, ed, item);
}

/** Editor of the values of an inline list (GFM_ITEMS.LOV = 'a:b:c'), sortable. */
function inlineValues(container, ed, item) {
    const list = container.querySelector('.lov-values');
    let values = (item.lov || '').split(':').filter(Boolean);

    const save = () => ed.updateItem(item.id, { lov: values.length ? values.join(':') : null });
    const draw = () => {
        container.querySelector('.lov-empty').classList.toggle('d-none', values.length > 0);
        list.innerHTML = values.length ? '' : '<li class="list-group-item small text-body-secondary">Aucune valeur</li>';
        values.forEach((v, n) => {
            const li = html(`<li class="list-group-item d-flex align-items-center gap-2" data-value="${esc(v)}">
                <i class="bi bi-grip-vertical lov-grip"></i><span class="me-auto text-break">${esc(v)}</span>
                <button class="btn btn-sm btn-link text-danger p-0" type="button" aria-label="Retirer ${esc(v)}"><i class="bi bi-x-lg"></i></button>
            </li>`);
            li.querySelector('button').addEventListener('click', () => { values.splice(n, 1); draw(); save(); });
            list.append(li);
        });
    };
    draw();

    Sortable.create(list, {
        handle: '.lov-grip',
        animation: 150,
        onEnd: () => {
            values = [...list.querySelectorAll('[data-value]')].map((li) => li.dataset.value);
            save();
        },
    });

    const input = container.querySelector('#p-newval');
    const add = () => {
        const v = input.value.replace(/[:]/g, ' ').trim();     // ':' is the separator
        if (!v || values.includes(v)) return;
        values.push(v);
        input.value = '';
        draw();
        save();
        input.focus();
    };
    container.querySelector('[data-act=addval]').addEventListener('click', add);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
}

/** Trigger value of a dependent item: list of the master values when available. */
async function masterValue(container, ed, item) {
    const box = container.querySelector('.master-value');
    const current = item.masterValue ?? '';
    let options = [];
    try {
        options = await api.itemLov(item.masterId) || [];
    } catch (err) { showError(err); }

    box.innerHTML = field('p-mval', 'Quand sa valeur est', options.length ? `
        <select class="form-select" id="p-mval" data-field="masterValue">
            <option value="">Renseignée (toute valeur)</option>
            ${options.map((o) => `<option value="${esc(o.r)}" ${o.r === current ? 'selected' : ''}>${esc(o.d)}</option>`).join('')}
            ${current && !options.some((o) => o.r === current) ? `<option value="${esc(current)}" selected>${esc(current)}</option>` : ''}
        </select>` : `
        <input class="form-control" id="p-mval" data-field="masterValue" value="${esc(current)}" placeholder="Vide : dès qu'elle est renseignée">`);
    bind(box, (name, value) => ed.updateItem(item.id, { [name]: value }));
}
