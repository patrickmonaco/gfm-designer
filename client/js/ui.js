// Small UI helpers: HTML escaping, toasts, confirmation and input dialogs.
/* global bootstrap */

/** In-app navigation: changes the URL and lets the router display the view. */
export function navigate(url) {
    history.pushState(null, '', url);
    window.dispatchEvent(new PopStateEvent('popstate'));
}

export const esc = (value) => String(value ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export function html(markup) {
    const t = document.createElement('template');
    t.innerHTML = markup.trim();
    return t.content.firstElementChild;
}

export function toast(message, type = 'success') {
    const icon = { success: 'check-circle', danger: 'exclamation-triangle', info: 'info-circle' }[type] || 'info-circle';
    const el = html(`
        <div class="toast align-items-center text-bg-${type} border-0" role="status" aria-live="polite">
            <div class="d-flex">
                <div class="toast-body"><i class="bi bi-${icon} me-2"></i>${esc(message)}</div>
                <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast" aria-label="Fermer"></button>
            </div>
        </div>`);
    document.getElementById('toasts').append(el);
    const t = new bootstrap.Toast(el, { delay: type === 'danger' ? 8000 : 3000 });
    el.addEventListener('hidden.bs.toast', () => el.remove());
    t.show();
}

export function showError(err) {
    console.error(err);
    toast(err?.message || String(err), 'danger');
}

/** Generic modal; resolves with the value returned by onOk, or null. */
function modal({ title, body, okLabel = 'OK', okClass = 'btn-primary', onOk, focus }) {
    return new Promise((resolve) => {
        const el = html(`
            <div class="modal fade" tabindex="-1">
                <div class="modal-dialog modal-dialog-centered">
                    <form class="modal-content" novalidate>
                        <div class="modal-header">
                            <h2 class="modal-title fs-5">${esc(title)}</h2>
                            <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fermer"></button>
                        </div>
                        <div class="modal-body">${body}</div>
                        <div class="modal-footer">
                            <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Annuler</button>
                            <button type="submit" class="btn ${okClass}">${esc(okLabel)}</button>
                        </div>
                    </form>
                </div>
            </div>`);
        document.body.append(el);
        const m = new bootstrap.Modal(el);
        let result = null;
        el.querySelector('form').addEventListener('submit', (e) => {
            e.preventDefault();
            const value = onOk ? onOk(el) : true;
            if (value === undefined) return;         // invalid input: stay open
            result = value;
            m.hide();
        });
        el.addEventListener('shown.bs.modal', () => el.querySelector(focus || '[type=submit]')?.focus());
        el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(result); });
        m.show();
    });
}

export function confirmDialog(message, { title = 'Confirmation', okLabel = 'Confirmer', danger = false } = {}) {
    return modal({
        title,
        body: `<p class="mb-0">${esc(message)}</p>`,
        okLabel,
        okClass: danger ? 'btn-danger' : 'btn-primary',
    }).then((r) => r === true);
}

export function promptDialog(title, label, value = '') {
    return modal({
        title,
        body: `<label class="form-label" for="prompt-input">${esc(label)}</label>
               <input class="form-control" id="prompt-input" value="${esc(value)}" required maxlength="100">`,
        focus: '#prompt-input',
        onOk: (el) => {
            const input = el.querySelector('#prompt-input');
            const v = input.value.trim();
            if (!v) { input.classList.add('is-invalid'); return undefined; }
            return v;
        },
    });
}

/**
 * Form creation dialog: resolves {lib, notes, vtype, scope, authent, isPublished}
 * or null. types / scopes: FORM_TYPES / SCOPES of meta.js.
 */
export function newFormDialog(types, scopes) {
    return modal({
        title: 'Nouveau formulaire',
        okLabel: 'Créer',
        focus: '#nf-lib',
        body: `
            <div class="mb-3">
                <label class="form-label" for="nf-lib">Libellé</label>
                <input class="form-control" id="nf-lib" required maxlength="200" placeholder="Ex. Fiche logistique">
                <div class="invalid-feedback">Le libellé est obligatoire.</div>
            </div>
            <div class="mb-3">
                <label class="form-label" for="nf-notes">Description</label>
                <textarea class="form-control" id="nf-notes" rows="2" maxlength="1000"></textarea>
            </div>
            <fieldset class="mb-3">
                <legend class="form-label fs-6 mb-2">Type</legend>
                <div class="type-choices">
                    ${Object.entries(types).map(([code, t], n) => `
                        <input class="btn-check" type="radio" name="nf-vtype" id="nf-t-${code}" value="${code}" ${n === 0 ? 'checked' : ''}>
                        <label class="type-choice" for="nf-t-${code}">
                            <i class="bi ${t.icon}"></i>
                            <span class="fw-medium">${esc(t.label)}</span>
                            <span class="small text-body-secondary">${esc(t.help)}</span>
                        </label>`).join('')}
                </div>
            </fieldset>
            <div class="row g-3 align-items-end">
                <div class="col-sm-6">
                    <label class="form-label" for="nf-scope">Portée</label>
                    <select class="form-select" id="nf-scope">
                        ${Object.entries(scopes).map(([code, s]) => `<option value="${code}">${esc(s.label)}</option>`).join('')}
                    </select>
                </div>
                <div class="col-sm-6">
                    <div class="form-check form-switch mb-1">
                        <input class="form-check-input" type="checkbox" role="switch" id="nf-authent" checked>
                        <label class="form-check-label" for="nf-authent">Authentification requise</label>
                    </div>
                    <div class="form-check">
                        <input class="form-check-input" type="checkbox" id="nf-published">
                        <label class="form-check-label" for="nf-published">Publié</label>
                    </div>
                </div>
            </div>
            <p class="form-text mb-0 mt-2">La portée et la publication sont enregistrées ; leur effet sera mis en place prochainement.</p>`,
        onOk: (el) => {
            const lib = el.querySelector('#nf-lib');
            if (!lib.value.trim()) { lib.classList.add('is-invalid'); return undefined; }
            return {
                lib: lib.value.trim(),
                notes: el.querySelector('#nf-notes').value.trim() || null,
                vtype: el.querySelector('[name=nf-vtype]:checked').value,
                scope: el.querySelector('#nf-scope').value,
                authent: el.querySelector('#nf-authent').checked ? 'Y' : 'N',
                isPublished: el.querySelector('#nf-published').checked ? 'Y' : 'N',
            };
        },
    });
}

export function formatDate(iso) {
    if (!iso) return null;
    const d = new Date(iso);
    return Number.isNaN(d.getTime()) ? iso
        : d.toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' });
}
