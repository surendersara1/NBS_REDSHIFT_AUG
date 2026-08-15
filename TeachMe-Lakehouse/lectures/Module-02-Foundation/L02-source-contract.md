# L02 · Define the Source Contract First

> **Module 2 · Lesson 02** · ~45 min

**Slide:** [`_render/L02-source-contract.html`](_render/L02-source-contract.html)

## The decision

Source number nine will arrive. It always does — a new acquisition, a new loyalty platform, a system nobody mentioned in the kickoff.

> **How does it plug in?**

Two answers. Either the engine grows a branch for every vendor (`if source == "oracle": ... elif source == "epsilon": ...`, spreading through jobs, writers and barriers), or the engine **never hears a vendor's name at all** and looks a class up by string at run time.

**Write the interface before you write any source.** The first connector you write will otherwise become the interface by accident, shaped entirely around whichever system you happened to start with.

## Do this

1. **Write the `Protocol` first — five methods, no more.**

   ```python
   class SourceConnector(Protocol):
       def configure(cfg)       -> None
       def read_full()          -> DataFrame
       def read_incremental(wm) -> tuple[DataFrame, str]   # (rows, new_watermark)
       def read_range(a, b)     -> DataFrame
       def emit_metrics()       -> dict
   ```

   Mark it `@runtime_checkable` so a test can assert `isinstance(conn, SourceConnector)` before the class ever runs in production.
   *Worked example:* [`sources/protocol.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/protocol.py) — the whole contract is about a hundred lines including docstrings.

2. **Put credentials and validation in `configure`, once per run.** Secret fetch, driver setup, connection-string assembly, and every precondition check the connector wants to make. It runs once; the read methods stay cheap and stateless.

3. **Make `read_incremental` *return* the new watermark — never persist it.** The connector hands back `(df, new_watermark)`; the engine writes it, atomically with the run-success record. Ordering matters: a connector that advanced its own watermark would move the bookmark for a run that then failed to land, and the rows in the gap are lost forever.

4. **Build a registry keyed by string.**

   ```python
   @register("oracle_jdbc")
   class OracleJdbcConnector: ...

   conn = get_connector(source_type)()      # look up by name
   conn.configure(cfg)
   ```

   Populate it with import side effects — one import block that pulls in every connector module so its decorator runs. Note that this block is load-bearing: delete it and the registry is empty.
   *Worked example:* [`sources/__init__.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/__init__.py).

5. **Make both registry failure modes loud.** Registering the same name twice raises immediately ("refusing to overwrite"). Asking for an unregistered name raises an error that **lists every registered name** — that list is the fastest debugging aid you will ship all quarter.

6. **Let a connector decline a mode.** A snapshot-only source raising `NotImplementedError` from `read_range` is correct behaviour, and the contract should say so explicitly. Declining is part of the interface, not a bug.
   *Worked example:* [`sources/excel_landing.py`](../../../tamimi-lakehouse/src/glue/glue_engine/sources/excel_landing.py).

7. **Allow a per-mode driver override, and keep it in config.** A table may want one connector for its full load and another for its deltas. Resolve it with a pure function — no cloud SDK imports, no Spark — so it is unit-testable anywhere.
   *Worked example:* [`driver_select.py`](../../../tamimi-lakehouse/src/glue/glue_engine/driver_select.py).

8. **Where the Oracle branch lands.** Onboarding Oracle is:
   - **1 new file** — `sources/oracle_jdbc.py`, holding the driver JAR reference, the connection URL, the partitioning strategy, the type quirks, everything Oracle-shaped.
   - **1 import line** — added to `sources/__init__.py`.
   - **0 changes** to jobs, writers, barriers, the control plane or any other connector.

9. **Enforce it with a test you can run in CI.**

   ```
   grep -ri oracle glue_engine/  →  hits sources/oracle_jdbc.py and nothing else
   ```

   If that grep ever returns a second file, a vendor name has leaked into the engine. Fail the build.

## Why

- **One interface, many shapes.** A JDBC pull, a paged REST call and a nightly file drop all satisfy the same five methods. The engine cannot tell them apart, and does not need to.
- **Onboarding becomes additive.** New behaviour is a new file. Nothing existing is edited, so nothing existing can regress — which means the change is reviewable in isolation and cheap to roll back.
- **The seam is free.** A `Protocol` and a dictionary cost you an afternoon. You will pay that afternoon back the first time a source is added, and again every time after.
- **It tells you when the engine genuinely must change.** If a source cannot express *any* of full / range / incremental, the contract is wrong and you should change the contract deliberately — rather than smuggling the special case into a job.

**What breaks if you don't:** source number nine means edits to twenty unrelated files, each one a chance to regress a source that was working fine yesterday.

## On Apparel Group

All eight sources reduce to three connector classes and a handful of declined modes.

| Source | `source_type` | `read_full` | `read_incremental` | `read_range` |
|---|---|---|---|---|
| Oracle Retail (RMS) | `oracle_jdbc` | ✔ | ✔ | ✔ |
| Oracle SIM | `oracle_jdbc` | ✔ | ✔ | ✔ |
| Oracle XStore | `oracle_jdbc` | ✔ | ✔ | ✔ (the giant needs it) |
| Epsilon | `api_cursor` | ✔ | ✔ (their cursor) | decline |
| MoEngage | `api_cursor` | ✔ | ✔ (their cursor) | decline |
| Magento | `oracle_jdbc` or `api_cursor` | ✔ | ✔ | depends |
| Vemco Footfall | `file_drop` | ✔ | decline | decline |
| Irisys Footfall | `file_drop` | ✔ | decline | decline |

Two things to notice. **Declining is the common case, not the exception** — five of the eight decline at least one mode, and that is fine. And **Epsilon carries PII**, so its connector is also the natural place to enforce masking-at-read; keeping that inside the class rather than in a job is what stops the rule being forgotten on source number ten.

Write the Oracle connector once and three of your eight sources are covered. That is the return on defining the contract first.

## Checklist

- [ ] `Protocol` written and `@runtime_checkable`, with all five method signatures
- [ ] Docstrings state the watermark contract: the connector **returns**, the engine **persists**
- [ ] Registry populated by decorator; the side-effect import block is present and commented as load-bearing
- [ ] Duplicate registration raises; unknown name raises and lists what *is* registered
- [ ] Declining a mode is documented as legal, with a real example
- [ ] Per-mode driver override resolves in a pure, importable-anywhere function
- [ ] A contract test asserts every registered class satisfies the `Protocol`
- [ ] CI runs the vendor-name grep over the engine package
- [ ] Adding a source touched exactly one new file and one import line — verified

## You've got it when you can…

…explain to a sceptical colleague why onboarding Oracle needs no change to the download job, point at the exact line where the class is chosen by name — and then say what *would* legitimately force an engine change: a source that cannot express any of full, range or incremental.
