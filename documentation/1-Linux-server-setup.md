This is a DevOps project from [roadmap.sh: Linux Server Setup](https://roadmap.sh/projects/linux-server-setup)

## SSH Configuration (Part 1): 
*Generate an SSH key pair on your local machine, add the public key to your server, and configure the server to disable password-based authentication.*
1. Generate SSH key pain on local machine (WSL)

`ssh-keygen -t ed25519 -C "<comment-if-needed>" -f ~/.ssh/<target-location> `

**Note: If the command executred is `ssh-keygen -t ed25519`, it'll ask where to save the key; the default location is (~/.ssh/id_ed25519).**


2.  Requiring to enter passphrase for the target location (empty for no passphrase)
```bash
#Output
Your identification has been saved in <target-location>
Your public key has been saved in <target-location>.pub
```

3. After generating the keypair, use `cat ~/.ssh/devops-playground.pub` and copy the entire line.
4. At AWS console, go to EC2 → Key Pairs (in the left sidebar under "Network & Security").
5. Click "Actions" → "Import key pair" and paste the `ssh-ed25519 ...` in the public key contents.

6. Next go to EC2 → Instances → Launch Instances and fill in the fields 

**Note:  It is best practice to establish a tagging policy to standardize tagging across all your resources, especially in production.**

7. AWS has a really good tutorial prepared for the resource to guide through each field. I will briefly run through here. 

8. Choose the desired OS and software, the Amazon Machine Image (AMI). An AMI is a template that contains the operating system and software required to launch your instance.

9. Choose the hardware or the instance type. An instance type determines the CPU, memory, storage, and networking capacity of the host computer used for your instance.

10. Prepare for securely logging into your instance with a key pair. A key pair is set of security credentials that you use to prove your identity when connecting to your instance. The public key is on your instance and the private key is on your computer. 

11. Set up the firewall. A security group is a set of firewall rules that control the traffic to the instance. To connect through SSH from local computer to the instance, you need a rule that allows SSH traffic from  local computer. 

12. At Network settings I left the default VPC but ensure "Allow SSH traffic from" is set to **My IP** (not default `0.0.0.0`). Other settings are per default which are free tier eligible. 

13. Then SSH into the instance using the Public IPv4 address of the instance.

`ssh -i ~/.ssh/devops-playground ubuntu@<IPv4>`

First connection will ask "Are you sure you want to continue connecting?" — type yes. This adds the server's fingerprint to your ~/.ssh/known_hosts so future connections skip the prompt.
The default user on Ubuntu AMIs is `ubuntu`, not root.

## User Setup: 
Create a non-root user with sudo privileges. This user should be used for all future server administration instead of root.

I created the user `dev` using `sudo adduser dev` and provided a password for it. The field `Full Name []`, `Room Number []`, etc were left as default by pressing ENTER.

Using `sudo usermod -aG sudo dev` to provide user with admin acceess and validate this step using the command `groups dev`, the output should be `dev : dev sudo users`. 

Then copy the public key to the new user.

```bash
sudo mkdir -p /home/dev/.ssh
sudo cp ~/.ssh/authorized_keys /home/dev/.ssh/authorized_keys
sudo chown -R dev:dev /home/dev/.ssh
sudo chmod 700 /home/dev/.ssh
sudo chmod 600 /home/dev/.ssh/authorized_keys
```
- `700` on the `.ssh` directory meaning the owner can list, create files in, and cd into it. For a directory, `x` means "allowed to enter/traverse it," which is why it's required even though no folder is being executed.
- `600` on `authorized_keys` because a regular file like this is just data, never run as a program.
- [Here](https://oneuptime.com/blog/post/2026-03-02-how-to-understand-linux-file-permissions-rwx-on-ubuntu/view) to read more. 

Note: OpenSSH `sshd` refuses to trust `authorized_keys` if the file or its parent directory is writable by anyone other than the owner. This exists because on a shared system, if group/others could write to your `.ssh` folder, another user could plant their own public key in your authorized_keys and log in as you. For example if the user is logging in as `dev`, the `.ssh` folder may only be written by `dev`. 


## SSH Configuration (Part 2): 
_Configure the server to disable password-based authentication._

Log in as the new sudo user `ssh -i ~/.ssh/devops-playground <new-user>@<IPv4>`, and edit the SSH config file using `sudo nano /etc/ssh/sshd_config`

Uncomment or add the following field with the corresponding value:
```bash
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```
Save and exit: `Ctrl+X`, then `Y`, then `Enter`. 
Restart the SSH service using `sudo systemctl restart ssh`

Update all system packages using `sudo apt update && sudo apt upgrade -y`.

**Note: Due to previous edit in `etc/ssh/sshd_config`, there will be an update conflict. Choose `"keep the local version currently installed"`. It is also helpful by selecting the option `"show the differences between the versions"`.**

## System Updates: 
*Update all system packages and configure automatic security updates using unattended-upgrades.*

Per default, system updates are done manually using package management tools. We can configure automatic security updates using `unattended-upgrades`. Usually this package is installed per default. 

- Check if the package is present using: `dpkg -l unattended-upgrades`

- If it's installed you'll see a line starting with `ii` (meaning installed). If not installed it'll say `dpkg-query: no packages found`.
The `ii` stands for: first i = desired state is "install", second i = current state is "installed".

- Then enable it: `sudo dpkg-reconfigure --priority=low unattended-upgrades`
- Verify its status by running: `sudo systemctl status unattended-upgrades`. It should be `active (running)`. 

**An interesting [write up](https://lowendbox.com/blog/debians-unattended-upgrades-is-not-enabled-after-you-install-it-why-lets-deep-dive-that/) regarding the configuration for the package `unattended-upgrades`.**

## Basic Hardening: 
*Install and configure Fail2Ban to protect against brute-force SSH attacks.*

Fail2Ban watches log files for repeated failed login attempts and temporarily bans the offending IP using firewall rules. It's the automated defense against brute-force attacks.

- Intall the package using `sudo apt install fail2ban -y`

- Now configure it for SSH protection.

Fail2Ban has two config files:

`/etc/fail2ban/jail.conf`: the default, never edit this directly (gets overwritten on package updates)

`/etc/fail2ban/jail.local`:  the local overrides, this is what you edit

- Create local config: `sudo nano /etc/fail2ban/jail.local`

Example value:
```bash
[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 3600
findtime = 600
```
`maxretry`: The maximum number of failed attempts before fail2ban bans the IP address.

`bantime` : Ban duration in seconds. A negative value indicates a permanent ban.

`findtime`: The number of seconds after which the counter for `maxretry` is reset.

- Save and exit, then restart `sudo systemctl restart fail2ban`.

- Verify with `sudo fail2ban-client status sshd`:
```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=ssh.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

Notice that `Journal matches: _SYSTEMD_UNIT=ssh.service`, meaning Fail2Ban is watching the SSH service logs by using systemd journal as the backend to read SSH auth failures. `logpath` would only be needed in the `.local` if you were pointing Fail2Ban at a traditional log file like /var/log/auth.log. On older systems or non-systemd distros, that was the approach.

**Note: A Fail2ban [wiki](https://wiki.ubuntuusers.de/fail2ban/)**
## Server Configuration: 
*Set the correct timezone and a meaningful hostname for your server.*

- Check the current timezone: `timedatectl`

List all options with `timedatectl list-timezones | grep <your region>` if unsure.

- Check the current hostname: `hostnamectl`

As I am using an AWS instance to host the Linux server, the hostname is auto-generated AWS internal IP name. 

Set the corresponding timezone and a meaningful hostname using:
```
sudo timedatectl set-timezone <your/timezone>
sudo hostnamectl set-hostname <meaningful-name>
```

## Firewall Configuration:
Set up UFW (Uncomplicated Firewall) to allow only SSH (port 22) by default. You should understand how to add additional rules when needed.

1. First check if UFW is installed: `sudo ufw status` 

It's likely installed but inactive on Ubuntu.

2. Before enabling it, add the SSH rule first. This order matters, if UFW is enabled before allowing SSH, you'll lock yourself out immediately.
```
sudo ufw allow ssh
sudo ufw enable
```

There will be a warning stating that enabling the firewall may disrupt existing SSH connections,  type `y` to confirm. The current session won't drop because the SSH rule is already in place.

3. Verify: `sudo ufw status`
```bash
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere                  
22/tcp (v6)                ALLOW       Anywhere (v6)
```

UFW is active and only port 22 (SSH) is open as required. Both IPv4 and IPv6 are covered.

Extra: 
- Adding UFW rules: `sudo ufw allow <port>/<protocol>`. 

Examples:
```
sudo ufw allow 80/tcp       # HTTP
sudo ufw allow 443/tcp      # HTTPS
sudo ufw allow 3000/tcp     # a Node.js app
sudo ufw deny 3306/tcp      # explicitly block MySQL from outside
```

- Remove rules: `sudo ufw delete allow <port>/<protocol>`
- Allow from a specific IP only: `sudo ufw allow from 192.168.1.100 to any port 22`

## Service Management: 
Demonstrate basic systemctl commands to check the status of services, start/stop them, and enable them at boot.

Checking status of service:
```bash
sudo systemctl status ssh
sudo systemctl status fail2ban
sudo systemctl status ufw
```
Ubuntu-specific SSH quirk: `systemctl is-enabled ssh` returns `disabled` because Ubuntu uses socket-based activation (ssh.socket) instead from version 24.04 onwards. It means SSH isn't managed by systemd's enable/disable mechanism in the traditional way on Ubuntu. systemd starts SSH on demand when a connection comes in, rather than having the service running permanently.

`systemctl is-enabled ssh.socket` will return enabled. 

Starting and stopping a service
```bash
sudo systemctl stop fail2ban
sudo systemctl start fail2ban
sudo systemctl enable/disable fail2ban # Whether to auto-start on boot
sudo systemctl status fail2ban
```

## Log Inspection:
*Use `journalctl` to view system logs and locate common log files in `/var/log/`*

`systemd` journal is the logging system built into `systemd`. Instead of writing plain text to files like `/var/log/auth.log`, it captures all log output from every service running under systemd and stores it in a structured binary format. 

Verify :`sudo journalctl -u ssh --since "1 hour ago"`

Run: `ls /var/log/`

Some key files in output to know :

- `auth.log`: all authentication attempts (SSH logins, sudo usage)
- `syslog`: general system messages
- `fail2ban.log`: Fail2Ban activity