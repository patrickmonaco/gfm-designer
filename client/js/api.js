// REST client of ORDS module gfm.designer.
import config from './config.js';
import * as auth from './auth.js';

export class ApiError extends Error {
    constructor(message, status) {
        super(message);
        this.status = status;
    }
}

async function request(method, path, body) {
    const headers = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const token = auth.getToken();
    if (token) headers.Authorization = `Bearer ${token}`;

    let res;
    try {
        res = await fetch(config.apiBase + path, {
            method,
            headers,
            body: body === undefined ? undefined : JSON.stringify(body),
        });
    } catch {
        throw new ApiError('Serveur injoignable', 0);
    }

    if (res.status === 401 && auth.enabled()) {
        auth.login().catch(() => { /* configuration error shown by the login screen */ });
        throw new ApiError('Session expirée, reconnexion…', 401);
    }

    const text = await res.text();
    let data = null;
    if (text) {
        try { data = JSON.parse(text); } catch { data = { error: text.slice(0, 300) }; }
    }
    if (!res.ok) {
        throw new ApiError(data?.error || data?.message || `Erreur HTTP ${res.status}`, res.status);
    }
    return data;
}

const enc = encodeURIComponent;

export const api = {
    info: () => request('GET', '/info'),

    forms: () => request('GET', '/forms'),
    form: (id) => request('GET', `/forms/${enc(id)}`),
    createForm: (body) => request('POST', '/forms', body),
    updateForm: (id, body) => request('PUT', `/forms/${enc(id)}`, body),
    deleteForm: (id, force = false) => request('DELETE', `/forms/${enc(id)}${force ? '?force=Y' : ''}`),
    copyForm: (id) => request('POST', `/forms/${enc(id)}/copy`, {}),
    generate: (id) => request('POST', `/forms/${enc(id)}/generate`, {}),
    reset: (id) => request('POST', `/forms/${enc(id)}/reset`, {}),
    layout: (id, body) => request('PUT', `/forms/${enc(id)}/layout`, body),
    prefs: (id, prefs) => request('PUT', `/forms/${enc(id)}/prefs`, { prefs }),

    createSection: (formId, body) => request('POST', `/forms/${enc(formId)}/sections`, body),
    updateSection: (id, body) => request('PUT', `/sections/${enc(id)}`, body),
    deleteSection: (id) => request('DELETE', `/sections/${enc(id)}`),

    createItem: (formId, body) => request('POST', `/forms/${enc(formId)}/items`, body),
    updateItem: (id, body) => request('PUT', `/items/${enc(id)}`, body),
    deleteItem: (id) => request('DELETE', `/items/${enc(id)}`),
    itemLov: (id) => request('GET', `/items/${enc(id)}/lov`),

    components: () => request('GET', '/components'),
    component: (id) => request('GET', `/components/${enc(id)}`),
    createComponent: (body) => request('POST', '/components', body),
    updateComponent: (id, body) => request('PUT', `/components/${enc(id)}`, body),
    deleteComponent: (id) => request('DELETE', `/components/${enc(id)}`),
    saveValues: (id, values) => request('PUT', `/components/${enc(id)}/values`, { values }),
    previewComponent: (id) => request('GET', `/components/${enc(id)}/preview`),
};
