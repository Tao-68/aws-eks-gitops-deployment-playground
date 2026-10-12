This is a DevOps project inspired from [roadmap.sh: Configuration Management](https://roadmap.sh/projects/configuration-management)

## Configuration Management with Ansible
*The goal of this project is to introduce you to the basics of configuration management using Ansible. You will write an Ansible playbook to configure a Linux server.*

What is Ansible? 

Ansible applies configuration to servers that already exist. Terraform answers "what infrastructure exists?" (the EC2 instance, its security group, its key pair). Ansible answers "what runs inside it?" (packages, users, files, services, firewall rules).

It works by describing the desired state, not a list of commands. You write "nginx is installed and running," and Ansible checks the server and changes only what's different. Running it twice produces no further changes, which is called idempotence. It also needs nothing installed on the server beyond SSH and Python, so it's agentless.

1. Install Ansible on WSL: `sudo apt install ansible`
2. Check the version using `ansible version`
3. Generate a new key pair on WSL for Ansible, such that the automation key is separate from the personal key, so it could be revoked without affecting the other. 
4. The agent holds the decrypted key in memory, so enter the passphrase once per session instead of on every Ansible run. Start the agent: 

```bash
eval "$(ssh-agent -s)"
Agent pid 000111 # Output
```

The eval line runs the output of `ssh-agent -s`, which sets two environment variables (`SSH_AUTH_SOCK` and `SSH_AGENT_PID`) in your shell. The `Agent pid` line is the printed confirmation that the agent started.

5. Load the automation key into `ssh-agent`
```bash
ssh-add ~/.ssh/<your-key-name>
Identity added: /ansible/key/.ssh/added # Output

`ssh-add -l` # Verify key load
256 SHA256:very-very-very-long-string (ED25519) # Output
```

6. Create the agent user within the Linux server (Ubuntu):
```bash
sudo adduser ansible --disabled-password
warn: Waiting for lock to become available...
warn: Waiting for lock to become available...
warn: Waiting for lock to become available...
warn: Waiting for lock to become available...
```

Another process holds a system lock, and adduser is waiting for it. This is because I tried to create the ansible user like a normal user when it should have been without password and I interrupted the process when the system prompted for password. I tested  with `id ansible` and it returned `uid=1002(ansible) gid=1002(ansible) groups=1002(ansible)`, meaning the user exists. 

Run `ps aux | grep -E "useradd|adduser|passwd|chpasswd|vipw" | grep -v grep`
```bash
# output
root        7707  0.0  0.6  12836  5752 pts/0    T    21:18   0:00 sudo adduser ansible
root        7711  0.0  0.2  12836  2352 pts/1    Ss   21:19   0:00 sudo adduser ansible
root        7712  0.0  1.3  17612 12312 pts/1    T+   21:19   0:00 adduser
root        7732  0.0  0.4  10156  4100 pts/1    S+   21:19   0:00 /bin/passwd ansible
```

Before killing them, check the account's password state:
```bash
sudo passwd -S ansible
# Output
ansible L 2026-10-06 0 99999 7 -1
```
- `NP` or `L`: no usable password. L means the password is locked, so password login is impossible. This is what we want for a key-only account.
- `P`: a password was set. Lock it with `sudo passwd -l` ansible before continuing.

```bash
getent passwd ansible
# Output
ansible:x:1002:1002::/home/ansible:/bin/bash
ls -ld /home/ansible
drwxr-x--- 2 ansible ansible 4096 Oct  6 21:19 /home/ansible
```
Clear the stale processes:
 ```bash
sudo kill -CONT 7707 7711 7712 7732
sudo kill -TERM 7707 7711 7712 7732
```
- `-CONT` (continue): resumes a process that was stopped. Your adduser processes were in state T, meaning they were paused, probably by a Ctrl+Z in their terminal. A stopped process can't handle any other signal, including termination, so the wake-up comes first.

- `-TERM` (terminate): asks the process to shut down cleanly. It can catch the signal and run cleanup, such as releasing its lock files.

Sending `-CONT` before `-TERM` is the reason for the two commands. Without the first, the -TERM would sit unhandled on the paused processes.

If a process ignored -TERM and kept running, the stronger option is `-KILL`(-9). It can't be caught, so it skips cleanup and can leave locks behind. Use it only if -TERM fails.

Confirm the stale processes are gone: 
```bash
ps aux | grep -E "useradd|adduser|passwd|chpasswd|vipw" | grep -v grep
```

7. On WSL, print the automation public key: `cat ~/.ssh/<your-key-name>.pub`

8. Then add the ekey to the ansible user: 

```bash
sudo nano /path/ansible/.ssh/authorized_keys # Paste the public key entire line
sudo chown -R ansible:ansible /home/ansible/.ssh
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
```

9. Verify by logging in as ansible user from WSL `ssh ansible@<server-ip>` when the agent is still runnning (Refer to Step 4.)

Note: the `-i` flag was not needed as the `ssh-agent` holds the automation key in memory (from the `ssh-add` in Step 5.) OpenSSH automatically requests the agent for available keys and sends it to the server. 

10. To have practical implementation, I decided for ansible to use a password-protected sudo account with the password to be encrypted via Ansible Vault.

The initial password decision for ansible user was a passwordless NOPASSWD sudoers rule, then a scoped command-allowlist version. 

A sudoers rule restricted to specific commands (eg. only allow `apt-get` and `systemctl`) which are listable.

However for some Ansible modules like `copy` (upload a file), `template` (upload a file with variables filled in), or `user` (create a user) don't call a simple system command. Instead, Ansible writes a Python script to a temp file on the server and runs that script with `python3`. The temp filename is random and different every single run.

This breaks the **"allowlist only specific commands"** because the script's path changes every time. The only option would be a rule like "allow running python3" which is essentially allowing unrestricted `python3`

`nginx` role probably needs template (to write the nginx config file) and your ssh role needs `copy` or lineinfile (to add a key). Both go through the Python-script path. That means a scoped sudoers rule wouldn't actually restrict those roles.

11. From the repo root, create a new directory (e.g. `ansible/`). Inside it, create a file named `inventory.ini`. This file tells Ansible which hosts exist and how to reach them.

12. An INI-style inventory needs, at minimum: a group header in square brackets (e.g. [servers]), then one line per host with the connection details. Example: 
```bash
[myhosts]
my_host_01 ansible_host=<public IPv4 or FQDN> ansible_user=<username>
```
Pay attention to the format as each line inside an INI inventory group is parsed as a separate host entry. So if ansible_user is written on the next line, the SSH connection will throw an error as Ansible will try to connect to a host literally named `ansible_user=ansible`. 

Users also have the freedom to configure in YAML format. Read more at the [official documentation of Ansible](https://docs.ansible.com/projects/ansible/latest/getting_started/get_started_inventory.html#get-started-inventory)

13. In WSL, under the ansible directory, establish the connection using `ansible myhosts -i inventory.ini -m ping -u ansible`
```bash
# Output
<IPv4> | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3.14"
    },
    "changed": false,
    "ping": "pong"
}
```

Note: Pass the `-u` option with the ansible command if the username is different on the control node and the managed node(s). Or specify the user in the `INI` file.

14. In the ansible directory, create the file `group_vars/myhosts/vault.yml` and populate it:
```bash
ansible_become_password: <the-actual-password>
```
Read more [here](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html#become-and-network-automation)

15. Run the command `ansible-vault encrypt group_vars/myhosts/vault.yml`. Then the file would appear:
```bash
$ANSIBLE_VAULT;1.1;AES256
6233356135323437386365356266323035363334353361313932333138313637303935323061353634653234373764303036343032303138336463
...
```
16. When trying to establish connection as ansible user such that the password is authenticated thorugh Ansible Vault, I was met with a persistent Timeout issue. After spending some time on it and still no avail, I will leave it aside for now and use a temporary work around to proceed with the Ansible roles configuration. This issue is documented in **3.5-ansible-todo.md**. 

*Edit: This issue is resolved and the complete write up is in **3.5-ansible-todo.md*** 

Simplified is due to Ubuntu 26.04 ("resolute") does ship `sudo-rs` (a Rust rewrite of sudo) as the default sudo. And the original C-based sudo is kept installed under a different name: `sudo.ws`. So in `/ansible/group_vars/myhosts/` directory, create `vars.yml` and add the key-value pair `ansible_become_exe: /usr/bin/sudo.ws`.
```bash
ansible myhosts -i inventory.ini -b -m command -a "id -u" --ask-vault-pass

# Output
Vault password: 
[WARNING]: Host 'my_host_01' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.20/reference_appendices/interpreter_discovery.html for more information.
my_host_01 | CHANGED | rc=0 >>
0
```
- `CHANGED`: Ansible's per-task status, expected every run.
- `rc=0`: Unix return code (exit code) of the command, 0 means success.
- `0`: Output of `id -u`, the numeric userID of user running. Due to privilege escalation by `-b`/`become: true`, the SSH chain became `<user>` -> `sudo` to root -> then execute `id -u`, so `0`/`root` is returned. 


17. Following the project requirement, I need to scaffold the role structure for `base`, `nginx`, `app` and `ssh`. In the `/ansible` directory, instead of creating the directories and files manually, run the following command:
```bash
ansible-galaxy init roles/base
ansible-galaxy init roles/nginx
ansible-galaxy init roles/app
ansible-galaxy init roles/ssh
```

Each creates a folder like:
```bash
roles/base/
  tasks/main.yml
  handlers/main.yml
  defaults/main.yml
  vars/main.yml
  files/
  templates/
  meta/main.yml
  tests/
```

**Note: The automated file generation is convenient but it creates also many unecessary file (only base will remain with this structure as an example). Most files that would be used are under `/tasks` and maybe `/defaults` and `/vars`. However it is good to know that such a command exists.**

## First role: `base`
*Basic server setup (installs utilities, updates the server, installs `fail2ban`, etc.)*

1. Open `roles/base/tasks/main.yml`. Ansible tasks are a YAML list, each item has a name: (a human-readable description, shows in the output) and one module key with that module's parameters. 
```bash
- name: <description>
  <module.name>:
    <param>: <value>
```

2. To update the apt cache and upgrade packages. Module: `ansible.builtin.apt`, namely `update_cache` and `upgrade parameters`.

3. Install a list of utility packages (e.g. curl, unzip). Same `ansible.builtin.apt module`, but this time `name` takes a `YAML` list, and `state` should ensure they're present.

4. Install `fail2ban` and ensure it is enabled and running. For `fail2ban`, instead of listing the packages and service name, these varialbles could be defined under `/defaults/main.yml` or `/vars/main.yml`.

**Note: `defaults/` is the lowest-priority tier, it could be easily overridden by `group_vars`, `host_vars`, or `-e` on the command line. It holds the default value, but could be overriden if needed. `vars/` sits much higher in precedence and is harder to override from outside the role, signaling "this is fixed, role-internal config." For something like a package name, defaults/ is the more conventional spot, since someone reusing this role on a different distro might want to override the package name without editing the role itself.**

5. Before proceeding with other roles, I will write a minimal `setup.yml` in the `/ansible` directory that references just `base` and test the script. 

```bash
- name: <description>
  hosts: <group>        # Inventory group to target (eg. localhost, myhosts)
  become: <true/false>  # true: at play level, every task at each role escalates privileges without needing become: true repeated on each task individually
  roles:
    - role: <role name> # (eg. base)
      tags: <tag name>  # Reference field for isolated run
```

**Note: in the `become` field, true: at play level, every task at each role escalates privileges without needing `become: true` repeated on each task individually.** 

6. Check the syntax `ansible-playbook -i inventory.ini setup.yml --syntax-check`.

7. A dry run for the `base` role `ansible-playbook -i inventory.ini setup.yml --ask-vault-pass --check`. Verify the output:
```bash
PLAY RECAP ******************************************************************************************
my_host_01                 : ok=6    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0 
```
- `update_cache` shows `changed` due to refreshing the apt package index. This is expected
- Everything else show `ok`.

*For self understanding:*
This role is for server-wide maintenance: keeping packages updated, installing `fail2ban` (prevent brute-force login attempts).


## Second role: `nginx`
*Installs and configures `nginx`*

This role installs nginx, deploys a config file, and restarts nginx only when that config actually changes.

1. Install nginx — same `ansible.builtin.apt` pattern as `base`, using `state: present` (not `latest`, to avoid unexpected version jumps on every run).

2. Deploy the config via `ansible.builtin.template`, not `ansible.builtin.copy`. `copy` transfers a file byte-for-byte; `template` renders it through Jinja2 first, so any `{{ variable }}` placeholders get substituted before the file lands on the server. Even with no variables in the config yet, using `template` from the start means no rewrite is needed later if one becomes necessary. The `.j2` extension on the source file is a naming convention only, hinting that this file gets rendered through Jinja2 before use.

3. A handler restarts nginx, triggered only when the config changes:
```bash
# roles/nginx/tasks/main.yml
- name: Install nginx
  apt:
    name: nginx
    state: present
    update_cache: yes

- name: Deploy nginx site configuration
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/sites-available/static-site
  notify: Restart nginx

- name: Enable nginx site configuration
  file:
    src: /etc/nginx/sites-available/static-site
    dest: /etc/nginx/sites-enabled/static-site
    state: link
  notify: Restart nginx

- name: Remove default nginx configuration
  file:
    path: /etc/nginx/sites-enabled/default
    state: absent

- name: Ensure nginx is running
  systemd:
    name: nginx
    state: started
    enabled: yes
```
```bash
# roles/nginx/handlers/main.yml
- name: Restart nginx
  systemd:
    name: nginx
    state: restarted
    enabled: yes
```
A handler is just a normal task living in `handlers/main.yml`. `notify: <name>` in a task triggers the handler whose `name:` matches exactly (case-sensitive), but only if that task reported `changed`. Even if multiple tasks notify the same handler in one play, it only runs **once**, at the end of the play.

**Mistakes made and fixed along the way:**

- **Naming collision:** my own site config was initially named `default` which is the same filename Ubuntu's stock (dfault) nginx config uses. This created a self-defeating sequence: deploy → symlink in → then immediately delete that same symlink via the "remove default" step, leaving `sites-enabled/` empty and nginx serving nothing. Renamed to `static-site` to avoid the collision entirely, keeping the "remove default" task scoped only to the *stock* config.
- **Empty template, `curl localhost` failing to connect at all:** `nginx.conf.j2` was created but left with no actual content. nginx accepted the empty included file silently (no syntax error), but with zero server blocks defined and the stock default removed, nothing was listening on port 80 at all. A minimal working server block:
```bash
server {
    listen 80;
    server_name _;

    root /var/www/static-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```
  `server_name _;` is nginx's catch-all, matching any hostname — used here since there's no real domain pointed at this server. The `root` path must match wherever the `app` role deploys its content.

## Third role: `app`
*Uploads the given tarball of a static HTML website to the server and unzips it.*

Tarball is a Unix phrase for a `.tar.gz` archive, bundled with the `tar` command, optionally compressed with `gzip`. `tar` is part of every standard Linux install, including minimal Ubuntu AMIs. 

1. I will create a simple static HTML called `index.html` under `app/files/site-src`.
2. Under `roles/app/files` (conventional location for static assets), package the html as a tarball:
```bash
tar -czf static-site.tar.gz -C site-src .
```
- `c` — create a new archive
- `z` — compress it with gzip (this is what makes it .tar.gz rather than plain .tar)
- `f static-site.tar.gz` — the output filename
- `C site-src .` — "change into the site-src directory first, then archive everything in . (the current dir, relative to that change)." This matters: without `-C`, the archive would contain the path `site-src/index.html` inside it; with `-C`, it contains just `index.html` at the archive's root, not nested inside an extra folder.

Verify what was packaged using `tar -tzf static-site.tar.gz`, ensuring the `html` file is not nested.

3. Before proceeding, the nginx's `root` directive `/var/www/static-site` needs to be created before the `unarchive` extracts into it. 
```bash
# roles/app/tasks/main.yml
- name: Ensure /var/www/static-site directory exists
  ansible.builtin.file:
    path: /var/www/static-site
    state: directory
    owner: www-data
    group: www-data
    mode: '0755'

- name: Unpack local archive
  ansible.builtin.unarchive:
    src: static-site.tar.gz
    dest: /var/www/static-site
    remote_src: no
    owner: www-data
    group: www-data
    mode: '0644'
```
- `remote_src: false` tells Ansible "the source archive lives on the control node (here WSL machine) and needs to be uploaded to the server before extracting"; as opposed to true, which would mean "the archive already exists on the remote server itself, just extract it in place." Since your tarball only exists locally right now, this must be false.
- `owner:` / `group:` set both to `www-data`, the user `nginx `runs as on Debian/Ubuntu. Without this, extracted files would be owned by whatever user Ansible escalated to (root), and depending on nginx's permission checks, that can cause it to fail reading the files.


**Incident : `403 Forbidden` from nginx after a "successful" deploy.** Even with all tasks reporting `ok`/`changed` as expected and no errors, `curl localhost` on the server returned `403 Forbidden` instead of the site content.

Diagnosis: `ls -la /var/www/static-site/` showed the directory itself as `drw-r--r--` (mode `644`, no execute bit) and every file inside as unreadable (`?` for every field) — the classic signature of a directory with read-but-no-traverse permission. The first task above correctly set the directory to `0755`. The root cause: **`unarchive`'s `mode` parameter is applied uniformly to everything it touches during extraction, including the destination directory itself, not just the extracted files.** There's no separate "directory mode" vs "file mode" option on this module. So the second task's `mode: '0644'` (correct for the files) silently overwrote the first task's `0755` on the directory, removing the execute bit again, and a directory without execute permission can't be traversed by nginx (running as `www-data`), which nginx reports as `403 Forbidden` rather than `404`, since it found the directory but couldn't read an index file inside it.

Fix: a third task, run *after* `unarchive`, re-asserting the directory's permissions back to `0755`. This is a defensive pattern worth remembering generally — when a task might have side effects on something already configured by an earlier task, re-assert that configuration *after* the side-effecting task runs, rather than assuming task order alone protects it.

*For self understanding:*
`nginx` role's job: install the web server software, and tell it where to look for content. When someone visits this server on port 80, go look in the folder `/var/www/static-site` for files, and serve `index.html` if someone just requests `/.`

`app` role's job: take the website files (the tarball) and physically place them into that exact folder, `/var/www/static-site.` This role doesn't know anything about web servers, ports, or HTTP, it's purely "unpack these files into this directory."

The directory and files are created by root (via `become` in `setup.yml`), which never needs permission to do so. Root then labels them `owner: www-data`, `group: www-data` as configured. Later, when nginx (running as `www-data`, a separate process) tries to read those files to serve them, that's when the `owner/group/mode` actually gets checked and it passes because nginx's identity (`www-data`) matches the label root assigned earlier.*
## Fourth role: `ssh`
*Adds the given public key to the server.*

The roadmap's phrasing "adds **the given** public key" is deliberately generic, not tied to any specific account. Decided the realistic pattern for something like onboarding a new admin or developer. The initial version only managed keys for an *existing* account; it was later extended with a user-creation task so the role can genuinely onboard a brand-new account end-to-end, not just add a key to one that already exists.

1. Use the dedicated `ansible.posix.authorized_key` module, not manual `copy`/`lineinfile` edits to `authorized_keys`. It handles deduplication, validates key format, and is properly idempotent, so adding the same key twice is a no-op, not a duplicate line. It also creates the target user's `.ssh` directory itself with correct permissions if missing, so no separate directory-creation task is needed.

2. Check the collection is available (it's separate from `ansible.builtin`):
```bash
ansible-galaxy collection list | grep posix
# ansible.posix   2.1.0
```
Install if missing: `ansible-galaxy collection install ansible.posix`

3. `roles/ssh/defaults/main.yml` — overridable placeholders, not real values baked into the role:
```bash
ssh_target_user: dev
ssh_public_key: "override with the real public key content or a lookup"
```

4. `roles/ssh/tasks/main.yml` — one task, referencing the variables:
```bash
- name: Add authorized key for target user
  ansible.posix.authorized_key:
    user: "{{ ssh_target_user }}"
    state: present
    key: "{{ ssh_public_key }}"
```

5. Run it with real values supplied at invocation:
```bash
ansible-playbook -i inventory.ini setup.yml --ask-vault-pass --tags ssh \
  -e "ssh_target_user=dev ssh_public_key={{ lookup('file', '~/.ssh/devops-playground.pub') }}"
```
Result: `ok=1`, no `changed` — confirming both that the role works, and that `dev`'s key was already correctly present from the Project 1 setup (idempotence correctly detected nothing needed to change, rather than adding a duplicate entry).

`newuser` was created while testing the `ssh` role and still accepted the personal key. Removed on the server with `sudo deluser --remove-home newuser`.

## Finalizing `setup.yml`
```bash
- name: ansible-playbook setup.yml
  hosts: myhosts
  become: true
  roles:
    - role: base
      tags: base
    - role: nginx
      tags: nginx
    - role: app
      tags: app
    - role: ssh
      tags: ssh
```
The longer dict form is still needed if a role requires extra parameters (e.g. a *custom* tag differing from the role's own name, or `vars:` scoped to just that role inclusion).

## Project 3 — complete

All four roles (`base`, `nginx`, `app`, `ssh`) are written, tested individually and together via `setup.yml`, and idempotent on repeat runs. Along the way, this project also surfaced and fully root-caused a genuine upstream compatibility bug (`sudo-rs` vs. Ansible's become plugin — full writeup in `3.5-ansible-todo.md`), rather than working around it blindly.

**Known open item carried forward:** state remains local (no S3 backend) for the IaC work in Project 2 — noted there as a deferred follow-up, not specific to this project.

