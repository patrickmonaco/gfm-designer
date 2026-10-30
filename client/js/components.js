// Components catalogue (GFM_COMP) and their lists of values (GFM_LOV).
/* global Sortable */
import { api } from './api.js';
import { esc, html, toast, showError, confirmDialog, navigate } from './ui.js';
import { CTYPES, VTYPES } from './meta.js';

const TYPE_ORDER = ['CT', 'CN', 'NB', 'DA', 'LI', 'DL'];
const typeLabel = (c) => (CTYPES[c] || {}).label || c;
const typeIcon = (c) => (CTYPES[c] || CTYPES.CT).icon;
const isListType = (c) => c === 'LI' || c === 'DL';
const plain = (s) => String(s ?? '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();

export class ComponentsView {
    constructor(root, selectedId) {
        this.root = root;
        this.selectedId = selectedId ? Number(selectedId) : null;
        this.list = [];
        this.comp = null;          // selected component, as returned by the API
        this.values = [];          // values being edited: {id?, d, r, isDefault}
        this.dirty = false;
        this.sortable = null;
        this.onBeforeUnload = (e) => { if (this.dirty) { e.preventDefault(); e.returnValue = ''; } };
        window.addEventListener('beforeunload', this.onBeforeUnload);
    }

    destroy() {
        window.removeEventListener('beforeunload', this.onBeforeUnload);
        this.sortable?.destroy();
    }

    /** Asks before losing unsaved values. */
    async canLeave() {
        if (!this.dirty) return true;
        return confirmDialog('Les valeurs modifiées ne sont pas enregistrées. Les abandonner ?',
            { title: 'Modifications non enregistrées', okLabel: 'Abandonner', danger: true });
    }

    async open() {
        this.root.innerHTML = `
            <div class="container-xl py-4 comp-view">
                <div class="d-flex flex-wrap align-items-center gap-2 mb-4">
                    <h1 class="h3 mb-0 me-auto">Composants</h1>
                    <button class="btn btn-primary" type="button" data-act="new"><i class="bi bi-plus-lg me-1"></i>Nouveau composant</button>
                </div>
                <div class="row g-4">
                    <div class="col-lg-4">
                        <div class="input-group mb-3">
                            <span class="input-group-text"><i class="bi bi-search"></i></span>
                            <input class="form-control" type="search" id="comp-search" placeholder="Rechercher" aria-label="Rechercher un composant">
                        </div>
                        <div class="comp-list" role="list"></div>
                    </div>
                    <div class="col-lg-8"><div class="comp-detail"></div></div>
                </div>
            </div>`;
        this.$list = this.root.querySelector('.comp-list');
        this.$detail = this.root.querySelector('.comp-detail');
        this.root.querySelector('#comp-search').addEventListener('input', () => this.renderList());
        this.root.querySelector('[data-act=new]').addEventListener('click', () => this.create());

        await this.loadList();
        const first = this.selectedId || this.list[0]?.id;
        if (first) await this.select(first, { force: true });
        else this.$detail.innerHTML = '<div class="empty-state"><i class="bi bi-boxes"></i><p class="mb-0">Aucun composant.</p></div>';
    }

    async loadList() {
        try {
            const res = await api.components();
            this.list = res?.components || [];
            this.renderList();
        } catch (err) { showError(err); }
    }

    // ---------------------------------------------------------------- list

    renderList() {
        const q = this.root.querySelector('#comp-search').value.trim().toLowerCase();
        const shown = this.list.filter((c) => !q || `${c.lib} ${plain(c.notes)}`.toLowerCase().includes(q));
        const groups = TYPE_ORDER.map((t) => [t, shown.filter((c) => c.ctype === t)]).filter(([, l]) => l.length);
        this.$list.innerHTML = groups.length ? groups.map(([t, comps]) => `
            <div class="comp-group-title"><i class="bi ${typeIcon(t)} me-1"></i>${esc(typeLabel(t))}</div>
            <div class="list-group mb-3">
                ${comps.map((c) => `
                    <button type="button" class="list-group-item list-group-item-action d-flex align-items-center gap-2${c.id === this.selectedId ? ' active' : ''}" data-id="${c.id}" role="listitem">
                        <span class="flex-grow-1 min-w-0">
                            <span class="d-block text-truncate fw-medium">${esc(c.lib)}</span>
                            <span class="d-block small comp-meta text-truncate">
                                ${c.itemCount} champ(s)${c.ctype === 'LI' && c.isInline !== 'Y' ? ` · ${c.valueCount} valeur(s)` : ''}${c.ctype === 'DL' && c.objSource ? ` · ${esc(c.objSource)}` : ''}
                            </span>
                        </span>
                        ${c.factory === 'Y' ? '<span class="badge text-bg-secondary">Standard</span>' : ''}
                    </button>`).join('')}
            </div>`).join('')
            : '<p class="text-body-secondary small">Aucun composant ne correspond.</p>';
        this.$list.querySelectorAll('[data-id]').forEach((b) => {
            b.addEventListener('click', () => this.select(Number(b.dataset.id)));
        });
    }

    async select(id, { force = false } = {}) {
        if (!force && id === this.selectedId && this.comp) return;
        if (!force && !await this.canLeave()) return;
        this.selectedId = id;
        history.replaceState(null, '', `?view=components&comp=${id}`);
        this.renderList();
        this.$detail.innerHTML = '<div class="p-5 text-center text-body-secondary"><span class="spinner-border"></span></div>';
        try {
            this.setComponent(await api.component(id));
        } catch (err) {
            showError(err);
            this.$detail.innerHTML = '';
        }
    }

    /** New state of the selected component returned by the API. */
    setComponent(comp) {
        this.comp = comp;
        this.values = (comp.values || []).map((v) => ({ ...v }));
        this.dirty = false;
        const i = this.list.findIndex((c) => c.id === comp.id);
        const summary = { ...comp, valueCount: comp.values?.length || 0 };
        if (i >= 0) this.list[i] = { ...this.list[i], ...summary }; else this.list.push(summary);
        this.renderList();
        this.renderDetail();
    }

    // -------------------------------------------------------------- detail

    renderDetail() {
        const c = this.comp;
        const factory = c.factory === 'Y';
        const used = c.itemCount > 0;
        const deleteBlocked = factory ? 'Composant standard' : used ? `Utilisé par ${c.itemCount} champ(s)` : '';
        const staticList = c.ctype === 'LI' && c.isInline !== 'Y';

        this.$detail.innerHTML = `
            <div class="card">
                <div class="card-body">
                    <div class="d-flex align-items-start gap-2 mb-3">
                        <i class="bi ${typeIcon(c.ctype)} comp-icon"></i>
                        <div class="me-auto min-w-0">
                            <h2 class="h4 mb-0 text-break">${esc(c.lib)}</h2>
                            <div class="small text-body-secondary">${esc(typeLabel(c.ctype))}${factory ? ' · composant standard' : ''}</div>
                        </div>
                        <span class="d-inline-block" ${deleteBlocked ? `tabindex="0" title="${esc(deleteBlocked)}"` : ''}>
                            <button class="btn btn-sm btn-outline-danger" type="button" data-act="delete" ${deleteBlocked ? 'disabled' : ''}>
                                <i class="bi bi-trash3"></i><span class="d-none d-sm-inline ms-1">Supprimer</span></button>
                        </span>
                    </div>

                    <div class="row g-3">
                        <div class="col-md-6">
                            <label class="form-label" for="c-lib">Libellé</label>
                            <input class="form-control" id="c-lib" data-field="lib" value="${esc(c.lib)}" maxlength="200" ${factory ? 'readonly' : ''}>
                        </div>
                        <div class="col-md-6">
                            <label class="form-label" for="c-ctype">Type</label>
                            <select class="form-select" id="c-ctype" data-field="ctype" ${factory || used ? 'disabled' : ''}>
                                ${TYPE_ORDER.map((t) => `<option value="${t}" ${t === c.ctype ? 'selected' : ''}>${esc(typeLabel(t))}</option>`).join('')}
                            </select>
                            ${used && !factory ? '<div class="form-text">Type figé : le composant est utilisé.</div>' : ''}
                        </div>
                        <div class="col-12">
                            <label class="form-label" for="c-notes">Description</label>
                            <textarea class="form-control" id="c-notes" data-field="notes" rows="2" maxlength="400">${esc(plain(c.notes))}</textarea>
                            <div class="form-text">Affichée en info-bulle dans la palette de l'éditeur.</div>
                        </div>
                        ${isListType(c.ctype) ? `
                        <div class="col-md-6">
                            <label class="form-label" for="c-vtype">Affichage par défaut</label>
                            <select class="form-select" id="c-vtype" data-field="vtype">
                                ${Object.entries(VTYPES).map(([k, v]) => `<option value="${k}" ${k === c.vtype ? 'selected' : ''}>${v.label}</option>`).join('')}
                            </select>
                            <div class="form-text">Repris par les nouveaux champs ; modifiable champ par champ.</div>
                        </div>` : ''}
                        <div class="col-md-6">
                            <label class="form-label" for="c-icon">Icône</label>
                            <input class="form-control" id="c-icon" data-field="icon" value="${esc(c.icon)}" maxlength="100" placeholder="fa-envelope-o">
                            <div class="form-text">Icône par défaut des champs (classe Font APEX).</div>
                        </div>
                        ${c.ctype === 'DL' ? `
                        <div class="col-12">
                            <label class="form-label" for="c-source">Vue source</label>
                            <div class="input-group">
                                <input class="form-control font-monospace" id="c-source" data-field="objSource" value="${esc(c.objSource)}" maxlength="50" placeholder="GFM_SITES_V">
                                <button class="btn btn-outline-secondary" type="button" data-act="preview"><i class="bi bi-eye me-1"></i>Aperçu</button>
                            </div>
                            <div class="form-text">Vue ou table exposant les colonnes <code>D</code> (libellé affiché) et <code>R</code> (valeur enregistrée).</div>
                        </div>` : ''}
                    </div>

                    ${c.forms?.length ? `
                    <p class="small text-body-secondary mt-3 mb-0"><i class="bi bi-link-45deg me-1"></i>Utilisé dans :
                        ${c.forms.map((f) => `<a href="?form=${f.id}" data-form="${f.id}">${esc(f.lib)}</a>`).join(', ')}</p>` : ''}
                </div>
            </div>

            ${staticList ? `
            <div class="card mt-4 values-card">
                <div class="card-header d-flex align-items-center gap-2">
                    <h3 class="h6 mb-0 me-auto">Valeurs de la liste</h3>
                    <button class="btn btn-sm btn-outline-secondary" type="button" data-act="paste"><i class="bi bi-clipboard-plus me-1"></i>Coller une liste</button>
                    <button class="btn btn-sm btn-outline-primary" type="button" data-act="add"><i class="bi bi-plus-lg me-1"></i>Ajouter</button>
                </div>
                <div class="card-body">
                    <div class="values-head d-none d-md-grid">
                        <span></span><span>Libellé affiché</span><span>Valeur enregistrée</span><span class="text-center">Défaut</span><span></span>
                    </div>
                    <ul class="values-list list-unstyled mb-0"></ul>
                    <p class="form-text mb-0 mt-2">Glissez la poignée <i class="bi bi-grip-vertical"></i> pour changer l'ordre d'affichage. Sans valeur enregistrée, le libellé est repris.</p>
                </div>
                <div class="card-footer d-flex align-items-center gap-2 values-footer">
                    <span class="values-state small me-auto"></span>
                    <button class="btn btn-sm btn-outline-secondary" type="button" data-act="cancel">Annuler</button>
                    <button class="btn btn-sm btn-primary" type="button" data-act="save"><i class="bi bi-check-lg me-1"></i>Enregistrer les valeurs</button>
                </div>
            </div>` : ''}

            ${c.isInline === 'Y' ? `
            <div class="alert alert-info mt-4 mb-0"><i class="bi bi-info-circle me-2"></i>
                Les valeurs d'une liste inline sont propres à chaque champ : elles se saisissent dans les propriétés du champ, dans l'éditeur de formulaire.</div>` : ''}

            ${isListType(c.ctype) && c.isInline !== 'Y' ? `
            <div class="card mt-4">
                <div class="card-header"><h3 class="h6 mb-0">Aperçu dans un formulaire</h3></div>
                <div class="card-body list-preview"></div>
            </div>` : ''}`;

        // properties: saved on change
        this.$detail.querySelectorAll('[data-field]').forEach((el) => {
            el.addEventListener('change', () => this.saveField(el.dataset.field, el.value.trim() || null, el));
        });
        this.$detail.querySelector('[data-act=delete]').addEventListener('click', () => this.remove());
        this.$detail.querySelectorAll('[data-form]').forEach((a) => a.addEventListener('click', (e) => {
            e.preventDefault();
            this.canLeave().then((ok) => { if (ok) { this.dirty = false; navigate(`?form=${a.dataset.form}`); } });
        }));
        this.$detail.querySelector('[data-act=preview]')?.addEventListener('click', () => this.renderPreview(true));

        if (staticList) {
            this.$detail.querySelector('[data-act=add]').addEventListener('click', () => this.addValue());
            this.$detail.querySelector('[data-act=paste]').addEventListener('click', () => this.pasteValues());
            this.$detail.querySelector('[data-act=save]').addEventListener('click', () => this.saveValues());
            this.$detail.querySelector('[data-act=cancel]').addEventListener('click', () => {
                this.values = (this.comp.values || []).map((v) => ({ ...v }));
                this.setDirty(false);
                this.renderValues();
            });
            this.renderValues();
        }
        this.setDirty(this.dirty);
        if (isListType(c.ctype) && c.isInline !== 'Y') this.renderPreview(false);
    }

    async saveField(field, value, el) {
        if (field === 'lib' && !value) { el.value = this.comp.lib; return; }
        if (field === 'ctype' && isListType(value) !== isListType(this.comp.ctype) && this.dirty) {
            if (!await this.canLeave()) { el.value = this.comp.ctype; return; }
        }
        try {
            const comp = await api.updateComponent(this.comp.id, { [field]: value });
            const keepValues = this.dirty ? this.values : null;
            this.setComponent(comp);
            if (keepValues) { this.values = keepValues; this.renderValues(); this.setDirty(true); }
            toast('Composant enregistré');
        } catch (err) {
            showError(err);
            el.value = this.comp[field] ?? '';
        }
    }

    // -------------------------------------------------------------- values

    setDirty(dirty) {
        this.dirty = dirty;
        const footer = this.$detail.querySelector('.values-footer');
        if (!footer) return;
        footer.classList.toggle('is-dirty', dirty);
        footer.querySelector('.values-state').innerHTML = dirty
            ? '<i class="bi bi-pencil-square me-1"></i>Modifications non enregistrées'
            : `<i class="bi bi-check2 me-1"></i>${this.values.length} valeur(s) enregistrée(s)`;
        footer.querySelector('[data-act=save]').disabled = !dirty;
        footer.querySelector('[data-act=cancel]').disabled = !dirty;
    }

    renderValues() {
        const list = this.$detail.querySelector('.values-list');
        if (!list) return;
        this.sortable?.destroy();
        list.innerHTML = this.values.length ? '' : '<li class="values-empty">Aucune valeur. Ajoutez-en ou collez une liste.</li>';
        this.values.forEach((v, n) => {
            const li = html(`
                <li class="value-row" data-index="${n}">
                    <i class="bi bi-grip-vertical value-grip" title="Glisser pour réordonner"></i>
                    <input class="form-control form-control-sm" data-key="d" value="${esc(v.d)}" maxlength="200" aria-label="Libellé affiché" placeholder="Libellé affiché">
                    <input class="form-control form-control-sm font-monospace" data-key="r" value="${esc(v.r)}" maxlength="200" aria-label="Valeur enregistrée" placeholder="${esc(v.d || 'Valeur')}">
                    <div class="text-center"><input class="form-check-input" type="radio" name="value-default" ${v.isDefault === 'Y' ? 'checked' : ''} aria-label="Valeur par défaut"></div>
                    <button class="btn btn-sm btn-link text-danger p-0" type="button" aria-label="Retirer la valeur"><i class="bi bi-x-lg"></i></button>
                </li>`);
            li.querySelectorAll('[data-key]').forEach((input) => input.addEventListener('input', () => {
                this.values[n][input.dataset.key] = input.value;
                if (input.dataset.key === 'd') li.querySelector('[data-key=r]').placeholder = input.value || 'Valeur';
                this.setDirty(true);
            }));
            li.querySelector('[type=radio]').addEventListener('change', () => {
                this.values.forEach((x, k) => { x.isDefault = k === n ? 'Y' : 'N'; });
                this.setDirty(true);
            });
            li.querySelector('button').addEventListener('click', () => {
                this.values.splice(n, 1);
                this.renderValues();
                this.setDirty(true);
            });
            list.append(li);
        });

        this.sortable = Sortable.create(list, {
            handle: '.value-grip',
            draggable: '.value-row',
            animation: 150,
            ghostClass: 'drag-ghost',
            onEnd: (evt) => {
                if (evt.oldIndex === evt.newIndex) return;
                const [moved] = this.values.splice(evt.oldIndex, 1);
                this.values.splice(evt.newIndex, 0, moved);
                this.renderValues();
                this.setDirty(true);
            },
        });
    }

    addValue() {
        this.values.push({ d: '', r: '', isDefault: 'N' });
        this.renderValues();
        this.setDirty(true);
        const rows = this.$detail.querySelectorAll('.value-row [data-key=d]');
        rows[rows.length - 1]?.focus();
    }

    async pasteValues() {
        const text = await new Promise((resolve) => {
            const el = html(`
                <div class="modal fade" tabindex="-1">
                    <div class="modal-dialog modal-dialog-centered">
                        <form class="modal-content">
                            <div class="modal-header">
                                <h2 class="modal-title fs-5">Coller une liste</h2>
                                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fermer"></button>
                            </div>
                            <div class="modal-body">
                                <label class="form-label" for="paste-area">Une valeur par ligne</label>
                                <textarea class="form-control font-monospace" id="paste-area" rows="8" placeholder="Toulouse;TLS&#10;Bordeaux;BDX&#10;Lyon"></textarea>
                                <div class="form-text">« Libellé ; valeur » ou « Libellé » seul (séparateur <code>;</code> ou tabulation, comme un copier depuis un tableur). Les valeurs déjà présentes sont ignorées.</div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Annuler</button>
                                <button type="submit" class="btn btn-primary">Ajouter</button>
                            </div>
                        </form>
                    </div>
                </div>`);
            document.body.append(el);
            // eslint-disable-next-line no-undef
            const m = new bootstrap.Modal(el);
            let result = null;
            el.querySelector('form').addEventListener('submit', (e) => { e.preventDefault(); result = el.querySelector('textarea').value; m.hide(); });
            el.addEventListener('shown.bs.modal', () => el.querySelector('textarea').focus());
            el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(result); });
            m.show();
        });
        if (!text) return;
        const existing = new Set(this.values.map((v) => (v.r || v.d).trim()));
        let added = 0;
        for (const line of text.split(/\r?\n/)) {
            if (!line.trim()) continue;
            const [d, r] = line.split(/[;\t]/).map((s) => s.trim());
            const value = r || d;
            if (!value || existing.has(value)) continue;
            existing.add(value);
            this.values.push({ d, r: r || '', isDefault: 'N' });
            added++;
        }
        this.renderValues();
        if (added) this.setDirty(true);
        toast(`${added} valeur(s) ajoutée(s)`, added ? 'success' : 'info');
    }

    async saveValues() {
        const rows = this.$detail.querySelectorAll('.value-row');
        rows.forEach((r) => r.querySelectorAll('input').forEach((i) => i.classList.remove('is-invalid')));
        // the returned value defaults to the label
        const values = this.values.map((v) => ({ ...v, d: (v.d || '').trim(), r: (v.r || '').trim() || (v.d || '').trim() }));
        const seen = new Map();
        let invalid = false;
        values.forEach((v, n) => {
            if (!v.r) { rows[n]?.querySelector('[data-key=d]').classList.add('is-invalid'); invalid = true; return; }
            if (seen.has(v.r)) { rows[n]?.querySelector('[data-key=r]').classList.add('is-invalid'); invalid = true; }
            seen.set(v.r, n);
        });
        if (invalid) { toast('Valeurs vides ou en double : corrigez les lignes signalées', 'danger'); return; }

        const btn = this.$detail.querySelector('[data-act=save]');
        btn.disabled = true;
        try {
            const comp = await api.saveValues(this.comp.id, values.map(({ id, d, r, isDefault }) => ({ id, d, r, isDefault })));
            this.setComponent(comp);
            toast('Valeurs enregistrées');
        } catch (err) {
            showError(err);
            btn.disabled = false;
        }
    }

    /** Rendering of the list in a generated form, with the stored values. */
    async renderPreview(fromButton) {
        const box = this.$detail.querySelector('.list-preview');
        if (!box) return;
        box.innerHTML = '<span class="spinner-border spinner-border-sm"></span>';
        let values = [];
        try {
            values = await api.previewComponent(this.comp.id) || [];
        } catch (err) {
            box.innerHTML = `<div class="text-danger small"><i class="bi bi-exclamation-triangle me-1"></i>${esc(err.message)}</div>`;
            if (fromButton) showError(err);
            return;
        }
        if (!values.length) {
            box.innerHTML = '<p class="small text-body-secondary mb-0">Aucune valeur à afficher.</p>';
            return;
        }
        const def = (this.comp.values || []).find((v) => v.isDefault === 'Y')?.r;
        const label = `<label class="form-label">${esc(this.comp.lib)}</label>`;
        const opts = values.map((v, n) => ({ ...v, n }));
        const vt = this.comp.vtype || 'LIST';
        if (vt === 'RADIO' || vt === 'CHECKBOX') {
            const type = vt === 'RADIO' ? 'radio' : 'checkbox';
            box.innerHTML = `${label}<div>${opts.map((v) => `
                <div class="form-check form-check-inline">
                    <input class="form-check-input" type="${type}" name="pv" id="pv${v.n}" ${v.r === def ? 'checked' : ''}>
                    <label class="form-check-label" for="pv${v.n}">${esc(v.d)}</label>
                </div>`).join('')}</div>`;
        } else if (vt === 'NATIVE_SINGLE_CHECKBOX') {
            box.innerHTML = `<div class="form-check"><input class="form-check-input" type="checkbox" id="pv0">
                <label class="form-check-label" for="pv0">${esc(this.comp.lib)}</label></div>
                <div class="form-text">Case unique : coché = « ${esc(opts[0].r)} ».</div>`;
        } else {
            box.innerHTML = `${label}<select class="form-select">${vt === 'POPUP' ? '' : '<option value=""></option>'}
                ${opts.map((v) => `<option ${v.r === def ? 'selected' : ''}>${esc(v.d)}</option>`).join('')}</select>
                ${vt === 'POPUP' ? '<div class="form-text">Affichée dans une fenêtre de recherche (popup LOV).</div>' : ''}`;
        }
        if (values.length >= 100) box.insertAdjacentHTML('beforeend', '<div class="form-text">100 premières valeurs.</div>');
    }

    // ------------------------------------------------------- create / delete

    async create() {
        if (!await this.canLeave()) return;
        const data = await new Promise((resolve) => {
            const el = html(`
                <div class="modal fade" tabindex="-1">
                    <div class="modal-dialog modal-dialog-centered">
                        <form class="modal-content" novalidate>
                            <div class="modal-header">
                                <h2 class="modal-title fs-5">Nouveau composant</h2>
                                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fermer"></button>
                            </div>
                            <div class="modal-body">
                                <div class="mb-3">
                                    <label class="form-label" for="nc-lib">Libellé</label>
                                    <input class="form-control" id="nc-lib" required maxlength="200" placeholder="Ex. Pays">
                                    <div class="invalid-feedback">Le libellé est obligatoire.</div>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label" for="nc-ctype">Type</label>
                                    <select class="form-select" id="nc-ctype">
                                        ${TYPE_ORDER.map((t) => `<option value="${t}" ${t === 'LI' ? 'selected' : ''}>${esc(typeLabel(t))}</option>`).join('')}
                                    </select>
                                </div>
                                <div class="nc-list">
                                    <label class="form-label" for="nc-vtype">Affichage par défaut</label>
                                    <select class="form-select" id="nc-vtype">
                                        ${Object.entries(VTYPES).map(([k, v]) => `<option value="${k}" ${k === 'LIST' ? 'selected' : ''}>${v.label}</option>`).join('')}
                                    </select>
                                </div>
                                <div class="nc-source mt-3 d-none">
                                    <label class="form-label" for="nc-source">Vue source</label>
                                    <input class="form-control font-monospace" id="nc-source" maxlength="50" placeholder="GFM_SITES_V">
                                    <div class="form-text">Colonnes <code>D</code> (libellé) et <code>R</code> (valeur).</div>
                                    <div class="invalid-feedback">La vue source est obligatoire.</div>
                                </div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Annuler</button>
                                <button type="submit" class="btn btn-primary">Créer</button>
                            </div>
                        </form>
                    </div>
                </div>`);
            document.body.append(el);
            // eslint-disable-next-line no-undef
            const m = new bootstrap.Modal(el);
            const ctype = el.querySelector('#nc-ctype');
            const sync = () => {
                el.querySelector('.nc-list').classList.toggle('d-none', !isListType(ctype.value));
                el.querySelector('.nc-source').classList.toggle('d-none', ctype.value !== 'DL');
            };
            ctype.addEventListener('change', sync);
            sync();
            let result = null;
            el.querySelector('form').addEventListener('submit', (e) => {
                e.preventDefault();
                const lib = el.querySelector('#nc-lib');
                const src = el.querySelector('#nc-source');
                lib.classList.toggle('is-invalid', !lib.value.trim());
                src.classList.toggle('is-invalid', ctype.value === 'DL' && !src.value.trim());
                if (el.querySelector('.is-invalid')) return;
                result = {
                    lib: lib.value.trim(),
                    ctype: ctype.value,
                    vtype: isListType(ctype.value) ? el.querySelector('#nc-vtype').value : null,
                    objSource: ctype.value === 'DL' ? src.value.trim() : null,
                };
                m.hide();
            });
            el.addEventListener('shown.bs.modal', () => el.querySelector('#nc-lib').focus());
            el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(result); });
            m.show();
        });
        if (!data) return;
        try {
            const comp = await api.createComponent(data);
            this.dirty = false;
            this.selectedId = comp.id;
            history.replaceState(null, '', `?view=components&comp=${comp.id}`);
            this.setComponent(comp);
            toast('Composant créé');
            if (comp.ctype === 'LI' && comp.isInline !== 'Y') this.addValue();
        } catch (err) { showError(err); }
    }

    async remove() {
        if (!await confirmDialog(`Supprimer le composant « ${this.comp.lib} » et ses valeurs ?`,
            { title: 'Supprimer le composant', okLabel: 'Supprimer', danger: true })) return;
        try {
            await api.deleteComponent(this.comp.id);
            this.dirty = false;
            this.list = this.list.filter((c) => c.id !== this.comp.id);
            this.comp = null;
            toast('Composant supprimé');
            const next = this.list[0];
            if (next) await this.select(next.id, { force: true });
            else { this.renderList(); this.$detail.innerHTML = ''; }
        } catch (err) { showError(err); }
    }
}
