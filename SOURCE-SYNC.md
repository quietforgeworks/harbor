# Harbor 0.3.0 source synchronization

The application sources and Info.plist come from the local 0.3.0 build 8 work tree. The corresponding patched Mihomo source, vendored dependencies, notices and build policy are retained from the previously published 0.2.0 source package. Only the outer build output filename is advanced to 0.3.0. No installed application or system proxy was changed.

Validation: swift test passed 75 tests, zero failures, and compiled the app in debug mode on Apple Silicon. Full patched-core rebuild, distribution signing, UI and real failover behavior have not been rerun for this combination.

Secret-pattern review: hits are unchanged public Mihomo example/test key fixtures inherited from the released source, not user credentials. No subscriptions, local preferences, private configurations or compiled artifacts are included.
