# Change Log

All notable changes to this project will be documented in this file.
This project adheres to the [Semantic Version](https://semver.org/) guideline.

## [Version] - yyyy-mm-dd

Here we write upgrading notes and make them as straightforward as possible.

### Added
- A short description for added item 1
- A short description for added item 2
- A short description for added item n

### Changed
- A short description for changed item 1
- A short description for changed item 2
- A short description for changed item n

### Fixed
- A short description for fixed item 1
- A short description for fixed item 2
- A short description for fixed item n

## [v1.1.1] - 2026-01-09

Minor code refactoring on `io_uring.zig`.

## [v1.1.0] - 2025-09-13

Minor code changes required for Zig v0.15.1 breaking changes.

## [v1.0.0] - 2025-07-29

A minimal barebones functionality for getting the job done.

## [v0.5.2] - 2025-07-25

Allows task executor integration on AsyncIo.

### Added
- `aio`, and `cpu` callbacks.

## [v0.5.1] - 2025-06-27

Less CPU consumption on internal `tick()`.

### Added
- `pending_ios` counter for early exist.

## [v0.5.0] - 2025-05-15

A minimal barebones implementation of Saturn.
