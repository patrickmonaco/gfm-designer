# GFM Designer — architecture

Concepteur de formulaires GFM hors d'Oracle APEX : un client web JavaScript/Bootstrap, pensé pour le glisser-déposer, qui travaille sur les métadonnées GFM au travers d'une API REST ORDS. Les données, les règles et la génération des pages restent dans Oracle.

## 1. Vue d'ensemble

```
┌──────────────────────────────┐        HTTPS + JSON         ┌───────────────────────────────────────────┐
│  Navigateur                  │  Authorization: Bearer …    │  ORDS                                     │
│  client/ (HTML, ES modules)  │ ──────────────────────────► │  module gfm.designer  /gfm/v1/            │
│  Bootstrap 5 · SortableJS    │ ◄────────────────────────── │  privilège gfm.designer.priv (OAuth2)     │
└──────────────┬───────────────┘                             └───────────────────┬───────────────────────┘
               │ 1. redirection /oauth/auth (flux implicite)                     │ handlers PL/SQL
               │ 2. jeton dans le fragment d'URL                                 ▼
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
  - **Propriétés** : formulaire, section ou champ sélectionné, enregistrés automatiquement à chaque modification.

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

Équivalents au clavier : `Tab` pour atteindre un champ, `Entrée` pour le sélectionner, `Alt+↑/↓` pour le déplacer, `Suppr` pour le supprimer.

### Organisation du code

| Module | Contenu |
|---|---|
| `js/config.js` | URL de l'API, mode d'authentification, modèle d'URL des pages APEX |
| `js/auth.js` | Flux implicite OAuth2 : redirection, lecture du jeton, expiration |
| `js/api.js` | Appels REST, gestion des erreurs et du 401 |
| `js/app.js` | Démarrage et routage (`?form=<id>`) |
| `js/forms.js` | Liste des formulaires |
| `js/editor.js` | Éditeur : palette, canevas, glisser-déposer, redimensionnement, actions |
| `js/props.js` | Panneau de propriétés |
| `js/meta.js` | Libellés et icônes des codes GFM (`CTYPE`, `VTYPE`), largeurs |
| `js/ui.js` | Échappement HTML, toasts, boîtes de dialogue |

## 4. Contrat de l'API

Base : `https://<hôte>/ords/<schéma>/gfm/v1`. Tous les échanges sont en JSON. Les indicateurs valent `"Y"`/`"N"`.

| Méthode | Ressource | Corps | Réponse |
|---|---|---|---|
| GET | `/info` | — | `{user, appId, version}` |
| GET | `/forms` | — | `[{id, lib, code, notes, vtype, authent, pageId, lastBuild, itemCount, sectionCount, dataCount}]` |
| POST | `/forms` | `{lib, notes?, vtype?, authent?}` | 201 `{id, form}` |
| GET | `/forms/:id` | — | formulaire complet (ci-dessous) |
| PUT | `/forms/:id` | `{lib?, notes?, vtype?, authent?}` | formulaire |
| DELETE | `/forms/:id[?force=Y]` | — | `{deleted}`. 409 si des données existent sans `force=Y`, ou si le formulaire sert de sous-formulaire |
| POST | `/forms/:id/copy` | — | 201 `{id, form}` |
| POST | `/forms/:id/generate` | — | `{appId, pageId, message, form}` |
| POST | `/forms/:id/reset` | — | formulaire |
| PUT | `/forms/:id/layout` | `{unsectioned: [itemId], sections: [{id, items: [itemId]}]}` | formulaire |
| PUT | `/forms/:id/prefs` | `{prefs: {"$ITEM_TEMPLATE": "ABOVE", …}}` (`null` = défaut) | formulaire |
| POST | `/forms/:id/sections` | `{name, rank?}` | 201 `{id, form}` |
| PUT / DELETE | `/sections/:id` | `{name}` | formulaire |
| POST | `/forms/:id/items` | `{compId, tcomp?, lib?, sectionId?, code?}` | 201 `{id, form}` |
| PUT / DELETE | `/items/:id` | `{lib?, code?, description?, vtype?, lov?, mandatory?, newRow?, colSpan?, icon?, masterId?, masterValue?}` | formulaire |
| GET | `/items/:id/lov` | — | `[{d, r}]`, valeurs d'un champ liste |
| GET | `/components` | — | `{components: [...], detailForms: [...]}` |

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

**Codes** : `gfm_api` dérive le code d'un champ de son libellé : majuscules, sans accents, `[A-Z0-9_]`, 26 caractères au plus. Il le rend unique dans le formulaire et évite `SEQ_ID`, `FORM_ID`, `PARENT_ID` et `UPD_ID`. Le trigger `GFM_ITEMS_T1` ajoute toujours `$` aux mots réservés. Le code d'un formulaire est limité à 22 caractères pour laisser la place au suffixe d'une copie.

## 5. Sécurité

- **Privilège ORDS `gfm.designer.priv`** sur tout le module, lié au rôle `gfm_designer` : tout appel sans jeton valide reçoit 401.
- **Client web : flux OAuth2 implicite** (`gfm_designer_spa`). Le client redirige vers `/oauth/auth`, l'utilisateur s'identifie auprès d'ORDS, et le jeton revient dans le fragment d'URL. Le paramètre `state` est vérifié, le jeton est gardé en `sessionStorage` jusqu'à son expiration, et un 401 relance la connexion.
- **Utilisateurs** : ORDS les authentifie avec son propre référentiel. Quand ORDS est installé avec APEX, il peut s'appuyer sur les **utilisateurs du workspace APEX** : l'utilisateur doit alors appartenir à un groupe APEX nommé comme le rôle, `gfm_designer`. **À vérifier selon la configuration de votre ORDS.**
- **Client de test `gfm_designer_cli`** (client credentials) pour curl et les scripts. Son secret ne doit jamais être mis dans le navigateur.
- **CORS** : `p_origins_allowed` du module liste les origines autorisées à appeler l'API.
- **Côté base** : `gfm_api` est en `authid definer` et ne fait de SQL dynamique que pour les requêtes de LOV, construites par `gfm_builder.get_lov` (noms validés par `DBMS_ASSERT`). Toutes les entrées passent par des variables liées.
- Le flux implicite est celui qu'ORDS propose pour une application sans serveur, mais il est déconseillé par OAuth 2.1. Si votre ORDS le permet, le flux *authorization code* avec PKCE est préférable : seul `auth.js` serait à modifier.

## 6. Génération hors session APEX

`gfm_builder` appelle des API internes d'APEX qui ont besoin du *security group* du workspace. Un appel ORDS n'a pas de session APEX, donc `gfm_api.generate_form` commence par `apex_util.set_workspace`. Le workspace est lu dans le paramètre `GFM_SETUP.WORKSPACE`, ou à défaut retrouvé à partir de l'application `APP_RUN_ID`.

Un **formulaire de détail** (`VTYPE = 'D'`) ne génère que sa vue : il s'affiche en grille dans la page de ses formulaires maîtres, qu'il faut ensuite régénérer.

## 7. Installation

1. Base, en tant que propriétaire du schéma (ex. `DEMO`), avec un client UTF-8 :
   ```
   cd db
   sql demo/<mot de passe>@<base> @install.sql
   ```
   Avant de lancer le script, renseigner `c_origins` dans `03_ords_module.sql`, ainsi que `c_redirect_uri` et les adresses de support dans `04_ords_security.sql`. Si le schéma n'est pas encore REST, décommenter `ords.enable_schema` en tête de `03`.
2. Facultatif : ajouter le paramètre `WORKSPACE` dans `GFM_SETUP` (`PARA_TYPE = 'C'`, `VALC = nom du workspace`).
3. Créer le groupe d'utilisateurs APEX `gfm_designer` et y ajouter les concepteurs (voir § 5).
4. Client : renseigner `client/js/config.js` (URL de l'API, `client_id` lu dans `user_ords_clients`, URL d'autorisation, URL des pages APEX). Déposer le dossier `client/` sur un hébergement statique accessible à l'URL de redirection : serveur web, OVH, ou fichiers statiques d'ORDS.
5. Vérifier avec le client de test :
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
- la disponibilité du package `OAUTH` (sinon `ORDS_SECURITY` sur les ORDS récents) ;
- la connexion des utilisateurs APEX au flux implicite ;
- `apex_util.set_workspace` appelé depuis ORDS.

**Pas encore repris de l'application APEX** :
- gestion des composants et de leurs valeurs (`GFM_COMP`, `GFM_LOV`) ;
- paramètres (`GFM_SETUP`) ;
- consultation des données saisies ;
- copie de champs d'un formulaire à un autre (`copyItems`) ;
- administration des utilisateurs.

Les endpoints suivraient le même modèle.
