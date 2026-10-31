# GFM Designer — architecture

Concepteur de formulaires GFM hors d'Oracle APEX : un client web JavaScript/Bootstrap, pensé pour le glisser-déposer, qui travaille sur les métadonnées GFM au travers d'une API REST ORDS. Les données, les règles et la génération des pages restent dans Oracle.

## 1. Vue d'ensemble

```
┌──────────────────────────────┐        HTTPS + JSON         ┌───────────────────────────────────────────┐
│  Navigateur                  │  Authorization: Bearer …    │  ORDS                                     │
│  client/ (HTML, ES modules)  │ ──────────────────────────► │  module gfm.designer  /gfm/v1/            │
│  Bootstrap 5 · SortableJS    │ ◄────────────────────────── │  privilège gfm.designer.priv (OAuth2)     │
└──────────────┬───────────────┘                             └───────────────────┬───────────────────────┘
               │ 1. redirection /oauth/auth (authorization code)                 │ handlers PL/SQL
               │ 2. code → /oauth/token → jeton                                  ▼
               │                                             ┌───────────────────────────────────────────┐
               │                                             │  Oracle Database (schéma DEMO)            │
               │                                             │  gfm_api      : API JSON, transactions    │
               │                                             │  gfm_builder  : vue G$_*, page APEX       │
               │                                             │  GFM_FORM / SECTIONS / ITEMS / COMP / LOV │
               │                                             └───────────────────┬───────────────────────┘
               │                                                                 │ wwv_flow_imp_page
               │   « Ouvrir la page »                        ┌───────────────────▼───────────────────────┐
               └───────────────────────────────────────────► │  Application APEX cible (APP_RUN_ID)      │
                                                             │  pages de saisie générées                 │
                                                             └───────────────────────────────────────────┘
```

| Couche | Rôle | Fichiers |
|---|---|---|
| Client | Liste des formulaires, éditeur en glisser-déposer, panneau de propriétés | `client/` |
| API REST | Exposition HTTP, sécurité OAuth2, CORS | `db/03_ords_module.sql`, `db/04_ords_security.sql` |
| `gfm_api` | Lecture/écriture des métadonnées en JSON, validations, codes HTTP | `db/01_gfm_api.pks`, `db/02_gfm_api.pkb` |
| `gfm_builder` | Génération de la vue et de la page APEX (inchangé hormis `copyForm`) | `db/00_gfm_builder.*` |
| Maquette | Même API en mémoire, pour développer le client sans Oracle | `dev/mock-server.mjs` |

**Périmètre retenu** : le client remplace l'application APEX de *conception*. La *saisie* reste dans les pages APEX générées par `gfm_builder`.

## 2. Choix techniques

- **ORDS plutôt qu'un serveur Node** : aucun serveur supplémentaire, les handlers appellent directement le PL/SQL, et la sécurité OAuth2 est fournie par ORDS.
- **Toute la logique en PL/SQL (`gfm_api`)** : les handlers ORDS ne contiennent qu'un appel d'une ligne. Les règles (codes uniques, ordre des champs, cohérence des sections) restent au même endroit que `gfm_builder`.
- **Le serveur renvoie le formulaire complet après chaque modification.** Le client ne fait aucun calcul d'état : il réaffiche ce que la base contient. Un formulaire pèse quelques kilo-octets, c'est plus simple et sans risque de désynchronisation.
- **Client sans étape de build** : modules ES natifs, Bootstrap 5.3 et SortableJS 1.15 depuis jsDelivr. Les fichiers se servent tels quels depuis n'importe quel hébergement statique.
- **SortableJS** pour le glisser-déposer : listes imbriquées, clonage depuis une palette, poignées, tactile, sans dépendance.

## 3. Le client

### Écrans

- **Formulaires** : cartes avec recherche, création (libellé, description, type maître/détail), duplication, suppression.
- **Éditeur**, en trois colonnes :
  - **Palette** : « Section », les composants (`GFM_COMP` non internes) et les formulaires de détail utilisables comme sous-formulaires. En bas, la **corbeille**.
  - **Canevas** : aperçu du formulaire sur une grille de 12 colonnes, comme la grille APEX de la page générée. Une zone « en tête » accueille les champs hors section, puis viennent les sections.
  - **Propriétés** : formulaire, section ou champ sélectionné, enregistrés automatiquement à chaque modification. Un champ liste propose un lien vers les valeurs de son composant.
- **Composants** : catalogue des composants (`GFM_COMP`) regroupés par type, création, propriétés, suppression. Pour une liste statique, un éditeur de valeurs (`GFM_LOV`) permet de modifier libellé et valeur, de choisir la valeur par défaut, de **réordonner par glisser-déposer** et de **coller une liste** depuis un tableur. Un aperçu montre la liste telle qu'elle apparaîtra dans le formulaire. Les composants standards (`FACTORY = 'Y'`) ne peuvent être ni renommés, ni changés de type, ni supprimés. Le type d'un composant utilisé est figé.

### Interactions en glisser-déposer

| Geste | Effet | Appels |
|---|---|---|
| Composant de la palette → section | Crée le champ à l'endroit du dépôt et le sélectionne | `POST /forms/:id/items` puis `PUT /forms/:id/layout` |
| Sous-formulaire de la palette → section | Ajoute une grille éditable (`TCOMP = 'D'`) | idem |
| « Section » de la palette → liste des sections | Demande le nom, crée la section à cette position | `POST /forms/:id/sections` |
| Champ → autre position ou autre section | Réordonne | `PUT /forms/:id/layout` |
| Poignée d'une section | Réordonne les sections | `PUT /forms/:id/layout` |
| Bord droit d'un champ | Change la largeur par sixièmes de ligne (`COL_SPAN`) | `PUT /items/:id` |
| Champ ou section → corbeille | Suppression, après confirmation | `DELETE /items/:id`, `DELETE /sections/:id` |
| Valeurs d'une liste inline | Réordonne les valeurs | `PUT /items/:id` (`lov`) |
| Valeurs d'un composant liste (écran Composants) | Réordonne les valeurs (enregistrées avec le bouton) | `PUT /components/:id/values` |

Équivalents au clavier : `Tab` pour atteindre un champ, `Entrée` pour le sélectionner, `Alt+↑/↓` pour le déplacer, `Suppr` pour le supprimer.

### Organisation du code

| Module | Contenu |
|---|---|
| `js/config.js` | URL de l'API, mode d'authentification, modèle d'URL des pages APEX |
| `js/auth.js` | OAuth2 (authorization code + PKCE, ou implicite) : redirection, échange du code, expiration |
| `js/api.js` | Appels REST, gestion des erreurs et du 401 |
| `js/app.js` | Démarrage et routage (`?form=<id>`, `?view=components&comp=<id>`) |
| `js/forms.js` | Liste des formulaires |
| `js/editor.js` | Éditeur : palette, canevas, glisser-déposer, redimensionnement, actions |
| `js/props.js` | Panneau de propriétés |
| `js/components.js` | Écran Composants : catalogue, propriétés, valeurs, aperçu |
| `js/icons.js`, `js/font-apex-icons.js` | Sélecteur d'icônes Font APEX et liste des icônes (catégories, mots-clés) |
| `js/meta.js` | Libellés et icônes des codes GFM (`CTYPE`, `VTYPE`), largeurs |
| `js/ui.js` | Échappement HTML, toasts, boîtes de dialogue |

## 4. Contrat de l'API

Base : `https://<hôte>/ords/<schéma>/gfm/v1`. Tous les échanges sont en JSON. Les indicateurs valent `"Y"`/`"N"`.

| Méthode | Ressource | Corps | Réponse |
|---|---|---|---|
| GET | `/info` | — | `{user, appId, version}` |
| GET | `/forms` | — | `[{id, lib, code, notes, vtype, authent, pageId, lastBuild, itemCount, sectionCount, dataCount}]` |
| POST | `/forms` | `{lib, notes?, vtype?, scope?, authent?, isPublished?}` | 201 `{id, form}` |
| GET | `/forms/:id` | — | formulaire complet (ci-dessous) |
| PUT | `/forms/:id` | `{lib?, notes?, vtype?, scope?, authent?, isPublished?}` | formulaire. 409 si une grille utilisée change de type |
| DELETE | `/forms/:id[?force=Y]` | — | `{deleted, message}`. Supprime aussi les pages de saisie et de rapport (si elles portent bien sur les vues du formulaire) et les vues `G$_<CODE>` et `G$_<CODE>_R`. 409 si des données existent sans `force=Y`, ou si le formulaire sert de sous-formulaire |
| POST | `/forms/:id/copy` | — | 201 `{id, form}` |
| POST | `/forms/:id/generate` | — | `{appId, pageId, reportPageId, message, form}` |
| POST | `/forms/:id/reset` | — | formulaire |
| PUT | `/forms/:id/layout` | `{unsectioned: [itemId], sections: [{id, items: [itemId]}]}` | formulaire |
| PUT | `/forms/:id/prefs` | `{prefs: {"$ITEM_TEMPLATE": "ABOVE", …}}` (`null` = défaut) | formulaire |
| POST | `/forms/:id/sections` | `{name, rank?}` | 201 `{id, form}` |
| PUT / DELETE | `/sections/:id` | `{name}` | formulaire |
| POST | `/forms/:id/items` | `{compId, tcomp?, lib?, sectionId?, code?}` | 201 `{id, form}` |
| PUT / DELETE | `/items/:id` | `{lib?, code?, description?, vtype?, lov?, mandatory?, newRow?, colSpan?, icon?, masterId?, masterValue?}` | formulaire |
| GET | `/items/:id/lov` | — | `[{d, r}]`, valeurs d'un champ liste |
| GET | `/components` | — | `{components: [{…, factory, objSource, itemCount, valueCount}], detailForms: [...]}` |
| POST | `/components` | `{lib, ctype, vtype?, notes?, icon?, groupe?, objSource?}` | 201 composant |
| GET / PUT / DELETE | `/components/:id` | (PUT) attributs à modifier | composant `{…, forms, values: [{id, d, r, isDefault}]}`. DELETE : 409 si standard ou utilisé |
| PUT | `/components/:id/values` | `{values: [{id?, d, r, isDefault}]}`, liste complète dans l'ordre | composant |
| GET | `/components/:id/preview` | — | `[{d, r}]` tels qu'affichés, au plus 100 (liste dynamique : résultat de la vue) |

**Formulaire complet**

```json
{
  "id": 1006, "lib": "Fiche Logistique", "code": "FICHE_LOGISTIQUE", "notes": "…",
  "vtype": "M", "authent": "Y", "pageId": 102, "appId": 157,
  "lastBuild": "2026-10-29T21:58:12", "isViewGenerated": "Y", "isFormGenerated": "Y", "dataCount": 12,
  "sections": [{ "id": 1007, "name": "Général", "rank": 1 }],
  "items": [{
    "id": 1011, "lib": "Nom du demandeur", "code": "NOM_DU_DEMANDEUR", "description": null,
    "tcomp": "C", "compId": 6, "compLib": "Text Field", "ctype": "CT", "isInline": "N",
    "vtype": null, "lov": null, "sectionId": 1007, "seq": 10, "newRow": "Y", "mandatory": "Y",
    "colSpan": 3, "icon": "fa-user", "compIcon": null, "masterId": null, "masterValue": null, "mapId": 1
  }],
  "prefs": [{ "pref": "$ITEM_TEMPLATE", "notes": "…", "val": "FLOATING", "options": [{ "d": "Floating", "r": "FLOATING" }] }]
}
```

**Erreurs** : `{"error": "message"}` avec le statut 404 (introuvable), 409 (conflit, doublon), 422 (règle métier, `ORA-20xxx` de `gfm_api` ou `gfm_builder`) ou 500 (erreur inattendue). Le message des 422 est affiché tel quel à l'utilisateur.

**Ordre des champs** : `save_layout` réécrit `GFM_SECTIONS.RANK`, puis `GFM_ITEMS.SECTION_ID`, `SECTION` (colonne historique) et `SEQ` (10, 20…) dans l'ordre reçu, d'abord les champs hors section, en une seule transaction. Cet ordre est celui qu'utilise `gfm_builder`.

**Valeurs des listes** : `GFM_LOV.SEQ` (script `06_lov_order.sql`) fixe l'ordre d'affichage. `gfm_builder.get_lov` trie sur `SEQ`, puis sur le libellé. Comme les pages générées appellent `get_lov` à l'affichage, un nouvel ordre s'applique sans régénérer. `save_values` reçoit la liste complète : les valeurs avec `id` sont mises à jour, celles sans `id` sont insérées, et les absentes sont supprimées. Seule la colonne `C_VALUE` est utilisée, comme dans `get_lov`. La valeur enregistrée est obligatoire et unique dans la liste, le libellé reprend la valeur s'il est vide, et une seule valeur peut être celle par défaut.

**Listes dynamiques** : `objSource` doit être une vue ou une table existante qui expose les colonnes `D` et `R`. Elle est vérifiée par `DBMS_ASSERT.SQL_OBJECT_NAME` et par une requête d'essai.

**Types de formulaire** (`GFM_FORM.VTYPE`) :
- `M` **Formulaire** : une page de saisie APEX et son report interactif ;
- `D` **Grille** : un tableau éditable inclus dans un formulaire, pour lequel seule la vue est générée ;
- `B` **Bloc** : un groupe de champs réutilisable. Il se conçoit dans l'éditeur, mais **n'est pas généré** : le bouton « Générer » est masqué et l'API répond 422. Un numéro de page n'est réservé que pour un formulaire de type `M`.

**Portée, authentification, publication** : `GFM_FORM.SCOPE` (`0` public, `1` groupe, `2` privé), `AUTHENT` et `IS_PUBLISHED` se règlent à la création et dans les propriétés du formulaire. Pour l'instant, seule l'authentification agit sur la génération (page publique ou non). La portée et la publication sont enregistrées, et leur effet est à implémenter.

**Colonnes de stockage** : chaque champ est stocké dans une colonne de `GFM_DATA`, enregistrée dans `GFM_ITEMS.MAP_COL` et attribuée par `generate_ddl` à la première génération qui suit sa création :
- un **nombre** va dans une colonne `NUMBER` (`N002` à `N020`), une **date** dans une colonne `DATE` (`D001` à `D020`), et tout le reste dans une colonne `VARCHAR2` (`C001` à `C050`) ;
- quand les colonnes typées sont épuisées pour un formulaire, le champ va dans une colonne texte, convertie dans la vue d'affichage ;
- `N001` est réservée au lien des sous-formulaires vers leur maître (`PARENT_ID`) ;
- une colonne libérée par un champ supprimé peut être réattribuée : elle est d'abord **vidée** pour ce formulaire, puisque ses anciennes valeurs n'étaient plus accessibles ;
- les champs créés avant cette version gardent leur colonne texte et leurs données (`MAP_COL` déduite de `MAP_ID` par `08_typed_columns.sql`).

Sur la page générée, l'item et la colonne de grille prennent le type de leur colonne : nombre, ou date au format de l'application. Le panneau de propriétés d'un champ indique sa colonne de stockage.

**Report interactif** : pour un formulaire maître, la génération produit, dans cet ordre :
1. la vue de saisie `G$_<CODE>` ;
2. une **vue d'affichage** `G$_<CODE>_R`. Les nombres y sont de type `NUMBER` (virgule ou point décimal) et les dates de type `DATE`, au format de stockage `MM/DD/YYYY`, modifiable par le paramètre `GFM_SETUP.DATE_FORMAT`. Les listes donnent leurs libellés, et les valeurs multiples `a:b` deviennent « libellé a, libellé b ». Les colonnes d'audit `GFM$CREATED_ON/BY` et `GFM$UPDATED_ON/BY` s'ajoutent à la fin. Une valeur non convertible s'affiche vide ;
3. une **page de report interactif** sur cette vue (`GFM_FORM.REPORT_PAGE_ID`). Le n° de chaque ligne ouvre la fiche, un bouton « Nouveau » crée une fiche, et les colonnes d'audit sont disponibles mais masquées par défaut ;
4. la page de saisie, qui revient au rapport après enregistrement ou suppression.

La page du rapport **n'est régénérée que si ses colonnes changent** (nom, libellé ou type). Une régénération supprime en effet les rapports enregistrés par les utilisateurs : modifier l'ordre ou la largeur des champs ne les touche pas, mais ajouter, supprimer ou renommer un champ les efface. `gfm_builder.generate_report(fid, pid, 'Y')` force la régénération. L'item date de la page de saisie reçoit le même masque que la vue (`date_format`) : changer `DATE_FORMAT` après coup rendrait illisibles les dates déjà saisies.

**Sous-formulaires (grilles)** : la grille d'un sous-formulaire est filtrée sur `PARENT_ID = :P<page>_SEQ_ID`, et la colonne cachée `PARENT_ID` reçoit par défaut le `SEQ_ID` de la fiche. `create_interactive_grid` crée lui-même le rapport principal et sa vue « grille » : `gfm_builder` les réutilise et n'ajoute que ce qui manque, sans quoi APEX lève `IG_RPT_NAME_UK` ou `IG_RPT_VIEW_UK`.

**Listes inline vides** : une liste inline sans valeur produirait une page APEX en erreur. Le champ est signalé sur le canevas et dans ses propriétés, et la génération est refusée tant qu'une telle liste reste vide. Le refus a lieu dans le client, dans `gfm_api.generate_form` (422 avec la liste des champs) et dans `gfm_builder`.

**Icônes** : le sélecteur propose les icônes Font APEX du Universal Theme, regroupées par catégorie et recherchables par nom ou mot-clé (en anglais). Il sert pour l'icône d'un champ et pour l'icône par défaut d'un composant. Il n'existe pas de liste interrogeable dans la base APEX. La liste vient donc de `docs/icons.js` du dépôt [oracle/font-apex](https://github.com/oracle/font-apex) (licence MIT), figé au commit `24631d9` de mars 2024, et la feuille de style est chargée depuis jsDelivr au même commit. Les icônes ajoutées par des versions d'APEX plus récentes peuvent manquer : le champ accepte toujours une saisie libre. Pour mettre la liste à jour : `node dev/gen-font-apex-icons.cjs <clone>/docs/icons.js client/js/font-apex-icons.js`, puis reporter le commit dans le lien `font-apex.min.css` de `index.html`.

**Codes** : `gfm_api` dérive le code d'un champ de son libellé : majuscules, sans accents, `[A-Z0-9_]`, 26 caractères au plus. Il le rend unique dans le formulaire et évite `SEQ_ID`, `FORM_ID`, `PARENT_ID` et `UPD_ID`. Le trigger `GFM_ITEMS_T1` ajoute toujours `$` aux mots réservés. Le code d'un formulaire est limité à 22 caractères pour laisser la place au suffixe d'une copie.

## 5. Sécurité

- **Privilège ORDS `gfm.designer.priv`** sur tout le module, lié au rôle `gfm_designer` : tout appel sans jeton valide reçoit 401.
- **Client web : flux OAuth2 *authorization code*** (`gfm_designer_web`, script `db/05_ords_client_code.sql`). Les versions récentes d'ORDS désactivent le flux implicite. Le client redirige vers `/oauth/auth`, l'utilisateur s'identifie auprès d'ORDS, et ORDS renvoie un code sur `index.html`. Le client échange ce code contre un jeton sur `/oauth/token`, en envoyant le `client_id`, le secret et un `code_verifier` PKCE. Le paramètre `state` est vérifié, le jeton est gardé en `sessionStorage` jusqu'à son expiration, et un 401 relance la connexion.
- **Secret client visible dans le navigateur** : sans serveur intermédiaire, le secret figure dans `config.js`. Il ne suffit pas à obtenir un jeton, puisque l'utilisateur doit toujours s'identifier, et les URL de redirection sont restreintes. Ce client doit rester dédié à GFM Designer. Si ORDS accepte un jour le PKCE sans secret, il suffira de vider `clientSecret`. Sinon, la solution propre consiste à servir le client depuis le même hôte qu'ORDS, derrière un petit proxy qui fait l'échange du code.
- **Utilisateurs** : ORDS les authentifie avec son propre référentiel. Quand ORDS est installé avec APEX, il peut s'appuyer sur les **utilisateurs du workspace APEX** : l'utilisateur doit alors appartenir à un groupe APEX nommé comme le rôle, `gfm_designer`. **À vérifier selon la configuration de votre ORDS.**
- **Client de test `gfm_designer_cli`** (client credentials) pour curl et les scripts. Son secret ne doit jamais être mis dans le navigateur.
- **CORS** : `ords.set_module_origins_allowed` (dans `03_ords_module.sql`) liste les origines autorisées à appeler l'API.
- **Côté base** : `gfm_api` est en `authid definer` et ne fait de SQL dynamique que pour les requêtes de LOV, construites par `gfm_builder.get_lov` (noms validés par `DBMS_ASSERT`). Toutes les entrées passent par des variables liées.
- `auth.js` sait aussi utiliser le flux implicite (`flow: 'implicit'`) pour un ORDS qui l'autorise encore.

## 6. Génération hors session APEX

`gfm_builder` appelle des API internes d'APEX qui ont besoin du *security group* du workspace. Un appel ORDS n'a pas de session APEX, donc `gfm_api.generate_form` commence par `apex_util.set_workspace`. Le workspace est lu dans le paramètre `GFM_SETUP.WORKSPACE`, ou à défaut retrouvé à partir de l'application `APP_RUN_ID`.

Un **formulaire de détail** (`VTYPE = 'D'`) ne génère que sa vue : il s'affiche en grille dans la page de ses formulaires maîtres, qu'il faut ensuite régénérer.

## 7. Installation

1. Base, en tant que propriétaire du schéma (ex. `DEMO`), avec un client UTF-8 :
   ```
   cd db
   sql demo/<mot de passe>@<base> @install.sql
   ```
   Avant de lancer le script, renseigner `c_origins` dans `03_ords_module.sql`, ainsi que l'origine, `c_redirect_uri` et les adresses de support dans `05_ords_client_code.sql`. Si le schéma n'est pas encore REST, décommenter `ords.enable_schema` en tête de `03`.
2. Facultatif : ajouter le paramètre `WORKSPACE` dans `GFM_SETUP` (`PARA_TYPE = 'C'`, `VALC = nom du workspace`).
3. Créer le groupe d'utilisateurs APEX `gfm_designer` et y ajouter les concepteurs (voir § 5).
4. Client OAuth : lancer `db/05_ords_client_code.sql`, qui crée le client `gfm_designer_web` et affiche son `client_id` et son `client_secret`.
5. Client web : renseigner `client/js/config.js` : URL de l'API, `clientId`, `clientSecret`, `authorizeUrl`, `tokenUrl` et URL des pages APEX. Déposer le dossier `client/` sur un hébergement statique accessible à l'URL de redirection : serveur web, OVH, ou fichiers statiques d'ORDS.
6. Vérifier avec le client de test :
   ```
   curl -u <client_id>:<secret> -d grant_type=client_credentials https://<hôte>/ords/<schéma>/oauth/token
   curl -H "Authorization: Bearer <jeton>" https://<hôte>/ords/<schéma>/gfm/v1/forms
   ```

## 8. Développer sans Oracle

```
node dev/mock-server.mjs        # http://localhost:8080
```

La maquette sert le client et implémente toute l'API en mémoire, avec le même contrat que `gfm_api`. Elle remplace `config.js` par une configuration sans authentification et contient un jeu d'essai : la « Fiche Logistique » et un sous-formulaire. Les données sont perdues à l'arrêt.

## 9. État et suite

**Vérifié** : le client a été testé dans Chromium avec la maquette. Sont couverts le dépôt depuis la palette, le déplacement entre sections, le réordonnancement des sections, la création de section, la corbeille, le redimensionnement, la liste inline, le champ maître et ses valeurs, la génération, la suppression avec données (409), les écrans mobile et sombre, et l'absence d'erreurs JavaScript.

**Non vérifié** : le PL/SQL et les scripts ORDS n'ont été ni compilés ni exécutés. Points à surveiller au premier déploiement :
- le statut HTTP posé par `owa_util.status_line` (sinon, utiliser le paramètre implicite `:status_code` d'ORDS) ;
- l'acceptation par ORDS des paramètres PKCE (`code_challenge`), envoyés en plus du secret ;
- la connexion des utilisateurs APEX au flux *authorization code* ;
- `apex_util.set_workspace` appelé depuis ORDS.

**Mise à jour 1.4 → 1.5 (bloc, portée, publication)** : `db/update_v1.5.sql`, qui recompile `gfm_api`. Les colonnes existent déjà.

**Mise à jour 1.3 → 1.4 (suppression des pages)** : `db/update_v1.4.sql`, qui recompile `gfm_builder` et `gfm_api`. Aucun changement de table ni d'ORDS.

**Mise à jour 1.2 → 1.3 (colonnes NUMBER et DATE)** : `db/update_v1.3.sql`. Il ajoute `N001` à `N020` et `D001` à `D020` à `GFM_DATA`, ainsi que `GFM_ITEMS.MAP_COL`, puis recompile `gfm_builder` et `gfm_api`. Le module ORDS ne change pas.

**Mise à jour 1.1 → 1.2 (report interactif)** : `db/update_v1.2.sql`. Il ajoute `GFM_FORM.REPORT_PAGE_ID` puis recompile `gfm_builder` et `gfm_api`. Le module ORDS ne change pas.

**Mise à jour 1.0 → 1.1 (écran Composants)** : `db/update_v1.1.sql`. Il ajoute `GFM_LOV.SEQ`, recompile `gfm_builder` et `gfm_api`, recrée le module ORDS, puis relance `04` pour rattacher le privilège au module recréé.

**Pas encore repris de l'application APEX** :
- composants système (`INTERNAL = 'Y'`, préférences `$…`), volontairement exclus de l'écran ;
- paramètres (`GFM_SETUP`) ;
- consultation des données saisies ;
- copie de champs d'un formulaire à un autre (`copyItems`) ;
- administration des utilisateurs.

Les endpoints suivraient le même modèle.
