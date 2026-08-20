# Downstream patches

`0000-fix-brave-patch-walker.patch` repairs the pinned Brave 1.93.137 legacy
patch driver. Its two `os.walk()` loops unpack only two values, although Python
returns `(root, directories, files)`. The compatibility patch also replaces
the obsolete `python-patch` backend, which requires exact hunk line numbers,
with GNU `patch`. Brave's current patch set contains valid unified diffs with
small upstream offsets, which GNU `patch` handles in the same way as the
current Brave Git-based tooling.

Brave's version updater normally reads the pristine Chromium `chrome/VERSION`
from Git metadata. Nix source snapshots deliberately contain no `.git`
directory, so the package creates the required `.chromium` sidecar from the
pristine file and writes the pinned Brave version fields directly before
running Brave's normal version generator.

`0001-use-br-user-data-directory.patch` changes Brave's Linux default user-data
directory from `BraveSoftware/Brave-Browser` to `br`. The wrapper also passes
the same directory explicitly. Patching the default is still necessary because
some Chromium paths, notably crash reporting, intentionally consult the default
instead of `--user-data-dir`. The patch therefore prevents a second
`BraveSoftware` directory from appearing next to the isolated `br` profile.

Tor is disabled independently with Brave's supported `enable_tor=false` GN
argument. Apart from the compatibility fix needed to run Brave's patch driver,
Brave's own patch series remains unchanged and is applied before the profile
path patch.
