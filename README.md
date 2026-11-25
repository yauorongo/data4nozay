# Observatoire citoyen — Data center Data4 PAR3, Nozay

Prototype indépendant d'information citoyenne sur le campus de data centers Data4 PAR3
(ancien site Nokia, route de Villejust, Nozay 91620). Réalisé par un habitant de Nozay, à partir
de données publiques. Non affilié à Data4, à la mairie de Nozay ni à la préfecture.

## Ce que fait le site

- Carte interactive (photo aérienne / plan, 2D / 3D, plein écran) avec les bâtiments du campus
  relevés sur le plan masse du dossier (avis MRAe APJIF-2025-091, illustration 2).
- Recherche d'adresse (Base Adresse Nationale) et simulation du bruit perçu chez soi,
  traduite en sons du quotidien, avec un volet détaillé pour les professionnels.
- Frise « Quand ? » : 2026 (chantier), fin 2027 (DC01), 2029 (+ DC02, estimation), fin 2030 (complet).
- Chronologie administrative, chiffres clés du dossier, écarts entre sources, liste des sources.

## Fichiers

| Fichier | Rôle |
|---|---|
| `index.html` | Page unique (HTML, CSS, JavaScript) |
| `maplibre-gl.js`, `maplibre-gl.css` | Bibliothèque cartographique MapLibre GL JS 5.23.0 (licence BSD-3) |
| `ortho.jpg`, `ortho_large.jpg` | Photo aérienne IGN BD ORTHO (3 km et 9 km autour du site) |
| `plan_hd.jpg`, `plan_large.jpg` | Plan IGN (mêmes emprises) |
| `batiments.json` | Bâtiments IGN BD TOPO avec hauteurs (3 694 bâtiments) |
| `adresses.csv` | Adresses de la Base Adresse Nationale dans le périmètre de la carte |

Site 100 % statique : pas de build, pas de serveur, pas de base de données.

## Publier sur Vercel

1. Comme pour DigitalMinds et Takenix, ce dossier a vocation à avoir son propre dépôt GitHub :
   dans un terminal ouvert sur `Data4Nozay`, lancer `git init`, `git add .`, `git commit -m "Observatoire Data4 Nozay"`,
   puis publier (VS Code > Contrôle de code source > « Publier sur GitHub », ou `gh repo create`).
2. Sur vercel.com : « Add New… » > « Project » > importer le dépôt.
   Preset « Other », aucune commande de build, aucun dossier de sortie. « Deploy ».
3. Chaque modification poussée sur GitHub republie automatiquement le site.

Test en local : `node serve.mjs` dans ce dossier, puis http://localhost:3000
(l'ouverture directe de index.html par double-clic ne charge pas la carte).

## Sources et licences des données

- IGN — BD ORTHO, Plan IGN, BD TOPO (Géoplateforme) : licence ouverte Etalab 2.0
- Base Adresse Nationale (adresse.data.gouv.fr) : licence ouverte Etalab 2.0
- Avis MRAe Île-de-France APJIF-2025-091 (8 octobre 2025), dossier d'autorisation PAR3,
  rapport du commissaire enquêteur, arrêté préfectoral du 29 mai 2026, DUP RTE du 5 mai 2026

## Limites (affichées sur le site)

- Modèle acoustique pédagogique (divergence géométrique + absorption de l'air) ;
  puissances sonores des équipements supposées, non issues de l'étude officielle.
- Hauteurs des bâtiments estimées ; calage du plan masse à ±20 m environ.
- Ordre de mise en service DC01 → DC02 → DC03 et année 2029 estimés.
