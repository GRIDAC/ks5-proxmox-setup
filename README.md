# ks5-proxmox-setup

Un serveur OVH Kimsufi **KS-5** sous **Proxmox VE**, prêt pour Coolify, KoboToolbox et des
applications web, en une commande. Interactif : les valeurs du KS-5 sont proposées par défaut
(Entrée pour garder), modifiables si le serveur est différent. Sécurisé sans être compliqué.

```bash
curl -fsSL https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh | bash
```

À lancer **en root sur le serveur**, depuis une session SSH interactive (`ssh root@IP`).
Simulation sans aucune modification : `… | bash -s -- -p`.

## Ce que fait le script

- **Hôte** : dépôts Proxmox sans abonnement, mises à jour, SSH par clé uniquement, fail2ban,
  pare-feu Proxmox, correctifs de sécurité automatiques, alertes par mail (disque en panne,
  sauvegarde ratée, disques pleins), plafond du cache ZFS, stockage ZFS des VM.
- **Réseau** : réseau privé `10.10.10.0/24` derrière l'hôte. Sur l'IP publique n'entrent que
  **SSH (22), HTTP (80), HTTPS (443) et le ping**.
- **Routeur web** : un petit conteneur HAProxy reçoit 80/443 et envoie chaque domaine vers sa VM
  **sans déchiffrer** ; chaque VM gère ses certificats Let's Encrypt et voit l'adresse réelle
  des visiteurs.
- **VM** : modèle Ubuntu cloud-init, puis Coolify, Kobo et les serveurs pilotés par Coolify, chacune
  isolée des autres par son pare-feu.
- **Sauvegarde** quotidienne locale de toutes les VM.
- **Contrôles** automatiques à la fin et récapitulatif dans `/root/ks5-resume.txt`.

| ID | Nom | Rôle | Adresse | vCPU | RAM | Disque |
|---|---|---|---|---|---|---|
| — | Hôte Proxmox | Hyperviseur, NAT, pare-feu | 10.10.10.1 | 8 threads | 64 Go | 2 × 2 To, RAID 1 ZFS |
| 100 | entree (LXC) | Routeur web HAProxy | 10.10.10.10 | 1 | 0,5 Go | 8 Go |
| 101 | coolify | Panneau Coolify | 10.10.10.11 | 2 | 4 Go | 50 Go |
| 102 | kobo | KoboToolbox (kobo-install) | 10.10.10.12 | 4 | 12 Go | 300 Go |
| 103 | uninef-prod | Serveur Coolify de production | 10.10.10.13 | 6 | 18 Go | 500 Go |
| 105 | perso-tests | Serveur Coolify de recette et d'essais | 10.10.10.15 | 4 | 10 Go | 250 Go |

Le plan s'adapte au matériel : sur 32 Go ou 2 × 450 Go NVMe, le script propose de réduire les VM,
de les modifier une par une, ou d'en ajouter.

**Routes web par défaut** (domaine demandé pendant les questions, `uninef.org` par défaut) :

| Domaine | VM |
|---|---|
| kobo / ee / kc.\<domaine\> et leurs sous-domaines | kobo |
| test.\<domaine\> et `*.test.<domaine>` | perso-tests |
| tout autre domaine | uninef-prod |

## Référence KS-5

Catalogue OVH (offre `24sk50`) : Intel Xeon E3-1270 v6, 4 cœurs / 8 threads ; 32 ou 64 Go DDR4
ECC ; disques au choix 2 × 2 To HDD (défaut), 3 × 4 To HDD, 2 × 450 Go NVMe, 2 × 1,2 To NVMe,
3 × 960 Go SSD (RAID matériel) ; 500 Mbit/s ; **pas de console KVM**. Le script détecte le
matériel réel et l'affiche à côté de ces valeurs.

## 1. Commande et installation chez OVH

- **RAM : 64 Go** pour le plan ci-dessus. **Disques** : 2 × 2 To HDD suffit en capacité ;
  2 × 1,2 To NVMe est nettement plus rapide pour les bases de données.
- Espace client OVH › Installer : ajouter votre clé SSH (ed25519), modèle **Proxmox VE 9**,
  **RAID 1** sur les deux disques (OVH met la partition de données en ZFS), nom d'hôte définitif
  (par exemple `ks5.mondomaine.org`).
- Repérer le **mode rescue** (Netboot › Rescue) : c'est le seul recours en cas de perte d'accès.

## 2. Préparer

- **Clés SSH** de tous les administrateurs dans `/root/.ssh/authorized_keys` du serveur (le script
  les reporte dans les VM, et les mots de passe SSH vont être refusés).
- **DNS** : enregistrements **A** vers l'IP du serveur, pas d'AAAA (sites en IPv4). Chez
  Cloudflare, mode « DNS only ». Pour les sites Coolify, attendre l'étape 4.4.
- **Alertes** : un relais SMTP (Brevo, etc.) évite que les mails du serveur partent en spam.

## 3. Lancement

```bash
ssh root@IP_DU_SERVEUR
curl -fsSL https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh | bash
```

Préférer lire le script avant de l'exécuter :

```bash
curl -fsSLO https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh
less ks5-setup.sh
bash ks5-setup.sh
```

Déroulé :

1. **Matériel** : référence KS-5 et valeurs détectées (threads, RAM, type de disques, RAID,
   stockage). Entrée garde la valeur proposée.
2. **Paramètres** : fuseau, mail d'alerte, relais SMTP, port SSH, réseau privé, Ubuntu,
   sauvegardes, domaine des sites. « - » vide un champ facultatif.
3. **Plan des VM** et budget mémoire / disque / vCPU, modifiable.
4. **Confirmation SSH** : après le durcissement, ouvrir **un second terminal**, se reconnecter,
   puis taper `OK`. Sans confirmation sous 5 minutes, SSH et pare-feu sont restaurés tout seuls,
   même si la session est coupée.
5. Création du modèle Ubuntu, du routeur web, des VM, de la sauvegarde, puis contrôles.

Durée : 20 à 40 minutes ; redémarrer ensuite si le script l'indique. Le script est relançable :
ce qui existe est conservé. Pour relancer avec les mêmes réponses :

```bash
curl -fsSL https://raw.githubusercontent.com/GRIDAC/ks5-proxmox-setup/main/ks5-setup.sh | bash -s -- -c /root/ks5-reponses.conf
```

Options : `-p` simulation, `-y` sans questions (valeurs du fichier de paramètres), `-c fichier`
paramètres (modèle commenté : [ks5.conf](ks5.conf)).

## 4. Après l'installation

### 4.1 Contrôle depuis l'extérieur

`nmap -Pn -p- IP_DU_SERVEUR` ne doit montrer que 22, 80 et 443 ; `https://IP_DU_SERVEUR:8006`
ne doit pas répondre.

### 4.2 Administration par tunnel SSH

L'interface Proxmox et Coolify ne sont pas exposées. Sur le poste de chaque administrateur,
dans `~/.ssh/config` :

```
Host ks5 ks5-ssh
    HostName IP_DU_SERVEUR
    User root
Host ks5
    LocalForward 8006 10.10.10.1:8006
    LocalForward 8000 10.10.10.11:8000
    LocalForward 6001 10.10.10.11:6001
    LocalForward 6002 10.10.10.11:6002

Host ks5-kobo ks5-prod ks5-tests
    User ubuntu
    ProxyJump ks5-ssh
Host ks5-kobo
    HostName 10.10.10.12
Host ks5-prod
    HostName 10.10.10.13
Host ks5-tests
    HostName 10.10.10.15
```

`ssh ks5` puis, tant que la session est ouverte : Proxmox sur `https://localhost:8006`, Coolify
sur `http://localhost:8000`. Une VM : `ssh ks5-prod`.

### 4.3 Proxmox

TOTP pour `root@pam` (Datacenter › Permissions › Two Factor) ; idéalement un compte nominatif par
administrateur. Vérifier que le mail de test est arrivé (Datacenter › Notifications).

### 4.4 Coolify

1. `ssh ks5`, ouvrir `http://localhost:8000` et **créer le compte administrateur tout de suite**.
2. Settings : désactiver les inscriptions, pas de domaine public pour l'instance.
3. Keys & Tokens › Private Keys : coller `cat /root/ks5-keys/coolify_ed25519` (sur l'hôte).
4. Servers › Add (utilisateur `root`, port 22, cette clé) : 10.10.10.13 et 10.10.10.15. Valider.
5. **Pour chacun de ces serveurs**, Proxy › Configuration : ajouter à la liste `command` de
   Traefik, enregistrer et redémarrer le proxy :

   ```yaml
   - '--entrypoints.http.proxyprotocol.trustedips=10.10.10.10/32'
   - '--entrypoints.https.proxyprotocol.trustedips=10.10.10.10/32'
   ```

   Sans ces lignes, les sites de ce serveur ne répondent pas ; elles transmettent aussi l'adresse
   réelle des visiteurs (en-tête `X-Forwarded-For` côté application).
6. Créer les enregistrements DNS, puis déployer avec des domaines en `https://` : Let's Encrypt
   fonctionne directement.

### 4.5 Routeur web : ajouter ou déplacer un domaine

```bash
pct exec 100 -- nano /etc/haproxy/domaines.map
pct exec 100 -- systemctl reload haproxy
```

Une ligne par route, `.domaine ID_DE_LA_VM` (le point couvre aussi les sous-domaines), sans
commentaire en fin de ligne. Un domaine absent va à la VM par défaut.

### 4.6 KoboToolbox

```bash
ssh ks5-kobo
cd /opt/kobo-install && sudo python3 run.py
```

Installation serveur, sous-domaines `kobo`, `ee`, `kc`, **sans reverse proxy en amont**, HTTPS par
Let's Encrypt.

## 5. Sauvegardes

La tâche `ks5-daily` garde 3 sauvegardes quotidiennes et 2 hebdomadaires de toutes les VM, **sur
les disques du serveur** : utile contre une erreur, pas contre une panne du serveur. Ajouter une
copie hors serveur avant la production (sauvegardes S3 des bases dans Coolify, sauvegardes de
kobo-install) et tester une restauration chaque trimestre.

## 6. Exploitation

| Quand | Action |
|---|---|
| Chaque mois | `apt update && apt full-upgrade` sur l'hôte, `reboot` si nouveau noyau |
| Chaque mois | `zpool status`, lecture des mails d'alerte |
| Avant une opération risquée | `qm snapshot <id> avant-maj` (retour : `qm rollback <id> avant-maj`) |

```bash
qm list ; pct list                        # état des VM et conteneurs
qm terminal 103                           # console série d'une VM
qm guest exec 103 -- uptime               # commande dans une VM sans réseau
pct exec 100 -- systemctl status haproxy  # routeur web
pve-firewall status ; fail2ban-client status sshd ; zpool status -x
```

**Perte de l'accès SSH** : mode rescue, puis
`mount /dev/md3 /mnt` (partition système, vérifier avec `lsblk`),
`ln -sf /dev/null /mnt/etc/systemd/system/pve-firewall.service`,
`rm -f /mnt/etc/ssh/sshd_config.d/00-ks5-hardening.conf`, redémarrage normal, correction, puis
`rm /etc/systemd/system/pve-firewall.service && systemctl daemon-reload`.

## Sécurité

Choix et protections détaillés dans [SECURITE.md](SECURITE.md).
