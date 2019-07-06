# git-buildnumber.sh

Create a continuous, consistent buildnumber independent of branch.
Synchronizes with the remote `origin` repository.

This is especially useful to create unique build numbers for mobile apps which are distributed in app stores, but might be built across different build servers. So you can easily use the build number as `versionCode` on android or `CFBundleVersion` on iOS. If you have a cross platform app in one repository, this makes sure that when building each version of the app (even on different build servers) they will have the same build number (if built from the same commit).

Behavior: first it checks if the current git commit has a build number already assigned to it, if so this one will be used, otherwise the global build number of the repository is incremented. (this guarantees that all builds from one and the same commit, even across built variants and platforms have the same build number).

Manages build numbers based on `refs/buildnumbers/last` and notes in `refs/notes/buildnumbers`.

# Install

## Homebrew

```bash
brew tap hpoul/tap
brew install git-buildnumber
```

## By hand

```bash
curl -O https://raw.githubusercontent.com/hpoul/git-buildnumber/v1.0/git-buildnumber.sh
chmod +x git-buildnumber.sh
sudo mv git-buildnumber.sh /usr/local/bin/
```

If you just want to use it on a CI you could obviously also just run it directly to generate a new build number:

`curl -s https://raw.githubusercontent.com/hpoul/git-buildnumber/master/git-buildnumber.sh | bash /dev/stdin generate`

feel free to pin a specific version or hash 😉️

`curl -s https://raw.githubusercontent.com/hpoul/git-buildnumber/v1.0/git-buildnumber.sh | bash /dev/stdin generate`

# Usage

Run inside your git repository. It expects the master remote repository to be named `origin` right now.

```bash
# Generates a new build number for the current commit, 
# or outputs the build number for the current commit, if it exists:
./git-buildnumber.sh generate
```

```bash
sh>>> ./git-buildnumber.sh help
git-buildnumber, version 1.0
Usage: ./git-buildnumber.sh <command>

Commands:
  generate             -- The default, outputs build number for current commit
                          or generates a new one.
  find-commit <number> -- Finds the commit (message) for a given build number.
  force <number>       -- Uses the given number as the current buildnumber of
                          the current commit.
  get                  -- show the build number for the current commit (if any)
  sync                 -- fetch && push
  fetch                -- fetch all refs from remote
  push                 -- push all refs from remote
```



