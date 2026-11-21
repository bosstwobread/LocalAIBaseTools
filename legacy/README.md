# Retired tools

`MessageHelper-Upwork/` retains the former browser companion for compatibility and its zero-send test fixture. MacHelper 6.6 and the current marketplace use the independent Translation and Polish-input source extensions instead. They work through the MacHelper selection toolbar without a browser extension.

The retired browser package is not listed in the current marketplace or bundled as a current source tool. Existing Native Messaging clients retain their protocol compatibility; this archive does not enable or install them.

[`MarketplacePackages/packages/`](MarketplacePackages/packages/) stores the source files and ZIPs for older marketplace releases. The website build copies these bytes to their original `/packages/` paths so existing links and catalog hashes still work.

Legacy regression tests stay in `test/` and exercise this source with synthetic data. Never send an Upwork message, submit feedback, or overwrite a real draft while testing.
