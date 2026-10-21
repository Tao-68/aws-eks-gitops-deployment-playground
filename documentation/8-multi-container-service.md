This is a DevOps project inspired from [roadmap.sh: Multi-Container Service](https://roadmap.sh/projects/multi-container-service)

## Multi-Container Service
*The goal of this project is to run an API and its database as separate containers, managed together with Docker Compose, and to deploy them to the remote server through the existing pipeline.*

| Roadmap part | In this project |
|---|---|
| 1. A Todo API in Node.js with Express: list, create, read, update and delete todos | A new service in `todo-api/`, next to the existing `app/` |
| 2. MongoDB to store the todos, with the data kept on a volume | The official `mongo` image, data on a named volume |
| 3. Docker Compose to run the API and the database together | One compose file for the whole stack: playground app, Todo API and MongoDB |
| 4. Deployment to a remote server, set up with configuration management | The existing app server, prepared by Ansible |
| 5. A workflow that builds the images and deploys with Compose | The existing workflow, extended to a second image |
| Bonus: a reverse proxy in front | The existing nginx on the host, with a new route for `/todos` |

## Plan

| Step | What | Where |
|---|---|---|
| 0 | More memory and disk for the server | OpenTofu, the server |
| 1 | The Todo API, run with Node against a MongoDB container | My PC |
| 2 | A Dockerfile for the Todo API, containers connected by hand | My PC |
| 3 | Docker Compose for the whole stack, with database users | My PC |
| 4 | Ansible prepares the server: the Compose plugin, the stack folder, the nginx route | The server |
| 5 | The deploy command and the workflow switch to Compose | The server, GitHub |

Each step ends with a diagram of where things stand at that point. The diagram at the end of the document shows only the final result.

## Decisions

- **The Todo API is a second service, not a replacement.** The playground app stays. nginx sends `/todos` to the Todo API and everything else to the playground app. One entry point routing to several services is how most real servers look.
- **One compose file runs everything on the server**: the playground app, the Todo API and MongoDB. The deploy command stops managing a single container with `docker run` and asks Compose instead. One file then describes everything that runs on the server.
- **nginx stays on the host**, outside Docker. It already works, Ansible manages it, and it owns port 80. The roadmap's bonus of an nginx container would only rebuild what already exists.
- **Mongoose talks to MongoDB.** It checks every write against a declared shape: a title is required, `completed` defaults to false. The plain MongoDB driver accepts any shape, so the API code would have to check by hand.
- **MongoDB is private and has two users.** Its port is never published, so only containers on the Compose network reach it. The API logs in with its own user, limited to the `todos` database. The root user is only for admin work.
- **MongoDB's memory is capped.** By default its cache takes about half of (RAM minus 1 GB). `--wiredTigerCacheSizeGB 0.25` leaves room for everything else on a 2 GB server.

## Where this phase starts

```
Visitor ── HTTP :80 ──▶ app server (t3.micro, 1 GiB RAM, 8 GB disk)
                          nginx ──▶ container playground-app (127.0.0.1:3000)

Developer ── git push ──▶ GitHub Actions ──▶ GHCR (one image)
                                └── VPN ──▶ bastion ──▶ app server: deploy-playground-app <image>
```

## 0. More room on the server

The numbers at the start: about 500 MB of free memory, no swap, and 2.4 GB of free disk. MongoDB alone wants a few hundred MB of memory, its image takes about 800 MB of disk once unpacked, and Phase 9 will write backups to the same disk.

### Memory: t3.micro to t3.small

One line in `iac/main.tf`, in the app server's resource:

```hcl
instance_type = "t3.small"
```

**Not a rebuild.** For a server whose disk is an EBS volume, changing the type is an in-place update: OpenTofu stops the instance, changes the type and starts it again. `tofu plan` shows `~ update in-place` and `0 to destroy`. If it had shown a replacement, `prevent_destroy` would have stopped the apply.

| | After the change |
|---|---|
| Downtime | One to two minutes |
| Public IP | **Changed.** Without an Elastic IP, AWS gives a new public address on every stop and start. |
| Private IP | Unchanged, so the inventory, the SSH config and the workflow's `APP_HOST` needed no edits |
| The container | Came back by itself, because Docker starts at boot and the container has `--restart unless-stopped` |
| Cost | About twice the hourly price. `t3.small` is still on this account's free-tier list, `t3.medium` is not. |

Checks: `free -h` showed 1.9 GiB total and 1.4 GiB available, `nproc` still 2, the site answered on the new IP, and a manual workflow run was green.

### Disk: 8 GB to 20 GB

**Docker was not the problem.** `docker images` listed four app images of 249 MB each, but `docker system df` showed 282 MB in total. Images share layers: the Node base and the dependencies are stored once, and each image adds only its own thin layer. Removing the three unused images with `sudo docker image prune -a` freed 5.8 MB. Most of the disk was the operating system.

In `iac/main.tf`, inside the app server's resource:

```hcl
root_block_device {
  volume_size = 20
}
```

Only `volume_size` is set. `tofu state show` listed the current values first (`gp3`, 8 GB, `encrypted = false`), so setting a different `volume_type` by mistake would have shown up in the plan as a second change. 20 GB for the server plus 8 GB for the bastion stays within the free tier's 30 GB.

A volume grows while the server runs, with no stop and no IP change. AWS allows one change per volume about every 6 hours, and a volume can only grow.

**Three layers, three resizes.** AWS only resizes the outer one:

```
EBS volume       20 GB    ◀── tofu apply
└─ partition 1    6.9 GB  ◀── growpart
   └─ ext4        6.7 GB  ◀── resize2fs
```

```bash
lsblk                              # nvme0n1 is 20G, nvme0n1p1 (/) still 6.9G
df -hT /                           # filesystem type: ext4
sudo growpart /dev/nvme0n1 1       # disk and partition number, two arguments
sudo resize2fs /dev/nvme0n1p1      # the partition itself
df -h /                            # 19G, 15G available
```

### Where things stand after step 0

```
Visitor ── HTTP :80 ──▶ app server (t3.small, 2 GiB RAM, 20 GB disk)   ◀── changed
                          nginx ──▶ container playground-app (127.0.0.1:3000)

Developer ── git push ──▶ GitHub Actions ──▶ GHCR ──▶ app server        (unchanged)
```

## 1. The Todo API, run with Node

Everything in steps 1 to 3 happens on my PC.

### A MongoDB container to develop against

```bash
docker run --detach --name todo-mongo \
  --publish 127.0.0.1:27017:27017 \
  --volume todo-mongo-data:/data/db \
  mongo:8
```

No password yet, because only my own PC can reach it. Step 3 adds the users.

**What a volume is.** A container's own files sit in a thin writable layer on top of the image, and `docker rm` deletes that layer with the container. A **volume** is a folder that Docker manages outside any container and plugs into a container at a chosen path. `--volume todo-mongo-data:/data/db` means: use the volume named `todo-mongo-data` (created on first use) and show it inside the container at `/data/db`, the folder MongoDB writes to. The container can be deleted and recreated, and the data stays.

```bash
docker volume ls
docker volume inspect todo-mongo-data     # Mountpoint: where the files really live
```

On my PC the files live inside Docker Desktop's own VM. On the server they will be in `/var/lib/docker/volumes/<name>/_data`, which is what Phase 9 backs up.

| | Named volume | Bind mount |
|---|---|---|
| Syntax | `--volume todo-mongo-data:/data/db` | `--volume /some/host/folder:/data/db` |
| Who picks the host folder | Docker | Me |
| Typical use | Database files | Config files, code during development |

### The project

```bash
mkdir todo-api && cd todo-api
npm init -y
npm install express mongoose
```

`package.json` gets the same scripts as `app/`: `"dev": "node --watch --env-file=.env server.js"` and `"start": "node server.js"`.

`todo-api/.env`, kept out of git by the existing `.env` rule:

```
MONGODB_URI=mongodb://127.0.0.1:27017/todos
PORT=3001
```

`/todos` at the end of the address is the database name. MongoDB creates it on the first write. Port 3001, because the playground app already uses 3000.

### `server.js`

**The model**, the shape of a todo:

```js
const todoSchema = new mongoose.Schema(
  {
    title: { type: String, required: true, trim: true },
    completed: { type: Boolean, default: false },
  },
  { timestamps: true }
);
const Todo = mongoose.model('Todo', todoSchema);
```

`timestamps: true` adds `createdAt` and `updatedAt`. Mongoose stores `Todo` documents in a collection called `todos`.

**The routes:**

| Route | Mongoose call | Answer |
|---|---|---|
| `GET /todos` | `Todo.find()` | 200 with the list |
| `POST /todos` | `Todo.create({ title, completed })` | 201 with the new todo |
| `GET /todos/:id` | `Todo.findById(id)` | 200, or 404 |
| `PUT /todos/:id` | `Todo.findByIdAndUpdate(id, { title, completed }, { returnDocument: 'after', runValidators: true })` | 200, or 404 |
| `DELETE /todos/:id` | `Todo.findByIdAndDelete(id)` | 204 with no body, or 404 |
| `GET /health` | `mongoose.connection.readyState === 1` | 200, or 503 when the database is unreachable |

- **`title` and `completed` are picked from the body by name.** Passing `req.body` straight to Mongoose would let a client set fields such as `createdAt`.
- **`req.body ?? {}`.** In Express 5, `req.body` is `undefined` when a request has no JSON body. Without the fallback the route would crash with a 500 instead of answering "title is required".
- **A partial PUT works.** With only `{"completed":true}`, `title` is `undefined`, and Mongoose leaves undefined fields out of an update.
- **`runValidators: true`** turns the schema rules back on, which updates skip by default.
- **`return res.status(404)...`.** The `return` stops the function. Without it, the code goes on and tries to send a second response.
- **`/health` checks the database connection**, not only that Node runs. An API without its database is not healthy.

**The error handler**, after all routes. Express recognises it by its four parameters:

```js
app.use((err, req, res, next) => {
  if (err.name === 'ValidationError') {
    return res.status(400).json({ error: err.message });
  }
  if (err.name === 'CastError') {
    return res.status(400).json({ error: 'Invalid id' });
  }
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Invalid JSON' });
  }
  console.error(err);
  res.status(500).json({ error: 'Internal server error' });
});
```

In Express 5 an `async` route that throws lands here by itself. `ValidationError` is a missing title, `CastError` an id that is not a valid MongoDB id (such as `/todos/abc`), and `entity.parse.failed` broken JSON. The `CastError` message is short on purpose, because Mongoose's own message names internal details.

**Start-up:** connect first, listen second.

```js
async function start() {
  try {
    await mongoose.connect(process.env.MONGODB_URI);
  } catch (err) {
    console.error('Could not connect to MongoDB:', err.message);
    process.exit(1);
  }
  app.listen(port, host, () => {
    console.log(`Todo API listening on http://${host}:${port}`);
  });
}

start();
```

A process that exits can be restarted by Docker. A process that keeps running without its database fails every request.

### Test

```bash
npm run dev

curl -i -X POST localhost:3001/todos -H 'Content-Type: application/json' -d '{"title":"learn compose"}'
curl localhost:3001/todos
curl -i localhost:3001/todos/<id>
curl -i -X PUT localhost:3001/todos/<id> -H 'Content-Type: application/json' -d '{"completed":true}'
curl -i -X DELETE localhost:3001/todos/<id>
curl -i localhost:3001/todos/<id>         # 404
curl -i localhost:3001/todos/abc          # 400
curl -i -X POST localhost:3001/todos -H 'Content-Type: application/json' -d '{}'   # 400
curl localhost:3001/health
```

**Persistence:** create a todo, `docker rm -f todo-mongo`, start the container again with the same `docker run`, and list the todos. The todo is still there, because it lives in the volume.

**`npm start dev` is not `npm run dev`.** `npm start` always runs the `start` script and passed `dev` along as an ignored argument. `start` has no `--env-file`, so `MONGODB_URI` was undefined and Mongoose refused to connect. `start` is one of the few scripts npm runs without `run`.

### Where things stand after step 1

```
My PC
  node server.js (npm run dev, port 3001)
     │  mongodb://127.0.0.1:27017/todos
     ▼
  container todo-mongo (127.0.0.1:27017, no password)
     └─ volume todo-mongo-data ──▶ /data/db

The server: unchanged
```

## 2. The Dockerfile

`todo-api/Dockerfile` and `todo-api/.dockerignore` are copies of the ones in `app/`, with one change:

| | `app/` | `todo-api/` |
|---|---|---|
| `ENV PORT` and `EXPOSE` | 3000 | 3001 |

Everything else is the same: `node:22-alpine`, the `LABEL` that links the image to this repository, the package files and `npm ci --omit=dev` before the code, `HOST=0.0.0.0` and `USER node`.

```bash
docker build -t todo-api:local todo-api
```

### Containers find each other by name

`127.0.0.1` inside a container means the container itself, not my PC. With `MONGODB_URI=mongodb://127.0.0.1:27017/todos` the API would look for MongoDB inside its own container and find nothing.

Containers on the same user-created **network** reach each other by container name, because Docker runs a small DNS server for that network:

```bash
docker network create todo-net
docker network connect todo-net todo-mongo

docker run --detach --name todo-api \
  --network todo-net \
  --publish 127.0.0.1:3001:3001 \
  --env MONGODB_URI=mongodb://todo-mongo:27017/todos \
  todo-api:local
```

- **`docker network connect`** attaches the running MongoDB container without recreating it.
- **`todo-mongo:27017`.** The host name is the container name.
- **`--publish`** is only for `curl` from my PC. The API reaches MongoDB inside `todo-net`, with no published port.

### Checks

```bash
docker logs todo-api                  # Todo API listening on http://0.0.0.0:3001
curl localhost:3001/health
curl localhost:3001/todos             # the todos from step 1
docker exec todo-api whoami           # node
docker exec todo-api ls -a /app       # no .env
```

The todos written by the `npm run dev` version show up through the container, because the data is in the volume, not in either container.

### Where things stand after step 2

```
My PC
  network todo-net
  ┌─────────────────────────────────────────────────────────┐
  │ container todo-api  ── mongodb://todo-mongo:27017 ──▶ container todo-mongo
  │ (127.0.0.1:3001)                                       │  └─ volume todo-mongo-data
  └─────────────────────────────────────────────────────────┘
  Everything here was started and wired by hand.

The server: unchanged
```

## 3. Docker Compose, locally

Compose replaces the hand-written commands of step 2 with one file. It creates the network, attaches every service to it, and the service name becomes the host name.

The step 2 containers, network and volume were removed first: `docker rm -f`, `docker network rm`, `docker volume rm`. The new database has to start from an empty volume, for the reason below.

### Two database users

| User | Created by | Can do | Used by |
|---|---|---|---|
| root | `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD`, a feature of the `mongo` image | everything | admin work only |
| todo | the init script below | read and write in `todos`, nothing else | the Todo API |

If the API were ever exploited, the attacker would reach the todos, not every database and setting.

**The `mongo` image creates users only on its very first start**, when `/data/db` is empty. It runs the scripts in `/docker-entrypoint-initdb.d/` once and never again. Changing a password in `.env` later does not change it in the database.

`mongo/init-todo-user.js`, in the repository root:

```js
db.getSiblingDB('todos').createUser({
  user: process.env.TODO_DB_USER,
  pwd: process.env.TODO_DB_PASSWORD,
  roles: [{ role: 'readWrite', db: 'todos' }],
});
```

It runs inside MongoDB's shell, `mongosh`, which reads environment variables through `process.env`. No password is written in the file.

### The settings

`.env` in the repository root, ignored by git. Compose reads a `.env` next to the compose file by itself and fills in each `${...}`:

```
MONGO_ROOT_USERNAME=root
MONGO_ROOT_PASSWORD=<a password>
TODO_DB_USER=todo
TODO_DB_PASSWORD=<a password>
```

Letters and digits only. The todo password goes inside a connection address, where `@`, `:` and `/` have their own meaning.

### `compose.yaml`

```yaml
name: playground

services:
  playground-app:
    build: ./app
    env_file: app/.env
    ports:
      - "127.0.0.1:3000:3000"
    restart: unless-stopped

  todo-api:
    build: ./todo-api
    environment:
      MONGODB_URI: mongodb://${TODO_DB_USER:?}:${TODO_DB_PASSWORD:?}@mongo:27017/todos
    ports:
      - "127.0.0.1:3001:3001"
    depends_on:
      mongo:
        condition: service_healthy
    restart: unless-stopped

  mongo:
    image: mongo:8
    command: ["--wiredTigerCacheSizeGB", "0.25"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_ROOT_USERNAME:?}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PASSWORD:?}
      TODO_DB_USER: ${TODO_DB_USER:?}
      TODO_DB_PASSWORD: ${TODO_DB_PASSWORD:?}
    volumes:
      - mongo-data:/data/db
      - ./mongo/init-todo-user.js:/docker-entrypoint-initdb.d/init-todo-user.js:ro
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s
    restart: unless-stopped

volumes:
  mongo-data:
```

- **`name: playground`** is the project name. Compose puts it in front of everything it creates: the containers, the network `playground_default` and the volume `playground_mongo-data`. Without it, the folder name would be used.
- **`build:`** builds each app from its folder. The server has no source code and will use `image:` instead (step 4).
- **`@mongo:27017`.** The service name is the host name, as with `todo-net` in step 2.
- **`${TODO_DB_USER:?}`.** The `:?` makes Compose refuse to start when the variable is missing or empty. Without it, a missing value silently becomes an empty string and shows up later as a confusing login error.
- **`environment:` sets single variables, `env_file:` loads a file.** The playground app reads its three settings from `app/.env`. `todo-api/.env` is not used here, only by `npm run dev`.
- **`mongo` has no `ports:`.** It is reachable only inside the Compose network, not even from my PC.
- **`command:`.** The image puts `mongod` in front of these arguments by itself, so this only adds the cache limit.
- **`healthcheck`** asks MongoDB for a `ping` every 10 seconds. `start_period` gives it 20 seconds to boot before failures count.
- **`depends_on` with `service_healthy`** starts the API only once MongoDB answers. A plain `depends_on` waits only until the container exists.
- **`:ro`** mounts the init script read-only.
- **The top-level `volumes:`** declares the named volume. Compose creates it on the first `up`.

### Run and check

```bash
docker compose up -d --build
docker compose ps                 # three services, mongo "(healthy)"
docker compose logs todo-api      # Todo API listening on http://0.0.0.0:3001
```

The curl tests from step 1 pass on port 3001, and `curl localhost:3000/` still shows the playground app.

**The todo user is limited to `todos`:**

```bash
# reading the admin database is refused
docker compose exec mongo mongosh -u todo -p <todo password> --authenticationDatabase todos \
  --eval 'db.getSiblingDB("admin").system.users.countDocuments()'
# MongoServerError: not authorized on admin ...

# writing to another database is refused
docker compose exec mongo mongosh -u todo -p <todo password> --authenticationDatabase todos \
  --eval 'db.getSiblingDB("other").stuff.insertOne({a: 1})'
# MongoServerError: not authorized on other ...
```

`db.adminCommand({listDatabases: 1})` is **not** refused for the todo user, which looked like admin rights at first. Since MongoDB 4.0.5, a user without the right to list all databases gets a filtered answer that contains only the databases it has rights on. The todo user saw only `todos`. The root user sees `admin`, `config`, `local` and `todos`.

A password after `-p` ends up in the shell history and is visible to other users of the machine while the command runs. Acceptable on my own PC with test values, not on a shared server.

**Persistence:** create a todo, `docker compose down` (removes the containers and the network, keeps the volume), `docker compose up -d`, list the todos. The todo is still there. `docker compose down -v` would also delete the volume, and with it the database.

### Where things stand after step 3

```
My PC, Compose project "playground"
  network playground_default
  ┌──────────────────────────────────────────────────────────────────────┐
  │ playground-app (127.0.0.1:3000)       built from ./app               │
  │                                                                      │
  │ todo-api (127.0.0.1:3001)             built from ./todo-api          │
  │    │ mongodb://todo:<password>@mongo:27017/todos                     │
  │    ▼                                                                 │
  │ mongo (no published port)             users: root, todo              │
  │    └─ volume playground_mongo-data                                   │
  └──────────────────────────────────────────────────────────────────────┘
  Settings from .env (root folder) and app/.env, both ignored by git.

The server: unchanged. Still one container started with docker run.
```

## 4. Ansible prepares the server

Step 4 puts everything in place on the server without starting it. The live site keeps running on the old container until step 5 switches over.

### The Compose plugin

In the docker role, next to `docker.io`:

```yaml
- name: Install Docker
  ansible.builtin.apt:
    name:
      - docker.io
      - docker-compose-v2
    state: present
```

`docker-compose-v2` is the **package**, `docker compose` (with a space) is the **command** it adds. Compose v1 was a separate Python program called `docker-compose`, with a hyphen, and is discontinued. Compose v2 is a plugin of the `docker` command. Ubuntu named the new package `-v2` to tell it apart from the old `docker-compose` package. Docker's own package repository calls the same thing `docker-compose-plugin`. `apt-cache policy docker-compose-v2` on the server showed a candidate version before the package was added.

### The project folder

Compose calls the folder that holds `compose.yaml` and `.env` the **project directory**. On the server it is `/etc/playground`:

| Path | Contents | Written by |
|---|---|---|
| `/etc/playground/` | the project directory, root only (`0700`) | Ansible |
| `/etc/playground/compose.yaml` | the server's compose file | Ansible, from a template |
| `/etc/playground/init-todo-user.js` | the MongoDB user script | Ansible, copied from `mongo/` |
| `/etc/playground/.env` | the secrets and the two image names | the deploy command, step 5 |

`sudo docker compose ...` run inside `/etc/playground` finds `compose.yaml` and `.env` by itself.

### The server's compose file

`ansible/roles/app/templates/compose.yaml.j2`:

```yaml
name: playground

services:
  playground-app:
    image: ${PLAYGROUND_APP_IMAGE:?}
    environment:
      SECRET_MESSAGE: ${APP_SECRET_MESSAGE:?}
      USERNAME: ${APP_USERNAME:?}
      PASSWORD: ${APP_PASSWORD:?}
    ports:
      - "127.0.0.1:{{ app_port }}:3000"
    restart: unless-stopped

  todo-api:
    image: ${TODO_API_IMAGE:?}
    environment:
      MONGODB_URI: mongodb://${TODO_DB_USER:?}:${TODO_DB_PASSWORD:?}@mongo:27017/todos
    ports:
      - "127.0.0.1:{{ todo_api_port }}:3001"
    depends_on:
      mongo:
        condition: service_healthy
    restart: unless-stopped

  mongo:
    # the same as in the local compose.yaml, except the init script path:
    volumes:
      - mongo-data:/data/db
      - ./init-todo-user.js:/docker-entrypoint-initdb.d/init-todo-user.js:ro
    # ...

volumes:
  mongo-data:
```

How it differs from the local file:

| | Local `compose.yaml` | Server `compose.yaml.j2` |
|---|---|---|
| Where the apps come from | `build: ./app`, from the source | `image: ${...}`, from GHCR. The deploy command writes the exact image names into `.env`. |
| The playground app's settings | `env_file: app/.env` | `environment:` from `.env`, like all other secrets |
| Ports | fixed numbers | `{{ app_port }}` and `{{ todo_api_port }}` from Ansible |

- **Two kinds of placeholders in one file.** `{{ ... }}` is Jinja, filled in by Ansible when it writes the file. `${...}` is Compose, which Ansible leaves alone and Compose fills in from `.env` at runtime. The brackets differ, so they do not clash.
- **`${APP_USERNAME}`, not `${USERNAME}`.** When Compose fills in `${...}`, a variable already set in the shell wins over `.env`. `USERNAME` and `USER` are common shell variables, so a stray one could silently replace the app's login. The `APP_` prefix avoids that and matches the GitHub secret names. `environment:` maps them back to the names the app reads.

### The tasks

`group_vars/app/vars.yml` gets `todo_api_port: 3001`. The app role gets three tasks:

```yaml
- name: Create compose folder
  ansible.builtin.file:
    path: /etc/playground
    state: directory
    owner: root
    group: root
    mode: '0700'

- name: Deploy docker compose file
  ansible.builtin.template:
    src: compose.yaml.j2
    dest: /etc/playground/compose.yaml
    owner: root
    group: root
    mode: '0600'

- name: Deploy MongoDB init script
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/../mongo/init-todo-user.js"
    dest: /etc/playground/init-todo-user.js
    owner: root
    group: root
    mode: '0644'
```

- **`{{ playbook_dir }}/../mongo/...`** is the same file the local compose uses. One copy for both environments, so they cannot drift apart.
- **Why `0644` inside a `0700` folder.** Permissions are checked along the path being used. A user on the server walks through `/etc/playground` and is stopped by its `0700`. The container never uses that path. dockerd runs as root, opens the file when it starts the container, and shows it inside the container at `/docker-entrypoint-initdb.d/init-todo-user.js`. There, only the container's own folders and the file's own mode count. MongoDB runs as the user `mongodb`, which is neither the owner nor in the group, so it needs the "others" read bit, the last `4`. With `0600` the init script would fail.

### nginx: `/todos` goes to the Todo API

A second `location` in `nginx.conf.j2`:

```nginx
    location /todos {
        proxy_pass http://127.0.0.1:{{ todo_api_port }};
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
```

nginx picks the **longest matching prefix**, whatever the order in the file. `/todos` and `/todos/<id>` go to the Todo API, everything else falls through to `location /` and the playground app.

### Run

`ansible.cfg` now names the inventory, so `-i inventory.ini` is no longer needed:

```ini
[defaults]
inventory = inventory.ini
```

```bash
ansible-playbook setup.yml --limit app --tags docker,app,nginx --check --diff
ansible-playbook setup.yml --limit app --tags docker,app,nginx
```

**Three failures on the way:**

| Error | Cause | Fix |
|---|---|---|
| `No inventory was parsed`, `skipping: no hosts matched` | The command had no `-i inventory.ini` and `ansible.cfg` did not name one. Nothing ran. | `inventory = inventory.ini` in `ansible.cfg` |
| `Connection closed by UNKNOWN port 65535` | The jump through the bastion failed. For that hop SSH takes the key from the ssh-agent, which was empty after WSL restarted. | `ssh-add ~/.ssh/ansible` |
| The template task could not find `deploy-playground-app.j2` | The current deploy script had been renamed while cleaning up old templates. | Renamed back. A task's `src:` must match the file name exactly, so reference copies need a different name, such as `copy ...`. |

### Checks

```bash
docker compose version
sudo ls -la /etc/playground                 # compose.yaml 0600, init-todo-user.js 0644
sudo docker ps                              # still only the old playground-app container
curl -i http://<app-public-ip>/todos        # 502 Bad Gateway
```

The 502 is expected. nginx forwards `/todos` to port 3001, where nothing listens yet.

### Where things stand after step 4

```
Visitor ── HTTP :80 ──▶ nginx
                          ├─ /       ──▶ container playground-app (docker run, 127.0.0.1:3000)
                          └─ /todos  ──▶ 127.0.0.1:3001 ── nothing yet: 502          ◀── new

app server
  docker compose plugin installed                                                    ◀── new
  /etc/playground/ (root only)                                                       ◀── new
    compose.yaml, init-todo-user.js   ready, not started; no .env yet

Developer ── git push ──▶ GitHub Actions ──▶ deploy-playground-app <one image>         (unchanged)
```

## 5. The deploy command and the workflow switch to Compose

Three pieces change together: the deploy command on the server, the workflow, and the GitHub secrets. Once the new deploy command is installed, the old workflow (one image) is refused, so everything is prepared first and then installed and pushed in one go.

### Four new GitHub secrets

In the GitHub environment `main`, next to the existing ones:

| Secret | Value |
|---|---|
| `MONGO_ROOT_USERNAME` | `root` |
| `MONGO_ROOT_PASSWORD` | a new password, letters and digits only |
| `TODO_DB_USER` | `todo` |
| `TODO_DB_PASSWORD` | a new password, letters and digits only |

New passwords, not the ones from my PC. They are also kept in the password manager, because GitHub never shows a secret again.

**These are fixed after the first start.** MongoDB creates its users only when the volume is empty. Changing the secrets later does not change the passwords inside the database, and the Todo API could no longer log in.

### The deploy command, Compose version

`ansible/roles/app/templates/deploy-playground-app.j2`:

```bash
#!/bin/bash
set -euo pipefail

app_image="${1:-}"
todo_image="${2:-}"
if [[ ! "$app_image" =~ ^ghcr\.io/tao-68/playground-app:[0-9a-f]{40}$ ]] ||
   [[ ! "$todo_image" =~ ^ghcr\.io/tao-68/todo-api:[0-9a-f]{40}$ ]]; then
  echo "usage: deploy-playground-app <playground-app image> <todo-api image> [--settings-from-stdin]" >&2
  exit 1
fi

cd /etc/playground
umask 077
keys=(APP_SECRET_MESSAGE APP_USERNAME APP_PASSWORD MONGO_ROOT_USERNAME MONGO_ROOT_PASSWORD TODO_DB_USER TODO_DB_PASSWORD)

if [[ "${3:-}" == "--settings-from-stdin" ]]; then
  incoming=$(mktemp ./secrets.XXXXXX)
  pattern="^($(IFS='|'; echo "${keys[*]}"))=.+$"
  grep -E "$pattern" > "$incoming" || true
  for key in "${keys[@]}"; do
    if ! grep -q "^$key=" "$incoming"; then
      rm -f "$incoming"
      echo "missing $key on standard input" >&2
      exit 1
    fi
  done
  mv "$incoming" secrets.env
elif [[ -n "${3:-}" ]]; then
  echo "unknown option: $3" >&2
  exit 1
fi

if [[ ! -s secrets.env ]]; then
  echo "no settings in /etc/playground/secrets.env" >&2
  exit 1
fi

{
  cat secrets.env
  printf 'PLAYGROUND_APP_IMAGE=%s\nTODO_API_IMAGE=%s\n' "$app_image" "$todo_image"
} > .env.new
mv .env.new .env

show_failure() {
  docker compose ps >&2
  docker compose logs --tail 20 >&2
}

docker compose pull --quiet

# The container started by the previous deploy command still holds port {{ app_port }}
docker rm --force playground-app > /dev/null 2>&1 || true

if ! docker compose up --detach --remove-orphans --wait --wait-timeout 120; then
  echo "the stack did not start" >&2
  show_failure
  exit 1
fi

for port in {{ app_port }} {{ todo_api_port }}; do
  healthy=false
  for attempt in 1 2 3 4 5; do
    if curl -fs "http://127.0.0.1:$port/health" > /dev/null; then
      healthy=true
      break
    fi
    sleep 2
  done
  if [[ "$healthy" != true ]]; then
    echo "health check failed on port $port" >&2
    show_failure
    exit 1
  fi
done

echo "deployed $app_image and $todo_image"
```

What changed from the `docker run` version:

- **Two image names**, each checked against its own pattern.
- **`keys=(...)` is a bash array** of the seven settings. The `pattern=` line joins them with `|` into `^(APP_SECRET_MESSAGE|APP_USERNAME|...)=.+$`, so the list is written once and both the `grep` and the "missing" check use it.
- **Two files.** `secrets.env` holds what arrives on standard input and changes only when secrets are sent. `.env` is rebuilt on every deploy from `secrets.env` plus the two image names, and Compose reads it. A deploy without `--settings-from-stdin` keeps the secrets and changes only the images.
- **`mktemp ./secrets.XXXXXX`** creates the temporary file inside `/etc/playground`. The previous version used `/tmp`, which can be a different filesystem, where `mv` copies instead of renaming. On the same filesystem `mv` swaps the file in one step, so Compose never reads a half-written file.
- **`umask 077`** comes before any file is written, so `secrets.env` and `.env` are readable by root only.
- **`docker rm --force playground-app`** removes the container of the `docker run` setup, which held port 3000. Compose names its containers `playground-playground-app-1` and so on, so after the first switch this line finds nothing.
- **`--remove-orphans`** removes containers of services that were taken out of `compose.yaml`.
- **`--wait --wait-timeout 120`** makes `up` wait until MongoDB reports healthy and the others are running, or fail after 120 seconds. The `if !` around it makes sure the logs are printed. Under `set -e` a plain failing command would end the script before that.
- **The health loop checks both apps.** The Todo API's `/health` includes the database connection.

The sudo rule from Phase 7 stays as it is. It allows `deploy` to run this one command, with any arguments.

### The workflow

`.github/workflows/deploy.yml`, now named `Deploy stack`:

- **Also triggered by the Todo API:** `- "todo-api/**"` under `paths:`.
- **The build job builds and pushes both images** and hands both names to the deploy job:

```yaml
    outputs:
      app_image: ${{ steps.push.outputs.app_image }}
      todo_image: ${{ steps.push.outputs.todo_image }}
```

```yaml
      - name: Build and push the image
        id: push
        run: |
          owner="${GITHUB_REPOSITORY_OWNER,,}"
          app_image="ghcr.io/$owner/playground-app:$GITHUB_SHA"
          todo_image="ghcr.io/$owner/todo-api:$GITHUB_SHA"
          docker build -t "$app_image" app
          docker build -t "$todo_image" todo-api
          docker push "$app_image"
          docker push "$todo_image"
          echo "app_image=$app_image" >> "$GITHUB_OUTPUT"
          echo "todo_image=$todo_image" >> "$GITHUB_OUTPUT"
```

- **The Deploy step sends seven settings and two images:**

```yaml
      - name: Deploy
        env:
          APP_IMAGE: ${{ needs.build.outputs.app_image }}
          TODO_IMAGE: ${{ needs.build.outputs.todo_image }}
          SECRET_MESSAGE: ${{ secrets.SECRET_MESSAGE }}
          APP_USERNAME: ${{ secrets.APP_USERNAME }}
          APP_PASSWORD: ${{ secrets.APP_PASSWORD }}
          MONGO_ROOT_USERNAME: ${{ secrets.MONGO_ROOT_USERNAME }}
          MONGO_ROOT_PASSWORD: ${{ secrets.MONGO_ROOT_PASSWORD }}
          TODO_DB_USER: ${{ secrets.TODO_DB_USER }}
          TODO_DB_PASSWORD: ${{ secrets.TODO_DB_PASSWORD }}
        run: |
          printf 'APP_SECRET_MESSAGE=%s\nAPP_USERNAME=%s\nAPP_PASSWORD=%s\nMONGO_ROOT_USERNAME=%s\nMONGO_ROOT_PASSWORD=%s\nTODO_DB_USER=%s\nTODO_DB_PASSWORD=%s\n' \
            "$SECRET_MESSAGE" "$APP_USERNAME" "$APP_PASSWORD" \
            "$MONGO_ROOT_USERNAME" "$MONGO_ROOT_PASSWORD" "$TODO_DB_USER" "$TODO_DB_PASSWORD" |
          ssh -i ~/.ssh/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
            deploy@${{ vars.APP_HOST }} \
            "sudo /usr/local/bin/deploy-playground-app $APP_IMAGE $TODO_IMAGE --settings-from-stdin"
```

The GitHub secret `SECRET_MESSAGE` becomes `APP_SECRET_MESSAGE` on the way, to match the `APP_` names in the server's compose file.

Every push builds both images, even when only one app changed. Simple, and fast enough for two small apps.

The new `todo-api` package on GHCR has to be public, like `playground-app` in Phase 7. Otherwise the server cannot pull it without logging in.

### Order of the switch

1. Ansible installs the new deploy command: `ansible-playbook setup.yml --limit app --tags app`.
2. Commit and push the workflow, the template and the Ansible changes. The push triggers the workflow.
3. The first successful deploy also downloads the `mongo` image, so it takes a minute longer.

### Incident: MongoDB 8 refuses to start on the server

The first deploy failed at `docker compose up`:

```
dependency failed to start: container playground-mongo-1 is unhealthy
mongo-1 | {"s":"F", ... "msg":"MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility with this version of MongoDB. See https://jira.mongodb.org/browse/SERVER-121912 for more information."}
```

The playground app was already running under Compose, so the site stayed up. Only `/todos` was down.

**The cause.** MongoDB's 8.0 release notes say MongoDB 8 is incompatible with Linux kernels 6.19 through 7.0.13. Its memory allocator (TCMalloc) can crash there, so MongoDB checks the kernel version at startup and stops. This affects every MongoDB 8 package, Docker images included. The only fix the notes give is a kernel of 7.0.14 or newer.

| Machine | `uname -r` | MongoDB 8 |
|---|---|---|
| My PC (WSL) | 6.18 | starts, which is why steps 1 to 3 worked |
| The app server (Ubuntu 26.04) | `7.0.0-1014-aws` | refuses |

A container shares the host's kernel. The image brings its own files and libraries, but not its own kernel, so the same image behaves differently on two hosts.

**Options considered:**

| Option | Verdict |
|---|---|
| `mongo:7.0` instead of `mongo:8` | **Chosen.** The problem is reported for MongoDB 8.0 and newer only, and 7.0 is still a supported major version. |
| Force MongoDB 8 to run with `GLIBC_TUNABLES=glibc.pthread.rseq=1` | Rejected. It only gets past the check and keeps the crash-prone allocator. |
| Rebuild the server on Ubuntu 24.04 | Too much for this, and a step backwards. |
| Wait for a kernel MongoDB 8 accepts | Possible later. Ubuntu keeps the version number `7.0.0-<build>` for the whole release, so it is unclear whether MongoDB's version check will ever accept it. |

**The fix:**

1. `image: mongo:7.0` in both the local `compose.yaml` and the server's `compose.yaml.j2`, so my PC and the server run the same database.
2. Remove the failed container and its volume on the server. MongoDB cannot open data files written by a newer major version, and the failed start may have left some. There was no real data yet.

   ```bash
   sudo -i
   cd /etc/playground
   docker compose rm --stop --force mongo
   docker volume rm playground_mongo-data
   exit
   ```

   `docker compose down -v` would have done the same but stopped the playground app as well.
3. The same locally, where the volume had been created by MongoDB 8: `docker compose down -v`, then `docker compose up -d`.
4. Ansible installs the new compose file, then **Re-run failed jobs** on the workflow run. The images had not changed, only the server's compose file, so re-running the deploy job was enough.

### Two warnings in the workflow

| Warning | Fix |
|---|---|
| `actions/checkout@v4` targets Node.js 20, which GitHub is retiring | `actions/checkout@v5`, built for Node.js 24 |
| `ubuntu-latest` moves to Ubuntu 26 from 19 October 2026 | `runs-on: ubuntu-24.04` in both jobs. The runner now changes only when I change it, in a commit of its own. |

### The ssh-agent, again

`Connection closed by UNKNOWN port 65535` came back after WSL restarted. The agent holds keys only until WSL stops. `keychain` starts one agent per WSL session, shared by all terminals, and asks for the passphrases once. In `~/.bashrc`:

```bash
eval "$(keychain --eval --quiet ~/.ssh/ansible ~/.ssh/devops-playground)"
```

### Clean-up

The old settings folder of the `docker run` setup is removed by Ansible:

```yaml
- name: Remove the old settings folder
  ansible.builtin.file:
    path: /etc/playground-app
    state: absent
```

### Checks

On the server, as root:

```bash
cd /etc/playground
docker compose ps          # three services, mongo "(healthy)"
ls -la                     # .env and secrets.env: -rw------- root
docker volume ls           # playground_mongo-data
```

From my PC, against the public address:

```bash
curl http://<app-public-ip>/
curl -u '<username>:<password>' http://<app-public-ip>/secret
curl -i -X POST http://<app-public-ip>/todos -H 'Content-Type: application/json' -d '{"title":"first todo in production"}'
curl http://<app-public-ip>/todos
```

Persistence on the server: `sudo docker restart playground-mongo-1 playground-todo-api-1`, then the todo is still listed.

`curl` against the private address `172.31.19.0` only works with the VPN up, and without `-m 10` it waits for minutes before giving up.

## Result

```
Visitor ── HTTP :80 ──▶ nginx ──┬─ /, /secret, /health ──▶ playground-app
                                └─ /todos              ──▶ todo-api ──▶ mongo ──▶ volume

git push ──▶ build job: two images to GHCR
         └─▶ deploy job ══VPN══▶ bastion ──SSH──▶ app server, as deploy
                 seven settings on stdin ──▶ deploy-playground-app <app image> <todo image>
                                               writes /etc/playground/secrets.env and .env
                                               docker compose pull, up --wait, health checks
```

| Roadmap part | Where |
|---|---|
| A Todo API with Express: list, create, read, update, delete | Step 1 |
| MongoDB, with the data on a volume | Steps 1 and 3, the named volume `playground_mongo-data` |
| Docker Compose for the API and the database | Step 3 locally, step 4 on the server |
| Configuration management for the server | Step 4, Ansible |
| A workflow that builds the images and deploys with Compose | Step 5 |
| Bonus: a reverse proxy | nginx on the host, `location /todos` in step 4 |

## Architecture at the end of this phase

```
VISITOR
  browser ── HTTP :80 ──▶ app server (t3.small, 2 GiB, 20 GB)
                            nginx (security group + UFW allow 80)
                              ├─ /       ──▶ playground-app   127.0.0.1:3000
                              └─ /todos  ──▶ todo-api         127.0.0.1:3001
                                                │ Compose network "playground_default"
                                                ▼
                                              mongo (no published port, users root + todo)
                                                └─ volume playground_mongo-data

DEVELOPER
  PC: docker compose up -d --build
      builds both apps from source, MongoDB 7.0 on a local volume,
      settings from .env and app/.env (test values, ignored by git)
    └─ git push ──▶ GitHub, main
                      build job ──▶ GHCR: playground-app:<commit>, todo-api:<commit>   (public, no secrets)
                      deploy job (environment "main": VPN, SSH, app and database secrets)
                        ══ VPN, 10.8.0.4 ══▶ bastion ──▶ app server, as deploy
                        settings on stdin ──▶ deploy-playground-app <two images>
                        Compose pulls from GHCR and replaces what changed

ADMIN
  ssh bastion (key + MFA), ssh app (ProxyJump), VPN as 10.8.0.2
  ansible (ProxyJump as ansible; keys from keychain): Docker engine, Compose plugin,
    /etc/playground (compose.yaml, init script), the deploy command, nginx routes
  tofu (EC2 API, state in S3): instance type, disk size, security groups
  sudo -i; cd /etc/playground; docker compose ps | logs
```

| Perspective | At this point |
|---|---|
| Visitor | `http://<app-public-ip>/` as before. New: `/todos`, a Todo API without login, backed by MongoDB. |
| Developer | Runs the whole stack on the PC with one command, from source. A push builds two images and deploys both. Database passwords never leave GitHub and the server. |
| Admin | Ansible owns the files around the stack, the deploy command owns what runs. MongoDB is reachable only from inside the Compose network. The data lives in one volume, which nothing backs up yet. |

**Development vs production:**

| | Development (my PC) | Production (app server) |
|---|---|---|
| Apps | built from source with `build:` | images from GHCR with `image:`, one commit per deploy |
| Compose file | `compose.yaml` in the repository | `/etc/playground/compose.yaml`, from the Ansible template |
| Settings | `.env`, `app/.env`, test values | `/etc/playground/secrets.env` and `.env`, from GitHub secrets |
| Started by | me, `docker compose up` | the deploy command, through the pipeline |
| Kernel | WSL 6.18 | Ubuntu 26.04, 7.0.0 |

## Open items

- **No backups.** The todos live in one volume on one disk. Phase 9.
- **The Todo API has no login.** Anyone can create, change and delete todos. The roadmap does not ask for it, but a real API would need authentication and HTTPS.
- **No rollback**, now for three containers. If the new images fail the health check, the stack stays broken until the next good deploy.
- **MongoDB 7.0 instead of 8.** Revisit when the server's kernel is one MongoDB 8 accepts. The move needs care: MongoDB upgrades one major version at a time, and the data has to be backed up first.
- **The database passwords are fixed after the first start.** Changing them means changing them inside MongoDB as well as in GitHub.
- **The disk is not encrypted** (`encrypted = false` on the EBS volume). AWS cannot switch this on for an existing volume, only by copying to a new, encrypted one.
- **Old images pile up on the server**, now two per deploy. `docker image prune` after a successful deploy would clear them.
- **Both images are rebuilt on every push**, even when only one app changed.
- **The `mongo:7.0` tag moves** with each 7.0 patch release. Pinning a digest would make deploys fully repeatable.
- **One-time lines left behind:** the `docker rm --force playground-app` line in the deploy command, and the cleanup tasks of earlier phases in the app role.
- **From earlier phases:** HTTPS, the visible `Server` and `X-Powered-By` headers, the public IP that changes on every stop and start.
