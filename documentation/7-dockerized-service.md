This is a DevOps project inspired from [roadmap.sh: Dockerized Service](https://roadmap.sh/projects/dockerized-service-deployment)

## Dockerized Service
*The goal of this project is to dockerize a simple Node.js service and deploy it to a remote server using GitHub Actions, practising secrets management along the way.*

| Roadmap part | In this project |
|---|---|
| 1. A Node.js service with `/` and a `/secret` route behind Basic Auth, settings in a `.env` file | The existing app gains the `/secret` route |
| 2. A Dockerfile, run locally, with `.env` kept out of the image | A Dockerfile in `app/`, run with Docker on my PC |
| 3. A remote server | The existing app server |
| 4. A workflow that builds the image, pushes it to a registry and deploys it | The existing workflow changes from "send a commit ID" to "build an image, push it, send the image's name" |

On the server, Docker replaces the hand-built Node setup. The app runs in a container instead of as a systemd service. nginx in front stays as it is.

## Decisions

- **Images are stored in GHCR**, GitHub's own registry, as a public image. The workflow pushes with GitHub's built-in token, so there is no extra account or password, and the server downloads without credentials. Public is safe only because the image contains no secrets, which the roadmap requires anyway. AWS's registry (ECR) is a possible later comparison.
- **Production secrets live in the GitHub environment `main`**, and the workflow passes them to the server during each deploy. That is the "secrets management in GitHub Actions" the roadmap asks for. AWS Secrets Manager is a possible later step.
- **Basic Auth over plain HTTP, with throwaway values.** HTTPS is a later topic.

### Basic Auth and HTTPS

They work at different layers:

| | What it answers | Where it lives |
|---|---|---|
| HTTP / HTTPS | How the request travels. HTTPS is HTTP wrapped in encryption. | The connection |
| Basic Auth | Who is asking: a username and password sent with the request | One header in each request |

The browser sends the username and password like this:

```
Authorization: Basic YWRtaW46c2VjcmV0
```

That is Base64, a reversible way of writing text, not encryption:

```bash
echo -n 'admin:secret' | base64       # YWRtaW46c2VjcmV0
echo YWRtaW46c2VjcmV0 | base64 -d     # admin:secret
```

Over plain HTTP the header travels readable to anyone watching the network. Over HTTPS the whole request is encrypted. Basic Auth is only safe on top of HTTPS, which is why the values used here are throwaway.

## 1. The `/secret` route

**`.env` stays out of git.** `.env` was added to `.gitignore` before the file was created, so it can never be committed by accident.

`app/.env`, with throwaway values:

```
SECRET_MESSAGE=<the secret message>
USERNAME=<a username>
PASSWORD=<a password>
```

**The check and the route**, in `app/server.js`:

```js
const crypto = require('crypto');

function sameText(a, b) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function basicAuth(req, res, next) {
  const expectedUser = process.env.USERNAME;
  const expectedPass = process.env.PASSWORD;
  if (!expectedUser || !expectedPass) {
    return res.status(500).send('Server is not configured');
  }

  const [scheme, encoded] = (req.headers.authorization || '').split(' ');
  if (scheme === 'Basic' && encoded) {
    const decoded = Buffer.from(encoded, 'base64').toString();
    const colon = decoded.indexOf(':');
    const user = decoded.slice(0, colon);
    const pass = decoded.slice(colon + 1);
    if (colon !== -1 && sameText(user, expectedUser) && sameText(pass, expectedPass)) {
      return next();
    }
  }

  res.set('WWW-Authenticate', 'Basic realm="secret"');
  res.status(401).send('Invalid username or password');
}

app.get('/secret', basicAuth, (req, res) => {
  res.send(process.env.SECRET_MESSAGE);
});
```

- **`basicAuth` is middleware**, a function that runs before the route. `app.get('/secret', basicAuth, ...)` means "check first, then answer". `next()` lets the request through to the route. Sending a response stops it.
- **Missing settings refuse everything.** Without the first `if`, an unset `USERNAME` and `PASSWORD` could match an empty username and password and let anyone in.
- **The header is decoded** from Base64 to `user:password` and split at the first colon, because a password may itself contain colons.
- **`sameText` compares in constant time.** A normal `===` stops at the first wrong character, and that tiny time difference can, in principle, help an attacker guess one character at a time.
- **`WWW-Authenticate` on a failed attempt** makes a browser show its login box, which covers the roadmap's "should be prompted for the username and password".

**Loading `.env` locally.** Node 22 and newer read the file themselves, so no extra package is needed. In `app/package.json`:

```json
"dev": "node --watch --env-file=.env server.js",
"start": "node server.js"
```

`npm start` is unchanged, because in production the values come from Docker, not from a file. With `--env-file`, a variable already set in the shell wins over the file, so `echo "$USERNAME"` in WSL should print nothing.

```bash
npm run dev

curl -i localhost:3000/secret                       # 401, with the WWW-Authenticate header
curl -i -u admin:wrongpass localhost:3000/secret    # 401
curl -u <username>:<password> localhost:3000/secret # the secret message
```

`http://localhost:3000/secret` in a browser shows a login box.

The change was not pushed yet. The pipeline would deploy it onto the current setup, where the variables do not exist, and the route would answer "Server is not configured". Safe, but pointless before the Dockerfile works.

## 2. The Dockerfile

An **image** is a packaged copy of the app with everything it needs to run: the operating system pieces, Node, the dependencies and the code. A **container** is an isolated process on the host, started from an image. The Dockerfile is the recipe for the image.

Docker on my PC: Docker Desktop on Windows runs the engine, and its WSL integration (Settings, Resources, WSL Integration) makes the `docker` command available inside WSL. `docker version` shows both halves: the **Client** (the command, in WSL) and the **Server** (the engine, in Docker Desktop). `docker run --rm hello-world` proved they talk to each other.

`app/Dockerfile`:

```dockerfile
FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

ENV HOST=0.0.0.0 \
    PORT=3000
EXPOSE 3000

USER node

CMD ["node", "server.js"]
```

| Line | What it does |
|---|---|
| `FROM node:22-alpine` | Starts from an official image with Node 22, the same major version as the server, on Alpine, a very small Linux |
| `WORKDIR /app` | All later steps work inside `/app` in the image |
| `COPY package.json package-lock.json ./` and `RUN npm ci --omit=dev` | Installs the dependencies before copying the code. Docker caches each step, so when only `server.js` changes, the slow install step is reused. |
| `COPY server.js ./` | Copies only the code file, by name. `.env` is never named, so it cannot get into the image. |
| `ENV HOST=0.0.0.0` | Inside a container, `127.0.0.1` means the container itself, so Docker could not pass traffic in. `0.0.0.0` means "listen on the container's network". This is why `HOST` became a setting in the service deployment phase. |
| `EXPOSE 3000` | Documents the port. It does not open anything by itself. |
| `USER node` | Runs the app as `node`, a non-root account that comes with the image, the same idea as `nodeapp` on the server |
| `CMD ["node", "server.js"]` | The command the container runs when it starts |

`app/.dockerignore`:

```
node_modules
.env
npm-debug.log
```

When building, Docker first sends the folder's contents to the engine, the **build context**. This file keeps those three out of it entirely. The `COPY` lines already avoid `.env`, so this is a second layer. It also avoids sending the local `node_modules`, which the image builds itself.

**Build and run locally**, in `app/`:

```bash
docker build -t playground-app:local .
docker run --rm -p 127.0.0.1:3000:3000 --env-file .env playground-app:local
```

- `-t playground-app:local` names the image. The part after `:` is the **tag**, a label for this version.
- `-p 127.0.0.1:3000:3000` connects my PC's port 3000 to the container's port 3000, reachable only from my own machine.
- `--env-file .env` hands the settings to the container when it starts. They are never stored in the image.

The three `curl` tests from step 1 and `/health` all answered as before.

**Checking that `.env` is not in the image:**

```bash
docker run --rm playground-app:local ls -la /app
# node_modules, package-lock.json, package.json, server.js. No .env.

docker run --rm playground-app:local env
# HOST=0.0.0.0, PORT=3000, NODE_VERSION=22.23.3. No SECRET_MESSAGE, USERNAME or PASSWORD.

docker run --rm playground-app:local id
# uid=1000(node) gid=1000(node)
```

The files in `/app` belong to root, while the app runs as `node`, so the running app can read its own code but cannot change it. The image is 249 MB.

## 3. The workflow builds and pushes the image

The rest of the phase in three steps:

| Step | What | Result |
|---|---|---|
| 3 | The workflow builds the image and pushes it to GHCR | The image exists in a registry, tagged with the commit ID |
| 4 | The server gets Docker and runs the app from that image | The container replaces the systemd service |
| 5 | The deploy step sends the image name and the secrets | A push deploys the new image automatically |

In this step only building was added. Deploying stayed as it was.

**The image is linked to the repository**, with a label in the Dockerfile, under `FROM`:

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/Tao-68/aws-eks-gitops-deployment-playground"
```

**A `build` job** in `.github/workflows/deploy.yml`, before the `deploy` job, which now has `needs: build` so it waits for it:

```yaml
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image: ${{ steps.push.outputs.image }}
    steps:
      - name: Get the code
        uses: actions/checkout@v4

      - name: Log in to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin

      - name: Build and push the image
        id: push
        run: |
          image="ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/playground-app:${GITHUB_SHA}"
          docker build -t "$image" app
          docker push "$image"
          echo "image=$image" >> "$GITHUB_OUTPUT"
```

- **Two jobs, each with only what it needs.** `build` may push images (`packages: write`) and sees none of the environment's secrets. `deploy` has the VPN and SSH secrets and cannot push images. A mistake or compromise in one job is limited to that job's rights.
- **`actions/checkout`** downloads the repo onto the runner. The old deploy job never needed it, because the server fetched the code itself. Building an image does need the code.
- **`GITHUB_TOKEN`** is a short-lived token GitHub creates for each run. It is never stored anywhere. Here it logs in to GHCR.
- **The image name** is `ghcr.io/<owner>/playground-app:<commit ID>`. GHCR requires lowercase, and the account is `Tao-68`, so `${GITHUB_REPOSITORY_OWNER,,}` (bash for "in lowercase") makes it `tao-68`.
- **Tagged with the commit ID, never `latest`**, so every image points to exactly one commit.
- **`outputs`** passes the image name from `build` to `deploy`, for step 5.

The first push also deployed the new code onto the systemd setup through the old deploy job. There, `/secret` answered "Server is not configured", because the settings did not exist yet. Safe, and the reason for the settings check.

**Making the image public.** A new GHCR image starts private. In GitHub: profile, Packages, `playground-app`, Package settings, Danger Zone, Change visibility, Public. Public is safe only because the image contains no secrets.

**Downloading it without logging in**, from WSL:

```bash
docker pull ghcr.io/tao-68/playground-app:<commit ID>
# four layers, "Pull complete", then a Digest
```

An image is a stack of **layers**, roughly one per step of the recipe: Alpine, Node, the dependencies, the code. Docker downloads each separately and reuses the ones it already has, so a code-only change downloads quickly. The **digest** is a fingerprint computed from the image's exact contents. The tag is a label I chose. The same digest always means the very same image.

## 4a. Docker on the app server

A new role, `roles/docker/tasks/main.yml`:

```yaml
- name: Install Docker
  ansible.builtin.apt:
    name: docker.io
    state: present

- name: Start and enable Docker
  ansible.builtin.systemd:
    name: docker
    state: started
    enabled: true
```

`docker.io` is Ubuntu's own Docker package. It was added to the app server's play in `setup.yml`, as the first role:

```yaml
    - role: docker
      tags: docker
```

```bash
ansible-playbook -i inventory.ini setup.yml --limit app --tags docker

# on the app server
docker --version                 # Docker version 29.1.3, build 29.1.3-0ubuntu4.1
sudo docker run --rm hello-world # Hello from Docker!
```

Here the engine runs on the server itself. On my PC it runs inside Docker Desktop.

**Nobody is added to the `docker` group.** Many guides do this so that `sudo` can be skipped. But anyone in that group can start a container with the server's whole disk mounted inside it, and read or change any file as root. The group is equivalent to root, without a password. `dev` and `deploy` stay out of it. The deploy command runs Docker as root through its single sudo rule.

## 4b. The container replaces the systemd service

**What is replaced and what stays.** The Docker role is not replaced. What goes is the previous way of running the app:

| | Before | After |
|---|---|---|
| What runs the app | systemd starts `node server.js` from a folder of code | Docker runs a container from an image |
| How the code reaches the server | The server clones the repo and runs `npm ci` | The server downloads a ready-made image from GHCR |
| What restarts it after a crash or reboot | systemd, through the unit file | Docker, through `--restart unless-stopped` |
| No longer needed | Node.js, the `nodeapp` account, `/opt/playground`, the unit file | Removed by the `app` role |
| The Docker engine | Not installed | Installed and kept running by the Docker role |

The **engine** is the program that runs containers. The Docker role installs it once. The **container** is the app running from one particular image, and each deploy replaces it.

**One owner each:**

| Piece | Owned by | Why |
|---|---|---|
| The engine, the `deploy` account, the deploy command, the sudo rule, the settings folder | Ansible | Server setup that rarely changes |
| Which image runs, and the container | The deploy command | Changes with every deploy |

If Ansible also started containers, a later Ansible run could replace the image the pipeline had just deployed.

Before this step the server had 2.5 GB of disk free (63% used) and about 500 MB of memory available, with no swap. Enough for this image, about 250 MB, but it will get tight once a database container joins.

**The deploy command**, `roles/app/templates/deploy-playground-app.j2`:

```bash
#!/bin/bash
set -euo pipefail

image="${1:-}"
if [[ ! "$image" =~ ^ghcr\.io/tao-68/playground-app:[0-9a-f]{40}$ ]]; then
  echo "usage: deploy-playground-app ghcr.io/tao-68/playground-app:<commit id> [--settings-from-stdin]" >&2
  exit 1
fi

settings=/etc/playground-app/app.env

if [[ "${2:-}" == "--settings-from-stdin" ]]; then
  umask 077
  incoming=$(mktemp)
  grep -E '^(SECRET_MESSAGE|USERNAME|PASSWORD)=.+$' > "$incoming" || true
  for key in SECRET_MESSAGE USERNAME PASSWORD; do
    if ! grep -q "^$key=" "$incoming"; then
      rm -f "$incoming"
      echo "missing $key on standard input" >&2
      exit 1
    fi
  done
  mv "$incoming" "$settings"
elif [[ -n "${2:-}" ]]; then
  echo "unknown option: $2" >&2
  exit 1
fi

if [[ ! -s "$settings" ]]; then
  echo "no settings in $settings" >&2
  exit 1
fi

docker pull --quiet "$image"
docker rm --force playground-app > /dev/null 2>&1 || true
docker run --detach --name playground-app --restart unless-stopped \
  --publish 127.0.0.1:{{ app_port }}:3000 \
  --env-file "$settings" \
  "$image" > /dev/null

for attempt in 1 2 3 4 5; do
  if curl -fs http://127.0.0.1:{{ app_port }}/health > /dev/null; then
    echo "deployed $image"
    exit 0
  fi
  sleep 2
done

echo "health check failed after deploying $image" >&2
docker logs --tail 20 playground-app >&2
exit 1
```

- **It takes an image name instead of a commit ID**, and accepts only my own image with a full commit ID as its tag. A leaked deploy key cannot make the server run someone else's image.
- **`--settings-from-stdin`** reads the three settings from standard input, the data piped into the command, so secrets never appear in a command line. Only lines for those three names are kept, all three must be present, and they are written to a file only root can read. Without the option, the settings from the last deploy are reused.
- **`--restart unless-stopped`** makes Docker start the container again after a crash or reboot, the job systemd did before.
- **`--publish 127.0.0.1:...`** matters. Ports Docker publishes bypass UFW, because Docker writes its own firewall rules. Binding to `127.0.0.1` keeps port 3000 reachable only from the server itself, for nginx.
- **`curl -fs`** checks health without printing the `curl: (7)` noise from before. On failure the container's last 20 log lines are printed, so the workflow shows why.

**The `app` role's tasks** keep the earlier ones as comments. The active tasks:

| Task | What it does |
|---|---|
| Check whether the old unit file exists | `stat`, registered as `old_unit` |
| Stop and disable the old service | Only `when: old_unit.stat.exists`, so later runs do not fail on a service that is gone |
| Remove the old unit file | Registered as `old_unit_removed` |
| Make systemd forget the old service | `daemon_reload`, only when a file was actually removed. systemd keeps a deleted unit in memory until it reloads. |
| Remove the old code, the `nodeapp` account, Node.js and npm | The image brings its own Node, so the server no longer needs one |
| Create the settings folder | `/etc/playground-app`, root only, `0700` |
| The four deploy tasks | Unchanged: the `deploy` account, its key, the deploy command, the sudo rule |

```bash
ansible-playbook -i inventory.ini setup.yml --limit app --tags app
```

The site was down from here until the first deploy, because the old service stopped before a container existed.

**The first deploy, by hand, over the VPN**, with the image from step 3 and the local `.env` as the settings:

```bash
sudo wg-quick up wg0
ssh -o IdentitiesOnly=yes -i ~/.ssh/github-deploy deploy@<app-private-ip> \
  "sudo /usr/local/bin/deploy-playground-app ghcr.io/tao-68/playground-app:<commit ID> --settings-from-stdin" \
  < app/.env
# deployed ghcr.io/tao-68/playground-app:<commit ID>
```

`<` sends the file's contents into the command on the server. The extra line before "deployed" is `docker pull --quiet` printing the image name.

| Check | Result |
|---|---|
| `curl http://<app-public-ip>/` | The greeting, now from the container |
| `curl -u <username>:<password> http://<app-public-ip>/secret` | `200 OK` and the secret message |
| `sudo docker ps` | One container, `playground-app`, published on `127.0.0.1:3000` only |
| `sudo ls -l /etc/playground-app/` | `app.env`, `-rw-------`, owned by root |

`curl -i` also showed the `Server: nginx/<version> (Ubuntu)` header and `X-Powered-By: Express`. Both tell an attacker what software and version run here. `server_tokens off;` in the nginx config and `app.disable('x-powered-by')` in `server.js` would hide them.

## 5. The workflow deploys the image, with the secrets

Until this step the `deploy` job still sent a commit ID, which the new deploy command refuses. Any push to `app/` would have failed at the deploy step, safely, without touching the running container.

**Three secrets** in the GitHub environment `main`:

| Name | Value |
|---|---|
| `SECRET_MESSAGE` | The secret message |
| `APP_USERNAME` | The username |
| `APP_PASSWORD` | The password |

They are named `APP_...` because a bare `USERNAME` is ambiguous next to the deploy and VPN secrets. The workflow maps them back to the names the app expects.

**The `Deploy` step** in the `deploy` job:

```yaml
      - name: Deploy
        env:
          IMAGE: ${{ needs.build.outputs.image }}
          SECRET_MESSAGE: ${{ secrets.SECRET_MESSAGE }}
          APP_USERNAME: ${{ secrets.APP_USERNAME }}
          APP_PASSWORD: ${{ secrets.APP_PASSWORD }}
        run: |
          printf 'SECRET_MESSAGE=%s\nUSERNAME=%s\nPASSWORD=%s\n' \
            "$SECRET_MESSAGE" "$APP_USERNAME" "$APP_PASSWORD" |
          ssh -i ~/.ssh/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
            deploy@${{ vars.APP_HOST }} \
            "sudo /usr/local/bin/deploy-playground-app $IMAGE --settings-from-stdin"
```

- **`needs.build.outputs.image`** is the image name the `build` job published, so `deploy` installs exactly what was just built.
- **`printf`** writes the three settings as lines in the `.env` format, and `|` pipes them into `ssh`. On the server they arrive as standard input for the deploy command, the same mechanism as the hand test with `< app/.env`, but fed from GitHub's secrets instead of a file.
- **The secrets never appear in a command line or the log.** They stay in environment variables on the runner and travel only through the encrypted SSH connection. GitHub also blanks out their values if they ever appear in output.

**Test:** a new greeting was committed and pushed. In the Actions tab `build` ran first, then `deploy`, both green. The site showed the new greeting, `/secret` still answered with the right username and password (so the settings travelled from GitHub to the server), and `sudo docker ps` showed the container running the image tagged with the new commit ID.

`curl -i` shows the response's headers as well as its content: the status code (`200 OK`, `401 Unauthorized`) and lines such as `WWW-Authenticate`, `Server` and `Content-Type`. Plain `curl` shows only the content. `-I` shows the headers only.

## Result

```
git push ──> build job: docker build, push ghcr.io/tao-68/playground-app:<commit>
         └─> deploy job ══VPN══> bastion ──SSH──> app server, as deploy
                 settings on stdin ──> deploy-playground-app <image> --settings-from-stdin
                                         writes /etc/playground-app/app.env (root, 0600)
                                         docker pull, replace the container, check /health
```

| Roadmap part | Where |
|---|---|
| A Node.js service with `/` and `/secret` behind Basic Auth | Step 1 |
| A `.env` file with `SECRET_MESSAGE`, `USERNAME`, `PASSWORD` | Step 1, kept out of git |
| A Dockerfile, run locally, `.env` not in the image | Step 2, checked inside the image |
| A remote server | The existing app server, Docker added in step 4a |
| A workflow that builds, pushes to a registry and deploys | Steps 3 and 5 |
| Secrets management in GitHub Actions | Step 5: environment secrets, passed on standard input |

## Architecture at the end of this phase

```
VISITOR
  browser ── HTTP, port 80 ──▶ app server: nginx, port 80 ──▶ container playground-app
                                (security group + UFW)          127.0.0.1:3000, user node
                                                                settings from /etc/playground-app/app.env

DEVELOPER
  PC: edit app/, npm run dev (settings from app/.env), http://localhost:3000
      or docker build + docker run --env-file .env, the same image locally
    └─ git push ──▶ GitHub, main
                      build job ──▶ GHCR: ghcr.io/tao-68/playground-app:<commit>   (public, no secrets)
                      deploy job (environment "main": VPN, SSH and app secrets)
                        ══ VPN, 10.8.0.4 ══▶ bastion ──▶ app server, as deploy
                        settings on stdin, deploy-playground-app <image>
                        app server: docker pull from GHCR, replace the container, check /health

ADMIN
  Unchanged: ssh bastion (key + MFA), ssh app (ProxyJump), ansible (ProxyJump as ansible),
  VPN as 10.8.0.2, tofu (AWS API, state in S3).
  Ansible now installs the Docker engine. It does not start containers.
```

| Perspective | At this point |
|---|---|
| Visitor | Unchanged: `http://<app-public-ip>/`. New route `/secret`, behind Basic Auth, over plain HTTP. |
| Developer | Can run the app directly with Node or as the same container production runs. A push builds an image, stores it in GHCR and deploys it with the settings from GitHub. |
| Admin | The server no longer has Node.js or a copy of the code. Ansible owns the engine and the deploy command. The deploy command owns the container. |

## Open items

- **Basic Auth over plain HTTP.** The credentials are readable on the network. HTTPS needs a domain name.
- **No rollback.** The old container is removed before the new one is checked. If the health check fails, the site stays down until the next good deploy. Keeping the previous image name and starting it again on failure would fix that.
- **Software versions are visible** in the `Server: nginx/<version> (Ubuntu)` header and `X-Powered-By: Express`. `server_tokens off;` and `app.disable('x-powered-by')` would hide them.
- **The base image tag `node:22-alpine` moves** with each Node 22 release. Pinning it by digest would make builds fully repeatable.
- **Old images pile up on the server.** Every deploy pulls a new image and keeps the previous ones, and the disk is small. `docker image prune` after a successful deploy would clear them.
- **Commented out in the `app` role:** the `Restart app` handler, the unused defaults (`app_repo`, `app_version`, `app_user`, `app_root`, `app_dir`) and `playground-app.service.j2`.
- **Possible later comparisons:** AWS's registry (ECR) instead of GHCR, and AWS Secrets Manager instead of GitHub secrets.
