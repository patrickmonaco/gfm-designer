// OAuth2 with ORDS.
//
// flow 'code' (default): authorization code flow. ORDS redirects back with
//   ?code=...&state=..., the code is exchanged for a token on the token
//   endpoint (client_id / client_secret, plus a PKCE code_verifier).
// flow 'implicit': token returned directly in the URL fragment; disabled on
//   recent ORDS releases.
//
// The token is kept in sessionStorage until it expires.
import config from './config.js';

const TOKEN_KEY = 'gfm.token';
const STATE_KEY = 'gfm.state';
const VERIFIER_KEY = 'gfm.verifier';
const RETURN_KEY = 'gfm.return';

function store(key, value) {
    try {
        if (value === null) sessionStorage.removeItem(key);
        else sessionStorage.setItem(key, value);
    } catch { /* storage unavailable: the user signs in again */ }
}

function read(key) {
    try { return sessionStorage.getItem(key); } catch { return null; }
}

const flow = () => config.auth?.flow || 'code';

export function enabled() {
    return config.auth?.mode === 'oauth';
}

function absolute(url, name) {
    try {
        return new URL(url, location.href);
    } catch {
        throw new Error(`auth.${name} invalide dans config.js : « ${url} »`);
    }
}

function saveToken(token, expiresIn) {
    const ttl = Number(expiresIn || 3600) * 1000;
    store(TOKEN_KEY, JSON.stringify({ token, exp: Date.now() + ttl - 30000 }));
}

/** Back to the page the user was on before signing in, without OAuth parameters. */
function restoreUrl() {
    const back = read(RETURN_KEY) || '';
    store(RETURN_KEY, null);
    store(STATE_KEY, null);
    store(VERIFIER_KEY, null);
    history.replaceState(null, '', location.pathname + back);
}

// PKCE (RFC 7636): random verifier, SHA-256 challenge, base64url
const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function newVerifier() {
    return b64url(crypto.getRandomValues(new Uint8Array(48)));
}

async function challenge(verifier) {
    return b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
}

/** Exchanges the authorization code for an access token. */
async function exchangeCode(code) {
    const body = new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: location.origin + location.pathname,
    });
    const verifier = read(VERIFIER_KEY);
    if (verifier) body.set('code_verifier', verifier);

    const headers = { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' };
    if (config.auth.clientSecret) {
        headers.Authorization = `Basic ${btoa(`${config.auth.clientId}:${config.auth.clientSecret}`)}`;
    } else {
        body.set('client_id', config.auth.clientId);
    }

    const res = await fetch(absolute(config.auth.tokenUrl, 'tokenUrl'), { method: 'POST', headers, body });
    const text = await res.text();
    let data = {};
    try { data = JSON.parse(text); } catch { /* not JSON */ }
    if (!res.ok || !data.access_token) {
        throw new Error(`Échec de l'échange du code OAuth (${res.status}) : ${data.error_description || data.error || text.slice(0, 200)}`);
    }
    saveToken(data.access_token, data.expires_in);
}

/**
 * Handles the return from ORDS, if any.
 * @returns {Promise<boolean>} true when the user can call the API
 */
export async function init() {
    if (!enabled()) return true;

    if (flow() === 'implicit') {
        const hash = new URLSearchParams(location.hash.slice(1));
        const token = hash.get('access_token');
        if (token) {
            const expected = read(STATE_KEY);
            if (expected && hash.get('state') === expected) saveToken(token, hash.get('expires_in'));
            restoreUrl();
        }
        return Boolean(getToken());
    }

    const query = new URLSearchParams(location.search);
    const code = query.get('code');
    const error = query.get('error');
    if (code || error) {
        const expected = read(STATE_KEY);
        try {
            if (error) throw new Error(`Connexion refusée par ORDS : ${query.get('error_description') || error}`);
            if (!expected || query.get('state') !== expected) throw new Error('Réponse OAuth inattendue (state invalide)');
            await exchangeCode(code);
        } finally {
            restoreUrl();
        }
    }
    return Boolean(getToken());
}

export function getToken() {
    if (!enabled()) return null;
    try {
        const t = JSON.parse(read(TOKEN_KEY));
        if (t && t.exp > Date.now()) return t.token;
    } catch { /* no token */ }
    return null;
}

/** Redirects to the ORDS sign-in page. */
export async function login() {
    const url = absolute(config.auth.authorizeUrl, 'authorizeUrl');
    const state = crypto.randomUUID();
    store(STATE_KEY, state);
    store(RETURN_KEY, location.search);

    url.searchParams.set('client_id', config.auth.clientId);
    url.searchParams.set('state', state);
    if (flow() === 'implicit') {
        url.searchParams.set('response_type', 'token');
    } else {
        const verifier = newVerifier();
        store(VERIFIER_KEY, verifier);
        url.searchParams.set('response_type', 'code');
        url.searchParams.set('code_challenge', await challenge(verifier));
        url.searchParams.set('code_challenge_method', 'S256');
    }
    location.assign(url.toString());
}

export function logout() {
    store(TOKEN_KEY, null);
    location.assign(location.pathname);
}
