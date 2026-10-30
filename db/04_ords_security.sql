--------------------------------------------------------------------------------
-- GFM Designer - ORDS security (OAuth2)
--
-- Run as the schema that owns module gfm.designer, after 03_ords_module.sql.
--
-- 1. Role gfm_designer + privilege gfm.designer.priv protecting the whole
--    module: every call without a valid token gets 401.
-- 2. OAuth2 client "gfm_designer_spa", implicit flow. Recent ORDS releases
--    disable this flow: the web client then uses gfm_designer_web
--    (authorization code), created by 05_ords_client_code.sql.
--    Former description:
--    the browser is redirected to ORDS, the user signs in, ORDS redirects
--    back to the client with the token in the URL fragment.
-- 3. OAuth2 client "gfm_designer_cli", client credentials, for tests
--    (curl, Postman, scripts). Do not use its secret in the browser.
--
-- Users of the implicit flow: ORDS signs them in with its own user
-- repository; when ORDS is configured with APEX, APEX workspace users can be
-- used: the user must belong to an APEX user group named like the role
-- (gfm_designer). Check the authentication setup of your ORDS installation.
--
-- Edit the variables below (redirect URI = URL of index.html of the client).
-- The script can be run again: existing role and clients are kept. To change
-- the redirect URI of an existing client, delete it first
-- (oauth.delete_client('gfm_designer_spa')) and update client_id in config.js.
--
-- Note: package OAUTH is deprecated in recent ORDS releases in favour of
-- ORDS_SECURITY, but still available. Adapt if your ORDS has removed it.
--------------------------------------------------------------------------------
set define off

declare
    c_role          constant varchar2(30)  := 'gfm_designer';
    c_privilege     constant varchar2(30)  := 'gfm.designer.priv';
    c_redirect_uri  constant varchar2(500) := 'http://localhost:8080/index.html';
    c_support_email constant varchar2(200) := 'support@example.com';
    c_support_uri   constant varchar2(500) := 'http://localhost:8080/';

    l_roles    owa.vc_arr;
    l_patterns owa.vc_arr;
    l_modules  owa.vc_arr;
    l_count    pls_integer;

    function client_exists (p_name in varchar2) return boolean is
        l_n pls_integer;
    begin
        select count(*) into l_n from user_ords_clients where name = p_name;
        return l_n > 0;
    end client_exists;
begin
    -- Script can be run again: existing role and clients are kept
    -- (their client_id stays the same).

    -- Role and privilege ----------------------------------------------------
    select count(*) into l_count from user_ords_roles where name = c_role;
    if l_count = 0 then
        ords.create_role(p_role_name => c_role);
    end if;

    l_roles(1)   := c_role;
    l_modules(1) := 'gfm.designer';
    ords.define_privilege(                       -- creates or replaces
        p_privilege_name => c_privilege,
        p_roles          => l_roles,
        p_patterns       => l_patterns,
        p_modules        => l_modules,
        p_label          => 'GFM Designer',
        p_description    => 'Conception des formulaires GFM',
        p_comments       => null );

    -- Web client: implicit flow ---------------------------------------------
    if not client_exists('gfm_designer_spa') then
        oauth.create_client(
            p_name            => 'gfm_designer_spa',
            p_grant_type      => 'implicit',
            p_owner           => 'GPM Factory',
            p_description     => 'Client web GFM Designer',
            p_redirect_uri    => c_redirect_uri,
            p_support_email   => c_support_email,
            p_support_uri     => c_support_uri,
            p_privilege_names => c_privilege );
    end if;

    -- Test client: client credentials ---------------------------------------
    if not client_exists('gfm_designer_cli') then
        oauth.create_client(
            p_name            => 'gfm_designer_cli',
            p_grant_type      => 'client_credentials',
            p_owner           => 'GPM Factory',
            p_description     => 'Tests de l''API GFM Designer',
            p_support_email   => c_support_email,
            p_privilege_names => c_privilege );
        oauth.grant_client_role(p_client_name => 'gfm_designer_cli', p_role_name => c_role);
    end if;

    commit;
end;
/

-- client_id of the web client: copy it into client/js/config.js
-- client_id / client_secret of the test client: for curl
select name, client_id, client_secret
  from user_ords_clients
 where name like 'gfm_designer%';

/*
-- Test with the client credentials client:
curl -s -u <client_id>:<client_secret> --data "grant_type=client_credentials" \
     https://<host>/ords/<schema>/oauth/token
curl -s -H "Authorization: Bearer <access_token>" \
     https://<host>/ords/<schema>/gfm/v1/forms
*/
