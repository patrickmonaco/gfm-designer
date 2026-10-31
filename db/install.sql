-- GFM Designer - installation (SQLcl / SQL*Plus, UTF-8 client)
--   sql demo/<password>@<db> @install.sql
-- gfm_builder (v2.6) is included: skip it if already up to date.
whenever sqlerror exit failure rollback
@06_lov_order.sql
@07_report_page.sql
@08_typed_columns.sql
@00_gfm_builder.pks
@00_gfm_builder.pkb
@01_gfm_api.pks
@02_gfm_api.pkb
show errors package body gfm_api
@03_ords_module.sql
@04_ords_security.sql
@05_ords_client_code.sql
