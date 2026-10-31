// Font APEX icon picker (icons of the Universal Theme).
/* global bootstrap */
import { esc, html } from './ui.js';

const CATEGORY_LABELS = {
    RECENTLY_ADDED: 'Ajouts récents',
    ACCESSIBILITY: 'Accessibilité',
    CALENDAR: 'Calendrier',
    CHART: 'Graphiques',
    CURRENCY: 'Devises',
    DIRECTIONAL: 'Flèches',
    EMOJI: 'Émoticônes',
    FILE_TYPE: 'Fichiers',
    FORM_CONTROL: 'Formulaires',
    GENDER: 'Genre',
    HAND: 'Mains',
    MEDICAL: 'Médical',
    NUMBERS: 'Nombres',
    PAYMENT: 'Paiement',
    SPINNER: 'Animations',
    TEXT_EDITOR: 'Éditeur de texte',
    TRANSPORTATION: 'Transport',
    VIDEO_PLAYER: 'Vidéo',
    WEB_APPLICATION: 'Application web',
};

let catalogue = null;     // {categories: [[code, label, [{name, keywords}]]], all: [...]}

async function loadCatalogue() {
    if (catalogue) return catalogue;
    const { default: data } = await import('./font-apex-icons.js');
    const byName = new Map();
    const categories = Object.entries(data).map(([code, list]) => {
        const icons = list.map(([name, keywords = '']) => {
            const icon = byName.get(name) || { name, keywords: '' };
            icon.keywords = [icon.keywords, keywords].filter(Boolean).join(',');
            byName.set(name, icon);
            return icon;
        });
        return [code, CATEGORY_LABELS[code] || code, icons];
    });
    const all = [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
    catalogue = { categories, all };
    return catalogue;
}

/**
 * Opens the picker. Resolves with the chosen class (e.g. "fa-user"),
 * '' to remove the icon, or null when cancelled.
 */
export function pickIcon(current = '') {
    return new Promise((resolve) => {
        const el = html(`
            <div class="modal fade icon-picker" tabindex="-1">
                <div class="modal-dialog modal-lg modal-dialog-centered modal-dialog-scrollable">
                    <div class="modal-content">
                        <div class="modal-header flex-wrap gap-2">
                            <h2 class="modal-title fs-5 me-auto">Choisir une icône</h2>
                            <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fermer"></button>
                            <div class="d-flex gap-2 w-100">
                                <input class="form-control" type="search" data-role="search" placeholder="Rechercher (nom ou mot-clé, en anglais)" aria-label="Rechercher une icône">
                                <select class="form-select icon-cat" data-role="category" aria-label="Catégorie">
                                    <option value="">Toutes les catégories</option>
                                </select>
                            </div>
                        </div>
                        <div class="modal-body">
                            <div class="icon-grid" role="listbox" aria-label="Icônes"><span class="spinner-border"></span></div>
                        </div>
                        <div class="modal-footer">
                            <span class="small text-body-secondary me-auto" data-role="count"></span>
                            <button type="button" class="btn btn-outline-secondary" data-role="none">Aucune icône</button>
                            <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Annuler</button>
                        </div>
                    </div>
                </div>
            </div>`);
        document.body.append(el);
        const modal = new bootstrap.Modal(el);
        const grid = el.querySelector('.icon-grid');
        const search = el.querySelector('[data-role=search]');
        const category = el.querySelector('[data-role=category]');
        const count = el.querySelector('[data-role=count]');
        let result = null;

        const choose = (value) => { result = value; modal.hide(); };

        const draw = () => {
            if (!catalogue) return;
            const q = search.value.trim().toLowerCase().replace(/^fa-/, '');
            const source = category.value
                ? catalogue.categories.find(([code]) => code === category.value)[2]
                : catalogue.all;
            const icons = q
                ? source.filter((i) => i.name.includes(q) || i.keywords.toLowerCase().includes(q))
                : source;
            count.textContent = `${icons.length} icône(s)`;
            grid.innerHTML = icons.length ? icons.map((i) => `
                <button type="button" class="icon-tile${i.name === current ? ' is-current' : ''}" data-name="${esc(i.name)}"
                        role="option" aria-selected="${i.name === current}" title="${esc(i.name)}${i.keywords ? ` (${esc(i.keywords)})` : ''}">
                    <span class="fa ${esc(i.name)}" aria-hidden="true"></span>
                    <span class="icon-name">${esc(i.name.replace(/^fa-/, ''))}</span>
                </button>`).join('')
                : '<p class="text-body-secondary text-center my-4">Aucune icône ne correspond.</p>';
        };

        grid.addEventListener('click', (e) => {
            const tile = e.target.closest('[data-name]');
            if (tile) choose(tile.dataset.name);
        });
        search.addEventListener('input', draw);
        category.addEventListener('change', draw);
        el.querySelector('[data-role=none]').addEventListener('click', () => choose(''));
        el.addEventListener('shown.bs.modal', () => {
            search.focus();
            el.querySelector('.is-current')?.scrollIntoView({ block: 'center' });
        });
        el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(result); });

        loadCatalogue().then((c) => {
            category.insertAdjacentHTML('beforeend', c.categories
                .map(([code, label, icons]) => `<option value="${code}">${esc(label)} (${icons.length})</option>`).join(''));
            draw();
            el.querySelector('.is-current')?.scrollIntoView({ block: 'center' });
        }).catch(() => {
            grid.innerHTML = '<p class="text-danger">Liste des icônes indisponible.</p>';
        });
        modal.show();
    });
}

/**
 * Icon input: preview + text field + "Choisir" button.
 * The field keeps its data-field attribute: it is saved by the usual change handler.
 */
export function iconInput(id, value, { field = 'icon', placeholder = '' } = {}) {
    return `
        <div class="input-group icon-input">
            <span class="input-group-text icon-preview" aria-hidden="true"><span class="fa ${esc(value || placeholder || 'fa-question-circle-o')}${value ? '' : ' opacity-50'}"></span></span>
            <input class="form-control" id="${id}" data-field="${field}" value="${esc(value)}" maxlength="100" placeholder="${esc(placeholder)}">
            <button class="btn btn-outline-secondary" type="button" data-pick-icon="${id}"><i class="bi bi-grid-3x3-gap me-1"></i>Choisir</button>
        </div>`;
}

/** Wires the icon inputs of a container: picker button and live preview. */
export function bindIconInputs(container) {
    container.querySelectorAll('[data-pick-icon]').forEach((btn) => {
        const input = container.querySelector(`#${CSS.escape(btn.dataset.pickIcon)}`);
        const preview = btn.closest('.icon-input').querySelector('.icon-preview .fa');
        const refresh = () => {
            const v = input.value.trim();
            preview.className = `fa ${v || input.placeholder || 'fa-question-circle-o'}${v ? '' : ' opacity-50'}`;
        };
        input.addEventListener('input', refresh);
        btn.addEventListener('click', async () => {
            const picked = await pickIcon(input.value.trim());
            if (picked === null || picked === input.value.trim()) return;
            input.value = picked;
            refresh();
            input.dispatchEvent(new Event('change', { bubbles: true }));
        });
    });
}
