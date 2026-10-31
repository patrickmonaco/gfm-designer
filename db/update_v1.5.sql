-- GFM Designer - update 1.4 -> 1.5 (block type, scope, published flag)
-- Run as the schema owner (e.g. DEMO). No table, gfm_builder or ORDS change:
-- columns GFM_FORM.SCOPE and IS_PUBLISHED already exist.
@01_gfm_api.pks
@02_gfm_api.pkb
show errors package body gfm_api
