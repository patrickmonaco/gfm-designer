--------------------------------------------------------------------------------
-- GFM Designer - OAuth2 client for the authorization code flow
--
-- Recent ORDS releases disable the implicit flow ("response_type=token
-- n'est pas autorisé"): the web client uses the authorization code flow.
--
-- Run as the schema that owns module gfm.designer, after 04_ords_security.sql
-- (privilege gfm.designer.priv must exist). Can be run again: an existing
-- client is kept.
--
-- Uses package OAUTH (same as 04). The ORDS_SECURITY signatures differ
-- between ORDS releases; see the query at the end to check yours.
--
-- Edit the variables below:
--   c_redirect_uri : URL of index.html of the web client
--------------------------------------------------------------------------------
set define off

declare
    c_name          constant varchar2(30)  := 'gfm_designer_web';
    c_redirect_uri  constant varchar2(500) := 'http://localhost:8080/index.html';
    c_support_email constant varchar2(200) := 'support@example.com';
    c_support_uri   constant varchar2(500) := 'http://localhost:8080/';
    l_count pls_integer;
begin
    select count(*) into l_count from user_ords_clients where name = c_name;
    if l_count = 0 then
        oauth.create_client(
            p_name            => c_name,
            p_grant_type      => 'authorization_code',
            p_owner           => 'GPM Factory',
            p_description     => 'Client web GFM Designer (authorization code)',
            p_redirect_uri    => c_redirect_uri,
            p_support_email   => c_support_email,
            p_support_uri     => c_support_uri,
            p_privilege_names => 'gfm.designer.priv' );
        commit;
    end if;
end;
/

-- clientId and clientSecret for client/js/config.js
-- (if client_secret is empty, your ORDS no longer stores it in clear:
--  send the result of the query below)
select name, client_id, client_secret
  from user_ords_clients
 where name = 'gfm_designer_web';

-- Signatures of ORDS_SECURITY in your ORDS release
-- select object_name, overload, position, argument_name, data_type, type_name
--   from all_arguments
--  where package_name = 'ORDS_SECURITY'
--    and object_name in ('REGISTER_CLIENT', 'ROTATE_CLIENT_SECRET', 'REGISTER_CLIENT_SECRET')
--  order by object_name, overload, position;

-- The implicit client is no longer used:
-- begin oauth.delete_client('gfm_designer_spa'); commit; end;
-- /
