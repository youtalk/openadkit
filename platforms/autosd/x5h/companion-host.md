# X5H companion host: always-on bench gateway for remote development

Stands up a small always-on PC next to the X5H that owns the bench LAN,
routes a tailnet into it, and serves the rescue paths (TFTP, NFS) and the
serial consoles. It is what makes the board reachable when nobody is in
the room, and it is where external developers' access is scoped.

> **Status: designed, not yet executed.** Every other document in this
> directory describes something validated on hardware. This one does not —
> the companion PC was not available during the 2026-08-07 session, so the
> procedure below has not been run end to end and the reboot drill and the
> access tests have not been performed. Treat it as a runbook to follow and
> correct, not as a record. The board-side half it depends on *is* done:
> the board self-boots from UFS and no longer needs a host to run.

## Why a separate machine

The board's bench dependencies used to live on a developer's workstation:
the TFTP server U-Boot pulled kernels from, the NFS export it mounted as
root, and the USB serial adapters. That workstation gets rebooted, taken
home, and put to sleep. [UFS self-boot](selfboot.md) removes the board's
*need* for those services in the normal path, but the rescue paths still
want them, and something has to hold the serial consoles and bridge the
tailnet. That something should be always on and boring.

It also creates the security boundary. The bench LAN carries services with
no authentication worth the name (TFTP has none; NFS here trusts the
subnet). Those must never face the tailnet, because the tailnet is shared
with external developers. The companion is where that separation is
enforced — twice, independently: in the Tailscale ACL, and in a firewall
that scopes each service to an interface.

Assumes a fresh Ubuntu 24.04 LTS install with two interfaces: `<BIF>` for
the bench LAN and a separate uplink. Substitute real names throughout.

## 1. Base packages and tailnet

```sh
sudo apt update && sudo apt install -y \
  nftables tftpd-hpa nfs-kernel-server tmux tio rsync unattended-upgrades
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=192.168.0.0/24 --advertise-tags=tag:x5h-gw
```

The tag must exist in the policy before it can be advertised — if this
errors, apply the ACL in section 6 first, then re-run. Approve the subnet
route in the admin console (or let `autoApprovers` do it), and confirm
with `tailscale status` that the route is advertised and accepted.

## 2. Bench LAN and forwarding

The companion takes over `192.168.0.1`, the address the board's kernel
command line already uses as its gateway, so nothing on the board changes
when the cables move.

```sh
sudo nmcli con add type ethernet ifname <BIF> con-name x5h-lan \
  ipv4.method manual ipv4.addresses 192.168.0.1/24 \
  connection.autoconnect yes connection.autoconnect-priority 100
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-x5h.conf
sudo sysctl --system
```

## 3. Firewall

Identity is the ACL's job; this file's job is to make sure the
unauthenticated bench services can only ever be reached from the bench
LAN, whatever the ACL says. `/etc/nftables.conf`:

```
#!/usr/sbin/nft -f
flush ruleset
define BIF = "<BIF>"
define UPLINK = "<uplink-if>"
table inet x5h {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    # SSH: tailnet and bench LAN, never the raw uplink
    iifname { "tailscale0", $BIF } tcp dport 22 accept
    # TFTP + NFS: bench LAN only -- these face no tailnet, ever
    iifname $BIF udp dport { 69, 111, 2049 } accept
    iifname $BIF tcp dport { 111, 2049 } accept
    iifname $BIF icmp type echo-request accept
    iifname "tailscale0" icmp type echo-request accept
    udp dport 41641 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "tailscale0" oifname $BIF accept
    iifname $BIF oifname $UPLINK accept
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    iifname $BIF oifname $UPLINK masquerade
  }
}
```

```sh
sudo nft -c -f /etc/nftables.conf && sudo systemctl enable --now nftables
```

The masquerade is what lets the board pull container images; the image
ships static resolvers because nothing on the bench LAN serves DNS.

## 4. Rescue services and artifact migration

```sh
sudo sed -i 's|^TFTP_DIRECTORY=.*|TFTP_DIRECTORY="/srv/tftp"|' /etc/default/tftpd-hpa
printf '/export/rfs 192.168.0.0/24(rw,sync,no_root_squash,no_subtree_check)\n/export/rfs-autosd 192.168.0.0/24(rw,sync,no_root_squash,no_subtree_check)\n' \
  | sudo tee /etc/exports
sudo systemctl enable --now tftpd-hpa nfs-kernel-server && sudo exportfs -ra
```

From the workstation that currently holds them — the remote side needs
root to preserve ownership under `/srv` and `/export`, hence
`--rsync-path`:

```sh
sudo rsync -aH --numeric-ids --rsync-path='sudo rsync' /srv/tftp/ companion:/srv/tftp/
sudo rsync -aH --numeric-ids --rsync-path='sudo rsync' --info=progress2 \
  /export/rfs/ companion:/export/rfs/
sudo rsync -aH --numeric-ids --rsync-path='sudo rsync' --info=progress2 \
  /export/rfs-autosd/ companion:/export/rfs-autosd/
```

Then the repo and the serial tooling:

```sh
git clone https://github.com/youtalk/openadkit ~/src/openadkit
sudo usermod -aG dialout "$USER"
```

Vendor SDK material stays off this list unless the companion is
administrator-only; it must not become reachable from a shared tailnet.

Verify: `showmount -e localhost` lists both exports, and `ss -ulpn | grep :69`
shows tftpd listening.

## 5. Host hardening and unattended updates

```sh
# put the admin pubkey in ~/.ssh/authorized_keys and verify a key login FIRST
printf 'PasswordAuthentication no\nPermitRootLogin no\n' \
  | sudo tee /etc/ssh/sshd_config.d/50-x5h.conf
sudo systemctl reload ssh
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
```

Confirm the key login works in a second session before reloading sshd —
locking yourself out of an always-on machine defeats its purpose.

## 6. Access tiers

Administrators get the whole bench. External developers get the board's
SSH port and nothing else — not the companion, not TFTP, not NFS. Merge
this with any existing policy rather than replacing it:

```jsonc
{
  "tagOwners": {
    "tag:x5h-gw":  ["autogroup:admin"],
    "tag:x5h-ext": ["autogroup:admin"]
  },
  "groups": {
    "group:x5h-admin": ["yutaka.kondo@youtalk.jp"],
    "group:x5h-ext":   []   // external developer logins land here
  },
  "acls": [
    {"action": "accept", "src": ["group:x5h-admin"], "dst": ["tag:x5h-gw:*", "192.168.0.0/24:*"]},
    {"action": "accept", "src": ["group:x5h-ext", "tag:x5h-ext"], "dst": ["192.168.0.20:22"]}
  ],
  "autoApprovers": {"routes": {"192.168.0.0/24": ["tag:x5h-gw"]}}
}
```

The board's own sshd is key-only (`PasswordAuthentication no`,
`PermitRootLogin prohibit-password`), so the well-known development root
password is not a network credential. It still works on the serial
console, which is deliberate — that is the recovery path.

### Onboarding an external developer

1. Add their login to `group:x5h-ext`.
2. Append their public key to `/etc/ssh/authorized_keys.d/root` on the
   board — or to `config/x5h-authorized-keys` if it should survive an
   image rebuild.
3. Verify with the checks below, from their node.

Offboarding is the reverse; remember the key on the board outlives the
tailnet removal.

## 7. Verification

### Reboot drill

Set the BIOS to power on after AC loss, then `sudo reboot` and — with no
keyboard attached — check from elsewhere on the tailnet:

```sh
ssh companion 'tailscale status | head -3 \
  && ip -4 addr show <BIF> | grep 192.168.0.1 \
  && showmount -e localhost \
  && ss -ulpn | sed -n /:69/p \
  && systemctl is-active nftables tftpd-hpa nfs-kernel-server' \
  && echo COMPANION_REBOOT_PASS
```

### Access tiers

From an admin node:

```sh
tailscale ping <companion> && ssh companion true && ssh root@192.168.0.20 true \
  && echo ACL_ADMIN_OK
```

From a node joined with a `tag:x5h-ext` auth key, using a key authorised on
the board — the first must succeed and the rest must all fail:

```sh
ssh -i <key> root@192.168.0.20 true                  # expect success
ssh -i <key> -o PubkeyAuthentication=no -o BatchMode=yes root@192.168.0.20 true  # expect failure
nc -w3 -z <companion-tailscale-ip> 22                # expect failure
nc -w3 -z 192.168.0.1 2049                           # expect failure
nc -w3 -zu 192.168.0.1 69                            # expect failure
```

The three service probes are blocked twice over — the ACL never admits
them, and the firewall scopes those ports to `<BIF>`. Either alone would
do; testing them proves the combination rather than one layer, which is
the point of checking from a real external node instead of reasoning about
the policy.

## Related

- [UFS self-boot](selfboot.md) — why the board no longer depends on this
  host, and the rescue commands that still do.
- [CR52 slot update](cr52-slot-update.md) — the remote firmware workflow
  this host makes reachable.
