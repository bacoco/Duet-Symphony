# Duet-Symphony Specification

This directory contains the **language-agnostic specification** for
Duet-Symphony. Everything an implementer needs to build a conformant port
in any language is here.

## Files

| File | Purpose |
|------|---------|
| [`SPEC.md`](./SPEC.md) | Normative specification (v0.4.1). Defines architecture, agent routing, tool profiles, phase pipeline, verification gates, convergence protocol, failure modes, configuration, conformance, and implementation-defined items. |

## Reading order

1. **§1-4** — Purpose, relation to Symphony, non-goals, glossary, architecture
2. **§5-7** — Task lifecycle, workspace/branch harness, agent runtime management and routing profiles
3. **§8-10** — Phase pipeline, optional SuperPower artifacts, PR-as-artifact protocol, convergence protocol
4. **§11-14** — Failure modes, configuration, logging/UI, security
5. **§15-20** — CLI surface, conformance, implementation-defined, open questions

## For implementers

A conformant implementation MUST satisfy the requirements in §16 and document
its choices for every item in §17. The spec is designed so you can build a
working Duet-Symphony in any language using only this document and the
[OpenAI Symphony SPEC](https://github.com/openai/symphony/blob/main/SPEC.md)
as references.

The parent repository's implementation is a Symphony fork with a Duet
pair-runtime overlay. You are not required to follow that approach — any
architecture that satisfies §16 conformance is valid.

## License

Same as the parent repository. When deriving from OpenAI Symphony code,
preserve Apache-2.0 license and NOTICE attribution per §1.1.
