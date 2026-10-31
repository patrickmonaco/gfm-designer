// Form editor: palette, canvas (drag & drop with SortableJS), properties panel.
/* global Sortable */
import config from './config.js';
import { api } from './api.js';
import { esc, html, toast, showError, confirmDialog, promptDialog, formatDate } from './ui.js';
import { CTYPES, itemIcon, itemTypeLabel, gridSpan, itemProblem } from './meta.js';
import { renderProps } from './props.js';

const GRID_GAP = 8;   // px, must match .gfm-grid gap in app.css

export class Editor {
    constructor(root, formId, { onBack }) {
        this.root = root;
        this.formId = Number(formId);
        this.onBack = onBack;
        this.form = null;
        this.palette = { components: [], detailForms: [] };
        this.selection = 'form';
        this.canvasSortables = [];
        this.paletteSortables = [];
        this.busy = 0;
    }

    // ------------------------------------------------------------------ load

    async open() {
        this.root.innerHTML = `
            <div class="editor">
                <div class="editor-toolbar"></div>
                <div class="editor-body">
                    <aside class="palette" aria-label="Palette de composants"></aside>
                    <section class="canvas" aria-label="Formulaire"></section>
                    <aside class="props" aria-label="Propriétés"></aside>
                </div>
            </div>`;
        this.$toolbar = this.root.querySelector('.editor-toolbar');
        this.$palette = this.root.querySelector('.palette');
        this.$canvas = this.root.querySelector('.canvas');
        this.$props = this.root.querySelector('.props');
        this.$canvas.innerHTML = '<div class="p-5 text-center text-body-secondary"><span class="spinner-border"></span></div>';

        this.$canvas.addEventListener('click', (e) => {
            const target = e.target.closest('[data-select]');
            if (target && !e.target.closest('.resize-handle')) this.select(target.dataset.select);
        });
        this.$canvas.addEventListener('keydown', (e) => this.onCanvasKey(e));

        try {
            const [form, palette] = await Promise.all([api.form(this.formId), api.components()]);
            this.palette = palette || this.palette;
            this.apply(form, { props: true });
            this.renderPalette();
        } catch (err) {
            showError(err);
            this.$canvas.innerHTML = `<div class="empty-state m-4"><i class="bi bi-exclamation-triangle"></i>
                <p>${esc(err.message)}</p><button class="btn btn-outline-primary" type="button">Retour à la liste</button></div>`;
            this.$canvas.querySelector('button').addEventListener('click', () => this.onBack());
        }
    }

    async reload() {
        try { this.apply(await api.form(this.formId), { props: true }); } catch (err) { showError(err); }
    }

    /** New state of the form returned by the API. */
    apply(form, { props = false } = {}) {
        this.form = form;
        if (!this.findSelection()) { this.selection = 'form'; props = true; }
        this.renderToolbar();
        this.renderCanvas();
        if (props) this.renderProps();
    }

    /**
     * Runs an API call that returns the form, with busy indicator and error
     * handling (the canvas is reloaded from the server after an error).
     */
    async mutate(call, { props = false, message } = {}) {
        this.setBusy(+1);
        try {
            const res = await call();
            const form = res && res.form && !res.items ? res.form : res;
            this.apply(form, { props });
            if (message) toast(typeof message === 'function' ? message(res) : message);
            return res;
        } catch (err) {
            showError(err);
            await this.reload();
            return null;
        } finally {
            this.setBusy(-1);
        }
    }

    setBusy(delta) {
        this.busy = Math.max(0, this.busy + delta);
        this.root.querySelector('.editor')?.classList.toggle('is-busy', this.busy > 0);
        const s = this.$toolbar.querySelector('.save-state');
        if (s) {
            s.innerHTML = this.busy
                ? '<span class="spinner-border spinner-border-sm me-1"></span>Enregistrement…'
                : '<i class="bi bi-cloud-check me-1"></i>Enregistré';
        }
    }

    // ------------------------------------------------------------- selection

    findSelection() {
        if (!this.form) return null;
        const [type, id] = this.selection.split(':');
        if (type === 'form') return { type, obj: this.form };
        if (type === 'section') {
            const obj = this.form.sections.find((s) => s.id === Number(id));
            return obj ? { type, obj } : null;
        }
        if (type === 'item') {
            const obj = this.form.items.find((i) => i.id === Number(id));
            return obj ? { type, obj } : null;
        }
        return null;
    }

    select(selection) {
        if (selection === this.selection) return;
        this.selection = selection;
        this.$canvas.querySelectorAll('.is-selected').forEach((el) => el.classList.remove('is-selected'));
        this.$canvas.querySelector(`[data-select="${CSS.escape(selection)}"]`)?.classList.add('is-selected');
        this.renderProps();
    }

    // --------------------------------------------------------------- toolbar

    renderToolbar() {
        const f = this.form;
        const pageUrl = f.pageId && f.appId && f.isFormGenerated === 'Y'
            ? config.apexPageUrl.replace('{app}', f.appId).replace('{page}', f.pageId) : null;
        const reportUrl = f.reportPageId && f.appId && f.isFormGenerated === 'Y'
            ? config.apexPageUrl.replace('{app}', f.appId).replace('{page}', f.reportPageId) : null;
        this.$toolbar.innerHTML = `
            <button class="btn btn-sm btn-outline-secondary" type="button" data-act="back" aria-label="Retour à la liste">
                <i class="bi bi-arrow-left"></i>
            </button>
            <div class="min-w-0 me-auto">
                <div class="d-flex align-items-center gap-2">
                    <h1 class="h5 mb-0 text-truncate">${esc(f.lib)}</h1>
                    <span class="badge ${f.vtype === 'D' ? 'text-bg-info' : 'text-bg-secondary'}">${f.vtype === 'D' ? 'Détail' : 'Maître'}</span>
                </div>
                <div class="small text-body-secondary text-truncate">
                    <span class="font-monospace">${esc(f.code)}</span>
                    ${f.pageId ? ` · page ${f.pageId}` : ''}${f.reportPageId ? `, rapport ${f.reportPageId}` : ''}
                    · ${f.lastBuild ? `générée le ${esc(formatDate(f.lastBuild))}` : 'jamais générée'}
                </div>
            </div>
            <span class="save-state small text-body-secondary d-none d-md-inline"><i class="bi bi-cloud-check me-1"></i>Enregistré</span>
            ${pageUrl ? `<a class="btn btn-sm btn-outline-secondary" href="${esc(pageUrl)}" target="_blank" rel="noopener">
                <i class="bi bi-box-arrow-up-right"></i><span class="d-none d-lg-inline ms-1">Ouvrir la page</span></a>` : ''}
            ${reportUrl ? `<a class="btn btn-sm btn-outline-secondary" href="${esc(reportUrl)}" target="_blank" rel="noopener" title="Report interactif des données saisies">
                <i class="bi bi-table"></i><span class="d-none d-lg-inline ms-1">Rapport</span></a>` : ''}
            <button class="btn btn-sm btn-primary" type="button" data-act="generate">
                <i class="bi bi-lightning-charge"></i><span class="d-none d-sm-inline ms-1">Générer</span>
            </button>`;
        this.$toolbar.querySelector('[data-act=back]').addEventListener('click', () => this.onBack());
        this.$toolbar.querySelector('[data-act=generate]').addEventListener('click', () => this.generate());
        this.setBusy(0);
    }

    // --------------------------------------------------------------- palette

    renderPalette() {
        const comps = this.palette.components || [];
        const details = (this.palette.detailForms || []).filter((d) => d.id !== this.formId);
        const compIcon = (c) => (CTYPES[c.ctype] || CTYPES.CT).icon;

        this.$palette.innerHTML = `
            <div class="palette-scroll">
                <h2 class="palette-title">Structure</h2>
                <div class="palette-list" data-group="sections">
                    <div class="pal-item" data-kind="section" title="Glisser dans le formulaire pour ajouter une section">
                        <i class="bi bi-layout-split"></i><span>Section</span>
                    </div>
                </div>
                <h2 class="palette-title">Champs</h2>
                <div class="palette-list" data-group="items">
                    ${comps.map((c) => `
                        <div class="pal-item" data-kind="comp" data-comp-id="${c.id}" title="${esc(c.notes ? c.notes.replace(/<[^>]*>/g, '') : c.lib)}">
                            <i class="bi ${compIcon(c)}"></i><span>${esc(c.lib)}</span>
                        </div>`).join('')}
                </div>
                ${details.length ? `
                    <h2 class="palette-title">Sous-formulaires</h2>
                    <div class="palette-list" data-group="items">
                        ${details.map((d) => `
                            <div class="pal-item" data-kind="detail" data-form-id="${d.id}" title="Grille éditable du formulaire ${esc(d.lib)}">
                                <i class="bi bi-table"></i><span>${esc(d.lib)}</span>
                            </div>`).join('')}
                    </div>` : ''}
            </div>
            <div class="trash" aria-label="Corbeille : glisser un champ ou une section ici pour le supprimer">
                <i class="bi bi-trash3"></i><span>Glisser ici pour supprimer</span>
            </div>`;

        this.paletteSortables.forEach((s) => s.destroy());
        this.paletteSortables = [];
        this.$palette.querySelectorAll('.palette-list').forEach((list) => {
            this.paletteSortables.push(Sortable.create(list, {
                group: { name: list.dataset.group, pull: 'clone', put: false },
                sort: false,
                animation: 150,
                ...this.dragHooks(),
            }));
        });
        this.paletteSortables.push(Sortable.create(this.$palette.querySelector('.trash'), {
            group: { name: 'trash', pull: false, put: ['items', 'sections'] },
            onAdd: (evt) => this.onTrash(evt),
        }));
    }

    // ---------------------------------------------------------------- canvas

    renderCanvas() {
        const f = this.form;
        const sel = this.selection;
        const byId = new Map(f.items.map((i) => [i.id, i]));
        const unsectioned = f.items.filter((i) => !i.sectionId);
        const sectionPref = (f.prefs || []).find((p) => p.pref === '$REGION_SECTION');
        const sectionMode = { TABS_CONTAINER: 'onglets', DISPLAY_SELECTOR: 'sélecteur', STANDARD: 'blocs' }[sectionPref?.val || 'TABS_CONTAINER'];

        const tile = (item) => {
            const master = item.masterId ? byId.get(item.masterId) : null;
            const span = gridSpan(item);
            const problem = itemProblem(item);
            return `
                <div class="gfm-item${sel === `item:${item.id}` ? ' is-selected' : ''}${item.tcomp === 'D' ? ' is-subform' : ''}${problem ? ' has-problem' : ''}"
                     data-id="${item.id}" data-select="item:${item.id}" tabindex="0"
                     style="grid-column: ${item.newRow === 'N' ? 'auto' : '1'} / span ${span}"
                     aria-label="${esc(item.lib)}">
                    <i class="bi ${itemIcon(item)} item-icon"></i>
                    <div class="item-text">
                        <div class="item-label">${item.icon || item.compIcon ? `<span class="fa ${esc(item.icon || item.compIcon)} item-fa" aria-hidden="true"></span>` : ''}${esc(item.lib)}${item.mandatory === 'Y' ? '<span class="req" title="Obligatoire">*</span>' : ''}</div>
                        <div class="item-meta"><span class="font-monospace">${esc(item.code)}</span> · ${esc(itemTypeLabel(item))}</div>
                    </div>
                    ${problem ? `<span class="item-badge item-problem" title="${esc(problem)}"><i class="bi bi-exclamation-triangle-fill"></i></span>` : ''}
                    ${master ? `<span class="item-badge" title="Affiché si ${esc(master.lib)} ${item.masterValue ? `= ${esc(item.masterValue)}` : 'est renseigné'}"><i class="bi bi-diagram-2"></i></span>` : ''}
                    ${item.tcomp === 'D' ? '' : '<span class="resize-handle" title="Glisser pour changer la largeur"></span>'}
                </div>`;
        };

        this.$canvas.innerHTML = `
            <div class="sheet">
                <div class="sheet-header${sel === 'form' ? ' is-selected' : ''}" data-select="form" tabindex="0">
                    <h2 class="h4 mb-1">${esc(f.lib)}</h2>
                    ${f.notes ? `<p class="mb-0 text-body-secondary">${esc(f.notes)}</p>` : ''}
                </div>

                <div class="zone">
                    <div class="zone-title"><i class="bi bi-arrow-down-short"></i>En tête de formulaire (hors section)</div>
                    <div class="gfm-items gfm-grid" data-section="">${unsectioned.map(tile).join('')}</div>
                </div>

                <div class="zone-title d-flex">
                    <span><i class="bi bi-layout-split me-1"></i>Sections</span>
                    ${f.sections.length > 1 ? `<span class="ms-auto">affichées en ${esc(sectionMode)}</span>` : ''}
                </div>
                <div class="sections">
                    ${f.sections.map((s) => {
                        const items = f.items.filter((i) => i.sectionId === s.id);
                        return `
                            <div class="gfm-section card${sel === `section:${s.id}` ? ' is-selected' : ''}" data-id="${s.id}">
                                <div class="card-header section-header" data-select="section:${s.id}" tabindex="0">
                                    <i class="bi bi-grip-vertical section-grip" title="Glisser pour déplacer la section"></i>
                                    <strong class="text-truncate">${esc(s.name)}</strong>
                                    <span class="badge rounded-pill bg-body-secondary text-body-secondary border ms-auto" title="Nombre de champs">${items.length}</span>
                                </div>
                                <div class="card-body">
                                    <div class="gfm-items gfm-grid" data-section="${s.id}">${items.map(tile).join('')}</div>
                                </div>
                            </div>`;
                    }).join('')}
                </div>
            </div>`;

        this.canvasSortables.forEach((s) => s.destroy());
        this.canvasSortables = [];

        this.$canvas.querySelectorAll('.gfm-items').forEach((list) => {
            this.canvasSortables.push(Sortable.create(list, {
                group: { name: 'items', pull: true, put: ['items'] },
                animation: 150,
                filter: '.resize-handle',
                preventOnFilter: false,
                emptyInsertThreshold: 24,
                ghostClass: 'drag-ghost',
                chosenClass: 'drag-chosen',
                onAdd: (evt) => this.onItemAdd(evt),
                onUpdate: () => this.saveLayout(),
                ...this.dragHooks(),
            }));
        });

        this.canvasSortables.push(Sortable.create(this.$canvas.querySelector('.sections'), {
            group: { name: 'sections', pull: true, put: ['sections'] },
            handle: '.section-grip',
            draggable: '.gfm-section',
            animation: 150,
            ghostClass: 'drag-ghost',
            onAdd: (evt) => this.onSectionAdd(evt),
            onUpdate: () => this.saveLayout(),
            ...this.dragHooks(),
        }));

        this.$canvas.querySelectorAll('.resize-handle').forEach((h) => {
            h.addEventListener('pointerdown', (e) => this.startResize(e));
        });
    }

    dragHooks() {
        return {
            onStart: () => document.body.classList.add('is-dragging'),
            onEnd: () => document.body.classList.remove('is-dragging'),
        };
    }

    /** Current order of sections and items, read from the canvas. */
    readLayout() {
        const ids = (list) => [...list.querySelectorAll(':scope > .gfm-item[data-id]')].map((el) => Number(el.dataset.id));
        return {
            unsectioned: ids(this.$canvas.querySelector('.gfm-items[data-section=""]')),
            sections: [...this.$canvas.querySelectorAll('.sections > .gfm-section[data-id]')].map((s) => ({
                id: Number(s.dataset.id),
                items: ids(s.querySelector('.gfm-items')),
            })),
        };
    }

    saveLayout() {
        return this.mutate(() => api.layout(this.formId, this.readLayout()));
    }

    // ------------------------------------------------------- drag & drop events

    async onItemAdd(evt) {
        const el = evt.item;
        const kind = el.dataset.kind;
        if (kind !== 'comp' && kind !== 'detail') {        // moved from another section
            await this.saveLayout();
            return;
        }

        // dropped from the palette: create the item at this position
        const sectionId = evt.to.dataset.section ? Number(evt.to.dataset.section) : null;
        const body = kind === 'comp'
            ? { compId: Number(el.dataset.compId), sectionId }
            : { tcomp: 'D', compId: Number(el.dataset.formId), sectionId };
        el.className = 'gfm-item is-pending';
        el.innerHTML = '<span class="spinner-border spinner-border-sm"></span><span class="ms-2">Création…</span>';

        await this.mutate(async () => {
            const res = await api.createItem(this.formId, body);
            el.dataset.id = res.id;
            this.selection = `item:${res.id}`;
            return api.layout(this.formId, this.readLayout());
        }, { props: true });
        this.$props.querySelector('[data-field=lib]')?.select();
    }

    async onSectionAdd(evt) {
        const rank = evt.newIndex + 1;
        evt.item.remove();
        const name = await promptDialog('Nouvelle section', 'Nom de la section', 'Nouvelle section');
        if (!name) { this.renderCanvas(); return; }
        await this.mutate(async () => {
            const res = await api.createSection(this.formId, { name, rank });
            this.selection = `section:${res.id}`;
            return res.form;
        }, { props: true });
    }

    async onTrash(evt) {
        const el = evt.item;
        el.remove();
        if (el.classList.contains('gfm-item') && el.dataset.id) {
            await this.deleteItem(Number(el.dataset.id));
        } else if (el.classList.contains('gfm-section') && el.dataset.id) {
            await this.deleteSection(Number(el.dataset.id));
        } else {
            this.renderCanvas();                            // palette element: nothing to do
        }
    }

    // ---------------------------------------------------------- width resize

    startResize(e) {
        e.preventDefault();
        e.stopPropagation();
        const handle = e.currentTarget;
        const tile = handle.closest('.gfm-item');
        const item = this.form.items.find((i) => i.id === Number(tile.dataset.id));
        const grid = tile.parentElement;
        const unit = (grid.clientWidth + GRID_GAP) / 12;      // one grid column + gap
        const startX = e.clientX;
        const startWidth = tile.getBoundingClientRect().width;
        const start = item.newRow === 'N' ? 'auto' : '1';
        let span = gridSpan(item);

        handle.setPointerCapture(e.pointerId);
        tile.classList.add('is-resizing');
        const tip = html(`<span class="resize-tip"></span>`);
        tile.append(tip);
        const show = () => { tip.textContent = `${span / 2}/6`; };
        show();

        const move = (ev) => {
            const width = startWidth + (ev.clientX - startX);
            const next = Math.min(12, Math.max(2, Math.round((width + GRID_GAP) / unit / 2) * 2));
            if (next !== span) {
                span = next;
                tile.style.gridColumn = `${start} / span ${span}`;
                show();
            }
        };
        const up = () => {
            handle.removeEventListener('pointermove', move);
            handle.removeEventListener('pointerup', up);
            handle.removeEventListener('pointercancel', up);
            tile.classList.remove('is-resizing');
            tip.remove();
            const colSpan = span / 2;
            if (colSpan !== item.colSpan && !(item.colSpan == null && span === gridSpan({ ...item, colSpan: null }))) {
                this.selection = `item:${item.id}`;
                this.mutate(() => api.updateItem(item.id, { colSpan }), { props: true });
            }
        };
        handle.addEventListener('pointermove', move);
        handle.addEventListener('pointerup', up);
        handle.addEventListener('pointercancel', up);
    }

    // ------------------------------------------------------------- keyboard

    /** Keyboard alternative to drag & drop: Alt+arrows move, Delete removes. */
    onCanvasKey(e) {
        const tile = e.target.closest('.gfm-item[data-id]');
        if (e.key === 'Enter' && e.target.dataset.select) {
            this.select(e.target.dataset.select);
            return;
        }
        if (!tile) return;
        if (e.key === 'Delete') {
            e.preventDefault();
            this.deleteItem(Number(tile.dataset.id));
        } else if (e.altKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
            e.preventDefault();
            const sibling = e.key === 'ArrowUp' ? tile.previousElementSibling : tile.nextElementSibling;
            if (!sibling) return;
            if (e.key === 'ArrowUp') sibling.before(tile); else sibling.after(tile);
            const id = tile.dataset.id;
            this.saveLayout().then(() => this.$canvas.querySelector(`.gfm-item[data-id="${id}"]`)?.focus());
        }
    }

    // --------------------------------------------------------------- actions

    updateForm(patch) {
        return this.mutate(() => api.updateForm(this.formId, patch));
    }

    savePrefs(prefs) {
        return this.mutate(() => api.prefs(this.formId, prefs));
    }

    updateSection(id, patch) {
        return this.mutate(() => api.updateSection(id, patch));
    }

    updateItem(id, patch, { props = false } = {}) {
        return this.mutate(() => api.updateItem(id, patch), { props });
    }

    async deleteItem(id) {
        const item = this.form.items.find((i) => i.id === id);
        if (!item) return;
        const deps = this.form.items.filter((i) => i.masterId === id).length;
        const msg = `Supprimer le champ « ${item.lib} » ?`
            + (deps ? ` ${deps} champ(s) en dépendent et redeviendront toujours visibles.` : '')
            + (item.mapId ? ' Les valeurs déjà saisies pour ce champ ne seront plus accessibles.' : '');
        if (!await confirmDialog(msg, { title: 'Supprimer le champ', okLabel: 'Supprimer', danger: true })) {
            this.renderCanvas();
            return;
        }
        if (this.selection === `item:${id}`) this.selection = 'form';
        await this.mutate(() => api.deleteItem(id), { props: true, message: 'Champ supprimé' });
    }

    async deleteSection(id) {
        const section = this.form.sections.find((s) => s.id === id);
        if (!section) return;
        const n = this.form.items.filter((i) => i.sectionId === id).length;
        const msg = `Supprimer la section « ${section.name} » ?` + (n ? ` Ses ${n} champ(s) passeront en tête de formulaire.` : '');
        if (!await confirmDialog(msg, { title: 'Supprimer la section', okLabel: 'Supprimer', danger: true })) {
            this.renderCanvas();
            return;
        }
        if (this.selection === `section:${id}`) this.selection = 'form';
        await this.mutate(() => api.deleteSection(id), { props: true, message: 'Section supprimée' });
    }

    async generate() {
        // same rule as the server: refused before any call, first item selected
        const problems = this.form.items.filter((i) => itemProblem(i));
        if (problems.length) {
            toast(`Listes sans valeur : ${problems.map((i) => `« ${i.lib} »`).join(', ')}. Ajoutez au moins une valeur avant de générer.`, 'danger');
            this.select(`item:${problems[0].id}`);
            this.$canvas.querySelector(`.gfm-item[data-id="${problems[0].id}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
            this.$props.querySelector('#p-newval')?.focus();
            return;
        }
        const btn = this.$toolbar.querySelector('[data-act=generate]');
        btn.disabled = true;
        btn.innerHTML = '<span class="spinner-border spinner-border-sm"></span><span class="d-none d-sm-inline ms-1">Génération…</span>';
        const res = await this.mutate(() => api.generate(this.formId), { message: (r) => r.message });
        if (!res) this.renderToolbar();
    }

    async copy() {
        try {
            const res = await api.copyForm(this.formId);
            toast(`Copie créée : ${res.form.lib}`);
        } catch (err) { showError(err); }
    }

    async resetData() {
        const n = this.form.dataCount;
        if (!await confirmDialog(`Supprimer les ${n} enregistrement(s) saisis et libérer les colonnes de stockage ? Il faudra régénérer le formulaire.`,
            { title: 'Réinitialiser les données', okLabel: 'Réinitialiser', danger: true })) return;
        await this.mutate(() => api.reset(this.formId), { props: true, message: 'Données réinitialisées' });
    }

    renderProps() {
        renderProps(this.$props, this);
    }

    destroy() {
        [...this.canvasSortables, ...this.paletteSortables].forEach((s) => s.destroy());
    }
}
