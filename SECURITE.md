# Sécurité

Objectif : un serveur exposé sur Internet, exploitable par une petite équipe avec un navigateur
et SSH, sans tunnel ni VPN. Chaque mesure ci-dessous est appliquée et contrôlée par le script.

## Exposition

| Entrée | Protection |
|---|---|
| SSH (22) de l'hôte | Clé uniquement (`AuthenticationMethods publickey`), fichier `00-ks5-hardening.conf` lu avant tout autre réglage, vérifié par `sshd -T` ; fail2ban (bannissement nftables progressif). Restriction possible à des adresses fixes (`SSH_ALLOW_FROM`). |
| 80 / 443 | Redirigés vers le routeur web (conteneur non privilégié, HAProxy, aucun déchiffrement des sites). Les VM n'acceptent que ce routeur sur ces ports. Domaine inconnu refusé (404 / connexion fermée) au lieu d'être envoyé à une application. |
| Ping | Accepté : sans réponse, la supervision OVH déclenche une intervention. |
| Interface Proxmox (8006) | Écoute sur 10.10.10.1 seulement, absente de l'IP publique. Publiée en HTTPS sous `proxmox.<domaine>` par le routeur, qui la transmet sans déchiffrer et **refuse toute source hors `ADMIN_ALLOW_FROM`** ; le pare-feu de l'hôte n'accepte le 8006 que du routeur. Sans liste d'adresses, l'interface n'est pas publiée, sauf choix explicite (`PVE_OPEN_TO_ALL`, TOTP alors indispensable). Le pare-feu Proxmox ajoute d'office le sous-réseau public de l'hôte (un /24 chez OVH) aux adresses autorisées à administrer : le script remplace ce réglage (`local_network`) par l'hôte lui-même. |
| Coolify | `coolify.<domaine>` en HTTPS. Compte administrateur créé à l'installation (mot de passe aléatoire sur l'hôte, `/root/ks5-keys/coolify-admin.txt`) : personne ne peut prendre l'instance en s'inscrivant le premier. Pendant l'amorçage, le routeur termine HTTPS avec un certificat provisoire (empreinte dans le récapitulatif), réservé à `ADMIN_ALLOW_FROM` s'il est renseigné ; ensuite, transmission sans déchiffrer au Traefik de Coolify. `COOLIFY_ADMIN_ONLY=1` réserve aussi Coolify aux adresses d'administration (au prix des webhooks Git entrants). |
| Portmapper (111) | Service arrêté et masqué (vecteur d'amplification DDoS). |

## Isolation

- Réseau privé derrière l'hôte : aucune connexion n'y entre de l'extérieur, hormis 80/443
  redirigés vers le routeur (règle FORWARD). Les VM sortent par NAT.
- Une VM par grande stack (Kobo, data/BI, observatoire, recette), toutes pilotées par la même
  instance Coolify.
- Pare-feu par VM, entrée refusée par défaut. N'entrent que : le routeur web (80/443, et
  l'interface de Coolify pendant l'amorçage), Coolify (SSH vers les serveurs qu'il pilote),
  l'hôte (SSH d'administration), et les flux entre stacks listés dans `VM_FW_EXTRA` (par défaut :
  observatoire → PostgreSQL/PostGIS de data-bi, port 5432). Les bases ne sont jamais publiées
  sur Internet.
- Filtre anti-usurpation (`ipfilter`) : une VM ne peut pas émettre avec l'adresse d'une autre
  pour contourner ces règles.
- Une VM compromise (par exemple la recette) n'atteint ni les autres VM, ni Proxmox : passant
  par le routeur, elle se présente avec l'adresse de l'hôte, hors de la liste d'administration.

## Application des changements à distance

Le KS-5 n'a pas de console KVM. Avant de toucher à SSH et au pare-feu, le script arme une
minuterie systemd : sans confirmation d'une **nouvelle** connexion SSH sous 5 minutes, SSH et
pare-feu sont restaurés, même si la session est coupée. Configurations remplacées conservées
dans `/root/ks5-backups/`.

## Mises à jour et alertes

- Correctifs de sécurité automatiques : Debian sur l'hôte (sans redémarrage, mail en cas
  d'erreur), Debian dans le routeur (HAProxy compris), Ubuntu dans les VM. Proxmox se met à jour
  à la main.
- Mail de root vers l'administrateur : panne de disque ou pool ZFS dégradé, sauvegarde en échec,
  erreur de mise à jour ; alerte quotidienne au-delà de 80 % d'occupation.

## Secrets

- Aucun jeton à fournir. Le seul secret facultatif (mot de passe du relais SMTP) est saisi
  masqué, jamais journalisé ni enregistré dans le fichier de réponses.
- Mot de passe initial de Coolify : généré sur l'hôte (mode 600), transmis à la VM par un
  fichier cloud-init lisible par root seulement ; à changer à la première connexion.
- Le fichier de paramètres est exécuté par le script : il doit appartenir à root et ne pas être
  modifiable par d'autres comptes, sinon le script s'arrête.
- Journal (`/var/log/ks5-setup.log`), réponses et récapitulatif en mode 600.

## « curl … | bash »

Le script entier est contenu dans un bloc que bash lit avant de l'exécuter : un téléchargement
interrompu n'exécute rien. Les questions lisent le terminal, jamais le flux téléchargé. Pour
relire avant d'exécuter : télécharger, lire, puis `bash ks5-setup.sh`.

## Sauvegardes

- Locale quotidienne (erreur humaine, mise à jour ratée) et, avec `BACKUP_REMOTE_STORAGE`, copie
  quotidienne hors serveur (panne ou perte du serveur). Sans copie hors serveur, le script le
  signale à chaque exécution.
- Une sauvegarde n'est fiable qu'une fois restaurée : essai trimestriel (README, section 5).

## Hors périmètre, volontairement

- Proxmox Backup Server *sur ce serveur*, supervision type Prometheus, IDS : disproportionnés
  pour un serveur unique ; les alertes mail couvrent les pannes qui comptent. Un PBS *distant*
  est en revanche la cible conseillée de la copie hors serveur.
- Changement du port SSH : peu de gain face à clé + fail2ban (possible par `SSH_PORT`).
- Tunnels SSH, ProxyJump, tunnel Cloudflare, VPN (Tailscale, WireGuard) : écartés. L'administration
  passe par HTTPS (routeur) et SSH direct ; Coolify joint ses serveurs par le réseau privé.

## Vérifications

- ShellCheck sans avertissement ; mode plan (`-p -y`) avec des commandes Proxmox simulées :
  plan, routes, flux entre stacks, refus de l'ancien profil `kobo`, Proxmox non publié sans
  liste d'adresses.
- Configuration HAProxy générée, validée et testée avec de faux serveurs (HAProxy 2.8) :
  aiguillage par domaine en HTTP et HTTPS, adresse du visiteur transmise, domaines inconnus
  refusés, Proxmox et amorçage de Coolify refusés hors des adresses d'administration,
  amorçage de Coolify en HTTPS vers le port 8000 (et 6001 pour le temps réel).
- **Non testé sur un vrai Proxmox VE 9 chez OVH**, ni avec une vraie instance Coolify
  (amorçage, protocole PROXY, certificats) : suivre la validation de la section 7 du README
  avant toute mise en production.
