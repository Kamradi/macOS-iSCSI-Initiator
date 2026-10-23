# Driver research

This project does not contain a DriverKit or kernel extension. Working Finder integration uses a private loopback filesystem bridge and the built-in macOS Raw DiskImage infrastructure.

See [the implemented architecture](../docs/ARCHITECTURE.md). DriverKit prototypes and hardware-dependent DMA experiments are not part of this release.
