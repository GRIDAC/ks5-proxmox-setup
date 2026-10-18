# ks5-proxmox-setup

Un serveur OVH Kimsufi **KS-5** sous **Proxmox VE**, avec **une seule installation de Coolify**
qui pilote **une VM Docker par grande stack**, en une commande. Interactif : les valeurs du KS-5
sont proposées par défaut (Entrée pour garder), modifiables si le serveur est différent.
Administration en **HTTPS, sans tunnel** ni VPN.

```bash
curl -fsSL https://raw.githubusercontent.com/kv5t/ks5-proxmox-setup/main/ks5-setup.sh | bash
```

À lancer **en root sur le serveur**, depuis une session SSH interactive (`ssh root@IP`).
Simulation sans aucune modification : `… | bash -s -- -p`.

> **Pas encore éprouvé sur un vrai Proxmox VE 9 chez OVH.** Le script a été vérifié par
> ShellCheck, en mode plan avec des commandes Proxmox simulées, et la configuration du routeur
> par HAProxy avec de faux serveurs. Avant la production, suivre la
> [validation sur serveur réel](#7-validation-avant-la-production).

## Architecture

```
OVH KS-5 — Proxmox VE (hyperviseur, réseau privé 10.10.10.0/24, pare-feu, sauvegardes)
│
├─ CT 100  entree        routeur HTTPS : une IPv4 publique → la bonne VM, selon le domaine
├─ VM 101  coolify       l'unique Coolify : déploiements, supervision, pilote 102 à 105 en SSH privé
├─ VM 102  kobo          stack 1 — KoboToolbox complet (Compose déployé par Coolify)
├─ VM 103  data-bi       stack 2 — PostgreSQL/PostGIS, Metabase, Redash, Lightdash, Grist, Teable
├─ VM 104  observatoire  stack 3 — Django / Wagtail
└─ VM 105  recette       essais, facultative
```

| ID | Nom | Rôle | Adresse | vCPU | RAM | Disque | Piloté par Coolify |
|---|---|---|---|---|---|---|---|
| — | Hôte Proxmox | Hyperviseur, NAT, pare-feu, sauvegardes | 10.10.10.1 | 8 threads | 64 Go | 2 × 2 To, RAID 1 ZFS | non |
| 100 | entree (LXC) | Routeur HTTPS HAProxy | 10.10.10.10 | 1 | 0,5 Go | 8 Go | non (infrastructure) |
| 101 | coolify | Console Coolify centrale | 10.10.10.11 | 2 | 6 Go | 60 Go | c'est la console |
| 102 | kobo | KoboToolbox | 10.10.10.12 | 4 | 14 Go | 300 Go | oui |
| 103 | data-bi | Bases et outils analytiques | 10.10.10.13 | 4 | 18 Go | 500 Go | oui |
| 104 | observatoire | Django / Wagtail | 10.10.10.14 | 2 | 8 Go | 150 Go | oui |
| 105 | recette | Recette et essais (facultative) | 10.10.10.15 | 2 | 4 Go | 100 Go | oui |

Une *stack* est un grand ensemble fonctionnel : les outils BI ont chacun leurs conteneurs et
leurs bases, mais partagent la VM 103. Ce n'est pas une VM par conteneur. Le plan s'adapte au
matériel : sur 32 Go ou 2 × 450 Go NVMe, le script propose de réduire les VM, de les modifier une
par une, d'en retirer (la recette par exemple) ou d'en ajouter.

**Pourquoi un routeur d'entrée ?** Avec une seule IPv4 publique, plusieurs VM ne peuvent pas
toutes recevoir le port 443 de cette adresse. Le conteneur HAProxy lit le nom demandé (SNI) et
transmet la connexion **sans la déchiffrer** à la VM concernée, dont le proxy Traefik (géré par
Coolify) obtient ses certificats Let's Encrypt et reçoit l'adresse réelle du visiteur par le
protocole PROXY. Ce n'est ni un VPN ni un tunnel d'administration.

**Coolify ↔ VM** : SSH direct sur le réseau privé (10.10.10.11 → 10.10.10.12 à .15, clé dédiée),
sans tunnel, Cloudflare, Tailscale, WireGuard ni ProxyJump.

### Domaines

Domaine demandé pendant les questions (`uninef.org` par défaut). Chaque nom couvre aussi ses
sous-domaines.

| Domaine | Destination |
|---|---|
| coolify.\<domaine\> | VM 101 (Coolify) |
| proxmox.\<domaine\> | Hôte Proxmox, **réservé aux adresses d'administration** |
| kobo, enketo, kc.\<domaine\> | VM 102 |
| monitoring, redash, lightdash, grist, teable.\<domaine\> | VM 103 |
| observatoire.\<domaine\> | VM 104 |
| test.\<domaine\> | VM 105 |
| tout autre domaine | **refusé** (404 en HTTP, connexion fermée en HTTPS) |

Les domaines d'une VM se règlent dans le 9e champ de `VMS` ([ks5.conf](ks5.conf)) ou pendant
les questions. Les services analytiques exposés doivent être protégés par leur propre
authentification ; PostgreSQL/PostGIS n'est jamais publié (voir [flux entre stacks](#flux-entre-stacks)).

## Ce que fait le script

- **Hôte** : dépôts Proxmox sans abonnement, mises à jour, SSH par clé uniquement, fail2ban,
  pare-feu Proxmox, correctifs de sécurité automatiques, alertes par mail (disque en panne,
  sauvegarde ratée, disques pleins), plafond du cache ZFS, stockage ZFS des VM.
- **Réseau** : réseau privé `10.10.10.0/24` derrière l'hôte. Sur l'IP publique n'entrent que
  **SSH (22), HTTP (80), HTTPS (443) et le ping**.
- **Routeur** : HAProxy aiguille chaque domaine vers sa VM, publie l'interface Proxmox pour les
  seules adresses d'administration, refuse les domaines inconnus.
- **VM** : modèle Ubuntu cloud-init, puis l'unique Coolify (compte administrateur créé d'office)
  et les serveurs qu'il pilote, chacun isolé des autres par son pare-feu ; seuls les flux
  nécessaires entre stacks sont ouverts.
- **Sauvegardes** : quotidienne locale de toutes les VM, et copie vers un stockage hors serveur
  si vous en indiquez un.
- **Contrôles** automatiques à la fin et récapitulatif dans `/root/ks5-resume.txt`.

## Référence KS-5

Catalogue OVH (offre `24sk50`) : Intel Xeon E3-1270 v6, 4 cœurs / 8 threads ; 32 ou 64 Go DDR4
ECC ; disques au choix 2 × 2 To HDD (défaut), 3 × 4 To HDD, 2 × 450 Go NVMe, 2 × 1,2 To NVMe,
3 × 960 Go SSD (RAID matériel) ; 500 Mbit/s ; **pas de console KVM**. Le script détecte le
matériel réel et l'affiche à côté de ces valeurs.

## 1. Commande et installation chez OVH

- **RAM : 64 Go** pour le plan ci-dessus.
- **Disques** : 2 × 2 To HDD suffit en capacité, mais PostgreSQL/PostGIS, Kobo et les outils BI
  sollicités en même temps y seront lents. **2 × 1,2 To NVMe est fortement conseillé** pour les
  bases de données. Dans tous les cas, mesurer la charge réelle (section 7).
- Espace client OVH › Installer : ajouter votre clé SSH (ed25519), modèle **Proxmox VE 9**,
  **RAID 1** sur les deux disques (OVH met la partition de données en ZFS), nom d'hôte définitif
  (par exemple `ks5.mondomaine.org`).
- Repérer le **mode rescue** (Netboot › Rescue) : c'est le seul recours en cas de perte d'accès.

## 2. Préparer

- **Clés SSH** de tous les administrateurs dans `/root/.ssh/authorized_keys` du serveur (le script
  les reporte dans les VM, et les mots de passe SSH vont être refusés).
- **Adresses d'administration** : les IP publiques fixes (ou réseaux) des administrateurs, pour
  l'interface Proxmox. Sans adresse fixe, voir [Proxmox sans adresse fixe](#proxmox-sans-adresse-fixe).
- **DNS** : enregistrements **A** vers l'IP du serveur, pas d'AAAA (sites en IPv4) :
  `coolify`, `proxmox`, puis ceux des applications. Chez Cloudflare, mode « DNS only ».
- **Alertes** : un relais SMTP (Brevo, etc.) évite que les mails du serveur partent en spam.
- **Copie hors serveur** (avant la production) : un Proxmox Backup Server distant, ou un partage
  NFS/CIFS, ajouté dans Datacenter › Storage. Son nom est demandé par le script.

## 3. Lancement

```bash
ssh root@IP_DU_SERVEUR
curl -fsSL https://raw.githubusercontent.com/kv5t/ks5-proxmox-setup/main/ks5-setup.sh | bash
```

Préférer lire le script avant de l'exécuter :

```bash
curl -fsSLO https://raw.githubusercontent.com/kv5t/ks5-proxmox-setup/main/ks5-setup.sh
less ks5-setup.sh
bash ks5-setup.sh
```

Déroulé :

1. **Matériel** : référence KS-5 et valeurs détectées (threads, RAM, type de disques, RAID,
   stockage). Entrée garde la valeur proposée.
2. **Paramètres** : fuseau, mail d'alerte, relais SMTP, port SSH, réseau privé, Ubuntu,
   sauvegardes et copie hors serveur, domaine des sites, adresses de Coolify et de Proxmox,
   adresses d'administration. « - » vide un champ facultatif.
3. **Plan des VM** et budget mémoire / disque / vCPU, modifiable.
4. **Confirmation SSH** : après le durcissement, ouvrir **un second terminal**, se reconnecter,
   puis taper `OK`. Sans confirmation sous 5 minutes, SSH et pare-feu sont restaurés tout seuls,
   même si la session est coupée.
5. Création du modèle Ubuntu, du routeur, des VM, des sauvegardes, puis contrôles.

Durée : 20 à 40 minutes ; redémarrer ensuite si le script l'indique. Le script est relançable :
ce qui existe est conservé. Pour relancer avec les mêmes réponses :

```bash
curl -fsSL https://raw.githubusercontent.com/kv5t/ks5-proxmox-setup/main/ks5-setup.sh | bash -s -- -c /root/ks5-reponses.conf
```

Options : `-p` simulation, `-y` sans questions (valeurs du fichier de paramètres), `-c fichier`
paramètres (modèle commenté : [ks5.conf](ks5.conf)).

## 4. Après l'installation

### 4.1 Contrôle depuis l'extérieur

`nmap -Pn -p- IP_DU_SERVEUR` ne doit montrer que 22, 80 et 443 ; `https://IP_DU_SERVEUR:8006`
ne doit pas répondre. Depuis une adresse **non** autorisée, `https://proxmox.<domaine>` doit être
refusé ; `https://inconnu.<domaine>` aussi.

### 4.2 Proxmox

Ouvrir `https://proxmox.<domaine>` depuis une adresse d'administration (certificat auto-signé de
Proxmox au premier accès). Puis :

1. **TOTP** pour `root@pam` (Datacenter › Permissions › Two Factor) ; idéalement un compte
   nominatif par administrateur, avec TOTP.
2. Certificat Let's Encrypt (le routeur transmet la validation HTTP à l'hôte), en SSH sur l'hôte :

   ```bash
   pvenode acme account register default admin@mondomaine.org   # accepter les conditions
   pvenode config set --acme domains=proxmox.mondomaine.org
   pvenode acme cert order
   ```

3. Vérifier que le mail de test est arrivé (Datacenter › Notifications).

#### Proxmox sans adresse fixe

Sans `ADMIN_ALLOW_FROM`, le script ne publie pas l'interface Proxmox, sauf accord explicite
(`PVE_OPEN_TO_ALL=1`), déconseillé : elle serait alors exposée à tout Internet, protégée
seulement par le mot de passe et le TOTP. Pour changer la liste plus tard : modifier
`ADMIN_ALLOW_FROM` dans `/root/ks5-reponses.conf`, relancer le script avec `-c`.

### 4.3 Coolify : premier accès (amorçage)

Tant que son domaine n'est pas réglé dans Coolify, son proxy ne tourne pas. Le routeur sert donc
d'abord Coolify lui-même, en HTTPS avec un **certificat provisoire** (valeur `boot` dans la table
des domaines), réservé aux adresses d'administration si elles sont indiquées.

1. Ouvrir `https://coolify.<domaine>`. Le navigateur signale un certificat inconnu : comparer son
   empreinte SHA-256 avec celle de `/root/ks5-resume.txt`, puis accepter.
2. Se connecter avec le compte créé à l'installation : `cat /root/ks5-keys/coolify-admin.txt`
   (sur l'hôte). **Changer ce mot de passe** et activer la 2FA (profil). Sans mail
   d'administrateur fourni au script (ou si Coolify a refusé ce compte à l'installation), la
   page d'inscription s'affiche : créer le compte tout de suite.
3. Settings : désactiver les inscriptions.
4. Servers › localhost › Proxy › Configuration : ajouter à la liste `command` de Traefik,
   enregistrer :

   ```yaml
   - '--entrypoints.http.proxyprotocol.trustedips=10.10.10.10/32'
   - '--entrypoints.https.proxyprotocol.trustedips=10.10.10.10/32'
   ```

5. Settings › Instance Domain : `https://coolify.<domaine>`, enregistrer ; démarrer le proxy de
   localhost s'il ne l'est pas. Le certificat Let's Encrypt est obtenu via le routeur.
6. Basculer le routeur vers Coolify, sur l'hôte :

   ```bash
   pct exec 100 -- sed -i 's/ boot$/ 101/' /etc/haproxy/domaines.map
   pct exec 100 -- systemctl reload haproxy
   ```

   Recharger `https://coolify.<domaine>` : certificat Let's Encrypt, plus d'avertissement.
   En cas de problème, remettre `boot` et recharger.

### 4.4 Coolify : serveurs des stacks

1. Keys & Tokens › Private Keys : coller `cat /root/ks5-keys/coolify_ed25519` (sur l'hôte).
2. Servers › Add, pour chaque VM : utilisateur `root`, port 22, cette clé, adresses
   10.10.10.12 (kobo), .13 (data-bi), .14 (observatoire), .15 (recette). Valider : Coolify y
   installe Docker.
3. **Pour chacun de ces serveurs**, Proxy › Configuration : mêmes deux lignes `trustedips` qu'en
   4.3, enregistrer et redémarrer le proxy. Sans elles, les sites du serveur ne répondent pas ;
   elles transmettent aussi l'adresse réelle des visiteurs (`X-Forwarded-For`).
4. Déployer chaque stack sur **son** serveur, avec des domaines en `https://` :
   - **kobo** : le Compose Kobo validé, en ressource *Docker Compose*, tel quel (mêmes images et
     dépendances), domaines `kobo`, `enketo`, `kc` ;
   - **data-bi** : PostgreSQL/PostGIS, Metabase, Redash, Lightdash, Grist, Teable ;
   - **observatoire** : l'application Django/Wagtail.

### Flux entre stacks

Les VM sont isolées les unes des autres. Seuls les flux nécessaires sont ouverts :

| Flux | Comment |
|---|---|
| observatoire (104) → PostgreSQL/PostGIS de data-bi (103), port 5432 | Règle de pare-feu créée par le script (`VM_FW_EXTRA`). Dans Coolify, publier le port 5432 de la base ; seule la VM 104 peut le joindre. Django utilise `10.10.10.13:5432`. |
| synchronisation data-bi (103) → API Kobo (102) | Par `https://kobo.<domaine>` : le trafic passe par le routeur, le certificat reste valide, aucune règle à ajouter. |

Autre flux : l'ajouter à `VM_FW_EXTRA` avant la création de la VM (`@ID` = adresse de la VM), ou
ensuite dans l'interface Proxmox (VM › Firewall), sans désactiver l'isolation.

### 4.5 Routeur : ajouter ou déplacer un domaine

```bash
pct exec 100 -- nano /etc/haproxy/domaines.map
pct exec 100 -- systemctl reload haproxy
```

Une ligne par route, `.domaine ID_DE_LA_VM` (le point couvre aussi les sous-domaines), sans
commentaire en fin de ligne. Un domaine absent est refusé.

### 4.6 Accès SSH

- Hôte : `ssh root@IP_DU_SERVEUR` (clé uniquement).
- Une VM : depuis l'hôte, `ssh -i /root/ks5-keys/coolify_ed25519 root@10.10.10.13`, ou le
  Terminal de Coolify. Sans réseau : `qm terminal 103`.

## 5. Sauvegardes

- **Locale** (`ks5-daily`) : 3 quotidiennes et 2 hebdomadaires de toutes les VM, **sur les
  disques du serveur** : utile contre une erreur, pas contre une panne du serveur.
- **Hors serveur** (`ks5-distant`) : si `BACKUP_REMOTE_STORAGE` désigne un stockage distant
  (Proxmox Backup Server conseillé), copie quotidienne gardant 7 jours, 4 semaines, 6 mois.
  **Indispensable avant la production.** Sur un PBS, programmer aussi une tâche de vérification
  (*Verify Jobs*).
- Compléter par les sauvegardes S3 des bases dans Coolify (PostgreSQL, bases de Kobo).
- **Tester une restauration chaque trimestre** : `qmrestore <archive> 900 --unique 1`, démarrer
  la VM 900 sans réseau, vérifier les données, puis `qm destroy 900`.

## 6. Exploitation

| Quand | Action |
|---|---|
| Chaque mois | `apt update && apt full-upgrade` sur l'hôte, `reboot` si nouveau noyau |
| Chaque mois | `zpool status`, lecture des mails d'alerte, mises à jour de Coolify |
| Chaque trimestre | Essai de restauration (section 5) |
| Avant une opération risquée | `qm snapshot <id> avant-maj` (retour : `qm rollback <id> avant-maj`) |

```bash
qm list ; pct list                        # état des VM et conteneurs
qm terminal 103                           # console série d'une VM
qm guest exec 103 -- uptime               # commande dans une VM sans réseau
pct exec 100 -- systemctl status haproxy  # routeur
pve-firewall status ; fail2ban-client status sshd ; zpool status -x
```

**Perte de l'accès SSH** : mode rescue, puis
`mount /dev/md3 /mnt` (partition système, vérifier avec `lsblk`),
`ln -sf /dev/null /mnt/etc/systemd/system/pve-firewall.service`,
`rm -f /mnt/etc/ssh/sshd_config.d/00-ks5-hardening.conf`, redémarrage normal, correction, puis
`rm /etc/systemd/system/pve-firewall.service && systemctl daemon-reload`.

## 7. Validation avant la production

À faire sur le KS-5 réel (ou un serveur équivalent), **avant d'y mettre des données** :

- [ ] Le script se termine avec « Tous les contrôles sont passés » ; relancé, il ne change rien.
- [ ] `nmap` externe : seuls 22, 80, 443 (section 4.1).
- [ ] Proxmox : accessible depuis une adresse d'administration, refusé depuis une autre (4G).
- [ ] Coolify : amorçage, bascule `boot` → `101`, certificat Let's Encrypt valide.
- [ ] Chaque serveur validé dans Coolify ; un site de test par VM répond en HTTPS avec
      l'adresse réelle du visiteur dans les journaux (protocole PROXY).
- [ ] Domaine inconnu refusé ; `http://` redirigé vers `https://`.
- [ ] Isolation : depuis la VM 105, `nc -zv 10.10.10.13 5432` échoue ; depuis la 104, il réussit.
- [ ] Kobo : collecte d'un formulaire via Enketo, synchronisation depuis data-bi.
- [ ] Charge : formulaires Kobo, requêtes BI et observatoire en parallèle ; surveiller
      `iostat -x 5` sur l'hôte (attente disque) et la mémoire des VM.
- [ ] Sauvegarde hors serveur réussie et restauration testée (section 5).
- [ ] Redémarrage complet de l'hôte : toutes les VM et tous les sites reviennent seuls.

## Sécurité

Choix et protections détaillés dans [SECURITE.md](SECURITE.md).
