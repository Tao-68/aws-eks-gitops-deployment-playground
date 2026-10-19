This is a DevOps project inspired from [roadmap.sh: VPN Server Setup](https://roadmap.sh/projects/vpn-server-setup)

## VPN Server Setup
*The goal of this project is to set up a VPN server with WireGuard, to secure traffic on untrusted networks and to reach the private network remotely, and to connect to it from several devices.*

## How it works

The bastion from the previous project relays one kind of connection, SSH. A VPN makes a device a member of the private network, so anything can travel through it.

```
Bastion:  PC ──SSH──> bastion ──SSH──> app server
VPN:      PC ══encrypted tunnel══> bastion ──anything──> app server / internet
```

- Each side has a key pair, like SSH. The server knows each client's public key, and each client knows the server's. Private keys never leave the machine they were generated on.
- Inside the tunnel, devices get addresses from a range of their own. Here it is `10.8.0.0/24`, with the server as `10.8.0.1`. It does not overlap with the AWS network (`172.31.0.0/16`).
- **Private address ranges.** `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16` are reserved for private networks. Nobody owns them, anyone may use them internally, and internet routers never deliver to them, which is why `172.31.x.x` is unreachable from home without the VPN. Inside the VPC, AWS assigns each network interface an address from the VPC's range: the bastion's is `<bastion-private-ip>` (`ip -4 addr show ens5` on the bastion), the app server's `<app-private-ip>`.
- The server passes on what arrives through the tunnel and sends it out under its own address. That is the "IP forwarding and NAT" in the roadmap.
- **Inner and outer packet.** A packet is a label (from, to) and content, and routers read only the label. The **inner packet** is what a program sends, for example `from 10.8.0.2 to 172.31.19.0:80, GET /`. The internet cannot deliver it, because `172.31.x.x` is private. WireGuard on the client encrypts the **whole** inner packet and makes it the content of an **outer packet** `from <my-ip> to <bastion-public-ip>:51820, UDP`. The two overlap on purpose: the outer packet is a new label plus 32 bytes of WireGuard header and check, around the entire inner packet. The bastion decrypts the content and gets the inner packet back unchanged. `tcpdump -ni wg0` shows the inner packets, `tcpdump -ni eth0 udp port 51820` the outer ones, at the same moments.

### Two uses, one server

| Use | What goes through the tunnel | `AllowedIPs` on the client |
|---|---|---|
| Remote access to a private network, like an employee reaching internal services | Only traffic meant for the private network | `10.8.0.0/24, 172.31.0.0/16` |
| Privacy on untrusted networks | Everything | `0.0.0.0/0, ::/0` |

`AllowedIPs` on a client lists the destinations that are sent into the tunnel. The first row is also called split tunnelling. Both were set up, one per client.

## Design decisions

- **WireGuard runs on the bastion.** It is already the one public entry point.
- **Nothing changes on the app server.** Traffic from VPN clients leaves the bastion under the bastion's address, so the existing "SSH from the bastion's group" rule and the fail2ban exception already cover it.
- **UDP port 51820 is open to any address**, not only my home address. The point of a VPN is to connect from networks I do not control. WireGuard does not answer anyone without a valid key, so the port does not show as open to a scanner.
- **Consequence:** over the VPN I can SSH to the app server directly, without going through the bastion's SSH service. That path is protected by the WireGuard key and the SSH key, but it does not ask for the MFA code.

### The bastion's two jobs

The bastion is one machine, but it now does two different jobs. Which one a connection uses decides whether MFA is asked:

```
                            ┌─────────────── bastion (one EC2 instance) ───────────────┐
                            │                                                          │
ssh app ───────────────────▶│ Job 1: SSH server, TCP 22                                │
(ProxyJump bastion)         │ I log in here as dev: key + MFA code,                    │──▶ app server
                            │ then it opens a second connection to the app server      │    172.31.19.0
                            │                                                          │
ssh -o ProxyJump=none app ═▶│ Job 2: WireGuard server, UDP 51820                       │
(VPN on)                    │ no login: unwraps the packet and forwards it, like a     │──▶ app server
                            │ router; the sender becomes the bastion's private address │    172.31.19.0
                            └──────────────────────────────────────────────────────────┘
```

| | `ssh app` (ProxyJump) | `ssh -o ProxyJump=none app` (VPN on) |
|---|---|---|
| Packets pass through the bastion | yes | yes |
| Login on the bastion | yes, as `dev`, with MFA | no |
| Port on the bastion | TCP 22 | UDP 51820 |
| Bastion's SSH log (`journalctl -u ssh`) | `Accepted publickey for dev` | nothing |
| Checks on the app server | SSH key | SSH key |

The MFA code belongs to the bastion's SSH login, not to the app server. The app server never asks for it. `ssh app` asks for it only because the `app` entry in `~/.ssh/config` jumps through the bastion's SSH service, even when the VPN is on.

The checks along the VPN path, in order:

| # | Where | Check |
|---|---|---|
| 1 | Bastion's security group | UDP 51820 allowed (from anywhere) |
| 2 | Bastion's WireGuard | encrypted with a known key, and the inner sender is the address tied to that key (`AllowedIPs = 10.8.0.2/32` for this PC) |
| 3 | Bastion forwards with NAT | sender `10.8.0.2` is replaced by the bastion's private address |
| 4 | App server's security group | SSH from the bastion's group: matches, because of step 3 |
| 5 | App server's UFW and fail2ban | port 22 allowed, the bastion's address is in `ignoreip` |
| 6 | App server's SSH | valid key for `dev`, no MFA configured |

`AllowedIPs` means two things depending on the side. On a client it lists the destinations sent into the tunnel. On the server, per peer, it lists the addresses that peer may send from, and where answers to those addresses go. WireGuard calls this cryptokey routing: each key is tied to its addresses.

## 1. Security group rule

One ingress rule on the bastion's group in `iac/security.tf`:

```hcl
resource "aws_vpc_security_group_ingress_rule" "bastion_vpn" {
  from_port         = 51820
  to_port           = 51820
  ip_protocol       = "udp"
  cidr_ipv4         = "0.0.0.0/0"
  security_group_id = aws_security_group.bastion.id
}
```

```bash
tofu plan    # 1 to add, 0 to change, 0 to destroy
tofu apply
```

## 2. The `wireguard` role

A new role, applied to the `bastion` group only, through a third play in `setup.yml`:

```yaml
- name: VPN server
  hosts: bastion
  become: true
  roles:
    - role: wireguard
      tags: wireguard
```

```bash
mkdir -p roles/wireguard/{tasks,templates,handlers,defaults}
```

### Part a: install, forwarding, server key

```yaml
- name: Install WireGuard
  ansible.builtin.apt:
    name: wireguard
    state: present

- name: Allow forwarding in sysctl
  ansible.builtin.sysctl:
    name: net.ipv4.ip_forward
    value: '1'
    sysctl_file: /etc/sysctl.d/99-wireguard.conf
    reload: yes

- name: Generate the server private key
  ansible.builtin.shell: umask 077 && wg genkey > /etc/wireguard/server.key
  args:
    creates: /etc/wireguard/server.key

- name: Derive the server public key
  ansible.builtin.shell: wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
  args:
    creates: /etc/wireguard/server.pub
```

- **Forwarding.** By default Linux drops traffic that arrives for some other machine. A VPN server has to pass it on. The task applies the setting now and writes it to a file so it survives a reboot.
- **`shell`, not `command`.** The key commands redirect output with `>` and `<`, which `command` does not support.
- **`creates`.** Each key task runs only if its file does not exist yet. Without it, every run would generate a new key and break all clients.
- **`umask 077`.** The private key file is readable by root only from the moment it is created. The umask removes permissions from every new file: a program asks for `666` (rw for everyone), `077` takes away everything from group and others, so the file gets `600`. It can only remove, never add, which is why the owner gets `rw` and not `rwx`: the `x` was never requested. Directories ask for `777` and become `700`, where `x` means "may enter". Creating the file and running `chmod 600` afterwards would leave a moment in which the key is readable by everyone.

```bash
sysctl net.ipv4.ip_forward          # net.ipv4.ip_forward = 1
sudo ls -l /etc/wireguard           # server.key -rw-------, server.pub -rw-r--r--
sudo cat /etc/wireguard/server.pub  # 44 characters ending in =
```

### Part b: config, firewall, service

`roles/wireguard/defaults/main.yml`:

```yaml
wireguard_port: 51820
wireguard_address: 10.8.0.1/24
wireguard_peers: []
```

`roles/wireguard/templates/wg0.conf.j2`. This is the first file in the project that needs a real template, because it loops over a list of clients:

```
[Interface]
Address = {{ wireguard_address }}
ListenPort = {{ wireguard_port }}
MTU = 1420
PostUp = wg set %i private-key /etc/wireguard/server.key
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostUp = iptables -I FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o {{ ansible_default_ipv4.interface }} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o {{ ansible_default_ipv4.interface }} -j MASQUERADE

{% for peer in wireguard_peers %}
[Peer]
# {{ peer.name }}
PublicKey = {{ peer.public_key }}
AllowedIPs = {{ peer.address }}/32

{% endfor %}
```

- `Address` and `ListenPort` are the server's address inside the tunnel and the UDP port.
- `%i` is filled in by WireGuard with the interface name, `wg0`.
- The first `PostUp` loads the private key from its file when the tunnel starts. The key stays out of this config and out of Ansible.
- The two `FORWARD` lines let traffic pass between the tunnel and the network. The `MASQUERADE` line makes it leave under the server's own address. `PostDown` removes the same rules when the tunnel stops.
- **Why NAT and not only forwarding.** Forwarding alone gets the request to the app server, but the answer would be lost. The app server would reply to `10.8.0.2`, an address it and the VPC's router do not know. AWS would also drop the request on the way out of the bastion, because the source/destination check discards packets an instance sends from an address that is not its own. With `MASQUERADE` the sender becomes `<bastion-private-ip>`, which everything in the VPC can reach. The kernel remembers each rewrite (connection tracking) and restores `10.8.0.2` on the answers before they go back into the tunnel. The alternative would be a VPC route for `10.8.0.0/24` to the bastion plus a disabled source/destination check, which keeps the real VPN addresses visible but needs more AWS configuration.
- `{{ ansible_default_ipv4.interface }}` is a fact Ansible gathers: the name of the server's main network interface.
- `MTU = 1420` is WireGuard's standard packet size for internet use. Without it the interface came up with `mtu 8921`, derived from AWS's oversized internal limit, which clients on the internet cannot use.
- The `{% for %}` block writes one `[Peer]` section per client. On the server, a peer's `AllowedIPs` is the tunnel address that client may use.

Three more tasks, and a handler:

```yaml
- name: Deploy the WireGuard configuration file
  ansible.builtin.template:
    src: wg0.conf.j2
    dest: /etc/wireguard/wg0.conf
    owner: root
    group: root
    mode: '0600'
  notify: Restart wireguard

- name: Open the WireGuard port in the firewall
  community.general.ufw:
    rule: allow
    port: "{{ wireguard_port }}"
    proto: udp

- name: Start and enable the WireGuard service
  ansible.builtin.systemd:
    name: wg-quick@wg0
    enabled: yes
    state: started
```

```yaml
# roles/wireguard/handlers/main.yml
- name: Restart wireguard
  ansible.builtin.systemd:
    name: wg-quick@wg0
    state: restarted
    enabled: yes
```

```bash
ansible-playbook -i inventory.ini setup.yml --limit bastion --tags wireguard

sudo wg show          # interface wg0, the server's public key, listening port 51820
ip addr show wg0      # inet 10.8.0.1/24
```

## 3. First client: this PC's WSL, split tunnel

The client is whatever machine runs the commands. Here that is WSL on my PC.

Two checks first:

```bash
# Can WSL's kernel run WireGuard?
sudo ip link add wgtest type wireguard && echo supported && sudo ip link delete wgtest
# supported

# Does WSL's own network clash with the AWS range 172.31.0.0/16?
ip -4 addr show eth0
# inet 172.24.144.8/20, a different range, so no clash
```

Key pair, generated where it is used:

```bash
sudo apt install wireguard-tools
sudo sh -c 'umask 077; wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub'
sudo cat /etc/wireguard/client.pub
```

- `wg genkey` prints a new private key. `tee client.key` saves it to the file **and** passes it on through the pipe, like a T-junction. `wg pubkey` calculates the matching public key from it, and `>` saves that. The private key never appears on screen.
- **`sudo sh -c '...'`**, not `sudo wg genkey | ...`. `sudo` applies only to the one command right after it. The `>` and the commands after `|` would run as my normal user, who cannot write to `/etc/wireguard`. `sh -c` runs the whole line in one new shell, and `sudo` makes that shell root. The `umask` also only works inside the same shell as the commands that create the files.

The server learns about the client through the list in `group_vars/bastion/vars.yml`. The public key is copied by hand from the `cat` output above. Public keys are not secret:

```yaml
wireguard_peers:
  - name: pc-wsl
    public_key: "<pc public key>"
    address: 10.8.0.2
```

The name is only a label, written as a comment in the server's config. What decides which device an entry belongs to is the public key: the server lets in whichever device holds the matching private key.

The client's config, `/etc/wireguard/wg0.conf` on WSL:

```
[Interface]
Address = 10.8.0.2/32
PostUp = wg set %i private-key /etc/wireguard/client.key

[Peer]
PublicKey = <server public key>
Endpoint = <bastion-public-ip>:51820
AllowedIPs = 10.8.0.0/24, 172.31.0.0/16
PersistentKeepalive = 25
```

`[Interface]` describes this machine and `[Peer]` describes the other side. Each side holds the other's public key:

| Config file | `[Interface]` (myself) | `[Peer]` (the other side) |
|---|---|---|
| On the bastion | The bastion's private key | The client's public key |
| On the client | The client's private key | The bastion's public key |

```bash
sudo wg-quick up wg0
sudo wg show
```

Results:

| Output | What it proves |
|---|---|
| `latest handshake: 19 seconds ago` | Both sides recognised each other's keys and built the tunnel |
| `ip -4 route add 172.31.0.0/16 dev wg0` | WSL sends traffic for the AWS network into the tunnel, and nothing else |
| `ping -c 3 10.8.0.1` answered | Traffic reaches the bastion's address inside the tunnel |
| `ssh dev@<app-private-ip>` worked, with no `ProxyJump` | The bastion forwarded the traffic to the app server. From home that address is otherwise unreachable |
| `echo $SSH_CONNECTION` on the app server starts with the bastion's private address | The app server saw the connection as coming from the bastion. That is the NAT rule, and why the existing security group rule let it in |
| After `sudo wg-quick down wg0`, the same `ssh` hangs | The access exists only through the VPN |

## 4. Second client: phone, full tunnel

The phone's config is prepared on WSL and handed over as a QR code. The trade-off is that the phone's private key exists on the PC for a few minutes.

"Outside the repo" matters here. The private key and the config are secrets, so they are created in `~/wg-clients`, a folder git never sees, and not in the project folder that is pushed to GitHub.

```bash
sudo apt install qrencode
mkdir -p ~/wg-clients && cd ~/wg-clients
umask 077
wg genkey | tee phone.key | wg pubkey > phone.pub
```

A second entry in `wireguard_peers`, then the role is run again:

```yaml
  - name: phone
    public_key: "<phone public key>"
    address: 10.8.0.3
```

`~/wg-clients/phone.conf`:

```
[Interface]
PrivateKey = <phone private key>
Address = 10.8.0.3/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server public key>
Endpoint = <bastion-public-ip>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`AllowedIPs = 0.0.0.0/0, ::/0` sends everything through the tunnel. `DNS` makes name lookups go through it too. `PersistentKeepalive` keeps the connection alive on mobile networks.

```bash
qrencode -t ansiutf8 < ~/wg-clients/phone.conf    # scan with the WireGuard app
```

Results:

| Check | Result |
|---|---|
| `sudo wg show` on the bastion | Two peers. The phone has a recent handshake and traffic counts. The PC has none while its tunnel is off |
| "What is my IP" site on the phone | The bastion's public address |
| `dnsleaktest.com` on the phone | Cloudflare's servers, from `DNS = 1.1.1.1`. No provider servers, so no leak |

Clean up, so the phone holds the only copy of its private key:

```bash
shred -u ~/wg-clients/phone.key ~/wg-clients/phone.conf
```

`rm` only removes a file's name, and the contents stay on disk until overwritten. `shred` overwrites the contents with random data first, and `-u` then deletes the file. On SSDs and virtual disks the overwrite is less of a guarantee, but it is still the better habit for secrets.

## Roadmap checklist

| Requirement | Where |
|---|---|
| Install WireGuard on the server | Role, part a |
| Generate server and client key pairs | Role, part a. Sections 3 and 4 |
| Configure `wg0.conf` with IP ranges | Template, `10.8.0.0/24` |
| Enable IP forwarding and NAT rules | `sysctl` task, `PostUp` lines |
| Open 51820/UDP in the firewall | Security group rule and UFW task |
| Start and enable the service | `wg-quick@wg0` |
| Client configuration files | Sections 3 and 4 |
| Connect from devices, verify the public address, test for DNS leaks | Section 4 |
| Multiple clients | PC and phone |
| Stretch: split tunnelling | Section 3 |

## Open items

- The phone test ran on my home Wi-Fi (its endpoint in `wg show` was my home address). A test on mobile data would also show the VPN working from another network.
- The server's private key lives on the bastion's disk. A rebuilt bastion generates a new one, and every client then needs the new public key. Storing the key in the vault would avoid that.
- A rebuilt bastion also gets a new public address, so each client's `Endpoint` needs updating.
- The VPN path to the app server does not ask for the MFA code. It relies on the WireGuard key and the SSH key.
- Only IPv4 is forwarded. A full-tunnel client's IPv6 traffic enters the tunnel and is dropped, which prevents leaks but means IPv6 does not work while connected.
- With the VPN in place, SSH on the bastion's public address could later be closed, leaving UDP 51820 as the only opening. Ansible would then also have to reach the servers through the VPN.
- The deploy job in the later CI phase could join as another client.

## Architecture at the end of this phase

```
Admin PC (WSL), 10.8.0.2 ══ WireGuard, UDP 51820 ══▶ bastion, 10.8.0.1
  split tunnel: 10.8.0.0/24, 172.31.0.0/16             forwards + NAT ──▶ app server
Phone, 10.8.0.3 ═════════ full tunnel ═════════════▶ bastion ──▶ the internet

Unchanged from the bastion phase:
  ssh bastion (key + MFA), ssh app (ProxyJump), ansible (ProxyJump as ansible), tofu
```

| Perspective | At this point |
|---|---|
| Visitor | Nothing is public. |
| Developer | Unchanged: the static site. |
| Admin | Two ways in. Through the bastion's SSH, with the MFA code. Or on the VPN, where the app server's private address is reachable directly, protected by the WireGuard key and the SSH key but without the code. The phone can also send all its traffic through the bastion. |
