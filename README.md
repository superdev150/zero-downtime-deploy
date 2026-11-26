# zero-downtime-deploy

A one-click deploy for a Laravel + Vite app on a **small VM**: the build runs elsewhere, everything ships through a
**single SSH connection over Google Cloud IAP**, and the live build is swapped **atomically**. The server's SSH port is
closed to the internet, and the deploy key can do exactly one thing.

```
 GitHub Actions (manual)            self-hosted runner (my Mac)                          VM (port 22 closed to internet)
 ───────────────────────            ──────────────────────────────────────               ───────────────────────────────
 Run workflow ───────────────────▶  checkout · composer · npm run build
                                    tar czf build.tgz
                                    ssh -o ProxyCommand="gcloud … start-iap-tunnel"  ─▶  sshd: key pinned to
                                        "deploy-build <sha>"   < build.tgz               command="bash scripts/deploy.sh"
                                                                                           ├ parse SSH_ORIGINAL_COMMAND
                                                                                           ├ git fetch; sha on main? newer than live?
                                                                                           ├ ff-only merge to <sha>
                                                                                           ├ size cap · no ../ in archive · unpack → build.new
                                                                                           ├ build.new has manifest? else stop
                                                                                           ├ mv build → build.old; mv build.new → build
                                                                                           └ post-deploy (artisan optimize, reload FPM)
```

> This is the deploy of the backend behind my apps ([Wallstudio](https://apps.apple.com/app/id6757434029) and
> [Rein](https://apps.apple.com/app/id6828685068)),
> generalised. It replaced a `git pull && npm run build` on the VM. With 1 GB of RAM that build took about 9 minutes,
> the web server stopped answering, and the admin panel showed "Vite manifest not found" until it finished.

## Design decisions

**Build where there is CPU.** A self-hosted runner (here a Mac) builds the frontend. The VM only unpacks a tarball,
which takes seconds and does not touch its memory.

**One connection, nothing to clean up.** The tarball travels on the **stdin** of the same SSH session that runs the
deploy. There is no scp step, no staging upload, and no half-uploaded files left behind if the job is cancelled.

**The key can do one thing.** In `authorized_keys` the deploy key is pinned with `command="bash scripts/deploy.sh"`
and `restrict` (see [`server/authorized_keys.example`](server/authorized_keys.example)). Whatever the client asks for
arrives in `$SSH_ORIGINAL_COMMAND`, and the script accepts exactly `deploy-build <40-hex sha>`. Even with the private
key, an attacker can only deploy a commit that is already on `main` and newer than what is live. They cannot get a
shell, forward ports or roll the server back.

**No open SSH port.** The firewall admits port 22 only from Google's IAP range. The runner reaches the VM with
`gcloud compute start-iap-tunnel` as a `ProxyCommand`, using the runner machine's Google session (2-step verification
included). The VM's host key is pinned through `known_hosts` from a secret (`StrictHostKeyChecking=yes`, no trust on
first use). The deploy key exists only on the runner and is not stored in GitHub. `-F /dev/null` and
`IdentityAgent=none` make sure the job uses that key and nothing from the runner user's `~/.ssh`.

**Atomic swap.** The new build is unpacked into `build.new`, verified (it must contain the Vite manifest), and then
two `mv` calls on the same filesystem replace the live directory. A broken or partial upload never reaches users.
The code is merged to the **exact commit that was built**, so the frontend and backend always match.

**Untrusted archive.** It is size-capped before unpacking (it cannot fill the disk). It is listed and rejected if any
path is absolute or contains `..`, so nothing is written outside `build.new`.

**Self-modifying script.** All the logic is inside `main()`, which bash reads in full before running it. The merge can
therefore rewrite `deploy.sh` itself without breaking the run in progress.

**Emergency path.** Run on the server by hand (no `SSH_ORIGINAL_COMMAND`), the same script pulls and builds locally:
slow, but it works without the runner.

**Serialised.** `concurrency: deploy-production` with `cancel-in-progress: false`. A second click waits for the first
deploy and never interrupts a swap.

## Tested

`tests/test-deploy.sh` plays the server on your machine. It creates a bare origin repo and a server checkout, then
calls `deploy.sh` exactly as sshd would. **29 checks**, including:

- first and later deploys; code at the built commit; manifest link; hook ran; no leftovers
- refused commands: `rm -rf /`, `bash -i`, a missing or short sha, extra arguments, `; reboot`, an empty command
- a commit from another branch (65); an **older** commit (65: a no-op merge would still have swapped in the old
  frontend, which the test caught while I wrote it)
- a build without a manifest (67: live build untouched, partial unpack removed)
- an archive with `../../escaped.txt` (66: nothing written outside); a 2 MB upload with a 1 MB cap (66)
- 2,000 probes of the live path while 5 deploys swap it

```bash
bash tests/test-deploy.sh      # macOS (bash 3.2, BSD tar) or Linux
```

CI runs it on Ubuntu together with `shellcheck`.

## Use it

1. Copy `scripts/deploy.sh` into your repo, and `example/post-deploy.sh` as `scripts/post-deploy.sh` (adapt it).
2. On the server: a deploy user that owns the checkout, its own read-only GitHub deploy key for `git fetch`, and the
   CI key in `authorized_keys` as in `server/authorized_keys.example`.
3. Copy `example/deploy.yml` to `.github/workflows/`, register a self-hosted runner with `gcloud` logged in, and set
   the variables and secrets listed at the top of the file.

Settings: `DEPLOY_BRANCH` (main), `BUILD_DIR` (public/build), `BUILD_MARKER` (.vite/manifest.json), `MAX_BUILD_MB` (200).

MIT licensed.
