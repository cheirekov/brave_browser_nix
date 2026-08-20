# Downstream patches

`0000-fix-brave-patch-walker.patch` repairs the pinned Brave 1.93.137 legacy
patch driver. Its two `os.walk()` loops unpack only two values, although Python
returns `(root, directories, files)`. The compatibility patch adds the ignored
directory value so Brave's own Chromium patch series can be applied.

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
