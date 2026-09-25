# STATE — kickoff pointer (1 page, not an issue list)

Map: [Audit route to a self-explanatory codebase (map)](https://github.com/ranokay/glance/issues/39)

Destination: route is clear when transient AUDIT findings are filed as scoped GitHub tickets, durable STATE.md kickoff pointer exists, and every ticket carries its verification + evidence contract. Refactor/implement work happens after via to-spec/to-tickets/implement, not inside this map.

Kickoff: `read STATE.md and run the kickoff`

- Pick first frontier child in map order (open + unblocked + unclaimed). Issue state is progress — this file never lists tickets.
- Emit human gates before acting; never stall waiting — continue everything else.
- Empty frontier → report map-done.

Human gates (agent stops, wizard checklist blocks the step): destructive (reset/uninstall/shared-DerivedData clean), publishing (gh release, App Store), credentials (Apple ID, notarization, keychain, VM secrets), signing/entitlement/deployment-target changes.

Context: transient AUDIT.md (deleted after ticketing per #63) + [CHANGELOG.md](./CHANGELOG.md). Locked: slices/no-big-bang [#46](https://github.com/ranokay/glance/issues/46), docs/lifecycle [#47](https://github.com/ranokay/glance/issues/47), automation/evidence/stack [#48](https://github.com/ranokay/glance/issues/48).
