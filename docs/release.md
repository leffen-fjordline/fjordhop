# Release

A release is a signed git tag, a GitHub release, and a formula update that
points Homebrew at the new tag. There is no binary to upload: users build
from source.

The formula update has to come in a commit **after** the tag. The formula
needs the SHA-256 of the tag's tarball, and that tarball exists only once the
tag is pushed. This works because Homebrew reads the formula from the tap's
`main` branch, never from a tag.

Replace `X.Y.Z` below with the new version. Use
[semantic versioning](https://semver.org): bump the patch number for fixes,
the minor number for new features, and the major number for changes that
break how people use it.

## Before you start

- `gh` is logged in with push access to `leffen-fjordline/fjordhop`.
- Your git commits and tags are signed (`git config commit.gpgsign` is
  `true`). The tag command below uses `-s`.
- You are on `main`, in sync with `origin`, with a clean tree:

    ```sh
    git switch main && git pull && git status
    ```

- The app works: `./install.sh`, then try the menu, ⌃⌥C and `cs`.

## 1. Set the version in the app

In `app/Info.plist`, set `CFBundleShortVersionString` to `X.Y.Z` and
increase `CFBundleVersion` by one. macOS shows these in Finder's Get Info.

```sh
git commit -am "Bump version to X.Y.Z"
git push origin main
```

## 2. Tag and publish the release

```sh
git tag -s vX.Y.Z -m "Fjordhop X.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --title "Fjordhop X.Y.Z" --generate-notes
```

`--generate-notes` lists the commits since the previous tag. Pass
`--notes "..."` instead to write the notes yourself, or edit them on GitHub
afterwards.

## 3. Hash the release tarball

```sh
curl -sL https://github.com/leffen-fjordline/fjordhop/archive/refs/tags/vX.Y.Z.tar.gz \
  | shasum -a 256
```

## 4. Point the formula at the new tag

In `Formula/fjordhop.rb`, change the two lines below. Homebrew reads the
version from the tag in the URL, so there is no separate version line.

```ruby
url "https://github.com/leffen-fjordline/fjordhop/archive/refs/tags/vX.Y.Z.tar.gz"
sha256 "<the hash from step 3>"
```

Check the style. `brew style` names the formula after its file, so lint it
from a folder called `Formula`, which the repo already has:

```sh
brew style Formula/fjordhop.rb
```

## 5. Test the formula before pushing

Homebrew installs only from a tap, so make a throwaway local tap with the
edited formula:

```sh
brew tap-new --no-git local/fjordhoptest
cp Formula/fjordhop.rb "$(brew --repository local/fjordhoptest)/Formula/"
HOMEBREW_NO_AUTO_UPDATE=1 brew install local/fjordhoptest/fjordhop
brew test local/fjordhoptest/fjordhop
```

The install should end with `🍺 …/Cellar/fjordhop/X.Y.Z`. Then clean up:

```sh
brew uninstall local/fjordhoptest/fjordhop
brew untap local/fjordhoptest
```

!!! warning "Don't set `HOMEBREW_NO_INSTALL_FROM_API`"
    With it set, Homebrew clones all of homebrew-core to resolve the `fzf`
    dependency, which takes many minutes.

## 6. Publish the formula

```sh
git commit -am "Formula: install the vX.Y.Z release by default"
git push origin main
```

## 7. Check it from a user's side

```sh
brew update
brew info leffen-fjordline/fjordhop/fjordhop   # should say stable X.Y.Z
brew upgrade fjordhop
```

Then follow the update steps in [Install](install.md#update) to copy the new
app to `~/Applications`.

## If something goes wrong

The checksum doesn't match
:   The tarball changed after you hashed it, usually because the tag was
    moved. Never move a published tag. Make a new patch release instead.

The release has a bad bug
:   Release a fix as the next patch version. To keep people off the broken
    version until then, point the formula back at the previous tag and its
    hash, and push. Leave the bad tag and release in place, and add a note to
    the release on GitHub.
