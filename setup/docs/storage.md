# Storage — reference LVM layout

State as built on `aes-server`. The scripts assume this setup and the
preflight verifies it.

## Physical

| Device | Partition | Size | Role |
|---|---|---|---|
| NVMe #1 | p1 | 1 GB | EFI System, vfat → `/boot/efi` |
| NVMe #1 | p2 | 2 GB | ext4 → `/boot` (outside LVM) |
| NVMe #1 | p3 | ~462 GB | PV of `vg0` |
| NVMe #2 | p1 | ~477 GB | PV of `vg0` |
| 3× HDD | whole | 1863 + 1397 + 1863 GB | PV of `vg1` |

> The names `/dev/nvme0n1` and `/dev/nvme1n1` **swap between reboots** on
> this hardware. Never use them in a script: derive the device from
> `pvs -o pv_name,pv_uuid` or from `lsblk -o NAME,SERIAL`.

## vg0 — 939 GB on NVMe

| LV | Mount | Size | Allocation | Filesystem |
|---|---|---|---|---|
| `lv_root` | `/` | 64 GB | linear | ext4 |
| `lv_swap` | swap | 16 GB | linear | swap |
| `lv_wal` | `/srv/wal` | 32 GB | linear | xfs |
| `lv_models` | `/srv/models` | **760 GB** | **striped 2× 512k** | xfs + `prjquota` |
| — | reserve | ~68 GB | | |

On the NVMe live **only** the model weights and the synchronously-written logs.
Every other GB given to the NVMe is tok/s taken away from colibrì, which is
disk-bound.

Verify the striping from the kernel:

```
findmnt -no OPTIONS /srv/models | tr ',' '\n' | grep -E 'sunit|swidth|prjquota'
# sunit=1024 swidth=2048  →  512 KiB × 2 disks
```

`sunit` is in 512-byte blocks: 1024 × 512 = 512 KiB stripe unit, and
`swidth / sunit` gives the number of disks.

## vg1 — 5123 GB on spinning disks

The disks are **heterogeneous** (the smallest is 1397 GB), so the 3-way
stripe is limited to `3 × 1397 = 4191 GB`. Mixed layout: striped where
bandwidth matters, linear on `sda`+`sdc` for the archive, which reclaims the
space beyond the smallest disk's limit.

| LV | Mount | Size | Allocation | Filesystem |
|---|---|---|---|---|
| `lv_docker` | `/var/lib/docker` | 300 GB | striped 3× | xfs (`ftype=1`) |
| `lv_appdata` | `/srv/appdata` | 500 GB | striped 3× | xfs |
| `lv_data` | `/srv/data` | 1200 GB | striped 3× | xfs + `prjquota` |
| `lv_home` | `/home` | 200 GB | striped 3× | ext4 |
| `lv_archive` | `/srv/archive` | 1200 GB | linear sda+sdc | xfs |
| `lv_backup` | `/srv/backup` | 800 GB | linear sda+sdc | xfs |
| — | reserve | ~923 GB | | |

## fstab

```
LABEL=wal     /srv/wal        xfs  defaults,noatime,logbsize=256k                     0 2
LABEL=models  /srv/models     xfs  defaults,noatime,nodiratime,logbsize=256k,prjquota 0 2
LABEL=docker  /var/lib/docker xfs  defaults,noatime,logbsize=256k,nofail              0 2
LABEL=appdata /srv/appdata    xfs  defaults,noatime,logbsize=256k,nofail              0 2
LABEL=data    /srv/data       xfs  defaults,noatime,nofail,prjquota                   0 2
LABEL=archive /srv/archive    xfs  defaults,noatime,nofail                            0 2
LABEL=backup  /srv/backup     xfs  defaults,noatime,nofail                            0 2
LABEL=home    /home           ext4 defaults,noatime,nofail                            0 2
```

`nofail` on the spinning disks: an old disk that doesn't respond at boot must
not stop you from reaching the shell.

## Project quotas

`prjquota` is a **mount option**, not a formatting one: XFS supports it
natively and nothing is needed in `mkfs`. But it takes effect **at mount**, not
with a `remount`: if you add it to fstab afterwards, you need `umount` and
`mount`.

```
/etc/projects            /etc/projid
10:/srv/models/gguf      gguf:10       → 100 GB
20:/srv/data/geodata     geodata:20    → 400 GB
21:/srv/data/corpora     corpora:21    → 400 GB
22:/srv/data/exports     exports:22    → 200 GB
```

`/srv/data/datasets` deliberately stays **without a quota**: it contains the
hand-validated fine-tuning datasets, the only thing on this server that does
not regenerate.

The quotas exist because **XFS never shrinks, ever**. A separate LV is an
irreversible commitment; a quota changes with one command. That is why the
GGUFs are a quota'd subdirectory of `/srv/models` instead of an LV of their
own.

## Volume map for the containers

```
/srv/appdata/neo4j/{data,logs,import}   graph state (knowledge-graph)
/srv/appdata/redis/                     Redis Stack AOF/RDB, shared
/srv/appdata/postgres-limen/            only if you don't use Neon
/srv/wal/neo4j-tx/                      NVMe — where the fsync latency lives
/srv/data/{geodata,corpora,exports,datasets}
/srv/archive/{hf,gguf-cold,colibri-cold,docker-images}
```

Always **explicit bind mounts**, never named or anonymous Docker volumes:
they would end up in `/var/lib/docker/volumes`, mixing persistent data and
image layers, and turning `docker system prune` into Russian roulette.

## ssh keys outside /home

`/home` is on spinning disks mounted `nofail`: if a disk doesn't respond at
boot, the server starts but `~/.ssh/authorized_keys` is unreachable.

```
AuthorizedKeysFile /etc/ssh/authorized_keys/%u .ssh/authorized_keys
```

with a copy in `/etc/ssh/authorized_keys/<user>` (0644, root:root).
Always test from a **second** session before closing the current one.
