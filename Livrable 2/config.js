// GFM Designer - client configuration. Adapt to your ORDS / APEX installation.
export default {
    // Base URL of ORDS module gfm.designer (no trailing slash)
    apiBase: 'https://<host>/ords/<schema>/gfm/v1',

    auth: {
        // 'oauth': OAuth2 with ORDS; 'none': no token (development)
        mode: 'oauth',
        // 'code': authorization code flow (default);
        // 'implicit': only if your ORDS still allows it
        flow: 'code',
        // client gfm_designer_web (see db/05_ords_client_code.sql)
        clientId: '<client_id>',
        // Visible to anyone who can load the page: the user must still sign in,
        // but keep this client dedicated to GFM Designer (see ARCHITECTURE.md)
        clientSecret: '<client_secret>',
        // ORDS OAuth endpoints of the schema
        authorizeUrl: 'https://<host>/ords/<schema>/oauth/auth',
        tokenUrl: 'https://<host>/ords/<schema>/oauth/token',
    },

    // URL of a generated APEX page; {app} and {page} are replaced
    apexPageUrl: 'https://<host>/ords/f?p={app}:{page}',
};
