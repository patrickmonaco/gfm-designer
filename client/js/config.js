// GFM Designer - client configuration. Adapt to your ORDS / APEX installation.
export default {
    // Base URL of ORDS module gfm.designer (no trailing slash)
    apiBase: 'https://xnb9864k2phluj7-db202006252027.adb.eu-frankfurt-1.oraclecloudapps.com/ords/demo/gfm/v1',

    auth: {
        // 'oauth': OAuth2 implicit flow with ORDS; 'none': no token (development)
        mode: 'oauth',
        flow: 'code',
       clientId: 'teZwr8jkfPXgi_Ohhymquw..',
       clientSecret: '_j3ObUNBzcriifSN6i6xew..',
        // client_id of OAuth client gfm_designer_spa (query on user_ords_clients)
        // ORDS authorization endpoint of the schema
        authorizeUrl: 'https://xnb9864k2phluj7-db202006252027.adb.eu-frankfurt-1.oraclecloudapps.com/ords/demo/oauth/auth',
        tokenUrl: 'https://xnb9864k2phluj7-db202006252027.adb.eu-frankfurt-1.oraclecloudapps.com/ords/demo/oauth/token',
        signInUrl: 'https://xnb9864k2phluj7-db202006252027.adb.eu-frankfurt-1.oraclecloudapps.com/ords/demo/sign-in/'
    },

    // URL of a generated APEX page; {app} and {page} are replaced
    apexPageUrl: 'https://xnb9864k2phluj7-db202006252027.adb.eu-frankfurt-1.oraclecloudapps.com/ords/f?p={app}:{page}',
};
