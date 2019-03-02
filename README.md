# git-buildnumber.sh

Create a continuous, consistent buildnumber independent of branch.
Synchronizes with the remote `origin` repository.

Manages build numbers based on `refs/buildnumbers/last` and notes in `refs/notes/buildnumbers`.

# Install

```bash
curl -O https://raw.githubusercontent.com/hpoul/git-buildnumber/v1.0/git-buildnumber.sh
chmod +x git-buildnumber.sh
sudo mv git-buildnumber.sh /usr/local/bin/
```

If you just want to use it on a CI you could obviously also just run it directly to generate a new build number:

`curl -s https://raw.githubusercontent.com/hpoul/git-buildnumber/master/git-buildnumber.sh | bash`

feel free to pin a specific version or hash 😉️

`curl -s https://raw.githubusercontent.com/hpoul/git-buildnumber/v1.0/git-buildnumber.sh | bash`

# Usage

Run inside your git repository. It expects the master remote repository to be named `origin` right now.

```bash
# Generates a new build number for the current commit, 
# or outputs the build number for the current commit, if it exists:
./git-buildnumber.sh 


# Show commit for a given build number:
./git-buildnumber.sh find-commit 99
```


