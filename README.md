# SSH Icinga2 NRPE Config Collector

An interactive Bash utility that scans an IPv4 range for SSH services, checks on each selected
device what the [Icinga2 NRPE Universal Bootstrap Kit](https://github.com/Michdo93/Icinga2-NRPE-Universal-Bootstrap-Kit)
installed and configured, and creates `services-<hostname>.conf` with the
[Icinga2 NRPE Service Generator](https://github.com/Michdo93/icinga2-nrpe-service-generator).
For every device you choose whether the file is stored **on this machine** or **on the remote host**.

Typical use: run it on the Icinga2 host, which has SSH access to all devices, and store every
file locally in `/etc/icinga2/conf.d/nrpe/`.

```
ssh-icinga2-nrpe-manager            ->  NRPE on all devices (bootstrap kit over SSH)
ssh-icinga2-nrpe-config-collector   ->  services-<hostname>.conf for every device
icinga2 daemon -C && systemctl reload icinga2
```

## Requirements

- Bash 4, OpenSSH client, `timeout`, `xargs`, and `curl` or `wget` (the generator is downloaded
  once on this machine and sent to the devices; they need no Internet access).
- Devices: NRPE installed by the bootstrap kit, `python3`, an SSH account. Root or sudo is **not**
  needed (only files are read; remote files go to a directory the SSH user can write).

## Run

```bash
chmod +x collect-configs.sh
./collect-configs.sh
# on the Icinga2 host, directly into the configuration:
sudo OUTPUT_DIR=/etc/icinga2/conf.d/nrpe ./collect-configs.sh
```

1. **Settings (once):** local directory (default `./icinga2-nrpe-services`), directory on the
   remote hosts (default `~` of the SSH user), all NRPE commands or only the kit's, Host
   objects yes/no.
2. **Range:** first and last IPv4 address; the range is scanned for SSH servers (32 parallel
   probes, no ping needed).
3. **Per device:** confirm, enter the SSH user name, log in (up to three attempts, then the next
   device). The tool shows what the kit set up:

   ```
     Host name:        pc-lab-01 (Ubuntu 24.04 LTS)
     NRPE server:      4.1.0-1ubuntu3, service active
     Plugins:          monitoring-plugins-basic 2.3.5-1ubuntu3
     Bootstrap kit:    configured (10 commands)
     Commands:         check_load check_users ... check_svc_nginx
     allowed_hosts:    127.0.0.1,::1,192.168.1.10
   Store services-pc-lab-01.conf on this machine? (No: on the remote host in ~) [Y/n]
   ```

   The Host object gets the address you connected to. An existing local file is only
   overwritten after confirmation. Devices without NRPE are skipped with a hint; without the
   kit's file you can fall back to all NRPE commands.
4. **End:** summary; if the local directory lies below `/etc/icinga2/` and `icinga2` is
   installed, the configuration can be validated right away (`icinga2 daemon -C`).

One SSH login per device: the first connection is kept as an SSH master connection, the check
and the generator run over it without asking for the password again.

## Options (environment)

| Variable | Default | Meaning |
|---|---|---|
| `OUTPUT_DIR` | `./icinga2-nrpe-services` | default for the local directory |
| `REMOTE_DIR` | `~` | default for the directory on the remote hosts |
| `GENERATOR_URL` | `generate-services.py` of icinga2-nrpe-service-generator (`main`) | other generator |
| `GENERATOR_FILE` | – | local copy of `generate-services.py` (no download) |
| `SSH_PORT` | `22` | SSH port for scan and login |
| `CONNECT_TIMEOUT` | `4` | seconds per connection attempt |
| `SCAN_PARALLEL` | `32` | parallel probes while scanning |

## Limits

- IPv4 ranges only, at most 65,536 addresses per run.
- Linux devices with a POSIX shell and Debian packaging (`dpkg`).
- New host keys are accepted on first login (`accept-new`); a changed key stops the login for that device.

## License

MIT License. Feel free to use and modify.
