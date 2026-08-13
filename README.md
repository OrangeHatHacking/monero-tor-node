# monero-tor-node

Monero full node + Tor middle/guard relay on Debian 13 (Trixie) amd64.

## What it sets up

- Monero full unpruned node (restricted RPC on clearnet + Tor)
- Tor middle/guard relay (non-exit) with bandwidth limits
- Monero hidden service (.onion for RPC + P2P)
- Automatic security updates (Debian + Tor Project repos)
- ufw firewall
- `node-status` monitoring command

## Requirements

- Debian 13 (Trixie) x86_64, root access
- 4+ GiB RAM, 512+ GiB SSD
- Port forwarding for Tor ORPort (default 443)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/OrangeHatHacking/monero-tor-node/main/install.sh | sudo bash
```

Or clone and run:

```bash
git clone https://github.com/OrangeHatHacking/monero-tor-node.git
cd monero-tor-node
sudo ./install.sh
```

Prompts for: relay nickname, contact email, bandwidth limits, ORPort.

## Usage

```bash
node-status              # overview
node-status monero       # monero only
node-status tor          # tor only
sudo nyx                 # tor live TUI
```

```bash
systemctl status monerod
systemctl status tor@default
tail -f /var/log/monero/monero.log
journalctl -fu tor@default
```

## Wallet connection

- Clearnet: `YOUR_IP:18089`
- Tor: `cat /var/lib/tor/monerod/hostname` then `<onion>:18089`

Both use restricted RPC (dangerous methods blocked).

## Backups

- `/var/lib/tor/monerod/` -- onion keys
- `/var/lib/tor/keys/` -- relay identity

## Updating Monero

Not in apt. Check https://www.getmonero.org/downloads/, replace binaries in `/usr/local/bin/`, restart monerod.

## Refs

- https://docs.getmonero.org/running-node/monerod-systemd/
- https://docs.getmonero.org/running-node/monerod-tori2p/
- https://community.torproject.org/relay/setup/guard/debian-ubuntu/
- https://support.torproject.org/little-t-tor/getting-started/installing/
