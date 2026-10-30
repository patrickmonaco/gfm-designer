// GFM Designer - entry point: authentication, routing (?form=<id>).
import * as auth from './auth.js';
import { api } from './api.js';
import { showError, esc } from './ui.js';
import { renderFormsList } from './forms.js';
import { Editor } from './editor.js';

const root = document.getElementById('app');
let editor = null;

function navigate(url) {
    history.pushState(null, '', url);
    route();
}

const openForm = (id) => navigate(`?form=${encodeURIComponent(id)}`);
const openList = () => navigate(location.pathname);

async function route() {
    editor?.destroy();
    editor = null;
    const formId = new URLSearchParams(location.search).get('form');
    document.body.classList.toggle('mode-editor', Boolean(formId));
    if (formId) {
        editor = new Editor(root, formId, { onBack: openList });
        await editor.open();
    } else {
        await renderFormsList(root, { openForm });
    }
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
    document.querySelector('[data-nav=list]').addEventListener('click', (e) => {
        e.preventDefault();
        openList();
    });
    window.addEventListener('popstate', route);

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
