# GFM Builder — générateur de pages formulaire APEX

Package PL/SQL `GFM_BUILDER` (GPM Factory, P. Monaco) — v2.1, octobre 2026, pour APEX 26.1.

## 1. Objet

Un utilisateur non développeur décrit un formulaire dans une application APEX « designer » : champs, sections, listes de valeurs, champs dépendants, sous-formulaires en grille. Ces métadonnées sont stockées dans les tables `GFM_*`.

`GFM_BUILDER` les exploite pour :

1. **générer la structure de données** : une vue typée `G$_<CODE>` posée sur la table générique `GFM_DATA` ;
2. **générer la page APEX** dans une application existante, composant par composant, exactement comme le ferait un import d'export SQL.

## 2. Principe de stockage

Toutes les données saisies vont dans une seule table `GFM_DATA`, sur le modèle des collections APEX :

| Colonne `GFM_DATA` | Rôle |
|---|---|
| `SEQ_ID` | clé primaire (séquence `GFM_DATA_SEQ`) |
| `FORM_ID` | formulaire propriétaire de la ligne |
| `COLLECTION_NAME` | code du formulaire |
| `C001 … Cnnn` | « slots » texte, un par champ (`GFM_ITEMS.MAP_ID` = numéro du slot) |
| `N001` | lien vers la ligne maître (`PARENT_ID`) pour un formulaire de détail |

`generate_ddl` crée pour chaque formulaire :

- la vue `G$_<CODE>` (`SEQ_ID`, une colonne par code de champ, `[PARENT_ID]`, `FORM_ID`) ;
- une clé primaire désactivée sur `SEQ_ID`, nécessaire à la région formulaire APEX ;
- un trigger `INSTEAD OF INSERT` `G$_<CODE>_TRG`. Les `UPDATE` et `DELETE` passent directement par la vue ;
- les UI defaults APEX (libellés, aides).

Un slot attribué à un champ (`MAP_ID`) n'est jamais réutilisé, sauf après `reset_form`. `GFM_FORM.MAP_LASTID` mémorise le dernier slot attribué.

## 3. Modèle de métadonnées (utilisé par le package)

| Table / objet | Colonnes exploitées |
|---|---|
| `GFM_SETUP_V` | `PARAMETER`, `VALEUR` — paramètre `APP_RUN_ID` = application cible |
| `GFM_FORM` | `ID`, `LIB`, `CODE`, `NOTES`, `PAGE_ID`, `AUTHENT`, `SECTIONS` (legacy), `MAP_LASTID`, `LAST_UPDATED_ON`, `IS_*`… |
| `GFM_FORM_PREFS` | `FORM_ID`, `PREF`, `VAL` |
| `GFM_SECTIONS` | `ID`, `FORM_ID`, `SECTION_NAME`, `RANK` |
| `GFM_ITEMS` | `ID`, `FORM_ID`, `CODE`, `LIB`, `DESCRIPTION`, `COMP`, `TCOMP`, `VTYPE`, `LOV`, `SECTION_ID`, `SECTION` (legacy), `SEQ`, `NEW_ROW`, `COL_SPAN`, `MANDATORY`, `ICON`, `MASTER_ID`, `MASTER_VALUE`, `MAP_ID` |
| `GFM_COMP` | `ID`, `LIB`, `CTYPE`, `ICON`, `OBJ_SOURCE`, `INTERNAL` |
| `GFM_LOV` | `COMP_ID`, `LIB_VALUE`, `C_VALUE`, `IS_DEFAULT` |
| Séquences | `GFM_PAGE_SEQ` (pages), `GFM_DATA_SEQ` (lignes de données) |

**`GFM_ITEMS.TCOMP`**
- `C` : champ ordinaire, qui devient une colonne de la vue et un item de page ;
- `D` : sous-formulaire. Dans ce cas, `COMP` contient l'id d'un **formulaire** et non d'un composant, et le sous-formulaire est affiché sous forme d'Interactive Grid.

**`GFM_COMP.CTYPE`** — type de champ

| Code | Item APEX généré |
|---|---|
| `CT` | Text Field |
| `CN` | Textarea (3 lignes) |
| `NB` | Number Field |
| `DA` | Date Picker |
| `LI` | liste statique (valeurs dans `GFM_LOV`, ou liste « Inline List » saisie dans `GFM_ITEMS.LOV` sous la forme `a:b:c`) |
| `DL` | liste dynamique sur la vue `GFM_COMP.OBJ_SOURCE` (colonnes `D`, `R`) |

**`GFM_ITEMS.VTYPE`** — affichage des listes : `RADIO`, `LIST`, `CHECKBOX`, `NATIVE_SINGLE_CHECKBOX`, `POPUP`.

**Champs dépendants** : un champ qui a un `MASTER_ID` est masqué au chargement de la page. Il apparaît quand le champ maître vaut `MASTER_VALUE`, ou dès que le maître est renseigné si `MASTER_VALUE` est vide.

## 4. Préférences de formulaire (`GFM_FORM_PREFS`)

| Préférence | Valeurs | Défaut |
|---|---|---|
| `$ITEM_TEMPLATE` | `FLOATING`, `ABOVE`, `BESIDE` | `FLOATING` |
| `$REGION_SECTION` | `TABS_CONTAINER`, `DISPLAY_SELECTOR`, `STANDARD` | `TABS_CONTAINER` |
| `$ITEM_HELP` | `Y` / `N` — description du champ utilisée comme aide | `N` |
| `$PAGE_TEMPLATE` | nom interne d'un template de page | `STANDARD` |

`init_prefs` initialise ces préférences à partir des composants internes `$…` de `GFM_COMP`, avec la valeur par défaut `GFM_LOV.IS_DEFAULT = 'Y'`.

## 5. Page générée

| Composant | Détail |
|---|---|
| Page | nom et titre = `GFM_FORM.LIB` ; publique si `AUTHENT <> 'Y'` |
| Région principale | Form natif sur `G$_<CODE>` |
| Sections | une région par section utilisée (ordre `RANK`). Avec plus d'une section, elles sont regroupées dans un Tabs Container ou pilotées par un Display Selector, selon `$REGION_SECTION` |
| Items techniques | `P<n>_SEQ_ID` (clé, défaut `GFM_DATA_SEQ.nextval`), `P<n>_UPD_ID` (non nul = mode modification) |
| Items | un par champ `TCOMP = 'C'`, dans la région de sa section |
| Boutons | `CANCEL` (ferme la fenêtre), `DELETE`, `SAVE` (modification), `CREATE` (création) |
| Branches | vers la page 20 après traitement et après suppression |
| Processus | copie `SEQ_ID → UPD_ID`, Form Init, Form DML |
| Actions dynamiques | masquage et affichage des champs dépendants |
| Grilles | une Interactive Grid par sous-formulaire (`TCOMP = 'D'`), filtrée sur `PARENT_ID = :P<n>_SEQ_ID`, avec son processus IG DML |

## 6. API publique

| Sous-programme | Rôle | Retour |
|---|---|---|
| `generate_form(fid, pid)` | (re)génère la page. **La page existante est supprimée** : toute modification manuelle est perdue | `0`, ou exception `ORA-20201` |
| `generate_ddl(fid, ptype)` | vue, trigger et UI defaults. `ptype = 'D'` pour un sous-formulaire | exception `ORA-20300` |
| `get_lov(id)` | SQL de la LOV d'un champ, appelée à l'exécution par les pages générées | requête |
| `get_lov(plov)` | SQL d'une liste `GFM_LOV` désignée par le libellé de son composant | requête |
| `get_lov_master(id)` | SQL d'une liste `GFM_LOV` désignée par l'id de son composant | requête |
| `getNewPageid(fid)` | 1er numéro de page libre entre 101 et 400. ⚠ `fid` est un **id d'application** | id ou `null` |
| `copyForm(fid, appid)` | duplique formulaire, sections et champs | nouvel id, ou `-1` |
| `copyItems(fid, tid)` | copie les champs d'un formulaire vers un autre | `0` / `-1` |
| `reseq(pid, plist)` | renumérote les champs (10, 20…) selon la liste d'ids `'12:7:9'`. ⚠ `pid` est un **id de formulaire** | `0` / `1` |
| `init_prefs(fid)` | crée les préférences manquantes | `0` |
| `reset_form(fid)` | supprime les données et libère les slots | `0` / `1` |

Séquence type pour un nouveau formulaire : `init_prefs` → `generate_ddl` (d'abord sur les sous-formulaires, avec `'D'`) → `generate_form`.

## 7. Prérequis et contexte d'exécution

- **Paramètre `APP_RUN_ID`** dans `GFM_SETUP` : l'application cible.
- **Templates Universal Theme** présents dans l'application cible, sous leurs noms internes : page `$PAGE_TEMPLATE` ; régions `STANDARD` et `TABS_CONTAINER` ; bouton `TEXT` ; labels `OPTIONAL`, `REQUIRED`, `OPTIONAL_ABOVE`, `REQUIRED_ABOVE`, `OPTIONAL_FLOATING`, `REQUIRED_FLOATING`. S'il en manque un, le package lève une erreur explicite.
- **Contexte workspace** : les API internes ont besoin du security group du workspace de l'application cible. C'est automatique quand l'appel part d'une session APEX du même workspace. Hors session (job, SQLcl), il faut le positionner avant l'appel, par exemple avec `apex_util.set_workspace`.
- **Privilèges** du schéma propriétaire : `CREATE VIEW` et `CREATE TRIGGER` reçus directement, pas via un rôle, puisque le package est en définisseur.
- **`GFM_DATA`** doit appartenir au même schéma que le package : la vérification des slots lit `USER_TAB_COLUMNS`.

### API APEX internes (non supportées)

- `wwv_flow_imp_page` : `remove_page`, `create_page`, `create_page_plug`, `create_page_button`, `create_page_branch`, `create_page_item`, `create_page_process`, `create_page_da_event`, `create_page_da_action`, `create_region_column`, `create_interactive_grid`, `create_ig_report`, `create_ig_report_view`, `create_ig_report_column` ;
- `wwv_flow_id.next_val` (identifiants des composants) ;
- `wwv_flow_t_plugin_attributes` (attributs nommés, fonction `attrs`).

Les appels sont regroupés dans la section 3 du corps et suivent la syntaxe des exports SQL 26.1, avec deux différences : les ids d'application et de page sont passés explicitement (`p_flow_id`, `p_page_id` / `p_flow_step_id`), car on n'ouvre pas de contexte `wwv_flow_imp.import_begin`, et les ids de composants ne passent pas par `wwv_flow_imp.id()` (pas d'offset). Pour adapter le package à une future version d'APEX, la méthode est la même : exporter une page générée au format SQL et comparer les appels.

`wwv_flow_api` n'est plus utilisé : en 26.1 ce n'est qu'une couche de compatibilité, et son `create_page_item` viole la contrainte `STEP_ITEM_SS_DATA_TYPE_CK`.

### Prérequis spécifiques à APEX 26.1

- **Thème** : les templates sont cherchés dans le thème courant de l'application cible. Une application migrée peut contenir plusieurs templates de même nom interne (copies, ancien thème non rafraîchi) : rafraîchir ou mettre à niveau le thème, ou passer l'id du template voulu dans la préférence (`$PAGE_TEMPLATE` accepte un id numérique).
- **Interface utilisateur** : celle qu'utilisent la majorité des pages de l'application.

## 8. Transactions et erreurs

| Code | Origine |
|---|---|
| `-20201` | `generate_form` — message `<étape> - <erreur>` |
| `-20202` | `APP_RUN_ID` absent (remonté via `-20201`) |
| `-20204` | métadonnées incohérentes : template absent, formulaire inconnu, type d'affichage non géré |
| `-20300` | `generate_ddl` — message `<vue>.<étape> - <erreur>` |

- `generate_form` travaille dans **une seule transaction** : commit à la fin, rollback complet en cas d'erreur, ce qui inclut la suppression de l'ancienne page.
- `generate_ddl` : chaque DDL valide implicitement la transaction.
- Les fonctions de maintenance gardent le contrat v1.x (codes retour `0` / `1` / `-1`). Elles font désormais un rollback et tracent l'erreur dans le debug APEX (`apex_debug.error`), avec l'étape et le backtrace.
- Chaque étape est tracée par `apex_debug.trace` : activez le debug de la session pour suivre une génération.

## 9. Journal des modifications

### v2.1 — passage natif à APEX 26.1

- Tous les appels passent par `wwv_flow_imp_page` au lieu de `wwv_flow_api`.
- Attributs des composants au format nommé des exports 26.1 (`p_attributes`) au lieu de `p_attribute_01..25`.
- **Bug corrigé : les dates n'étaient jamais enregistrées.** L'item date était créé sans `p_source_type`, donc `ALWAYS_NULL`. Il est maintenant lié à sa colonne (`REGION_SOURCE_COLUMN`).
- Date picker JET (retiré) remplacé par `NATIVE_DATE_PICKER_APEX`.
- Cases à cocher multiples : valeurs stockées séparées par `:` (`p_multi_value_type = SEPARATED`).
- Colonnes de grille : `p_session_state_data_type` renseigné, comme dans les exports 26.1.
- Grilles : le rapport principal et sa vue (`create_ig_report`, `create_ig_report_view`) sont créés explicitement si APEX ne les a pas créés avec la grille.
- Bouton `CANCEL` en `REDIRECT_URL` (forme produite par la migration 26.1).
- Container d'onglets : attributs corrigés (`expand_shortcuts = N`, `output_as = HTML`) ; la v1.x passait des valeurs décalées.
- `wwv_flow_string.join` remplacé par l'API publique `apex_string.join`.

### v2.0

Les signatures publiques (noms, paramètres, défauts, types de retour) sont **inchangées**.

### Corrections de bugs

1. **Perte de page en cas d'erreur.** Un `COMMIT` placé au milieu de `generate_form`, lors de la mise à jour de `GFM_FORM.SECTIONS`, validait la suppression de l'ancienne page. Si la suite échouait, la page était perdue. Ce commit est supprimé.
2. **`pid` au lieu du numéro de page réel.** Les actions dynamiques, la grille (clause `where`, items à soumettre, défaut de `PARENT_ID`), la recherche de la vue de rapport IG et la date de build utilisaient `pid`. Quand `pid` est nul (page prise dans la séquence), on obtenait des noms `P_xxx` invalides et un `NO_DATA_FOUND`. C'est désormais le numéro de page effectif partout.
3. **LOV inline cumulées.** La variable de construction des listes statiques n'était jamais réinitialisée. À partir du 2ᵉ champ « Inline List », la liste contenait aussi les valeurs des champs précédents.
4. **Langage de LOV** testé sur le libellé du champ (`r.lib`) au lieu de celui du composant (`complib`).
5. **Type d'affichage des listes** (`tdisplay`, `attr1`, `attr2`) non réinitialisé : un `POPUP` héritait des attributs du champ précédent. Un `VTYPE` inconnu lève maintenant une erreur explicite.
6. **Champs sans section.** Avec des sections, un champ sans section était rattaché à `subforms('$DUMMY')`, affecté *avant* la création de la région principale, donc nul. Il va maintenant dans la région principale. Même correction pour les grilles.
7. **Colonne `PARENT_ID` de la grille** créée sans `p_region_id`, donc orpheline.
8. **Grille avec plus de 7 colonnes** : le `VARRAY` n'était étendu qu'à 10 éléments, d'où un `SUBSCRIPT_BEYOND_COUNT`. Il est remplacé par une collection qui s'étend à la demande.
9. **Plusieurs grilles sur une page** : la vue de rapport IG était cherchée par page seulement (`TOO_MANY_ROWS`). Elle est maintenant cherchée par région.
10. **`APP_RUN_ID` absent** : `getParam` renvoyait `'NOK'`, ce qui provoquait une erreur de conversion au lieu du message prévu. La fonction renvoie maintenant `null` et le message est le bon.
11. **Séquences de champs** : si aucun champ n'avait de `SEQ`, `max(seq)` nul donnait des séquences nulles.
12. **Condition du bouton `CREATE`** sur `P<n>_upd_ID` en minuscules. Les noms d'items sont maintenant normalisés en majuscules.
13. **Nom de la vue** : la page utilisait `'G$_'||code` alors que `generate_ddl` créait `upper('G$_'||replace(code,' ','_'))`. Les deux passent désormais par une fonction unique.
14. **`copyForm`** : les `MASTER_ID` des champs copiés pointaient vers les champs du formulaire **source**. Ils sont maintenant remappés par code. `MAP_LASTID` n'est plus recopié, puisque les `MAP_ID` sont remis à zéro.
15. **`init_prefs`** : un deuxième appel créait des doublons. Le `INSERT` est remplacé par un `MERGE`.
16. **Slots au-delà de 99** : `'C0'||lpad(n,2,'0')` donnait `C0100`. Le nom est maintenant `C`+3 chiffres, et le package vérifie que la colonne existe dans `GFM_DATA`.
17. **Vue sans aucun champ** : la liste de colonnes produisait `seq_id,,form_id`.

### Sécurité

- Noms de vue et de colonnes validés par `DBMS_ASSERT.SIMPLE_SQL_NAME`.
- Littéraux des requêtes de LOV et du trigger échappés (`DBMS_ASSERT.ENQUOTE_LITERAL`), ce qui supprime l'injection SQL possible via `get_lov(plov)` et `get_lov_master`.
- `OBJ_SOURCE` validé par `DBMS_ASSERT.QUALIFIED_SQL_NAME`.

### Changements de comportement

- Seuls les champs `TCOMP = 'C'` génèrent un item de page ou une colonne de grille. Les autres n'ont pas de colonne dans la vue et produisaient un item en erreur.
- `copyItems` renseigne maintenant `SECTION_ID`, en retrouvant la section de même nom dans le formulaire cible.
- Un champ dont le `MANDATORY` n'est ni `Y` ni `N` est traité comme optionnel ; il recevait auparavant un template nul.
- Un `CTYPE` inconnu est ignoré avec un avertissement dans le debug, au lieu d'être ignoré silencieusement.

### Nettoyage

- La procédure `bootstrap`, une quarantaine de variables inutilisées et le code commenté mort sont supprimés.
- Les huit recherches de template sont factorisées dans `get_template_id`, et la création des boutons dans `add_button`.
- `generate_form`, qui faisait environ 900 lignes, est découpé en procédures par type de composant, qui partagent un contexte (`t_ctx`).
- `apex_debug_message` (legacy) est remplacé par `apex_debug`.
- Les constantes sont nommées : codes d'erreur, types de champs, plage de pages, page de retour.

## 10. Points à vérifier / limites connues

- **Attributs non confirmés par un export** : textarea, popup LOV et display selector utilisent les réglages par défaut d'APEX. À compléter avec les clés d'un export 26.1 si un réglage particulier est nécessaire.
- **Grilles** : `create_ig_report` et `create_ig_report_view` reçoivent `p_flow_id` / `p_page_id`, absents des exports. À valider à la première génération d'un formulaire avec sous-formulaire.
- **Champs numériques** : ils gardent le template de label par défaut, sans distinction obligatoire / optionnel ni astérisque, comme en v1.x. À confirmer : intentionnel ou oubli ?
- **Listes « Inline List »** : elles sont reconnues par le libellé du composant (`'Inline List'`), ce qui est fragile. Une valeur contenant `,` ou `;` casse la LOV statique.
- **`getNewPageid`** ne filtre pas `GFM_FORM.PAGE_ID` par application. Les pages réservées sont donc communes à toutes les applications.
- **Libellés en dur et en anglais** : `Apply Changes`, `Add a row`, `No data`… Page de retour fixée à 20 (`c_return_page`).
- **`CREATE OR REPLACE VIEW`** lors d'une régénération, suivi de `ALTER VIEW … ADD CONSTRAINT` : à surveiller si la contrainte existe déjà.
- **Codes de champs** : ils doivent être uniques dans un formulaire. `copyItems` ne contrôle pas les doublons avec les champs déjà présents dans le formulaire cible.
