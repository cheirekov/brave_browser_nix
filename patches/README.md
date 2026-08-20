# Downstream patches

`0001-use-br-user-data-directory.patch` changes Brave's Linux default user-data
directory from `BraveSoftware/Brave-Browser` to `br`. The wrapper also passes
the same directory explicitly. Patching the default is still necessary because
some Chromium paths, notably crash reporting, intentionally consult the default
instead of `--user-data-dir`. The patch therefore prevents a second
`BraveSoftware` directory from appearing next to the isolated `br` profile.

Tor is disabled independently with Brave's supported `enable_tor=false` GN
argument. Brave's own patch series remains part of the pinned `brave-core`
source and is applied before this single downstream patch.
