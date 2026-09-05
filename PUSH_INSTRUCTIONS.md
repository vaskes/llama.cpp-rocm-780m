# PUSH_INSTRUCTIONS.md — how to push this repo to GitHub

The `https://github.com/vaskes/llama.cpp-rocm-780m` repo is empty and
ready to receive this commit. The build environment does not have
GitHub credentials, so the push must be done by a human (you) from
anywhere with `git push` access.

## What's in this commit

```
.dockerignore
.gitignore
OPERATIONS.md
PUSH_INSTRUCTIONS.md
README.md
docker-compose.yml
build/Dockerfile
scripts/start.sh
scripts/stop.sh
scripts/restart.sh
scripts/shell.sh
scripts/logs.sh
scripts/test-api.sh
```

The image is `llama.cpp-rocm-780m:7.13` (10.7 GB on disk, 3.25 GB
compressed), already built and tagged locally on llmhost2. The push
instructions do **not** include the image — push the source tree, and
the next `docker build` on the target machine reproduces the image.

## Steps

### 1. Pull this commit to your local machine

```bash
# Option A: tarball
ssh git@85.136.112.144 "cd /opt && tar -czf /tmp/llama.cpp-rocm-780m.tar.gz llama.cpp-rocm-780m --exclude=build --exclude=logs --exclude='*.log' --exclude='.git'"
scp git@85.136.112.144:/tmp/llama.cpp-rocm-780m.tar.gz .
tar -xzf llama.cpp-rocm-780m.tar.gz
cd llama.cpp-rocm-780m

# Option B: git clone from the local repo (if you have SSH access to llmhost2)
git clone git@85.136.112.144:/opt/llama.cpp-rocm-780m.git
cd llama.cpp-rocm-780m
```

### 2. Verify the contents

```bash
ls -la
# Should see: README.md OPERATIONS.md PUSH_INSTRUCTIONS.md
#              docker-compose.yml .gitignore .dockerignore
#              build/ scripts/ logs/  (logs/ is empty)
```

### 3. Push to GitHub

```bash
# The remote is already set up if you cloned the empty repo first.
# If not:
git remote add origin https://github.com/vaskes/llama.cpp-rocm-780m.git

# Set the local branch to main (GitHub default)
git branch -M main

# Push
git push -u origin main

# If GitHub asks for auth and you have 2FA:
# - Use a Personal Access Token (PAT) in the password field, or
# - Use gh CLI: gh auth login && git push -u origin main
```

### 4. Optional: publish the Docker image

The image is already built on llmhost2 as `llama.cpp-rocm-780m:7.13`.
To make it available to others without a build, push it to GitHub
Container Registry (ghcr.io) or Docker Hub:

```bash
# Option A: GitHub Container Registry (recommended — same auth as git push)
echo "$GITHUB_PAT" | docker login ghcr.io -u vaskes --password-stdin
docker tag llama.cpp-rocm-780m:7.13 ghcr.io/vaskes/llama.cpp-rocm-780m:7.13
docker push ghcr.io/vaskes/llama.cpp-rocm-780m:7.13

# Then update docker-compose.yml to use ghcr.io/vaskes/llama.cpp-rocm-780m:7.13
# instead of llama.cpp-rocm-780m:7.13
```

## What the user will see on GitHub

A clean, well-documented repo with:
- Comprehensive README explaining the build choices (and the 7.13
  wheels / 7.14 wheels / apt 7.2.4 decision tree)
- OPERATIONS.md with day-to-day management
- Working `docker compose up -d` deployment
- The Dockerfile is portable — works on any Ubuntu 24.04 host
