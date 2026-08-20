# Changelog

All notable changes to the Big Brother project are documented in this file.

## v1.0.1 (2026-08-20)

- Fix SMART device detection for shared device paths
- Improve agent reconnection when SSH connections silently fail
- Fix stale SMART records when drives are no longer reported
- Point release badges at the GitHub Container Registry
- Add health score summary card to the system page
- Update documentation and install guides

## v1.0.0 (2026-07-28)

- First stable release
- Add multi-battery monitoring
- Add Linux fan RPM monitoring
- Add Intel GPU power monitoring through sysfs
- Add ARMv5, ARMv6 and ARM64 agent builds
- Add slim NVIDIA agent container image
- Add public key display to token settings
- Add support for showing all container port mappings

## v0.4.0 (2026-07-14)

- Add Windows agent support via LibreHardwareMonitor
- Add docker image build workflows and GoReleaser
- Add multilingual translations (30+ languages)
- Add issue templates, SECURITY.md and CODEOWNERS
- Add dependency vulnerability scanning

## v0.3.0 (2026-06-18)

- Add Docker Compose examples
- Add one-line install scripts for Linux, macOS and Windows
- Add Helm charts for hub and agent
- Add Debian packaging
- Add systemd and guides documentation
- Add self-update mechanism with checksum verification

## v0.2.0 (2026-05-22)

- Add GPU monitoring (NVML, AMD, Intel, nvtop)
- Add alert quiet hours and alert history
- Add token and fingerprint management
- Add SSH transport for agent connections
- Add heartbeat monitoring
- Add systemd unit monitoring

## v0.1.0 (2026-04-12)

- Initial release
- Hub web application built on PocketBase
- Agent with CPU, memory, disk and network collectors
- Real-time dashboard with live charts
- Docker container statistics
- SMART disk health monitoring
- Alert engine with notification support