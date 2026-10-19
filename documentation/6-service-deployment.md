This is a DevOps project inspired from [roadmap.sh: Node.js Service Deployment](https://roadmap.sh/projects/nodejs-service-deployment)

## Node.js Service Deployment
*The goal of this project is to deploy a Node.js service to a remote server with Ansible, and then automate the deployment with GitHub Actions.*

When it is finished:

```
I edit app/server.js ──git push──> GitHub Actions ──deploys──> app server
A visitor opens http://<app-public-ip>/  ──>  "Hello, world!"
```

| Step | What it means | Roadmap requirement |
|---|---|---|
| 1. Write the service, run it locally | A small program in `app/`, tested on my PC | A simple Node.js service with a `/` route |
| 2. Use Ansible to deploy it | Install Node.js on the server, fetch the code from GitHub, keep it running | A role called `app` that clones the repo, installs dependencies and starts the application |
| 3. Open port 80, deploy by hand | Let the internet reach the server on the web port, run the playbook myself | Run the playbook with `--tags app`, reach the app by public address |
| 4. GitHub Actions | GitHub runs the deployment on every push | Automate the deployment with GitHub Actions |

## Design decisions

Beyond the bare roadmap:

- **The app runs as a systemd service, under its own account.** A program started by hand in an SSH session belongs to that login session and can be stopped when the session ends, which is exactly what happens to every Ansible task. It also would not survive a reboot or restart after a crash. systemd runs it as part of the system, the same way it runs nginx and fail2ban. The dedicated account (no password, no login, no `sudo`) limits the damage if the app ever had a flaw, the same idea as nginx running as `www-data`.
- **nginx stays in front.** The roadmap asks for port 80. Node listening there directly would have to run as root. Instead Node listens on port 3000 on the server only, and the existing nginx forwards port 80 to it.
- **The deploy job gets its own narrow identity.** GitHub's runner will come in through the VPN as a new client and log in as a `deploy` account that can only update and restart the app. Putting the `ansible` key and the vault password into GitHub would give GitHub root on both servers.
- **An exact version is deployed.** The workflow deploys the specific commit that was pushed, and dependencies are installed with `npm ci`, which uses the exact versions in the lock file.
- **The deploy is checked.** A `/health` route, called by the workflow at the end, so a broken deploy fails visibly.
- **Express**, a library for building web servers in Node. Node's built-in `http` module would be enough for one route, but the later phases (the Todo API, a Basic Auth route) are built on Express, and it gives the "install the dependencies" step something real to do.

## 1. The service, run locally

In a new `app/` folder at the repo root:

```bash
cd app
npm init -y           # creates package.json
npm install express   # downloads Express into node_modules/, records it in package.json, creates package-lock.json
```

`package.json` after editing:

```json
{
  "name": "app",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1",
    "start": "node server.js"
  },
  "type": "commonjs",
  "dependencies": {
    "express": "^5.3.0"
  }
}
```

- `main` was changed from the generated `index.js` to the real file name.
- `start` lets the app be run with `npm start`.
- `"type": "commonjs"` decides how libraries are loaded: `require('express')`. With `"type": "module"` it would be `import express from 'express'`. The code has to match.
- `package-lock.json` records the exact versions installed and is committed, so the server installs the same ones. `node_modules/` is not committed. `.gitignore` already excludes it.

`app/server.js`:

```js
const express = require('express');
const app = express();
const port = process.env.PORT || 3000;
const host = process.env.HOST || '127.0.0.1';

app.get('/', (req, res) => {
  res.send('Hello, World!');
});

app.listen(port, host, () => {
  console.log(`Server is running on http://${host}:${port}`);
});
```

- `app.get('/', ...)` is one route: for a request to `/`, send this text.
- `process.env.PORT` and `process.env.HOST` read environment variables, and `||` falls back to the value after it when the variable is not set. The values can then change without touching the code, which the systemd unit and later a container will use.
- `127.0.0.1` means only programs on the same machine can connect. On the server that is exactly nginx's position. Without a host, Express listens on every network interface, and port 3000 would be protected only by the firewall.

```bash
npm start
curl localhost:3000    # Hello, World!
```

## 2a. Closing the `ubuntu` account gap

Left over from the bastion phase. AWS creates an `ubuntu` account on every new instance, with my personal key and `sudo` without a password. It was only needed for the first run on a fresh server, but it stayed on both servers. On the bastion it is not enrolled for MFA, so because of `nullok` it got in with the key alone and became root with no code, undercutting the MFA set up for `dev`.

Its passwordless `sudo` comes from one rule:

```bash
sudo ls /etc/sudoers.d/                          # 90-cloud-init-users  README
sudo cat /etc/sudoers.d/90-cloud-init-users      # ubuntu ALL=(ALL) NOPASSWD:ALL
```

Two tasks at the end of `roles/ssh/tasks/main.yml`:

```yaml
- name: Remove the default ubuntu account
  ansible.builtin.user:
    name: ubuntu
    state: absent
    remove: true
  when: ansible_user != 'ubuntu'

- name: Remove the ubuntu sudo rule
  ansible.builtin.file:
    path: /etc/sudoers.d/90-cloud-init-users
    state: absent
  when: ansible_user != 'ubuntu'
```

- `state: absent` deletes the account. `remove: true` also deletes its home folder, including its key file.
- `ansible_user` is the account Ansible logged in as. On a brand-new server the first run logs in as `ubuntu` (`-e ansible_user=ubuntu`), because no other account exists yet. An account cannot be deleted while it is in use, and that run depends on its passwordless `sudo`. The condition skips both tasks on that run. The next normal run, as `ansible`, deletes them.

| Run on a new server | Logs in as | `ubuntu` |
|---|---|---|
| 1. Bootstrap | `ubuntu` | Kept, the tasks are skipped |
| 2. Next normal run | `ansible` | Deleted, with its sudo rule |
| Later runs | `ansible` | Nothing to do, `ok` |

```bash
ansible-playbook -i inventory.ini setup.yml --tags ssh
# bastion_01: ok=13, changed=2
# my_host_01: ok=8, changed=2, skipped=5 (the MFA tasks, bastion only)

ssh -i ~/.ssh/devops-playground ubuntu@<bastion-public-ip>    # refused
ssh bastion                                                  # still works as dev, with the code
```

## 2b. Node.js, the app account and the code on the server

The `app` role used to upload the static site from `roles/app/files/`. Its tasks were replaced, and the `files/` folder deleted.

**Why the server clones from GitHub.** Version control keeps the code on my PC and on GitHub. The server is a third machine and has none of it. There are two ways to get code onto a server: Ansible uploads it from my PC (as the static site was), or the server downloads it from GitHub. The second is what the roadmap asks for, and it means the server gets exactly what was pushed, not whatever is on my PC at that moment, including uncommitted changes. It is also what the GitHub Actions step needs, since my PC is not involved there. On the server git is only a download tool. It never commits or pushes.

```
My PC  ──git push──>  GitHub  ──git clone (by the server)──>  App server
```

`roles/app/defaults/main.yml`:

```yaml
app_repo: https://github.com/Tao-68/aws-eks-gitops-deployment-playground.git
app_version: main
app_user: nodeapp
app_root: /opt/playground
app_dir: "{{ app_root }}/app"
app_port: 3000
```

`app_root` is where the whole repo is cloned. `app_dir` is the Node app inside it, because the code lives in the repo's `app/` folder.

`roles/app/tasks/main.yml`:

```yaml
- name: Install Node.js and npm
  ansible.builtin.apt:
    name:
      - nodejs
      - npm
    state: present

- name: Create the app account
  ansible.builtin.user:
    name: "{{ app_user }}"
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/{{ app_user }}
    create_home: true

- name: Create the app folder
  ansible.builtin.file:
    path: "{{ app_root }}"
    state: directory
    owner: "{{ app_user }}"
    group: "{{ app_user }}"
    mode: '0755'

- name: Get the code from GitHub
  ansible.builtin.git:
    repo: "{{ app_repo }}"
    dest: "{{ app_root }}"
    version: "{{ app_version }}"
  become_user: "{{ app_user }}"
  register: app_clone

- name: Check whether dependencies are installed
  ansible.builtin.stat:
    path: "{{ app_dir }}/node_modules"
  register: app_modules

- name: Install dependencies
  ansible.builtin.command: npm ci --omit=dev
  args:
    chdir: "{{ app_dir }}"
  become_user: "{{ app_user }}"
  when: app_clone.changed or not app_modules.stat.exists
```

**The account.** `system: true` makes it a service account, and `shell: /usr/sbin/nologin` means nobody can log in as it. It still gets a home folder, because npm keeps a cache there.

**The last three tasks, compared with doing it by hand:**

| Task | By hand on the server | Notes |
|---|---|---|
| Get the code from GitHub | `sudo -u nodeapp git clone <repo> /opt/playground` | Clones on the first run, updates to the latest commit later. `become_user` runs this one task as `nodeapp` instead of root, so the files belong to the app's account. `register: app_clone` stores the result. `app_clone.changed` is true if new code arrived. |
| Check whether dependencies are installed | `ls /opt/playground/app/node_modules` | `stat` only looks and never changes anything. `app_modules.stat.exists` says whether the folder is there. |
| Install dependencies | `cd /opt/playground/app && sudo -u nodeapp npm ci --omit=dev` | `chdir` is the `cd`. `when` runs it only if new code arrived or `node_modules` is missing. |

`node_modules` is never in GitHub, because `.gitignore` excludes it, so a fresh clone has the code but not Express. That does not make the check always false: `.gitignore` only decides what goes into GitHub and never deletes files on a machine. Once the install task has built `node_modules` on the server, it stays there, and later `git` updates leave ignored files alone.

| Situation | Get the code | `node_modules` found | Install |
|---|---|---|---|
| First run | Clones, `changed` | No | Runs |
| Nothing new on GitHub | `ok` | Yes | Skipped |
| A change to `app/` was pushed | Pulls it, `changed` | Yes | Runs, in case dependencies changed |

**`npm ci`, not `npm install express`.**

| Command | What it does | Where it belongs |
|---|---|---|
| `npm install express` | Adds a dependency, picking the newest matching version, and writes it into `package.json` and `package-lock.json` | My PC, while developing |
| `npm ci` | Installs exactly the versions in `package-lock.json`, deletes any existing `node_modules` first, never changes either file | Servers and CI |

What the app needs was decided on my PC and recorded in `package.json`, so the server should not decide it again. `package.json` allows `"^5.3.0"`, meaning any newer 5.x, and a plain `npm install` months later could pick a version I never tested. `--omit=dev` skips tools only needed while developing. There are none yet.

```bash
ansible-playbook -i inventory.ini setup.yml --limit app --tags app
# First run:  ok=8, changed=5
# Second run: ok=7, changed=0, skipped=1 (the install task)
```

The first run printed a warning that `/var/lib/nodeapp/.ansible/tmp` was created with mode `0700`. That is Ansible's own working folder for the account it acts as. It belongs to `nodeapp` and is only used when acting as `nodeapp`, so the warning does not apply here.

The app started by hand on the server, once:

```bash
node -v                                                   # v22.22.1
cd /opt/playground/app && sudo -u nodeapp node server.js  # Server is running on http://127.0.0.1:3000
curl localhost:3000                                       # from a second session: Hello, World!
```

Started like this, the app belongs to my login session. Step 2c makes it a service.

## 2c. The app as a service, behind nginx

**The port, shared by two roles.** The `app` role needs `app_port` (the app listens on it) and so does the `nginx` role (it forwards to it). It moved out of `roles/app/defaults/main.yml` into `group_vars/app/vars.yml`, where both roles see it for the app server:

```yaml
app_port: 3000
```

**The unit file**, `roles/app/templates/playground-app.service.j2`:

```ini
[Unit]
Description=Playground Node.js app
After=network.target

[Service]
User={{ app_user }}
WorkingDirectory={{ app_dir }}
Environment=PORT={{ app_port }}
Environment=HOST=127.0.0.1
ExecStart=/usr/bin/node server.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

- **systemd** is the first program the kernel starts at boot (process 1). It starts every other service, restarts them after a crash and collects their logs (`journalctl -u <name>`). Each thing it manages is a unit: `.service` (a program), `.target` (a milestone during boot), `.timer` (a schedule). **Boot** is every time the OS starts from scratch: when the instance is created, stopped and started, or rebooted. Nobody is there to start the app by hand, so systemd does it.
- `After=network.target` starts it once networking is up. At boot systemd starts many units in parallel, and targets are the milestones that order them. `network.target` means the network services have been started. `After=` only sets the order, and it does not wait for an IP address (that is `network-online.target`). Enough here, because the app listens on `127.0.0.1`, which exists from the start.
- The `Environment` lines set the two variables `server.js` reads.
- `Restart=on-failure` brings it back after a crash. `WantedBy=multi-user.target` makes it start at boot.
- `User` runs it as `nodeapp`.

**Three new tasks in `roles/app/tasks/main.yml`:**

```yaml
- name: Deploy the unit file for the app
  ansible.builtin.template:
    src: playground-app.service.j2
    dest: /etc/systemd/system/playground-app.service
    mode: '0644'
  notify: Restart app

- name: Start and enable the app service
  ansible.builtin.systemd:
    name: playground-app
    state: started
    enabled: true
    daemon_reload: true

- name: Remove old static site files
  ansible.builtin.file:
    path: /var/www/static-site
    state: absent
```

`notify: Restart app` was also added to "Get the code from GitHub" and "Install dependencies", so new code or new dependencies restart the app. `roles/app/handlers/main.yml`:

```yaml
- name: Restart app
  ansible.builtin.systemd:
    name: "playground-app"
    state: restarted
    daemon_reload: yes
```

**What `daemon_reload` is for.** There are two copies of a unit: the file on disk, and systemd's copy in memory. The template task always writes the file, so the file is never out of date. But systemd reads unit files into memory only at boot or when told to with `systemctl daemon-reload`. It does not watch the folder. Without a reload after the template changes (a new port, for example), a restart would still use the old definition from memory. It is the same warning the upgrade showed in Project 1: "The unit file ... changed on disk. Run 'systemctl daemon-reload'."

**nginx forwards to the app.** In `roles/nginx/templates/nginx.conf.j2` the `root`, `index` and `try_files` lines were replaced:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:{{ app_port }};
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

- `proxy_pass` sends each request on to the app. This makes nginx a **reverse proxy**: it receives the visitor's request on port 80, passes it to `node server.js` on `127.0.0.1:3000`, and sends the app's answer back. The switch was needed because the content changed type. The static site was finished HTML files, which nginx can send itself (`root /var/www/static-site;`). The Node app builds each answer in a running program, and nginx cannot run JavaScript. nginx stays in front because ports below 1024 need root, it is built for facing the internet, it can route several apps behind one entry point, and HTTPS can later be added there once for all of them.
- Behind nginx, every request reaches the app from `127.0.0.1`. `X-Forwarded-For` attaches the visitor's real address as a header, for example `X-Forwarded-For: 203.0.113.5`. `$proxy_add_x_forwarded_for` takes any value the request already had from earlier proxies and appends the visitor's address. The app does not read it yet. It is the standard line for a reverse proxy.
- `Host` passes on the name the visitor typed, which the app would otherwise see as `127.0.0.1:3000`.
- `server_name _;` is still right. `_` is not a keyword, just a name no real hostname matches. This is the only `server` block on port 80, so nginx sends every request to it.

```bash
ansible-playbook -i inventory.ini setup.yml --limit app --tags nginx,app

systemctl status playground-app    # active (running), enabled
curl localhost                     # Hello, World!  (port 80: nginx, then the app)
```

The app now runs the way nginx does: as part of the system, not as part of a login.

Proof that it is a real service: after `sudo reboot` on the app server, and a few minutes' wait, `systemctl status playground-app` showed it running again and `curl localhost` answered, with nobody having started it.

**Static to dynamic.** In Project 3 nginx answered every request itself, by sending a file already on disk (`index.html`). Now nginx passes each request to the Node app, and the app's code builds the answer each time. The text is still fixed, so from outside it looks the same, but routes whose answers depend on data, such as `/health` or the later Todo API, are only possible this way. The old site's files are no longer used.

## 3. Port 80 open to the internet

Two layers blocked port 80: the security group in AWS and UFW on the server. Both needed a rule.

Security group, in `iac/security.tf`, on the app server's group:

```hcl
resource "aws_vpc_security_group_ingress_rule" "allow_inbound_http" {
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = aws_security_group.this.id
}
```

`server_public_ip` was added to `outputs.tf`, to find the address for testing.

UFW, as a task in the `nginx` role. nginx is what listens on port 80, so the rule belongs with it: only servers that run nginx get it, and the bastion stays closed.

```yaml
- name: Allow HTTP
  community.general.ufw:
    rule: allow
    port: 80
    proto: tcp
```

```bash
tofu plan     # 1 to add
tofu apply
ansible-playbook -i inventory.ini setup.yml --limit app --tags nginx
```

From outside, on WSL:

```bash
curl http://<app-public-ip>/              # Hello, World!
curl -m 5 http://<app-public-ip>:3000/    # Connection timed out
```

Port 3000 has to stay unreachable from outside. The app listens on `127.0.0.1` only, and no rule opens 3000, so only nginx on the same machine can talk to it.

Two limits: it is plain HTTP, so traffic is not encrypted (HTTPS needs a domain name for its certificate), and the public address changes if the instance is stopped and started. A reboot keeps it.

## 4. GitHub Actions

### Which roadmap option

The roadmap offers two options: run the playbook in GitHub Actions, or connect over SSH and deploy. This is the SSH option, adapted:

```
GitHub runner ══VPN══> bastion ──> app server: ssh deploy@<app-private-ip> "sudo deploy-playground-app <commit>"
```

- **No rsync.** The server already fetches code from GitHub itself, so the runner only says which commit.
- **Plain `ssh`, no third-party actions** such as `appleboy/ssh-action` or `webfactory/ssh-agent`. They work, but every action used gets to handle the deploy key, and the runner already has `ssh`.

**Why not run the playbook in GitHub Actions.** GitHub would need the `ansible` key (login to both servers, exempt from the MFA code), the vault password (all `sudo` passwords and my home address) and the inventory (the servers' addresses, deliberately kept out of the repo). Together that is root on both servers, held outside my control. With the SSH option, a leaked deploy key can only redeploy a commit that already exists in the repo.

The trade-off: the playbook would stay the single description of how the app is deployed. Here the deploy script and the `app` role both know how to update the app, so a change in one has to be mirrored in the other.

### 4a. The deploy account and its one command

**A health route** in `app/server.js`, so a deploy can be checked:

```js
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});
```

The server never sees files on my PC. It only gets what was pushed to GitHub and then fetched by the server, so the route had to be tested locally (`npm start` in one terminal, `curl localhost:3000/health` in another), committed and pushed before the server could have it. Before that, `curl localhost:3000/health` on the server returned Express's "Cannot GET /health" page, meaning the app was running but had no such route.

**A key pair for the deploy job**, on WSL:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github-deploy -N ""
```

`-N ""` sets an empty passphrase, because GitHub's runner cannot type one. Its protection comes from elsewhere: GitHub stores it as an encrypted secret, and on the server it only opens an account that can run one command. The public half goes into `group_vars/app/vars.yml` as `deploy_public_key`.

**The deploy command**, `roles/app/templates/deploy-playground-app.j2`:

```bash
#!/bin/bash
set -euo pipefail

commit="${1:-}"
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: deploy-playground-app <40-character commit id>" >&2
  exit 1
fi

cd {{ app_root }}
runuser -u {{ app_user }} -- git fetch --quiet origin
runuser -u {{ app_user }} -- git checkout --quiet --detach "$commit"

cd {{ app_dir }}
runuser -u {{ app_user }} -- npm ci --omit=dev --silent

systemctl restart playground-app

for attempt in 1 2 3 4 5; do
  if curl -fsS http://127.0.0.1:{{ app_port }}/health > /dev/null; then
    echo "deployed $commit"
    exit 0
  fi
  sleep 2
done

echo "health check failed after deploying $commit" >&2
exit 1
```

- `set -euo pipefail` stops the script at the first failing command, instead of carrying on and reporting success. It is three options: `-e` (errexit) stops on a failed command, `-u` (nounset) makes an unset variable an error instead of silently empty, so a typo cannot turn `rm -rf "$DIR/"` into `rm -rf "/"`, and `-o pipefail` makes a pipeline `a | b` fail if any part fails, not only the last. `"${1:-}"` means "empty if not given", a deliberate default that `-u` accepts. Where a failure is expected, `|| true` says so: `grep` reports failure when nothing matches, which would otherwise end the script.
- Only a full 40-character commit ID is accepted. Anything else is refused before anything runs.
- The script runs as root, and `runuser -u nodeapp --` hands git and npm back to the app's account, the same idea as `become_user`.
- `git checkout --detach "$commit"` switches the code to exactly that commit.
- The loop calls `/health` up to five times, two seconds apart, because the app needs a moment to start. If it never answers, the script fails, and so will the workflow.

**Four tasks in the `app` role:**

```yaml
- name: Create the deploy account
  ansible.builtin.user:
    name: deploy
    shell: /bin/bash
    create_home: true

- name: Authorise the deploy key
  ansible.posix.authorized_key:
    user: deploy
    key: "{{ deploy_public_key }}"
    state: present

- name: Install the deploy command
  ansible.builtin.template:
    src: deploy-playground-app.j2
    dest: /usr/local/bin/deploy-playground-app
    owner: root
    group: root
    mode: '0755'

- name: Allow deploy to run only the deploy command as root
  ansible.builtin.copy:
    dest: /etc/sudoers.d/deploy
    content: "deploy ALL=(root) NOPASSWD: /usr/local/bin/deploy-playground-app\n"
    owner: root
    group: root
    mode: '0440'
    validate: /usr/sbin/visudo -c -f %s
```

- The account has no password, so only the deploy key opens it.
- The script belongs to root and cannot be edited by `deploy`. Otherwise `deploy` could rewrite it into anything and run that as root.
- The sudo rule reads: the account `deploy`, on any host, may run as `root`, without a password, this one command. `0440` is the permission sudo requires for its rule files. `validate` checks the rule with `visudo` before it is put in place, the same idea as `sshd -t` for the sshd file. `visudo` was confirmed to exist first, because Ubuntu 26.04 uses `sudo-rs`.

```bash
ansible-playbook -i inventory.ini setup.yml --limit app --tags app    # ok=16, changed=7
```

**Test by hand, over the VPN**, from WSL:

```bash
sudo wg-quick up wg0
git rev-parse origin/main    # the latest pushed commit
ssh -o IdentitiesOnly=yes -i ~/.ssh/github-deploy deploy@<app-private-ip> "sudo /usr/local/bin/deploy-playground-app <commit>"
# curl: (7) Failed to connect to 127.0.0.1 port 3000    <- first check, the app was still starting
# deployed <commit>                                     <- second check passed

ssh -o IdentitiesOnly=yes -i ~/.ssh/github-deploy deploy@<app-private-ip> "sudo whoami"
# sudo: I'm sorry deploy. I'm afraid I can't do that
```

`IdentitiesOnly=yes` makes `ssh` offer only the named key, instead of trying the agent's keys first. The refusal of `sudo whoami` is `sudo-rs` saying no: the deploy key can redeploy the app and nothing else.

The deployed commit has to contain the `/health` route. Deploying an older commit would leave the app running, but the script would report "health check failed".

### 4b. A VPN client for GitHub, and the secrets

A **runner** is the machine that executes a workflow job. `runs-on:` asks GitHub for a GitHub-hosted runner: a fresh virtual machine with Ubuntu and common tools, deleted when the job ends. Each job gets its own, so nothing carries over between jobs or runs. The alternative is a self-hosted runner, GitHub's runner program installed on a machine of my own.

GitHub's runner is a brand-new machine for every run, outside my network. It has to pass two locks, so it needs two key pairs:

| Key pair | Opens | Made with |
|---|---|---|
| `github-deploy` (4a) | The SSH login to the `deploy` account | `ssh-keygen` |
| `github.key` / `github.pub` | The WireGuard tunnel into the AWS network | `wg genkey` |

The tunnel comes first, because the app server's port 22 is not reachable from the internet. My PC has the same pair: `client.key` for its tunnel and `devops-playground` for SSH.

**The runner's VPN key pair**, generated outside the repo:

```bash
cd ~/wg-clients
umask 077
wg genkey | tee github.key | wg pubkey > github.pub
```

A third peer in `group_vars/bastion/vars.yml`, then the `wireguard` role was run on the bastion:

```yaml
  - name: github-actions
    public_key: "<github public key>"
    address: 10.8.0.4
```

**The app server's host key.** My PC learned it on the first connection and saved it in `~/.ssh/known_hosts`. The runner is new every time, so it has to be told in advance. Skipping the check would mean trusting whatever answers at that address. With the VPN up:

```bash
ssh-keyscan -t ed25519 <app-private-ip> > ~/app-hostkey.txt   # ask whatever answers at that address for its key
ssh-keygen -lf ~/app-hostkey.txt                                 # its fingerprint

# on the app server, through a login I already trust:
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub                 # the key read from the server's own disk
```

The two `SHA256:` fingerprints matched, so nothing in between had substituted another key. The line in `app-hostkey.txt` became a secret.

**A GitHub environment instead of repository secrets.** Repository secrets are available to any workflow on any branch. An environment can be limited to chosen branches, and can require approval before each run. The environment is named `main` and allows only the `main` branch, so only code that has reached `main` can deploy. The environment and the branch are different things that share a name: the branch is a line of code, the environment is where code is deployed to.

In the environment (Settings, Environments, `main`):

| Name | Kind | Value |
|---|---|---|
| `DEPLOY_SSH_KEY` | Secret | The private deploy key |
| `WG_PRIVATE_KEY` | Secret | The runner's WireGuard private key |
| `APP_KNOWN_HOSTS` | Secret | The line from `ssh-keyscan` |
| `WG_SERVER_PUBLIC_KEY` | Variable | The bastion's WireGuard public key (`sudo cat /etc/wireguard/server.pub`) |
| `WG_ENDPOINT` | Variable | `<bastion-public-ip>:51820` |
| `APP_HOST` | Variable | The app server's private address |

Secrets are encrypted and cannot be read back. Variables are plain settings, for values that are not secret. The repository is public, but secrets are never shown in logs, and workflows started from other people's pull requests do not receive them.

The two private keys were kept on WSL until the first deploy worked, so they could still be compared if something failed. A regenerated key pair would never match the old one: it would mean new secrets in GitHub, new public keys in the vars files, and rerunning both roles.

### 4c. The workflow

The old EKS workflow (`ci.yaml`, entirely commented out) was deleted. `.github/workflows/deploy.yml`:

```yaml
name: Deploy app

on:
  push:
    branches: [main]
    paths:
      - "app/**"
      - ".github/workflows/deploy.yml"
  workflow_dispatch:

concurrency:
  group: deploy
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: main
    timeout-minutes: 10
    steps:
      - name: Install WireGuard
        run: sudo apt-get update -qq && sudo apt-get install -y -qq wireguard-tools

      - name: Connect to the VPN
        env:
          WG_PRIVATE_KEY: ${{ secrets.WG_PRIVATE_KEY }}
        run: |
          printf '%s\n' "$WG_PRIVATE_KEY" | sudo tee /etc/wireguard/runner.key > /dev/null
          sudo chmod 600 /etc/wireguard/runner.key
          sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
          [Interface]
          Address = 10.8.0.4/32
          PostUp = wg set %i private-key /etc/wireguard/runner.key

          [Peer]
          PublicKey = ${{ vars.WG_SERVER_PUBLIC_KEY }}
          Endpoint = ${{ vars.WG_ENDPOINT }}
          AllowedIPs = 172.31.0.0/16
          PersistentKeepalive = 25
          EOF
          sudo wg-quick up wg0

      - name: Set up SSH
        env:
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          APP_KNOWN_HOSTS: ${{ secrets.APP_KNOWN_HOSTS }}
        run: |
          mkdir -p ~/.ssh
          chmod 700 ~/.ssh
          printf '%s\n' "$DEPLOY_SSH_KEY" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          printf '%s\n' "$APP_KNOWN_HOSTS" > ~/.ssh/known_hosts

      - name: Deploy
        run: |
          ssh -i ~/.ssh/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
            deploy@${{ vars.APP_HOST }} \
            "sudo /usr/local/bin/deploy-playground-app ${{ github.sha }}"

      - name: Disconnect from the VPN
        if: always()
        run: sudo wg-quick down wg0 || true
```

- **`on`**: a push to `main` that touches `app/` or this file. A change to Ansible or the docs alone does not deploy. `workflow_dispatch` adds a "Run workflow" button, to deploy by hand without changing code.
- **`concurrency`**: two quick pushes deploy one after the other, not both at once.
- **`permissions: contents: read`**: the least the run's built-in GitHub token can have. The runner does not even check out the code, because the server fetches it. The runner only sends the commit ID.
- **`environment: main`**: gives the job access to that environment's secrets and variables.
- **The VPN step** builds a config with the same structure as my PC's: its own address `10.8.0.4`, the bastion as the peer, and `AllowedIPs` covering only the AWS network.
- **Secrets go through `env:`**, not straight into commands. `${{ secrets.X }}` inside `run:` is pasted into the script text before the shell reads it, so a quote, `$`, backtick or line break in the value (the SSH key has several lines) would be read as code. That is called injection. Through `env:` the script only contains `"$X"`, and the shell treats the value as data, whatever it contains. Separately, GitHub blanks out secret values (`***`) if they ever appear in the log.
- **`StrictHostKeyChecking=yes`** refuses to connect to anything but the server whose key was verified.
- **The deploy step** is the command tested by hand in 4a. `${{ github.sha }}` is the full ID of the pushed commit.
- **`if: always()`** brings the tunnel down even when a step failed.

**`ubuntu-latest`** is a moving label that GitHub points at its newest default runner image. It needs no maintenance, but one day it moves and a workflow can break without any change of mine. This workflow depends only on `wireguard-tools` and `ssh`, so the risk is small. Pinning to a fixed image (named under "Runner Image" in a run's "Set up job" step) would match the rest of the project: a fixed AMI, the lock file, `npm ci`.

## Result

A visible change to `server.js` was committed and pushed together with the workflow. The run went green, and:

```bash
curl http://<app-public-ip>/    # Good Morning World! (おはようせかい)
```

The whole chain works: push to GitHub, the runner joins the VPN, logs in as `deploy`, the server fetches exactly that commit, installs its dependencies, restarts the service and passes the health check.

```
git push ──> GitHub Actions runner ══VPN══> bastion ──SSH──> app server (deploy)
                                                               └ deploy-playground-app <commit>
                                                                 git fetch, checkout, npm ci,
                                                                 restart, /health
```

## Open items

- Shred the two private keys on WSL now that a deploy has succeeded: `shred -u ~/wg-clients/github.key ~/.ssh/github-deploy`.
- Pin `runs-on` to a fixed runner image.
- The deploy script and the `app` role both know how to update the app. A change to one has to be mirrored in the other.
- A rebuilt bastion gets a new public address and a new WireGuard key, so `WG_ENDPOINT` and `WG_SERVER_PUBLIC_KEY` would need updating in GitHub as well as on every VPN client.
- The site is plain HTTP. HTTPS needs a domain name.
- The script's first health check usually prints a `curl: (7)` line while the app is still starting. `2> /dev/null` on that line would hide it.

## Architecture at the end of this phase

```
VISITOR
  browser ── HTTP, port 80 ──▶ app server: nginx, port 80 ──▶ Node app on 127.0.0.1:3000
                                (security group + UFW)          systemd, user nodeapp

DEVELOPER
  PC: edit app/, npm start, http://localhost:3000        my own copy, only on my PC
    └─ git push ──▶ GitHub, main ──▶ Actions runner (environment "main")
                                       ══ VPN, 10.8.0.4 ══▶ bastion ──▶ app server
                                       ssh deploy@<app> "deploy-playground-app <commit>"
                                         app server: git fetch from GitHub, npm ci,
                                                     restart, check /health

ADMIN
  ssh bastion (key + MFA), ssh app (ProxyJump), ansible (ProxyJump as ansible),
  VPN as 10.8.0.2, tofu (AWS API, state in S3). The ubuntu accounts are gone from both servers.
```

| Perspective | At this point |
|---|---|
| Visitor | For the first time something is public: `http://<app-public-ip>/`. Only port 80 is open. nginx is the only thing that talks to the app. |
| Developer | Works on their own copy and runs it locally. A push to `main` that touches `app/` deploys automatically, through the VPN, as the narrow `deploy` account. |
| Admin | Unchanged paths. The `deploy` account can run one command and nothing else. |

### Development and production

The setup now has two places where the app runs, and they are deliberately separate:

| | Development | Production |
|---|---|---|
| Where | The developer's own PC | The app server |
| Address | `http://localhost:3000` | `http://<app-public-ip>/` |
| Which code | Whatever is in the developer's files right now, committed or not | Exactly the commit that was last deployed |
| Who sees it | Only the developer | Everyone |
| How it changes | Edit and restart | Only through a push to `main` and the pipeline |

The developer never logs in to the production server to change it. The only route from code to production is git and the pipeline, so every change is recorded and the same steps run every time. In larger teams there is usually a third environment in between, often called staging: a copy of production where changes are tested before they reach real users.
