// GFM Designer - entry point: authentication, routing.
//   ./                        forms list
//   ?form=<id>                form editor
//   ?view=components[&comp=n] components and lists of values
import * as auth from './auth.js';
import { api } from './api.js';
import { showError, esc } from './ui.js';
import { renderFormsList } from './forms.js';
import { Editor } from './editor.js';
import { ComponentsView } from './components.js';

const root = document.getElementById('app');
let current = null;        // view with destroy() / canLeave()

function navigate(url) {
    history.pushState(null, '', url);
    route();
}

const openForm = (id) => navigate(`?form=${encodeURIComponent(id)}`);
const openList = () => navigate(location.pathname);

async function route() {
    current?.destroy?.();
    current = null;
    const params = new URLSearchParams(location.search);
    const formId = params.get('form');
    const view = formId ? 'editor' : params.get('view') === 'components' ? 'components' : 'forms';

    document.body.classList.toggle('mode-editor', view === 'editor');
    document.querySelectorAll('.app-nav [data-nav]').forEach((a) => {
        const active = a.dataset.nav === view || (a.dataset.nav === 'forms' && view === 'editor');
        a.classList.toggle('active', active);
        if (active) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });

    if (view === 'editor') {
        current = new Editor(root, formId, { onBack: openList });
        await current.open();
    } else if (view === 'components') {
        current = new ComponentsView(root, params.get('comp'));
        await current.open();
    } else {
        await renderFormsList(root, { openForm });
    }
}

/** Navigation links of the navbar, with confirmation of unsaved changes. */
function bindNav() {
    document.querySelectorAll('[data-nav]').forEach((a) => {
        a.addEventListener('click', async (e) => {
            e.preventDefault();
            if (current?.canLeave && !await current.canLeave()) return;
            if (current) current.dirty = false;
            navigate(a.dataset.nav === 'components' ? '?view=components' : location.pathname);
        });
    });
}

function loginScreen() {
    root.innerHTML = `
        <div class="login-screen">
            <div class="card shadow-sm">
                <div class="card-body p-4 text-center">
                    <span class="brand-mark brand-mark-lg mb-3"><i class="bi bi-ui-checks-grid"></i></span>
                    <h1 class="h4">GFM Designer</h1>
                    <p class="text-body-secondary">Concevez vos formulaires APEX par glisser-déposer.</p>
                    <button class="btn btn-primary w-100" type="button" id="login">
                        <i class="bi bi-box-arrow-in-right me-1"></i>Se connecter
                    </button>
                </div>
            </div>
        </div>`;
    root.querySelector('#login').addEventListener('click', () => {
        auth.login().catch(showError);
    });
}

async function start() {

    let signedIn = false;
    try {
        signedIn = await auth.init();
    } catch (err) {
        showError(err);
    }
    if (!signedIn) {
        loginScreen();
        return;
    }

    // navigation only once signed in
    document.querySelector('.app-nav').classList.remove('d-none');
    bindNav();
    window.addEventListener('popstate', route);
    if (auth.enabled()) {
        const btn = document.getElementById('logout');
        btn.classList.remove('d-none');
        btn.addEventListener('click', () => auth.logout());
    }

    api.info()
        .then((info) => {
            if (info?.user) document.getElementById('user').innerHTML = `<i class="bi bi-person-circle me-1"></i>${esc(info.user)}`;
        })
        .catch(() => { /* displayed by the first real call */ });

    try {
        await route();
    } catch (err) {
        showError(err);
    }
}

start();
