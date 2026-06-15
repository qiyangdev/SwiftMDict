# ``SwiftMDict``

Read MDict 2.x dictionary and resource archives with bounded parsing,
dictionary-aware lookup, and lazy record decompression.

## Overview

Create an ``MDict`` from a file URL or `Data`. The container header and entries
are parsed eagerly, while record blocks are decompressed on demand and retained
by a bounded cache.

Use ``MDictOptions`` to select file loading, indexing, cache budgets, and
``MDictLimits`` for untrusted input.

## Topics

### Opening Containers

- ``MDict``
- ``MDictOptions``
- ``MDictLimits``
- ``MDictContainerKind``

### Reading Content

- ``MDictEntry``
- ``MDictRecord``
- ``MDictHeader``

### Errors

- ``MDictError``
