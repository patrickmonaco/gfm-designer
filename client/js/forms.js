// Forms list (home view).
import { api } from './api.js';
import { esc, html, showError, toast, confirmDialog, newFormDialog, formatDate } from './ui.js';

export async function renderFormsList(root, { openForm }) {
    root.innerHTML = `
        <div class="container-xl py-4">
            <div class="d-flex flex-wrap align-items-center gap-2 mb-4">
                <h1 class="h3 mb-0 me-auto">Formulaires</h1>
                <div class="input-group list-search">
                    <span class="input-group-text"><i class="bi bi-search"></i></span>
                    <input class="form-control" type="search" id="form-search" placeholder="Rechercher" aria-label="Rechercher un formulaire">
                </div>
                <button class="btn btn-primary" id="new-form" type="button"><i class="bi bi-plus-lg me-1"></i>Nouveau formulaire</button>
            </div>
            <div id="forms-grid" class="row row-cols-1 row-cols-md-2 row-cols-xl-3 g-3">
                <div class="col"><div class="placeholder-glow"><span class="placeholder col-12 form-card-placeholder"></span></div></div>
            </div>
        </div>`;

    const grid = root.querySelector('#forms-grid');
    let forms = [];

    const draw = () => {
        const q = root.querySelector('#form-search').value.trim().toLowerCase();
        const shown = forms.filter((f) => !q || `${f.lib} ${f.code} ${f.notes || ''}`.toLowerCase().includes(q));
        grid.innerHTML = '';
        if (!shown.length) {
            grid.append(html(`<div class="col-12"><div class="empty-state">
                <i class="bi bi-ui-checks-grid"></i>
                <p class="mb-0">${forms.length ? 'Aucun formulaire ne correspond à la recherche.' : 'Aucun formulaire pour l\'instant. Créez le premier.'}</p>
            </div></div>`));
            return;
        }
        for (const f of shown) grid.append(card(f));
    };

    const card = (f) => {
        const el = html(`
            <div class="col">
                <div class="card h-100 form-card">
                    <div class="card-body">
                        <div class="d-flex align-items-start gap-2 mb-2">
                            <h2 class="h5 card-title mb-0 me-auto text-break">
                                <a href="?form=${f.id}" class="stretched-link text-reset text-decoration-none" data-open>${esc(f.lib)}</a>
                            </h2>
                            <span class="badge ${f.vtype === 'D' ? 'text-bg-info' : 'text-bg-secondary'}">${f.vtype === 'D' ? 'Détail' : 'Maître'}</span>
                        </div>
                        <div class="font-monospace small text-body-secondary mb-2">${esc(f.code)}</div>
                        ${f.notes ? `<p class="card-text small text-body-secondary line-clamp-2">${esc(f.notes)}</p>` : ''}
                        <div class="d-flex flex-wrap gap-3 small text-body-secondary">
                            <span title="Champs"><i class="bi bi-input-cursor me-1"></i>${f.itemCount} champs</span>
                            <span title="Sections"><i class="bi bi-layout-split me-1"></i>${f.sectionCount} sections</span>
                            <span title="Enregistrements"><i class="bi bi-database me-1"></i>${f.dataCount}</span>
                        </div>
                    </div>
                    <div class="card-footer bg-transparent d-flex align-items-center small text-body-secondary">
                        <span class="me-auto">${f.pageId ? `Page ${f.pageId}` : 'Sans page'}${f.lastBuild ? ` · générée le ${esc(formatDate(f.lastBuild))}` : ' · jamais générée'}</span>
                        <div class="dropdown position-relative card-menu">
                            <button class="btn btn-sm btn-link text-body-secondary" type="button" data-bs-toggle="dropdown" aria-expanded="false" aria-label="Actions">
                                <i class="bi bi-three-dots-vertical"></i>
                            </button>
                            <ul class="dropdown-menu dropdown-menu-end">
                                <li><button class="dropdown-item" data-act="copy"><i class="bi bi-copy me-2"></i>Dupliquer</button></li>
                                <li><hr class="dropdown-divider"></li>
                                <li><button class="dropdown-item text-danger" data-act="delete"><i class="bi bi-trash3 me-2"></i>Supprimer</button></li>
                            </ul>
                        </div>
                    </div>
                </div>
            </div>`);
        el.querySelector('[data-open]').addEventListener('click', (e) => {
            e.preventDefault();
            openForm(f.id);
        });
        el.querySelector('[data-act=copy]').addEventListener('click', async () => {
            try {
                const res = await api.copyForm(f.id);
                toast(`Copie créée : ${res.form.lib}`);
                await load();
            } catch (err) { showError(err); }
        });
        el.querySelector('[data-act=delete]').addEventListener('click', () => remove(f));
        return el;
    };

    const remove = async (f) => {
        if (!await confirmDialog(`Supprimer le formulaire « ${f.lib} » ? La page APEX et la vue générées ne sont pas supprimées.`,
            { title: 'Supprimer le formulaire', okLabel: 'Supprimer', danger: true })) return;
        try {
            await api.deleteForm(f.id);
        } catch (err) {
            if (err.status !== 409 || !/enregistrement/.test(err.message)) { showError(err); return; }
            if (!await confirmDialog(err.message, { title: 'Données existantes', okLabel: 'Tout supprimer', danger: true })) return;
            try { await api.deleteForm(f.id, true); } catch (e2) { showError(e2); return; }
        }
        toast('Formulaire supprimé');
        await load();
    };

    const load = async () => {
        try {
            forms = await api.forms() || [];
            if (!grid.isConnected) return;          // the user went to another view
            draw();
        } catch (err) {
            grid.innerHTML = '';
            showError(err);
        }
    };

    root.querySelector('#form-search').addEventListener('input', draw);
    root.querySelector('#new-form').addEventListener('click', async () => {
        const data = await newFormDialog();
        if (!data) return;
        try {
            const res = await api.createForm(data);
            openForm(res.id);
        } catch (err) { showError(err); }
    });

    await load();
}
