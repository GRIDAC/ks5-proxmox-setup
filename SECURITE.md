# Sécurité

Objectif : un serveur exposé sur Internet, exploitable par une petite équipe, sans outil de plus
que SSH. Chaque mesure ci-dessous est appliquée et contrôlée par le script.

## Exposition

| Entrée | Protection |
|---|---|
| SSH (22) de l'hôte | Clé uniquement (`AuthenticationMethods publickey`), fichier `00-ks5-hardening.conf` lu avant tout autre réglage, vérifié par `sshd -T` ; fail2ban (bannissement nftables progressif). Restriction possible à des adresses fixes (`SSH_ALLOW_FROM`). |
| 80 / 443 | Redirigés vers le routeur web (conteneur non privilégié, HAProxy, aucun déchiffrement). Les VM n'acceptent que ce routeur sur ces ports. |
| Ping | Accepté : sans réponse, la supervision OVH déclenche une intervention. |
| Interface Proxmox (8006) | Écoute sur 10.10.10.1 seulement, joignable par tunnel SSH. Le pare-feu Proxmox ajoute d'office le sous-réseau public de l'hôte (un /24 chez OVH) aux adresses autorisées à administrer : le script remplace ce réglage (`local_network`) par l'hôte lui-même. |
| Portmapper (111) | Service arrêté et masqué (vecteur d'amplification DDoS). |

## Isolation

- Réseau privé derrière l'hôte : aucune connexion n'y entre de l'extérieur, hormis 80/443
  redirigés vers le routeur (règle FORWARD). Les VM sortent par NAT.
- Pare-feu par VM, entrée refusée par défaut. N'entrent que : le routeur web (80/443), Coolify
  (SSH vers les serveurs qu'il pilote), l'hôte (SSH d'administration, interface Coolify).
- Filtre anti-usurpation (`ipfilter`) : une VM ne peut pas émettre avec l'adresse d'une autre
  pour contourner ces règles.
- Une VM compromise (par exemple un serveur d'essais) n'atteint ni les autres VM, ni Proxmox.

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
- Le fichier de paramètres est exécuté par le script : il doit appartenir à root et ne pas être
  modifiable par d'autres comptes, sinon le script s'arrête.
- Journal (`/var/log/ks5-setup.log`), réponses et récapitulatif en mode 600.

## « curl … | bash »

Le script entier est contenu dans un bloc que bash lit avant de l'exécuter : un téléchargement
interrompu n'exécute rien. Les questions lisent le terminal, jamais le flux téléchargé. Pour
relire avant d'exécuter : télécharger, lire, puis `bash ks5-setup.sh`.

## Hors périmètre, volontairement

- Proxmox Backup Server, supervision type Prometheus, IDS : disproportionnés pour un serveur
  unique ; les alertes mail couvrent les pannes qui comptent.
- Changement du port SSH : peu de gain face à clé + fail2ban (possible par `SSH_PORT`).
- Tunnel Cloudflare, VPN (Tailscale) : écartés pour garder un seul outil d'administration, SSH.

## Vérifications

- ShellCheck sans avertissement ; exécution complète et relance dans Debian 13 avec des commandes
  Proxmox simulées ; mode `curl … | bash` (interactif, sans questions, téléchargement coupé).
- Configuration HAProxy générée, chargée par HAProxy 3.0 de Debian 13 et testée avec de faux
  serveurs : bon aiguillage par domaine en HTTP et HTTPS, adresse du visiteur transmise.
- Non testé sur un vrai Proxmox VE 9 chez OVH au moment de la publication : relire les
  contrôles en fin d'exécution et faire la vérification externe (`nmap`) du README.
